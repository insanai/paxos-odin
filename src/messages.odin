package paxos

// Wire messages. Every variant is small and fixed-size; a value travels by pointer.
// Outbound, the pointer refers into the sending node's ledger and stays valid until
// that node's next transition, so a host serialises before then. Inbound, the host
// points it at the decoded value for the duration of the `step` call. An in-process
// transport that queues envelopes copies the value at enqueue time, as a codec would.

// What a prepare asks an acceptor to promise: every decree from `first` on (Global,
// the Multi-Paxos takeover) or only the decrees in [first, last] (Bounded, a revocation
// under rotating ownership, recorded per decree).
Prepare_Scope :: enum u8 {
	Global,
	Bounded,
}

// Phase one: promise `ballot` for the decrees the scope names and report your votes in
// [first, last].
Prepare_Message :: struct {
	ballot: Ballot,
	first:  Slot,
	last:   Slot,
	scope:  Prepare_Scope,
}

// One reported vote (state .Voted) or decision (state .Chosen) for one decree.
Promise_Message :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	vote:   Ballot,
	state:  Cell_State,
	value:  ^Value,
}

// The manifest that closes a phase-one answer for one chunk: how many Promise
// messages describe [first, last], whether more used cells lie above, the acceptor's
// trim anchor, and its decided prefix.
Promise_Range_Message :: struct {
	ballot:         Ballot,
	anchor:         Trim_Anchor,
	chosen_through: Slot,
	first:          Slot,
	last:           Slot,
	reported:       u32,
	more:           bool,
}

// Phase two: vote for `value` in `slot` under `ballot`.
Accept_Message :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  ^Value,
}

Accepted_Message :: struct {
	ballot:          Ballot,
	slot:            Slot,
	decided_through: Slot,
}

// A decision. It carries no ballot because a chosen value is final.
Commit_Message :: struct($Value: typeid) {
	slot:  Slot,
	value: ^Value,
}

// Catch-up request for decided slots starting at `from_slot`.
Learn_Message :: struct {
	from_slot: Slot,
	count:     u32,
}

// `slot` is the decree whose accept was refused, or zero for a refused prepare.
Nack_Message :: struct {
	rejected:        Ballot,
	promised:        Ballot,
	slot:            Slot,
	decided_through: Slot,
}

Heartbeat_Message :: struct {
	ballot:          Ballot,
	decided_through: Slot,
}

Message :: union($Value: typeid) {
	Prepare_Message,
	Promise_Message(Value),
	Promise_Range_Message,
	Accept_Message(Value),
	Accepted_Message,
	Commit_Message(Value),
	Learn_Message,
	Nack_Message,
	Heartbeat_Message,
}

Envelope :: struct($Value: typeid) {
	from:    Node_Id,
	to:      Node_Id,
	message: Message(Value),
}

// The value a message carries, when its kind carries one.
message_value :: proc(message: Message($Value)) -> (^Value, bool) {
	#partial switch m in message {
	case Promise_Message(Value): return m.value, m.state != .Empty
	case Accept_Message(Value):  return m.value, true
	case Commit_Message(Value):  return m.value, true
	}
	return nil, false
}

// A newly decided entry released to the application, in slot order. The pointer refers
// into the node's ledger and is valid until the node's next transition.
Committed :: struct($Value: typeid) {
	slot:  Slot,
	value: ^Value,
}

// History a peer asked for that lies below this node's memory floor; the host serves it.
Serve_Range_Request :: struct {
	peer:  Node_Id,
	first: Slot,
	count: u32,
}

Host_Request :: union {
	Serve_Range_Request,
}
