// The transitions. Each performs at most one core transition and leaves exactly
// one pending batch behind.
//
// A non-zero return means NO transition ran, NO batch exists, and the token and
// report are zeroed: validation, capability refusal and a live previous batch
// all take that path before anything mutates. A zero return means a batch
// exists and must be discharged -- and `report.status` may still be a protocol
// error, because status and effects are independent (POD 0003).
package paxodin_bridge

import p "paxos:src"

@(private)
begin_prologue :: proc(
	node: ^Handle, token: ^C_Token, report: ^C_Report,
) -> (^Handle, Status) {
	if token != nil do token^ = {}
	if report != nil do report^ = {}
	handle, status := enter(node)
	if status != .Ok do return nil, status
	if token == nil || report == nil {
		leave(handle)
		return nil, .Null_Pointer
	}
	return handle, .Ok
}

@(export)
paxodin_begin_campaign :: proc "c" (
	node: ^Handle, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	err := p.log_campaign(&handle.node, NOOP, &handle.effects)
	batch_seal(handle, err, token, report)
	return 0
}

@(export)
paxodin_begin_tick :: proc "c" (node: ^Handle, token: ^C_Token, report: ^C_Report) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	err := p.log_tick(&handle.node, NOOP, &handle.effects)
	batch_seal(handle, err, token, report)
	return 0
}

@(export)
paxodin_begin_propose :: proc "c" (
	node: ^Handle, value: ^C_Entry, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if value == nil do return i32(Status.Null_Pointer)
	if value.kind != .Command do return i32(Status.Unsupported_Kind)
	// Decoded and range-checked before a batch exists, so an oversized command
	// leaves the node byte-identical.
	entry, decode := entry_from_c(value)
	if decode != .Ok do return i32(decode)
	command, is_command := entry.(Command)
	if !is_command do return i32(Status.Unsupported_Kind)
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	slot, err := p.log_propose(&handle.node, command, &handle.effects)
	handle.batch.assigned_slot = slot
	batch_seal(handle, err, token, report)
	return 0
}

@(export)
paxodin_begin_propose_batch :: proc "c" (
	node: ^Handle, values: [^]C_Entry, count: u32, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if values == nil do return i32(Status.Null_Pointer)
	if count == 0 || count > CHUNK_SLOTS do return i32(Status.Invalid_Argument)
	commands: [CHUNK_SLOTS]Command
	for index in 0 ..< int(count) {
		if values[index].kind != .Command do return i32(Status.Unsupported_Kind)
		entry, decode := entry_from_c(&values[index])
		if decode != .Ok do return i32(decode)
		command, is_command := entry.(Command)
		if !is_command do return i32(Status.Unsupported_Kind)
		commands[index] = command
	}
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	assigned, err := p.log_propose_batch(
		&handle.node, commands[:count], handle.batch.assigned[:], &handle.effects,
	)
	handle.batch.assigned_count = u32(len(assigned))
	if len(assigned) > 0 do handle.batch.assigned_slot = assigned[0]
	batch_seal(handle, err, token, report)
	return 0
}

// Always the checked step: a configuration mismatch resets the effects and
// returns without writes, messages or any state change, so stale traffic from
// another epoch can never be relabelled into this one.
@(export)
paxodin_begin_step :: proc "c" (
	node: ^Handle, envelope: ^C_Envelope, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if envelope == nil do return i32(Status.Null_Pointer)
	wire, decode := envelope_from_c(handle, envelope)
	if decode != .Ok do return i32(decode)
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	err := p.log_step(&handle.node, wire, &handle.effects)
	batch_seal(handle, err, token, report)
	return 0
}

@(export)
paxodin_begin_reconnected :: proc "c" (
	node: ^Handle, peer: u16, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if peer == 0 do return i32(Status.Invalid_Argument)
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	err := p.log_reconnected(&handle.node, p.Node_Id(peer), &handle.effects)
	batch_seal(handle, err, token, report)
	return 0
}

@(export)
paxodin_begin_request_catch_up :: proc "c" (
	node: ^Handle, peer: u16, from_slot: u64, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if peer == 0 do return i32(Status.Invalid_Argument)
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	err := p.log_request_catch_up(
		&handle.node, p.Node_Id(peer), p.Slot(from_slot), &handle.effects,
	)
	batch_seal(handle, err, token, report)
	return 0
}

@(export)
paxodin_begin_install_chosen_trim :: proc "c" (
	node: ^Handle, trim_id: u64, chosen_trim_slot: u64, token: ^C_Token, report: ^C_Report,
) -> i32 {
	context = bridge_context()
	handle, status := begin_prologue(node, token, report)
	if status != .Ok do return i32(status)
	defer leave(handle)
	anchor := p.Trim_Anchor{trim_id = trim_id, chosen_trim_slot = chosen_trim_slot}
	if open_status := batch_open(handle); open_status != .Ok do return i32(open_status)
	err := p.log_install_chosen_trim(&handle.node, anchor, &handle.effects)
	batch_seal(handle, err, token, report)
	return 0
}
