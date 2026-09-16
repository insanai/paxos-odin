#import "theme.typ": *
#import "figures.typ": *

#part_page("II", [The complete ballot], [
  We run one ballot from the first Prepare to the last Commit. We stop at every
  write, every message and every place the power can fail, and we show that the
  restart never has to guess.
])

= The Single-Decree Protocol

#objectives([
  By the end of this chapter you should be able to run one ballot by hand through the
  library's own handlers, distinguish *accepted*, *chosen*, *committed* and *applied*,
  place every `Write` before the message that depends on it, explain what a Nack does
  to a campaign, and say what a node replays after a crash at any step.
])

#checkpoint([Foundation], [
  State rule B3 from memory. If your sentence contains "majority" or "most recent
  message", go back to Part I before you learn the message names, because the names
  make the wrong rule sound plausible.
])

== The four roles

Paxos is described with four roles. Keep them apart in your head even though this
library runs all four inside one `Node` value.

#book_figure(
  [A client supplies intent. The proposer orders it. The acceptors are the durable
  memory. The learner releases decided entries, in order, to the application.],
  role_map(),
)

The *client* wants a command applied; it is outside the library, and the host calls
`paxos.propose` on its behalf. The *proposer* runs campaigns, picks values under B3,
and drives phase two; its bookkeeping is volatile, and a restarted proposer simply
campaigns again higher. The *acceptor* promises and votes, and never says anything it
has not first written down. The *learner* collects commits and hands the application
a contiguous prefix of decided slots, never a slot with a hole below it.

One `Node(Value, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE)` plays all four. Its
proposer side is the `Role` enum: `.Follower` acts only as acceptor and learner,
`.Preparing` is running phase one, `.Leader` may run phase two. A node built with
`paxos.init_learner` is the exception: its id lies outside the membership, it never
promises or votes, and it answers `.Learner_Message_Forbidden` to anything but Commit.

== Phase one: earn the right to propose

Phase one has two purposes, both from chapter 1. It secures a read quorum's promise
to refuse lower ballots, and it collects that quorum's votes so that B3 can be applied.

#book_figure(
  [Phase one asks the past; phase two writes the future. Each arrow is one variant of
  `Message(Value)`.],
  phase_flow(),
)

=== Prepare

A campaign starts when the host calls `paxos.campaign(&node, noop, &effects)` or when
a follower's election timer expires inside `paxos.tick`. Both paths reach
`start_campaign`:

#code_file("src/election.odin", [
```odin
	greatest := max(node.highest_observed_round, ballot_round(node.ballot))
	greatest = max(greatest, ballot_round(ledger_highest_ballot(&node.ledger)))
	if greatest >= MAX_ROUND do return .Ballot_Exhausted

	node.ballot = ballot_make(greatest + 1, node.priority, node.id)
	node.role = .Preparing
```
])

The new round is one more than the greatest round this node has seen from any source:
its own last ballot, any round a peer has mentioned, and the greatest ballot anywhere
in its own ledger, which `ledger_highest_ballot` takes over the promise, every
per-slot promise and every vote. That is B1 in one expression. The candidate then
promises itself, setting `ledger.promised` to the new ballot and adding a
`Write_Promise` to the batch, and calls `broadcast_all` with a `Prepare_Message`
holding `ballot`, the slot range `first..last` it wants to hear about, and a `scope`
of `.Global`, meaning "promise me every slot from `first` on"; it proposes no value.
The order matters: the promise is in the same batch as the `Prepare`, so it is
durable before any peer hears the ballot, and a candidate that crashes can never
build the same ballot again. The broadcast includes the node itself, so the
candidate's own acceptor answers through the same handler as everyone else's; by then
the promise is already recorded and `on_prepare` writes nothing new.

#api_anchor([`paxos.campaign(node, noop, effects)`], [
  Starts phase one. Returns `.Not_Voter` for a learner and `.Campaign_Disabled` for an
  acceptor-only member. The `noop` value is remembered for filling recovered holes.
], source: [`node_campaign` in `src/election.odin`])

=== Promise

An acceptor compares the Prepare ballot with the greatest ballot it has ever
promised, which lives in `node.ledger.promised`:

#code_file("src/election.odin", [
```odin
	l := &node.ledger
	if msg.ballot < l.promised {
		send_nack(node, from, msg.ballot, l.promised, 0, effects)
	return .None
}
	if msg.first == 0 || msg.last < msg.first do return .Invalid_Slot
	switch msg.scope {
	case .Global:
		if msg.ballot != l.promised {
			l.promised = msg.ballot
			effects_add_write(effects, Write_Promise{msg.ballot})
	}
		observe_leader(node, from, msg.ballot)
```
])

A ballot below the promise is refused with a Nack. A ballot equal to the promise is a
retransmission and needs no new record. A greater ballot becomes the new promise, and
`Write_Promise` enters the effects batch before any reply. (The `.Bounded` scope,
which promises one slot range instead of every slot, belongs to rotating ownership
and waits for a later chapter.) The handler then walks the ledger's `used` bitmap and
reports every vote or decision it holds in the requested range, one `Promise_Message`
per cell:

#code_file("src/election.odin", [
```odin
	cell, used := bit_set_next(l.used, 0)
	for used {
		slot := l.slot[cell]
		if slot > l.anchor.chosen_trim_slot && slot >= msg.first {
			if slot > msg.last {
				more = true
		} else {
				reported += 1
				send_to(node, from, effects, Promise_Message(V){
					ballot = msg.ballot, slot = slot, vote = l.vote_ballot[cell],
					state = l.state[cell], value = &l.value[cell],
				})
		}
	}
		cell, used = bit_set_next(l.used, cell + 1)
}
```
])

The `state` field is the cell's `Cell_State`. A cell this node voted in is reported
as `.Voted` with its `vote` ballot. A cell this node learned through a Commit is
reported as `.Chosen`: it carries a value and no meaningful ballot, and it tells the
candidate "this is decided; do not run phase two for it". After the per-slot messages
comes one `Promise_Range_Message`, which names the slot range answered, the
`reported` count of per-slot promises sent, and the acceptor's own decided prefix.
The candidate counts an acceptor toward the read quorum only when it holds the range
descriptor *and* that many per-slot promises, so reordered runners cannot make a
partial answer look complete.

#callout([Write before speak], [
  `Write_Promise` is added to `effects.writes` before `Promise_Message` is added to
  `effects.messages`, and the host may not read the messages until it has confirmed
  the writes. This is the point where the acceptor's word becomes indelible.
], kind: "warning")

=== Value selection

The candidate's `on_promise` stores each report in the `recovered_ballot`,
`recovered_state` and `recovered_value` columns for the slot's cell and replaces a
vote only when `msg.vote > node.recovered_ballot[cell]`, so each slot keeps the
greatest ballot seen; a report with `state = .Chosen` dominates every vote. Two
reports with equal ballots and different values return `.Conflicting_Value`: that
would mean B1 was broken, and the library stops rather than pick. When
`maybe_resolve_chunk` counts a read quorum of complete answers, `resolve_chunk` walks
the slots and applies B3 to each:

#code_file("src/election.odin", [
```odin
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

A slot the candidate itself already holds as chosen is re-announced. A reported
decision is committed outright. A reported vote is re-proposed under the new ballot.
A slot nobody voted in, below one somebody did, is filled with the host's no-op. For
a fresh single decision none of these fire: `become_leader` runs, the role becomes
`.Leader`, and `next_slot` is 1.

#predict([
  The candidate receives an acceptor's `Promise_Range_Message` with
  `reported = 1` before the matching `Promise_Message` arrives. May it count that
  acceptor toward the read quorum yet? Name the vote it might miss and the rule that
  vote protects.
])

== Phase two: write the future

A client value arrives through `paxos.propose(&node, value, &effects)`, which checks
`node.role == .Leader`, takes `next_slot`, and calls
`send_accept(node, slot, node.ballot, value, effects)`.

=== Accept

#code_file("src/consensus.odin", [
```odin
	l.promised_at[cell] = max(l.promised_at[cell], ballot)
	ledger_record_vote(l, cell, ballot, value)
	effects_add_write(effects, Write_Vote(V){ballot = ballot, slot = slot, value = &l.value[cell]})

	if bit_set_insert(&node.acknowledgements[cell], node.self_index) do node.acknowledged[cell] += 1
	if membership_write_quorum(&node.membership) == 1 {
		record_commit(node, slot, value, effects) or_return
	}
	broadcast_peers(node, effects, Accept_Message(V){ballot = ballot, slot = slot, value = &l.value[cell]})
```
])

The leader is also an acceptor, and it votes for its own proposal without sending
itself a message: `ledger_record_vote` puts the ballot and value into its own ledger,
`Write_Vote` records that vote, and the leader sets its own bit in the cell's
`acknowledgements` and counts it in `acknowledged`. The proposal *is* that vote:
`Accept_Message.value` points into the leader's ledger, and the pointer stays valid
until the node's next transition, which is why a host serialises the batch before
running another. This is the *local acceptance optimisation*. With three members and
a write quorum of two, one remote Accepted completes the quorum. `broadcast_peers`
sends the Accept to everyone except the leader.

#api_anchor([`paxos.propose(node, value, effects)`], [
  Returns the slot the value took, or `.Not_Leader` if phase one has not completed,
  `.Window_Full` if the bounded window has no room, and `.Leader_Catching_Up` if the
  host asked proposals to wait for the inherited prefix.
], source: [`node_propose` in `src/consensus.odin`])

=== Accepted

`on_accept` checks the promise once more, because another candidate may have
campaigned since the leader's phase one; a ballot below the effective promise for the
cell, `l.promised` or the cell's own `promised_at`, whichever is greater, gets
`send_nack` naming the slot. Otherwise the acceptor raises the cell's `promised_at`
to the accepted ballot (a vote implies the promise, even if no Prepare was ever seen),
stores the vote with `ledger_record_vote`, adds `Write_Vote` to the batch, and only
then sends `Accepted_Message` with the ballot, the slot, and `decided_through`, its
own contiguous decided prefix. The leader records that prefix per peer and uses it in
chapter 3 to decide what to retransmit. A duplicate Accept for a vote already held
under the same ballot is answered with Accepted again and no new write. A cell that
is already `.Chosen` never votes again: an Accept for the same value gets Accepted, an
Accept for a different value gets the decision back as a `Commit_Message`. One more
guard applies before any of this: an Accept whose ballot has round zero is accepted
only from the slot's owner under rotating ownership, and otherwise ignored; a later
chapter explains that mode.

=== Commit

The leader's `on_accepted` ignores replies for any slot and ballot but the one it
is driving in that cell (`lead_slot` and `lead_ballot`), adds the sender's bit to
`acknowledgements[cell]`, and returns until `acknowledged[cell]` reaches
`membership_write_quorum`. At that count the value is chosen. `record_commit` marks
the cell `.Chosen` with `ledger_record_chosen`, adds `Write_Chosen`, and calls
`emit_contiguous`, which walks from `delivered_through + 1` upward and appends every
chosen slot it finds to `effects.committed` until it reaches a hole. Then
`broadcast_peers` sends `Commit_Message{slot, value}` to every peer, whose `on_commit`
runs the same `record_commit` and the same `emit_contiguous`. A later Accepted for a
slot already chosen returns early.

#callout([Four words that are not synonyms], [
  *Accepted*: one acceptor holds a durable vote. *Chosen*: a write quorum holds
  durable votes under one ballot; nobody needs to know. *Committed*: a node holds a
  durable `Write_Chosen` for the slot. *Applied*: the host has consumed the entry from
  `committed_slice` and changed its state machine. Safety is about chosen; the rest is
  delivery.
], kind: "idea")

#api_anchor([`paxos.step(node, envelope, effects)`], [
  Processes one message addressed to this node: `.Wrong_Recipient` if `envelope.to`
  is not this node, `.Not_Member` if `envelope.from` is outside the membership,
  otherwise a dispatch on the `Message(Value)` variant.
], source: [`node_step` in `src/consensus.odin`])

== A complete trace

Members 1, 2 and 3; read and write quorums both 2; every priority 0. The host calls
`paxos.campaign(&n1, noop, &effects)`, later `paxos.propose(&n1, tea, &effects)`. The
runner to member 3 is slow. Each row lists writes before messages, the host's order,
and drops the `_Message` suffix from message names. Ballots are written as their
unpacked `(round, priority, node)` triples, and the chunk is the default 64 slots.

#transcript((
  [1], [N1], [`start_campaign`: ballot `(1, 0, 1)`, role `.Preparing`,
    `recover_base = 1`, `recover_last = 64`. No writes. Sends
    `Prepare{(1,0,1), first = 1, last = 64, scope = .Global}` to 1, 2, 3.],
  [2], [N1], [`on_prepare` on its own Prepare: `(1,0,1)` is above `promised`, which
    is `BALLOT_ZERO`. Writes `Write_Promise{(1,0,1)}`. No used cells, so no per-slot
    promise. Sends `Promise_Range{reported = 0}` to 1.],
  [3], [N2], [`on_prepare`: writes `Write_Promise{(1,0,1)}`, `leader_hint = 1`. Sends
    `Promise_Range{reported = 0}` to 1.],
  [4], [N1], [`on_promise_range` from itself: one of two complete. No effects.],
  [5], [N1], [`on_promise_range` from N2: read quorum met. `resolve_chunk` finds no
    votes. `become_leader`: role `.Leader`, `next_slot = 1`. No effects.],
  [6], [N1], [`node_propose(tea)`: slot 1. `send_accept` records its own vote, writes
    `Write_Vote{(1,0,1), 1, tea}` and marks its own acknowledgement
    (`acknowledged = 1` of 2). Sends `Accept{(1,0,1), 1, tea}` to 2 and 3.],
  [7], [Host of N1], [Appends the record, syncs, calls `confirm_writes_durable`, then
    reads `messages_slice` and sends. Reading first would stop the process.],
  [8], [N2], [`on_accept`: `(1,0,1)` is not below `promised`. Writes
    `Write_Vote{(1,0,1), 1, tea}`. Sends `Accepted{(1,0,1), 1, decided_through = 0}`
    to 1.],
  [9], [N1], [`on_accepted` from N2: acknowledgements `{1, 2}`, `acknowledged = 2`,
    write quorum met. *Tea is chosen.* `record_commit` writes `Write_Chosen{1, tea}`;
    `emit_contiguous` releases `Committed{1, tea}`, `delivered_through = 1`. Sends
    `Commit{1, tea}` to 2 and 3.],
  [10], [Host of N1], [Persists the decision (a cheaper barrier is allowed: no promise
    or vote is in this batch), sends the Commits, applies tea.],
  [11], [N2], [`on_commit`: `record_commit` writes `Write_Chosen{1, tea}` and
    releases `Committed{1, tea}`. N2 applies tea.],
  [12], [N3], [The slow Prepare arrives. Writes `Write_Promise{(1,0,1)}`, sends
    `Promise_Range` to 1, which ignores it: N1 is no longer `.Preparing`.],
  [13], [N3], [Accept arrives: writes `Write_Vote`, sends `Accepted`. N1 records the
    third acknowledgement and returns early: slot 1 is already chosen.],
  [14], [N3], [Commit arrives: `Write_Chosen{1, tea}`, `Committed{1, tea}`. All agree.],
))

Look at step 9. Tea was chosen the instant N2's `Write_Vote` in step 8 became
durable, because at that moment two of three acceptors held durable votes under
`(1, 0, 1)`. Step 9 is N1 *learning* that fact. Had N1 crashed between steps 8 and 9,
tea would still be chosen, and any future leader's phase one would meet N2 and be
forced to re-propose it.

#predict([
  Swap steps 12 and 13, so N3 receives Accept before it has ever seen a Prepare.
  Which branch of `on_accept` runs, what does N3 write, and what does `promised` hold
  afterwards?
])

== Rejection and competing campaigns

A ballot below an acceptor's promise is answered with a Nack rather than silence, so
that a stale leader learns it is stale. `Nack_Message` carries the `rejected` ballot,
the `promised` ballot that beat it, the `slot` whose Accept was refused (zero for a
refused Prepare), and the acceptor's `decided_through`. The receiver's `on_nack` is
short because a Nack changes nothing durable:

#code_file("src/consensus.odin", [
```odin
	node.highest_observed_round = max(node.highest_observed_round, ballot_round(msg.promised))
	if msg.rejected != node.ballot || msg.promised <= node.ballot do return
	node.role = .Follower
	node.leader_hint = ballot_node(msg.promised)
```
])

Every Nack raises `highest_observed_round`, so the next `start_campaign` jumps above
the rival instead of colliding with it again. A Nack for some other ballot, or whose
`promised` is not actually greater, changes nothing else. A genuine Nack demotes the
node to `.Follower` and points `leader_hint` at the winner, the node id unpacked from
the promised ballot.

Suppose N2 campaigns at `(2, 0, 2)` while N1 leads at `(1, 0, 1)`. N1's own acceptor
sees the greater ballot, writes `Write_Promise{(2, 0, 2)}`, and `observe_leader`
demotes N1 to `.Follower`. A later `paxos.propose` on N1 returns `.Not_Leader`, and any Accept of
N1's still in flight is nacked by every acceptor that promised `(2, 0, 2)`.

== Liveness and the dueling leaders

Two candidates can chase each other upward forever: N1 prepares round 1, N2 prepares
round 2 and N1's Accepts are nacked, N1 prepares round 3 and N2's are nacked, and so
on. Nothing unsafe happens, and nothing useful either. No safety rule can remove this.

The core reads no clock, so it can be simulated and replayed deterministically. Time
enters only through `paxos.tick(&node, noop, &effects)`, called at a cadence the host
chooses. A follower that reaches `election_timeout_ticks` without leader contact
campaigns; a leader sends `Heartbeat_Message`s every `heartbeat_interval_ticks` and
retransmits every `resend_interval_ticks`. All three are fields of `Node_Options`, and
so are the two tools against duels. `priority` breaks ties inside a round: if N1 and N2
both reach round 5, the greater priority wins and the other steps aside on its Nack;
priority never overrides a greater round, so it cannot affect safety.
`campaign_disabled` removes a member from the contest: it promises and votes like any
acceptor, but `paxos.campaign` returns `.Campaign_Disabled` and its timer never fires,
until the host calls `paxos.set_campaign_enabled`.

#api_anchor([`paxos.tick(node, noop, effects)`], [
  Advances the election, heartbeat and resend timers by one logical tick. Followers
  may campaign; leaders may emit heartbeats and retransmissions. The library does not
  randomise timeouts, read wall-clock time, or hold leases; a host builds those
  outside the core, and none of them may be used as a safety argument.
], source: [`node_tick` in `src/consensus.odin`])

== Crash points and recovery

Every transition returns its writes and messages together in one `Effects`, and the
host must persist the writes before sending the messages. The library does not trust
the host to remember:

#code_file("src/effects.odin", [
```odin
	when G == .Enforced {
		if e.writes_pending do host_order_violation("messages_slice before confirm_writes_durable")
}
	return small_array.slice(&e.messages)
```
])

That is the body of `effects_messages_slice`, where `G` is the node's `GATE`
parameter. With the default gate, reading messages
while a write is unconfirmed calls `host_order_violation`, which prints a diagnostic
and stops the process; so does `effects_reset` on a batch with unconfirmed writes.
The check is compiled out only for a `Node` declared with
`Durability_Gate.Host_Managed`, whose comment lists the four obligations such a host
takes on.

#api_anchor([`paxos.confirm_writes_durable(effects)`], [
  Called after every record in `writes_slice(effects)` is appended and synced. It
  clears `writes_pending`; until then `messages_slice` is fatal. Never call it after a
  failed write.
], source: [`effects_confirm_writes_durable` in `src/effects.odin`])

Not every batch needs the same barrier. `effects_requires_power_loss_barrier` returns
true only when the batch holds a `Write_Promise`, a `Write_Promise_At` or a
`Write_Vote`; decisions (`Write_Chosen`) and trim anchors are derived state a restart
can rebuild, so a host may persist them more cheaply. Step 10 of the trace is such a
batch. One deliberate overlap exists: `effects_pre_durable_messages` returns an
iterator whose `pre_durable_next` yields only the `Accept_Message` envelopes whose
ballot has a round above zero, so a host may put a leader's Accepts on the wire while
its own vote is still syncing. The batch must still be confirmed before
`messages_slice` is read or the next transition runs.

=== Where the power can fail

#table(
  columns: (1.3fr, 1fr, 1.7fr),
  table.header([*Crash between*], [*Journal holds*], [*After restart*]),
  [Prepare received; promise not synced], [old promise],
    [As if the Prepare was never delivered. The candidate retransmits on a tick.],
  [Promise synced; reply not sent], [new promise],
    [The acceptor answers the retransmitted Prepare from the journal and can promise
     nothing lower.],
  [Accept received; vote not synced], [no vote],
    [As if the Accept was never delivered. The leader retransmits.],
  [Vote synced; Accepted not sent], [the vote],
    [The vote counts toward "chosen" now. A later leader's phase one will see it.],
  [Leader's Accepts sent early; its own vote not synced], [no vote],
    [Allowed only at round above zero: the restarted proposer campaigns at a fresh
     ballot, so the old Accept can only be re-proposed through phase one. At round
     zero an owner would reuse the same ballot, so `pre_durable_next` never releases
     such an Accept before the barrier.],
  [Write quorum reached; commit not recorded], [votes on a quorum],
    [The value is chosen. Any later leader is forced by B3 to re-propose it.],
  [Commit synced; entry not applied], [the commit],
    [Restart releases the slot again through `committed_slice`; the host applies
     idempotently or checks its own applied index.],
)

No row says "guess". Every restart sees either the old durable state or the new one,
and both are states the protocol could have been in.

=== What a restart replays

The host feeds every journal record, in journal order, through `ledger_replay_fold`
into an empty `Ledger`:

#code_file("src/ledger.odin", [
```odin
ledger_replay_fold :: proc(l: ^Ledger($Value, $WINDOW), write: Write(Value)) -> Error {
	switch w in write {
	case Write_Promise:
		l.promised = max(l.promised, w.ballot)
		return .None
	// ...
```
])

Replay folds monotonically: a promise record raises `promised` only if greater, a vote
record claims the slot's cell, raises that cell's `promised_at` to its ballot and
installs the vote unless the cell already holds a decision, and decisions and trim
anchors go through `ledger_apply`. The result is the greatest promise and the latest
vote per slot, which is what the acceptor knew at the crash. Then
`paxos.restore(&node, id, membership, ledger)` builds a `Node` around that ledger. It
comes back as a `.Follower` with no leader hint and no election bookkeeping: none of
that was durable and none is needed, because the next Prepare or heartbeat
re-establishes it and the next campaign starts above every round the journal holds.

#api_anchor([`paxos.restore(node, id, membership, ledger, floor, options)`], [
  Rebuilds a voting member from a replayed ledger. `floor` is the slot through
  which the host has durably consumed released entries; cells at or below it that
  hold only an open vote are cleared.
], source: [`node_restore` in `src/node.odin`])

#exercise([8.1], [
  Leaders at ballots (3, 0, 1) and (4, 0, 2) both send Accept for slot 1 with
  different values to the same three acceptors. Trace which acceptor answers Accepted
  and which answers Nack for every arrival order, and state which value can be chosen.
], hint: [Ask first how the leader at (4, 0, 2) finished phase one without seeing a
  vote for (3, 0, 1).])

#checkpoint([Before chapter 3], [
  Name the write that precedes each of Promise, Accepted and Commit. Say at which
  step of the trace tea became chosen and at which step N1 found out. Explain why a
  Nack needs no write. State what `ledger_replay_fold` does with a promise record
  lower than one it has already seen.
])

#teach_back([
  Explain one ballot from the acceptor's point of view. Use only the words "number",
  "promise", "vote" and "ink" until the last sentence. Then map those four words to
  `Ballot`, `Write_Promise`, `Write_Vote` and `confirm_writes_durable`, and say
  which one the host, not the library, is responsible for.
])
