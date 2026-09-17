// The flat, C-visible shapes of everything that crosses the ABI.
//
// The core's effect values are Odin tagged unions holding pointers into the
// node's ledger, valid only until that node's next transition. Nothing of that
// shape can leave: each union becomes a struct with an explicit kind, each
// pointer becomes a copied, length-delimited payload, and every field has a
// fixed width. A C caller reads these with no knowledge of Odin's layout rules.
package paxodin_bridge

Entry_Kind :: enum u8 {
	None      = 0,
	Command   = 1,
	Noop      = 2,
	Stop_Sign = 3,
}

Write_Kind :: enum u8 {
	None       = 0,
	Promise    = 1,
	Promise_At = 2,
	Vote       = 3,
	Chosen     = 4,
	Trim       = 5,
}

Batch_Phase :: enum u8 {
	Idle      = 0,
	Pending   = 1,
	Confirmed = 2,
	Finished  = 3,
}

Message_Kind :: enum u32 {
	None          = 0,
	Prepare       = 1,
	Promise       = 2,
	Promise_Range = 3,
	Accept        = 4,
	Accepted      = 5,
	Commit        = 6,
	Learn         = 7,
	Nack          = 8,
	Heartbeat     = 9,
}

Request_Kind :: enum u32 {
	None        = 0,
	Serve_Range = 1,
}

// Set on a write that carries a promise or a vote. A decision or a trim record
// is derived state a host may persist behind a cheaper barrier; a promise or a
// vote is the indelible ink whose loss can let a crash choose twice.
WRITE_FLAG_BARRIER :: u32(1 << 0)

// A sealing stop sign, flattened. `member_count` and `metadata_length` bound the
// two arrays; bytes above them are zero and carry no meaning.
C_Stop_Sign :: struct {
	configuration_id: u64,
	member_count:     u32,
	metadata_length:  u32,
	members:          [MAX_MEMBERS]u16,
	metadata:         [MAX_METADATA]u8,
}

// One log entry: an application command, an internal no-op, or a stop sign.
// The distinction is load bearing -- an application that treated all three as
// opaque bytes would apply a no-op as a command and mistake a reconfiguration
// for data -- so `kind` is explicit rather than inferred from `length`.
C_Entry :: struct {
	kind:   Entry_Kind,
	pad:    [3]u8,
	length: u32,
	body:   [MAX_VALUE]u8,
	stop:   C_Stop_Sign,
}

// One durable record. The host appends these in order and syncs before any
// message of the same transition may leave. `entry` is a copy, not a borrow.
C_Write :: struct {
	kind:      Write_Kind,
	pad:       [3]u8,
	flags:     u32,
	ballot:    u64,
	slot:      u64,
	trim_id:   u64,
	trim_slot: u64,
	entry:     C_Entry,
}

// All nine message variants in one shape. `kind` selects which fields carry
// meaning; the rest are zero. A flat struct keeps the wire codec in Python,
// where it can version independently of this ABI, while the bridge stays purely
// structural. `configuration_id` is the Log_Envelope stamp: every envelope
// carries the configuration it belongs to, so stale traffic is refused rather
// than relabelled.
C_Envelope :: struct {
	configuration_id: u64,
	ballot:           u64,
	slot:             u64,
	vote:             u64,
	first:            u64,
	last:             u64,
	rejected:         u64,
	promised:         u64,
	decided_through:  u64,
	trim_id:          u64,
	trim_slot:        u64,
	kind:             Message_Kind,
	count:            u32,
	from:             u16,
	to:               u16,
	scope:            u8,
	cell_state:       u8,
	more:             u8,
	pad:              u8,
	entry:            C_Entry,
}

// One entry released to the application, in slot order.
C_Committed :: struct {
	slot:  u64,
	flags: u32,
	pad:   u32,
	entry: C_Entry,
}

// History a peer asked for that lies below this node's memory floor. The host
// serves it from its own retained journal; the core no longer has it.
C_Request :: struct {
	kind:  Request_Kind,
	peer:  u16,
	pad:   u16,
	first: u64,
	count: u32,
	pad2:  u32,
}

// Identifies one pending batch. The epoch binds it to a handle lifetime as well
// as a generation, so a token minted before a close-and-reopen is rejected
// rather than silently applied to a different node.
C_Token :: struct {
	epoch:      u64,
	generation: u64,
}

// What one transition produced, so a caller can size its buffers once, and
// where the batch has got to, so an interrupted caller can resume at the right
// phase without reconfirming or repeating the transition.
//
// `status` is the PROTOCOL outcome and is independent of the call's own status:
// an error can still leave writes the host is obliged to persist. Checking the
// error is never a substitute for discharging the batch.
//
// `writes_copied_through` is a high-water mark. `confirm` refuses until it
// reaches `write_count`, which turns "confirmed without ever reading the
// records" -- the likeliest integration bug -- into a status instead of a
// silently lost promise.
C_Report :: struct {
	epoch:                 u64,
	generation:            u64,
	assigned_slot:         u64,
	status:                i32,
	phase:                 u32,
	write_count:           u32,
	writes_copied_through: u32,
	message_count:         u32,
	committed_count:       u32,
	request_count:         u32,
	assigned_count:        u32,
	requires_barrier:      u32,
	pad:                   u32,
}

// A read-only view of the node, gathered in one call so a caller never has to
// interleave several queries around a transition.
C_State :: struct {
	configuration_id: u64,
	ballot:           u64,
	decided_through:  u64,
	memory_floor:     u64,
	leader_base:      u64,
	frontier:         u64,
	stop_slot:        u64,
	trim_id:          u64,
	trim_slot:        u64,
	node_id:          u16,
	leader:           u16,
	has_leader:       u8,
	role:             u8,
	sealed:           u8,
	voting_member:    u8,
	campaign_enabled: u8,
	leader_caught_up: u8,
	pad:              [2]u8,
	resubmits_dropped: u32,
}

// Everything needed to start or restore a participant. Zero selects the default
// for every tuning field, exactly as Node_Options does in the core.
C_Config :: struct {
	configuration_id:         u64,
	members:                  [MAX_MEMBERS]u16,
	member_count:             u32,
	read_quorum:              u32,
	write_quorum:             u32,
	election_timeout_ticks:   u32,
	heartbeat_interval_ticks: u32,
	resend_interval_ticks:    u32,
	flags:                    u32,
	node_id:                  u16,
	priority:                 u8,
	pad:                      u8,
}

// C_Config.flags
FLAG_CAMPAIGN_DISABLED  :: u32(1 << 0)
FLAG_GATE_ON_INHERITED  :: u32(1 << 1)
FLAG_ROTATING_OWNERSHIP :: u32(1 << 2)
FLAG_LEARNER            :: u32(1 << 3)
