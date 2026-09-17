// Reads and the two mutations that are not transitions.
package paxodin_bridge

import p "paxos:src"

@(export)
paxodin_state :: proc "c" (node: ^Handle, out: ^C_State) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if out == nil do return i32(Status.Null_Pointer)
	log := &handle.node
	leader, has_leader := p.log_current_leader(log)
	anchor := p.log_trim_anchor(log)
	out^ = C_State {
		configuration_id  = p.log_configuration_id(log),
		ballot            = u64(p.ballot(log)),
		decided_through   = p.log_decided_through(log),
		memory_floor      = p.log_memory_floor(log),
		leader_base       = p.log_leader_base(log),
		frontier          = p.log_proposal_frontier(log),
		stop_slot         = p.log_stop_slot(log),
		trim_id           = anchor.trim_id,
		trim_slot         = anchor.chosen_trim_slot,
		node_id           = u16(p.id(log)),
		leader            = u16(leader) if has_leader else 0,
		has_leader        = 1 if has_leader else 0,
		role              = u8(p.role(log)),
		sealed            = 1 if p.log_is_sealed(log) else 0,
		voting_member     = 1 if p.is_voting_member(log) else 0,
		campaign_enabled  = 1 if p.is_campaign_enabled(log) else 0,
		leader_caught_up  = 1 if p.is_leader_caught_up(log) else 0,
		resubmits_dropped = p.resubmits_dropped(log),
	}
	return 0
}

// Requires no live batch. Advancing the floor frees window cells for reuse, and
// the batch's committed entries still point into those cells: if the copy then
// failed, a contiguously released prefix would be gone from the window having
// never reached the host.
@(export)
paxodin_advance_memory_floor :: proc "c" (node: ^Handle, through: u64) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	#partial switch handle.batch.phase {
	case .Pending, .Confirmed:
		return i32(Status.Batch_Pending)
	}
	return core_status(p.log_advance_memory_floor(&handle.node, p.Slot(through)))
}

@(export)
paxodin_set_campaign_enabled :: proc "c" (node: ^Handle, enabled: u32) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	p.set_campaign_enabled(&handle.node, enabled != 0)
	return 0
}

// How many contiguously decided entries sit at or above from_slot, so a caller
// can size a buffer before reading.
@(export)
paxodin_decided_span :: proc "c" (node: ^Handle, from_slot: u64, out: ^u64) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if out == nil do return i32(Status.Null_Pointer)
	out^ = 0
	if from_slot == 0 do return core_status(.Invalid_Slot)
	if from_slot <= p.log_memory_floor(&handle.node) do return core_status(.Trimmed)
	decided := p.log_decided_through(&handle.node)
	if from_slot > decided do return 0
	out^ = decided - from_slot + 1
	return 0
}

// A bounded read of the decided prefix.
//
// This walks slots with log_read rather than calling log_read_decided, which
// returns .Read_Buffer_Too_Small unless the buffer holds the ENTIRE decided
// suffix (src/node.odin:372). There is no partial mode there, so a bounded
// result is only reachable one slot at a time.
@(export)
paxodin_read_decided :: proc "c" (
	node: ^Handle, from_slot: u64, limit: u32, out: [^]C_Committed,
	written: ^u32, next_slot: ^u64,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if out == nil || written == nil || next_slot == nil do return i32(Status.Null_Pointer)
	written^ = 0
	next_slot^ = from_slot
	if from_slot == 0 do return core_status(.Invalid_Slot)
	if from_slot <= p.log_memory_floor(&handle.node) do return core_status(.Trimmed)
	decided := p.log_decided_through(&handle.node)
	if from_slot > decided do return 0
	count := u32(min(u64(limit), decided - from_slot + 1))
	produced: u32 = 0
	for offset in 0 ..< count {
		slot := from_slot + u64(offset)
		entry, found := p.log_read(&handle.node, p.Slot(slot))
		if !found do break
		out[produced] = {}
		out[produced].slot = slot
		entry_to_c(&entry, &out[produced].entry)
		produced += 1
	}
	written^ = produced
	next_slot^ = from_slot + u64(produced)
	return 0
}

@(export)
paxodin_committed_at :: proc "c" (
	node: ^Handle, slot: u64, out: ^C_Entry, found: ^u32,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if out == nil || found == nil do return i32(Status.Null_Pointer)
	found^ = 0
	out^ = {}
	entry, is_found := p.log_read(&handle.node, p.Slot(slot))
	if !is_found do return 0
	entry_to_c(&entry, out)
	found^ = 1
	return 0
}
