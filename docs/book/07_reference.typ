#import "theme.typ": *

// Unicode line breaking forbids a break before ".", so runs of error values such as
// `.Not_Leader`, `.Window_Full` could not wrap; a zero-width space restores the opportunity.
#show raw.where(block: false): it => {
  if it.text.starts-with(".") { sym.zws }
  it
}

// Signatures and identifiers in table cells read better ragged-right than justified.
#show table: set par(justify: false)

#part_page("VII", [Desk reference], [
  Messages, effects, the public API, options, errors, formulas, invariants,
  exercise answers, and sources, collected where a reviewer can reach them
  without rereading the narrative chapters.
])

= Consensus Desk Reference

This chapter is the part of the book meant to be opened rather than read. Every
identifier is spelled as it appears under `src/`, with the parameter order the
compiler accepts. Where the prose and the code disagree, the code is right and
this page needs a patch. `VERSION` is `"0.2.0"`.

== Message reference

`Message(Value)` is a union of nine variants. `Envelope(Value)` wraps one with
`from` and `to`, both `Node_Id` (a `u16`; zero is reserved). `node_step`
answers `.Wrong_Recipient` when `to` is not the local id and `.Not_Member`
when `from` lies outside the membership; a non-voting node accepts only
`Commit_Message` and answers every other kind with
`.Learner_Message_Forbidden`. Three variants carry a value as a `^Value`:
outbound it points into the sender's ledger and is valid until that node's
next transition; inbound the host points it at the decoded value for the
duration of `step`. `message_value(message) -> (^Value, bool)` returns that
pointer for the kinds that carry one (a `Promise_Message` only when its
`state` is not `.Empty`).

#table(
  columns: (auto, 1.15fr, 1.6fr),
  table.header([*Variant*], [*Fields*], [*Meaning and sender*]),
  [`Prepare_Message`], [`ballot: Ballot`, `first: Slot`, `last: Slot`,
    `scope: Prepare_Scope`],
    [Phase one. `start_campaign` and `begin_next_chunk` broadcast it to every
    member, the sender included, with `scope = .Global`: promise `ballot` for
    every decree from `first` on and report votes in `[first, last]`.
    `start_revocation` sends it with `scope = .Bounded`: promise only the
    decrees in `[first, last]`, recorded per decree.],
  [`Promise_Message(Value)`], [`ballot: Ballot`, `slot: Slot`,
    `vote: Ballot`, `state: Cell_State`, `value: ^Value`],
    [One reported vote (`state = .Voted`) or decision (`state = .Chosen`) for
    one decree in the chunk. `on_prepare` sends one per used cell above the
    trim anchor and at or above `first`; a reported decision dominates every
    vote in `on_promise`.],
  [`Promise_Range_Message`], [`ballot: Ballot`, `anchor: Trim_Anchor`,
    `chosen_through: Slot`, `first: Slot`, `last: Slot`, `reported: u32`,
    `more: bool`],
    [The manifest that closes a phase-one answer. `reported` tells the
    candidate how many `Promise_Message`s describe `[first, last]`; `more`
    says used cells lie above `last`; `chosen_through` is the acceptor's
    released prefix; `anchor` is its adopted trim record.],
  [`Accept_Message(Value)`], [`ballot: Ballot`, `slot: Slot`, `value: ^Value`],
    [Phase two. `send_accept` records the sender's own vote, then broadcasts
    to every peer; `resend_to` repeats it. It is the only variant
    `pre_durable_next` yields, and only when `ballot_round(ballot) > 0`.],
  [`Accepted_Message`], [`ballot: Ballot`, `slot: Slot`,
    `decided_through: Slot`],
    [`on_accept` answers after recording `Write_Vote`; a duplicate of an
    identical vote is acknowledged again without a new write.
    `decided_through` updates the sender's entry in `peer_decided_through`.],
  [`Commit_Message(Value)`], [`slot: Slot`, `value: ^Value`],
    [A value the sender knows is chosen: `on_accepted` broadcasts it once a
    write quorum acknowledged; `resolve_chunk`, `on_learn`, and `resend_to`
    re-teach it; `on_accept` answers a conflicting accept for a decided cell
    with it; the host serves evicted history with it.],
  [`Learn_Message`], [`from_slot: Slot`, `count: u32`],
    [Catch-up request for decisions in `from_slot` through
    `from_slot + count - 1`, `count` in `1..=CHUNK_SLOTS`. Sent by
    `request_learn` from `on_heartbeat` when behind, from `resolve_chunk`
    toward the peer with the longest chosen prefix, from `resend_to`,
    `node_reconnected`, `tick_ownership`, and `node_request_catch_up`.],
  [`Nack_Message`], [`rejected: Ballot`, `promised: Ballot`, `slot: Slot`,
    `decided_through: Slot`],
    [Refusal of a ballot below the promise, from `on_prepare` or
    `on_heartbeat` (`slot = 0`) or `on_accept` (the refused decree).
    `on_nack` steps the rejected candidate or leader down and records
    `ballot_node(promised)` as the leader hint.],
  [`Heartbeat_Message`], [`ballot: Ballot`, `decided_through: Slot`],
    [Leader liveness, broadcast by `node_tick` every
    `heartbeat_interval_ticks`. A follower whose promise is lower adopts the
    ballot with a `Write_Promise`; one that is behind replies with
    `Learn_Message`.],
)

`Prepare_Scope` is `enum u8 { Global, Bounded }`. `Cell_State` is
`enum u8 { Empty, Voted, Chosen }`.

== Effect ordering

An `Effects` batch is the whole output of one transition. It holds four lists
and one flag, `writes_pending`, which `effects_add_write` raises and
`effects_confirm_writes_durable` lowers. `Write(Value)` is a union of five
records:

#table(
  columns: (auto, 1.05fr, 1.7fr),
  table.header([*Write*], [*Fields*], [*Must be durable before*]),
  [`Write_Promise`], [`ballot: Ballot`],
    [Any `Promise_Message` or `Promise_Range_Message` for that ballot leaves
    (`on_prepare`, `scope = .Global`), and any `Nack_Message` that cites it
    as `promised`. `on_heartbeat` also emits it.],
  [`Write_Promise_At`], [`ballot: Ballot`, `slot: Slot`],
    [The bounded answer leaves: `promise_bounded` emits one per decree in
    `[first, last]` above the memory floor whose per-decree promise changes.],
  [`Write_Vote(Value)`], [`ballot: Ballot`, `slot: Slot`, `value: ^Value`],
    [The `Accepted_Message` for that vote leaves (`on_accept`), and before
    the leader counts its own vote toward a decision (`send_accept`).],
  [`Write_Chosen(Value)`], [`slot: Slot`, `value: ^Value`],
    [The `Commit_Message` broadcast, the application's consumption of the
    matching `Committed` entry, and any `on_learn` answer built on it
    (`record_commit`).],
  [`Write_Trim`], [`Trim_Anchor` (`trim_id: u64`, `chosen_trim_slot: Slot`)],
    [Any `Promise_Range_Message` that vouches for the released prefix from
    this anchor, and any cell reuse below it (`node_install_chosen_trim`).],
)

#callout([Pointer validity], [
  Nothing in a batch owns a value. `Write_Vote.value`, `Write_Chosen.value`,
  every `^Value` in a message, and `Committed.value` point into the ledger of
  the node that produced the batch (or, for one decision released past the
  window edge, into `node.pass_through`). Each pointer is valid until the next
  transition on that node. A host persists every write before it runs another
  transition, and copies or serialises a message's value when it queues the
  envelope, as `packet_of` does in `examples/counter.odin`.
])

`Committed(Value)` carries `slot` and `value: ^Value`; entries arrive in slot
order, contiguous with everything released earlier (`emit_contiguous`).
`Host_Request` is a union with one variant, `Serve_Range_Request`, carrying
`peer: Node_Id`, `first: Slot`, and `count: u32`: `on_learn` emits it when a
peer asks for history at or below `memory_floor`, and the host answers from its
own journal or state image with `Commit_Message`s.

#callout([Host commit sequence], [
  1. `effects_writes_slice`: append every record in order and sync.
  2. `effects_confirm_writes_durable`: clear `writes_pending`. Never confirm a
     failed write; recover from the journal instead.
  3. `effects_committed_slice`: apply released entries in order.
  4. `effects_requests_slice`: serve history the peer asked for.
  5. `effects_messages_slice`: transmit. Under the default
     `Durability_Gate.Enforced`, reading this slice while writes are pending
     stops the process, and so does `effects_reset` on an unconfirmed batch.
  Every public transition calls `effects_reset` first, so a host drains one
  batch fully before the next call. `effects_init` discards without the
  check; it exists for fresh memory and for a crashed batch that can never
  be completed. `.Host_Managed` disables the check for a host that has been
  audited against the four rules in `src/effects.odin`.
])

`effects_requires_power_loss_barrier` returns true when the batch holds a
`Write_Promise`, `Write_Promise_At`, or `Write_Vote`. Decision and trim records
are derived facts that a host may persist with a cheaper barrier.
`effects_pre_durable_messages` returns a `Pre_Durable_Iterator(Value)`;
`pre_durable_next` yields only `Accept_Message` envelopes whose
`ballot_round` is above zero. A campaign accept may leave before the local
sync because it claims nothing about the sender's durable state and a
restarted proposer campaigns at a fresh ballot; an owner's round-zero
suggestion must wait, because its own vote is the only durable record that the
instance was used. `effects_is_empty` reports a transition that produced
nothing to do.

== Core API

In the signatures below `node` is `^Node($V, $M, $W, $C, $G)` and `effects` is
the matching `^Effects(V, M, W, C, G)`; `m` is `^Membership($MAX_MEMBERS)`;
`l` is `^Ledger($Value, $WINDOW)`; `e` is `^Effects($V, $M, $W, $C, $G)`; `bs`
is a `Bit_Set($N)`, by pointer where it is mutated. Transitions reset `effects`
before doing anything else.

=== Membership

#table(
  columns: (1.5fr, 1.5fr),
  table.header([*Proc*], [*Contract*]),
  [`membership_init(m, node_ids: []Node_Id, read_quorum_override: int = 0, write_quorum_override: int = 0) -> Error`],
    [Validate non-zero unique ids and quorum sizes; zero overrides mean majority. Errors leave `m` untouched.],
  [`membership_index_of(m, id: Node_Id) -> (int, bool)`],
    [The stable index of `id` (its rank, since members are sorted). Linear scan up to `LINEAR_LOOKUP_LIMIT` members, binary search above it.],
  [`membership_contains(m, id: Node_Id) -> bool`], [Membership test.],
  [`membership_count(m) -> int`], [Number of voters.],
  [`membership_get(m, index: int) -> Node_Id`], [The member at a stable index.],
  [`membership_slice(m) -> []Node_Id`], [Members in ascending id order.],
  [`membership_read_quorum(m) -> int`, `membership_write_quorum(m) -> int`],
    [Phase-one and phase-two quorum sizes.],
)

`Membership(MAX_MEMBERS)` holds `members` (a `Small_Array` sorted by id whatever
order the host listed them in; the position is the member's stable index, and
under rotating ownership the owner order), `read_quorum_size`, and
`write_quorum_size`.

=== Ballots, slots, and bit sets

#table(
  columns: (1.5fr, 1.5fr),
  table.header([*Proc*], [*Contract*]),
  [`ballot_make(round: u64, priority: u8, node: Node_Id) -> Ballot`],
    [Pack `round << 24 | priority << 16 | node` into one `distinct u64`, so `<` on `Ballot` orders round, then priority, then node.],
  [`ballot_round(b: Ballot) -> u64`, `ballot_priority(b: Ballot) -> u8`, `ballot_node(b: Ballot) -> Node_Id`],
    [Unpack the three fields.],
  [`cell_of(slot: Slot, $WINDOW: int) -> int`],
    [The window cell of a slot: `(slot - 1) & (WINDOW - 1)`.],
  [`slot_add(slot, offset: Slot) -> Slot`],
    [Add without wrapping past `max(Slot)`.],
  [`bit_set_insert(bs, index: int) -> bool`],
    [Insert; true when the index was absent.],
  [`bit_set_remove(bs, index: int)`, `bit_set_contains(bs, index: int) -> bool`, `bit_set_count(bs) -> int`, `bit_set_reset(bs)`],
    [Remove, test, cardinality, clear.],
  [`bit_set_next(bs, from: int) -> (int, bool)`],
    [The smallest member at or after `from`, by trailing-zero count per 64-bit word.],
  [`bit_set_last(bs) -> (int, bool)`], [The largest member.],
)

`Bit_Set(N)` is `[(N + WORD_BITS - 1) / WORD_BITS]Word` with `Word :: bit_set[0..<WORD_BITS]`
and `WORD_BITS :: 64`. `Ballot` constants: `BALLOT_ZERO`, `BALLOT_ROUND_BITS`
(40), and `MAX_ROUND` ($2^40 - 1$).

=== Ledger

#table(
  columns: (1.5fr, 1.5fr),
  table.header([*Proc*], [*Contract*]),
  [`ledger_promise_for(l, cell: int) -> Ballot`],
    [The effective promise for a cell: `max(promised, promised_at[cell])`.],
  [`ledger_cell(l, slot: Slot) -> (int, bool)`],
    [The cell and whether it currently holds `slot`.],
  [`ledger_vote_at(l, slot: Slot) -> (Ballot, ^Value, bool)`],
    [The vote in a `.Voted` cell for `slot`.],
  [`ledger_chosen_at(l, slot: Slot) -> (^Value, bool)`],
    [The decision in a `.Chosen` cell for `slot`.],
  [`ledger_is_chosen(l, slot: Slot) -> bool`], [Decision test.],
  [`ledger_open(l, cell: int, slot: Slot)`, `ledger_clear_cell(l, cell: int)`],
    [Retag a cell for `slot` (or for no slot), clearing everything but the value storage.],
  [`ledger_claim(l, slot: Slot) -> (int, bool)`],
    [Replay-time claim: reuse a cell only when its previous slot is chosen or at or below the anchor.],
  [`ledger_record_vote(l, cell: int, ballot: Ballot, value: Value)`, `ledger_record_chosen(l, cell: int, value: Value)`],
    [Store a vote or a decision and maintain the `used` and `chosen` bitmaps.],
  [`ledger_highest_ballot(l) -> Ballot`],
    [The greatest of the global promise, every per-decree promise, and every vote.],
  [`ledger_highest_used(l) -> Slot`], [The greatest slot held by any used cell.],
  [`ledger_apply(l, write: Write(Value)) -> Error`],
    [Strict single-configuration replay of one record (rules in Part VIII).],
  [`ledger_replay_fold(l, write: Write(Value)) -> Error`],
    [Lifetime replay across window reuse: promises fold to their maximum, a vote or per-decree promise whose cell a later slot owns is skipped, decisions and anchors stay strict.],
)

`Ledger(Value, WINDOW)` is struct-of-arrays: `promised: Ballot`,
`anchor: Trim_Anchor`, and per cell `slot`, `promised_at`, `vote_ballot`,
`state: Cell_State`, and `value`, plus the bitmaps `used` and `chosen`. The
host never copies it; it persists the five `Write` records and rebuilds the
struct by replay.

=== Node lifecycle and queries

#table(
  columns: (1.5fr, 1.5fr),
  table.header([*Proc*], [*Contract*]),
  [`node_init(node, id: Node_Id, membership: Membership(M), options := Node_Options{}) -> Error`],
    [Voting follower at slot 1; `.Not_Member` if `id` is not a voter.],
  [`node_init_learner(node, id: Node_Id, membership: Membership(M)) -> Error`],
    [Non-voting learner; an `id` inside the membership is `.Learner_Is_Voter`.],
  [`node_restore(node, id: Node_Id, membership: Membership(M), ledger: Ledger(V, W), floor: Slot = 0, options := Node_Options{}) -> Error`],
    [Rebuild from a replayed `Ledger`; open votes at or below `max(floor, anchor)` are dropped.],
  [`node_continue_at(node, id: Node_Id, membership: Membership(M), floor: Slot, anchor: Trim_Anchor, options := Node_Options{}) -> Error`],
    [Empty node resuming at `floor + 1` with an inherited anchor.],
  [`node_restore_learner(node, id: Node_Id, membership: Membership(M), ledger: Ledger(V, W)) -> Error`],
    [Learner from its decision-only journal.],
  [`node_begin_recovery(node, anchor: Trim_Anchor) -> Error`],
    [Install a certified prefix; keeps cells above the anchor, returns to `.Follower`, persists nothing.],
  [`node_advance_memory_floor(node, through: Slot) -> Error`],
    [Host has durably consumed the released prefix; `.Invalid_Slot` above `delivered_through`.],
  [`node_install_chosen_trim(node, anchor: Trim_Anchor, effects) -> Error`],
    [Adopt a chosen trim record, emitting `Write_Trim`.],
  [`node_set_campaign_enabled(node, enabled: bool)`, `node_is_campaign_enabled(node) -> bool`],
    [Toggle elections; disabling during `.Preparing` drops back to `.Follower`.],
  [`node_current_leader(node) -> (Node_Id, bool)`], [The leader hint, if any.],
  [`node_decided_through(node) -> Slot`], [Greatest contiguous slot released.],
  [`node_leader_base(node) -> Slot`], [First slot the current leadership may fill.],
  [`node_proposal_frontier(node) -> Slot`], [Slot the next proposal would take.],
  [`node_is_leader_caught_up(node) -> bool`],
    [`delivered_through >= leader_base - 1`; not a lease and not a read barrier.],
  [`node_memory_floor(node) -> Slot`, `node_trim_anchor(node) -> Trim_Anchor`],
    [Reuse floor and adopted anchor.],
  [`node_role(node) -> Role`, `node_ballot(node) -> Ballot`, `node_id(node) -> Node_Id`, `node_is_voting_member(node) -> bool`],
    [Plain accessors. `Role` is `enum u8 { Follower, Preparing, Leader }`.],
  [`node_ledger(node) -> ^Ledger(V, W)`],
    [Inspection only; persistence goes through `Write` records.],
  [`node_resubmits_dropped(node) -> u32`],
    [Losing suggestions that could not be queued for resubmission (the queue holds one chunk). Resubmission is best effort; the host retries these.],
  [`node_committed_at(node, slot: Slot) -> (V, bool)`],
    [A resident decided value, by copy.],
  [`node_read_decided(node, from_slot: Slot, output: []Committed(V)) -> (int, Error)`],
    [Copy the released suffix; `.Trimmed` at or below the floor, `.Read_Buffer_Too_Small`.],
)

=== Node transitions

#table(
  columns: (1.5fr, 1.5fr),
  table.header([*Proc*], [*Contract*]),
  [`node_campaign(node, noop: V, effects) -> Error`],
    [Start phase one; `.Not_Voter`, or `.Campaign_Disabled` when disabled or under rotating ownership.],
  [`node_propose(node, value: V, effects) -> (slot: Slot, err: Error)`],
    [Assign the next slot (or the next own slot) and send accepts; `.Not_Leader`, `.Leader_Catching_Up`, `.Window_Full`.],
  [`node_propose_batch(node, values: []V, slots: []Slot, effects) -> (assigned: []Slot, err: Error)`],
    [Up to `CHUNK_SLOTS` values into consecutive slots (consecutive own slots under ownership), all or none.],
  [`node_tick(node, noop: V, effects) -> Error`],
    [Advance the election, heartbeat, and resend timers by one; under ownership, skips, resubmissions, and stall detection.],
  [`node_step(node, envelope: Envelope(V), effects) -> Error`],
    [Process one authenticated envelope addressed to this node.],
  [`node_learn_chosen(node, from: Node_Id, slot: Slot, value: V, effects) -> Error`],
    [Learner-only: install a host-certified decision; a voter gets `.Not_Learner`.],
  [`node_reconnected(node, peer: Node_Id, effects) -> Error`],
    [Repair one peer path: a leader resends, a follower asks its leader to teach.],
  [`node_request_catch_up(node, peer: Node_Id, from_slot: Slot, effects) -> Error`],
    [Emit one chunk-bounded `Learn_Message`.],
  [`owner_of(node, slot: Slot) -> Node_Id`],
    [The member that owns `slot`: `membership_get(m, (slot - 1) mod N)`.],
  [`ownership_ballot(owner: Node_Id) -> Ballot`],
    [`ballot_make(0, 0, owner)`, the round-zero ballot no campaign ever uses.],
)

=== Effects

#table(
  columns: (1.5fr, 1.5fr),
  table.header([*Proc*], [*Contract*]),
  [`effects_init(e)`], [Discard without checking the gate (fresh memory, crashed batch).],
  [`effects_reset(e)`], [Empty for the next transition; stops the process on unconfirmed writes under `.Enforced`.],
  [`effects_confirm_writes_durable(e)`], [Every write is appended and synced.],
  [`effects_writes_slice(e) -> []Write(V)`], [Durable records, in order.],
  [`effects_messages_slice(e) -> []Envelope(V)`], [Outbound envelopes; stops the process while writes are pending under `.Enforced`.],
  [`effects_committed_slice(e) -> []Committed(V)`], [Newly decided entries, contiguous.],
  [`effects_requests_slice(e) -> []Host_Request`], [History a peer asked for.],
  [`effects_requires_power_loss_barrier(e) -> bool`], [The batch holds a promise or a vote.],
  [`effects_pre_durable_messages(e) -> Pre_Durable_Iterator(V)`, `pre_durable_next(it: ^Pre_Durable_Iterator($Value)) -> (Envelope(Value), bool)`],
    [The accept-only iterator for campaign ballots.],
  [`effects_is_empty(e) -> bool`], [All four lists are empty.],
  [`effects_add_write(e, w: Write(V))`, `effects_add_message(e, envelope: Envelope(V))`, `effects_add_committed(e, c: Committed(V))`, `effects_add_request(e, r: Host_Request)`],
    [Producers used by the node; a full list is an assertion failure, never backpressure.],
)

=== Proc groups

`src/paxos.odin` folds these into proc groups dispatched on the receiver type:
`init`, `init_learner`, `restore`, `restore_learner`, `continue_at`,
`begin_recovery`, `campaign`, `propose`, `propose_batch`, `step`, `tick`,
`reconnected`, `request_catch_up`, `learn_chosen`, `set_campaign_enabled`,
`advance_memory_floor`, `install_chosen_trim`, `current_leader`,
`decided_through`, `leader_base`, `proposal_frontier`, `committed_at`,
`read_decided`, `is_leader_caught_up`, `is_campaign_enabled`, `memory_floor`,
`trim_anchor`, `role`, `ballot`, `id`, `is_voting_member`, `resubmits_dropped`, and
`ledger`.
`init` also covers `effects_init`, `membership_init`, and `stop_sign_init`;
`step` covers both replicated-log overloads; `committed_at` covers
`replicated_log_read` and `learner_chosen_at`; `read_decided` covers
`learner_read_chosen`; `learn_chosen` covers `learner_learn_chosen`. The
effects verbs drop their prefix: `reset`, `confirm_writes_durable`,
`writes_slice`, `messages_slice`, `committed_slice`, `requests_slice`,
`requires_power_loss_barrier`, `pre_durable_messages`, `is_empty`. The
long spellings remain available when a call site wants to name its receiver.

== Replicated-log API

`Replicated_Log_Node(Value, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS,
MAX_METADATA_BYTES, GATE)` wraps a core node whose value type is
`Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)`, a union of `Value` and
`Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES)`. The matching effects type is
`Effects(Entry(...), MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE)`. A
`Stop_Sign` holds `configuration_id`, a `members` small array, and opaque
`metadata` bytes; `stop_sign_init(ss, configuration_id, members, metadata)`
and `stop_sign_create(T, configuration_id, members, metadata)` validate it,
`stop_sign_validate_members(members, $MAX_MEMBERS)` checks a bare member
slice, and `stop_sign_members_slice` and `stop_sign_metadata_slice` read it
back. `Log_Envelope(Value, MAX_MEMBERS, MAX_METADATA_BYTES)` pairs a core
envelope with the `configuration_id` it was sent under.

#table(
  columns: (1.35fr, 1.65fr),
  table.header([*Proc (short spelling)*], [*Contract*]),
  [`replicated_log_init(node, id, configuration_id, membership, options := Node_Options{}) -> Error` (`log_init`)],
    [Voting member of a non-zero configuration.],
  [`replicated_log_init_learner(node, id, configuration_id, membership) -> Error` (`log_init_learner`)],
    [Non-voting learner of that configuration.],
  [`replicated_log_init_from_stop(node, id, stop, stop_slot, anchor, options := Node_Options{}) -> Error` (`log_init_from_stop`)],
    [Start the configuration a decided stop sign names, at `stop_slot + 1`; a removed voter gets `.Not_Member`.],
  [`replicated_log_continue_at(node, id, configuration_id, membership, floor, anchor, options := Node_Options{}) -> Error` (`log_continue_at`)],
    [Empty node resuming at `floor + 1`.],
  [`replicated_log_restore(node, id, configuration_id, membership, ledger, floor := 0, options := Node_Options{}) -> Error` (`log_restore`)],
    [Replayed restore; rediscovers a decided seal from the chosen cells.],
  [`replicated_log_restore_learner(node, id, configuration_id, membership, ledger) -> Error` (`log_restore_learner`)],
    [Learner restore.],
  [`replicated_log_begin_recovery(node, anchor) -> Error` (`log_begin_recovery`)],
    [Install a state image; forgets a decided seal and rediscovers it from what remains.],
  [`replicated_log_propose(node, value, effects) -> (Slot, Error)` (`log_propose`)],
    [Propose a command; `.Log_Sealed` once a stop is pending or decided.],
  [`replicated_log_propose_batch(node, values, slots, effects) -> ([]Slot, Error)` (`log_propose_batch`)],
    [At most `CHUNK_SLOTS` commands in one batch, else `.Batch_Too_Large`.],
  [`replicated_log_propose_stop_sign(node, next_configuration_id, next_members, metadata, effects) -> (Slot, Error)` (`log_propose_stop_sign`, `log_reconfigure`)],
    [Propose the seal; a next id that is not strictly greater is `.Configuration_Id_Regression`.],
  [`replicated_log_campaign(node, noop, effects) -> Error`, `replicated_log_tick(node, noop, effects) -> Error` (`log_campaign`, `log_tick`)],
    [Core transitions with the `Value` no-op wrapped as an `Entry`.],
  [`replicated_log_step(node, envelope, effects) -> Error`, `replicated_log_step_checked(node, message, effects) -> Error` (`log_step`)],
    [Bare envelope, or a `Log_Envelope` whose id must match; a mismatch is `.Configuration_Mismatch` with no effects.],
  [`replicated_log_envelope(node, envelope) -> Log_Envelope` (`log_envelope`)],
    [Stamp an outbound envelope with the local configuration id.],
  [`replicated_log_learn_chosen(node, from, slot, entry, effects) -> Error` (`log_learn_chosen`)],
    [Learner-only certified decision.],
  [`replicated_log_reconnected`, `replicated_log_request_catch_up`, `replicated_log_advance_memory_floor`, `replicated_log_install_chosen_trim`, `replicated_log_set_campaign_enabled`],
    [Pass-throughs to the core (`log_reconnected`, `log_request_catch_up`, `log_advance_memory_floor`, `log_install_chosen_trim`).],
  [`replicated_log_is_sealed(node) -> bool` (`log_is_sealed`)],
    [A stop sign is pending or decided.],
  [`replicated_log_stop_sign(node) -> (Stop_Sign, bool)` (`log_stop_sign`, `log_is_reconfigured`)],
    [The decided seal, which alone licenses handover.],
  [`replicated_log_stop_slot(node) -> Slot` (`log_stop_slot`)], [Its slot, or zero.],
  [`replicated_log_pending_stop_sign(node) -> (Stop_Sign, bool)` (`log_pending_stop_sign`)],
    [A decided seal first, else one retained in any used cell.],
  [`replicated_log_read(node, slot) -> (Entry, bool)`, `replicated_log_read_decided(node, from_slot, output) -> (int, Error)` (`log_read`, `log_read_decided`)],
    [Resident decided entries.],
  [`replicated_log_decided_through`, `replicated_log_leader_base`, `replicated_log_proposal_frontier`, `replicated_log_memory_floor`, `replicated_log_trim_anchor`, `replicated_log_current_leader`, `replicated_log_is_leader_caught_up`],
    [Frontier queries (`log_decided_through`, `log_leader_base`, `log_proposal_frontier`, `log_memory_floor`, `log_trim_anchor`, `log_current_leader`).],
  [`replicated_log_configuration_id(node) -> u64` (`log_configuration_id`)],
    [The host-supplied configuration identity.],
  [`replicated_log_role`, `replicated_log_ballot`, `replicated_log_id`, `replicated_log_is_voting_member`, `replicated_log_is_campaign_enabled`],
    [Accessors mirroring the core.],
  [`replicated_log_ledger(node) -> ^Ledger(Entry(...), WINDOW_SLOTS)`],
    [The core ledger, for inspection.],
)

== Learner API

`Learner(Value, MAX_ENTRIES)` is the standalone non-voting window for hosts
that certify decisions themselves. It stores `configuration_id`, a ring of
`Learner_Cell(Value)` (`slot`, `value`; slot zero marks an empty cell), and
`released_through`.

#table(
  columns: (1.35fr, 1.65fr),
  table.header([*Proc*], [*Contract*]),
  [`learner_init(l, configuration_id: u64) -> Error`],
    [`.Invalid_Configuration_Id` for zero.],
  [`learner_learn_chosen(l, configuration_id: u64, slot: Slot, value: Value) -> (Learn_Result, Error)` (`learner_step`)],
    [Record one certified value. Errors: `.Configuration_Mismatch`,
    `.Invalid_Slot`, `.Conflicting_Chosen_Value`, `.Window_Full` when
    `slot - released_through > MAX_ENTRIES`.],
  [`learner_read_chosen(l, from_slot: Slot, output: []Chosen_Value(Value)) -> (int, Error)` (`learner_read`)],
    [Copy the released suffix; `.Trimmed` once the ring has wrapped past it.],
  [`learner_chosen_at(l, slot: Slot) -> (Value, bool)` (`learner_get`)],
    [One released value still resident.],
  [`learner_cell_index(slot: Slot, $MAX_ENTRIES: int) -> int`],
    [`(slot - 1) mod MAX_ENTRIES`.],
)

`Learn_Result` has three values: `.Buffered` (recorded, a gap below it holds
release), `.Advanced` (the contiguous prefix moved past it), and `.Duplicate`
(already released or buffered). `Chosen_Value(Value)` pairs `slot` and `value`
in the output buffer.

== Options, constants, and capacities

`Node_Options` is a plain struct whose zero value selects every default:
`priority: u8` (breaks ballot ties, higher wins), `election_timeout_ticks`,
`heartbeat_interval_ticks`, `resend_interval_ticks` (each `u32`, zero means
the default), `gate_proposals_on_inherited_prefix: bool` (refuse proposals
with `.Leader_Catching_Up` until the inherited prefix is delivered),
`campaign_disabled: bool` (an acceptor that promises and votes but never
campaigns), and `rotating_ownership: bool` (every member proposes in its own
slots without phase one; campaigns are refused; stalls are repaired by bounded
revocations).

#table(
  columns: (auto, auto, 1fr),
  table.header([*Constant*], [*Value*], [*Role*]),
  [`DEFAULT_MAX_MEMBERS`], [7], [Voter capacity of `Membership`, `Node`, `Effects`, `Stop_Sign`.],
  [`MAX_SUPPORTED_MEMBERS`], [65535], [Ceiling on `MAX_MEMBERS`: member indexes and the ballot's node field are 16 bits.],
  [`LINEAR_LOOKUP_LIMIT`], [8], [Memberships up to this size use a linear scan; larger ones binary-search the sorted members.],
  [`DEFAULT_WINDOW_SLOTS`], [256], [Resident consensus cells per node; must be a power of two.],
  [`DEFAULT_CHUNK_SLOTS`], [64], [Recovery chunk and batch bound; `1 <= CHUNK_SLOTS <= WINDOW_SLOTS`.],
  [`DEFAULT_MAX_METADATA_BYTES`], [256], [Stop-sign metadata capacity.],
  [`DEFAULT_MAX_ENTRIES`], [256], [`Learner` ring capacity.],
  [`DEFAULT_ELECTION_TIMEOUT_TICKS`], [10], [Follower ticks without leader contact before campaigning; owner ticks without progress before a revocation.],
  [`DEFAULT_HEARTBEAT_INTERVAL_TICKS`], [3], [Leader ticks between heartbeats.],
  [`DEFAULT_RESEND_INTERVAL_TICKS`], [10], [Ticks between retransmission scans.],
  [`SKIP_BURST`], [8], [Most no-op skips an idle owner sends per tick (also bounded by `CHUNK_SLOTS`).],
  [`BALLOT_ROUND_BITS`], [40], [Width of the round field; `MAX_ROUND` is $2^40 - 1$.],
  [`WORD_BITS`], [64], [Bits per `Bit_Set` word.],
  [`INVARIANT_CHECKS`], [`ODIN_DEBUG`], [`#config(PAXOS_INVARIANT_CHECKS, ODIN_DEBUG)`: internal assertions in debug builds; `-define:PAXOS_INVARIANT_CHECKS=true` enables them in release.],
)

`Effects` is sized to the exact per-transition maxima, so the library never
allocates and a full list is a bug rather than backpressure:

#table(
  columns: (auto, auto, 1fr),
  table.header([*List*], [*Capacity*], [*Why the bound holds*]),
  [`writes`], [`2 * CHUNK_SLOTS + 1`],
    [One transition drives at most one chunk of slots (`resolve_chunk`,
    `node_propose_batch`). Each slot costs one `Write_Vote`, followed by a
    `Write_Chosen` when the write quorum is one; `on_prepare` and
    `on_heartbeat` add at most one `Write_Promise`, and `promise_bounded` at
    most one `Write_Promise_At` per slot of the chunk.],
  [`messages`], [`MAX_MEMBERS * CHUNK_SLOTS + 2 * MAX_MEMBERS + 1`],
    [One chunk per peer (accepts or commits for `CHUNK_SLOTS` slots to every
    peer, or `CHUNK_SLOTS` promises to one candidate), plus one broadcast of
    prepares or heartbeats, plus one `Promise_Range_Message` or one
    `Learn_Message`.],
  [`committed`], [`WINDOW_SLOTS + 1`],
    [`emit_contiguous` can release every resident cell, and `record_commit`
    can pass one further entry straight through when its cell is unavailable.],
  [`requests`], [`MAX_MEMBERS`],
    [`on_learn` emits at most one `Serve_Range_Request` per transition; the
    bound allows one per peer.],
)

== State lifetime

A node begins in `.Follower` with `next_slot = leader_base = 1`.
`node_campaign` (or an election timeout in `node_tick`) runs `start_campaign`:
the ballot becomes
`ballot_make(max(highest_observed_round, ballot_round(ballot), ballot_round(ledger_highest_ballot(ledger))) + 1, priority, id)`,
the role becomes `.Preparing`, the election scratch (`election`,
`promise_seen`, `recover_base`, the `recovered_*` and `lead_*` columns,
`acknowledgements`, `acknowledged`) is cleared, and a `Prepare_Message` with
`first = delivered_through + 1`, `last = slot_add(first, CHUNK_SLOTS - 1)`,
and `scope = .Global` goes to every member. `maybe_resolve_chunk` waits until
a read quorum has described the chunk completely; `resolve_chunk` re-drives
every slot from the fence up; when no peer reports `more`, `become_leader`
sets `.Leader`, `leader_hint = id`,
`next_slot = leader_base = max(next_slot, slot_add(max(ledger_highest_used, fences), 1))`,
and releases any contiguous prefix. A `Nack_Message` for the current ballot,
with a greater promised ballot makes the node step down. A message handler can also call
`observe_leader`, which demotes when the observed ballot differs from the local
ballot. Its promise and role checks determine whether that call is reached.

Under rotating ownership `node_campaign` is refused; `tick_ownership` starts a
`start_revocation` after `election_timeout_ticks` ticks without progress,
sending a `.Bounded` prepare over the stalled chunk; `become_leader` then
returns the node to `.Follower` once the chunk is driven, so there is no
standing leader.

#table(
  columns: (auto, 1fr, 1.15fr),
  table.header([*Entry*], [*Keeps*], [*Clears or rebuilds*]),
  [`node_restore`],
    [`promised`, `anchor`, every chosen cell, and every open vote above the
    base, which is the greater of `floor` and the anchor's
    `chosen_trim_slot`.],
    [Open votes at or below the base; role, ballot, hint, timers, and the
    election scratch. `memory_floor` and `delivered_through` become the base;
    `next_slot` and `leader_base` become one above the highest used slot or
    the base; `own_next` is recomputed.],
  [`node_continue_at`],
    [Only the inherited `anchor`, which must not exceed `floor`; otherwise
    `.Trim_Regression`.],
    [Everything else; the window resumes at `floor + 1`.],
  [`node_begin_recovery`],
    [`id`, `membership`, options, `promised`, and every cell above the
    anchor's `chosen_trim_slot`.],
    [Cells at or below the anchor, the leader hint, timers,
    `peer_decided_through`, `resend_cursor`, and the election scratch; the
    role becomes `.Follower`. The anchor must pass the regression checks of
    `ledger_apply`.],
  [`node_restore_learner`],
    [The decision-only `ledger` and its anchor.],
    [Voting state; the floor is the anchor's `chosen_trim_slot`.],
)

The replicated-log wrappers add `configuration_id`, reset the seal fields
(`stop_sign`, `stop_slot`, `stop_pending`), and, for `restore`,
`restore_learner`, and `begin_recovery`, rediscover a decided seal by scanning
chosen cells for a stop sign that names a newer configuration.

== Error reference

`Error` has forty-two values besides `.None`, grouped below as in
`src/errors.odin`. `explain_error(err)` returns an operator-facing block with
the problem and a hint. Class: *input* means the call was wrong and nothing
changed; *backpressure* means retry later; *terminal* means this log or epoch
cannot continue; *incident* means a safety assumption broke and the node must
stop with its evidence preserved.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Value*], [*Class*], [*Meaning*]),
  table.cell(colspan: 3)[_Membership_],
  [`.Empty_Membership`], [input], [No voter ids were given.],
  [`.Too_Many_Members`], [input], [More ids than `MAX_MEMBERS`.],
  [`.Invalid_Node_Id`], [input], [Id zero is the reserved sentinel.],
  [`.Duplicate_Node_Id`], [input], [One id appears twice.],
  [`.Invalid_Read_Quorum`], [input], [Override outside `1..=N`.],
  [`.Invalid_Write_Quorum`], [input], [Override outside `1..=N`.],
  [`.Non_Intersecting_Quorums`], [input], [`read + write <= N`; a phase-one quorum could miss a phase-two quorum.],
  table.cell(colspan: 3)[_Input and addressing_],
  [`.Not_Member`], [input], [Sender, peer, or local id is outside the membership.],
  [`.Wrong_Recipient`], [input], [`envelope.to` is not this node.],
  [`.Invalid_Peer`], [input], [`node_reconnected` targeted the local node.],
  [`.Invalid_Slot`], [input], [Slot zero; a prepare with `last < first`; a `Learn_Message` count outside `1..=CHUNK_SLOTS`; a floor or trim claim above `delivered_through`.],
  [`.Read_Buffer_Too_Small`], [input], [Output cannot hold `decided_through - from_slot + 1` entries.],
  [`.Unknown_Node`], [input], [Reserved for host routers; the core never returns it.],
  table.cell(colspan: 3)[_Role and capability_],
  [`.Not_Voter`], [input], [A campaign or proposal on a learner.],
  [`.Not_Learner`], [input], [`node_learn_chosen` on a voter.],
  [`.Learner_Is_Voter`], [input], [Learner id lies inside the membership.],
  [`.Learner_Message_Forbidden`], [input], [A learner received anything but a commit.],
  [`.Configuration_Mismatch`], [input], [`Log_Envelope` id differs from the local one; the batch is empty.],
  table.cell(colspan: 3)[_Liveness and progress_],
  [`.Not_Leader`], [backpressure], [Phase one has not completed for this ballot.],
  [`.Leader_Catching_Up`], [backpressure], [Inherited slots below `leader_base` are still undelivered (only with the gate option).],
  [`.Window_Full`], [backpressure], [`next_slot - memory_floor` (or the next own slot) would exceed `WINDOW_SLOTS`, or a learner slot is beyond its ring.],
  [`.Global_Slot_Exhausted`], [terminal], [The `u64` slot line is spent; it never wraps.],
  [`.Empty_Batch`], [input], [A batch with no values.],
  [`.Slot_Buffer_Too_Small`], [input], [Fewer output slots than values.],
  [`.Ballot_Exhausted`], [terminal], [No round above `MAX_ROUND`.],
  [`.Invalid_Promise`], [input], [A `Promise_Message` with `state = .Empty`, or a `Promise_Range_Message` with `last < first`, a wrong chunk limit, or `reported > CHUNK_SLOTS`.],
  [`.Missing_Noop`], [input], [A chunk resolved without a no-op from `campaign` or `tick`.],
  [`.Missing_Proposed_Value`], [incident], [A quorum acknowledged a slot whose cell the leader holds with no vote (a stale acknowledgement for a cell that moved on is ignored instead).],
  [`.Campaign_Disabled`], [backpressure], [This voter never starts elections, or runs rotating ownership.],
  table.cell(colspan: 3)[_Durability and safety_],
  [`.Promise_Regression`], [incident], [Replay moved a promise, or recorded a vote, below the durable promise.],
  [`.Conflicting_Value`], [incident], [One ballot and slot carry two values.],
  [`.Conflicting_Commit`], [incident], [One slot observed two chosen values.],
  [`.Conflicting_Chosen_Value`], [incident], [A learner saw two chosen values for one slot.],
  [`.Trim_Regression`], [incident], [A trim anchor moved backward or contradicts the adopted one.],
  table.cell(colspan: 3)[_Replicated log and window_],
  [`.Invalid_Configuration_Id`], [input], [Configuration id zero.],
  [`.Metadata_Too_Large`], [input], [Stop metadata above `MAX_METADATA_BYTES`.],
  [`.Log_Sealed`], [backpressure], [A stop sign is pending or decided; finish the handover.],
  [`.Batch_Too_Large`], [input], [More than `CHUNK_SLOTS` values.],
  [`.Configuration_Id_Regression`], [input], [The next id is not greater than the current one.],
  [`.Configuration_Id_Exhausted`], [terminal], [Reserved for hosts that allocate ids; the library never returns it.],
  [`.Window_Overrun`], [incident], [A record, or a leader's own proposal, addresses a cell still holding an earlier open slot.],
  [`.Trimmed`], [backpressure], [The slot was released at or below the floor; read it from the host journal.],
)

== Formula sheet

#table(
  columns: (1fr, auto, 1.35fr),
  table.header([*Quantity*], [*Formula*], [*Where it lives*]),
  [Majority], [$floor(N \/ 2) + 1$], [`membership_init`: `total / 2 + 1`.],
  [Crashes a majority tolerates], [$N - (floor(N \/ 2) + 1)$], [Five voters survive two.],
  [Flexible quorum safety], [$|Q_1| + |Q_2| > N$], [`membership_init` refuses otherwise.],
  [Ballot packing], [`round << 24 | priority << 16 | node`],
    [`ballot_make`; 40, 8, and 16 bits, so `<` on `Ballot` is B1.],
  [Cell index], [`(slot - 1) & (W - 1)`],
    [`cell_of`; `W` is `WINDOW_SLOTS`, a power of two. `learner_cell_index`
    uses `(slot - 1) mod MAX_ENTRIES`.],
  [Recovery index], [`slot - recover_base`],
    [`recovery_index` checks range before subtraction; scratch has `CHUNK_SLOTS`
    entries and does not use the ledger mask.],
  [Owner of a slot], [$("slot" - 1) mod N$],
    [`owner_of`, an index into the membership order; the owner's ballot is
    `ballot_make(0, 0, owner)`.],
  [Stable-path messages per value], [$3(N - 1)$],
    [`send_accept` broadcasts $N - 1$ accepts; each `on_accept` answers once;
    `on_accepted` broadcasts $N - 1$ commits exactly once.],
  [Acknowledgements a commit waits for], [$|Q_2| - 1$ replies],
    [`send_accept` counts the leader's own vote first.],
  [Window backpressure], [$"next_slot" - "memory_floor" <= "WINDOW_SLOTS"$],
    [`node_propose`. A batch must fit in the free cells: `WINDOW_SLOTS`
    minus the occupied count `next_slot - 1 - memory_floor`.],
  [Recovery chunk], [$["first", "first" + "CHUNK_SLOTS" - 1]$],
    [`start_campaign`, `begin_next_chunk`; `slot_add` saturates at
    `max(Slot)`. A revocation caps `last` at `highest_seen`.],
  [Effects capacities], [$2C + 1$, $M C + 2M + 1$, $W + 1$, $M$],
    [Writes, messages, committed, requests; $C$, $M$, $W$ are the chunk,
    member, and window bounds.],
)

== Invariants for review

1. Ballots are unique and totally ordered: `Ballot` is one packed `u64`
   compared as an integer, round above priority above node; `start_campaign`
   stamps `node.id` and picks a round above every round the node has
   promised, voted, or observed; round zero is reserved for slot owners.
2. Every read quorum meets every write quorum: `membership_init` returns
   `.Non_Intersecting_Quorums` unless `read + write > N`.
3. No vote below the promise: `on_accept` answers a ballot below `promised`
   or below `promised_at[cell]` with a nack; `ledger_apply` refuses a
   `Write_Vote` below either with `.Promise_Regression`.
4. One value per ballot and slot: `on_accept` and `ledger_apply` return
   `.Conflicting_Value`; `send_accept` never replaces a live proposal at the
   same ballot with another value.
5. The greatest vote wins: `on_promise` keeps the highest-ballot vote per
   slot, and a reported decision dominates; `resolve_chunk` re-proposes it,
   or the no-op for a true hole, only after `maybe_resolve_chunk` has a read
   quorum of complete chunk descriptions. `recovery_ready` freezes the selected
   values before phase two, including across retries at the window boundary.
6. Chosen means a write quorum of distinct voters: `on_accepted` inserts the
   member index into `acknowledgements[cell]` and counts `acknowledged[cell]`
   against `membership_write_quorum`; a duplicate never counts twice.
7. A decided slot never changes: `record_commit` and `ledger_apply` return
   `.Conflicting_Commit`.
8. Release is a contiguous prefix: `emit_contiguous` advances
   `delivered_through` one slot at a time and stops at the first gap.
9. Persist before send: `effects_add_write` raises `writes_pending`;
   `effects_messages_slice` and `effects_reset` stop the process while it is
   raised under `.Enforced`.
10. Within a configuration, a decided slot is never assigned a second value,
    and live cells are retagged only for released history: `claim_live` reuses a cell only when its old slot is chosen and
    at or below `memory_floor`; `ledger_claim` also accepts slots at or below
    the anchor; `resolve_chunk` starts above `quorum_fences`.

== Answers to selected exercises

=== Exercise 1.1
With voters `{1, 2, 3, 4}`, the sets `{1, 2}` and `{3, 4}` share no member.
Suppose both were legal quorums. Node 1 campaigns with ballot `(1, 0, 1)`
while a partition separates `{1, 2}` from `{3, 4}`; nodes 1 and 2 promise, node
1 proposes `x` for slot 1, and both vote, so `x` is chosen by `{1, 2}`.
Meanwhile node 3 campaigns with `(1, 0, 3)`; nodes 3 and 4 promise, having
voted for nothing, and node 3 proposes `y`; both vote and `y` is chosen by
`{3, 4}`. Slot 1 now has two chosen values: agreement fails, because no member
of the second quorum could carry the first quorum's vote into phase one. The
library refuses the configuration before any of this can happen:
`membership_init` with overrides `2, 2` returns `.Non_Intersecting_Quorums`
since `2 + 2 <= 4`, and the default majority of four is three.

=== Exercise 2.1
`ballot_make` packs the round into bits 63 through 24, the priority into bits
23 through 16, and the node into bits 15 through 0, so integer comparison on
`Ballot` orders round, then priority, then node. The ascending order is
`(1, 5, 1) < (1, 5, 3) < (2, 0, 1) < (2, 0, 3)` and `(2, 0, 3)` wins. Round
sits first because it is the freshness counter: every campaign takes a round
above everything the node has seen, so a new attempt always outranks an old
one, whatever its priority. Priority sits second so an operator can prefer one
node within a round without ever letting a stale high-priority ballot outlive
fresh ones; if priority came first, a promise to a crashed high-priority node
would block every lower-priority candidate at every future round. The node id
comes last purely to make ballots unique.

=== Exercise 4.1
The promise for `(5, 0, 2)` never became durable, so on restart
`ledger_replay_fold` rebuilds `promised` without it, and nothing about
`(5, 0, 2)` was ever transmitted: under `.Enforced`, `effects_messages_slice`
stops the process while a write is pending, so the `Promise_Range_Message`
for ballot `(5, 0, 2)` could not have left. No peer holds evidence of the lost
promise. `on_prepare` therefore compares `(4, 0, 3)` with the replayed promise,
finds it not lower, records `Write_Promise{(4, 0, 3)}`, and answers with the
chunk. The deciding rule is the first of the host contract: every write of a
transition is durable before any message of that transition reaches a peer. Had
the sync completed, replay would restore `(5, 0, 2)` and `on_prepare` would
send `Nack_Message{rejected = (4, 0, 3), promised = (5, 0, 2), slot = 0}`
instead.

=== Exercise 4.2
Claim: if a write quorum $Q$ voted for $v$ at ballot $b$ in slot $s$, then
every `Accept_Message` for $s$ at any ballot $b' > b$ carries $v$. Induct on
$b'$ in ballot order, assuming the claim for every ballot strictly between
$b$ and $b'$. The leader at $b'$ proposes for $s$ only after
`maybe_resolve_chunk` saw complete chunk descriptions from a read quorum $R$.
By `membership_init`, $R$ and $Q$ share some acceptor $a$. Acceptor $a$'s
promise to $b'$ was recorded after its vote at $b$: had the promise come first,
`on_accept` would have nacked ballot $b < b'$, because `promised` never
decreases (`ledger_apply` rejects `.Promise_Regression`). So when $a$ answered
`Prepare_Message` for $b'$, its cell for $s$ held a vote at some ballot $c$
with $b <= c < b'$: at least $b$, since `on_accept` only replaces a vote with a
higher ballot, and below $b'$, since after promising $b'$ it accepts nothing
lower and the promise reflects the state at that moment. If $c = b$ the value is
$v$; if $b < c < b'$ the induction hypothesis says the accept at $c$ carried
$v$. `on_promise` keeps the highest-ballot vote per slot across $R$; that
highest ballot is at least $c$ and below $b'$, so by the same argument its
value is $v$, and `resolve_chunk` re-proposes exactly that value. The no-op
branch is unreachable because $a$ reported a vote, and a cell reported with
`state = .Chosen` names a chosen value, which is $v$ by agreement.

=== Exercise 8.1
Write $A_3$ for the accept at `(3, 0, 1)` with value $x$ and $A_4$ for the
accept at `(4, 0, 2)` with value $y$. Each acceptor sees one of two orders.
$A_3$ then $A_4$: `on_accept` finds `(3, 0, 1)` not below its promise, records
`Write_Vote`, answers `Accepted_Message` to node 1; then `(4, 0, 2)` is not
below `(3, 0, 1)`, so it overwrites the vote, records another `Write_Vote`,
and answers `Accepted_Message` to node 2. $A_4$ then $A_3$: it votes $y$ and
raises the cell's `promised_at` to `(4, 0, 2)`; then `(3, 0, 1)` is below that
promise, so it sends `Nack_Message{rejected = (3, 0, 1), promised = (4, 0, 2)}`
with the slot, and node 1, on `on_nack`, drops to `.Follower`. An acceptor that
already promised `(4, 0, 2)` during node 2's phase one nacks $A_3$ in either
order. Every acceptor that receives $A_4$ at all votes $y$, so $y$ is chosen in
every arrival order once two acceptors receive it. $x$ could be chosen only if
two acceptors saw $A_3$ before promising `(4, 0, 2)`; but node 2 needed
promises from two acceptors, one of which would then have reported $x$ at
ballot `(3, 0, 1)`, and `resolve_chunk` would have made $A_4$ carry $x$,
contradicting the premise. So only $y$ can be chosen, and if $x$ ever reached a
quorum both accepts would carry the same value.

=== Exercise 11.1
Say slots 1 through 9 are delivered. The next candidate sends
`Prepare_Message{first = 10, last = 10 + CHUNK_SLOTS - 1, scope = .Global}`.
The acceptor holding the slot-10 vote answers
`Promise_Message{slot = 10, state = .Voted}` and a `Promise_Range_Message`
with `reported = 1`; the one holding slot 12 answers likewise for 12; the
others report `reported = 0`. Once a read quorum has described the chunk,
`resolve_chunk` computes the fence as 9, starts at slot 10, and bounds the
drive at `known_high = 12`. Slot 10 has a recovered vote
(`recovered_state = .Voted`), so `send_accept` re-proposes its value under the
new ballot; slot 11 has no vote, so `send_accept` carries the campaign's
no-op; slot 12 re-proposes the recovered value. `become_leader` then sets
`next_slot = leader_base = 13`. If the read quorum happens to miss the single
acceptor that voted in 10 or 12, that slot looks like a hole and gets the no-op
too, which is safe because a lone vote is not a choice; if the old leader's own
durable vote is in the quorum, it is reported like any other.

=== Exercise 14.1
Elections with two of five down need $Q_1 <= 3$; safety needs
$Q_1 + Q_2 > 5$, so $Q_2 >= 3$. The cheapest commit compatible with both is
$Q_1 = Q_2 = 3$, the majority pair, which `membership_init(&m, ids)` selects
by default and `3 + 3 = 6 > 5` satisfies. A commit then waits for two
`Accepted_Message`s beyond the leader's own vote, and message count is
unchanged at $3(N - 1) = 12$ per value, since `broadcast_peers` always writes
to every peer; quorum size changes latency, not traffic. The genuinely cheaper
setting $Q_2 = 2$ forces $Q_1 = 4$: a commit waits for one reply, but an
election needs four live voters, so a single crash is the most the cluster
can lose and still elect.

== Glossary

#table(
  columns: (auto, 1fr),
  table.header([*Term*], [*Meaning*]),
  [Ballot], [One `u64` packing `(round, priority, node)`, the unique, totally ordered name of one proposal attempt.],
  [Ledger], [`Ledger(Value, WINDOW)`: the acceptor's durable state in Lamport's variables, laid out as struct-of-arrays and rebuilt by replaying `Write` records.],
  [Cell], [One index of the window, `cell_of(slot, WINDOW)`, tagged by `slot[c]` with the slot it currently holds and by `state[c]` with `.Empty`, `.Voted`, or `.Chosen`.],
  [Chosen], [A write quorum has durably voted for one value in one slot; true before anyone knows it. A cell whose `state` is `.Chosen` records a known decision (`Write_Chosen`).],
  [Applied], [The host state machine has executed a released `Committed` entry.],
  [`decided_through`], [The greatest slot released in contiguous order; the field is `delivered_through`.],
  [Memory floor], [The greatest slot the host has durably consumed; cells at or below it may be retagged.],
  [Trim anchor], [`Trim_Anchor{trim_id, chosen_trim_slot}`: every slot at or below it is chosen and folded into the host image the host binds to `trim_id`.],
  [Fence], [`quorum_fences`: the greatest trim anchor and chosen prefix a read quorum reported (`Fences{trim, chosen, chosen_peer}`); recovery starts above it.],
  [Chunk], [`CHUNK_SLOTS` consecutive slots answered by one `Prepare_Message`, or proposed by one batch.],
  [Bounded prepare], [A `Prepare_Message` with `scope = .Bounded`: the acceptor promises only the decrees in `[first, last]`, each as a `Write_Promise_At`.],
  [Owner], [Under rotating ownership, the member `owner_of(node, slot)` that may propose in `slot` at round zero without phase one.],
  [Suggestion], [An owner's proposal in its own slot at `ownership_ballot(owner)`.],
  [Skip], [A no-op an idle owner proposes in its own slot below `highest_seen` so the log never waits on it; at most `SKIP_BURST` per tick.],
  [Revocation], [A bounded phase one over a stalled chunk at a round above zero, fencing the owner out of those slots only and re-proposing any vote found.],
  [Resubmission], [An owner proposing again, in its next own slot, a suggestion that a revocation decided to another value.],
  [Stop sign], [A decided `Stop_Sign` entry that seals its configuration and names the next one.],
  [Configuration id], [The host-allocated, strictly increasing `u64` naming one voter set.],
  [Term base], [`leader_base`: the first slot the current leadership may fill; everything below was inherited.],
  [Learner], [A non-voting participant that only receives commits or certified decisions.],
  [No-op], [The host's harmless value, remembered from `campaign` or `tick`, that fills a recovered hole or a skipped slot.],
  [Quorum], [Any subset of voters of the required size.],
  [Read and write quorum], [`read_quorum_size` for phase one, `write_quorum_size` for phase two; their sum exceeds $N$.],
  [Envelope], [`Envelope{from, to, message}`; `Log_Envelope` adds `configuration_id`.],
  [Effect batch], [One `Effects` value: the writes, messages, committed entries, and requests of one transition.],
)

== Sources

+ Leslie Lamport, "The Part-Time Parliament", _ACM Transactions on Computer
  Systems_ 16(2), 1998. The parliament metaphor, the ledger, B1 through B3,
  and the multi-decree refinements this book follows.
+ Leslie Lamport, "Paxos Made Simple", _ACM SIGACT News_ 32(4), 2001. The
  same protocol derived from the safety requirement in plain prose.
+ Leslie Lamport, Dahlia Malkhi, and Lidong Zhou, "Reconfiguring a State
  Machine", _ACM SIGACT News_ 41(1), 2010. Stop signs and configuration
  handover on one slot line.
+ Yanhua Mao, Flavio P. Junqueira, and Keith Marzullo, "Mencius: Building
  Efficient Replicated State Machines for WANs", OSDI 2008. Rotating slot
  ownership, skips, and revocation, which `src/ownership.odin` follows.
+ Heidi Howard, Dahlia Malkhi, and Alexander Spiegelman, "Flexible Paxos:
  Quorum Intersection Revisited", OPODIS 2016. Why only phase-one and
  phase-two quorums need to intersect.
+ Robbert van Renesse and Deniz Altinbuken, "Paxos Made Moderately Complex",
  _ACM Computing Surveys_ 47(3), 2015. Slots, ballots, and the roles of a
  complete implementation.
+ The Odin language overview,
  #link("https://odin-lang.org/docs/overview")[odin-lang.org/docs/overview].
  Parametric structs, unions, `bit_set`, `Maybe`, and `or_return`, the
  language features the library leans on.

== Closing note

Paxos is one preservation rule carried through time. Quorum intersection
guarantees a witness; stable storage lets the witness remember; phase one asks
the witnesses; phase two records; slots put decisions in order. Everything in
`src/` is that rule made concrete, and everything the host does with sync,
identity, and deterministic application is that rule made physical.

#teach_back([
  Close the book and explain the protocol in six sentences. Then reopen the
  invariant list above, find the first fact you left out, and revise only that
  sentence. The gap is the lesson.
])
