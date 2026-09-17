#import "theme.typ": *
#import "figures.typ": *

= Advanced Replicated Log Features

#objectives([
  By the end of this chapter you should be able to drive a node with logical
  ticks and say what each timer does and does not guarantee, tell the term base
  apart from a lease, choose flexible quorum sizes and check them against the
  intersection rule, seal and hand over a configuration with a stop sign, bring
  a lagging peer or a lagging leader back with `Learn_Message`, install a trim
  anchor without losing a vote, run a non-voting learner, and name the second
  way to lead that the next chapter develops. Every mechanism is named by its
  identifier in `src/node.odin`, `src/consensus.odin`, `src/election.odin`,
  `src/replicated_log.odin`, or `src/learner.odin`.
])

== Logical Time

The core owns no clock. Safety never depends on time, but liveness needs a way
to suspect a silent leader, remind followers that a leader is alive, and resend
what was lost. The host converts elapsed time into calls to
`tick(&node, noop, &effects)` at whatever cadence it chooses, and three
intervals in `Node_Options` are measured in those calls:

#code_file("src/node.odin", [
```odin
	// Follower ticks without leader contact before it campaigns. Zero means the default.
	election_timeout_ticks:             u32,
	// Leader ticks between heartbeat broadcasts. Zero means the default.
	heartbeat_interval_ticks:           u32,
	// Leader ticks between bounded retransmission scans. Zero means the default.
	resend_interval_ticks:              u32,
```
])

#code_file("src/paxos.odin", [
```odin
DEFAULT_ELECTION_TIMEOUT_TICKS   :: 10
DEFAULT_HEARTBEAT_INTERVAL_TICKS :: 3
DEFAULT_RESEND_INTERVAL_TICKS    :: 10
```
])

The zero value of `Node_Options` selects every default, so
`paxos.init(&node, id, membership)` and
`paxos.init(&node, id, membership, {election_timeout_ticks = 20})` both read
naturally. A non-voting node returns from `tick` at once: it has nothing to
suspect and nothing to resend.

#book_figure(
  [One logical tick advances all three counters, but only the current role's
  duties run: a follower may campaign, a leader may heartbeat and resend.],
  tick_flow(),
)

For a voter, one tick increments `election_ticks`, `heartbeat_ticks`, and
`resend_ticks` (saturating, never wrapping), then acts by role:

+ A *leader* whose `heartbeat_ticks` reached `heartbeat_interval_ticks`
  broadcasts `Heartbeat_Message{ballot, decided_through}` to its peers. The
  heartbeat carries the leader's delivered prefix, so a follower can see that it
  is behind without any extra message kind.
+ A *leader* whose `resend_ticks` reached `resend_interval_ticks` calls
  `resend_to` for every peer. If the peer has reported a decided prefix above
  the leader's own, `resend_to` first sends it a `Learn_Message`, because
  leadership does not imply knowing every decision. Then it walks the ledger's
  `used` bitmap with `bit_set_next` from a per-peer cursor (`resend_cursor`),
  skipping cells at or below what the peer has already decided, resending a
  `Commit_Message` for a `.Chosen` cell and an `Accept_Message` for a `.Voted`
  cell this leader is driving under its current `lead_ballot`, and stops after
  `CHUNK_SLOTS` messages or one complete sweep. It wraps at most once and never
  visits the same used cell twice in that sweep. The cursor keeps its position, so a quiet peer
  cannot pin every retry to the first chunk.
+ A *candidate* still in `.Preparing` before its timeout retries
  `maybe_resolve_chunk`, for the case where the window could not hold the
  whole chunk the first time.
+ A *follower*, or a candidate whose election timed out, with `election_ticks`
  at or past `election_timeout_ticks` starts a campaign with the `noop` passed
  to this `tick`, provided campaigning is enabled. The timeout is suspicion,
  not proof: the old leader may be alive and partitioned.

A node with `rotating_ownership` set takes a different path, `tick_ownership`
in `src/ownership.odin`, after the counters advance; the ownership chapter
walks it. `election_ticks` resets whenever the node observes a leader
(`observe_leader`): on a global `Prepare`, an `Accept` at a round above zero,
a `Commit`, or a `Heartbeat`. The heartbeat handler has one more job:

#code_file("src/consensus.odin", [
```odin
	// A heartbeat above the promise means this node missed the leader's prepare.
	// Promising is always safe, and it stops a needless election.
	if msg.ballot != l.promised {
		l.promised = msg.ballot
		effects_add_write(effects, Write_Promise{msg.ballot})
	}
	observe_leader(node, from, msg.ballot)
	if msg.decided_through > node.delivered_through do request_learn(node, from, effects)
```
])

A follower that never saw the winning `Prepare`, perhaps because it was
partitioned during the election, adopts the heartbeat's ballot by promising to
it, and the promise is written to `ledger.promised` and to the batch before
anything else happens, exactly as in phase one. A heartbeat below the
follower's promise gets a `Nack_Message` instead, which tells a stale leader to
step down. `request_learn` asks for one chunk from `delivered_through + 1`.

#api_anchor([`tick`], [
  `node_tick(node, noop, effects)` and `replicated_log_tick(node, noop, effects)`.
  The `noop` is stored for any campaign the tick starts; pass the same value the
  host passes to `campaign`.
], source: [`src/consensus.odin`])

#predict([
  A node just won an election. Its `leader_base` is 13 and its
  `delivered_through` is 9, because the chosen fence told it that a peer has
  decided through 12. It has `gate_proposals_on_inherited_prefix` set. A client
  proposes a value now. What does `propose` return, and what has to happen
  before the same call succeeds?
])

== Taking Over: The Term Base

Winning phase one does not leave an idle log. The new leader is re-proposing
recovered votes, filling holes with the no-op, and possibly learning slots
below the chosen fence from a peer. New proposals go above all of that.
`become_leader` records the boundary: it raises `next_slot` past the greatest
used slot and both fences, and `leader_base` is the first slot this
leadership may fill with a fresh value, while `next_slot`, reported by
`proposal_frontier`, is the slot the next proposal would take. Right after the
election they are equal.

A host whose values are independent of each other may pipeline straight
through the takeover. A host whose values depend on applied state (a
compare-and-swap, a hash chain, a sequence number derived from the last applied
entry) cannot: the inherited slots below `leader_base` will decide ahead of any
new proposal, and a value derived before they are applied is derived from the
wrong state. Such a host delivers through `leader_base - 1` first. The option
`gate_proposals_on_inherited_prefix` makes the core enforce this in `propose`
and `propose_batch`, through the shared `proposal_gate`:

#code_file("src/consensus.odin", [
```odin
@(private)
proposal_gate :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Error {
	if !node.voting_member do return .Not_Voter
	if node.ownership do return .None
	if node.role != .Leader do return .Not_Leader
	if node.gate_proposals_on_inherited_prefix && node.delivered_through < node.leader_base - 1 {
		return .Leader_Catching_Up
	}
	return .None
}
```
])

The option is off by default. With or without it, `is_leader_caught_up(&node)`
reports whether `delivered_through` has reached `leader_base - 1`. This
resolves the prediction: `propose` returns `.Leader_Catching_Up`, and it
succeeds once the `Learn_Message` sent during recovery has been answered and
slots 10 through 12 are delivered.

#warning([`is_leader_caught_up` is not a lease and not a read barrier], [
  It reports prefix progress only: the leader has applied every slot it
  inherited. It says nothing about whether this node is still the leader, or
  whether a higher ballot has since chosen values this node has not seen. A
  linearizable read from local state additionally needs a quorum round trip or
  a read barrier through the log, driven by the host. Leader leases are a design
  proposal (POD 0004) and are not implemented in this library.
])

#api_anchor([`leader_base`, `proposal_frontier`, `is_leader_caught_up`], [
  Three queries on `Node` and `Replicated_Log_Node`. The first two are slots;
  the third is `delivered_through >= leader_base - 1`.
], source: [`src/node.odin`])

== Flexible Quorums

Phase one needs a read quorum of promises; phase two needs a write quorum of
votes. The single-decree argument only requires that every read quorum
intersect every write quorum, so that a later ballot's phase one sees at least
one vote from any earlier ballot's phase two. With uniform sizes over $N$
members, that is

$ |Q_1| + |Q_2| > N. $

#book_figure(
  [Read and write quorums have different jobs. Here two votes choose X and four
  reports recover the past. Their overlap is forced by 4 + 2 > 5. The diagram
  assumes no intervening votes; the highest-vote argument handles that case.],
  flexible_quorum_picture(),
)

Two write quorums need not intersect: within one ballot the leader proposes one
value per slot, and across ballots the read quorum does the intersecting. The
library validates the sizes when the membership is built:

#code_file("src/membership.odin", [
```odin
// Validates and installs a membership. Zero overrides select majorities.
membership_init :: proc(
	m: ^Membership($MAX_MEMBERS),
	node_ids: []Node_Id,
	read_quorum_override: int = 0,
	write_quorum_override: int = 0,
) -> Error {
```
])

Zero means a majority. A size outside `1..=N` is `.Invalid_Read_Quorum` or
`.Invalid_Write_Quorum`; a pair whose sum does not exceed $N$ is
`.Non_Intersecting_Quorums`, and the caller's membership is left untouched. For
five voters:

#table(
  columns: (auto, auto, auto, 1fr),
  align: (center, center, center, left),
  table.header([*$N$*], [*$Q_1$ (read)*], [*$Q_2$ (write)*], [*What it buys and what it costs*]),
  [5], [3], [3], [Symmetric majorities. Any two voters may be down for both
    elections and commits.],
  [5], [4], [2], [A commit needs the leader plus one acceptor, so a stable
    leader tolerates three silent voters. An election needs four promises, so
    replacing the leader tolerates only one.],
  [5], [2], [4], [Elections need only two promises, but every commit needs four
    durable votes; two unavailable voters prevent a commit; one slow voter can be bypassed.],
  [5], [5], [1], [The leader commits on its own vote: `send_accept` calls
    `record_commit` before the `Accept` leaves. An election needs all five
    voters.],
)

A smaller write quorum buys cheaper commits and pays for them at the next
election. Choose the pair for the failure you expect to be common, and let
`membership_init` check it:

```odin
m: paxos.Membership(5)
ids := [5]paxos.Node_Id{1, 2, 3, 4, 5}
err := paxos.membership_init(&m, ids[:], 4, 2) // Q1 = 4, Q2 = 2
```

Every `membership_*` query takes a `^Membership`. Up to `LINEAR_LOOKUP_LIMIT`
(8) members, `membership_index_of` scans the members in order; above that it
binary-searches them, which works because `membership_init` sorted them, so a
membership near the 65535 bound is still one lookup per message.

== Reconfiguration: The Stop-Sign Invariant

A configuration is a voter set, a pair of quorum sizes, and a configuration id.
The application must see one sequence across configuration changes. A stop sign
fixes which prefix belongs to the old configuration; the next configuration owns
the application sequence after that boundary.
`Replicated_Log_Node` wraps the core `Node` with entries that are either a
command or a stop sign:

#code_file("src/replicated_log.odin", [
```odin
// One log entry: an application command or a sealing stop sign.
Entry :: union(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$MAX_METADATA_BYTES: int = DEFAULT_MAX_METADATA_BYTES,
) {
	Value,
	Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES),
}
```
])

`Replicated_Log_Node` takes `Value`, `MAX_MEMBERS`, `WINDOW_SLOTS`,
`CHUNK_SLOTS`, `MAX_METADATA_BYTES`, and `GATE`, and holds a `core` node over
that union plus four seal fields: `configuration_id`, `stop_sign`,
`stop_slot`, and `stop_pending`. Its effects type is
`Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE)`,
and its durable state is the core's
`Ledger(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS)`, which
`log_restore` takes and `replicated_log_ledger` (the `ledger` proc group) returns. A `Stop_Sign` carries the next
`configuration_id`, the next member list, and up to `MAX_METADATA_BYTES` of
opaque handover metadata, for example the identifier of a state image the new
members must install.

#book_figure(
  [A stop sign decided in slot $s$ seals configuration $C_1$. Configuration
  $C_2$ continues the same slot line at $s + 1$.],
  scale(x: 78%, y: 78%, reflow: true, reconfiguration_flow()),
)

=== Proposing the stop

`log_reconfigure(&log, next_configuration_id, next_members, metadata, &effects)`
is `replicated_log_propose_stop_sign` under a shorter name. It refuses an id
that is not strictly greater than the current one with
`.Configuration_Id_Regression`, validates the member list and metadata size
through `stop_sign_create`, and proposes the stop sign through the ordinary
`node_propose`. To the host it is one more entry in the pipeline; to the log it
is the last one.

#definition([Sealed], [
  `log_is_sealed(&log)` is true while a stop sign naming a newer configuration
  is pending or decided on this node. Pending means it sits in a used ledger
  cell, whether as an acceptor's vote or as the leader's own proposal. While
  sealed, `log_propose`, `log_propose_batch`, and a second `log_reconfigure`
  all return `.Log_Sealed` before touching the core.
])

The seal starts early on purpose. The proposer is sealed the moment
`log_reconfigure` returns, because its proposal is its own vote in the ledger;
an acceptor is sealed the moment it votes for the stop. If the stop is later
overtaken (a higher ballot re-proposes that slot with a command, as recovery
may) the pending flag is recomputed after every transition
(`replicated_log_observe_effects`) and the seal clears. This local gate stops new proposals as soon as the node
knows a stop is pending. Other owners may still decide later slots before learning
the stop; the release rule below excludes those slots from the application log.

=== Observing the decision

Once the stop sign commits, `log_stop_sign(&log)` returns it with `true` and
`log_stop_slot(&log)` returns its slot. After a crash, `log_restore` takes the
replayed `Ledger` and rediscovers a committed stop by walking the ledger's
`chosen` bitmap; `log_pending_stop_sign(&log)` also reports an undecided one
held in a used cell, so a host can resume its own handover phase without
guessing.

The library decides where the boundary is. It does not move application state,
start processes, or stop old traffic. The host waits for the decided stop,
delivers every slot through it, transfers whatever the metadata names, and then
starts the new configuration:

```odin
stop, sealed := paxos.log_stop_sign(&old)
if sealed {
	stop_slot := paxos.log_stop_slot(&old)
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = stop_slot}
	err := paxos.log_init_from_stop(&next, id, stop, stop_slot, anchor)
}
```

`log_init_from_stop(node, id, stop, stop_slot, anchor, options = {})` builds
the membership from the stop sign's members, takes its configuration id, and
calls `log_continue_at` with `stop_slot` as the floor: the new node's
`delivered_through` and `memory_floor` are `stop_slot`, and its `next_slot` is
`stop_slot + 1`. The slot line does not restart; the first command of $C_2$
takes slot $s + 1$. An id that is not among the stop sign's members is refused
with `.Not_Member`, which is how a removed voter learns it is no longer one. An
anchor above the floor is `.Trim_Regression`.

=== Fencing old traffic

A message from $C_1$ may still be in flight when $C_2$ starts, and a node that
has not heard about the stop may keep sending. A bare `Envelope` carries no
configuration, so the log offers `Log_Envelope`: a `configuration_id` next to
the core `envelope`. On the way out, `log_envelope(&log, message)` stamps each
outbound envelope with the sender's current configuration id. On the way in,
`log_step` given a `Log_Envelope` is the checked overload
(`replicated_log_step_checked`): it compares the stamp to the node's own id
before the core sees the message, and on a mismatch resets the effects and
returns `.Configuration_Mismatch` with no writes and no messages. The plain
`Envelope` overload is for transports that already keep configurations apart.

```odin
for message in paxos.messages_slice(&effects) {
	deliver(paxos.log_envelope(&log, message))
}
// On the receiving node:
err := paxos.log_step(&log, stamped, &effects)
if err == .Configuration_Mismatch {
	// Stale traffic; nothing was written or sent. Drop it.
}
```

Do not relabel old traffic with the new id to make it pass. A vote cast under
$C_1$'s quorum rules is not a vote under $C_2$'s. Under rotating ownership the
member list also fixes which slots each member owns (`owner_of` deals the slot
line in membership order), so a membership change is a stop sign there too. And
because another owner may get a suggestion decided above the stop sign before
it learns of the seal, the log abandons every decision above a decided stop
sign: `replicated_log_observe_effects` cuts them from the released batch, the
read procedures report them undecided, and the next configuration decides those
slots afresh. The ownership chapter returns to this.

#api_anchor([`log_reconfigure`, `log_is_sealed`, `log_init_from_stop`, `log_envelope`, `log_step`], [
  The reconfiguration surface of `Replicated_Log_Node`; every name is also
  available with its `replicated_log_` spelling.
], source: [`src/replicated_log.odin`])

== Catch-Up and Reconciliation

A node that missed traffic does not enter a special recovery mode. It asks a
peer for decisions with `Learn_Message{from_slot, count}`, and `on_learn`
answers by walking the ledger's `chosen` bitmap and sending a
`Commit_Message` for every decision in that range that is still in its window.
If any part of the range lies at or below the answering node's `memory_floor`,
that part has left protocol memory, and the node emits a
`Serve_Range_Request{peer, first, count}` in `effects.requests` for exactly
that part: the host serves it from its own journal or state image, because the
library never reads history it has released. A `from_slot` of zero, or a
`count` of zero or above `CHUNK_SLOTS`, is `.Invalid_Slot`, so one request
never asks for more than one chunk. Three entry points send a `Learn_Message`:

+ `request_catch_up(&node, peer, from_slot, &effects)` asks `peer` for one chunk
  from `from_slot`. The host calls it when it knows it is behind, and again as
  its prefix advances.
+ `reconnected(&node, peer, &effects)` is the host's signal that a link came
  back. A leader answers by running `resend_to` for that peer; a follower whose
  `leader_hint` is that peer asks it for decisions from `delivered_through + 1`.
+ The core sends one itself when a heartbeat, an election manifest, or a
  resend sweep reveals a peer that has decided further than this node.

The last case relies on `peer_decided_through`, one slot per member, which
`node_step` updates from every message that reports progress:

#code_file("src/consensus.odin", [
```odin
// The sender's decided prefix, when the message kind reports it.
@(private)
message_decided_through :: #force_inline proc(message: Message($V)) -> (Slot, bool) {
	#partial switch msg in message {
	case Accepted_Message:      return msg.decided_through, true
	case Heartbeat_Message:     return msg.decided_through, true
	case Nack_Message:          return msg.decided_through, true
	case Promise_Range_Message: return msg.chosen_through, true
	case Prepare_Message:       return msg.first - 1, true
	case Learn_Message:         return msg.from_slot - 1, true
	}
	return 0, false
}
```
])

The leader uses it to skip resends a peer no longer needs and to notice when a
peer is ahead of it. Decisions may arrive out of order; each is recorded in its
cell and only the contiguous prefix is released by `emit_contiguous`.

== Trim Anchors and State Images

The window bounds residency; the host's journal holds the rest. A journal
cannot grow forever either, so the cluster periodically agrees that everything
through some slot is captured in a state image, and acceptors then answer phase
one for that prefix from the anchor instead of from cells:

#code_file("src/ledger.odin", [
```odin
// The trim anchor: every slot at or below `chosen_trim_slot` is chosen and has been
// folded into a host state image identified by `trim_id`. The core compares anchors
// by identity; the host binds the image's checksum to the id itself.
Trim_Anchor :: struct {
	trim_id:          u64,
	chosen_trim_slot: Slot,
}
```
])

The anchor carries no hash. The core compares anchors by identity only: two
anchors with the same `trim_id` must be the same anchor. A host that wants to
verify a state image binds a monotonically increasing `trim_id` to the image's
checksum in the durable record that chose the trim. A raw checksum is not a
suitable sequence number: a later checksum can be numerically smaller and would
fail the trim-regression check. How the anchor is chosen is the host's business; the natural way is to
put the trim record in the log as an ordinary command, ordered with everything
else. Once the host knows the record is chosen, it calls
`install_chosen_trim(&node, anchor, &effects)`. The call refuses an anchor
above `delivered_through` with `.Invalid_Slot`, and a lower `trim_id`, a
different anchor under the same `trim_id`, or a lower `chosen_trim_slot` with
`.Trim_Regression`; the same anchor again is `.None` with nothing written.
Otherwise it emits `Write_Trim` for the journal, adopts the anchor into
`ledger.anchor`, and raises `memory_floor` to the anchor slot, never past
`delivered_through`.

From then on the anchor travels with the node. `on_prepare` skips cells at or
below it and reports it in `Promise_Range_Message.anchor`; `on_accept` ignores
votes for slots at or below it; and a candidate folds every reported anchor
into the trim fence (`quorum_fences`), so no new leader can propose into a
trimmed prefix.

A node so far behind that the slots it needs are below the cluster's anchor
cannot catch up from decisions. Its host fetches the state image, verifies it
against the anchor, persists it, and calls `begin_recovery(&node, anchor)`:

#code_file("src/node.odin", [
```odin
// Installs a certified state image at `anchor`, keeping votes and decisions above it. The
// host must persist the image and the anchor before running further transitions.
node_begin_recovery :: proc(node: ^Node($V, $M, $W, $C, $G), anchor: Trim_Anchor) -> Error {
	node_assert_valid(node)
	ledger_apply(&node.ledger, Write_Trim(anchor)) or_return
	node.leader_hint = nil
	node.election_ticks, node.heartbeat_ticks, node.resend_ticks = 0, 0, 0
	node.peer_decided_through = {}
	node.resend_cursor = {}
	node.role = .Follower
	clear_election(node)
	node_resume_at(node, anchor.chosen_trim_slot)
	return .None
}
```
])

`node_resume_at` clears every open vote at or below the anchor; every vote and
decision above it is kept, because a vote above the anchor may already be part
of a quorum that a future election must find. The node returns to `.Follower`
with an empty election state and a floor at the anchor. `begin_recovery` emits
no effects: the host must have persisted the image and the anchor before the
call, since the node now answers phase one from them.

`continue_at(&node, id, membership, floor, anchor)` is the same idea for a node
that starts empty rather than repairing in place: a fresh voter joining at a
known floor, or the next configuration after a stop sign, which is what
`log_init_from_stop` calls. An anchor above the floor is `.Trim_Regression`
there too.

#api_anchor([`install_chosen_trim`, `begin_recovery`, `continue_at`, `trim_anchor`], [
  Adopt a chosen anchor with a durable record; reset onto an installed image
  keeping votes above it; start empty at a floor; read the adopted anchor.
], source: [`src/node.odin`])

== Non-Voting Learners

Some processes need the decided sequence and nothing else: a read replica, an
indexer, an auditor. Two shapes are available.

The first is a core `Node` initialized with
`node_init_learner(&node, id, membership)`. Its `id` must be non-zero and lie
outside the voting membership, otherwise `.Invalid_Node_Id` or
`.Learner_Is_Voter`. It never promises, votes, or campaigns; `node_step`
accepts only `Commit_Message` from a member and returns
`.Learner_Message_Forbidden` for every other kind, and `tick` does nothing. A
host that has certified a decision by some other path installs it with
`learn_chosen(&node, from, slot, value, &effects)`, which is `.Not_Learner` on
a voter and `.Not_Member` if `from` is not a member. The node releases the
contiguous prefix through `effects.committed` exactly as a voter does;
`Replicated_Log_Node` offers the same through `log_init_learner`,
`log_restore_learner`, and `log_learn_chosen`.

The second is the standalone `Learner` in `src/learner.odin`, a window of
`MAX_ENTRIES` cells with no membership at all:

#code_file("src/learner.odin", [
```odin
// Result of recording a certified chosen value in the learner window.
Learn_Result :: enum {
	// Value was buffered in the window; a gap below it prevents immediate release.
	Buffered,
	// Contiguous released prefix advanced past this value.
	Advanced,
	// Duplicate of an already released or buffered value.
	Duplicate,
}
```
])

`learner_init(&l, configuration_id)` binds it to one configuration.
`learner_learn_chosen(&l, configuration_id, slot, value)` returns a
`Learn_Result` and an `Error`: `.Configuration_Mismatch` for a foreign
configuration, `.Window_Full` when the slot is more than `MAX_ENTRIES` above
`released_through`, and `.Conflicting_Chosen_Value` if the same slot arrives
with a different value, which is a safety incident to preserve, not to retry.
`learner_read_chosen(&l, from_slot, output)` copies the released suffix from
`from_slot`, and `learner_chosen_at(&l, slot)` reads one released value. The
learner takes and stores values by copy, not by pointer, because it has no
ledger for a pointer to refer into. It trusts its caller: it has no quorum to
check against, so the host must feed it only values it has certified as
chosen.

== Two Ways to Lead

Everything above assumes one elected leader: a node campaigns, wins a read
quorum, and proposes in every slot above its term base until a higher ballot
displaces it. `Node_Options.rotating_ownership` selects a second discipline in
which the slot line is dealt round-robin and each member proposes in its own
slots with no phase one at all, because round zero of each such slot's ballot
space belongs to the owner alone. Under that option `campaign` returns
`.Campaign_Disabled`, `proposal_gate` no longer requires the `.Leader` role,
and `tick` runs `tick_ownership`: idle owners fill their slots with the no-op,
a stalled prefix is repaired by a bounded phase one (`Prepare_Scope.Bounded`,
recorded per decree as `Write_Promise_At`), and a suggestion that lost to such
a revocation is proposed again. The ledger, the effect contract, the trim
anchor, the learners, and reconfiguration are the same in both disciplines;
`tools/check.py` runs the fault simulator in both. The next chapter derives
the ownership rules from the same Synod proof and reads `src/ownership.odin`
procedure by procedure.

#exercise([14.1], [
  For five voters, choose read and write quorum sizes that make commits as cheap
  as possible while elections stay possible with two voters down. Show that the
  pair satisfies `Q1 + Q2 > N` and say what it costs.
], hint: [
  Start from what "possible with two voters down" bounds, then let the
  inequality bound the other size.
])

#teach_back([
  Explain to a colleague, without notes, the three things that can make a
  follower send a `Learn_Message` and the one thing that makes a leader send
  one. Then explain why `is_leader_caught_up` returning `true` is not enough to
  serve a linearizable read from local state, and what the host would have to
  add. Finish with the stop-sign invariant in one sentence and the two error
  values that enforce it at the API.
])
