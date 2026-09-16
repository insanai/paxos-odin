package paxos

import "core:container/small_array"

// A decided configuration change: next members plus opaque handover metadata.
Stop_Sign :: struct($MAX_MEMBERS: int = 7, $MAX_METADATA_BYTES: int = 256) {
	configuration_id: u64,
	members:          small_array.Small_Array(MAX_MEMBERS, NodeId),
	metadata:         small_array.Small_Array(MAX_METADATA_BYTES, u8),
}

stop_sign_init :: proc(
	ss: ^Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES),
	configuration_id: u64,
	members: []NodeId,
	metadata: []u8,
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	if len(metadata) > MAX_METADATA_BYTES do return .MetadataTooLarge
	if len(members) == 0 do return .EmptyMembership
	if len(members) > MAX_MEMBERS do return .TooManyMembers

	for m, i in members {
		if m == 0 do return .InvalidNodeId
		for prev in 0..<i {
			if members[prev] == m do return .DuplicateNodeId
		}
	}

	ss.configuration_id = configuration_id
	small_array.clear(&ss.members)
	small_array.clear(&ss.metadata)
	for m in members {
		small_array.push_back(&ss.members, m)
	}
	for b in metadata {
		small_array.push_back(&ss.metadata, b)
	}
	return .None
}

stop_sign_create :: proc(
	$T: typeid/Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES),
	configuration_id: u64,
	members: []NodeId,
	metadata: []u8,
) -> (T, Error) {
	ss: T
	err := stop_sign_init(&ss, configuration_id, members, metadata)
	return ss, err
}

stop_sign_members_slice :: proc(ss: ^Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES)) -> []NodeId {
	return small_array.slice(&ss.members)
}

stop_sign_metadata_slice :: proc(ss: ^Stop_Sign($MAX_MEMBERS, $MAX_METADATA_BYTES)) -> []u8 {
	return small_array.slice(&ss.metadata)
}

// One log entry: an application command or a sealing stop sign.
Entry :: union($Value: typeid, $MAX_MEMBERS: int = 7, $MAX_METADATA_BYTES: int = 256) {
	Value,
	Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES),
}

// A bounded replicated log built on the explicit Paxos effect machine.
// Commands and configuration stop signs share one ordered log. A decided stop
// sign seals the current configuration, allowing safe reconfiguration and snapshot handover.
Replicated_Log_Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = 7,
	$WINDOW_SLOTS: int = 256,
	$CHUNK_SLOTS: int = 64,
	$MAX_METADATA_BYTES: int = 256,
	$GATE: Durability_Gate = .Enforced,
) {
	core:             Node(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE),
	configuration_id: u64,
	stop_sign:        Maybe(Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES)),
	stop_slot:        Slot,
	stop_pending:     bool,
}

replicated_log_init :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
	priority: u32 = 0,
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	err := node_init_with_priority(&node.core, id, membership, priority)
	if err != .None do return err

	node.configuration_id = configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	node.stop_pending = false
	return .None
}

replicated_log_init_learner :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	configuration_id: u64,
	membership: Membership(MAX_MEMBERS),
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	err := node_init_learner(&node.core, id, membership)
	if err != .None do return err

	node.configuration_id = configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	node.stop_pending = false
	return .None
}

replicated_log_is_sealed :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> bool {
	return node.stop_sign != nil
}

replicated_log_stop_sign :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> (Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	if node.stop_sign != nil {
		return node.stop_sign.?, true
	}
	return {}, false
}

replicated_log_stop_slot :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> Slot {
	return node.stop_slot
}

replicated_log_propose :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	value: Value,
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> (Slot, Error) {
	if node.stop_pending || node.stop_sign != nil {
		return 0, .LogSealed
	}
	entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(value)
	return node_propose(&node.core, entry, effects)
}

replicated_log_propose_batch :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	values: []Value,
	slots: []Slot,
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> ([]Slot, Error) {
	if node.stop_pending || node.stop_sign != nil {
		return nil, .LogSealed
	}
	if len(values) == 0 do return nil, .EmptyBatch

	entries_buf: [CHUNK_SLOTS]Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)
	if len(values) > CHUNK_SLOTS do return nil, .BatchTooLarge

	for val, i in values {
		entries_buf[i] = Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(val)
	}

	return node_propose_batch(&node.core, entries_buf[:len(values)], slots, effects)
}

replicated_log_propose_stop_sign :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	next_configuration_id: u64,
	next_members: []NodeId,
	metadata: []u8,
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> (Slot, Error) {
	if node.stop_pending || node.stop_sign != nil {
		return 0, .LogSealed
	}
	if next_configuration_id <= node.configuration_id {
		return 0, .ConfigurationIdRegression
	}
	if next_configuration_id == max(u64) {
		return 0, .ConfigurationIdExhausted
	}

	ss, err := stop_sign_create(Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), next_configuration_id, next_members, metadata)
	if err != .None do return 0, err

	entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(ss)
	slot, prop_err := node_propose(&node.core, entry, effects)
	if prop_err != .None do return 0, prop_err

	node.stop_pending = true
	return slot, .None
}

replicated_log_campaign :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	noop: Value,
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	noop_entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(noop)
	return node_campaign(&node.core, noop_entry, effects)
}

replicated_log_tick :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	noop: Value,
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	noop_entry := Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)(noop)
	return node_tick(&node.core, noop_entry, effects)
}

replicated_log_step :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	envelope: Envelope(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES)),
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	err := node_step(&node.core, envelope, effects)
	if err != .None do return err

	// Inspect committed entries in effects for Stop_Sign
	committed := effects_committed_slice(effects)
	for c in committed {
		#partial switch val in c.value {
		case Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES):
			node.stop_sign = val
			node.stop_slot = c.slot
			node.stop_pending = false
		}
	}
	return .None
}

// Starts an empty node continuing across a decided stop sign configuration handover.
replicated_log_init_from_stop :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	stop: Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES),
	anchor: Trim_Anchor,
	floor: Slot,
	priority: u32 = 0,
) -> Error {
	mem: Membership(MAX_MEMBERS)
	var_stop := stop
	err := membership_init(&mem, stop_sign_members_slice(&var_stop))
	if err != .None do return err

	err = node_continue_at(&node.core, id, mem, floor, anchor, priority)
	if err != .None do return err

	node.configuration_id = stop.configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	node.stop_pending = false
	return .None
}

// Starts an empty node whose window resumes at floor under configuration_id with anchor.
replicated_log_continue_at :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	configuration_id: u64,
	anchor: Trim_Anchor,
	floor: Slot,
	priority: u32 = 0,
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	err := node_continue_at(&node.core, id, membership, floor, anchor, priority)
	if err != .None do return err

	node.configuration_id = configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	node.stop_pending = false
	return .None
}

// Restores a replicated log node from replayed durable state resuming at floor.
replicated_log_restore_at :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	configuration_id: u64,
	durable: Durable_State(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS),
	floor: Slot,
	priority: u32 = 0,
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	err := node_restore_at(&node.core, id, membership, durable, floor, priority)
	if err != .None do return err

	node.configuration_id = configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	replicated_log_recalculate_stop_pending(node)
	return .None
}

// Restores a replicated log node from replayed durable state at floor zero.
replicated_log_restore :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	configuration_id: u64,
	durable: Durable_State(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS),
) -> Error {
	return replicated_log_restore_at(node, id, membership, configuration_id, durable, 0, 0)
}

// Restores a prioritized replicated log node from replayed durable state at floor zero.
replicated_log_restore_with_priority :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	configuration_id: u64,
	durable: Durable_State(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS),
	priority: u32,
) -> Error {
	return replicated_log_restore_at(node, id, membership, configuration_id, durable, 0, priority)
}

// Restores a non-voting learner on a replicated log from durable state.
replicated_log_restore_learner :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	configuration_id: u64,
	durable: Durable_State(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), WINDOW_SLOTS),
) -> Error {
	if configuration_id == 0 do return .InvalidConfigurationId
	err := node_restore_learner(&node.core, id, membership, durable)
	if err != .None do return err

	node.configuration_id = configuration_id
	node.stop_sign = nil
	node.stop_slot = 0
	replicated_log_recalculate_stop_pending(node)
	return .None
}

// Resets this replicated log node onto an installed state image at anchor.
replicated_log_begin_recovery :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	anchor: Trim_Anchor,
) -> Error {
	err := node_begin_recovery(&node.core, anchor)
	if err != .None do return err
	node.stop_sign = nil
	node.stop_slot = 0
	replicated_log_recalculate_stop_pending(node)
	return .None
}

// Returns the undecided stop value retained in durable accepted state or volatile leader proposals.
replicated_log_pending_stop_sign :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> (Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	if node.stop_sign != nil {
		return node.stop_sign.?, true
	}
	for &cell in node.core.durable.cells {
		if cell.slot == 0 || cell.committed != nil do continue
		if cell.accepted == nil do continue
		acc := cell.accepted.?
		#partial switch entry in acc.value {
		case Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES):
			if entry.configuration_id > node.configuration_id {
				return entry, true
			}
		}
	}
	for &lead in node.core.lead {
		if lead.slot == 0 do continue
		if _, committed := durable_committed_at(&node.core.durable, lead.slot); committed do continue
		if lead.proposal == nil do continue
		prop := lead.proposal.?
		#partial switch entry in prop {
		case Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES):
			if entry.configuration_id > node.configuration_id {
				return entry, true
			}
		}
	}
	return {}, false
}

// Recalculates whether any uncommitted accepted or lead slot contains a stop sign.
replicated_log_recalculate_stop_pending :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) {
	if node.stop_sign != nil {
		node.stop_pending = true
		return
	}
	_, has_pending := replicated_log_pending_stop_sign(node)
	node.stop_pending = has_pending
}

// Alias for proposing a configuration change stop sign.
replicated_log_reconfigure :: replicated_log_propose_stop_sign

// Reads committed entry at the specified slot if available.
replicated_log_read :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	slot: Slot,
) -> (Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	return node_committed_at(&node.core, slot)
}

// Returns the slot line through which all entries have committed.
replicated_log_decided_through :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> Slot {
	return node_decided_through(&node.core)
}

// Returns the slot line where current leadership began.
replicated_log_leader_base :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> Slot {
	return node_leader_base(&node.core)
}

// Returns the slot the next proposal would occupy.
replicated_log_proposal_frontier :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> Slot {
	return node_proposal_frontier(&node.core)
}

// Records that the host has durably consumed log entries up through slot.
replicated_log_advance_memory_floor :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	through: Slot,
) -> Error {
	return node_advance_memory_floor(&node.core, through)
}

// Returns the released memory floor.
replicated_log_memory_floor :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> Slot {
	return node_memory_floor(&node.core)
}

// Installs a chosen trim record into the replicated log.
replicated_log_install_chosen_trim :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
	anchor: Trim_Anchor,
	effects: ^Effects(Entry(Value, MAX_MEMBERS, MAX_METADATA_BYTES), MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	return node_install_chosen_trim(&node.core, anchor, effects)
}

// Returns the active trim anchor.
replicated_log_trim_anchor :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> Trim_Anchor {
	return node_trim_anchor(&node.core)
}

// Returns the currently recognized leader ID hint.
replicated_log_current_leader :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> (NodeId, bool) {
	return node_current_leader(&node.core)
}

// Returns the durable configuration ID.
replicated_log_configuration_id :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> u64 {
	return node.configuration_id
}

// Returns the decided stop sign if this log has been sealed.
replicated_log_is_reconfigured :: proc(
	node: ^Replicated_Log_Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $MAX_METADATA_BYTES, $GATE),
) -> (Stop_Sign(MAX_MEMBERS, MAX_METADATA_BYTES), bool) {
	return replicated_log_stop_sign(node)
}
