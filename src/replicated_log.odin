package paxos

import "base:intrinsics"
import "core:container/small_array"

// A decided configuration change: the next configuration's identity and members,
// plus opaque handover metadata (for example a state-image identifier).
Stop_Sign :: struct(
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$MAX_METADATA_BYTES: int = DEFAULT_MAX_METADATA_BYTES,
) {
	configuration_id: u64,
	members:          small_array.Small_Array(MAX_MEMBERS, Node_Id),
	metadata:         small_array.Small_Array(MAX_METADATA_BYTES, u8),
}

// Rejects zero and duplicate member ids. Host wire decoders may reuse it.
stop_sign_validate_members :: proc(members: []Node_Id, $MAX_MEMBERS: int) -> Error {
	if len(members) == 0 do return .Empty_Membership
	if len(members) > MAX_MEMBERS do return .Too_Many_Members
	for m, i in members {
		if m == 0 do return .Invalid_Node_Id
		for previous in members[:i] {
			if previous == m do return .Duplicate_Node_Id
		}
	}
	return .None
}

// Builds a validated stop sign in place. The input slices may alias the destination.
stop_sign_init :: proc(
	ss: ^Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES),
	configuration_id: u64,
	members: []Node_Id,
	metadata: []u8,
) -> Error {
	if configuration_id == 0 do return .Invalid_Configuration_Id
	if len(metadata) > MAX_METADATA_BYTES do return .Metadata_Too_Large
	stop_sign_validate_members(members, MAX_MEMBERS) or_return

	validated := Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES){configuration_id = configuration_id}
	for m in members do small_array.push_back(&validated.members, m)
	for b in metadata do small_array.push_back(&validated.metadata, b)
	ss^ = validated
	return .None
}

// Returns a validated stop sign by value.
stop_sign_create :: proc(
	$T: typeid/Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES),
	configuration_id: u64,
	members: []Node_Id,
	metadata: []u8,
) -> (ss: T, err: Error) {
	err = stop_sign_init(&ss, configuration_id, members, metadata)
	return
}

stop_sign_members_slice :: proc(ss: ^Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES)) -> []Node_Id {
	return small_array.slice(&ss.members)
}

stop_sign_metadata_slice :: proc(ss: ^Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES)) -> []u8 {
	return small_array.slice(&ss.metadata)
}

// One log entry: an application command or a sealing stop sign.
Entry :: union(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$MAX_METADATA_BYTES: int = DEFAULT_MAX_METADATA_BYTES,
) {
	Value,
	Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES),
}

// A reconfigurable replicated log on top of the core Node. Commands and stop signs
// share one ordered slot line. A decided stop sign seals the configuration: no
// later slot is ever chosen in it, and the next configuration continues at the
// stop slot plus one with the same global slot numbers.
//
// Declare the matching effects as
// `Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW, CHUNK)`.
Replicated_Log_Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$MAX_METADATA_BYTES: int = DEFAULT_MAX_METADATA_BYTES,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	core:             Node(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
	configuration_id: u64,
	stop_sign:        Maybe(Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES)),
	stop_slot:        Slot,
	stop_pending:     bool,
}

// Initializes a voting member of configuration `configuration_id`.
replicated_log_init :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	id: Node_Id,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
	options := Node_Options{},
) -> Error {
	if configuration_id == 0 do return .Invalid_Configuration_Id
	node_init(&node.core, id, membership, options) or_return
	replicated_log_reset_seal(node, configuration_id)
	return .None
}

// Initializes a non-voting learner that follows configuration `configuration_id`.
replicated_log_init_learner :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	id: Node_Id,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
) -> Error {
	if configuration_id == 0 do return .Invalid_Configuration_Id
	node_init_learner(&node.core, id, membership) or_return
	replicated_log_reset_seal(node, configuration_id)
	return .None
}

// Starts an empty node in the configuration a decided stop sign describes, continuing
// the slot line at `stop_slot + 1` with the inherited trim anchor.
replicated_log_init_from_stop :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	id: Node_Id,
	stop: Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES),
	stop_slot: Slot,
	anchor: Trim_Anchor,
	options := Node_Options{},
) -> Error {
	if stop.configuration_id == 0 do return .Invalid_Configuration_Id
	stop := stop
	membership: Membership(MAX_MEMBERS)
	membership_init(&membership, stop_sign_members_slice(&stop)) or_return
	return replicated_log_continue_at(
		node, id, stop.configuration_id, membership, stop_slot, anchor, options,
	)
}

// Starts an empty node whose window resumes at `floor` under `configuration_id`.
replicated_log_continue_at :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	id: Node_Id,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
	floor: Slot,
	anchor: Trim_Anchor,
	options := Node_Options{},
) -> Error {
	if configuration_id == 0 do return .Invalid_Configuration_Id
	node_continue_at(&node.core, id, membership, floor, anchor, options) or_return
	replicated_log_reset_seal(node, configuration_id)
	return .None
}

// Restores a voting member from replayed durable state and rediscovers a committed seal.
replicated_log_restore :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	id: Node_Id,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
	ledger: Ledger(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS),
	floor: Slot = 0,
	options := Node_Options{},
) -> Error {
	if configuration_id == 0 do return .Invalid_Configuration_Id
	node_restore(&node.core, id, membership, ledger, floor, options) or_return
	replicated_log_reset_seal(node, configuration_id)
	replicated_log_observe_durable(node)
	return .None
}

// Restores a non-voting learner from its commit-only journal.
replicated_log_restore_learner :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	id: Node_Id,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
	ledger: Ledger(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS),
) -> Error {
	if configuration_id == 0 do return .Invalid_Configuration_Id
	node_restore_learner(&node.core, id, membership, ledger) or_return
	replicated_log_reset_seal(node, configuration_id)
	replicated_log_observe_durable(node)
	return .None
}

// Resets this node onto an installed state image at `anchor`, keeping votes above it.
replicated_log_begin_recovery :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	anchor: Trim_Anchor,
) -> Error {
	node_begin_recovery(&node.core, anchor) or_return
	node.stop_sign = nil
	node.stop_slot = 0
	replicated_log_observe_durable(node)
	return .None
}

// ---------------------------------------------------------------------------
// Transitions
// ---------------------------------------------------------------------------

// Proposes an application command. Fails with .Log_Sealed once a stop sign is
// pending or decided in this configuration.
replicated_log_propose :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	value: Value,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> (slot: Slot, err: Error) {
	if replicated_log_is_sealed(node) do return 0, .Log_Sealed
	entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(value)
	slot = node_propose(&node.core, entry, effects) or_return
	replicated_log_observe_effects(node, effects)
	return slot, .None
}

// Proposes up to CHUNK_SLOTS commands into consecutive slots as one effect batch.
replicated_log_propose_batch :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	values: []Value,
	slots: []Slot,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> (assigned: []Slot, err: Error) {
	if replicated_log_is_sealed(node) do return nil, .Log_Sealed
	if len(values) == 0 do return nil, .Empty_Batch
	if len(values) > CHUNK_SLOTS do return nil, .Batch_Too_Large

	entries: [CHUNK_SLOTS]Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)
	for value, i in values do entries[i] = value
	assigned = node_propose_batch(&node.core, entries[:len(values)], slots, effects) or_return
	replicated_log_observe_effects(node, effects)
	return assigned, .None
}

// Proposes a stop sign that seals this configuration and names the next one.
replicated_log_propose_stop_sign :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	next_configuration_id: u64,
	next_members: []Node_Id,
	metadata: []u8,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> (slot: Slot, err: Error) {
	if replicated_log_is_sealed(node) do return 0, .Log_Sealed
	if next_configuration_id <= node.configuration_id do return 0, .Configuration_Id_Regression

	stop := stop_sign_create(
		Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), next_configuration_id, next_members, metadata,
	) or_return
	entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(stop)
	slot = node_propose(&node.core, entry, effects) or_return
	replicated_log_observe_effects(node, effects)
	return slot, .None
}

// Alias: reconfiguration is the act of proposing a stop sign.
replicated_log_reconfigure :: replicated_log_propose_stop_sign

replicated_log_campaign :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	noop: Value,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(noop)
	node_campaign(&node.core, entry, effects) or_return
	replicated_log_observe_effects(node, effects)
	return .None
}

replicated_log_tick :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	noop: Value,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	node_tick(&node.core, Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(noop), effects) or_return
	replicated_log_observe_effects(node, effects)
	return .None
}

// Processes a bare core envelope. Use it only when the transport already isolates
// configurations; otherwise use the Log_Envelope overload.
replicated_log_step :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	envelope: Envelope(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)),
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	node_step(&node.core, envelope, effects) or_return
	replicated_log_observe_effects(node, effects)
	return .None
}

// Carries the configuration identity on the wire. Use it whenever a transport can
// deliver a message delayed across a membership handover.
Log_Envelope :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$MAX_METADATA_BYTES: int = DEFAULT_MAX_METADATA_BYTES,
) {
	configuration_id: u64,
	envelope:         Envelope(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)),
}

// Stamps an outbound core envelope with its originating configuration.
replicated_log_envelope :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	envelope: Envelope(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)),
) -> Log_Envelope(Value, MAX_MEMBERS, MAX_METADATA_BYTES) {
	return {configuration_id = node.configuration_id, envelope = envelope}
}

// Checks the configuration before the core may inspect or mutate protocol state. A
// mismatch returns .Configuration_Mismatch with no writes and no messages.
replicated_log_step_checked :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	message: Log_Envelope(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	if message.configuration_id != node.configuration_id {
		effects_reset(effects)
		return .Configuration_Mismatch
	}
	return replicated_log_step(node, message.envelope, effects)
}

// Records a host-certified decision on a non-voting participant.
replicated_log_learn_chosen :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	from: Node_Id,
	slot: Slot,
	entry: Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	node_learn_chosen(&node.core, from, slot, entry, effects) or_return
	replicated_log_observe_effects(node, effects)
	return .None
}

replicated_log_reconnected :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	peer: Node_Id,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	return node_reconnected(&node.core, peer, effects)
}

replicated_log_request_catch_up :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	peer: Node_Id,
	from_slot: Slot,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	return node_request_catch_up(&node.core, peer, from_slot, effects)
}

// Records that the host durably consumed every released entry through `through`.
replicated_log_advance_memory_floor :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	through: Slot,
) -> Error {
	return node_advance_memory_floor(&node.core, through)
}

// Adopts a chosen trim record; emits Write_Trim_Anchor.
replicated_log_install_chosen_trim :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	anchor: Trim_Anchor,
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) -> Error {
	return node_install_chosen_trim(&node.core, anchor, effects)
}

replicated_log_set_campaign_enabled :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	enabled: bool,
) {
	node_set_campaign_enabled(&node.core, enabled)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// True once a stop sign is pending or decided: no further command may be proposed here.
replicated_log_is_sealed :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> bool {
	return node.stop_pending || node.stop_sign != nil
}

// The decided stop sign, if this configuration has been sealed by a decision.
replicated_log_stop_sign :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> (Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	return node.stop_sign.?
}

// Alias of replicated_log_stop_sign.
replicated_log_is_reconfigured :: replicated_log_stop_sign

// The slot of the decided stop sign, or zero.
replicated_log_stop_slot :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Slot {
	return node.stop_slot
}

// The undecided stop sign retained in durable accepted state or in volatile leader
// proposals, so a host can repair its own handover phase after a crash. A decided
// stop sign is returned first.
replicated_log_pending_stop_sign :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> (Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	if stop, decided := node.stop_sign.?; decided do return stop, true
	l := &node.core.ledger
	cell, used := bit_set_next(l.used, 0)
	for used {
		if stop, is_stop := replicated_log_next_stop(node, l.value[cell]); is_stop do return stop, true
		cell, used = bit_set_next(l.used, cell + 1)
	}
	return {}, false
}

replicated_log_read :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	slot: Slot,
) -> (Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	if replicated_log_abandoned(node, slot) do return {}, false
	return node_committed_at(&node.core, slot)
}

replicated_log_read_decided :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	from_slot: Slot,
	output: []Committed(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)),
) -> (count: int, err: Error) {
	count = node_read_decided(&node.core, from_slot, output) or_return
	for i in 0..<count {
		if replicated_log_abandoned(node, output[i].slot) do return i, .None
	}
	return count, .None
}

replicated_log_decided_through :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Slot {
	if stop_slot, sealed := replicated_log_seal(node); sealed {
		return min(node.core.delivered_through, stop_slot)
	}
	return node.core.delivered_through
}

replicated_log_leader_base :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Slot {
	return node.core.leader_base
}

replicated_log_proposal_frontier :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Slot {
	return node.core.next_slot
}

replicated_log_is_leader_caught_up :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> bool {
	return node_is_leader_caught_up(&node.core)
}

replicated_log_memory_floor :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Slot {
	return node.core.memory_floor
}

replicated_log_trim_anchor :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Trim_Anchor {
	return node.core.ledger.anchor
}

replicated_log_current_leader :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> (Node_Id, bool) {
	return node.core.leader_hint.?
}

replicated_log_configuration_id :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> u64 {
	return node.configuration_id
}

replicated_log_role :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Role {
	return node.core.role
}

replicated_log_ballot :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Ballot {
	return node.core.ballot
}

replicated_log_id :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> Node_Id {
	return node.core.id
}

replicated_log_is_voting_member :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> bool {
	return node.core.voting_member
}

replicated_log_is_campaign_enabled :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> bool {
	return node.core.campaign_enabled
}

replicated_log_ledger :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> ^Ledger(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS) {
	return &node.core.ledger
}

// ---------------------------------------------------------------------------
// Seal bookkeeping
// ---------------------------------------------------------------------------

@(private="file")
replicated_log_reset_seal :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	configuration_id: u64,
) {
	node.configuration_id = configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	node.stop_pending = false
}

// A stop sign that names a configuration newer than this node's, if `entry` holds one.
@(private="file")
replicated_log_next_stop :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	entry: Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
) -> (Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	stop, is_stop := entry.(Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES))
	if !is_stop || stop.configuration_id <= node.configuration_id do return {}, false
	return stop, true
}

// Records the earliest decided stop sign that seals this configuration.
@(private="file")
replicated_log_observe_stop :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	slot: Slot,
	entry: Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
) {
	stop, is_stop := replicated_log_next_stop(node, entry)
	if !is_stop do return
	if node.stop_sign == nil || slot < node.stop_slot {
		node.stop_sign = stop
		node.stop_slot = slot
	}
}

// Recalculates whether any uncommitted accepted or leader slot holds a stop sign.
@(private="file")
replicated_log_recalculate_stop_pending :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) {
	_, pending := replicated_log_pending_stop_sign(node)
	node.stop_pending = pending
}

// Every transition that can release a chosen entry passes through here.
@(private="file")
replicated_log_observe_effects :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) {
	for c in effects_committed_slice(effects) {
		replicated_log_observe_stop(node, c.slot, c.value^)
	}
	replicated_log_recalculate_stop_pending(node)
	replicated_log_abandon_above_seal(node, effects)
}

// The slot of the decided stop sign, if this configuration is sealed.
@(private="file")
replicated_log_seal :: #force_inline proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) -> (Slot, bool) {
	return node.stop_slot, node.stop_sign != nil
}

// A slot above a decided stop sign belongs to the next configuration. Under rotating
// ownership another owner may still get a suggestion decided there before it learns
// of the seal; such a decision is abandoned, never released, and the next
// configuration decides that slot afresh with its own quorums (Lamport, Malkhi, and
// Zhou: the acceptors of an instance are those of the configuration that owns it).
@(private="file")
replicated_log_abandoned :: #force_inline proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	slot: Slot,
) -> bool {
	stop_slot, sealed := replicated_log_seal(node)
	return sealed && slot > stop_slot
}

// Drops every released entry above the seal from this batch. Releases are contiguous,
// so the batch is cut at the first abandoned slot.
@(private="file")
replicated_log_abandon_above_seal :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
	effects: ^Effects(
		Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES),
		MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE,
	),
) {
	for c, i in effects_committed_slice(effects) {
		if replicated_log_abandoned(node, c.slot) {
			small_array.resize(&effects.committed, i)
			return
		}
	}
}

@(private="file")
replicated_log_observe_durable :: proc(
	node: ^Replicated_Log_Node(
		$Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS,
		$MAX_METADATA_BYTES, $GATE,
	),
) {
	l := &node.core.ledger
	cell, chosen := bit_set_next(l.chosen, 0)
	for chosen {
		replicated_log_observe_stop(node, l.slot[cell], l.value[cell])
		cell, chosen = bit_set_next(l.chosen, cell + 1)
	}
	replicated_log_recalculate_stop_pending(node)
}
