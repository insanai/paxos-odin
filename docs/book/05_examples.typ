#import "theme.typ": *
#import "figures.typ": *

// Unicode line breaking forbids a break before "."; see the same rule in Part VII.
#show raw.where(block: false): it => {
  if it.text.starts-with(".") { sym.zws }
  it
}

#part_page("V", [Three worked systems], [
  We run the repository's counter line by line, design a key-value host around
  the library's contract, and rehearse a partition in a five-voter control plane.
  The guidance thins as the systems grow.
])

= Three Worked Systems

#objectives([
  By the end of this chapter you should be able to trace the runnable counter's
  host loop and explain its output, add durable request deduplication and an
  explicit read discipline to a key-value host, say when a host would turn on
  rotating ownership, and write the pass and fail observations for a regional
  partition drill without claiming anything the library does not provide.
])

== Small Example: The Replicated Counter

`examples/counter.odin` is the complete integration contract in miniature. It
runs three nodes in one process, with a queue standing in for the network and
nothing standing in for the journal. Run it from the repository root with
`odin run examples/counter.odin -file`.

=== The command and the types

#code_file("examples/counter.odin", [
```odin
package main

import "core:container/queue"
import "core:fmt"
import paxos "../src"

Command :: struct {
	client_id:  u32,
	request_id: u32,
	amount:     i64,
}

MEMBERS :: 3
WINDOW  :: 64
CHUNK   :: 16

Node    :: paxos.Node(Command, MEMBERS, WINDOW, CHUNK)
Effects :: paxos.Effects(Command, MEMBERS, WINDOW, CHUNK)
```
])

`Command` is three integers, so it is comparable and self-contained. The two
aliases pin one configuration, three members with a 64-slot window and 16-slot
recovery chunks, and share it between node and batch, which is what lets
`paxos.step(&node, envelope, &effects)` type-check. `WINDOW` must be a power
of two, because a slot's cell is `(slot - 1) & (WINDOW - 1)`; `node_init`
rejects any other value at compile time.

=== The packet: a value copied at enqueue

#code_file("examples/counter.odin", [
```odin
// An envelope in flight. A message points at a value inside the sender's ledger, so a
// transport copies the value when it queues the envelope, exactly as a codec would.
Packet :: struct {
	envelope: paxos.Envelope(Command),
	value:    Command,
}

packet_of :: proc(envelope: paxos.Envelope(Command)) -> (packet: Packet) {
	packet.envelope = envelope
	if value, carries := paxos.message_value(envelope.message); carries do packet.value = value^
	return
}

packet_envelope :: proc(packet: ^Packet) -> paxos.Envelope(Command) {
	envelope := packet.envelope
	#partial switch &m in envelope.message {
	case paxos.Promise_Message(Command): m.value = &packet.value
	case paxos.Accept_Message(Command):  m.value = &packet.value
	case paxos.Commit_Message(Command):  m.value = &packet.value
	}
	return envelope
}
```
])

This is the one idiom the data-oriented core asks of every host. A
`Promise_Message`, `Accept_Message`, or `Commit_Message` carries its value as a
`^Command` that points into the sending node's ledger, and that pointer is valid
only until the sender's next transition. A real transport serialises the value
into a frame at that moment; this in-process transport does the equivalent by
copying it into the `Packet`. `paxos.message_value` answers whether the message
kind carries a value at all, so the variants without values are copied
unchanged. `packet_envelope` reverses the move before delivery: it repoints the
message at the packet's own copy, which the caller keeps alive for the duration
of `step`. The test harness (`tests/harness.odin`) and the simulator carry the
same two procedures under the same names.

=== The cluster

#code_file("examples/counter.odin", [
```odin
Cluster :: struct {
	nodes:   [MEMBERS]Node,
	network: queue.Queue(Packet),
	counter: i64,
}
```
])

The network is a `core:container/queue` of packets; this host delivers every
message once and in order, and the fault simulator in `sim/` is where drops,
duplicates, and crashes live. `counter` is the application state, one for the
whole cluster, for a reason the output section explains.

=== The host commit sequence

#code_file("examples/counter.odin", [
```odin
// Consumes one node's effects in the order the durability contract requires.
host_commit :: proc(cluster: ^Cluster, node_index: int, effects: ^Effects) {
	// 1. Append effects.writes to a journal and sync it. This example keeps no journal.
	// 2. Tell the batch its writes are durable; only then may messages leave.
	paxos.confirm_writes_durable(effects)
	// 3. Transmit.
	for envelope in paxos.messages_slice(effects) {
		queue.push_back(&cluster.network, packet_of(envelope))
	}
	// 4. Apply newly decided entries, in slot order. One node narrates.
	for entry in paxos.committed_slice(effects) {
		if node_index == 0 {
			cluster.counter += entry.value.amount
			fmt.printfln("slot %d: %+d -> counter = %d", entry.slot, entry.value.amount, cluster.counter)
		}
	}
}
```
])

This is the contract from the bounded-core chapter with step 1 reduced to a comment. The order
is still real: if `messages_slice` came before `confirm_writes_durable` the
program would stop with the durability banner. A real host replaces the comment
with an append and a sync, and `queue.push_back` with a send. Note that step 3
copies each value out of the ledger through `packet_of` before the node moves
on, and that `entry.value` in step 4 is a `^Command` into the same ledger, read
here before the next transition.

=== Settling the network

#code_file("examples/counter.odin", [
```odin
// Delivers every queued envelope until the network is silent.
settle :: proc(cluster: ^Cluster) {
	effects: Effects
	for packet in queue.pop_front_safe(&cluster.network) {
		packet := packet
		envelope := packet_envelope(&packet)
		to := int(envelope.to - 1)
		err := paxos.step(&cluster.nodes[to], envelope, &effects)
		assert(err == .None, paxos.explain_error(err))
		host_commit(cluster, to, &effects)
	}
}
```
])

`settle` pops packets until the queue is empty, rebuilds the envelope over the
packet's own copy of the value, steps the addressee, and commits that node's
batch, which may push more packets. The shadowing `packet := packet` gives the
loop variable an address that outlives the `step` call. One `Effects` value
serves every step: each transition resets it, and each reset succeeds because
`host_commit` confirmed the previous batch.

=== `main`: election, then three proposals

#code_file("examples/counter.odin", [
```odin
	membership: paxos.Membership(MEMBERS)
	ids := [MEMBERS]paxos.Node_Id{1, 2, 3}
	// Keep side effects out of assert: a release build may compile assertions away.
	membership_err := paxos.init(&membership, ids[:])
	assert(membership_err == .None)
	for &node, i in cluster.nodes {
		node_err := paxos.init(&node, ids[i], membership, paxos.Node_Options{priority = u8(i)})
		assert(node_err == .None)
	}

	// Node 1 runs phase one once; every later command commits in one round trip.
	effects: Effects
	noop := Command{}
	campaign_err := paxos.campaign(&cluster.nodes[0], noop, &effects)
	assert(campaign_err == .None)
	host_commit(&cluster, 0, &effects)
	settle(&cluster)
	assert(paxos.role(&cluster.nodes[0]) == .Leader)
	fmt.println("node 1 is the leader")
```
])

`paxos.init` is called with two receivers: the membership (a slice of ids,
majority quorums by default) and each node. Every call that has an effect is
bound to a variable first and asserted afterwards, because `assert` may vanish
from a release build and take its argument with it. The priorities 0, 1, and 2
(a `u8`) only break ties between campaigns in the same round; nothing here calls
`tick`, so no timeout fires and node 1 is the only candidate. Its
`Prepare_Message` goes to all three nodes, itself included; `settle` delivers
the promises back, and once a read quorum of two has described the empty chunk
node 1 is leader.

#code_file("examples/counter.odin", [
```odin
	commands := [?]Command{
		{client_id = 1, request_id = 101, amount = 10},
		{client_id = 1, request_id = 102, amount = 25},
		{client_id = 2, request_id = 201, amount = -5},
	}
	for command in commands {
		slot, err := paxos.propose(&cluster.nodes[0], command, &effects)
		assert(err == .None, paxos.explain_error(err))
		fmt.printfln("proposed request %d in slot %d", command.request_id, slot)
		host_commit(&cluster, 0, &effects)
		settle(&cluster)
	}

	// Every node holds the same decided log.
	for &node in cluster.nodes {
		assert(paxos.decided_through(&node) == len(commands))
		for slot in 1..=paxos.Slot(len(commands)) {
			value, ok := paxos.committed_at(&node, slot)
			assert(ok && value == commands[slot-1])
		}
	}
	fmt.printfln("counter = %d on all %d nodes", cluster.counter, MEMBERS)
	assert(cluster.counter == 30)
```
])

#predict([
  Node 3 never proposes and never narrates. Before reading the output, write
  down what `paxos.decided_through(&cluster.nodes[2])` returns after the loop,
  and which message kind delivered each of its three decisions.
])

=== The output

```text
node 1 is the leader
proposed request 101 in slot 1
slot 1: +10 -> counter = 10
proposed request 102 in slot 2
slot 2: +25 -> counter = 35
proposed request 201 in slot 3
slot 3: -5 -> counter = 30
counter = 30 on all 3 nodes
```

=== Why the counter ends at 30 on all three nodes

The arithmetic is $10 + 25 - 5 = 30$. The claim about three nodes needs the
trace of one proposal. `propose` on node 1 assigns the next slot, records node
1's own vote in its ledger as a `Write_Vote`, counts itself in the slot's
acknowledgement set, and broadcasts `Accept_Message` to nodes 2 and 3. Each
peer records its vote, again as a `Write_Vote`, and replies with
`Accepted_Message`. When the first reply reaches node 1 the acknowledgement set
holds two distinct members, which meets the write quorum of two, so node 1
records a `Write_Chosen`, releases the entry through `committed_slice`, and
broadcasts `Commit_Message` to both peers. Each peer records the decision on
top of its vote and releases the same entry. The second `Accepted_Message`
arrives at a cell whose state is already `.Chosen` and changes nothing.

Only node index 0 adds to `cluster.counter`, so the number printed is node 1's
view. The final loop extends it to the other two: every node reports
`decided_through` of 3, and `committed_at` on every node returns the very
`Command` proposed for that slot. The counter is a fold over the log, and three
equal logs fold to the same 30; the example asserts that rather than assuming it.

The `client_id` and `request_id` fields are carried but never used. Request 101
and request 102 come from the same client, and nothing in this program would
stop a retried 101 from being applied twice.

#exercise([16.1], [
  Extend the counter so a client that retries a request after a timeout can
  never be applied twice. Say what the state machine stores and what the host
  returns to the client.
])

== Middle Example: A Key-Value Host

This section is a design, not repository code. The library orders commands; the
host owns the store, the client protocol, the snapshot, and the journal. The
sketches below use those host types by name without defining them.

=== A bounded request discipline

A write may commit even though its reply is lost, so a client that times out
does not know whether its command was applied. The host resolves that ambiguity
inside the state machine, where it is replicated. Give every client a stable id
and increasing request ids, allow one outstanding request per client, and store
next to the data a table from client id to the last applied request id and its
result:

```odin
Client_Record :: struct {
	request_id: u64,
	result:     Result,
}

State :: struct {
	values:       Bounded_Map(Key, Value_Hash),
	clients:      Bounded_Map(Client_Id, Client_Record),
	applied_slot: paxos.Slot,
}
```

The apply procedure advances through a duplicate's slot even when it suppresses
the duplicate's effect, because the slot was decided whether or not the command
was new:

```odin
apply :: proc(state: ^State, slot: paxos.Slot, command: Command) -> Result {
	assert(slot == state.applied_slot + 1)
	if record, known := state.clients[command.client_id]; known {
		if command.request_id < record.request_id {
			state.applied_slot = slot
			return stale_request_result()
		}
		if command.request_id == record.request_id {
			state.applied_slot = slot
			return record.result
		}
	}
	result := execute(state, command)
	state.clients[command.client_id] = Client_Record{command.request_id, result}
	state.applied_slot = slot
	return result
}
```

`stale_request_result` is a host-defined result for an older request whose answer
is no longer retained. Returning the most recent answer for that older request would
be incorrect. Keeping one answer per client is sufficient only with the stated
one-outstanding-request discipline; hosts needing older answers retain more history.

`values`, `clients`, and `applied_slot` are persisted together and included in
every snapshot; a dedup table that outlives the store would answer a retry with a
result the store never held. The host calls `apply` from step 4 of its commit
sequence with `entry.value^`, copying nothing it does not keep.

=== Timeouts do not mean failure

A client that times out retries the same request id, possibly at a different
node. Three outcomes are possible, and the host handles each without guessing:

- The original committed. The retry is proposed, decided in a later slot, and
  `apply` returns the stored result without touching `values`.
- The original never committed. The retry is proposed and applied once.
- The node is not the leader. `paxos.propose` returns `.Not_Leader` before
  producing any effects; the host answers the client with the hint from
  `paxos.current_leader`, if there is one, and the client tries there.

`.Window_Full` and `.Leader_Catching_Up` are handled the same way as
`.Not_Leader`: they describe a state to wait out, not a failed request.

=== Reads are an application protocol

`paxos.committed_at` and `paxos.read_decided` inspect the local log. They do not
prove that this node is still leader, or that no later slot has been decided
elsewhere, at the moment of the read. The library says so on
`node_is_leader_caught_up`: it "is not a lease and not a read barrier".

A linearizable read on the leader therefore needs a barrier. The plain design is
to propose a read-only command, capture the result from `values` when that command is applied, and return it
only after local application. With replies sent only after
application, the read follows every write that completed before the read began. This
costs one consensus round per read, or per batch of reads that share a barrier.
The cheaper alternative, a leader lease bounded by ticks and heartbeat
acknowledgements, is not implemented in this repository; it is the subject of
the proposal in `docs/pod/records/0004-fast-path-leases.typ`, whose status is
"Open for Discussion". A follower may serve a read without a barrier only when
the service contract calls it stale and the reply carries `applied_slot`, so the
client knows which prefix was read. That index alone does not bound staleness in time.

=== Snapshots and `install_chosen_trim`

The window is finite, and `advance_memory_floor` only lets cells be reused; the
journal and the peers still expect the history to exist somewhere. Periodically
the host writes a state image of `State` through some applied slot $S$, syncs
it, and then tells the node that everything at or below $S$ is chosen and
covered by that image:

```odin
anchor := paxos.Trim_Anchor{
	trim_id          = next_trim_id,
	chosen_trim_slot = image_slot,
}
err := paxos.install_chosen_trim(&node, anchor, &effects)
```

`Trim_Anchor` has exactly those two fields. The core compares anchors by
identity and order only; it never hashes the image. The host therefore binds
the image's checksum to `trim_id` on its own side, in a table from `trim_id` to
the image's checksum and path, written and synced before the anchor is
installed. When a peer's `Promise_Range_Message` later reports an anchor with a
`trim_id` this host does not hold, the host knows it must fetch that image, and
when it does hold the id it can verify the fetched bytes against the checksum
it recorded.

`install_chosen_trim` resets the batch first, then returns `.Invalid_Slot` if
the anchor lies above `decided_through`, `.Trim_Regression` if `trim_id` moves
backward, if the same `trim_id` names a different slot, or if
`chosen_trim_slot` moves backward, and `.None` with no write when the identical
anchor is installed twice. Otherwise it emits a `Write_Trim`, adopts the anchor,
and raises the memory floor to the anchor (capped at `decided_through`). From
then on the node answers `Prepare_Message` with the anchor in its
`Promise_Range_Message`, reports no cell at or below it, and a new leader fences
its recovery above it. A node that has fallen below a peer's anchor cannot catch
up from messages alone: `record_commit` ignores slots at or below its own
anchor, and `on_accept` ignores accepts for them. The host installs the image
and calls `paxos.begin_recovery(&node, anchor)`, which applies the anchor to the
ledger through `ledger_apply`, keeps the node's votes and decisions above it,
returns the node to `.Follower`, and persists nothing on its own; the host must
have the image and the anchor durable before running further transitions.

=== Serving `Serve_Range_Request` from the journal

When a peer's `Learn_Message` asks for slots at or below this node's memory
floor, `on_learn` emits a `Serve_Range_Request{peer, first, count}` and the
host answers from what it kept. The simulator keeps an applied array per node
and does this:

#code_file("sim/simulation.odin", [
```odin
	// Serve evicted history from the host's durable application image.
	for request in paxos.requests_slice(effects) {
		switch r in request {
		case paxos.Serve_Range_Request:
			for offset in 0..<r.count {
				slot := r.first + paxos.Slot(offset)
				if slot >= MAX_SIM_SLOTS do continue
				if value, ok := &sim.applied[node_idx][slot].?; ok {
					commit := paxos.Commit_Message(u64){slot = slot, value = value}
					enqueue(sim, paxos.Envelope(u64){from = node_id, to = r.peer, message = commit})
				}
			}
		}
	}
```
])

A key-value host does the same from its journal of `Write_Chosen` records:
each served slot goes back as a `Commit_Message` whose `value` points at the
host's own copy for as long as the transport needs it, and the peer's `step`
handles it as it would a leader's commit. Slots below the host's own image need
the image.

=== When the host would choose rotating ownership

Everything above assumes one leader, which is the right shape when writes come
from one region: a single phase one, then one round trip per command. A store
whose writers sit in several regions pays a cross-region hop for every write
that did not originate where the leader lives. For that host the library offers
a second shape, selected per node at initialisation:

```odin
err := paxos.init(&node, id, membership, paxos.Node_Options{rotating_ownership = true})
```

Under rotating ownership there is no leader. Member $i$ in membership order
owns every slot $s$ with $(s - 1) mod N = i$ (`owner_of`), and proposes in its
own slots at round zero (`ownership_ballot`) with no phase one at all, because
no lower ballot exists in that decree. `campaign` answers `.Campaign_Disabled`,
and `propose` succeeds on every member, so each region writes locally and pays
one round trip. The price is contiguity: the log advances only as fast as its
slowest owner. An idle owner fills its own slots below the highest slot it has
seen with the no-op (at most `SKIP_BURST` per tick), and a stalled owner is
repaired after `election_timeout_ticks` by a bounded revocation, a phase one
over the stalled chunk that fences the owner out of those slots only and
re-proposes any vote it finds. An owner whose suggestion lost to a revocation
queues a best-effort resubmission; the host still handles retries and deduplication.
The read command must be evaluated at its position in the applied sequence. Reply
to writes only after contiguous application: a value merely chosen in a higher
slot is not yet a completed application operation. Under that contract, the read
follows every write completed before it began. The host picks this option when write
latency across regions is the cost that matters, and keeps the single leader
when a quiet region would otherwise be skipped for every slot it owns.

== Large Example: A Regional Control Plane

This is an architecture and a drill, not runnable code. Assume five voters in
three zones: nodes 1 and 2 in zone A, nodes 3 and 4 in zone B, node 5 in zone C.
The membership is `paxos.Membership(5)` with the default majority quorums, so
any three voters can elect and commit, and the loss of any one zone leaves at
least three.

Placement is expressed through `Node_Options`. If zone A is the preferred home
for the leader, its nodes are initialised with `paxos.Node_Options{priority =
2}`, zone B with `paxos.Node_Options{priority = 1}`, and node 5 with
`paxos.Node_Options{campaign_disabled = true}` so that a lone zone never leads
but still promises and votes. Priority breaks ties between campaigns in the same
round; a campaign in a higher round wins regardless, as the `.Campaign_Disabled`
banner reminds the reader. A longer `election_timeout_ticks` in the less
preferred zones reduces the number of simultaneous campaigns after a leader
fails, at the cost of a slower failover when the preferred zone is the one that
failed.

=== The partition drill

Node 1 leads. The operator isolates zone A from zones B and C; the link between
nodes 1 and 2 stays up.

#transcript((
  [1], [Operator], [Cuts every link between zone A and the rest. Node 1 is still
    `.Leader` in memory; its heartbeats now reach only node 2.],
  [2], [Node 1], [Accepts a client command and proposes it. `send_accept`
    records its own `Write_Vote`; the `Accept_Message` reaches node 2 only, so
    the slot's acknowledgement set holds two members against a write quorum of
    three. Nothing commits. The client sees a timeout, which is not a failure.],
  [3], [Nodes 3, 4, 5], [Count `election_timeout_ticks` ticks without leader
    contact. Node 3 or 4 campaigns (node 5 is `campaign_disabled`);
    `start_campaign` takes a round one above the highest it has observed, so
    its ballot exceeds node 1's, and its `Prepare_Message` names
    `first = decided_through + 1` with `scope = .Global`.],
  [4], [Nodes 3, 4, 5], [Each records a `Write_Promise`, syncs, and only then
    sends its `Promise_Message`s and the closing `Promise_Range_Message`. Three
    answers meet the read quorum. No promiser voted in the slot node 1 was
    filling, so `resolve_chunk` drives nothing and `become_leader` sets
    `next_slot` to that slot: the new leader's first proposal takes it. Node 1's
    value was never chosen.],
  [5], [New leader], [Commits with votes from 3, 4, and 5. Node 1 still
    believes it leads: it accepts proposals that never commit, and once
    `WINDOW_SLOTS` of them are open `propose` returns `.Window_Full`. Zone A
    serves no writes that anyone will ever read back.],
  [6], [Operator], [Heals the links.],
  [7], [Node 1], [Receives a `Heartbeat_Message` with the higher ballot,
    records a `Write_Promise` in `on_heartbeat`, and drops to `.Follower`; or
    its own stale heartbeat draws a `Nack_Message`, and `on_nack` has the same
    result and records `ballot_node(promised)` as the leader hint. Its clients
    now get `.Not_Leader` and the new leader's id from `current_leader`.],
  [8], [Nodes 1, 2], [See a `decided_through` above their own in the heartbeat
    and send `Learn_Message`; the leader answers with `Commit_Message` for each
    slot. Node 2's stale vote is superseded by the decision `record_commit`
    writes on top of it as a `Write_Chosen`. The host may also call
    `paxos.reconnected` on each side to start the repair immediately.],
  [9], [Leader host], [If the outage outlasted the leader's memory floor, the
    `Learn_Message` produces a `Serve_Range_Request` and the host serves from
    its journal. If it outlasted the trim anchor, zone A's hosts fetch the image
    named by the anchor's `trim_id`, verify it against the checksum they
    recorded, install it, and call `begin_recovery` before those nodes vote
    again.],
))

=== Exit criteria

The drill passes on observations, not on the absence of alarms.

#table(
  columns: (1.2fr, 1.4fr, 1.4fr),
  table.header([*Observation*], [*Pass*], [*Fail*]),
  [Writes in the isolated zone], [Every proposal in zone A times out; none is
    later reported as applied.], [A command voted for only by nodes 1 and 2
    appears in the majority side's decided log.],
  [Election on the majority side], [A zone B node becomes `.Leader` with a round
    above node 1's.], [No leader within the timeout, or node 5 leads.],
  [Log agreement after healing], [`decided_through` is equal on all five nodes
    and `committed_at` agrees slot by slot.], [Two nodes report different values
    for one slot, or any node returns `.Conflicting_Commit`.],
  [Step-down], [Node 1 reports `.Follower` and its hint names the new leader.],
    [Node 1 still reports `.Leader` after receiving the new ballot.],
  [Catch-up path], [Every `Serve_Range_Request` was answered from the journal;
    every below-anchor node was rebuilt from the image its `trim_id` names.],
    [A node below the anchor votes before its image is installed.],
  [Durability banner], [Never printed.], [Printed once, by any node.],
)

#exercise([17.1], [
  Write the exit criteria for the regional partition drill: what must be
  observed before the drill counts as passed, and which observation would fail
  it.
])

#teach_back([
  Explain the regional design to an operator in three columns: guaranteed by the
  library, required from the host, and merely a service policy. Place write
  ordering, request deduplication, stale reads, the durability order, snapshot
  transfer, value copying at the transport, and leader placement in the correct
  column.
])
