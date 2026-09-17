// The C ABI over the paxos-odin core.
//
// Nothing here implements Paxos: every transition is delegated to `paxos:src`.
// The bridge exists to own the boundary the core deliberately leaves to a host --
// it copies borrowed effect values into caller storage, keeps one batch alive
// until the host has discharged it, and turns protocol errors into status codes.
//
// The ABI exports fixed-width integers, explicit lengths, opaque handles and
// status codes. It never exports an Odin union, slice, string or interior pointer.
package paxodin_bridge

import "base:runtime"
import p "paxos:src"

PAXODIN_ABI_VERSION :: 1

// The single compiled capacity profile. These are packaging choices, not limits
// of the core, which is fully parametric.
MAX_MEMBERS   :: 7
WINDOW_SLOTS  :: 256
CHUNK_SLOTS   :: 64
MAX_VALUE     :: 1024
MAX_METADATA  :: p.DEFAULT_MAX_METADATA_BYTES

// A host that owns the durability boundary itself compiles the core with
// .Host_Managed and enforces the order in this bridge, returning a status where
// the core would call os.exit. The .Enforced twin exists so the test suite can
// prove the bridge never trips the core's own gate.
ENFORCED :: #config(PAXODIN_GATE_ENFORCED, false)
when ENFORCED {
	GATE :: p.Durability_Gate.Enforced
} else {
	GATE :: p.Durability_Gate.Host_Managed
}

// The application value, stored inline WINDOW_SLOTS + 2 * CHUNK_SLOTS times.
// `Invalid = 0` keeps zeroed memory from passing as an empty command, and the
// zero padding above `length` makes equal byte strings compare equal.
Command :: struct {
	kind:     Entry_Kind,
	reserved: [3]u8,
	length:   u32,
	body:     [MAX_VALUE]u8,
}

Log_Node :: p.Replicated_Log_Node(
	Command, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, MAX_METADATA, GATE,
)

Log_Entry :: p.Entry(Command, MAX_MEMBERS, MAX_METADATA)

Log_Effects :: p.Effects(Log_Entry, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE)

Log_Ledger :: p.Ledger(Log_Entry, WINDOW_SLOTS)

Log_Stop_Sign :: p.Stop_Sign(MAX_MEMBERS, MAX_METADATA)

Log_Wire :: p.Log_Envelope(Command, MAX_MEMBERS, MAX_METADATA)

// The canonical internal no-op. campaign and tick need a value to fill a hole
// with during recovery (node.noop, src/node.odin:88); the bridge supplies its
// own so the distinction between "no command" and "an empty command" is never
// the caller's problem.
NOOP :: Command{kind = .Noop, length = 0}

// Reported through the ABI so a host can refuse a journal, a peer or a wheel
// whose capacities differ from the ones this library was compiled with. The
// struct sizes are included because a layout disagreement between this library
// and its caller corrupts silently; a fingerprint mismatch is loud.
Profile :: struct {
	abi_version:             u32,
	max_members:             u32,
	window_slots:            u32,
	chunk_slots:             u32,
	max_value_bytes:         u32,
	max_metadata_bytes:      u32,
	max_writes_per_batch:    u32,
	max_messages_per_batch:  u32,
	max_committed_per_batch: u32,
	max_requests_per_batch:  u32,
	sizeof_entry:            u32,
	sizeof_write:            u32,
	sizeof_envelope:         u32,
	sizeof_committed:        u32,
	sizeof_request:          u32,
	sizeof_token:            u32,
	sizeof_report:           u32,
	sizeof_state:            u32,
	sizeof_config:           u32,
	gate_enforced:           u32,
	node_bytes:              u64,
	effects_bytes:           u64,
	capabilities:            u64,
	fingerprint:             u64,
}

// The per-transition capacities, mirroring the formulas on Effects. A caller
// that sizes a buffer from these never sees Buffer_Too_Small.
MAX_WRITES_PER_BATCH    :: 2 * CHUNK_SLOTS + 1
MAX_MESSAGES_PER_BATCH  :: MAX_MEMBERS * CHUNK_SLOTS + 2 * MAX_MEMBERS + 1
MAX_COMMITTED_PER_BATCH :: WINDOW_SLOTS + 1
MAX_REQUESTS_PER_BATCH  :: MAX_MEMBERS

#assert(MAX_VALUE % 8 == 0, "Command payload must stay 8-byte aligned. Hint: keep MAX_VALUE a multiple of 8.")

@(private)
profile_values :: proc "contextless" () -> Profile {
	return Profile {
		abi_version             = PAXODIN_ABI_VERSION,
		max_members             = MAX_MEMBERS,
		window_slots            = WINDOW_SLOTS,
		chunk_slots             = CHUNK_SLOTS,
		max_value_bytes         = MAX_VALUE,
		max_metadata_bytes      = MAX_METADATA,
		max_writes_per_batch    = MAX_WRITES_PER_BATCH,
		max_messages_per_batch  = MAX_MESSAGES_PER_BATCH,
		max_committed_per_batch = MAX_COMMITTED_PER_BATCH,
		max_requests_per_batch  = MAX_REQUESTS_PER_BATCH,
		sizeof_entry            = size_of(C_Entry),
		sizeof_write            = size_of(C_Write),
		sizeof_envelope         = size_of(C_Envelope),
		sizeof_committed        = size_of(C_Committed),
		sizeof_request          = size_of(C_Request),
		sizeof_token            = size_of(C_Token),
		sizeof_report           = size_of(C_Report),
		sizeof_state            = size_of(C_State),
		sizeof_config           = size_of(C_Config),
		gate_enforced           = 1 if ENFORCED else 0,
		node_bytes              = u64(size_of(Log_Node)),
		effects_bytes           = u64(size_of(Log_Effects)),
		capabilities            = CAPABILITIES,
		fingerprint             = 0,
	}
}

// FNV-1a over every field of the profile except the fingerprint itself, so one
// 64-bit word in a journal header or a handshake frame covers the ABI version,
// the capacities, every struct size and the capability mask.
@(private)
profile_fingerprint :: proc "contextless" () -> u64 {
	values := profile_values()
	// The gate is a build-time debugging choice, not a compatibility property:
	// the two libraries have identical capacities and must accept each other's
	// journals and handshakes. Hashing it would split them needlessly.
	values.gate_enforced = 0
	bytes := (cast([^]u8)&values)[:size_of(Profile) - size_of(u64)]
	hash := u64(0xcbf29ce484222325)
	for byte_value in bytes do hash = (hash ~ u64(byte_value)) * 0x100000001b3
	return hash
}

@(export)
paxodin_abi_version :: proc "c" () -> u32 {
	return PAXODIN_ABI_VERSION
}

@(export)
paxodin_capabilities :: proc "c" () -> u64 {
	return CAPABILITIES
}

@(export)
paxodin_profile_fingerprint :: proc "c" () -> u64 {
	return profile_fingerprint()
}

@(export)
paxodin_profile :: proc "c" (out: ^Profile) -> i32 {
	if out == nil do return i32(Status.Null_Pointer)
	out^ = profile_values()
	out.fingerprint = profile_fingerprint()
	return 0
}

@(export)
paxodin_status_count :: proc "c" () -> u32 {
	return u32(max(p.Error)) + 1
}

// Odin strings are length-delimited, never NUL-terminated, so a caller buffer is
// the only safe way to hand one to C. `written` always reports the required
// length, so a caller probes with a zero capacity and retries.
@(private)
copy_text :: proc "contextless" (
	text: string, buffer: [^]u8, capacity: u32, written: ^u32,
) -> i32 {
	needed := u32(len(text))
	if written != nil do written^ = needed
	// A nil buffer or a short one is a probe, not a mistake: report the required
	// length the same way in both cases so one retry path serves them.
	if buffer == nil || capacity < needed + 1 do return i32(Status.Buffer_Too_Small)
	for index in 0 ..< int(needed) do buffer[index] = text[index]
	buffer[needed] = 0
	return 0
}

@(export)
paxodin_core_version :: proc "c" (buffer: [^]u8, capacity: u32, written: ^u32) -> i32 {
	return copy_text(p.VERSION, buffer, capacity, written)
}

// The core's own explanation table is the single source of hint text for a
// protocol error; the Python package must never keep a second copy of it.
@(export)
paxodin_explain :: proc "c" (status: i32, buffer: [^]u8, capacity: u32, written: ^u32) -> i32 {
	context = bridge_context()
	return copy_text(explanation_of(status), buffer, capacity, written)
}
