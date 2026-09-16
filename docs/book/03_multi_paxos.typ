#import "theme.typ": *
#import "figures.typ": *

#part_page("III", [A sequence of decisions], [
  A service needs more than one chosen value. We arrange decisions in slots,
  recover an old leader's unfinished work, fill the holes it left, and release
  one ordered prefix to the application.
])

= Multi-Paxos Log Replication

#objectives([
  By the end of this chapter you should be able to explain why one phase one
  can cover every slot after a starting point, describe how a candidate combines
  chunked phase-one replies per slot even when the network reorders them, say
  what the two fences forbid a new leader from re-proposing, recover a hole with
  the host's no-op, and bound a pipelined leader with the window and the memory
  floor, all in terms of the fields and procedures in `src/election.odin` and
  `src/consensus.odin`.
])

#checkpoint([Foundation], [
  Before reading on, state the single-decree rule from Part II in one sentence:
  a phase-two proposal must carry the value of the highest-ballot vote any
  promise reported, or a fresh value only when no promise reported a vote. Every
  rule in this chapter is that sentence applied to one slot at a time.
])

== Why Multi-Paxos?

The single-decree protocol chooses one value. A replicated log needs a chosen
value in slot 1, then slot 2, then slot 3, without end. The obvious construction
runs an independent single-decree instance per slot. Each instance costs a
`Prepare`/`Promise` round trip with a durable promise on every acceptor, then an
`Accept`/`Accepted` round trip with a durable vote on every acceptor: two round
trips and two synchronous writes for every entry, before the commit is even
announced.

Multi-Paxos observes that phase one does not depend on the value. A candidate
can send one `Prepare` that covers every slot from some starting point onward.
Once a read quorum has promised, the candidate holds a ballot that is valid for
every one of those slots, and each later proposal needs only phase two: one
round trip and one durable vote per acceptor. The candidate that finishes this
phase one is the leader for its ballot until a higher ballot appears.

#book_figure(
  [A log with a contiguous committed prefix (slots 1 to 5), a hole at slot 6, and
  a decided slot 7 that cannot be released until slot 6 is filled. Multi-Paxos
  runs one phase one that covers slots 6 and beyond.],
  log_picture(),
)

== One Phase One for Every Slot After `first`

Slots are 64-bit and one-based. The `Prepare` names the first slot the candidate
wants resolved, the last slot of the chunk it wants reported, and a scope:

#code_file("src/ballot.odin", [
```odin
// One-based position in the global decree log. Zero means "no slot".
Slot :: u64
```
])

#code_file("src/messages.odin", [
```odin
Prepare_Scope :: enum u8 {
	Global,
	Bounded,
}

// Phase one: promise `ballot` for the decrees the scope names and report your votes in
// [first, last].
Prepare_Message :: struct {
	ballot: Ballot,
	first:  Slot,
	last:   Slot,
	scope:  Prepare_Scope,
}
```
])

`campaign(&node, noop, &effects)` starts the election. The candidate picks a
round above every round it has observed, promised, or used, records the host's
`noop` for later, sets `recover_base` to `delivered_through + 1` and
`recover_last` to the end of the first chunk, and broadcasts
`Prepare_Message{ballot, first = recover_base, last = recover_last}` with the
default scope `.Global` to every member, itself included. The candidate answers
its own `Prepare` as an ordinary acceptor when the host steps that envelope back
into it; there is no private shortcut for the local vote. Everything below
`first` is already delivered on this node. Everything at or above it is covered
by this one promise: that is what `.Global` means, and it is the Multi-Paxos
takeover this chapter describes. (`.Bounded` promises only `[first, last]` and
belongs to rotating ownership, a later chapter.) The question is how an acceptor
describes an unbounded suffix in a bounded message.

#predict([
  A candidate wants slots 10 and above. An acceptor voted in slot 10 and in slot
  12 and has nothing in slot 11. The network delivers the acceptor's reply about
  slot 12 first, then a summary of its reply, then the reply about slot 10. When
  is the candidate allowed to count this acceptor toward its read quorum? Write
  down your answer, then read how `Election_Peer` decides.
])

== Combining Phase-One Replies per Slot

=== A chunk and its manifest

An acceptor answers a `Prepare` for one chunk of `CHUNK_SLOTS` slots starting at
`first`. For each used cell in that chunk, it sends one `Promise_Message`
carrying the slot, the cell's `state`, its `vote` ballot and its value. A cell
that holds a decision (the acceptor learned it from a `Commit`, whether or not
it also voted) is reported with `state = .Chosen`, so the candidate learns the
decided value without a separate message kind. After the per-slot promises the
acceptor sends one manifest:

#code_file("src/messages.odin", [
```odin
Promise_Range_Message :: struct {
	ballot:         Ballot,
	anchor:         Trim_Anchor,
	chosen_through: Slot,
	first:          Slot,
	last:           Slot,
	reported:       u32,
	more:           bool,
}
```
])

`reported` says how many `Promise_Message`s the acceptor sent for the
range `first..last`. `more` says whether it holds used cells above `last`, so the
candidate knows another chunk is needed. `chosen_through` and `anchor` are the
acceptor's two fences; we return to them below.

=== Counting a peer as complete

The candidate cannot assume the manifest arrives after the promises it
describes, or before them. It keeps one `Election_Peer` per member:

#code_file("src/node.odin", [
```odin
Election_Peer :: struct {
	anchor:            Trim_Anchor,
	chosen_through:    Slot,
	range_first:       Slot,
	range_last:        Slot,
	expected_in_range: u32,
	received_in_range: u32,
	range_described:   bool,
	more:              bool,
}
```
])

Each `Promise_Message` inside the current chunk increments that peer's
`received_in_range`, but only the first time a given slot is seen from that
peer: a per-peer bit set, `promise_seen`, deduplicates retransmissions. The
report goes into the candidate's `recovered_slot`, `recovered_ballot`,
`recovered_state` and `recovered_value` columns, which keep the highest-ballot
vote per slot, with a `.Chosen` report dominating any vote; two different values
under one ballot for one slot are `.Conflicting_Value`. The manifest sets
`expected_in_range` and marks the peer `range_described`. `maybe_resolve_chunk`
then runs after every promise and every manifest:

#code_file("src/election.odin", [
```odin
	complete := 0
	any_more := false
	for i in 0..<membership_count(&node.membership) {
		peer := &node.election[i]
		if !peer.range_described || peer.received_in_range < peer.expected_in_range do continue
		complete += 1
		if peer.more do any_more = true
	}
	if complete < membership_read_quorum(&node.membership) do return .None
	if node.noop == nil do return .Missing_Noop
```
])

A peer counts only when it is fully described: its manifest arrived and every
promise the manifest announced arrived too. The candidate waits until
`read_quorum_size` peers are complete. That answers the prediction: the
acceptor counts once its manifest and both promises are in, in whatever order
they took. Wire order does not matter, and neither does a duplicate.

=== The next chunk

If any complete peer reported `more`, the candidate resolves this chunk (below)
and calls `begin_next_chunk`: `recover_base` moves to the slot after the chunk
and `recover_last` to the end of the next one, every `Election_Peer` is reset
except its two fences, `promise_seen` is cleared, and a new `Prepare` with the
new `first` and `last` goes out under the same ballot. At most
`CHUNK_SLOTS` promises per peer are ever in flight, however long the unresolved
suffix is. When no complete peer reports `more`, the candidate becomes leader.

== The Fences

Two numbers from the manifests tell the new leader where the past is already
settled. `quorum_fences` folds them over the election state into a `Fences`
value, starting from the candidate's own values:

#code_file("src/election.odin", [
```odin
	fences.trim = node.ledger.anchor.chosen_trim_slot
	fences.chosen = node.delivered_through
	for i in 0..<membership_count(&node.membership) {
		peer := &node.election[i]
		fences.trim = max(fences.trim, peer.anchor.chosen_trim_slot)
		if peer.chosen_through > fences.chosen {
			fences.chosen = peer.chosen_through
			fences.chosen_peer = membership_get(&node.membership, i)
		}
	}
```
])

The trim fence is the greatest `chosen_trim_slot` any promising peer has
adopted: every slot at or below it was chosen and has been released from that
peer's window (the advanced-features chapter covers trim anchors). The chosen
fence is the greatest `chosen_through` any promising peer reported: that peer
has delivered a contiguous decided prefix through it. The leader takes the
larger of the two and never re-proposes, fills, or accepts a client value at or
below it. A missing vote below the fence means the slot was released, not that
it is open.

The chosen fence also tells the leader that it is behind. Leadership means
holding the highest ballot, not knowing every decision. When the chosen fence is
above the leader's own `delivered_through`, `resolve_chunk` sends a
`Learn_Message` to `chosen_peer`, asking for commits from
`delivered_through + 1` for up to `CHUNK_SLOTS` slots. The leader learns those
slots the same way any lagging follower does.

== Holes and the No-Op

Within the chunk, above the fence, the leader must settle every slot up to the
highest one it knows about, from its own cells or from recovered votes. A slot
with no recovered vote is a hole: no acceptor in the read quorum voted there, so
by quorum intersection nothing can have been chosen there, and the leader may
propose anything. (The safety-argument chapter proves this per-slot claim as a
lemma.) It must propose something, because entries are released only in
contiguous order and a permanent hole would block every later slot forever.

The library does not invent a value. The host passes a `noop` to `campaign` and
to `tick`; the node remembers it, and `maybe_resolve_chunk` refuses to resolve
with `.Missing_Noop` if none was recorded. `resolve_chunk` then walks the chunk:

#code_file("src/election.odin", [
```odin
		cell := cell_of(slot, W)
		if chosen, is_chosen := ledger_chosen_at(&node.ledger, slot); is_chosen {
			broadcast_peers(node, effects, Commit_Message(V){slot = slot, value = chosen})
		} else if node.recovered_slot[cell] == slot && node.recovered_state[cell] == .Chosen {
			record_commit(node, slot, node.recovered_value[cell], effects) or_return
			if decided, ok := ledger_chosen_at(&node.ledger, slot); ok {
				broadcast_peers(node, effects, Commit_Message(V){slot = slot, value = decided})
			}
		} else if node.recovered_slot[cell] == slot && node.recovered_state[cell] == .Voted {
			send_accept(node, slot, node.ballot, node.recovered_value[cell], effects) or_return
		} else {
			send_accept(node, slot, node.ballot, node.noop.?, effects) or_return
		}
```
])

Three outcomes per slot, after a slot the leader itself already holds as chosen
is simply re-announced with a `Commit_Message`. A report with `state = .Chosen`
came from a peer's decided cell, so it is recorded and announced as a commit. A
report with `state = .Voted` is re-proposed under the leader's ballot with
`send_accept`: the highest-vote rule applied to that slot. No report at all
means the no-op is proposed. Each `send_accept` records the leader's own vote
durably (a `Write_Vote`) before the `Accept_Message` leaves.

#warning([A no-op is still a real value], [
  It must be comparable, self-contained, and harmless when applied. Its type is
  the host's `Value`; the protocol has no special no-op tag. If the state
  machine cannot apply the no-op, it cannot apply the log.
])

When the window cannot yet hold the whole chunk because the memory floor is too
far behind, `resolve_chunk` proposes as much as fits and reports the chunk
unresolved. The node stays in `.Preparing`, and `tick` retries
`maybe_resolve_chunk` until the host advances the floor or the election times
out.

== A Worked Recovery: Slots 10, 11, and 12

Three voters, ids 1, 2, and 3; both quorums are majorities of two. Node 1 led
under ballot $b_1$ and delivered through slot 9. It proposed `X` in slot 10, and
node 2's `Accepted` gave it a write quorum, so node 1 committed slot 10 and sent
a `Commit`; the `Commit` reached node 2 but not node 3. Node 1 proposed `Z` in
slot 12, and that `Accept` reached node 3 only. Nothing was ever sent for slot
eleven. Then node 1 crashed. Node 3's election timer fires, and the host calls
`campaign(&node3, noop, &effects)`. Its `delivered_through` is 9.

#transcript((
  [1], [Node 3],
  [Chooses a round above $b_1$ and sends `Prepare{first = 10, scope = .Global}`,
  with `last` closing one chunk, to nodes 1, 2, and 3. Node 1 is down and never
  answers.],
  [2], [Node 3],
  [Steps its own `Prepare`. It writes a promise, sends itself
  `Promise{slot 12, vote b_1, state .Voted, Z}` and a manifest with
  `reported = 1`, `chosen_through = 9`, `more = false`.],
  [3], [Node 2],
  [Writes a promise. Its cell 10 holds the decision (it voted, then received the
  `Commit`), so it sends `Promise{slot 10, state .Chosen, X}` and a manifest
  with `reported = 1`, `chosen_through = 10`. The manifest overtakes the promise
  on the wire.],
  [4], [Node 3],
  [Receives node 2's manifest: `expected_in_range = 1`, `received_in_range = 0`.
  Node 2 is described but not complete. `complete` is 1, below the read quorum
  of 2. Nothing else happens.],
  [5], [Node 3],
  [Receives node 2's promise for slot 10. `received_in_range` becomes 1; node
  2 is complete. `complete` is 2. `quorum_fences` returns a chosen fence of 10
  from node 2. `resolve_chunk` starts at slot 11.],
  [6], [Node 3],
  [Slot 11 has no recovered report: `send_accept` proposes `noop` there. Slot
  12 has the recovered vote `(b_1, Z)`: `send_accept` re-proposes `Z` under the
  new ballot. Both votes are written (`Write_Vote`) before the `Accept`s go out.
  Because the chosen fence is above its own `delivered_through`, it sends
  `Learn{from_slot = 10}` to node 2.],
  [7], [Node 3],
  [`become_leader`: `next_slot` and `leader_base` become 13, the slot after the
  highest slot it knows. The role is `.Leader`.],
  [8], [Node 2],
  [Answers the `Learn` with `Commit{10, X}` and the two `Accept`s with
  `Accepted` for slots 11 and 12, each after writing its vote.],
  [9], [Node 3],
  [Records the commit for slot 10 and reaches a write quorum of 2 for slots 11
  and 12. It commits both, broadcasts `Commit`s, and releases `X`, `noop`, `Z`
  in that order. `delivered_through` is 12 and `is_leader_caught_up` is true.],
))

Notice what did not happen. Slot 10 was never re-proposed: the chosen fence put
it out of reach, and the leader learned it instead. Node 2's recovered report
for slot 10 sat unused, because `resolve_chunk` began above the fence. Had node
2 voted for `X` but never received the `Commit`, it would have reported
`chosen_through = 9` and `Promise{slot 10, vote b_1, state .Voted, X}`, and the
leader would have re-proposed `X` in slot 10 under its own ballot, which is the
highest-vote rule at work. The `.Chosen` branch is for a peer that holds the
decision but has not delivered through it, for instance one that received the
`Commit` for slot 10 while slot 9 was still missing. Every path ends the same
way: `X` is the only value slot 10 can ever hold.

== The Stable-Leader Pipeline

After `become_leader`, `propose(&node, value, &effects)` assigns `next_slot`,
advances it, and calls `send_accept`. Nothing waits for the previous slot to
commit: the leader may have many slots in flight, and acceptors vote on each
independently. `propose_batch(&node, values, slots, &effects)` does the same for
up to `CHUNK_SLOTS` values in consecutive slots and one effect batch, returning
the assigned slots in the caller's `slots` buffer; more values give
`.Batch_Too_Large`, none give `.Empty_Batch`.

Pipelining needs a bound, or one slow follower would let the leader's memory
grow without limit. The bound is the window:

#code_file("src/consensus.odin", [
```odin
	if node.next_slot == max(Slot) do return 0, .Global_Slot_Exhausted
	if node.next_slot - node.memory_floor > Slot(W) do return 0, .Window_Full
```
])

`W` is the node's `WINDOW_SLOTS` parameter. `memory_floor` is the greatest slot
the host has told the node it may forget. It rises only when the host calls
`advance_memory_floor(&node, through)` after durably consuming every released
entry through `through`:

#code_file("src/node.odin", [
```odin
node_advance_memory_floor :: proc(node: ^Node($V, $M, $W, $C, $G), through: Slot) -> Error {
	if through > node.delivered_through do return .Invalid_Slot
	node.memory_floor = max(node.memory_floor, through)
	return .None
}
```
])

Asking to advance past `delivered_through` is `.Invalid_Slot`, and the floor
never moves down. `.Window_Full` is flow control, not a log limit: the proposal
is refused, nothing is written or sent, and the same call succeeds once the
floor moves.

Physically, slot `s` lives in the ledger cell `cell_of(s, WINDOW_SLOTS)`:

#code_file("src/ballot.odin", [
```odin
// The window index of a slot. WINDOW is a power of two, so this is one mask.
cell_of :: #force_inline proc(slot: Slot, $WINDOW: int) -> int {
	return int((slot - 1) & Slot(WINDOW - 1))
}
```
])

`node_init` asserts at compile time that `WINDOW_SLOTS` is a power of two, so
the ring index is `(s - 1) & (WINDOW_SLOTS - 1)`, one mask rather than a
division. The cell is tagged with its slot number in the ledger's `slot`
column. `claim_live` decides whether a cell may be taken for a new slot:

#code_file("src/consensus.odin", [
```odin
	if slot <= node.memory_floor do return 0, false
	l := &node.ledger
	cell := cell_of(slot, W)
	held := l.slot[cell]
	if held == slot do return cell, true
	if held == 0 || (held <= node.memory_floor && l.state[cell] == .Chosen) {
		ledger_open(l, cell, slot)
		return cell, true
	}
	return cell, false
```
])

A cell is retagged (`ledger_open` clears everything but the value storage) only
when it is empty or when its old occupant is both at or below the memory floor
and `.Chosen`. A cell holding a `.Voted` but undecided vote is never evicted,
because that vote may be part of a quorum some future leader must discover. The
tag makes a stale cell impossible to mistake for the slot that now maps to it.

#checkpoint([Window arithmetic], [
  With `WINDOW_SLOTS = 8`, the host has advanced the floor to 40 and the leader's
  `next_slot` is 48. Is the next `propose` accepted? Compute
  `next_slot - memory_floor` and compare with the window before answering. Then
  say what `advance_memory_floor(&node, 41)` changes.
])

== Membership Changes: The Stop Sign

A configuration is a fixed voter set with fixed quorum sizes. To change it, the
log carries a stop sign: a special entry that names the next configuration and
its members. The `Replicated_Log_Node` in `src/replicated_log.odin` layers this
on the core `Node`; its entries are an `Entry` union of the host's `Value` and a
`Stop_Sign`. From the moment a stop sign is pending on a node, `log_propose`
refuses commands with `.Log_Sealed`; once the stop is decided in slot $s$, no
slot above $s$ is ever chosen in that configuration, and the next configuration
starts at $s + 1$ on the same slot line. The full treatment, including how a
delayed message from the old configuration is rejected, is in the
advanced-features chapter.

== Global Slots on One Line

A slot number is used once, ever. `Slot :: u64` counts from 1 and never resets:
not on a new leader, not on a trim, and not on a configuration change. What the
window bounds is residency, not history: at most `WINDOW_SLOTS` slots live in
protocol memory at a time, and everything below the memory floor survives only
in the host's journal and materialized state.

Slot arithmetic saturates rather than wrapping. Chunk limits, batch sizes, and
continuation slots go through `slot_add`, which adds
`min(offset, max(Slot) - slot)`, so no calculation can produce slot zero or a
small slot from a large one. The only terminal condition is
`.Global_Slot_Exhausted`, returned by `propose`, `propose_batch`, `campaign`,
and chunk resolution when the next slot would be `max(Slot)`. It is a stop, not
a rollover: restarting the counter in the same log would reuse consensus
instances that acceptors may still hold votes for.

#exercise([11.1], [
  A leader crashes after slot 10's Accept reached one acceptor and slot 12's
  Accept reached a different one; nobody voted in slot 11. Describe what the
  next leader's phase one learns, and what it proposes in slots 10, 11, and 12.
], hint: [
  Ask which acceptors are in the read quorum, what each one's manifest says, and
  which branch of `resolve_chunk` each of the three slots takes.
])

#teach_back([
  Draw three acceptors and one candidate. Send a `Prepare` for slots 10 and up,
  write down each acceptor's `Promise_Message`s and manifest, and deliver them
  in a deliberately bad order. Show when each `Election_Peer` becomes complete,
  when the read quorum is met, where the fence lands, and which branch of
  `resolve_chunk` each slot takes. Finish by explaining why a cell holding an
  undecided vote can never be retagged, even when the window is full.
])
