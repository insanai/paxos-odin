package paxos

import "base:intrinsics"
import "core:container/small_array"
import "core:fmt"
import "core:os"

// Whether an effects batch enforces the persist-then-send contract at runtime.
//
// .Enforced stops the process (with a diagnostic and a hint) when a host reads messages
// or resets a batch before confirming its writes durable. It is the default and the
// only mode a host should use unless it has been audited against the four rules below.
//
// .Host_Managed disables that check for hosts that own the durability boundary
// themselves, for example by grouping several transitions behind one storage barrier.
// Such a host must guarantee, by construction, that:
//   1. every write of a transition is durable before any message of that transition
//      reaches a peer;
//   2. a batch is never discarded while it still holds unconfirmed writes;
//   3. committed entries are applied only after their commit record is durable;
//   4. a crash between the writes and the barrier is recovered from the journal, never by
//      confirming writes that did not complete.
Durability_Gate :: enum {
	Enforced,
	Host_Managed,
}

// Caller-owned output of one transition. Declare it with the same parameters as the
// Node it serves; the compiler rejects a mismatch. The zero value is ready to use.
//
// Nothing in a batch owns a value: writes, messages, and committed entries point into
// the node's ledger. Capacities are per-transition maxima: one recovery chunk of votes,
// each possibly followed by a local decision, plus one promise; one chunk per peer plus
// prepares, heartbeats, and one catch-up request (an ownership tick proposes at most
// one chunk and retransmits only on a quiet tick); one window plus one pass-through
// entry of decisions.
Effects :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	writes:         small_array.Small_Array(2 * CHUNK_SLOTS + 1, Write(Value)),
	messages:       small_array.Small_Array(
		MAX_MEMBERS * CHUNK_SLOTS + 2 * MAX_MEMBERS + 1, Envelope(Value),
	),
	committed:      small_array.Small_Array(WINDOW_SLOTS + 1, Committed(Value)),
	requests:       small_array.Small_Array(MAX_MEMBERS, Host_Request),
	// True while this batch holds writes the host has not confirmed durable.
	writes_pending: bool,
}

host_order_violation :: proc(what: string) -> ! {
	fmt.eprintf(
		"-- DURABILITY ORDER VIOLATION --------------------------------------------------\n\n" +
		"%s.\n\n" +
		"Hint: Persist and sync the pending writes before calling confirm_writes_durable(),\n" +
		"then transmit messages and reset the batch. Never confirm a failed write.\n" +
		"Recover from the durable journal before restarting this stopped node.\n",
		what,
	)
	os.exit(1)
}

// Drops every entry by resetting the lengths; the inline storage is left untouched.
@(private="file")
effects_clear :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	// Four stores, not four generic resizes: this runs on every transition.
	e.writes.len = 0
	e.messages.len = 0
	e.committed.len = 0
	e.requests.len = 0
	e.writes_pending = false
}

// Discards the batch without checking the durability gate. Use it on fresh memory or on
// a batch a crashed process can never complete (for example in a crash simulator).
// Every protocol transition calls effects_reset, which does check the gate.
effects_init :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	effects_clear(e)
}

// Empties the batch for the next transition. With the enforced gate, discarding
// unconfirmed writes stops the process: a lost write can lose a promise or a vote.
effects_reset :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	when G == .Enforced {
		if e.writes_pending do host_order_violation("reset discarded unconfirmed writes")
	}
	effects_clear(e)
}

// The host calls this after every write in the batch is durable (appended and synced).
effects_confirm_writes_durable :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) {
	e.writes_pending = false
}

// Durable records the host must persist, in order, before sending any message.
effects_writes_slice :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) -> []Write(V) {
	return small_array.slice(&e.writes)
}

// Outbound envelopes. With the enforced gate, reading them before confirming the writes
// stops the process.
effects_messages_slice :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) -> []Envelope(V) {
	when G == .Enforced {
		if e.writes_pending do host_order_violation("messages_slice before confirm_writes_durable")
	}
	return small_array.slice(&e.messages)
}

// Newly decided entries, contiguous with everything released before them.
effects_committed_slice :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) -> []Committed(V) {
	return small_array.slice(&e.committed)
}

// History a peer asked for that lies below this node's memory floor.
effects_requests_slice :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) -> []Host_Request {
	return small_array.slice(&e.requests)
}

// True when the batch carries a promise or a vote. Decision and trim records are derived
// state that a host may persist with a cheaper barrier.
effects_requires_power_loss_barrier :: proc(e: ^Effects($V, $M, $W, $C, $G)) -> bool {
	for w in small_array.slice(&e.writes) {
		switch _ in w {
		case Write_Promise, Write_Promise_At, Write_Vote(V): return true
		case Write_Chosen(V), Write_Trim:
		}
	}
	return false
}

effects_is_empty :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G)) -> bool {
	return e.writes.len == 0 && e.messages.len == 0 && e.committed.len == 0 && e.requests.len == 0
}

// Accept requests at a campaign ballot may leave before the local barrier: they ask peers
// to persist a vote and claim nothing about the sender's own durability, and a restarted
// proposer always campaigns at a fresh ballot. An owner's round-zero suggestion is the
// exception: its own vote is the only durable record that the instance was used, so it
// must wait for the barrier or a restart could reuse the ballot for another value.
Pre_Durable_Iterator :: struct($Value: typeid) {
	messages: []Envelope(Value),
	cursor:   int,
}

effects_pre_durable_messages :: proc(e: ^Effects($V, $M, $W, $C, $G)) -> Pre_Durable_Iterator(V) {
	return {messages = small_array.slice(&e.messages)}
}

pre_durable_next :: proc(it: ^Pre_Durable_Iterator($Value)) -> (Envelope(Value), bool) {
	for it.cursor < len(it.messages) {
		envelope := it.messages[it.cursor]
		it.cursor += 1
		if accept, is_accept := envelope.message.(Accept_Message(Value)); is_accept {
			if ballot_round(accept.ballot) > 0 do return envelope, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------------
// Producers (used by the node)
// ---------------------------------------------------------------------------------

// The capacities are sized by the formulas on Effects, so an overrun is a library bug,
// not a host error; it is still checked, with one branch and no second bounds check.
@(cold, private="file")
effects_overrun :: proc(buffer: string) -> ! {
	panic(fmt.tprintf("%s buffer overrun. Hint: report this; the capacity formula is wrong.", buffer))
}

effects_add_write :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G), w: Write(V)) {
	n := e.writes.len
	if n >= len(e.writes.data) do effects_overrun("writes")
	#no_bounds_check e.writes.data[n] = w
	e.writes.len = n + 1
	e.writes_pending = true
}

effects_add_message :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G), envelope: Envelope(V)) {
	n := e.messages.len
	if n >= len(e.messages.data) do effects_overrun("messages")
	#no_bounds_check e.messages.data[n] = envelope
	e.messages.len = n + 1
}

effects_add_committed :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G), c: Committed(V)) {
	n := e.committed.len
	if n >= len(e.committed.data) do effects_overrun("committed")
	#no_bounds_check e.committed.data[n] = c
	e.committed.len = n + 1
}

effects_add_request :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G), r: Host_Request) {
	n := e.requests.len
	if n >= len(e.requests.data) do effects_overrun("requests")
	#no_bounds_check e.requests.data[n] = r
	e.requests.len = n + 1
}
