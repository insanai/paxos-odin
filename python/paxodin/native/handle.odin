// The opaque handle: one participant, its effects batch, and the guards that
// keep a misuse from becoming memory corruption or a process exit.
package paxodin_bridge

import "base:runtime"
import "core:os"
import p "paxos:src"

// "paxodin" plus the ABI version. Checked on every entry, cleared on close, so
// a use-after-close is a status rather than a read of freed memory.
HANDLE_MAGIC :: u64(0x7061786f64696e01)

// Scratch that only journal replay needs. It is allocated for the replay window
// and freed on restore, so a steady-state handle never carries the extra ledger
// (~270 KiB at this profile).
Replay_Scratch :: struct {
	ledger:  Log_Ledger,
	staging: Log_Entry,
}

Batch :: struct {
	phase:                 Batch_Phase,
	requires_barrier:      bool,
	generation:            u64,
	protocol_status:       i32,
	write_count:           u32,
	writes_copied_through: u32,
	message_count:         u32,
	committed_count:       u32,
	request_count:         u32,
	assigned_count:        u32,
	assigned_slot:         p.Slot,
	assigned:              [CHUNK_SLOTS]p.Slot,
}

Handle :: struct {
	magic:           u64,
	epoch:           u64,
	generation:      u64,
	fork_generation: u64,
	pid:             int,
	busy:            bool,
	poisoned:        bool,
	replaying:       bool,
	node_id:         u16,
	configuration_id: u64,
	options:         p.Node_Options,
	membership:      p.Membership(MAX_MEMBERS),
	node:            Log_Node,
	effects:         Log_Effects,
	batch:           Batch,
	replay:          ^Replay_Scratch,
	// Inbound staging. A decoded message points its value here for exactly the
	// duration of one step call, so no pointer the core sees outlives the call
	// and no queued Python frame keeps native memory alive.
	step_value:      Log_Entry,
	propose_in:      [CHUNK_SLOTS]Log_Entry,
}

// Monotone and never reused, so a token minted before a close cannot be
// mistaken for one minted after a reopen that landed on the same address.
@(private) epoch_counter: u64

// fork() leaves a child with a copy of every handle and none of the peer state
// that made it meaningful. pthread_atfork bumps this in the child, so the check
// on every entry is one load and one compare rather than a getpid syscall.
@(private) fork_generation: u64
@(private) atfork_registered: bool
@(private) atfork_available: bool

when ODIN_OS == .Linux || ODIN_OS == .Darwin {
	foreign import libc_system "system:c"

	@(default_calling_convention = "c")
	foreign libc_system {
		pthread_atfork :: proc(prepare, parent, child: proc "c" ()) -> i32 ---
	}

	@(private)
	on_fork_in_child :: proc "c" () {
		fork_generation += 1
	}

	@(private)
	ensure_fork_hook :: proc() {
		if atfork_registered do return
		atfork_registered = true
		atfork_available = pthread_atfork(nil, nil, on_fork_in_child) == 0
	}
} else {
	@(private)
	ensure_fork_hook :: proc() {
		atfork_registered = true
		atfork_available = false
	}
}

@(private)
bridge_context :: proc "contextless" () -> runtime.Context {
	context_value := runtime.default_context()
	// Nothing in the bridge allocates a temporary. A nil temp allocator turns an
	// accidental one into a visible failure instead of a per-thread arena leaked
	// for every thread that ever crossed the boundary.
	context_value.temp_allocator = runtime.nil_allocator()
	return context_value
}

// Validates the handle and takes it. Every export begins here, so the checks
// are in one place and cannot be forgotten on a new entry point.
@(private)
enter :: proc(handle: ^Handle) -> (^Handle, Status) {
	if handle == nil do return nil, .Null_Pointer
	if handle.magic != HANDLE_MAGIC do return nil, .Handle_Closed
	if atfork_available {
		if handle.fork_generation != fork_generation do return nil, .Wrong_Process
	} else if handle.pid != os.get_pid() {
		return nil, .Wrong_Process
	}
	if handle.poisoned do return nil, .Poisoned
	// A plain bool, not an atomic: this catches one thread re-entering a handle
	// from inside an adapter, which a caller-side lock cannot catch. Excluding
	// two threads is the caller's job, and the ABI says so.
	if handle.busy do return nil, .Reentrant
	handle.busy = true
	return handle, .Ok
}

@(private)
leave :: #force_inline proc "contextless" (handle: ^Handle) {
	handle.busy = false
}

@(private)
options_from_c :: proc "contextless" (config: ^C_Config) -> p.Node_Options {
	return p.Node_Options {
		priority = config.priority,
		election_timeout_ticks = config.election_timeout_ticks,
		heartbeat_interval_ticks = config.heartbeat_interval_ticks,
		resend_interval_ticks = config.resend_interval_ticks,
		gate_proposals_on_inherited_prefix = config.flags & FLAG_GATE_ON_INHERITED != 0,
		campaign_disabled = config.flags & FLAG_CAMPAIGN_DISABLED != 0,
		rotating_ownership = config.flags & FLAG_ROTATING_OWNERSHIP != 0,
	}
}

// Validates everything the core would otherwise assert on, before it allocates.
@(private)
config_check :: proc(config: ^C_Config) -> Status {
	if config == nil do return .Null_Pointer
	if config.node_id == 0 do return .Invalid_Argument
	if config.configuration_id == 0 do return .Invalid_Argument
	if config.member_count == 0 || config.member_count > MAX_MEMBERS do return .Invalid_Argument
	if config.read_quorum > MAX_MEMBERS || config.write_quorum > MAX_MEMBERS {
		return .Invalid_Argument
	}
	if config.flags & FLAG_ROTATING_OWNERSHIP != 0 && CAPABILITIES & CAP_ROTATING_OWNER == 0 {
		return .Unsupported_Capability
	}
	if config.flags & FLAG_LEARNER != 0 && CAPABILITIES & CAP_LEARNER == 0 {
		return .Unsupported_Capability
	}
	return .Ok
}

// Allocates a zeroed handle and installs its membership. The node itself is
// left to the caller, which differs between a fresh start, a continuation and a
// replay restore.
@(private)
handle_create :: proc(config: ^C_Config) -> (^Handle, Status, p.Error) {
	ensure_fork_hook()
	if status := config_check(config); status != .Ok do return nil, status, .None

	handle, allocation_error := new(Handle)
	if allocation_error != nil do return nil, .Out_Of_Memory, .None

	ids: [MAX_MEMBERS]p.Node_Id
	for index in 0 ..< int(config.member_count) do ids[index] = p.Node_Id(config.members[index])
	err := p.membership_init(
		&handle.membership, ids[:config.member_count],
		int(config.read_quorum), int(config.write_quorum),
	)
	if err != .None {
		free(handle)
		return nil, .Ok, err
	}

	epoch_counter += 1
	handle.magic = HANDLE_MAGIC
	handle.epoch = epoch_counter
	handle.pid = os.get_pid()
	handle.fork_generation = fork_generation
	handle.node_id = config.node_id
	handle.configuration_id = config.configuration_id
	handle.options = options_from_c(config)
	p.init(&handle.effects)
	return handle, .Ok, .None
}

@(private)
handle_destroy :: proc(handle: ^Handle) -> u32 {
	// A pending batch has confirmed nothing, so every record it holds is
	// abandoned. How many the host merely copied does not change that: a copy
	// without a confirmation is a record whose durability nobody asserted.
	abandoned: u32 = handle.batch.write_count if handle.batch.phase == .Pending else 0
	// effects_init, not effects_reset: this batch can never be completed, and
	// the gate must not be consulted for a discard that is already reported.
	p.init(&handle.effects)
	if handle.replay != nil {
		free(handle.replay)
		handle.replay = nil
	}
	handle.magic = 0
	free(handle)
	return abandoned
}
