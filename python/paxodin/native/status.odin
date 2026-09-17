// Status codes and their explanations.
//
// Codes below 1000 are the bridge's own. Codes at 1000 and above mirror
// `paxos.Error`, and their explanation text comes from the core's own table --
// there is never a second copy of it here or in Python.
//
// Following POD 0001, an error never only states what failed: every entry names
// the context, the cause, and a `Hint:` line with the corrective action.
package paxodin_bridge

import p "paxos:src"

// Core statuses are 1000 + the Odin enum ordinal. These assertions are the
// drift guard: inserting or reordering a variant in src/errors.odin moves an
// ordinal and fails the build here, instead of silently renumbering the ABI.
CORE_STATUS_BASE :: i32(1000)
#assert(int(p.Error.None) == 0, "Error.None must be zero. Hint: keep None first in src/errors.odin.")
#assert(int(p.Error.Not_Leader) == 19,
	"Error ordinals moved. Hint: a variant was inserted before Not_Leader; update paxodin.h and the ABI version.")
#assert(int(p.Error.Trimmed) == 42,
	"Error ordinals moved. Hint: a variant was added or reordered; update paxodin.h and the ABI version.")

Status :: enum i32 {
	Ok                       = 0,
	Invalid_Argument         = 1,
	Null_Pointer             = 2,
	Abi_Mismatch             = 3,
	Out_Of_Memory            = 4,
	Handle_Closed            = 5,
	Wrong_Process            = 6,
	Reentrant                = 7,
	Poisoned                 = 8,
	Batch_Pending            = 9,
	No_Batch                 = 10,
	Stale_Token              = 11,
	Foreign_Token            = 12,
	Batch_Finished           = 13,
	Writes_Unconfirmed       = 14,
	Writes_Not_Copied        = 15,
	Buffer_Too_Small         = 16,
	Range                    = 17,
	Value_Too_Large          = 18,
	Unsupported_Kind         = 19,
	Unsupported_Capability   = 20,
	Replay_Active            = 21,
	Replay_Not_Active        = 22,
}

// Capability bits. A feature whose wrapper contract and negative tests do not
// exist yet reports its bit clear and refuses the call, rather than half-working.
CAP_REPLICATED_LOG   :: u64(1 << 0)
CAP_REPLAY           :: u64(1 << 1)
CAP_TRIM_ANCHOR      :: u64(1 << 2)
CAP_RECONFIGURATION  :: u64(1 << 3)
CAP_ROTATING_OWNER   :: u64(1 << 4)
CAP_LEARNER          :: u64(1 << 5)
CAP_PRE_DURABLE_SEND :: u64(1 << 6)

CAPABILITIES :: CAP_REPLICATED_LOG | CAP_REPLAY | CAP_TRIM_ANCHOR

core_status :: #force_inline proc "contextless" (err: p.Error) -> i32 {
	return 0 if err == .None else CORE_STATUS_BASE + i32(err)
}

core_error_of :: proc "contextless" (status: i32) -> (p.Error, bool) {
	ordinal := status - CORE_STATUS_BASE
	if ordinal <= 0 || ordinal > i32(max(p.Error)) do return .None, false
	return p.Error(ordinal), true
}

@(rodata)
BRIDGE_EXPLANATIONS := [Status]string{
	.Ok = "No error.",
	.Invalid_Argument = `
-- INVALID ARGUMENT ------------------------------------------------------------

An argument is outside the range this profile accepts.
Hint: Check the value against paxodin_profile(); ids must be non-zero and counts
must not exceed the compiled capacities.
`,
	.Abi_Mismatch = `
-- ABI MISMATCH ----------------------------------------------------------------

The loaded library and its caller disagree about a struct layout or version.
Hint: Reinstall so the package and its native library come from one build. Never
mix them across revisions.
`,
	.Poisoned = `
-- HANDLE POISONED -------------------------------------------------------------

An invariant failed on this handle, so it is unusable rather than pretending the
failure was recovered.
Hint: Close it, reopen the node, and replay the journal. Report the failure with
the revision from paxodin_core_revision().
`,
	.Null_Pointer = `
-- NULL POINTER ----------------------------------------------------------------

A required pointer argument was NULL.
Hint: Pass storage for every out-parameter the signature marks as required.
`,
	.Out_Of_Memory = `
-- OUT OF MEMORY ---------------------------------------------------------------

The bridge could not allocate a handle or its replay scratch.
Hint: A node of this profile needs several hundred kilobytes. Free memory or
choose a smaller compiled profile.
`,
	.Handle_Closed = `
-- HANDLE CLOSED ---------------------------------------------------------------

This handle was already closed; a closed handle is never reopened.
Hint: Create a new node and replay its journal.
`,
	.Wrong_Process = `
-- WRONG PROCESS ---------------------------------------------------------------

This handle was created in another process and cannot be used after fork().
Hint: Create a new node in the child and replay its own journal. Never share one
journal directory between processes.
`,
	.Reentrant = `
-- REENTRANT CALL --------------------------------------------------------------

This handle is already inside a native call on this thread.
Hint: A storage or transport adapter must not call back into the node that is
driving it. Queue the work and run it after the current call returns.
`,
	.Batch_Pending = `
-- BATCH PENDING ---------------------------------------------------------------

A previous batch has not been finished, so no new transition may begin.
Hint: Copy the writes, persist and sync them, confirm, copy the outputs, then
finish the batch. Finishing is what guarantees the records reached the journal
before the next transition overwrites the buffer they describe.
`,
	.No_Batch = `
-- NO BATCH --------------------------------------------------------------------

This handle has no pending batch.
Hint: Begin a transition before copying its effects.
`,
	.Stale_Token = `
-- STALE TOKEN -----------------------------------------------------------------

This token names a batch that has been superseded by a later transition.
Hint: Use the token the most recent begin_* returned. Nothing was changed.
`,
	.Foreign_Token = `
-- FOREIGN TOKEN ---------------------------------------------------------------

This token belongs to a different handle, or to one that has since been closed.
Hint: Tokens are bound to a handle lifetime as well as a generation. Use the
token returned by this handle. Nothing was changed.
`,
	.Batch_Finished = `
-- BATCH FINISHED --------------------------------------------------------------

This batch was released; its native effects are no longer readable.
Hint: Copy every output you need before calling finish.
`,
	.Writes_Unconfirmed = `
-- WRITES UNCONFIRMED ----------------------------------------------------------

This batch still holds writes the host has not confirmed durable, so its
messages, committed entries and host requests may not be read yet.
Hint: Copy every record, append and sync them, then confirm with this token.
Never confirm a failed write; reopen the node and replay the journal instead.
`,
	.Writes_Not_Copied = `
-- WRITES NOT COPIED -----------------------------------------------------------

Confirmation was requested for records the host never received.
Hint: Call copy_writes until it has returned every record in the batch, persist
them in order, and only then confirm.
`,
	.Buffer_Too_Small = `
-- BUFFER TOO SMALL ------------------------------------------------------------

The supplied buffer cannot hold the result; the required length was reported.
Hint: Probe with a zero capacity, allocate the reported length, and call again.
The probe is idempotent and does not repeat the transition.
`,
	.Range = `
-- RANGE OUT OF BOUNDS ---------------------------------------------------------

The requested offset lies beyond the number of records in this batch.
Hint: Read the counts from the batch report before copying.
`,
	.Value_Too_Large = `
-- VALUE TOO LARGE -------------------------------------------------------------

The command is larger than this compiled profile allows.
Hint: Store a reference to the larger object, or install a compatible larger
profile on every member before creating the configuration. No proposal was
admitted and no state changed.
`,
	.Unsupported_Kind = `
-- UNSUPPORTED KIND ------------------------------------------------------------

An enum tag in the input is not one this ABI version defines.
Hint: Check the sender's ABI version; never relabel traffic from another version.
`,
	.Unsupported_Capability = `
-- UNSUPPORTED CAPABILITY ------------------------------------------------------

This library was built without the capability the call requires.
Hint: Read paxodin_capabilities() before using an optional feature. A capability
ships only once its contract and negative tests exist.
`,
	.Replay_Active = `
-- REPLAY ACTIVE ---------------------------------------------------------------

This handle is replaying a journal; transitions are not legal until it restores.
Hint: Finish replay with paxodin_replay_restore, or abandon it with
paxodin_replay_abort.
`,
	.Replay_Not_Active = `
-- REPLAY NOT ACTIVE -----------------------------------------------------------

This handle is live; journal replay applies only to a handle opened for it.
Hint: Open the node with paxodin_node_open_for_replay to rebuild from a journal.
`,
}

explanation_of :: proc(status: i32) -> string {
	if err, is_core := core_error_of(status); is_core {
		// The core's own table is the single source of hint text for a protocol
		// error; duplicating it here is what would let the two drift apart.
		return p.explain_error(err)
	}
	if status < 0 || status > i32(max(Status)) do return ""
	return BRIDGE_EXPLANATIONS[Status(status)]
}
