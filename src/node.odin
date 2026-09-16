package paxos

import "base:intrinsics"
import "core:container/small_array"

// Proposer status. A Follower acts as acceptor and learner; Preparing runs phase one;
// Leader runs phase two for every slot above its term base.
Role :: enum u8 {
	Follower,
	Preparing,
	Leader,
}

// Runtime tuning for one node. The zero value selects every default, so
// `paxos.init(&node, id, membership)` and
// `paxos.init(&node, id, membership, paxos.Node_Options{priority = 2})` both read naturally.
Node_Options :: struct {
	// Breaks ballot ties between rounds: higher wins. Zero is the lowest priority.
	priority:                           u8,
	// Follower ticks without leader contact before it campaigns. Zero means the default.
	election_timeout_ticks:             u32,
	// Leader ticks between heartbeat broadcasts. Zero means the default.
	heartbeat_interval_ticks:           u32,
	// Leader ticks between bounded retransmission scans. Zero means the default.
	resend_interval_ticks:              u32,
	// Refuse proposals with .Leader_Catching_Up until every inherited slot is delivered.
	gate_proposals_on_inherited_prefix: bool,
	// Start as an acceptor that promises and votes but never campaigns.
	campaign_disabled:                  bool,
	// Rotating slot ownership: every member proposes in its own slots without phase one.
	// Campaigns are refused; stalls are repaired by bounded revocations.
	rotating_ownership:                 bool,
}

// What one phase-one peer has told the candidate about the current chunk.
Election_Peer :: struct {
	anchor:            Trim_Anchor,
	chosen_through:    Slot,
	range_first:       Slot,
	range_last:        Slot,
	expected_in_range: u32,
	received_in_range: u32,
	range_described:   bool,
	more:              bool,
}

// One Multi-Paxos participant: proposer, acceptor, and learner in one bounded value.
// Every array is indexed by window cell or by stable member index; there is no
// per-slot struct, so a scan touches only the columns it needs.
//
// The host persists only the ledger, and only through the Write records it receives.
Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	id:                                 Node_Id,
	membership:                         Membership(MAX_MEMBERS),
	ledger:                             Ledger(Value, WINDOW_SLOTS),

	role:                               Role,
	ballot:                             Ballot,
	highest_observed_round:             u64,
	leader_hint:                        Maybe(Node_Id),
	next_slot:                          Slot,
	leader_base:                        Slot,
	delivered_through:                  Slot,
	memory_floor:                       Slot,
	priority:                           u8,
	voting_member:                      bool,
	campaign_enabled:                   bool,
	// This node's position in membership order, resolved once (learners: 0).
	self_index:                         int,
	gate_proposals_on_inherited_prefix: bool,
	election_ticks:                     u32,
	heartbeat_ticks:                    u32,
	resend_ticks:                       u32,
	election_timeout_ticks:             u32,
	heartbeat_interval_ticks:           u32,
	resend_interval_ticks:              u32,
	peer_decided_through:               [MAX_MEMBERS]Slot,
	// The host's no-op, remembered from the last campaign to fill recovered holes.
	noop:                               Maybe(Value),
	// A decision released past the window edge lives here until the next transition.
	pass_through:                       Value,

	// Rotating ownership.
	ownership:                          bool,
	own_next:                           Slot,
	highest_seen:                       Slot,
	stall_ticks:                        u32,
	gap_ticks:                          u32,
	resubmit:                           small_array.Small_Array(CHUNK_SLOTS, Value),

	// Phase one: what each peer reported for the chunk being recovered.
	election:                           [MAX_MEMBERS]Election_Peer,
	promise_seen:                       [MAX_MEMBERS]Bit_Set(WINDOW_SLOTS),
	recover_base:                       Slot,
	recover_last:                       Slot,
	recovered_slot:                     [WINDOW_SLOTS]Slot,
	recovered_ballot:                   [WINDOW_SLOTS]Ballot,
	recovered_state:                    [WINDOW_SLOTS]Cell_State,
	recovered_value:                    [WINDOW_SLOTS]Value,

	// Phase two: acknowledgements for the slots this leader is driving. The proposal
	// itself is the leader's own vote in its ledger.
	lead_slot:                          [WINDOW_SLOTS]Slot,
	lead_ballot:                        [WINDOW_SLOTS]Ballot,
	acknowledgements:                   [WINDOW_SLOTS]Bit_Set(MAX_MEMBERS),
	acknowledged:                       [WINDOW_SLOTS]u32,
	resend_cursor:                      [MAX_MEMBERS]int,
}

@(private)
clear_election :: proc(node: ^Node($V, $M, $W, $C, $G)) {
	node.election = {}
	node.promise_seen = {}
	node.recover_base = 0
	node.recovered_slot = {}
	node.recovered_ballot = {}
	node.recovered_state = {}
	node.lead_slot = {}
	node.lead_ballot = {}
	node.acknowledgements = {}
	node.acknowledged = {}
}

@(private)
node_assert_valid :: proc(node: ^Node($V, $M, $W, $C, $G)) {
	when INVARIANT_CHECKS {
		assert(node.id != 0, "node id cannot be zero")
		if node.voting_member {
			assert(membership_contains(&node.membership, node.id), "voter outside membership")
		} else {
			assert(!membership_contains(&node.membership, node.id), "non-voter inside membership")
			assert(!node.campaign_enabled, "non-voter cannot campaign")
		}
		assert(membership_count(&node.membership) > 0, "membership cannot be empty")
		assert(node.next_slot >= 1, "next slot must be at least 1")
		l := &node.ledger
		for cell in 0..<W {
			if l.slot[cell] != 0 do assert(cell_of(l.slot[cell], W) == cell, "cell index broken")
			if l.state[cell] == .Voted {
				assert(l.vote_ballot[cell] <= ledger_promise_for(l, cell), "vote above promise")
			}
			used := bit_set_contains(l.used, cell)
			assert(used == (l.state[cell] != .Empty), "used bitmap stale")
			chosen := bit_set_contains(l.chosen, cell)
			assert(chosen == (l.state[cell] == .Chosen), "chosen bitmap stale")
		}
	}
}

@(private)
or_default :: #force_inline proc(value, fallback: u32) -> u32 {
	return value if value != 0 else fallback
}

// Initializes a voting follower. Options default to zero, which means: priority zero,
// default timers, no proposal gate, and campaigning enabled.
node_init :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	options := Node_Options{},
) -> Error {
	#assert(M > 0 && M <= MAX_SUPPORTED_MEMBERS,
		"Invalid member capacity. Hint: Choose MAX_MEMBERS in 1..=65535.")
	#assert(W > 0 && (W & (W - 1)) == 0,
		"Invalid window. Hint: WINDOW_SLOTS must be a power of two.")
	#assert(C > 0 && C <= W,
		"Invalid recovery chunk. Hint: Choose 1 <= CHUNK_SLOTS <= WINDOW_SLOTS.")
	members := membership
	self_index, is_member := membership_index_of(&members, id)
	if !is_member do return .Not_Member

	// Zeroed in place: a compound literal would build a whole Node on the stack, and a
	// Node with a wide window of large values can be megabytes.
	intrinsics.mem_zero(node, size_of(Node(V, M, W, C, G)))
	node.id = id
	node.membership = membership
	node.self_index = self_index
	node.role = .Follower
	node.next_slot = 1
	node.leader_base = 1
	node.priority = options.priority
	node.voting_member = true
	node.campaign_enabled = !options.campaign_disabled
	node.election_timeout_ticks = or_default(
		options.election_timeout_ticks, DEFAULT_ELECTION_TIMEOUT_TICKS,
	)
	node.heartbeat_interval_ticks = or_default(
		options.heartbeat_interval_ticks, DEFAULT_HEARTBEAT_INTERVAL_TICKS,
	)
	node.resend_interval_ticks = or_default(
		options.resend_interval_ticks, DEFAULT_RESEND_INTERVAL_TICKS,
	)
	node.gate_proposals_on_inherited_prefix = options.gate_proposals_on_inherited_prefix
	node.ownership = options.rotating_ownership
	node.own_next = own_slot_from(node, 1)
	node_assert_valid(node)
	return .None
}

// Initializes a non-voting learner. Its id must lie outside the voting membership; it
// accepts commits (and host-certified decisions) and never promises, votes, or campaigns.
node_init_learner :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
) -> Error {
	if id == 0 do return .Invalid_Node_Id
	members := membership
	if membership_count(&members) == 0 do return .Empty_Membership
	if membership_contains(&members, id) do return .Learner_Is_Voter
	node_init(node, membership_get(&members, 0), membership) or_return
	node.id = id
	node.self_index = 0
	node.voting_member = false
	node.campaign_enabled = false
	node_assert_valid(node)
	return .None
}

// Restores a node from a replayed ledger. `floor` is the slot through which the host has
// durably consumed the log (zero for a node that never released anything); cells at or
// below max(floor, anchor) that hold only an open vote are cleared.
node_restore :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	ledger: Ledger(V, W),
	floor: Slot = 0,
	options := Node_Options{},
) -> Error {
	node_init(node, id, membership, options) or_return
	node.ledger = ledger
	node_resume_at(node, max(floor, ledger.anchor.chosen_trim_slot))
	return .None
}

// Resumes an empty node on the same slot line, carrying an inherited trim anchor across a
// configuration handover or a state-image install.
node_continue_at :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	floor: Slot,
	anchor: Trim_Anchor,
	options := Node_Options{},
) -> Error {
	if anchor.chosen_trim_slot > floor do return .Trim_Regression
	node_init(node, id, membership, options) or_return
	node.ledger.anchor = anchor
	node_resume_at(node, floor)
	return .None
}

// Restores a non-voting learner from its decision-only journal.
node_restore_learner :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	id: Node_Id,
	membership: Membership(M),
	ledger: Ledger(V, W),
) -> Error {
	node_init_learner(node, id, membership) or_return
	node.ledger = ledger
	node_resume_at(node, ledger.anchor.chosen_trim_slot)
	return .None
}

// Installs a certified state image at `anchor`, keeping votes and decisions above it. The
// host must persist the image and the anchor before running further transitions.
node_begin_recovery :: proc(node: ^Node($V, $M, $W, $C, $G), anchor: Trim_Anchor) -> Error {
	node_assert_valid(node)
	ledger_apply(&node.ledger, Write_Trim(anchor)) or_return
	node.leader_hint = nil
	node.election_ticks, node.heartbeat_ticks, node.resend_ticks = 0, 0, 0
	node.peer_decided_through = {}
	node.resend_cursor = {}
	node.role = .Follower
	clear_election(node)
	node_resume_at(node, anchor.chosen_trim_slot)
	return .None
}

// Clears open votes at or below `base` and recomputes every frontier from the ledger.
@(private)
node_resume_at :: proc(node: ^Node($V, $M, $W, $C, $G), base: Slot) {
	l := &node.ledger
	for cell in 0..<W {
		if l.slot[cell] != 0 && l.slot[cell] <= base && l.state[cell] != .Chosen {
			ledger_clear_cell(l, cell)
		}
	}
	node.memory_floor = base
	node.delivered_through = base
	node.next_slot = slot_add(max(ledger_highest_used(l), base), 1)
	node.leader_base = node.next_slot
	node.highest_seen = max(node.highest_seen, node.next_slot - 1)
	if node.voting_member do node.own_next = own_slot_from(node, node.next_slot)
	node_assert_valid(node)
}

// Records that the host has durably consumed every released entry through `through`.
node_advance_memory_floor :: proc(node: ^Node($V, $M, $W, $C, $G), through: Slot) -> Error {
	if through > node.delivered_through do return .Invalid_Slot
	node.memory_floor = max(node.memory_floor, through)
	return .None
}

// Adopts a chosen trim record; emits Write_Trim for durability.
node_install_chosen_trim :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	anchor: Trim_Anchor,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if anchor.chosen_trim_slot > node.delivered_through do return .Invalid_Slot
	current := node.ledger.anchor
	if anchor.trim_id < current.trim_id do return .Trim_Regression
	if anchor.trim_id == current.trim_id do return anchor == current ? .None : .Trim_Regression
	if anchor.chosen_trim_slot < current.chosen_trim_slot do return .Trim_Regression
	effects_add_write(effects, Write_Trim(anchor))
	node.ledger.anchor = anchor
	if anchor.chosen_trim_slot > node.memory_floor {
		node.memory_floor = min(anchor.chosen_trim_slot, node.delivered_through)
	}
	return .None
}

// Enables or disables election campaigning for this node.
node_set_campaign_enabled :: proc(node: ^Node($V, $M, $W, $C, $G), enabled: bool) {
	node.campaign_enabled = enabled && node.voting_member
	if !enabled && node.role == .Preparing do node.role = .Follower
}

// ---------------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------------

node_is_campaign_enabled :: proc(node: ^Node($V, $M, $W, $C, $G)) -> bool { return node.campaign_enabled }
node_current_leader :: proc(node: ^Node($V, $M, $W, $C, $G)) -> (Node_Id, bool) {
	return node.leader_hint.?
}
node_decided_through :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Slot { return node.delivered_through }
node_leader_base :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Slot { return node.leader_base }
node_proposal_frontier :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Slot { return node.next_slot }
node_memory_floor :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Slot { return node.memory_floor }
node_trim_anchor :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Trim_Anchor { return node.ledger.anchor }
node_role :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Role { return node.role }
node_ballot :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Ballot { return node.ballot }
node_id :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Node_Id { return node.id }
node_is_voting_member :: proc(node: ^Node($V, $M, $W, $C, $G)) -> bool { return node.voting_member }
node_ledger :: proc(node: ^Node($V, $M, $W, $C, $G)) -> ^Ledger(V, W) { return &node.ledger }

// Reports prefix catch-up only. This is not a lease and not a read barrier.
node_is_leader_caught_up :: proc(node: ^Node($V, $M, $W, $C, $G)) -> bool {
	return node.delivered_through >= node.leader_base - 1
}

// The decided value at `slot`, if it is still resident in the window.
node_committed_at :: proc(node: ^Node($V, $M, $W, $C, $G), slot: Slot) -> (V, bool) {
	if value, ok := ledger_chosen_at(&node.ledger, slot); ok do return value^, true
	return {}, false
}

// Copies the decided suffix starting at `from_slot` into the caller's buffer.
node_read_decided :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from_slot: Slot,
	output: []Committed(V),
) -> (int, Error) {
	if from_slot == 0 do return 0, .Invalid_Slot
	if from_slot > node.delivered_through do return 0, .None
	if from_slot <= node.memory_floor do return 0, .Trimmed
	count := int(node.delivered_through - from_slot + 1)
	if len(output) < count do return 0, .Read_Buffer_Too_Small
	for i in 0..<count {
		slot := from_slot + Slot(i)
		value, ok := ledger_chosen_at(&node.ledger, slot)
		if !ok do return 0, .Trimmed
		output[i] = Committed(V){slot = slot, value = value}
	}
	return count, .None
}
