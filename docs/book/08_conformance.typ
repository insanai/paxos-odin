#import "theme.typ": *

// Unicode line breaking forbids a break before "."; see the same rule in Part VII.
#show raw.where(block: false): it => {
  if it.text.starts-with(".") { sym.zws }
  it
}

// Signatures and identifiers in table cells read better ragged-right than justified.
#show table: set par(justify: false)

#part_page("VIII", [Conformance], [
  One table from the paper to the code to the oracles: every safety-relevant
  rule of the basic protocol is traceable to a proc, and every oracle names the
  invariant it watches.
])

= Lamport Conformance Appendix

This appendix maps the basic protocol of _The Part-Time Parliament_ (section
2.3) and its multi-decree refinements (sections 3.1 through 3.3) onto
`src/election.odin`, `src/consensus.odin`, `src/ownership.odin`,
`src/ledger.odin`, and `src/replicated_log.odin`, and then onto the runtime
oracles in `sim/simulation.odin`, the seeded reconfiguration scenarios in
`tests/test_reconfiguration_sim.odin`, and the ownership scenarios in
`tests/test_ownership.odin`. Line numbers drift; proc names are the stable
anchors. Read the whole chapter with one caveat in mind: what follows is
executable evidence that the implementation follows the paper on every schedule
the harnesses have run. It is not a proof. The argument that B1, B2, and B3
imply agreement, and the lemmas that tie each proc to one of the three, live
in the safety-argument chapter (`docs/book/03_proofs.typ`); this appendix only
says where each lemma's premise is enforced and which oracle would notice if
it were not.

== The basic protocol, step by step

The paper's priest keeps `lastTried`, `nextBal`, `prevVote`, and the ledger.
The library's acceptor keeps a `Ledger`: `promised` for every decree, a
per-decree `promised_at`, one slot-tagged cell per resident decree, and the
volatile `node.ballot` for its own attempts.

#table(
  columns: (auto, 1.2fr, 1.8fr),
  table.header([*Paper*], [*Rule*], [*Implementing proc*]),
  [Step 1], [A priest chooses a ballot greater than `lastTried`, owned by
    itself, and sends `NextBallot(b)`.],
    [`start_campaign`: the round is one above the greatest of
    `highest_observed_round`, `ballot_round(ballot)`, and the round of
    `ledger_highest_ballot`, packed by `ballot_make` with the node's
    `priority` and `id`, so ownership is built into the ballot; the
    `Prepare_Message` with `scope = .Global` goes to every member.],
  [Step 2], [On `NextBallot(b)` with `b` above `nextBal`, set `nextBal` and
    answer `LastVote(b, v)` with the highest vote below `b`.],
    [`on_prepare`: a ballot below `promised` gets a `Nack_Message`; otherwise
    `Write_Promise` is recorded (or, for `scope = .Bounded`,
    `promise_bounded` records one `Write_Promise_At` per decree in the
    range), one `Promise_Message` per used cell in the chunk is sent with its
    `vote` and `state`, and a `Promise_Range_Message` closes the answer.],
  [Step 3], [With `LastVote` from every priest in a majority, begin the ballot
    with the decree of the highest vote, or any decree if none (B3).],
    [`on_promise` keeps the highest-ballot vote per slot, lets a reported
    decision dominate, and refuses two values at one ballot;
    `on_promise_range` records each peer's chunk description;
    `maybe_resolve_chunk` waits for `membership_read_quorum` complete
    descriptions; `resolve_chunk` re-proposes each recovered value above the
    quorum fences.],
  [Step 4], [On `BeginBallot(b, d)` with `b` equal to `nextBal`, cast the vote
    and write it in the ledger.],
    [`send_accept` records the proposer's own `Write_Vote` and broadcasts
    `Accept_Message`; `on_accept` nacks a ballot below `promised` or below
    the cell's `promised_at`, otherwise records `Write_Vote` and answers
    `Accepted_Message` only after that write is in the batch.],
  [Step 5], [With `Voted` from every priest in the quorum, the decree passes
    and the president writes it in the ledger.],
    [`on_accepted`: acknowledgements are a `Bit_Set` keyed by member index,
    so duplicates never count twice; at `membership_write_quorum`,
    `record_commit` writes `Write_Chosen` and `Commit_Message` is broadcast
    once.],
  [Step 6], [On `Success(d)`, every priest writes the decree in its ledger.],
    [`on_commit` and `record_commit`: `.Conflicting_Commit` if the slot holds
    a different decision; `emit_contiguous` then releases the decided prefix
    in order.],
)

Several departures from the paper's message rules are deliberate. A repeated
Prepare at the current promise is answered idempotently. An Accept may carry a
ballot above the effective promise; accepting it raises the per-slot promise.
A repeated Accept for the same vote needs no new write. `on_prepare` reports a decided cell in the same answer as the votes,
with `state = .Chosen`, and `on_promise` lets it dominate every vote: the
paper's president learns passed decrees separately. And round zero of every
decree is reserved for the decree's owner (`ownership_ballot`), which
`on_accept` enforces by refusing a round-zero accept from anyone else; under
rotating ownership an owner therefore runs step 4 in its own slots with no
step 1 at all, because no lower ballot exists in that decree, and the Synod
proof applies unchanged.

== Multi-decree refinements

#table(
  columns: (auto, 1.2fr, 1.8fr),
  table.header([*Paper*], [*Refinement*], [*Implementing code*]),
  [Section 3.1], [One `NextBallot(b, n)` covers every decree numbered above
    `n`; the reply carries all of that priest's votes for those decrees.],
    [`Prepare_Message.first` is the paper's `n + 1` and `scope = .Global`
    promises every decree from it on; `on_prepare` reports only
    `[first, last]`, one chunk of `CHUNK_SLOTS`, and sets
    `Promise_Range_Message.more` when used cells exist above `last`;
    `begin_next_chunk` issues the next `Prepare_Message` under the same
    ballot. Leadership, once won, covers every later slot without a new
    phase one.],
  [Section 3.2], [Gaps below a passed decree are filled with the harmless
    "olive-day" decree so the ledger stays contiguous.],
    [`resolve_chunk` proposes the no-op remembered from `campaign` or `tick`
    for every slot in the drive range that has no recovered vote; slots at or
    below the quorum's trim anchor or chosen prefix are released history and
    are not treated as holes. Under ownership `skip_idle_slots` proposes the
    same no-op in an idle owner's slots before anyone has to recover them.],
  [Section 3.3], [A decree can change the membership; the change takes effect
    a fixed number of decrees later, so the parliament that passes it is the
    one that decides the intervening decrees.],
    [`src/replicated_log.odin` uses a stop sign instead of a delay: a decided
    `Stop_Sign` in slot $s$ seals its configuration, nothing above $s$ is
    released to the application in it, proposals answer `.Log_Sealed`, and
    `replicated_log_init_from_stop` starts the next configuration at $s + 1$
    on the same slot line with an inherited trim anchor. Under rotating ownership,
    decisions made above the seal before it was learned are abandoned; the new
    configuration decides those positions afresh.],
  [Section 2.2 (B1)], [Each ballot has a unique number.],
    [`Ballot` is one packed `u64`, `round << 24 | priority << 16 | node`, so
    the total order is integer comparison and the node field makes two
    proposers' ballots distinct; per decree, round zero belongs to the owner
    alone.],
  [Section 2.2 (B2)], [Any two quorums share a priest.],
    [`membership_init` rejects `read + write <= N` with
    `.Non_Intersecting_Quorums`; majority by default, flexible pairs allowed.],
  [Section 2.2 (B3)], [A ballot's decree equals the decree of the highest
    earlier vote in its quorum, if any.],
    [`on_promise` and `resolve_chunk`, checked by
    `test_lamport_b3_max_vote_rule` in `tests/test_protocol.odin` and by
    `ownership_revocation_keeps_a_seen_vote` in `tests/test_ownership.odin`.],
)

== Durable state: the ledger

The paper's ledger variables map onto the columns of `Ledger(Value,
WINDOW)`. The host never copies the struct; it persists the five `Write`
records and rebuilds the struct by replay. Cells are struct-of-arrays, and
`slot[c]` tags which slot a cell holds so a reused cell is never mistaken for
an older one.

#table(
  columns: (auto, 1.25fr, 1.55fr),
  table.header([*Paper*], [*Column*], [*Persisted by*]),
  [`nextBal`], [`promised`, and per decree `promised_at[c]`; the effective
    promise is `ledger_promise_for`],
    [`Write_Promise` from `on_prepare` (`.Global`) and `on_heartbeat`;
    `Write_Promise_At` from `promise_bounded`. A vote also raises
    `promised_at[c]` to its ballot.],
  [`prevVote`], [`vote_ballot[c]` and `value[c]` while `state[c]` is
    `.Voted`, read by `ledger_vote_at`],
    [`Write_Vote` from `send_accept` and `on_accept`, before the
    `Accepted_Message` may be sent.],
  [outcome], [`value[c]` while `state[c]` is `.Chosen`, read by
    `ledger_chosen_at`],
    [`Write_Chosen` from `record_commit`, before the commit broadcast or
    application delivery.],
  [`lastTried`], [`node.ballot` (volatile)],
    [Not persisted: a restarted node campaigns above
    `ledger_highest_ballot`, which is safe because every accept it ever
    sent at a campaign ballot implies its promise was durable first, and an
    owner's round-zero suggestion waits for the barrier.],
  [(none)], [`anchor`],
    [`Write_Trim` from `node_install_chosen_trim`; `node_begin_recovery`
    applies one through `ledger_apply` and emits nothing, so the host
    persists the image and the anchor itself. The paper predates bounded
    windows; the anchor lets an acceptor vouch for a released prefix it no
    longer stores.],
  [(derived)], [`used`, `chosen`],
    [Bitmaps over cells, maintained by `ledger_record_vote` and
    `ledger_record_chosen`; never persisted.],
)

`ledger_apply` is the strict single-configuration replay and the rule set a
reviewer should check against the paper:

- `Write_Promise` below `promised` is `.Promise_Regression`; otherwise it
  replaces the promise.
- `Write_Promise_At` at slot zero is `.Invalid_Slot`; a cell still holding an
  earlier open slot is `.Window_Overrun`; a ballot below the cell's
  `promised_at` is `.Promise_Regression`; otherwise it replaces the per-decree
  promise.
- `Write_Vote` at slot zero is `.Invalid_Slot`; below `promised` it is
  `.Promise_Regression`; a cell still holding an earlier open slot is
  `.Window_Overrun`; below the cell's `promised_at` it is
  `.Promise_Regression`; the same ballot with a different value is
  `.Conflicting_Value`; a value that disagrees with a stored decision is
  `.Conflicting_Commit`; otherwise `promised_at[c]` follows the ballot and,
  unless the cell is already `.Chosen`, the vote is stored.
- `Write_Chosen` at slot zero is `.Invalid_Slot`; one whose cell a later slot
  already owns is silently skipped, because a decision is derived state that
  the anchor or a later decision already covers; one that disagrees with a
  stored decision is `.Conflicting_Commit`; otherwise the decision is stored.
- In phase one, `on_promise` keeps per decree the greatest vote reported and lets a
  reported decision dominate; a `.Voted` report that arrives after a decision is an
  older, losing vote from an acceptor outside the deciding quorum and is ignored,
  and only a second decision with a different value is `.Conflicting_Commit`.
- `Write_Trim` with a lower `trim_id` or lower `chosen_trim_slot`, or the same
  non-zero `trim_id` with a different slot, is `.Trim_Regression`.

A decision that disagrees with a stale local *vote* is legal and accepted; the
choosing quorum may not have included this node. `ledger_replay_fold` relaxes
the rules for lifetime journals that span window reuse and configuration
changes: a promise folds to its maximum, a per-decree promise or a vote whose
cell is already held by a later slot is skipped rather than reported as an
overrun, a vote is stored without the global-promise check, and decisions and
anchors go through `ledger_apply` unchanged. `ledger_claim` decides cell reuse
during replay: a cell may be retagged when its previous slot is chosen or lies
at or below the certified trim.

== The oracles that watch the same rules

The simulator in `sim/simulation.odin` runs up to five nodes
(`MAX_SIM_NODES`) with a 256-slot window and 64-slot chunks (`SIM_WINDOW`,
`SIM_CHUNK`). One seed fixes every choice; a failing run prints the seed so it
can be replayed step for step with
`./bin/paxos-sim --seed=N --steps=N --nodes=N [--ownership] [--verbose]`, and
`make sim` runs one seeded pass. The default fault mix (`default_faults`)
drops 60 per thousand envelopes, duplicates 40, crashes 20 per transition, and
toggles a link 25 per thousand steps. The harness carries values the way a
host would: `packet_of` copies a message's value at enqueue and
`packet_envelope` repoints the envelope at that copy before `step`, and every
journaled `Sim_Record` copies the value of a `Write_Vote` or `Write_Chosen`.

The simulator has two modes. Without `--ownership`, node 1 campaigns at
bootstrap and again during quiescence, and the liveness probe is proposed by
whichever node reports `.Leader`. With `--ownership`, every node is
initialised with `Node_Options{rotating_ownership = true}`, nobody campaigns, a proposal
on any live node succeeds in that node's own slot, and the probe is proposed
by the first node the loop reaches. The oracles are the same in both modes.

Crashes strike inside the host commit sequence at one of three
`Crash_Point`s: `.Before_Writes` (nothing survives), `.Partial_Writes` (a
prefix of the writes is durable, no message left), and `.Partial_Messages`
(every write durable, a prefix of the messages sent). Before the crash roll,
the accepts that `pre_durable_next` yields are enqueued, so a campaign accept
can reach a peer whose sender then loses its batch. Restart replays the
journal through `ledger_replay_fold` and `restore` with the consumed prefix
as floor and the same `Node_Options`. `advance_memory_floor` is called after
only half of the transitions, so full-window paths are exercised.

#table(
  columns: (auto, 1.4fr, auto, 1.1fr),
  table.header([*Oracle*], [*What it checks*], [*Proc*], [*Invariant witnessed*]),
  [Agreement], [The first decision per slot fixes the golden log; any later
    decision for that slot must equal it. A decision is recorded at the vote
    level: a write quorum of `Write_Vote` records at one ballot counts as a
    decision even if the proposer crashes before announcing it, and every
    `Write_Chosen` and every released `Committed` entry is checked against
    the golden log.],
    [`record_decision`, `persist_sim_write`], [One value per slot; chosen
    means voted.],
  [Validity], [Every decided value is the no-op or a value some node
    proposed in this run.],
    [`record_decision`], [Values come from proposals.],
  [Promise monotonicity], [A `Write_Promise` never carries a ballot below the
    node's last durable promise.],
    [`persist_sim_write`], [`nextBal` is monotone.],
  [Vote below promise], [A `Write_Vote` never carries a ballot below the
    node's global promise, and one ballot never records two values in a
    slot across the cluster.],
    [`persist_sim_write`], [Steps 2 and 4; one value per ballot.],
  [Contiguity], [Each released `Committed` entry is exactly the consumed
    prefix plus one.],
    [`process_effects`], [Contiguous delivery.],
  [Liveness probe], [After healing links, restarting every node, and
    draining the network, the cluster must decide one fresh proposal, so a run
    without progress cannot pass vacuously.],
    [`run_quiescence`, `sim_run`], [Progress under quiescence.],
  [Convergence], [Every node applied every slot of the golden log with the
    golden value.],
    [`verify_convergence`], [All ledgers agree at the end.],
)

The seeded reconfiguration scenarios in `tests/test_reconfiguration_sim.odin`
run a three-voter `Replicated_Log_Node` (capacity `SEAL_MEMBERS` of 4) with
an eight-slot window, two-slot chunks, and 32 metadata bytes (`SEAL_WINDOW`,
`SEAL_CHUNK`, `SEAL_METADATA`), shuffling delivery order per seed, stamping
every envelope through `log_envelope`, and journaling every write with
`journal_append` before any message leaves. Each scenario runs sixteen seeds
(`SEAL_SEEDS`) and applies the same oracles: `seal_expect_agreement` (every
member decided the same stop sign in the same slot, with identical sealed
prefixes), `seal_expect_nothing_after` (no slot past the seal reads as decided and
proposals return `.Log_Sealed`), `seal_expect_replay_keeps_seal` (journal
replay through `journal_replay` and `restore` rediscovers the seal), and
`seal_expect_next_epoch_decides` (the configuration the stop sign names
elects a leader and decides new commands at `stop_slot + 1` onward).

- `reconfiguration_sim_seal_survives_drop_duplicate_and_reorder`: members
  `{1, 2, 3}` keep the same voter set while the configuration id moves from 1
  to 2. A command and the stop sign race for adjacent slots; the accept
  carrying the stop is dropped once toward node 2 and duplicated once toward
  node 3, and the test asserts both faults fired.
- `reconfiguration_sim_membership_handover_reaches_new_configuration`:
  `{1, 2, 3}` hands over to `{2, 3, 4}`, id 1 to 2. The removed voter's
  `log_init_from_stop` returns `.Not_Member`; node 2 leads the next
  configuration.
- `reconfiguration_sim_one_for_one_voter_replacement`: `{1, 2, 3}` becomes
  `{1, 2, 4}`, id 7 to 8. Node 3 leads the old configuration and is refused
  by the new one; node 1 leads after handover.
- `reconfiguration_sim_ownership_abandons_decisions_above_the_seal`: the same
  three members run with `rotating_ownership = true`. Owner 2 seals in slot 2
  while owners 3 and 1, not yet aware of it, get slots 3 and 4 decided. The
  test requires that some ledger holds slot 3 as chosen, that no node releases
  or reads anything above the seal (`decided_through` stops at the stop slot,
  `read_decided` returns two entries), and that the next configuration decides
  slot 3 afresh. The host commit sequence in the harness carries the oracle for
  every scenario: a node sealed by a decided stop sign releases nothing above it.

The ownership scenarios in `tests/test_ownership.odin` run three
`Node(u64, 3, 16, 4)` values with `rotating_ownership = true` and a queue
that can silence one member as if it had crashed:

- `ownership_three_owners_propose_concurrently`: `owner_of` deals slots 1, 2,
  3, then 4 to members 1, 2, 3, 1; four concurrent proposals decide in their
  own slots with no campaign, and `campaign` answers `.Campaign_Disabled`.
- `ownership_idle_owners_skip`: only member 1 proposes, in slots 1 and 4;
  after three ticks members 2 and 3 have skipped slots 2 and 3 with the
  no-op and every member has `decided_through` of 4.
- `ownership_revokes_a_crashed_owner`: member 3 is silent; the prefix stalls
  at 2 until a revocation fills slot 3 with the no-op, after which both
  survivors report `.Follower`, because a revoker holds no standing
  leadership.
- `ownership_revocation_keeps_a_seen_vote`: member 3's suggestion for slot 3
  reached only member 2 before member 3 fell silent; the revoker finds that
  vote and re-proposes it (B3), so slot 3 decides 33, not the no-op.
- `ownership_revoked_suggestion_is_resubmitted`: member 3's suggestion
  reached nobody and is revoked to the no-op; when member 3 returns it learns
  the revocation and proposes the value again in a later own slot.

In all, `tests/*.odin` holds 79 `@(test)` procedures; the ones above are the
schedule-driven subset. `review_hundred_twenty_eight_voters` and
`review_thousand_voters_reach_quorum` in `tests/test_review.odin` exercise the
sorted membership array and the word-array bit set at sizes the default
capacities never reach.

== What this evidence does and does not say

The mapping from paper step to proc is one-to-one with the first table, and
each oracle names a proc and an invariant, so a change to any handler should
update this appendix, the oracle, and the unit test that pins the rule
together. The evidence is bounded by what was run: finitely many seeds, five
nodes, one fault mix, two modes. A schedule the generator never produced is
not covered, and no claim here rests on exhaustive state exploration. The
lemmas in the safety-argument chapter remain the argument, the invariants in
Part VII are its checklist, and the oracles are its instrumentation.
