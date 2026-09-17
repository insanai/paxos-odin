// Conversions between the core's borrowed, pointer-carrying values and the flat
// records that cross the ABI.
//
// Ingress canonicalises rather than validates: the payload above `length` is
// zeroed, so two equal byte strings always produce equal native values and
// Conflicting_Value can never fire on trailing garbage. Egress zeroes the whole
// destination first, so no uninitialised native byte is ever handed to a caller.
package paxodin_bridge

import "base:intrinsics"
import p "paxos:src"

@(private)
entry_from_c :: proc(source: ^C_Entry) -> (entry: Log_Entry, status: Status) {
	switch source.kind {
	case .None:
		return nil, .Ok
	case .Command, .Noop:
		if source.length > MAX_VALUE do return nil, .Value_Too_Large
		// The literal zeroes `body`; only `length` bytes are then written, which
		// is what makes the padding canonical.
		command := Command{kind = source.kind, length = source.length}
		if source.length > 0 {
			intrinsics.mem_copy_non_overlapping(
				&command.body[0], &source.body[0], int(source.length),
			)
		}
		return command, .Ok
	case .Stop_Sign:
		if CAPABILITIES & CAP_RECONFIGURATION == 0 do return nil, .Unsupported_Capability
		return nil, .Unsupported_Capability
	}
	return nil, .Unsupported_Kind
}

@(private)
entry_to_c :: proc "contextless" (entry: ^Log_Entry, destination: ^C_Entry) {
	destination^ = {}
	if entry == nil do return
	if command, is_command := &entry.(Command); is_command {
		destination.kind = command.kind
		destination.length = min(command.length, MAX_VALUE)
		if destination.length > 0 {
			intrinsics.mem_copy_non_overlapping(
				&destination.body[0], &command.body[0], int(destination.length),
			)
		}
		return
	}
	if stop, is_stop := &entry.(Log_Stop_Sign); is_stop {
		destination.kind = .Stop_Sign
		destination.stop.configuration_id = stop.configuration_id
		destination.stop.member_count = u32(stop.members.len)
		for index in 0 ..< stop.members.len {
			destination.stop.members[index] = u16(stop.members.data[index])
		}
		destination.stop.metadata_length = u32(stop.metadata.len)
		if stop.metadata.len > 0 {
			intrinsics.mem_copy_non_overlapping(
				&destination.stop.metadata[0], &stop.metadata.data[0], stop.metadata.len,
			)
		}
	}
}

@(private)
write_to_c :: proc "contextless" (record: p.Write(Log_Entry), destination: ^C_Write) {
	destination^ = {}
	switch value in record {
	case p.Write_Promise:
		destination.kind = .Promise
		destination.ballot = u64(value.ballot)
		destination.flags = WRITE_FLAG_BARRIER
	case p.Write_Promise_At:
		destination.kind = .Promise_At
		destination.ballot = u64(value.ballot)
		destination.slot = value.slot
		destination.flags = WRITE_FLAG_BARRIER
	case p.Write_Vote(Log_Entry):
		destination.kind = .Vote
		destination.ballot = u64(value.ballot)
		destination.slot = value.slot
		destination.flags = WRITE_FLAG_BARRIER
		entry_to_c(value.value, &destination.entry)
	case p.Write_Chosen(Log_Entry):
		destination.kind = .Chosen
		destination.slot = value.slot
		entry_to_c(value.value, &destination.entry)
	case p.Write_Trim:
		destination.kind = .Trim
		destination.trim_id = value.trim_id
		destination.trim_slot = value.chosen_trim_slot
	}
}

// Replay only. The record's value is staged on the handle and the Write points
// at that slot for exactly the fold call, which dereferences it immediately
// (src/ledger.odin:250). One staging slot therefore serves every record.
@(private)
write_from_c :: proc(
	handle: ^Handle, source: ^C_Write,
) -> (record: p.Write(Log_Entry), status: Status) {
	entry := entry_from_c(&source.entry) or_return
	handle.replay.staging = entry
	switch source.kind {
	case .Promise:
		return p.Write_Promise{ballot = p.Ballot(source.ballot)}, .Ok
	case .Promise_At:
		return p.Write_Promise_At{ballot = p.Ballot(source.ballot), slot = source.slot}, .Ok
	case .Vote:
		return p.Write_Vote(Log_Entry) {
			ballot = p.Ballot(source.ballot),
			slot = source.slot,
			value = &handle.replay.staging,
		}, .Ok
	case .Chosen:
		return p.Write_Chosen(Log_Entry) {
			slot = source.slot, value = &handle.replay.staging,
		}, .Ok
	case .Trim:
		return p.Write_Trim{trim_id = source.trim_id, chosen_trim_slot = source.trim_slot}, .Ok
	case .None:
		return nil, .Unsupported_Kind
	}
	return nil, .Unsupported_Kind
}

@(private)
committed_to_c :: proc "contextless" (
	entry: p.Committed(Log_Entry), destination: ^C_Committed,
) {
	destination^ = {}
	destination.slot = entry.slot
	entry_to_c(entry.value, &destination.entry)
}

@(private)
request_to_c :: proc "contextless" (request: p.Host_Request, destination: ^C_Request) {
	destination^ = {}
	switch value in request {
	case p.Serve_Range_Request:
		destination.kind = .Serve_Range
		destination.peer = u16(value.peer)
		destination.first = value.first
		destination.count = value.count
	}
}


// Inbound. The decoded value is staged on the handle and the message points at
// that slot for exactly the duration of the step call. on_promise dereferences
// msg.value for every non-Empty state (src/election.odin), so the pointer must
// always be live, never nil.
@(private)
envelope_from_c :: proc(
	handle: ^Handle, source: ^C_Envelope,
) -> (wire: Log_Wire, status: Status) {
	if source.from == 0 || source.to == 0 do return {}, .Invalid_Argument
	entry := entry_from_c(&source.entry) or_return
	handle.step_value = entry

	message: p.Message(Log_Entry)
	switch source.kind {
	case .Prepare:
		if source.scope > u8(p.Prepare_Scope.Bounded) do return {}, .Unsupported_Kind
		message = p.Prepare_Message {
			ballot = p.Ballot(source.ballot),
			first  = source.first,
			last   = source.last,
			scope  = p.Prepare_Scope(source.scope),
		}
	case .Promise:
		if source.cell_state > u8(p.Cell_State.Chosen) do return {}, .Unsupported_Kind
		message = p.Promise_Message(Log_Entry) {
			ballot = p.Ballot(source.ballot),
			slot   = source.slot,
			vote   = p.Ballot(source.vote),
			state  = p.Cell_State(source.cell_state),
			value  = &handle.step_value,
		}
	case .Promise_Range:
		message = p.Promise_Range_Message {
			ballot         = p.Ballot(source.ballot),
			anchor         = p.Trim_Anchor {
				trim_id = source.trim_id, chosen_trim_slot = source.trim_slot,
			},
			chosen_through = source.decided_through,
			first          = source.first,
			last           = source.last,
			reported       = source.count,
			more           = source.more != 0,
		}
	case .Accept:
		message = p.Accept_Message(Log_Entry) {
			ballot = p.Ballot(source.ballot), slot = source.slot, value = &handle.step_value,
		}
	case .Accepted:
		message = p.Accepted_Message {
			ballot          = p.Ballot(source.ballot),
			slot            = source.slot,
			decided_through = source.decided_through,
		}
	case .Commit:
		message = p.Commit_Message(Log_Entry){slot = source.slot, value = &handle.step_value}
	case .Learn:
		message = p.Learn_Message{from_slot = source.first, count = source.count}
	case .Nack:
		message = p.Nack_Message {
			rejected        = p.Ballot(source.rejected),
			promised        = p.Ballot(source.promised),
			slot            = source.slot,
			decided_through = source.decided_through,
		}
	case .Heartbeat:
		message = p.Heartbeat_Message {
			ballot = p.Ballot(source.ballot), decided_through = source.decided_through,
		}
	case .None:
		return {}, .Unsupported_Kind
	}
	return Log_Wire {
		configuration_id = source.configuration_id,
		envelope = {from = p.Node_Id(source.from), to = p.Node_Id(source.to), message = message},
	}, .Ok
}

// Outbound. The value is copied, never referenced: the pointer in the envelope
// aims into the sending node's ledger and dies at its next transition.
@(private)
envelope_to_c :: proc "contextless" (
	configuration_id: u64, envelope: p.Envelope(Log_Entry), destination: ^C_Envelope,
) {
	destination^ = {}
	destination.configuration_id = configuration_id
	destination.from = u16(envelope.from)
	destination.to = u16(envelope.to)
	switch message in envelope.message {
	case p.Prepare_Message:
		destination.kind = .Prepare
		destination.ballot = u64(message.ballot)
		destination.first = message.first
		destination.last = message.last
		destination.scope = u8(message.scope)
	case p.Promise_Message(Log_Entry):
		destination.kind = .Promise
		destination.ballot = u64(message.ballot)
		destination.slot = message.slot
		destination.vote = u64(message.vote)
		destination.cell_state = u8(message.state)
		// message_value reports a value only for a non-Empty cell; an Empty
		// promise carries a live pointer to a meaningless entry.
		if message.state != .Empty do entry_to_c(message.value, &destination.entry)
	case p.Promise_Range_Message:
		destination.kind = .Promise_Range
		destination.ballot = u64(message.ballot)
		destination.trim_id = message.anchor.trim_id
		destination.trim_slot = message.anchor.chosen_trim_slot
		destination.decided_through = message.chosen_through
		destination.first = message.first
		destination.last = message.last
		destination.count = message.reported
		destination.more = 1 if message.more else 0
	case p.Accept_Message(Log_Entry):
		destination.kind = .Accept
		destination.ballot = u64(message.ballot)
		destination.slot = message.slot
		entry_to_c(message.value, &destination.entry)
	case p.Accepted_Message:
		destination.kind = .Accepted
		destination.ballot = u64(message.ballot)
		destination.slot = message.slot
		destination.decided_through = message.decided_through
	case p.Commit_Message(Log_Entry):
		destination.kind = .Commit
		destination.slot = message.slot
		entry_to_c(message.value, &destination.entry)
	case p.Learn_Message:
		destination.kind = .Learn
		destination.first = message.from_slot
		destination.count = message.count
	case p.Nack_Message:
		destination.kind = .Nack
		destination.rejected = u64(message.rejected)
		destination.promised = u64(message.promised)
		destination.slot = message.slot
		destination.decided_through = message.decided_through
	case p.Heartbeat_Message:
		destination.kind = .Heartbeat
		destination.ballot = u64(message.ballot)
		destination.decided_through = message.decided_through
	}
}
