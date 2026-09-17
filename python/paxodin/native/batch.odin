// The pending-batch protocol.
//
// A batch is a durability obligation, not a result. The core hands out writes,
// messages and committed entries that point into the node's ledger and stay
// valid only until its next transition. The bridge therefore retains one batch
// and refuses to begin another until the host has discharged it.
//
// GUARD PROOF. With GATE == .Enforced the core calls host_order_violation --
// which exits the process -- from effects_reset and effects_messages_slice, and
// only while writes_pending. Neither is reachable here:
//
//   (a) messages_slice runs only from paxodin_copy_messages, which requires
//       phase == .Confirmed. .Confirmed is entered only by batch_confirm, which
//       calls effects_confirm_writes_durable and clears the flag, or at seal
//       when write_count == 0 -- and writes_pending is set only by
//       effects_add_write, so no writes means the flag is already false.
//   (b) effects_reset runs only inside a core transition, reachable only from a
//       begin_*, which requires phase in {.Idle, .Finished}. .Idle holds only on
//       a fresh handle, where effects_init cleared the flag; .Finished is
//       reachable only from .Confirmed, where it is false.
//
// So both libraries return the same status for the same trace, and the
// .Enforced twin is a proof obligation the test suite discharges rather than a
// different implementation.
package paxodin_bridge

import p "paxos:src"

@(private)
batch_open :: proc(handle: ^Handle) -> Status {
	if handle.replaying do return .Replay_Active
	#partial switch handle.batch.phase {
	case .Pending, .Confirmed:
		return .Batch_Pending
	}
	handle.batch = {}
	handle.generation += 1
	handle.batch.generation = handle.generation
	handle.batch.phase = .Pending
	return .Ok
}

@(private)
batch_seal :: proc(handle: ^Handle, err: p.Error, token: ^C_Token, report: ^C_Report) {
	effects := &handle.effects
	batch := &handle.batch
	batch.protocol_status = core_status(err)
	batch.write_count = u32(effects.writes.len)
	batch.message_count = u32(effects.messages.len)
	batch.committed_count = u32(effects.committed.len)
	batch.request_count = u32(effects.requests.len)
	batch.requires_barrier = p.requires_power_loss_barrier(effects)
	// A batch with nothing to persist is born confirmed. Without this, a
	// transition that releases decisions without writing -- a Commit_Message for
	// an already chosen cell, or a Configuration_Mismatch -- would force the host
	// to confirm a durability fact about no records at all.
	if batch.write_count == 0 do batch.phase = .Confirmed
	if token != nil do token^ = C_Token{epoch = handle.epoch, generation = batch.generation}
	report_fill(handle, report)
}

@(private)
report_fill :: proc "contextless" (handle: ^Handle, report: ^C_Report) {
	if report == nil do return
	batch := &handle.batch
	report^ = C_Report {
		epoch                 = handle.epoch,
		generation            = batch.generation,
		assigned_slot         = batch.assigned_slot,
		status                = batch.protocol_status,
		phase                 = u32(batch.phase),
		write_count           = batch.write_count,
		writes_copied_through = batch.writes_copied_through,
		message_count         = batch.message_count,
		committed_count       = batch.committed_count,
		request_count         = batch.request_count,
		assigned_count        = batch.assigned_count,
		requires_barrier      = 1 if batch.requires_barrier else 0,
	}
}

@(private)
token_check :: proc "contextless" (handle: ^Handle, token: ^C_Token) -> Status {
	if token == nil do return .Null_Pointer
	if token.epoch != handle.epoch do return .Foreign_Token
	if handle.batch.phase == .Idle do return .No_Batch
	if token.generation != handle.batch.generation do return .Stale_Token
	return .Ok
}

// Messages, committed entries and host requests are all outputs of the same
// transition and all become visible only after its writes are durable. Serving
// a range request means transmitting commits, so it is a send like any other.
@(private)
output_gate :: #force_inline proc "contextless" (handle: ^Handle) -> Status {
	#partial switch handle.batch.phase {
	case .Pending:
		return .Writes_Unconfirmed
	case .Finished:
		return .Batch_Finished
	}
	return .Ok
}

@(private)
span :: #force_inline proc "contextless" (
	total, offset, want: u32,
) -> (count: u32, status: Status) {
	if offset > total do return 0, .Range
	return min(want, total - offset), .Ok
}

@(export)
paxodin_batch_report :: proc "c" (node: ^Handle, token: ^C_Token, report: ^C_Report) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if report == nil do return i32(Status.Null_Pointer)
	if check := token_check(handle, token); check != .Ok do return i32(check)
	report_fill(handle, report)
	return 0
}

@(export)
paxodin_copy_writes :: proc "c" (
	node: ^Handle, token: ^C_Token, offset, want: u32, out: [^]C_Write, written: ^u32,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if written != nil do written^ = 0
	if check := token_check(handle, token); check != .Ok do return i32(check)
	if handle.batch.phase == .Finished do return i32(Status.Batch_Finished)
	if out == nil || written == nil do return i32(Status.Null_Pointer)
	count, range_status := span(handle.batch.write_count, offset, want)
	if range_status != .Ok do return i32(range_status)
	records := p.writes_slice(&handle.effects)
	for index in 0 ..< int(count) do write_to_c(records[int(offset) + index], &out[index])
	// A high-water mark, so a copy that dies halfway cannot satisfy confirm.
	handle.batch.writes_copied_through = max(handle.batch.writes_copied_through, offset + count)
	written^ = count
	return 0
}

@(export)
paxodin_confirm :: proc "c" (node: ^Handle, token: ^C_Token) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if check := token_check(handle, token); check != .Ok do return i32(check)
	#partial switch handle.batch.phase {
	case .Confirmed:
		return 0
	case .Finished:
		return i32(Status.Batch_Finished)
	}
	// Confirming records the host never received is the likeliest integration
	// bug and the most damaging: it acknowledges a promise or a vote that may
	// never have reached stable storage.
	if handle.batch.writes_copied_through < handle.batch.write_count {
		return i32(Status.Writes_Not_Copied)
	}
	p.confirm_writes_durable(&handle.effects)
	handle.batch.phase = .Confirmed
	return 0
}

@(export)
paxodin_copy_messages :: proc "c" (
	node: ^Handle, token: ^C_Token, offset, want: u32, out: [^]C_Envelope, written: ^u32,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if written != nil do written^ = 0
	if check := token_check(handle, token); check != .Ok do return i32(check)
	if gate := output_gate(handle); gate != .Ok do return i32(gate)
	if out == nil || written == nil do return i32(Status.Null_Pointer)
	count, range_status := span(handle.batch.message_count, offset, want)
	if range_status != .Ok do return i32(range_status)
	configuration := p.log_configuration_id(&handle.node)
	envelopes := p.messages_slice(&handle.effects)
	for index in 0 ..< int(count) {
		envelope_to_c(configuration, envelopes[int(offset) + index], &out[index])
	}
	written^ = count
	return 0
}

@(export)
paxodin_copy_committed :: proc "c" (
	node: ^Handle, token: ^C_Token, offset, want: u32, out: [^]C_Committed, written: ^u32,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if written != nil do written^ = 0
	if check := token_check(handle, token); check != .Ok do return i32(check)
	if gate := output_gate(handle); gate != .Ok do return i32(gate)
	if out == nil || written == nil do return i32(Status.Null_Pointer)
	count, range_status := span(handle.batch.committed_count, offset, want)
	if range_status != .Ok do return i32(range_status)
	entries := p.committed_slice(&handle.effects)
	for index in 0 ..< int(count) do committed_to_c(entries[int(offset) + index], &out[index])
	written^ = count
	return 0
}

@(export)
paxodin_copy_requests :: proc "c" (
	node: ^Handle, token: ^C_Token, offset, want: u32, out: [^]C_Request, written: ^u32,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if written != nil do written^ = 0
	if check := token_check(handle, token); check != .Ok do return i32(check)
	if gate := output_gate(handle); gate != .Ok do return i32(gate)
	if out == nil || written == nil do return i32(Status.Null_Pointer)
	count, range_status := span(handle.batch.request_count, offset, want)
	if range_status != .Ok do return i32(range_status)
	requests := p.requests_slice(&handle.effects)
	for index in 0 ..< int(count) do request_to_c(requests[int(offset) + index], &out[index])
	written^ = count
	return 0
}

@(export)
paxodin_copy_assigned_slots :: proc "c" (
	node: ^Handle, token: ^C_Token, offset, want: u32, out: [^]u64, written: ^u32,
) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if written != nil do written^ = 0
	if check := token_check(handle, token); check != .Ok do return i32(check)
	if handle.batch.phase == .Finished do return i32(Status.Batch_Finished)
	if out == nil || written == nil do return i32(Status.Null_Pointer)
	count, range_status := span(handle.batch.assigned_count, offset, want)
	if range_status != .Ok do return i32(range_status)
	for index in 0 ..< int(count) do out[index] = u64(handle.batch.assigned[int(offset) + index])
	written^ = count
	return 0
}

@(export)
paxodin_finish :: proc "c" (node: ^Handle, token: ^C_Token) -> i32 {
	context = bridge_context()
	handle, status := enter(node)
	if status != .Ok do return i32(status)
	defer leave(handle)
	if check := token_check(handle, token); check != .Ok do return i32(check)
	#partial switch handle.batch.phase {
	case .Finished:
		return 0
	case .Pending:
		// Releasing here would discard records the journal never took.
		return i32(Status.Writes_Unconfirmed)
	}
	handle.batch.phase = .Finished
	return 0
}
