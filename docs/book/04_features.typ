#import "theme.typ": *
#import "figures.typ": *

= Advanced Replicated Log Features

#objectives([
  By the end of this chapter you should be able to drive logical timers with `tick`,
  execute dynamic membership reconfigurations with Lamport's `Stop_Sign` protocol,
  install snapshot trim anchors, and pipeline client requests without risking data loss.
])

== Logical Time: The Power of Ticks

Paxos safety never depends on synchronized clocks. Progress (liveness), however,
requires detecting peer silence and triggering retransmissions.

Reading the system clock directly inside the core would destroy determinism: two
runs with the same inputs might diverge due to timer differences.
`paxos-odin` solves this by keeping time out of the core entirely.
The host application advances logical time by periodically calling `node_tick`:

#code_file("src/protocol.odin", [
```odin
// Called by the host event loop (e.g. every 10ms or on scheduler ticks)
err := paxos.node_tick(&node, &effects)
```
])

#book_figure(
  [One logical tick drives election timers, leader heartbeats, and slot retransmission sweeps.
  Only the logic for the node's current role executes.],
  tick_flow(),
)

During a `tick`:
1. *Follower*: Increments `election_ticks`. If no valid leader traffic arrives
   before `election_timeout_ticks` expires, the follower suspects the leader and
   initiates a new campaign with a higher ballot.
2. *Leader*: Increments `heartbeat_ticks`. When it reaches `heartbeat_interval_ticks`,
   it transmits lightweight heartbeats to prevent follower election splits.
3. *Leader*: Increments `resend_ticks`. At `resend_interval_ticks`, it sweeps its
   uncommitted ring-buffer slots and re-transmits pending proposals to slow peers.

Because ticks are plain procedure calls, tests and simulators can advance time
instantly without waiting for wall-clock milliseconds.

== Dynamic Reconfiguration: Stop Signs

How can a distributed cluster add or remove servers safely without shutting down?
If two different configurations were active at the same time, each might form a
disjoint quorum, leading to catastrophic split brain.

`paxos-odin` implements the state-machine reconfiguration protocol from Lamport,
Malkhi, and Zhou's *"Reconfiguring a State Machine"*:

#book_figure(
  [A Stop Sign decided in slot $s$ seals configuration $C_1$. All subsequent
  decrees ($s + 1, dots$) execute strictly under configuration $C_2$.],
  reconfiguration_flow(),
)

1. A special `Stop_Sign` decree is proposed in slot $s$ containing the new membership list:
   #code_file("src/replicated_log.odin", [
   ```odin
   Stop_Sign :: struct(MAX_MEMBERS: int = 7, METADATA_BYTES: int = 64) {
       members:  small_array.Small_Array(MAX_MEMBERS, NodeId),
       metadata: small_array.Small_Array(METADATA_BYTES, u8),
   }
   ```
   ])
2. Once the `Stop_Sign` is chosen in slot $s$, configuration $C_1$ is *permanently sealed*.
3. Any attempt to propose commands after the stop sign under the old configuration
   returns `Error.LogSealed`.
4. The new configuration $C_2$ takes ownership of the log starting strictly at slot $s + 1$.

Because the handover occurs on a single continuous slot line, configuration changes
are completely serialized and immune to split-brain.

== Log Trimming and Snapshot Anchors

As a service runs for years, storing every past slot would exhaust storage.
Once an application takes a complete state snapshot at slot $k$, it can safely trim
the preceding log prefix:

#code_file("src/protocol.odin", [
```odin
Trim_Anchor :: struct {
	trim_id:          u64,
	chosen_trim_slot: Slot,
	history_hash:     u64,
}
```
])

When the host calls `node_install_chosen_trim(&node, anchor, &effects)`:
1. The node records a `Write_Trim_Anchor` effect to persist the trim boundary.
2. The memory floor advances, freeing all cells below `chosen_trim_slot`.
3. If a severely lagging peer connects requesting slots below the trim boundary,
   the node responds with a `Host_Request.Serve_Snapshot`, delegating bulk snapshot
   transfer to the host application.

== High-Throughput Batching

In workloads with thousands of requests per second, issuing single-item proposals
multiplies overhead. `paxos-odin` provides `node_propose_batch`:

#code_file("src/protocol.odin", [
```odin
node_propose_batch :: proc(
	node:    ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	values:  []Value,
	slots:   []Slot,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> (int, Error)
```
])

Batching assigns contiguous slots to an array of client values in a single pass,
amortizing ring-buffer updates and generating aggregated `Accept` messages that
replicate millions of commands per second.

#teach_back([
  Explain why a Stop Sign must be chosen through consensus rather than broadcast as
  an out-of-band administrative message.
])
