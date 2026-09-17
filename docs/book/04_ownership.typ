#import "theme.typ": *

= Rotating Slot Ownership

#objectives([
  By the end of this chapter you should be able to say which member owns a
  slot and why the answer needs no election, explain how round zero of the
  ballot space lets an owner skip phase one without weakening B1, trace a skip,
  a revocation, and a resubmission through the code, and state what rotating
  ownership costs on an idle member and on a crashed one. Every mechanism is
  named by its identifier in `src/ownership.odin`, `src/consensus.odin`, or
  `src/election.odin`, and every claim is checked by `tests/test_ownership.odin`
  or the simulator's `--ownership` mode.
])

== One Leader Is a Bottleneck

The Multi-Paxos chapter made a single stable leader the engine of the log: it
runs phase one once, and from then on every proposal is one round trip of
`Accept` and `Accepted`. That is the cheapest a decision can be, but the cost is paid on one
node. Every value a client hands to a follower must first cross the network to
the leader, so a proposal from a non-leader pays a forwarding hop before its
round trip, and the leader's outbound bandwidth, disk, and CPU bound the
throughput of the whole group. In a group spread across sites the forwarding
hop is a wide-area delay on every proposal that did not happen to originate at
the leader.

Mao, Junqueira, and Marzullo's Mencius (OSDI 2008) removes the forwarding hop
by dealing the log out round-robin: every member is the coordinator of its own
instances, suggests values in them without a prepare, skips them when it has
nothing to say, and is revoked when it is suspected. `paxos-odin` implements
the same idea as an option on `Node`, called *rotating slot ownership*. Nothing
in the acceptor's or learner's proof changes; what changes is who may propose
where, and at which ballot.

#api_anchor([`Node_Options.rotating_ownership`], [
  A `bool` in `Node_Options`. `node_init` copies it into `node.ownership` and
  sets `own_next` to the first slot this member owns. Every member of the group
  must be initialised with the same setting: a node without it ignores every
  round-zero `Accept_Message` in `on_accept`, and a node with it refuses
  `campaign` with `.Campaign_Disabled`. `Replicated_Log_Node` passes the option
  through `log_init`, `log_restore`, `log_continue_at`, and `log_init_from_stop`.
], source: [`src/node.odin`])

== The Ownership Rule

The membership is an ordered list: `membership_init` sorts the ids the host
gives it, so every node holds the same list whatever order its host used, and a
member's position in that list is its stable index. Ownership is a function of
that index and the slot number alone:

#code_file("src/ownership.odin", [
```odin
// The member that owns `slot`.
owner_of :: #force_inline proc(node: ^Node($V, $M, $W, $C, $G), slot: Slot) -> Node_Id {
	count := Slot(membership_count(&node.membership))
	return membership_get(&node.membership, int((slot - 1) % count))
}
```
])

Slot $s$ is owned by the member at index $(s - 1) mod N$. With members
`{1, 2, 3}` in that order, member 1 owns slots 1, 4, 7, ..., member 2 owns 2,
5, 8, ..., and member 3 owns 3, 6, 9, .... The first test in
`tests/test_ownership.odin` pins this down: `owner_of(&node, 1)` is 1 and
`owner_of(&node, 5)` is 2. No message ever carries an owner id; every member
computes the same answer from the same membership, which is why the membership
order must be identical on every node. Two hosts that pass the same ids in a
different order to `membership_init` will disagree about who owns slot 2, and
`on_accept` on one of them will silently discard the other's suggestions.

The private helper `own_slot_from(node, from)` returns the first slot at or
after `from` that this node owns; `node_init` seeds `own_next` with
`own_slot_from(node, 1)`, and `node_resume_at` recomputes it from `next_slot`
after a restore so a restarted owner never re-suggests in a slot its ledger
already holds.

#api_anchor([`owner_of`], [
  `owner_of(node, slot) -> Node_Id`. Public and pure: a host that wants to route
  a client to the member that will suggest its value soonest can call it, but
  nothing requires that, because any member can propose at any time in its own
  slots.
], source: [`src/ownership.odin`])

== Partitioning the Ballot Space

Phase one exists to make sure no lower ballot can still choose a different
value in the same decree. An owner can skip it only if, in its own slots, there
is no lower ballot at all. The library arranges exactly that by reserving one
round of the 40-bit round field:

#code_file("src/ballot.odin", [
```odin
//   bits 63..24  round      (40 bits, the campaign counter; round 0 is reserved for
//                            slot owners under rotating ownership)
```
])

`start_campaign` and `start_revocation` both compute `greatest + 1` for a
round, so every campaign ballot has round one or more. The owner's ballot is
round zero with priority zero:

#code_file("src/ownership.odin", [
```odin
// The ballot an owner proposes with: round zero, which no campaign ever uses.
ownership_ballot :: #force_inline proc(owner: Node_Id) -> Ballot {
	return ballot_make(0, 0, owner)
}
```
])

The acceptor closes the partition. Before anything else in `on_accept`, a
round-zero accept is checked against the ownership rule:

#code_file("src/consensus.odin", [
```odin
	// Round zero belongs to the slot's owner alone (B1 per decree under rotating ownership).
	if ballot_round(msg.ballot) == 0 {
		if !node.ownership || ballot_node(msg.ballot) != owner_of(node, msg.slot) do return .None
	}
```
])

So in decree $s$ the only round-zero ballot any acceptor will ever vote at is
`ownership_ballot(owner_of(s))`. Lamport's B1 (§2.2 of _The Part-Time
Parliament_) asks that each ballot in a decree have a unique number, and it is
stated per decree: two decrees may reuse the same number freely. Under
ownership the ballot `(0, 0, 3)` appears in every slot member 3 owns, and in
each of those decrees it is unique and the least ballot anyone can vote at.
B3 then lets the owner pick any value, because the set of votes at lower
ballots is empty by construction. Campaign and revocation ballots at round one
and above are compared exactly as before, so everything the single-decree
chapter proved holds unchanged.

== Proposing Without Phase One

With ownership on, `proposal_gate` returns `.None` for any voting member
regardless of role, and `node_propose` hands the value to `propose_owned`:

#code_file("src/ownership.odin", [
```odin
// Proposes `value` in this node's next usable own slot.
@(private)
propose_owned :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> (slot: Slot, err: Error) {
	for {
		slot = next_usable_own_slot(node) or_return
		err = send_accept(node, slot, ownership_ballot(node.id), value, effects)
		if err != .Not_Leader do break
		// A revoker's promise reached this slot first; the next own slot is ours.
		node.own_next = own_slot_from(node, slot + 1)
	}
	err or_return
	node.own_next = own_slot_from(node, slot + 1)
	node.highest_seen = max(node.highest_seen, slot)
	return slot, .None
}
```
])

`send_accept` is the same phase-two procedure a leader uses, now with the
ballot as a parameter: it claims the cell, records the node's own vote and
`Write_Vote`, registers the slot in `lead_slot` and `lead_ballot` so that
`on_accepted` will count acknowledgements for exactly this ballot, and
broadcasts the `Accept_Message`. A write quorum of one commits on the spot, as
before.

`next_usable_own_slot` decides which slot that is: it asks `own_slot_probe`,
which starts from `own_next` and steps over any own slot that is already
decided or whose per-decree promise is above the owner's ballot, that is, a
slot a revocation has fenced, without changing any state; only then does
`own_next` move:

#code_file("src/ownership.odin", [
```odin
		cell := cell_of(slot, W)
		occupant := l.slot[cell]
		switch {
		case occupant == slot:
			if l.state[cell] != .Chosen && ledger_promise_for(l, cell) <= mine do return slot, .None
		case occupant == 0 || (occupant <= node.memory_floor && l.state[cell] == .Chosen):
			if l.promised <= mine do return slot, .None
		case:
			// The cell still holds an older open slot; wait for the host to release it.
			return 0, .Window_Full
		}
		slot = own_slot_from(node, slot + 1)
```
])

Two errors come out of it. `.Global_Slot_Exhausted` when `own_next` reaches
`max(Slot)`, and `.Window_Full` when the candidate slot lies more than
`WINDOW_SLOTS` above `memory_floor`. The second is the backpressure of a
leaderless log: if some slot below is not decided and the host has not consumed
the prefix, the floor does not move, and every owner eventually gets
`.Window_Full` until a revocation fills the hole. `node_propose_batch` first
runs `own_slots_available`, which probes the `len(values)` own slots the batch
would take, stepping over revoked and decided ones exactly as a proposal would,
without changing anything; only when every one of them fits under the window
edge does it call `propose_owned` once per value. So a batch is admitted whole
or refused whole, and a refused batch leaves no vote behind. A batch of $k$
values spans at least $(k - 1) N + 1$ slots of the log, and the slots in between
belong to the other owners.

#api_anchor([`propose`, `propose_batch`], [
  Unchanged signatures. Under ownership `propose` returns the own slot it
  suggested in, never `.Not_Leader` or `.Leader_Catching_Up`, and the batch form
  fills consecutive own slots.
], source: [`src/consensus.odin`])

== Skips

A log with three owners and one busy member would stall after the busy member's
first slot: slot 2 belongs to member 2, and until it is decided nothing above it
can be released. Mencius solves this with skips. Here a skip is an ordinary
suggestion of the host's no-op, sent by `tick`:

#code_file("src/ownership.odin", [
```odin
// At most this many skips leave per tick, so an idle owner catching up does not flood.
SKIP_BURST :: 8

// Skips: no-ops in this node's own slots below the highest slot anyone has reached, at
// most `budget` (and never more than SKIP_BURST) per tick.
@(private)
skip_idle_slots :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	budget: int,
	effects: ^Effects(V, M, W, C, G),
) -> (sent: int, err: Error) {
	for node.own_next <= node.highest_seen && sent < min(budget, SKIP_BURST) {
		_, propose_err := propose_owned(node, noop, effects)
		if propose_err == .Window_Full do break
		if propose_err != .None do return sent, propose_err
		sent += 1
	}
	return sent, .None
}
```
])

`highest_seen` is the greatest slot this node has any evidence of: its own
suggestions raise it in `propose_owned`, an accept for a slot raises it in
`on_accept` (after the ownership check), and a decision raises it in
`record_commit`. A restore sets it from the ledger in `node_resume_at`. The
rule is simply "if somebody has reached a slot above one of mine, my slot is
holding them up, so fill it." Each tick sends at most `min(CHUNK_SLOTS,
SKIP_BURST)` skips so an owner that wakes up far behind does not flood the
network or its own effects buffer.

Consider the second test, `ownership_idle_owners_skip`. Members `{1, 2, 3}`,
only member 1 has traffic:

+ Member 1 proposes 11. `own_next` is 1, so the suggestion goes to slot 1 at
  ballot `(0, 0, 1)`; `own_next` becomes 4 and `highest_seen` 1.
+ Member 1 proposes 14. Slot 4, `own_next` 7, `highest_seen` 4.
+ Members 2 and 3 process the two accepts. Both are round zero from the right
  owner, both are voted, and both raise `highest_seen` to 4. Slots 1 and 4 are
  decided everywhere, but `delivered_through` stays at 1 because slot 2 is
  empty.
+ On the next tick, member 2 finds `own_next = 2 <= 4` and suggests the no-op
  in slot 2; then `own_next` is 5, above `highest_seen`, and the loop stops.
  Member 3 does the same for slot 3.
+ The skips are decided like any other value, by a write quorum of votes at
  round zero. Once they are, every member releases slots 2, 3, and 4 and
  `decided_through` is 4 on all three.

A skip is not free: it costs the same messages and the same durable votes as a
value. What it buys is that nobody has to guess whether an idle owner is slow
or dead, because a live idle owner fills its slots within a tick.

== Retransmission and Catch-Up Without a Leader

`node_tick` hands the whole tick to `tick_ownership` when ownership is on.
There are no heartbeats, because there is no leader to announce. Instead every
member does what a leader used to do for the slots it drives: every
`resend_interval_ticks` it calls `resend_to` for each peer. `resend_to` resends
a `Commit_Message` for every decided cell above what the peer has reported
decided, and an `Accept_Message` for every voted cell where `lead_slot` names
the slot and the vote's ballot equals `lead_ballot`. That key is what makes
retransmission correct in a log with many proposers: an acceptor that merely
voted for someone else's suggestion has no `lead_ballot` entry for it and does
not resend it, while an owner resends its own suggestions at
`ownership_ballot(node.id)` and a revoker resends its accepts at its campaign
ballot. `on_accepted` uses the same key, so a late acknowledgement for a ballot
the node is no longer driving in that slot is dropped.

Catch-up follows the ownership rule. When the prefix is stalled, every
`heartbeat_interval_ticks` of stall `tick_ownership` sends a `Learn_Message`
to `owner_of(delivered_through + 1)`, the one member that certainly knows what
became of the stuck slot if it is alive. `peer_decided_through`, updated from
every `Accepted_Message`, still lets `resend_to` ask a peer that has decided
further for what it has.

#predict([
  Members `{1, 2, 3}` have decided slots 1, 2, and 4, and member 3, the owner
  of slot 3, has crashed without ever suggesting anything there. Which member
  notices, after how many ticks, and what message does it send first? When it
  finally runs phase one, which slots does its `Prepare_Message` name, and why
  not the whole chunk?
])

== Revocation

A crashed owner leaves a hole that no skip can fill. The library repairs it by
running phase one, but a phase one narrowed in two ways: it covers only the
stalled range, and it promises per decree, so the crashed owner is fenced out
of those slots only and keeps every other slot it owns.

*Stall detection.* `tick_ownership` compares `delivered_through` with
`highest_seen`. Equal or above means nothing is outstanding and `stall_ticks`
resets to zero. Otherwise `stall_ticks` increments, and when it reaches
`election_timeout_ticks` (the same option a follower uses to suspect a leader)
the node calls `start_revocation`. This answers the first half of the
prediction: both survivors notice, on the tick where `stall_ticks` reaches the
timeout, and before that each has sent a `Learn_Message` to member 3 every
`heartbeat_interval_ticks`.

*Bounded prepare.* `start_revocation` picks a fresh round above everything it
has seen, exactly as `start_campaign` does, bounds the range, promises itself,
and only then enters `.Preparing`, remembers the no-op, and clears the election
state:

#code_file("src/ownership.odin", [
```odin
	base := node.delivered_through + 1
	chunk_end := slot_add(base, Slot(C - 1))
	last := min(chunk_end, max(node.highest_seen, base), node.memory_floor + Slot(W))
	prepare := Prepare_Message{
		ballot = ballot_make(greatest + 1, node.priority, node.id),
		first = base, last = last, scope = .Bounded,
	}
	// The revoker promises itself first, so its ballot is durable before the Prepare
	// leaves and a restart campaigns above it (the same rule as start_campaign). If a
	// cell of the range is still held by an older open slot, nothing has changed yet:
	// the node stays a follower and tries again after the next timeout.
	if !promise_bounded(node, prepare, effects) {
		node.stall_ticks = 0
		return .None
	}
	node.ballot = prepare.ballot
	node.role = .Preparing
```
])

The revoker answers its own prepare before sending it: `promise_bounded` records
a `Write_Promise_At` for every slot of the range in the same batch as the
`Prepare`, so the revocation ballot is durable before any peer hears of it. That
is what lets a restarted revoker always pick a higher round, and the
safety-argument chapter's pre-durable lemma rests on it.

The range is $[#[`delivered_through + 1`], min(#[`chunk end`], #[`highest_seen`], #[`memory_floor + W`])]$,
clamped to the live window so the revoker can always promise every slot of it.
There is no reason to fence any slot above `highest_seen`: nobody has reached
it, its owner has not been slow about it, and revoking it would only steal a
slot from a live member. That is the second half of the prediction.
`Prepare_Message.scope` is `.Bounded`; a campaign's prepare leaves it at the
zero value `.Global`.

*Per-decree promises.* `on_prepare` dispatches on the scope. A global prepare
raises the ledger's single `promised` ballot and writes `Write_Promise`. A
bounded prepare goes through `promise_bounded`, which promises each decree in
the range separately in `promised_at[cell]` and writes one `Write_Promise_At`
per slot. The effective promise for a cell is `ledger_promise_for`, the larger
of the two, and both `on_accept` and `next_usable_own_slot` consult it. The
procedure fails closed:

#code_file("src/election.odin", [
```odin
	if msg.last - msg.first >= Slot(C) do return false
	for slot := msg.first; slot <= msg.last; slot += 1 {
		if slot <= node.memory_floor do continue
		cell, ok := claim_live(node, slot)
		if !ok || msg.ballot < l.promised_at[cell] do return false
	}
```
])

If the range is wider than one chunk, if a slot in it has no cell to carry its
promise, or if any slot is already promised to a higher ballot, the acceptor
sends nothing at all, not even a partial answer. A candidate can then never
count a promise that was not recorded, and it simply times out and tries again
at a higher round. A bounded prepare does not call `observe_leader`: the
revoker is nobody's leader, and it must not reset anyone's timers. Any
round-zero accept that arrives after the promise is refused with a
`Nack_Message` whose `slot` names the fenced decree.

*Resolution and B3.* Promises flow back through the same `on_promise` and
`on_promise_range` handlers a campaign uses. When a read quorum has described
the range, `resolve_chunk` drives it. Under ownership `drive_all` is true, so
every slot in the range is decided: a known decision is rebroadcast, a
recovered vote is re-proposed at the revocation ballot (B3: the crashed owner's
value survives if any quorum member voted for it), and an empty decree gets the
no-op. Driving every promised slot matters here more than in a campaign,
because a promised slot that was left undecided would fence its owner out of
it forever. If an acceptor reported used cells above the range, `begin_next_chunk`
continues with another bounded prepare, again capped at `highest_seen`.

*No standing leader.* When the range is driven, `become_leader` takes the
ownership branch: role back to `.Follower`, `stall_ticks` to zero,
`emit_contiguous` to release whatever became contiguous. There is no term, no
`leader_base`, and nothing for `is_leader_caught_up` to say. Should a revoker
stall again, `tick_ownership` starts a fresh revocation at a higher round after
`election_timeout_ticks` in `.Preparing`.

Here is the third test, `ownership_revokes_a_crashed_owner`, with
`Node(u64, 3, 16, 4)`, default timers, member 3 silent, and member 1 reaching
the timeout first:

#transcript((
  [1], [M1, M2], [`propose`: 11 in slot 1 by member 1, 12 in slot 2 by member 2,
    14 in slot 4 by member 1, all at round zero. Every accept to member 3 is
    lost. Slots 1, 2, and 4 are decided by the votes of members 1 and 2;
    `delivered_through` is 2 and `highest_seen` is 4 on both.],
  [2], [M1, M2], [`tick_ownership`: no resubmits, no skips (`own_next` is 7 and 5,
    both above 4). `delivered_through < highest_seen`, so `stall_ticks` becomes
    1. At 3, 6, and 9 each sends `Learn_Message{from_slot = 3}` to
    `owner_of(3) = 3`, which is lost.],
  [3], [M1], [`stall_ticks` reaches `election_timeout_ticks = 10`.
    `start_revocation`: ballot `(1, 0, 1)`, role `.Preparing`, `recover_base = 3`,
    chunk end 6, `recover_last = min(6, 4) = 4`. Sends
    `Prepare{(1,0,1), first = 3, last = 4, scope = .Bounded}` to 1, 2, and 3.],
  [4], [M1], [`on_prepare` on its own prepare: `promise_bounded` claims a cell for
    slot 3 and finds slot 4's cell. Writes `Write_Promise_At (1,0,1)` for 3 and
    for 4. Reports slot 4 as `.Chosen` with 14, then
    `Promise_Range{reported = 1, more = false, chosen_through = 2}`.],
  [5], [M2], [`on_prepare`: the same two `Write_Promise_At` records, the same
    report for slot 4, the same manifest. Its `highest_observed_round` becomes 1;
    its `leader_hint` and `election_ticks` are untouched.],
  [6], [M1], [`maybe_resolve_chunk`: two complete descriptions reach the read
    quorum. `resolve_chunk`: the chosen fence is 2, so the drive starts at 3.
    Slot 3 has no recovered vote: `send_accept(3, (1,0,1), noop)`, writes
    `Write_Vote`, sends `Accept` to 2 and 3. Slot 4 is chosen locally: rebroadcasts
    `Commit{4, 14}`. `become_leader`: role `.Follower`, `stall_ticks = 0`.],
  [7], [M2], [`on_accept` for slot 3 at round one: the owner rule does not apply,
    `(1,0,1)` is not below `promised_at`, so it votes, writes `Write_Vote`,
    calls `observe_leader` (hint 1), and sends `Accepted{(1,0,1), 3}`.],
  [8], [M1], [`on_accepted`: `lead_slot[cell] == 3` and `lead_ballot[cell] == (1,0,1)`;
    two acknowledgements reach the write quorum. `record_commit(3, 0)` writes
    `Write_Chosen` and `emit_contiguous` releases slots 3 and 4. Broadcasts
    `Commit{3, 0}`.],
  [9], [M2], [`on_commit`: records slot 3, releases 3 and 4. On both survivors
    `decided_through` is now 4, `stall_ticks` is 0, and `role` is `.Follower`,
    which is what the test asserts.],
))

If member 2 reaches the timeout in the same round, it starts its own revocation
at `(1, 0, 2)`, which is the higher ballot. Member 1 gets no answer to its
prepare from member 2 (`promise_bounded` fails closed against the higher
per-decree promise), member 2 resolves the range instead, and member 1 drops
back to `.Follower` when it votes for member 2's round-one accept in
`observe_leader`. Either way slot 3 takes the no-op and neither survivor keeps
a role.

The fourth test, `ownership_revocation_keeps_a_seen_vote`, is the B3 case: member
3 suggests 33 in slot 3 and only member 2 hears it before member 3 falls
silent. Member 2's `Promise_Message` for slot 3 reports a `.Voted` cell at
`(0, 0, 3)` with 33, `resolve_chunk` re-proposes 33 at the revocation ballot,
and slot 3 decides 33, not the no-op.

== Resubmission

A revocation can decide the no-op in a slot whose owner had suggested a real
value that nobody heard. The value was accepted from a client and must not
vanish. Two places notice the case. `on_accept`, when the revoker's accept is
about to overwrite the owner's own vote, and `record_commit`, when the decision
arrives without the accept having been seen:

#code_file("src/consensus.odin", [
```odin
	// An owner whose suggestion lost to a revocation proposes it again later.
	if node.ownership && l.state[cell] == .Voted &&
	   l.vote_ballot[cell] == ownership_ballot(node.id) && l.value[cell] != value {
		queue_resubmit(node, l.value[cell])
	}
```
])

The conditions read: this node's own vote in the slot is at
its ownership ballot, and the decision that just arrived carries a different
value. The lost value goes into `resubmit`, a `small_array` of `CHUNK_SLOTS`
values, and the next `tick_ownership` calls `drain_resubmits`, which
`propose_owned`s each queued value in order into the next usable own slot,
stopping (without losing anything) on `.Window_Full`. The fifth test,
`ownership_revoked_suggestion_is_resubmitted`, silences member 3 after its
suggestion of 33 for slot 3 reaches nobody, lets members 1 and 2 revoke slot 3
to the no-op, then reconnects member 3. The retransmitted `Commit{3, 0}` fires
the hook, and 33 is decided in a later slot owned by member 3.

What a host may rely on is narrower than "never lost." The queue holds one
chunk of values; `queue_resubmit` counts a value beyond that in
`resubmits_dropped` (read it with `paxos.resubmits_dropped`) and leaves it to
the host's ordinary timeout-and-retry discipline, the same one it needs anyway
for a suggestion whose owner crashes with a non-durable vote. Resubmission is a
liveness courtesy that covers the common case, not a delivery guarantee, and a
resubmitted value is decided in a different slot from the one it was first
suggested in, later in the log.

== Why Round-Zero Accepts Wait for the Barrier

The bounded-core chapter introduced `pre_durable_messages`: an `Accept_Message`
at a campaign ballot may leave before the sender's own writes are durable,
because it asks peers to persist their votes and claims nothing about the
sender, and a restarted proposer always campaigns at a fresh ballot. An owner's
suggestion is different:

#code_file("src/effects.odin", [
```odin
// ... An owner's round-zero suggestion is the
// exception: its own vote is the only durable record that the instance was used, so it
// must wait for the barrier or a restart could reuse the ballot for another value.
```
])

`pre_durable_next` therefore yields only accepts with `ballot_round > 0`. The
failure it prevents is concrete. An owner suggests `a` in slot 5 at `(0, 0, 2)`,
the accept leaves, and the owner crashes before `Write_Vote` reaches disk. It
restarts, `node_resume_at` finds slot 5 empty, `own_next` is 5 again, and the
next proposal `b` goes out in slot 5 at the very same ballot `(0, 0, 2)`. Two
values under one ballot in one decree is the violation of B1 that everything
else rests on, and it is exactly what the simulator's vote-level oracle
reports: `persist_sim_write` keeps every durable vote per member and slot and
fails the run with "ballot accepted two values in slot" the moment two members
hold different values under the same ballot. That oracle is the reason round
zero is excluded from the pre-durable path.

#warning([Round-zero accepts are not pre-durable], [
  A host that sends accepts early through `pre_durable_messages` must send an
  owner's suggestions only after `confirm_writes_durable`. The iterator
  enforces this by never yielding a round-zero accept; a host that bypasses the
  iterator and drains `messages_slice` before the barrier under the
  `.Host_Managed` gate takes on the ballot-reuse hazard itself.
])

== What Ownership Does Not Do

- *No leases and no read path.* Ownership is about who may propose. It says
  nothing about who may answer a read from local state; that still needs a
  quorum round trip or a barrier through the log, and leader leases remain a
  proposal (POD 0004). `current_leader` under ownership reports only the sender
  of the last commit or revocation accept this node processed.
- *No separate ownership order.* Membership order is ownership order. Changing
  the order changes every owner, so it changes only with the membership, at a
  stop sign, where the new configuration recomputes `owner_of` from its own
  member list and `Log_Envelope` keeps the old configuration's suggestions out.
  One rule makes that safe: an owner that has not yet heard of the stop sign
  can still get a suggestion decided above it, so `Replicated_Log_Node`
  abandons every decision above a decided stop sign. It is never released and
  never readable, and the next configuration decides that slot again with its
  own quorums. The client whose command was abandoned sees a timeout and
  retries, as after any other loss.
- *No unbounded buffering.* A full-window stall applies backpressure. If a
  revocation cannot complete (say, no read quorum), owners receive
  `.Window_Full` from `propose` once their next own slot is `WINDOW_SLOTS`
  above the floor, and the host waits, exactly as it would behind a leader with
  a full window.
- *No campaigns.* `campaign` returns `.Campaign_Disabled`. The only phase one
  that runs is a revocation, started by a tick.

== Evidence

`tests/test_ownership.odin` runs five scenarios on `Node(u64, 3, 16, 4)`, with
an in-process queue and a `silent` member whose traffic is dropped:

- `ownership_three_owners_propose_concurrently`: four proposals from three
  owners decide in slots 1 through 4 without a campaign; `campaign` is refused.
- `ownership_idle_owners_skip`: slots 2 and 3 decide the no-op.
- `ownership_revokes_a_crashed_owner`: slot 3 is revoked to the no-op and both
  survivors end as `.Follower`.
- `ownership_revocation_keeps_a_seen_vote`: the revoker re-proposes 33 (B3).
- `ownership_revoked_suggestion_is_resubmitted`: 33 is decided in a later own
  slot once its owner returns.

The simulator (`sim/main.odin`) takes `--ownership`, which initialises every
node with `rotating_ownership = true`, skips the bootstrap campaign, and lets
`propose_random` pick any live node as the proposer. Every oracle from the
single-leader runs applies unchanged: agreement and validity in
`record_decision`, the durable-vote quorum and one-value-per-ballot checks in
`persist_sim_write`, promise regression for the global promise, contiguity of
released entries, convergence of every node onto the golden log, and the
liveness probe after healing, which in ownership mode is proposed by whichever
node the loop reaches first. Crashes still land at any of the three points of
the host commit sequence, and a restarted node comes back through `restore`
with the same option, which is how `node_resume_at`'s recomputation of
`own_next` and `highest_seen` is exercised.

== Single Leader or Rotating Ownership?

#table(
  columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  table.header([*Property*], [*Single stable leader*], [*Rotating ownership*]),
  [Round trips per proposal], [One accept round trip at the leader; a proposal
    that originates elsewhere first crosses to the leader.], [One accept round
    trip at the owner; no forwarding.],
  [Messages per decision, $N$ members], [$N - 1$ accepts, up to $N - 1$
    acknowledgements, $N - 1$ commits, plus periodic heartbeats.], [The same
    per slot, no heartbeats; but every idle owner's skip is one more decision.],
  [An idle member], [Costs nothing.], [Fills its own slots below `highest_seen`
    with the no-op, at most `SKIP_BURST` per tick.],
  [A crashed member], [A crashed follower costs nothing while a quorum remains;
    a crashed leader costs an election after `election_timeout_ticks` with a
    global prepare.], [Its slots below `highest_seen` stall the prefix for
    `election_timeout_ticks`, then a bounded revocation decides them; it keeps
    every slot above.],
  [Campaign availability], [`campaign` unless `campaign_disabled`.],
    [`.Campaign_Disabled`, always.],
  [Standing role after repair], [A leader with a term base.], [None; the
    revoker returns to `.Follower`.],
)

Choose ownership when proposals originate at many members and forwarding
latency dominates, and when members are rarely idle or rarely crash for long.
Choose a single leader when most traffic already arrives at one place, or when
an idle member must cost nothing.

#exercise([15.1], [
  Three owners `{1, 2, 3}`. Member 2 crashes after proposing $v$ in slot 5 with
  its accept delivered to member 3 only. Trace the revocation by member 1 and
  say which value slot 5 takes, and why member 2 will or will not resubmit.
], hint: [
  Start with `owner_of(5)` and with what member 1's `highest_seen` must be for
  it to stall on slot 5 at all. Then ask what member 3's `Promise_Message` for
  slot 5 reports, what `resolve_chunk` does with a recovered `.Voted` cell, and
  which of the four conditions in `record_commit`'s resubmit hook fails when
  member 2 finally processes the commit for slot 5.
])

#teach_back([
  Explain to a colleague why an owner may skip phase one and a candidate may
  not, using only B1 and B3 and the words "round zero." Then explain, with
  `highest_seen` on the whiteboard, what an idle owner does on each tick, what a
  stalled member does on each tick, and the one slot bound that keeps a
  revocation from stealing slots nobody has reached. Finish with the four
  conditions under which a decision triggers a resubmission and the one reason
  a round-zero accept may not leave before the barrier.
])
