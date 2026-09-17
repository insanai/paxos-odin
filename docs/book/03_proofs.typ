#import "theme.typ": *
#import "figures.typ": proof_dependency_picture

= The Safety Argument

#objectives([
  After completing this chapter, you will be able to:
  - Formulate the asynchronous consensus model as five formal system axioms.
  - Define "chosen" rigorously in terms of acceptor state and write quorums.
  - Reproduce the inductive proof of the Synod agreement theorem from ballot invariants B1, B2, and B3.
  - Trace how real-world engine adaptations (chunked recovery, sliding memory windows, rotating ownership, durability ordering, and reconfiguration stop signs) preserve mathematical safety.
  - Map each formal safety lemma directly to the Odin procedure that discharges its premises.
])

Parts I to III told the story: an empty ledger, a quorum, a ballot, three rules, and a
log of decrees. This chapter is the argument in its compact form. It states the model
as axioms, defines the words the theorem uses, proves the Synod theorem for one decree
in the style of Lamport's Theorem 1, extends it to the multi-decree log, and then walks
through every place where `paxos-odin` does something Lamport's parliament did not.
Every lemma names the procedure in `src/` that discharges its premise, and the closing
table maps each obligation of the package documentation in `src/paxos.odin` to its
lemma, its procedures, and the test or simulator oracle that exercises it. Where the
code guarantees less than a sentence in the package documentation suggests, the lemma
says exactly what is guaranteed and what the host must add.

#book_figure(
  [Read the proof as a chain of obligations. Intersection supplies a witness;
  persistence and promises preserve its evidence; recovery carries that evidence
  forward. The diagram is a map of the argument, not a substitute for its premises.],
  proof_dependency_picture(),
)

== Axioms of the model

- *A1 (Processes).* A configuration has a fixed, finite set of members. A process
  runs the library's transitions one at a time and may crash at any instant. A crashed
  process may restart, and when it does it holds exactly the records it persisted
  before the crash and nothing else: every field of `Node` outside the `Ledger` is
  volatile and is reset or rebuilt by `node_restore`, using the ledger and the
  host's durable consumed floor and configuration.
- *A2 (Channels).* Envelopes may be lost, duplicated, reordered and delayed without
  bound, but never forged or corrupted. Every envelope a node processes was sent by
  `envelope.from` with the contents it carries; the host authenticates the transport,
  and `node_step` refuses an envelope whose `from` is outside the membership with
  `.Not_Member` and one not addressed to the node with `.Wrong_Recipient`.
- *A3 (Quorums).* A read quorum $Q_1$ is any set of `read_quorum_size` members and a
  write quorum $Q_2$ any set of `write_quorum_size` members, and
  `read_quorum_size + write_quorum_size > count`. `membership_init` refuses any other
  pair with `.Non_Intersecting_Quorums`, and `replicated_log_init_from_stop` builds the
  next configuration's membership through the same procedure.
- *A4 (Durability).* The host appends every `Write` of a transition to stable storage
  in the order given, syncs, and only then calls `confirm_writes_durable`; no message of
  that transition leaves before then, with the single exception of Lemma 10, and no
  later transition runs before then (`effects_reset` stops the process otherwise). A
  confirmed record survives every crash. On restart the host folds its journal in order
  through `ledger_replay_fold` (or `ledger_apply`) and calls `node_restore` with the
  slot through which it has durably consumed the log; that consumed floor is itself
  durable and never decreases. A `Committed` entry is applied only after the batch that
  released it is confirmed.
- *A5 (No Byzantine behaviour).* Every process runs the library's code on its own
  ledger, never confirms a write that failed, never edits a ledger by hand, and reports
  its state truthfully in every message.

== Definitions

#definition([D1: Ballot], [
  A ballot is one integer, `Ballot :: distinct u64`, built by `ballot_make(round,
  priority, node)` as `round << 24 | priority << 16 | node`. The three fields occupy
  disjoint bit ranges (40, 8 and 16 bits), so distinct triples give distinct integers
  and integer order is the lexicographic order on $("round", "priority", "node")$. The
  *proposer* of $b$ is `ballot_node(b)`; a *campaign ballot* has `ballot_round(b) >= 1`;
  the *round-zero ballot* of a member $n$ is `ownership_ballot(n)`, that is
  `ballot_make(0, 0, n)`. $b' > b$ means integer comparison.
])

#definition([D2: Vote], [
  Acceptor $a$ *votes* $(b, v)$ in decree $s$ when it records `Write_Vote{ballot = b,
  slot = s, value = v}`; afterwards the ledger cell for $s$ has `vote_ballot = b`,
  `value = v` and state `.Voted` (or `.Chosen`, which keeps the vote). "$a$ voted
  $(b, v)$ in $s$" means such a record was confirmed durable at some time.
])

#definition([D3: Promise], [
  The ledger holds a global promise `promised` (Lamport's $"maxBal"$, written by
  `Write_Promise`) and a per-decree promise `promised_at[c]` (written by
  `Write_Promise_At`, or implied by a vote). The *effective promise* of $a$ for decree
  $s$ is $p_a (s) = max("promised"_a, "promised_at"_a [s])$, which is exactly
  `ledger_promise_for`.
])

#definition([D4: Chosen], [
  Value $v$ is *chosen* in decree $s$ at ballot $b$ when some write quorum $Q_2$ exists
  such that every $a in Q_2$ voted $(b, v)$ in $s$. Nobody has to know. $v$ is chosen in
  $s$ when it is chosen at some ballot.
])

#definition([D5: Decided], [
  A node has *decided* (or *committed*) $s$ when `record_commit` has recorded
  `Write_Chosen{slot = s, value = v}`; the cell is in state `.Chosen` and
  `ledger_chosen_at` returns $v$.
])

#definition([D6: Applied], [
  The host has *applied* $s$ once it consumed the `Committed` entry for $s$ from
  `committed_slice`. `delivered_through` is the greatest slot released so far, and the
  host reports what it has durably consumed through `advance_memory_floor`.
])

The words are ordered by strength: applied implies decided on that node, decided implies
chosen (Corollary 1), and chosen is the property the theorem is about. Chosen is a fact
about durable votes and nothing else; no message, timer or leader is mentioned in D4.

== The Synod theorem for one decree

Fix one decree $s$ throughout this section.

*Lemma 1 (quorum intersection).* Every read quorum meets every write quorum:
$Q_1 inter Q_2 != emptyset$.

*Proof.* $|Q_1 inter Q_2| >= |Q_1| + |Q_2| - N$, and A3 gives $|Q_1| + |Q_2| > N$. The
inequality is `read + write <= total` in `membership_init`, refused with
`.Non_Intersecting_Quorums`. $qed$

*Lemma 2 (a vote respects the promise).* If $a$ votes $(b, v)$ in $s$ then
$b >= p_a (s)$ at the moment of the vote, and $p_a (s) >= b$ ever after. $p_a (s)$ never
decreases.

*Proof.* Every vote is recorded by one of two procedures. `on_accept` replies
`send_nack` and records nothing when `msg.ballot < l.promised` or
`msg.ballot < l.promised_at[cell]`; when it does record, it first sets
`l.promised_at[cell] = msg.ballot`. `send_accept`, the proposer's own vote, returns
without voting when `ballot < ledger_promise_for(l, cell)` and otherwise raises
`promised_at` to the ballot. Promises only grow: `on_prepare` and `on_heartbeat` nack
a ballot below `promised` and assign only a ballot at or above it; `promise_bounded`
refuses the whole range if any `promised_at` exceeds the ballot; `ledger_apply`
returns `.Promise_Regression` for a lower promise or a vote below a promise, and
`ledger_replay_fold` folds with `max`. Across a restart the ledger is the replayed
journal, so the same fields carry the same values (Lemma 9). $qed$

*Lemma 3 (one value per ballot).* For each ballot $b$ at most one value is ever
carried by an `Accept_Message` for $(b, s)$, and every vote at $b$ in $s$ is for that
value.

*Proof.* The proposer of $b$ is `ballot_node(b)`, and a node builds ballots carrying
only its own id (`start_campaign`, `start_revocation`, `ownership_ballot`). For a
campaign ballot, the round is `greatest + 1` where `greatest` covers the node's own
`ballot`, every round it observed, and `ledger_highest_ballot` (the global promise,
every per-decree promise and every vote in the ledger); so each campaign of a node uses
a round it never used before (a restart is Lemma 10). Within one campaign, a value
enters $s$ only through `send_accept`, which refuses to re-vote at the same ballot for a
different value in a cell it is driving (`.Conflicting_Value`), and fresh proposals take
`next_slot`, which `become_leader` sets above every used slot. For the round-zero
ballot, `on_accept` discards any round-zero Accept unless `node.ownership` holds and
`ballot_node(msg.ballot) == owner_of(node, msg.slot)`, and the owner proposes in an own
slot once (Lemma 11). On the acceptor's side, `on_accept` answers a second value at the
ballot it already voted with `.Conflicting_Value` rather than a vote, and `ledger_apply`
does the same on replay. $qed$

*Lemma 4 (B3, the max-vote rule).* Suppose the proposer of a campaign ballot $b$
issues an Accept for $(b, s, v)$. Then there is a set $Q_1$ of at least
`read_quorum_size` acceptors, each of which promised $b$ for $s$ before reporting, such
that either (i) a received report supplies a vote $(b'', v)$ in $s$ whose ballot
is at least as high as every vote reported by $Q_1$, or (ii) no received report
supplies a vote in $s$, and $v$ is the no-op or a fresh client value. The selected
report in (i) may come from an additional peer whose chunk is not yet complete.

*Proof.* Every Accept at a campaign ballot is issued by `resolve_chunk` or, after
`become_leader`, by `node_propose` and `node_propose_batch`. `resolve_chunk` runs only
from `maybe_resolve_chunk`, which returns until `complete` reaches
`membership_read_quorum`, where a peer is complete when its `Promise_Range_Message`
arrived (`range_described`) and `received_in_range` reached the `reported` count it
announced (`on_promise_range`, `on_promise`). Each such peer ran `on_prepare`, which
promised the ballot (globally for `.Global`, per decree through `promise_bounded` for
`.Bounded`) and then reported every used cell in the chunk above its trim anchor, one
`Promise_Message` per cell, with the cell's `vote_ballot`, `state` and value. The
candidate's `on_promise` keeps, per slot, the report with the greatest `vote`,
promotes a `.Chosen` report over any vote, and returns `.Conflicting_Value` on two
values at one ballot. `resolve_chunk` then proposes `recovered_value[cell]` for a slot
with a `.Voted` record and `node.noop` for a slot with none, which is (i) and (ii)
inside the chunk. Reports already received from additional peers can raise the
selected ballot, but cannot lower it below the maximum from the complete quorum.
`recovery_ready` freezes this selection before any phase-two vote and keeps it
unchanged across a window-limited retry. A fresh value from `node_propose` lands at `next_slot`, which
`become_leader` set above `ledger_highest_used` and both fences; by Lemma 6 no member
of the final chunk's $Q_1$ holds a vote there, which is (ii). $qed$

*Theorem 1 (Agreement).* If $v$ is chosen in $s$ at $b$ and $w$ is chosen in $s$ at
$b'$, then $v = w$.

*Proof.* Let $b_0$ be the least ballot at which any value is chosen in $s$, and let
$v_0$ be that value; by Lemma 3 it is unique. It suffices to show that every Accept
issued in $s$ at a ballot $b' > b_0$ carries $v_0$: then a value chosen at $b_0$ is
$v_0$ by Lemma 3, and a value chosen at $b' > b_0$ is the value of the Accepts its
voters answered, again $v_0$.

Order Accept events in $s$ by happens-before. Because every execution prefix is
finite the order is well founded, and we argue by induction along it. Consider an
Accept $e$ for $(b', s, u)$ with $b' > b_0$ and assume the claim for every Accept in
$s$ that happens before $e$.

The round-zero ballot of $s$ is the least integer any acceptor will vote at in $s$
(Lemma 11), so $b' > b_0$ is a campaign ballot, and Lemma 4 gives a read quorum $Q_1$
whose members promised $b'$ for $s$ before reporting. $v_0$ chosen at $b_0$ gives a
write quorum $Q_2$ each of whose members voted $(b_0, v_0)$ in $s$. By Lemma 1 pick
$a in Q_1 inter Q_2$. By Lemma 2, $a$ could not vote at $b_0 < b'$ after promising $b'$
for $s$; so $a$ voted $(b_0, v_0)$ before it answered the prepare for $b'$. A cell's
vote is replaced only by a vote at a greater ballot (`on_accept` records only at or
above `promised_at`, which the earlier vote raised, and equality is the same value), and
a vote leaves a ledger only for a slot at or below that node's delivered prefix or
trim anchor (Lemma 8), in which case $a$'s manifest fences $s$ and $e$ is never issued.
So when $a$ answered, it reported a vote $(b_m, u_m)$ in $s$ with $b_m >= b_0$, and
case (ii) of Lemma 4 is excluded.

By Lemma 4 (i), $u$ is the value of a reported vote $(b_M, u_M)$ at least as high
as every vote reported by $Q_1$,
with $b_M >= b_m >= b_0$. If $b_M = b_0$, then $u_M = v_0$ by Lemma 3. If $b_M > b_0$,
the vote $(b_M, u_M)$ was cast on receipt of an Accept for $(b_M, s, u_M)$ that
happened before the report, hence before $e$; by the induction hypothesis
$u_M = v_0$. In both cases $u = v_0$. If instead some member of $Q_1$ reported $s$ as
`.Chosen`, `resolve_chunk` records that decision and issues no Accept in $s$ at all,
and the decision is $v_0$ by Corollary 1 and the same induction. $qed$

#callout([Why the induction runs along time, not along ballots], [
  Lamport's proof of Theorem 1 inducts on ballot numbers, because in his protocol a
  priest that has voted at $b''$ refuses to answer a `NextBallot` below $b''$. Here a
  vote raises only the per-decree promise `promised_at`, while a `.Global` prepare
  compares against `promised`; so an acceptor may report a vote at a ballot *above* the
  candidate's, and the candidate re-proposes that value at its lower ballot. That is
  still safe, and the induction along happens-before shows why: the higher vote was
  produced by an Accept that already carried $v_0$.
], kind: "idea")

*Corollary 1 (decided implies chosen).* If any node has decided $s$ with value $v$,
then $v$ is chosen in $s$ once the transition's required writes are durable.

*Proof.* `record_commit` is reached from four places. `on_accepted` calls it only when
`acknowledged[cell]` reached `membership_write_quorum`, counting each member once
(`bit_set_insert` on `acknowledgements[cell]`), for the ballot and slot the node is
driving (`lead_slot`, `lead_ballot`), and only when its own cell still holds a vote at
that ballot (`.Missing_Proposed_Value` otherwise); each acknowledgement is an
`Accepted_Message` sent by `on_accept` after recording a vote at that ballot (or for a
cell already holding it), and by Lemma 3 all those votes are for the same value, so
they form a $Q_2$. `send_accept` calls it directly only when the write quorum is one,
where the proposer's own vote is a $Q_2$. `on_commit` and `node_learn_chosen` record a
value another node had decided (A2, A5), and `resolve_chunk` records a value a reporting
peer had decided; both carry an earlier decision. Following these reports backward through the
finite execution reaches a quorum-backed decision; this induction is over decision
events, including repeated reports, rather than over the number of distinct nodes. $qed$

Theorem 1 with Corollary 1 is what the simulator's `AGREEMENT` oracle checks: it
records the first value it sees chosen in each slot, counting durable votes directly in
`persist_sim_write` so that a value chosen by a quorum whose leader then crashes still
enters the golden log, and it fails the run if any node ever decides another.

== Extension to the multi-decree log

*Lemma 5 (decrees are independent).* The ledger state of decree $s$ is the cell
`cell_of(s, W)` while `slot[cell] == s`, and nothing about $s$ is ever read from a
cell tagged with another slot.

*Proof.* Every read of a cell goes through `ledger_cell`, `ledger_vote_at`,
`ledger_chosen_at` or `claim_live`, each of which compares `l.slot[cell]` with the
slot it was asked about. A cell is retagged only by `ledger_open`, reached from
`claim_live` (live), `ledger_claim` (replay) and `ledger_clear_cell` (restart), and it
clears the promise, vote and state as the tag changes. So a vote, promise or decision belongs to one decree, and the Synod
argument applies to each decree separately; only the global `promised` is shared, and
sharing a promise can only refuse more votes, never permit one. $qed$

*Lemma 6 (one campaign covers every decree above its base).* Let a candidate at
campaign ballot $b$ become leader. Then for every decree $s >= $ `recover_base` there
is a set of at least `read_quorum_size` acceptors that promised $b$ before reporting
their votes in $s$, and the reports for $s$ were complete before the candidate
proposed in $s$.

*Proof.* `start_campaign` sends `Prepare_Message{ballot = b, first = recover_base,
last = recover_last}` with scope `.Global`. `on_prepare` answers only if
`msg.ballot >= l.promised`, sets `promised = b`, and then reports every used cell with
`first <= slot <= last` above its anchor; it sets `more` if it holds a used cell above
`last`. A `.Global` promise covers every decree, so a member that answered the first
chunk refuses every lower ballot in every later chunk as well. `maybe_resolve_chunk`
proposes nothing until a read quorum of members is complete for the current chunk;
then `resolve_chunk` drives the chunk and, if any complete member said `more`,
`begin_next_chunk` resets every `Election_Peer` except its fences, clears
`promise_seen`, and sends the next `Prepare` for `[last + 1, ...]` under the same
ballot. Each chunk therefore has its own complete read quorum, and each of its members
reported every vote it held in that chunk after promising $b$. When no complete member
reports `more`, no member of that final read quorum holds a vote above `last`, which
is what Lemma 4 (ii) needs for fresh proposals above the last chunk. $qed$

The per-chunk bookkeeping is what lets the candidate tolerate A2: a manifest that
overtakes its promises, a duplicated promise, or a chunk answered in two halves changes
`expected_in_range` and `received_in_range` and nothing else, and the test
`review_promise_reordering_deduplication_and_validation` runs those orders.

*Lemma 7 (holes).* Filling a hole with the host's no-op is an ordinary proposal and
cannot conflict with a chosen value.

*Proof.* A hole is a slot in the drive range with no recovered vote and no recovered
decision; `resolve_chunk` calls `send_accept(node, slot, node.ballot, node.noop.?,
effects)`, the same procedure as any proposal, and `maybe_resolve_chunk` refuses to
resolve at all with `.Missing_Noop` if no no-op was recorded. Lemma 4 (ii) holds for
the slot, so if any value were chosen there at a lower ballot, its $Q_2$ would meet
the chunk's $Q_1$ in a member that voted before promising and reported it, a
contradiction; and Theorem 1 covers every higher ballot. The no-op is a `Value` like
any other, with no tag, so nothing downstream distinguishes it. $qed$

*Lemma 8 (fences and the memory window).* A vote or decision leaves an acceptor's
ledger only for a slot at or below that acceptor's delivered prefix or trim anchor,
and a candidate never proposes at or below the greatest delivered prefix or trim
anchor any complete member reported.

*Proof.* Three procedures drop a slot from a cell. `claim_live` admits only slots in
the live window $(#[`memory_floor`], #[`memory_floor`] + W]$, so the map from live
slots to cells is a bijection and no cell is ever tagged with a slot whose predecessor
in that cell is still live; within the window it retags a cell only when
`held <= node.memory_floor` and the cell is `.Chosen`; `node_advance_memory_floor`
keeps `memory_floor <= delivered_through`. `node_resume_at` clears open votes at or
below `max(floor, anchor.chosen_trim_slot)` and sets `delivered_through` to that value.
`ledger_claim`, on replay, reuses a cell whose slot is `.Chosen` or at or below the
anchor for a later slot, and the later record exists only because the live node had
claimed the cell under the first rule. In each case the dropped slot is at or below
`delivered_through` or the anchor of that node, and both travel in every
`Promise_Range_Message` as `chosen_through` and `anchor`. `quorum_fences` takes the
maximum over the candidate's own values and every `Election_Peer`; `resolve_chunk`
starts driving at `max(recover_base, fence + 1)`, and `become_leader` sets `next_slot`
above both fences. A slot at or below a delivered prefix is decided on that node, hence
chosen (Corollary 1), and a slot at or below a trim anchor is chosen by the definition
of `Trim_Anchor`; so fencing forgoes only proposals that Theorem 1 would have forced to
carry the chosen value anyway. The leader learns the fenced slots through
`request_learn` instead, and slots below its memory floor come from the host through
`Serve_Range_Request`. $qed$

The fence is not an optimisation. Without it, an acceptor whose vote for a chosen slot
had been cleared by `node_resume_at` could be the only member of $Q_1 inter Q_2$, and
the candidate would see a hole where a decision lies. `review_recovery_preserves_fences_across_chunks`
and `review_snapshot_preserves_votes_above_anchor` exercise both fences.

== Durability

*Lemma 9 (indelible ink).* No promise or vote is observable by another node before it
is durable, and a restarted node's ledger contains every promise and vote it ever
revealed. Hence Lemma 2 holds across restarts.

*Proof.* `on_prepare`, `promise_bounded`, `on_heartbeat`, `on_accept` and
`send_accept` each call `effects_add_write` before `effects_add_message` in the same
transition, and `effects_add_write` sets `writes_pending`. With the default
`Durability_Gate.Enforced`, `effects_messages_slice` calls `host_order_violation`,
which stops the process, while `writes_pending` is set, and so does `effects_reset`, so
neither the messages nor the next transition can precede `confirm_writes_durable`
(A4). A restart replays the journal: `ledger_replay_fold` keeps the greatest promise,
every per-decree promise and every vote for a slot still resident, and `node_restore`
installs the result. Volatile bookkeeping is not needed for Lemma 2: the promise and
the vote are the ledger. A restart lowers no promise, and the only cells it clears
are those Lemma 8 covers. $qed$

The simulator injects a crash at each of `Before_Writes`, `Partial_Writes` and
`Partial_Messages` in `process_effects`, replays the journal into a fresh `Ledger`
through `ledger_replay_fold`, restores with the consumed floor, and checks
`PROMISE REGRESSION` and `VOTE BELOW PROMISE` on every record it persists.

*Lemma 10 (the pre-durable exception).* Let the host transmit, before its barrier,
only the envelopes `pre_durable_next` yields: `Accept_Message`s whose ballot has
round at least one. Theorem 1 continues to hold provided a proposer that crashes with
such an Accept in flight campaigns after restart at a round greater than the round of
that ballot. `start_campaign` and `start_revocation` guarantee this unconditionally:
each records the proposer's own promise for the new ballot in the same batch as the
`Prepare` it sends (`Write_Promise` from `start_campaign`; the `Write_Promise_At`
records of `promise_bounded` from `start_revocation`), and A4 makes that batch
durable before any `Prepare` leaves. The restarted ledger therefore always holds a
record at the round of every ballot the proposer ever announced.

*Proof.* An Accept claims nothing about its sender's durability: it asks acceptors to
vote, and each acceptor persists its own vote before answering (Lemma 9). The only
record the crash can lose is the proposer's own vote at $(b, s)$, and a lost vote
shrinks the set of votes at $b$; a subset of a $Q_2$ is not a $Q_2$, so nothing chosen
becomes unchosen. The proposer counts its own vote toward a quorum only in
`on_accepted`, a later transition, which A4 forbids before the vote is confirmed. What
Lemma 3 needs is that $b$ is never used again in $s$ for another value. `start_campaign`
and `start_revocation` compute `greatest` from `ledger_highest_ballot`, which scans
`promised`, every `promised_at` and every `vote_ballot`; so if any record at the round
of $b$ survived, the next ballot has a greater round and the old votes at $b$ are
ordinary votes at a lower ballot that Lemma 4 will report. A record always survives:
the proposer's own promise for $b$ was written before its `Prepare` left, and a
`Prepare` precedes every Accept at $b$. $qed$

#warning([Why the proposer promises itself], [
  The candidate's self-addressed `Prepare` is an ordinary envelope, and
  `maybe_resolve_chunk` counts a read quorum without requiring the candidate itself in
  it. If the candidate's promise were written only when that envelope came back, a
  candidate that reached its quorum from peers alone, proposed, and crashed before its
  first vote at $b$ was durable would hold no record at that round, and its restart
  could build the same ballot again: two values at one ballot in one decree, and Lemma
  3 gone. With majority quorums at most one of the two is chosen, but a later phase one
  may report both, `on_promise` counts a report before it returns `.Conflicting_Value`,
  and `node_tick` retries `maybe_resolve_chunk`, so a campaign could resolve on
  whichever report arrived first. This is why `start_campaign` writes
  `Write_Promise` for its own ballot in the batch that carries the `Prepare`, and why
  `start_revocation` runs `promise_bounded` on itself before broadcasting. The premise
  of this lemma is discharged by the library, not by a host rule.
])

The exception is unsound at round zero, and `pre_durable_next` withholds round-zero
Accepts for that reason. An owner's ballot is the same integer in every own slot, so
after a restart `next_usable_own_slot` would hand it the same slot again if its vote
there were not durable, and it would propose a different value at the same ballot in
the same decree. The simulator's vote oracle, which fails a run when one ballot
accepts two values in one slot, found exactly that counter-example: an owner reused its
ballot for a different value after a crash. With round-zero Accepts behind the barrier,
the owner's vote is in `ledger_highest_used` before any acceptor can see the Accept,
and `node_resume_at` sets `own_next` above it.

== Rotating ownership

*Lemma 11 (ballot partition).* Under `rotating_ownership`, in every decree $s$ the
round-zero ballot `ownership_ballot(owner_of(node, s))` is the least ballot any
acceptor votes at, it belongs to the owner alone, and every other ballot has round at
least one; so B1 holds per decree and Lemma 3 applies.

*Proof.* `owner_of` is `membership_get((s - 1) mod count)`, a function of $s$ and the
fixed membership, so every node computes the same owner. `on_accept` discards a
round-zero Accept unless `node.ownership` holds and `ballot_node(msg.ballot)` is that
owner. The owner proposes in $s$ through `propose_owned`, which takes
`next_usable_own_slot` and then moves `own_next` to `own_slot_from(slot + 1)`, so it
proposes once per own slot; after a restart `node_resume_at` recomputes `own_next`
above `ledger_highest_used`, which holds the vote (Lemma 10). Every other ballot comes
from `start_campaign` or `start_revocation`, whose round is `greatest + 1 >= 1`, and the
round occupies the top 40 bits, so any such ballot exceeds any round-zero ballot. $qed$

*Lemma 12 (a revocation is a phase one).* A revocation at ballot $b$ over the range
$[f, l]$ satisfies the premises of Lemma 4 for every decree in the range, so Theorem 1
holds with round-zero and campaign ballots mixed in one decree.

*Proof.* `start_revocation` picks a fresh round and sends
`Prepare_Message{scope = .Bounded, first = f, last = l}` with $l - f <$ `CHUNK_SLOTS`.
`on_prepare` first nacks a ballot below the global promise, then calls
`promise_bounded`, which walks the range twice: it returns false, and the acceptor
sends nothing, if any slot above the memory floor has no live cell or a `promised_at`
above $b$; otherwise it records `Write_Promise_At{ballot = b, slot}` for every slot in
the range before a single `Promise_Message` leaves. So a member the candidate counts as
complete has promised $b$ for every decree of the chunk, which is all Lemma 2 needs in
$s$. The reports and `maybe_resolve_chunk` are unchanged. `resolve_chunk` runs with
`drive_all` set, so every decree of the range is settled: a recovered round-zero vote
is re-proposed at $b$ (B3, the test `ownership_revocation_keeps_a_seen_vote`), a
recovered decision is recorded, a hole takes the no-op. The revoked owner is fenced by
`promised_at`: `on_accept` nacks its round-zero Accept, and `next_usable_own_slot`
steps over a slot whose effective promise exceeds `ownership_ballot(node.id)`. After
the chunk `become_leader` returns the revoker to `.Follower`; there is no standing
leader to reuse the ballot. $qed$

*Lemma 13 (skips).* A skip is a proposal of the no-op at the owner's ballot in an own
slot.

*Proof.* `skip_idle_slots` calls `propose_owned(node, noop, effects)` for own slots
up to `highest_seen`, at most `min(C, SKIP_BURST)` per tick; nothing distinguishes the
resulting Accept from any other round-zero proposal. $qed$

*Lemma 14 (resubmission).* A resubmitted suggestion is a new proposal in a new
decree and violates nothing.

*Proof.* `queue_resubmit` is called from two places, and both key on the ledger alone:
`on_accept`, when a higher ballot's value is about to overwrite the cell's own
round-zero vote, and `record_commit`, when the decided value differs from that vote.
The vote's ballot identifies the suggestion, so the check survives a revocation the
owner itself started (which clears the lead columns). A suggestion overwritten in
`on_accept` may yet be chosen at the revoker's ballot only if the revoker re-proposed
it (Lemma 4), in which case the resubmission decides it twice; that is the
at-least-once the host already handles by command id. `drain_resubmits` proposes it through
`propose_owned`, that is, at the owner's ballot in a later own slot; Lemma 11 applies
to that decree. The queue holds one chunk; a burst beyond it is dropped for the host's
ordinary retry, so the guarantee is at-least-once only through the host. $qed$

*Liveness, informally.* A stalled prefix does not stay stalled. `tick_ownership`
counts `stall_ticks` while `delivered_through < highest_seen`, asks the owner of the
stuck slot for what it knows every `heartbeat_interval_ticks`, and starts a revocation
of the chunk above `delivered_through` at `election_timeout_ticks`; a revoker that
times out revokes again at a higher round. A live owner either proposes in its slots or
skips them (Lemma 13), `resend_to` retransmits open Accepts and decisions, and
`emit_contiguous` releases the prefix as it fills. None of this is proved here; it
is the subject of the simulator's `LIVENESS` and `CONVERGENCE` oracles under
`--ownership`.

== Stop signs

*Lemma 15 (a decided stop sign seals its configuration).* Let stop sign $sigma$ be
chosen at slot $s$ in configuration $K$. Then (i) no node whose ledger holds $sigma$,
voted or decided, admits a new entry into $K$ through `replicated_log_propose`,
`replicated_log_propose_batch` or `replicated_log_propose_stop_sign`; (ii) no
`Replicated_Log_Node` of $K$ that has decided $s$ ever releases, reports or reads a
slot above $s$, so a value the core nevertheless chooses there is *abandoned*; (iii) the
next configuration continues at $s + 1$ on the same slot line, and a message from $K$
cannot act there.

*Proof.* (i) All three proposal procedures return `.Log_Sealed` when
`replicated_log_is_sealed` holds, which is `stop_pending || stop_sign != nil`.
`replicated_log_recalculate_stop_pending` runs after every transition
(`replicated_log_observe_effects`) and after restore
(`replicated_log_observe_durable`); it scans every used cell of the ledger for a
`Stop_Sign` whose `configuration_id` exceeds the node's own, so a vote for $sigma$
seals the node as surely as a decision does. (ii) `replicated_log_observe_effects` first
records the earliest decided stop sign and its slot through
`replicated_log_observe_stop`, and then `replicated_log_abandon_above_seal` cuts
`effects.committed` at the first slot above `stop_slot`. Releases are contiguous
(Lemma 16), so $s$ is released before or together with $s + 1$, and the seal is on
record before the cut runs in the same call; after a restart
`replicated_log_observe_durable` rediscovers the seal from the `.Chosen` cells before
any transition runs. `replicated_log_decided_through` reports at most `stop_slot`, and
`replicated_log_read` and `replicated_log_read_decided` refuse the first abandoned
slot. (iii) `replicated_log_init_from_stop` builds the membership from $sigma$ through
`membership_init` and calls `replicated_log_continue_at`, which starts an empty window
with `memory_floor = delivered_through = s` and `next_slot = s + 1`, refusing an anchor
above $s$ with `.Trim_Regression`. `replicated_log_step_checked` compares
`Log_Envelope.configuration_id` with the node's own before the core sees the
envelope, and on a mismatch resets the effects and returns `.Configuration_Mismatch`
with no write and no message. $qed$

#warning([Sealed at release, not at choice], [
  The core can still *choose* a value above $s$ in $K$. `resolve_chunk` re-drives a
  reported vote with no seal check, so a minority vote an earlier leader left above $s$
  can be chosen by a later one; and under rotating ownership an owner that has not yet
  learned of $sigma$ can have a suggestion decided in its own slot, which
  `reconfiguration_sim_ownership_abandons_decisions_above_the_seal` provokes on
  purpose. Such a value is chosen in the sense of D4 and abandoned by the log: never
  released, invisible to `committed_at` and `read_decided`, and decided afresh by the
  next configuration with its own quorums, following Lamport, Malkhi and Zhou's rule
  that the acceptors of an instance are those of the configuration that owns it. S1
  therefore holds for everything the host ever sees. Two consequences remain the host's:
  a client value abandoned this way must be proposed again in the next configuration,
  and a host that inspects the core ledger through `replicated_log_ledger` sees the
  abandoned decision and must not act on it.
])

== Contiguity

*Lemma 16 (contiguous delivery).* Every `Committed` entry a node releases is for slot
`delivered_through + 1` at the moment of release, its value is chosen, and
`delivered_through` then becomes that slot; so the sequence released by one node is
$1, 2, 3, ...$ from its restart base, with no gap and no repeat.

*Proof.* `emit_contiguous` loops from `next = delivered_through + 1`, stops at the
first cell that is not tagged `next` or not `.Chosen`, and for each released slot
appends `Committed{slot = next}` and sets `delivered_through = next`. The one other
release is the pass-through in `record_commit`, taken only when `claim_live` fails
(the slot is just past the live window) and `slot == node.delivered_through + 1`; it
records `Write_Chosen`, releases exactly that slot, advances `delivered_through` and
then calls `emit_contiguous`. Record and entry both point at the single
`pass_through` field, so `record_commit` takes this path at most once per transition:
a second such decision in the same batch is dropped and learned again later, never
released with the wrong value. Every released
value is a `.Chosen` cell or a value `record_commit` was about to record, chosen by
Corollary 1. After a restart `node_resume_at` sets `delivered_through` to the restart
base, the host's consumed floor or the trim anchor, whichever is greater, so the host
sees the same sequence continue; a slot delivered before the crash but not yet consumed
is released again, which is why the host applies idempotently. The standalone `Learner` gives the same guarantee through
`released_through` in `learner_learn_chosen`. $qed$

The simulator's `CONTIGUITY` oracle fails the run if any node releases a slot other
than `consumed + 1`.

== Chunk-local recovery scratch

The volatile recovery arrays and each peer's report bitmap have capacity
`CHUNK_SLOTS`, independently of the durable ledger window. For an active range
`[recover_base, recover_last]`, `recovery_index` first checks range membership,
then checks `slot - recover_base < CHUNK_SLOTS`, and only then converts the offset
to an array index. Subtraction is therefore nonnegative and the index is bounded.
Distinct slots in the range have distinct offsets. This argument does not require
the chunk size to be a power of two or to divide the ledger window.

`reset_recovery_chunk` invalidates slot tags, states, ballots, and per-peer duplicate
bitmaps at a new campaign or chunk. Payload bytes need not be zeroed: they are read
only through a valid state and matching absolute slot tag. Delayed reports are
rejected by ballot and range before they can access a new chunk's scratch. The
cross-chunk trim and chosen-prefix fences are retained separately.

Once enough complete peer manifests constitute a read quorum, `recovery_ready`
freezes the collected selection and `recovery_more`. This happens before the first
phase-two vote. A window-limited retry retains that same selection; a late promise
cannot replace a value already issued under this ballot. New chunks clear the
freeze. Without this rule, a late higher losing vote could replace a proposal made
from an earlier complete read quorum during a partial drive.

Resolution copies selected payloads into ledger-owned storage before emitting
borrowed writes and messages. No outgoing effect borrows scratch that will be
invalidated by chunk rollover. The refactor changes volatile representation, not
journal or wire formats, quorum intersection, or the persistence-before-reply rule.

Tests exercise absolute-slot reference selection, non-power-of-two chunks, ring
crossings, stale and duplicate reports, a blocked partial drive, a late promise
after that drive, and large payload lifetimes. The simulator additionally exercises
small windows with both flexible-quorum extremes and crashes. These are checks of
the implementation's correspondence to the argument, not a machine-checked proof.

== Obligations, lemmas, procedures, evidence

#block(width: 100%)[
#show raw: set text(size: 6.3pt)
#set par(justify: false)
#table(
  columns: (28mm, 1.45fr, 2.2fr),
  table.header([*Obligation*], [*Procedures*], [*Tests and oracles*]),
  [B1 ballot uniqueness \ (Lemmas 3, 11)],
    [`ballot_make`, `start_campaign`, `start_revocation`, `ownership_ballot`,
     `on_accept` (owner rule), `send_accept`],
    [`test_ballot_ordering`, `ownership_three_owners_propose_concurrently`,
     simulator vote oracle "ballot accepted two values"],
  [B2 quorum intersection \ (Lemma 1)],
    [`membership_init`],
    [`test_membership_validation`, `review_negative_quorums_and_learner_campaign`,
     `review_flexible_quorums_and_window_reuse`],
  [B3 max-vote \ (Lemmas 4, 6, 7, 12)],
    [`on_prepare`, `on_promise`, `on_promise_range`, `maybe_resolve_chunk`,
     `resolve_chunk`, `promise_bounded`],
    [`test_lamport_b3_max_vote_rule`, `election_matrix_preserves_chosen_values`,
     `ownership_revocation_keeps_a_seen_vote`,
     `review_multichunk_recovery_and_retry_progress`, simulator `AGREEMENT` and
     `VALIDITY`],
  [Votes respect promises \ (Lemma 2)],
    [`on_accept`, `send_accept`, `ledger_apply`, `ledger_replay_fold`],
    [simulator `PROMISE REGRESSION` and `VOTE BELOW PROMISE`, `node_assert_valid`],
  [Decided implies chosen \ (Corollary 1)],
    [`on_accepted`, `record_commit`],
    [`review_duplicate_acknowledgements_do_not_make_a_quorum`,
     `review_missing_proposal_is_error`, `test_three_node_cluster_agreement`],
  [Window and fences \ (Lemmas 5, 8)],
    [`claim_live`, `ledger_claim`, `quorum_fences`, `resolve_chunk`, `become_leader`],
    [`review_recovery_preserves_fences_across_chunks`,
     `review_snapshot_preserves_votes_above_anchor`,
     `review_replay_reuses_certified_trimmed_vote`],
  [D1 indelible ink \ (Lemmas 9, 10)],
    [`effects_messages_slice`, `effects_reset`, `effects_confirm_writes_durable`,
     `pre_durable_next`, `node_restore`],
    [`test_effects_power_loss_barrier_flag`, `test_pre_durable_messages_iterator`,
     `test_host_managed_gate`, `test_node_restore_and_recovery`, simulator crash
     points and `CONVERGENCE`],
  [Rotating ownership \ (Lemmas 11, 12, 13, 14)],
    [`owner_of`, `propose_owned`, `skip_idle_slots`, `start_revocation`,
     `queue_resubmit`, `drain_resubmits`],
    [`ownership_idle_owners_skip`, `ownership_revokes_a_crashed_owner`,
     `ownership_revoked_suggestion_is_resubmitted`, simulator `--ownership`],
  [S1 stop-sign sealing \ (Lemma 15)],
    [`replicated_log_is_sealed`, `replicated_log_propose`,
     `replicated_log_abandon_above_seal`, `replicated_log_step_checked`,
     `replicated_log_init_from_stop`],
    [`test_replicated_log_stop_sign_seals_epoch`,
     `review_stop_seal_restore_and_completed_history`,
     `reconfiguration_cluster_handover_rejects_old_epoch`,
     `review_out_of_order_chosen_stop_blocks_proposals`, the `seal_expect_nothing_after`
     oracle of every `reconfiguration_sim_*` scenario],
  [L1 contiguous delivery \ (Lemma 16)],
    [`emit_contiguous`, `record_commit`, `learner_learn_chosen`],
    [`test_learner_contiguous_release`,
     `review_leader_fetches_decisions_from_ahead_follower`, simulator `CONTIGUITY`],
)
]

#exercise("12.1", [
  Show where the proof of Theorem 1 uses A3 (quorum intersection), and what fails if
  read and write quorums may be disjoint. Then construct the failure concretely: five
  members, a read quorum of two and a write quorum of two, two candidates, one decree.
  Write down the votes each acceptor holds when the second candidate resolves its
  chunk and name the branch of `resolve_chunk` it takes.
], hint: [
  The proof picks $a in Q_1 inter Q_2$ exactly once. If no such $a$ exists, Lemma 4
  case (ii) is no longer excluded, and `membership_init` is the only line between you
  and the no-op.
])

#teach_back([
  Rehearse the core structure of Theorem 1 using a single witness acceptor $a in Q_1 inter Q_2$:
  - Why the ordering of $a$'s vote relative to its subsequent promise prevents older values from being proposed.
  - How `resolve_chunk` translates the witness's promise into the leader's phase-two proposal.
  - The precise scope of Lemma 10 regarding the durability barrier and host obligations.
  - How Lemma 15 enforces configuration isolation across reconfiguration stop signs.
])
