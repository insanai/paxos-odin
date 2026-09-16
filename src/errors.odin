package paxos

// Comprehensive enumeration of protocol, replicated-log, and learner error codes.
Error :: enum {
	None = 0,

	// Membership errors
	EmptyMembership,
	TooManyMembers,
	InvalidNodeId,
	DuplicateNodeId,
	InvalidReadQuorum,
	InvalidWriteQuorum,
	NonIntersectingQuorums,

	// Input and addressing errors
	NotMember,
	WrongRecipient,
	InvalidPeer,
	InvalidSlot,
	ReadBufferTooSmall,
	UnknownNode,

	// Role and capability errors
	NotVoter,
	NotLearner,
	LearnerIsVoter,
	LearnerMessageForbidden,
	ConfigurationMismatch,

	// Liveness and progress errors
	NotLeader,
	LeaderCatchingUp,
	WindowFull,
	GlobalSlotExhausted,
	EmptyBatch,
	SlotBufferTooSmall,
	BallotExhausted,
	InvalidPromise,
	MissingNoop,
	MissingProposedValue,
	CampaignDisabled,

	// Durability and safety violations
	PromiseRegression,
	ConflictingValue,
	ConflictingCommit,
	ConflictingChosenValue,
	TrimRegression,

	// Replicated log and window errors
	InvalidConfigurationId,
	MetadataTooLarge,
	LogSealed,
	BatchTooLarge,
	ConfigurationIdRegression,
	ConfigurationIdExhausted,
	WindowOverrun,
	Trimmed,
}

// Returns a concise, Elm-style operator explanation and recovery hint for any protocol error.
explain_error :: proc(err: Error) -> string {
	switch err {
	case .None:
		return "No error."

	// Membership errors
	case .EmptyMembership:
		return `
-- EMPTY MEMBERSHIP ------------------------------------------------------------

A consensus configuration needs at least one voting member.
Hint: Pass a slice with at least one non-zero ID to membership_init().
`
	case .TooManyMembers:
		return `
-- TOO MANY MEMBERS ------------------------------------------------------------

The membership is larger than the compile-time MAX_MEMBERS bound.
Hint: Reduce the member slice or deliberately raise MAX_MEMBERS.
`
	case .InvalidNodeId:
		return `
-- INVALID NODE ID -------------------------------------------------------------

Node ID zero is reserved as a sentinel.
Hint: Assign every logical member a stable, non-zero ID.
`
	case .DuplicateNodeId:
		return `
-- DUPLICATE NODE ID -----------------------------------------------------------

The membership contains one voting identity more than once.
Hint: Validate uniqueness before calling membership_init().
`
	case .InvalidReadQuorum:
		return `
-- INVALID READ QUORUM ----------------------------------------------------------

The phase-one size is zero or exceeds the actual member count.
Hint: Choose 1 <= read_quorum_size <= member_count.
`
	case .InvalidWriteQuorum:
		return `
-- INVALID WRITE QUORUM ---------------------------------------------------------

The phase-two size is zero or exceeds the actual member count.
Hint: Choose 1 <= write_quorum_size <= member_count.
`
	case .NonIntersectingQuorums:
		return `
-- NON-INTERSECTING QUORUMS ----------------------------------------------------

A phase-one quorum might miss a prior phase-two quorum.
Hint: Require read_quorum_size + write_quorum_size > member_count.
`

	// Input and addressing errors
	case .NotMember:
		return `
-- NOT A MEMBER ----------------------------------------------------------------

The source, target, or local ID is outside the active membership.
Hint: Check the configuration ID and authenticated peer identity.
`
	case .WrongRecipient:
		return `
-- WRONG RECIPIENT --------------------------------------------------------------

The envelope target is not the node processing it.
Hint: Repair transport routing before retrying the envelope.
`
	case .InvalidPeer:
		return `
-- INVALID PEER -----------------------------------------------------------------

A peer-only operation targeted the local node itself.
Hint: Pass a different member ID to the peer operation.
`
	case .InvalidSlot:
		return `
-- INVALID SLOT -----------------------------------------------------------------

Slot zero is reserved and cannot address a log entry.
Hint: Use a one-based slot.
`
	case .ReadBufferTooSmall:
		return `
-- READ BUFFER TOO SMALL --------------------------------------------------------

The caller buffer cannot hold the available decided suffix.
Hint: Size output for decided_through - from_slot + 1 entries.
`
	case .UnknownNode:
		return `
-- UNKNOWN NODE -----------------------------------------------------------------

The example or host router does not recognize this node ID.
Hint: Reconcile routing state with the active membership.
`

	// Role errors
	case .NotVoter:
		return `
-- NOT A VOTER ------------------------------------------------------------------

A voter-only operation ran on a node outside the voting membership.
Hint: Route proposals and campaigns to a configured voting member.
`
	case .NotLearner:
		return `
-- NOT A LEARNER ----------------------------------------------------------------

A learner-only operation ran on a voting member.
Hint: Use the voter step path; learn_chosen is for non-voting nodes.
`
	case .LearnerIsVoter:
		return `
-- LEARNER IS A VOTER -----------------------------------------------------------

A learner was initialized with an ID inside the voting membership.
Hint: Give learners IDs outside the configured voter set.
`
	case .LearnerMessageForbidden:
		return `
-- LEARNER MESSAGE FORBIDDEN ----------------------------------------------------

A learner received a message kind only voters may process.
Hint: Send learners commits and heartbeats only.
`
	case .ConfigurationMismatch:
		return `
-- CONFIGURATION MISMATCH -------------------------------------------------------

The message's configuration ID differs from the local one.
Hint: Finish the configuration handover before mixing traffic.
`

	// Progress errors
	case .NotLeader:
		return `
-- NOT LEADER ------------------------------------------------------------------

This node has not completed phase one for its current ballot.
Hint: Route to current_leader() or wait for a successful campaign.
`
	case .LeaderCatchingUp:
		return `
-- LEADER CATCHING UP -----------------------------------------------------------

Slots inherited in phase one are undelivered; deliver through leader_base() - 1.
`
	case .WindowFull:
		return `
-- WINDOW FULL ------------------------------------------------------------------

Every consensus cell holds a live slot; this is transient flow control.
Hint: Retry after the memory floor advances past delivered slots.
`
	case .GlobalSlotExhausted:
		return `
-- GLOBAL SLOT EXHAUSTED --------------------------------------------------------

The 64-bit global slot space is exhausted and never wraps to zero.
Hint: This database has reached the end of its logical history.
`
	case .EmptyBatch:
		return `
-- EMPTY BATCH -----------------------------------------------------------------

A batch proposal contained no values.
Hint: Skip the call or submit at least one value.
`
	case .SlotBufferTooSmall:
		return `
-- SLOT BUFFER TOO SMALL ---------------------------------------------------------

The output slot slice is shorter than the value batch.
Hint: Provide at least values.len slot elements.
`
	case .BallotExhausted:
		return `
-- BALLOT EXHAUSTED -------------------------------------------------------------

The node cannot create a round greater than max(u64).
Hint: Stop this epoch and investigate the runaway campaign source.
`
	case .InvalidPromise:
		return `
-- INVALID PROMISE --------------------------------------------------------------

A completion marker claims more accepted entries than window_slots.
Hint: Reject the peer and verify codec and protocol bounds.
`
	case .MissingNoop:
		return `
-- MISSING NO-OP ----------------------------------------------------------------

Leader recovery needs the host's no-op value to fill a hole.
Hint: Supply a deterministic no-op to campaign() or tick().
`
	case .MissingProposedValue:
		return `
-- MISSING PROPOSED VALUE --------------------------------------------------------

An acknowledgement names a slot with no local leader proposal.
Hint: Preserve proposal state until the slot commits.
`
	case .CampaignDisabled:
		return `
-- CAMPAIGN DISABLED ------------------------------------------------------------

This voter is configured to never start elections.
Hint: Campaign from a member whose priority permits leadership.
`

	// Safety errors
	case .PromiseRegression:
		return `
-- PROMISE REGRESSION -----------------------------------------------------------

Replay attempted to move the durable promise to a lower ballot.
Hint: Stop the node and inspect journal ordering or corruption.
`
	case .ConflictingValue:
		return `
-- CONFLICTING VALUE -----------------------------------------------------------

One ballot and slot contain two different values.
Hint: Stop the node and preserve the full message and journal trace.
`
	case .ConflictingCommit:
		return `
-- CONFLICTING COMMIT ----------------------------------------------------------

One slot observed two different committed values.
Hint: Treat this as a safety incident; stop and retain all evidence.
`
	case .ConflictingChosenValue:
		return `
-- CONFLICTING CHOSEN VALUE -----------------------------------------------------

A learner saw two different chosen values for one slot.
Hint: Treat this as a safety incident; stop and retain all evidence.
`
	case .TrimRegression:
		return `
-- TRIM REGRESSION --------------------------------------------------------------

A trim anchor moved backward or conflicts with the adopted one.
Hint: Stop the node and inspect trim records and journal ordering.
`

	// Log errors
	case .InvalidConfigurationId:
		return `
-- INVALID CONFIGURATION ID -----------------------------------------------------

Configuration ID zero is reserved.
Hint: Persist and use a positive epoch identity.
`
	case .MetadataTooLarge:
		return `
-- METADATA TOO LARGE -----------------------------------------------------------

Stop-sign metadata exceeds MAX_METADATA_BYTES.
Hint: Store a smaller durable snapshot identifier or raise the bound.
`
	case .LogSealed:
		return `
-- LOG SEALED -------------------------------------------------------------------

A stop sign is pending or decided in this configuration.
Hint: Finish handover to the decided next configuration.
`
	case .BatchTooLarge:
		return `
-- BATCH TOO LARGE --------------------------------------------------------------

The command batch exceeds MAX_BATCH.
Hint: Split the batch or deliberately raise the compile-time bound.
`
	case .ConfigurationIdRegression:
		return `
-- CONFIGURATION ID REGRESSION --------------------------------------------------

The proposed configuration ID is not newer than the current ID.
Hint: Allocate a strictly increasing durable configuration ID.
`
	case .ConfigurationIdExhausted:
		return `
-- CONFIGURATION ID EXHAUSTED ---------------------------------------------------

No configuration ID exists after max(u64).
Hint: Stop and investigate configuration churn before recovery.
`
	case .WindowOverrun:
		return `
-- WINDOW OVERRUN ---------------------------------------------------------------

A journal record addresses a cell still occupied by an earlier slot.
Hint: Stop the node; the journal ran past the window without an anchor.
`
	case .Trimmed:
		return `
-- LOG ENTRY TRIMMED ------------------------------------------------------------

The requested slot prefix was released and trimmed below the window floor.
Hint: Read trimmed history from the host's long-term journal or snapshot.
`
	}
	return `
-- UNEXPECTED ERROR -------------------------------------------------------------

The error is not one of the library's documented protocol errors.
Hint: Preserve the original host I/O or transport context in logs.
`
}
