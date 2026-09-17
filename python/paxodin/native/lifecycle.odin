// Opening, closing and restoring a participant.
package paxodin_bridge

import p "paxos:src"

@(private)
finish_open :: proc(handle: ^Handle, err: p.Error, out: ^^Handle) -> i32 {
	if err != .None {
		_ = handle_destroy(handle)
		return core_status(err)
	}
	out^ = handle
	return 0
}

@(export)
paxodin_node_open :: proc "c" (config: ^C_Config, out: ^^Handle) -> i32 {
	context = bridge_context()
	if out == nil do return i32(Status.Null_Pointer)
	out^ = nil
	handle, status, err := handle_create(config)
	if status != .Ok do return i32(status)
	if err != .None do return core_status(err)
	return finish_open(
		handle,
		p.log_init(
			&handle.node, p.Node_Id(handle.node_id), handle.configuration_id,
			handle.membership, handle.options,
		),
		out,
	)
}

// An empty node resuming the shared slot line above a handover, with the
// anchor the previous configuration reached. Slot numbers are global across
// configurations, so this never restarts numbering.
@(export)
paxodin_node_open_continue_at :: proc "c" (
	config: ^C_Config, floor: u64, trim_id: u64, chosen_trim_slot: u64, out: ^^Handle,
) -> i32 {
	context = bridge_context()
	if out == nil do return i32(Status.Null_Pointer)
	out^ = nil
	handle, status, err := handle_create(config)
	if status != .Ok do return i32(status)
	if err != .None do return core_status(err)
	anchor := p.Trim_Anchor{trim_id = trim_id, chosen_trim_slot = chosen_trim_slot}
	return finish_open(
		handle,
		p.log_continue_at(
			&handle.node, p.Node_Id(handle.node_id), handle.configuration_id,
			handle.membership, p.Slot(floor), anchor, handle.options,
		),
		out,
	)
}

// Opens a handle in replay state. Only the replay calls and close are legal
// until it restores, so a half-rebuilt ledger can never serve a transition.
@(export)
paxodin_node_open_for_replay :: proc "c" (config: ^C_Config, out: ^^Handle) -> i32 {
	context = bridge_context()
	if out == nil do return i32(Status.Null_Pointer)
	out^ = nil
	handle, status, err := handle_create(config)
	if status != .Ok do return i32(status)
	if err != .None do return core_status(err)
	scratch, allocation_error := new(Replay_Scratch)
	if allocation_error != nil {
		_ = handle_destroy(handle)
		return i32(Status.Out_Of_Memory)
	}
	handle.replay = scratch
	handle.replaying = true
	out^ = handle
	return 0
}

// Closing never fails: a caller in a `finally` block must be able to release the
// handle. Abandoning unconfirmed writes is a durability violation, so it is
// reported through `abandoned` rather than hidden or turned into an error the
// caller cannot act on.
@(export)
paxodin_node_close :: proc "c" (node: ^Handle, abandoned: ^u32) -> i32 {
	context = bridge_context()
	if abandoned != nil do abandoned^ = 0
	if node == nil do return i32(Status.Null_Pointer)
	if node.magic != HANDLE_MAGIC do return 0
	if node.busy do return i32(Status.Reentrant)
	count := handle_destroy(node)
	if abandoned != nil do abandoned^ = count
	return 0
}

@(export)
paxodin_replay_apply :: proc "c" (node: ^Handle, record: ^C_Write) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if !handle.replaying || handle.replay == nil do return i32(Status.Replay_Not_Active)
	if record == nil do return i32(Status.Null_Pointer)
	write, decode := write_from_c(handle, record)
	if decode != .Ok do return i32(decode)
	// The lifetime fold, not the strict apply: a journal appended across
	// restarts legitimately holds promises out of monotone order.
	return core_status(p.ledger_replay_fold(&handle.replay.ledger, write))
}

// Restores from the folded ledger and the floor the host has durably consumed.
// node_restore takes the Ledger by value -- hundreds of kilobytes -- so it is
// read out of the bridge's own scratch and never named by a C signature.
@(export)
paxodin_replay_restore :: proc "c" (node: ^Handle, floor: u64) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if !handle.replaying || handle.replay == nil do return i32(Status.Replay_Not_Active)
	err := p.log_restore(
		&handle.node, p.Node_Id(handle.node_id), handle.configuration_id,
		handle.membership, handle.replay.ledger, p.Slot(floor), handle.options,
	)
	if err != .None do return core_status(err)
	free(handle.replay)
	handle.replay = nil
	handle.replaying = false
	p.init(&handle.effects)
	handle.batch = {}
	return 0
}

@(export)
paxodin_replay_abort :: proc "c" (node: ^Handle) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if !handle.replaying || handle.replay == nil do return i32(Status.Replay_Not_Active)
	handle.replay.ledger = {}
	return 0
}
