#import "theme.typ": *
#import "figures.typ": *

#part_page("III", [A sequence of decisions], [
  A real database needs more than one decision. We arrange values into an ordered
  sequence of slots, recover an old leader's log, fill gaps, and apply a contiguous stream.
])

= Multi-Paxos Log Replication

#objectives([
  By the end of this chapter you should be able to explain how Multi-Paxos amortizes
  Phase 1 into a single election round, how chunked recovery resolves log gaps under
  packet reordering, why no-op proposals are mandatory to fill holes, and how sliding
  ring buffers bound memory consumption.
])

== Why Multi-Paxos?

Classic Paxos (the Synod protocol) decides exactly one value for one slot. If an
application needs an append-only log to replicate a database, running Classic Paxos
independently for every slot would require:
1. Phase 1 (Prepare / Promise) -> 1 Network Round Trip + 1 Disk Sync.
2. Phase 2 (Accept / Accepted) -> 1 Network Round Trip + 1 Disk Sync.

Every single write would incur at least two network round trips and two disk flushes!

Multi-Paxos introduces an optimization: instead of executing Phase 1 for each slot,
a candidate node executes Phase 1 *once for all uncommitted slots in the log*.
Once the candidate secures a quorum of promises covering the log, it becomes the
*Stable Leader*.

#book_figure(
  [Multi-Paxos runs Phase 1 once to establish leadership across all subsequent slots.
  All normal client writes execute Phase 2 directly in a single network round trip.],
  log_picture(),
)

For all subsequent client requests, the leader bypasses Phase 1 completely and issues
`Accept` messages directly in Phase 2! Throughput increases by an order of magnitude
and latency drops to 1 RTT.

== The Multi-Slot Log and Slot Indexing

In `paxos-odin`, decree numbers are modeled as 64-bit integer slots:

#code_file("src/protocol.odin", [
```odin
Slot :: distinct u64

SLOT_RESERVED: Slot : 0 // Slot 0 represents unassigned/uninitialized state
```
])

Valid consensus slots begin at $1$ and increase monotonically: $1, 2, 3, dots, 2^{64}-1$.

== Chunked Phase 1 Recovery

How can a new candidate query a log that could theoretically span billions of entries?
It cannot transmit the entire log history in one packet.
Phase 1 queries therefore operate in bounded *chunks*:

#code_file("src/protocol.odin", [
```odin
Prepare_Message :: struct {
	ballot: Ballot,
	first:  Slot, // Start of the chunk range
}

Promise_Range_Message :: struct {
	ballot:         Ballot,
	anchor:         Trim_Anchor,
	chosen_through: Slot,
	first:          Slot,
	last:           Slot,
	accepted_count: u32,
	more:           bool,
}
```
])

The candidate transmits `Prepare(ballot, first = recover_base)`. Each acceptor replies with:
1. Individual `Promise` messages for any slots in the range `[first, last]` where it has voted.
2. A `Promise_Range` message that acts as a manifest, stating exactly how many `Promise`
   entries were transmitted (`accepted_count`) and whether unrecovered slots remain (`more = true`).

Because networks can arbitrarily reorder packets, the `Promise_Range` manifest may arrive
*before* the individual `Promise` messages. If the candidate prematurely declared leadership,
it might miss an accepted value, violating Lamport's Max-Vote Rule ($B_3$).

To prevent this hazard, `paxos-odin` counts received entries against `expected_in_range`:

#code_file("src/protocol.odin", [
```odin
// Excerpt from src/protocol.odin: maybe_resolve_chunk
if !peer.range_described do continue
if peer.received_in_range >= peer.expected_in_range {
    // All promised entries for this peer have been received!
}
```
])

== Filling Log Holes with No-Ops

During leader handover, an old leader might have proposed a value in slot 10 and slot 12,
leaving slot 11 completely unallocated before crashing.

When the new leader recovers the log via Phase 1, it discovers:
- Slot 10 has accepted value `"X"`.
- Slot 11 has no votes from any acceptor.
- Slot 12 has accepted value `"Z"`.

Can the leader leave slot 11 empty?
*No!* Replicated state machines require log entries to be applied in strict, contiguous
numerical order: $1, 2, 3, dots$ If slot 11 remained empty, the application would halt
forever at slot 10, unable to apply slot 12.

The new leader solves this by proposing a *No-Op* (blank decree) in Phase 2 for slot 11:
1. Slot 10: re-propose `"X"` in Phase 2.
2. Slot 11: propose `no-op` in Phase 2.
3. Slot 12: re-propose `"Z"` in Phase 2.

Once all three slots reach quorum commitment, the application applies `"X"`, ignores
the no-op at slot 11, and applies `"Z"` at slot 12 without delay.

== Sliding Windows and Memory Recycling

A physical server cannot store billions of log entries in volatile RAM.
`paxos-odin` maps the infinite slot line onto a fixed-size ring buffer:

$ "index" = ("slot" - 1) mod "WINDOW_SLOTS" $

Once the host application has persisted and applied all slots through slot $k$, it calls:
```odin
paxos.node_advance_memory_floor(&node, k)
```
Advancing the memory floor permits `paxos-odin` to reuse ring-buffer cells for future
slots ($k + "WINDOW_SLOTS"$), maintaining a strict, bounded memory footprint of a few
kilobytes indefinitely.

#teach_back([
  Explain why a Multi-Paxos leader can propose values in 1 RTT during normal operation,
  and what steps it must perform during recovery before accepting new client writes.
])
