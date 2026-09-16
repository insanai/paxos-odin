package paxos

// Comprehensive enumeration of protocol, replicated-log, and learner error codes.
Error :: enum {
	None = 0,

	// Membership errors
	Empty_Membership,
	Too_Many_Members,
	Invalid_Node_Id,
	Duplicate_Node_Id,
	Invalid_Read_Quorum,
	Invalid_Write_Quorum,
	Non_Intersecting_Quorums,

	// Input and addressing errors
	Not_Member,
	Wrong_Recipient,
	Invalid_Peer,
	Invalid_Slot,
	Read_Buffer_Too_Small,
	Unknown_Node,

	// Role and capability errors
	Not_Voter,
	Not_Learner,
	Learner_Is_Voter,
	Learner_Message_Forbidden,
	Configuration_Mismatch,

	// Liveness and progress errors
	Not_Leader,
	Leader_Catching_Up,
	Window_Full,
	Global_Slot_Exhausted,
	Empty_Batch,
	Slot_Buffer_Too_Small,
	Ballot_Exhausted,
	Invalid_Promise,
	Missing_Noop,
	Missing_Proposed_Value,
	Campaign_Disabled,

	// Durability and safety violations
	Promise_Regression,
	Conflicting_Value,
	Conflicting_Commit,
	Conflicting_Chosen_Value,
	Trim_Regression,

	// Replicated log and window errors
	Invalid_Configuration_Id,
	Metadata_Too_Large,
	Log_Sealed,
	Batch_Too_Large,
	Configuration_Id_Regression,
	Configuration_Id_Exhausted,
	Window_Overrun,
	Trimmed,
}

// Every error explains itself: a title, the cause, and a corrective `Hint:`. The table is
// data, so adding an enum value without an entry fails the exhaustive-explanation test.
@(rodata)
EXPLANATIONS := [Error]string{
	.None = "No error.",
	.Empty_Membership = `
-- EMPTY MEMBERSHIP ------------------------------------------------------------

A consensus configuration needs at least one voting member.
Hint: Pass a slice with at least one non-zero ID to membership_init().
`,
	.Too_Many_Members = `
-- TOO MANY MEMBERS ------------------------------------------------------------

The membership is larger than the compile-time MAX_MEMBERS bound.
Hint: Reduce the member slice or deliberately raise MAX_MEMBERS.
`,
	.Invalid_Node_Id = `
-- INVALID NODE ID -------------------------------------------------------------

Node ID zero is reserved as a sentinel.
Hint: Assign every logical member a stable, non-zero ID.
`,
	.Duplicate_Node_Id = `
-- DUPLICATE NODE ID -----------------------------------------------------------

The membership contains one voting identity more than once.
Hint: Validate uniqueness before calling membership_init().
`,
	.Invalid_Read_Quorum = `
-- INVALID READ QUORUM ----------------------------------------------------------

The phase-one quorum override is negative or exceeds the member count.
Hint: Use zero for a majority, or choose 1 <= read_quorum_size <= member_count.
`,
	.Invalid_Write_Quorum = `
-- INVALID WRITE QUORUM ---------------------------------------------------------

The phase-two quorum override is negative or exceeds the member count.
Hint: Use zero for a majority, or choose 1 <= write_quorum_size <= member_count.
`,
	.Non_Intersecting_Quorums = `
-- NON-INTERSECTING QUORUMS ----------------------------------------------------

A phase-one quorum might miss a prior phase-two quorum.
Hint: Require read_quorum_size + write_quorum_size > member_count.
`,
	.Not_Member = `
-- NOT A MEMBER ----------------------------------------------------------------

The source, target, or local ID is outside the active membership.
Hint: Check the configuration ID and authenticated peer identity.
`,
	.Wrong_Recipient = `
-- WRONG RECIPIENT --------------------------------------------------------------

The envelope target is not the node processing it.
Hint: Repair transport routing before retrying the envelope.
`,
	.Invalid_Peer = `
-- INVALID PEER -----------------------------------------------------------------

A peer-only operation targeted the local node itself.
Hint: Pass a different member ID to the peer operation.
`,
	.Invalid_Slot = `
-- INVALID SLOT -----------------------------------------------------------------

Slot zero is reserved and cannot address a log entry.
Hint: Use a one-based slot.
`,
	.Read_Buffer_Too_Small = `
-- READ BUFFER TOO SMALL --------------------------------------------------------

The caller buffer cannot hold the available decided suffix.
Hint: Size output for decided_through - from_slot + 1 entries.
`,
	.Unknown_Node = `
-- UNKNOWN NODE -----------------------------------------------------------------

The example or host router does not recognize this node ID.
Hint: Reconcile routing state with the active membership.
`,
	.Not_Voter = `
-- NOT A VOTER ------------------------------------------------------------------

A voter-only operation ran on a node outside the voting membership.
Hint: Route proposals and campaigns to a configured voting member.
`,
	.Not_Learner = `
-- NOT A LEARNER ----------------------------------------------------------------

A learner-only operation ran on a voting member.
Hint: Use the voter step path; learn_chosen is for non-voting nodes.
`,
	.Learner_Is_Voter = `
-- LEARNER IS A VOTER -----------------------------------------------------------

A learner was initialized with an ID inside the voting membership.
Hint: Give learners IDs outside the configured voter set.
`,
	.Learner_Message_Forbidden = `
-- LEARNER MESSAGE FORBIDDEN ----------------------------------------------------

A learner received a message kind only voters may process.
Hint: Send learners commits only, or call node_learn_chosen() with a certified decision.
`,
	.Configuration_Mismatch = `
-- CONFIGURATION MISMATCH -------------------------------------------------------

The message's configuration ID differs from the local one.
Hint: Discard stale messages or route them to their original configuration.
Do not relabel old traffic with the new configuration ID.
`,
	.Not_Leader = `
-- NOT LEADER ------------------------------------------------------------------

This node has not completed phase one for its current ballot.
Hint: Route to current_leader() or wait for a successful campaign.
`,
	.Leader_Catching_Up = `
-- LEADER CATCHING UP -----------------------------------------------------------

The leader has not yet delivered every slot inherited from an earlier ballot.
Hint: Process catch-up messages through leader_base() - 1, then retry the proposal.
`,
	.Window_Full = `
-- WINDOW FULL ------------------------------------------------------------------

The proposal or learned slot does not fit in the available consensus window.
Hint: Deliver missing decisions, durably consume the released prefix, and call
advance_memory_floor() through that prefix before retrying. Never advance past it.
`,
	.Global_Slot_Exhausted = `
-- GLOBAL SLOT EXHAUSTED --------------------------------------------------------

The 64-bit global slot space is exhausted and never wraps to zero.
Hint: Stop allocating slots. Move to a separately identified log if more history
is needed; resetting the counter in this log would reuse consensus instances.
`,
	.Empty_Batch = `
-- EMPTY BATCH -----------------------------------------------------------------

A batch proposal contained no values.
Hint: Skip the call or submit at least one value.
`,
	.Slot_Buffer_Too_Small = `
-- SLOT BUFFER TOO SMALL ---------------------------------------------------------

The output slot slice is shorter than the value batch.
Hint: Provide at least values.len slot elements.
`,
	.Ballot_Exhausted = `
-- BALLOT EXHAUSTED -------------------------------------------------------------

The node cannot create a round greater than max(u64).
Hint: Stop this epoch and investigate the runaway campaign source.
`,
	.Invalid_Promise = `
-- INVALID PROMISE --------------------------------------------------------------

A promise describes an invalid recovery range or too many accepted entries.
Hint: Check first/last against the requested chunk and keep accepted_count <=
CHUNK_SLOTS. Verify that all members use compatible recovery chunk sizes.
`,
	.Missing_Noop = `
-- MISSING NO-OP ----------------------------------------------------------------

Leader recovery needs the host's no-op value to fill a hole.
Hint: Supply a deterministic no-op to campaign() or tick().
`,
	.Missing_Proposed_Value = `
-- MISSING PROPOSED VALUE --------------------------------------------------------

An acknowledgement names a slot with no local leader proposal.
Hint: Stop this node and inspect its leader-state lifecycle. Keep the slot
proposal until a decision or a new campaign; do not invent a replacement value.
`,
	.Campaign_Disabled = `
-- CAMPAIGN DISABLED ------------------------------------------------------------

This voter is configured to never start elections.
Hint: Route the request to a campaign-enabled voter, or explicitly enable
this voter with set_campaign_enabled(). Priority only breaks ballot ties.
`,
	.Promise_Regression = `
-- PROMISE REGRESSION -----------------------------------------------------------

Replay attempted to move the durable promise to a lower ballot.
Hint: Stop the node and inspect journal ordering or corruption.
`,
	.Conflicting_Value = `
-- CONFLICTING VALUE -----------------------------------------------------------

One ballot and slot contain two different values.
Hint: Stop the node and preserve the full message and journal trace.
`,
	.Conflicting_Commit = `
-- CONFLICTING COMMIT ----------------------------------------------------------

One slot observed two different committed values.
Hint: Treat this as a safety incident; stop and retain all evidence.
`,
	.Conflicting_Chosen_Value = `
-- CONFLICTING CHOSEN VALUE -----------------------------------------------------

A learner saw two different chosen values for one slot.
Hint: Treat this as a safety incident; stop and retain all evidence.
`,
	.Trim_Regression = `
-- TRIM REGRESSION --------------------------------------------------------------

A trim anchor moved backward or conflicts with the adopted one.
Hint: Stop the node and inspect trim records and journal ordering.
`,
	.Invalid_Configuration_Id = `
-- INVALID CONFIGURATION ID -----------------------------------------------------

Configuration ID zero is reserved.
Hint: Persist and use a positive epoch identity.
`,
	.Metadata_Too_Large = `
-- METADATA TOO LARGE -----------------------------------------------------------

Stop-sign metadata exceeds MAX_METADATA_BYTES.
Hint: Store a smaller durable snapshot identifier or raise the bound.
`,
	.Log_Sealed = `
-- LOG SEALED -------------------------------------------------------------------

A stop sign is pending or decided in this configuration.
Hint: Finish deciding and delivering the stop sign, then install the agreed
state in its next configuration. A pending stop alone does not authorize handover.
`,
	.Batch_Too_Large = `
-- BATCH TOO LARGE --------------------------------------------------------------

The command batch contains more than CHUNK_SLOTS values.
Hint: Split it into batches of at most CHUNK_SLOTS, or increase CHUNK_SLOTS
without exceeding WINDOW_SLOTS.
`,
	.Configuration_Id_Regression = `
-- CONFIGURATION ID REGRESSION --------------------------------------------------

The proposed configuration ID is not newer than the current ID.
Hint: Allocate a strictly increasing durable configuration ID.
`,
	.Configuration_Id_Exhausted = `
-- CONFIGURATION ID EXHAUSTED ---------------------------------------------------

No configuration ID exists after max(u64).
Hint: Stop and investigate configuration churn before recovery.
`,
	.Window_Overrun = `
-- WINDOW OVERRUN ---------------------------------------------------------------

A journal record addresses a cell still occupied by an earlier slot.
Hint: Stop the node and check journal order and retained trim certificates.
Restore the certified prefix before reusing a cell that still holds an open vote.
`,
	.Trimmed = `
-- LOG ENTRY TRIMMED ------------------------------------------------------------

The requested slot prefix was released and trimmed below the window floor.
Hint: Read trimmed history from the host's long-term journal or snapshot.
`,
}

// Returns the Elm-style explanation and recovery hint for a protocol error.
explain_error :: proc(err: Error) -> string {
	return EXPLANATIONS[err]
}
