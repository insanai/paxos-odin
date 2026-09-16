package paxos

import "core:math"
import "core:os"
import "core:fmt"
import "core:container/small_array"

// Stable identity of one voting member. Zero is reserved as a sentinel.
NodeId :: u32

// One-based position in the global protocol log. Zero means no slot.
Slot :: u64

// A totally ordered, globally unique proposal ballot.
Ballot :: struct {
	round:    u64,
	priority: u32,
	node:     NodeId,
}

ballot_zero :: Ballot{round = 0, priority = 0, node = 0}

ballot_less_than :: proc(a, b: Ballot) -> bool {
	if a.round < b.round do return true
	if a.round > b.round do return false
	if a.priority < b.priority do return true
	if a.priority > b.priority do return false
	return a.node < b.node
}

ballot_equal :: proc(a, b: Ballot) -> bool {
	return a.round == b.round && a.priority == b.priority && a.node == b.node
}

// Compares two ballots: returns -1 if a < b, 1 if a > b, 0 if equal.
ballot_order :: proc(a, b: Ballot) -> int {
	if ballot_less_than(a, b) do return -1
	if ballot_equal(a, b) do return 0
	return 1
}

// The chosen-trim anchor an acceptor answers Phase 1 with for its released prefix:
// every slot at or below chosen_trim_slot is chosen under history_hash.
Trim_Anchor :: struct {
	trim_id:          u64,
	chosen_trim_slot: Slot,
	history_hash:     [32]u8,
}

// Whether the generated node enforces the persist-then-send ordering contract at runtime.
Durability_Gate :: enum {
	Enforced,
	Host_Managed,
}

// Proposer status. Follower acts as acceptor/learner; Preparing runs phase 1; Leader runs phase 2.
Role :: enum {
	Follower,
	Preparing,
	Leader,
}

// One acceptor vote: the ballot it was cast in and the value voted for.
Accepted :: struct($Value: typeid) {
	ballot: Ballot,
	value:  Value,
}

// Fixed voting membership and validated quorum sizes.
Membership :: struct($MAX_MEMBERS: int = 7) {
	members:           small_array.Small_Array(MAX_MEMBERS, NodeId),
	read_quorum_size:  int,
	write_quorum_size: int,
}

membership_init :: proc(
	m: ^Membership($MAX_MEMBERS),
	node_ids: []NodeId,
	read_quorum_override: int = 0,
	write_quorum_override: int = 0,
) -> Error {
	if len(node_ids) == 0 do return .EmptyMembership
	if len(node_ids) > MAX_MEMBERS do return .TooManyMembers

	small_array.clear(&m.members)
	for id, index in node_ids {
		if id == 0 do return .InvalidNodeId
		for prev in 0..<index {
			if small_array.get(m.members, prev) == id do return .DuplicateNodeId
		}
		small_array.push_back(&m.members, id)
	}

	total := small_array.len(m.members)
	majority := total / 2 + 1
	m.read_quorum_size = read_quorum_override if read_quorum_override > 0 else majority
	m.write_quorum_size = write_quorum_override if write_quorum_override > 0 else majority

	if m.read_quorum_size <= 0 || m.read_quorum_size > total {
		return .InvalidReadQuorum
	}
	if m.write_quorum_size <= 0 || m.write_quorum_size > total {
		return .InvalidWriteQuorum
	}
	if m.read_quorum_size + m.write_quorum_size <= total {
		return .NonIntersectingQuorums
	}
	return .None
}

membership_index_of :: proc(m: Membership($MAX_MEMBERS), id: NodeId) -> (int, bool) {
	for i in 0..<small_array.len(m.members) {
		if small_array.get(m.members, i) == id do return i, true
	}
	return -1, false
}

membership_contains :: proc(m: Membership($MAX_MEMBERS), id: NodeId) -> bool {
	_, found := membership_index_of(m, id)
	return found
}

membership_count :: proc(m: Membership($MAX_MEMBERS)) -> int {
	return small_array.len(m.members)
}

membership_get :: proc(m: Membership($MAX_MEMBERS), index: int) -> NodeId {
	return small_array.get(m.members, index)
}

membership_slice :: proc(m: ^Membership($MAX_MEMBERS)) -> []NodeId {
	return small_array.slice(&m.members)
}

membership_read_quorum :: proc(m: Membership($MAX_MEMBERS)) -> int {
	return m.read_quorum_size
}

membership_write_quorum :: proc(m: Membership($MAX_MEMBERS)) -> int {
	return m.write_quorum_size
}

membership_quorum :: proc(m: Membership($MAX_MEMBERS)) -> int {
	return m.write_quorum_size
}

// -------------------------------------------------------------
// Wire Protocol Messages
// -------------------------------------------------------------

Prepare_Message :: struct {
	ballot: Ballot,
	first:  Slot,
}

Promise_Message :: struct($Value: typeid) {
	ballot:   Ballot,
	slot:     Slot,
	accepted: Accepted(Value),
}

Promise_Range_Message :: struct {
	ballot:         Ballot,
	anchor:         Trim_Anchor,
	chosen_through: Slot,
	first:          Slot,
	last:           Slot,
	accepted_count: u32,
	more:           bool,
}

Accept_Message :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  Value,
}

Accepted_Message :: struct {
	ballot:         Ballot,
	slot:           Slot,
	decided_through: Slot,
}

Commit_Message :: struct($Value: typeid) {
	slot:  Slot,
	value: Value,
}

Learn_Message :: struct {
	from_slot: Slot,
	count:     u32,
}

Nack_Message :: struct {
	rejected:       Ballot,
	promised:       Ballot,
	decided_through: Slot,
}

Heartbeat_Message :: struct {
	ballot:         Ballot,
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
	from:    NodeId,
	to:      NodeId,
	message: Message(Value),
}

// -------------------------------------------------------------
// Durable State Records and Output Effects
// -------------------------------------------------------------

Write_Promise :: Ballot

Write_Accept :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  Value,
}

Write_Commit :: struct($Value: typeid) {
	slot:  Slot,
	value: Value,
}

Write_Trim_Anchor :: Trim_Anchor

Write :: union($Value: typeid) {
	Write_Promise,
	Write_Accept(Value),
	Write_Commit(Value),
	Write_Trim_Anchor,
}

Committed :: struct($Value: typeid) {
	slot:  Slot,
	value: Value,
}

Host_Request :: union {
	Serve_Range_Request,
}

Serve_Range_Request :: struct {
	peer:  NodeId,
	first: Slot,
	count: u32,
}

Effects :: struct($Value: typeid, $MAX_MEMBERS: int = 7, $WINDOW_SLOTS: int = 256, $GATE: Durability_Gate = .Enforced) {
	writes:           small_array.Small_Array(1 + WINDOW_SLOTS * 2, Write(Value)),
	messages:         small_array.Small_Array(MAX_MEMBERS * (WINDOW_SLOTS + 2), Envelope(Value)),
	committed:        small_array.Small_Array(WINDOW_SLOTS + 1, Committed(Value)),
	requests:         small_array.Small_Array(MAX_MEMBERS, Host_Request),
	writes_confirmed: bool,
}

host_order_violation :: proc(msg: string) -> ! {
	fmt.eprintf("paxos: %s\n", msg)
	os.exit(1)
}

effects_init :: #force_inline proc(effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE)) {
	small_array.clear(&effects.writes)
	small_array.clear(&effects.messages)
	small_array.clear(&effects.committed)
	small_array.clear(&effects.requests)
	effects.writes_confirmed = true
}

effects_reset :: #force_inline proc(effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE)) {
	when GATE == .Enforced {
		if !effects.writes_confirmed {
			host_order_violation("reset discarded unconfirmed writes")
		}
	}
	small_array.clear(&effects.writes)
	small_array.clear(&effects.messages)
	small_array.clear(&effects.committed)
	small_array.clear(&effects.requests)
	effects.writes_confirmed = true
}

effects_confirm_writes_durable :: #force_inline proc(effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE)) {
	effects.writes_confirmed = true
}

effects_writes_slice :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
) -> []Write(Value) {
	return small_array.slice(&effects.writes)
}

effects_messages_slice :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
) -> []Envelope(Value) {
	when GATE == .Enforced {
		if !effects.writes_confirmed {
			host_order_violation("messages_slice before confirm_writes_durable")
		}
	}
	return small_array.slice(&effects.messages)
}

effects_committed_slice :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
) -> []Committed(Value) {
	return small_array.slice(&effects.committed)
}

effects_requests_slice :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
) -> []Host_Request {
	return small_array.slice(&effects.requests)
}

effects_requires_power_loss_barrier :: proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
) -> bool {
	for w in small_array.slice(&effects.writes) {
		switch _ in w {
		case Write_Promise, Write_Accept(Value):
			return true
		case Write_Commit(Value), Write_Trim_Anchor:
		}
	}
	return false
}

effects_add_write :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
	w: Write(Value),
) {
	ok := small_array.push_back(&effects.writes, w)
	assert(ok, "Writes buffer overrun")
	effects.writes_confirmed = false
}

effects_add_message :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
	env: Envelope(Value),
) {
	ok := small_array.push_back(&effects.messages, env)
	assert(ok, "Messages buffer overrun")
}

effects_add_committed :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
	c: Committed(Value),
) {
	ok := small_array.push_back(&effects.committed, c)
	assert(ok, "Committed buffer overrun")
}

effects_add_request :: #force_inline proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
	req: Host_Request,
) {
	ok := small_array.push_back(&effects.requests, req)
	assert(ok, "Requests buffer overrun")
}

// Pre-durable iterator returning only Accept messages that can be pipelined
// before the local disk fsync barrier completes.
Pre_Durable_Iterator :: struct($Value: typeid) {
	messages: []Envelope(Value),
	cursor:   int,
}

effects_pre_durable_messages :: proc(
	effects: ^Effects($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $GATE),
) -> Pre_Durable_Iterator(Value) {
	return Pre_Durable_Iterator(Value){
		messages = small_array.slice(&effects.messages),
		cursor   = 0,
	}
}

pre_durable_next :: proc(it: ^Pre_Durable_Iterator($Value)) -> (Envelope(Value), bool) {
	for it.cursor < len(it.messages) {
		msg := it.messages[it.cursor]
		it.cursor += 1
		#partial switch _ in msg.message {
		case Accept_Message(Value):
			return msg, true
		}
	}
	return Envelope(Value){}, false
}

// -------------------------------------------------------------
// Durable State Machine Storage
// -------------------------------------------------------------

Durable_Cell :: struct($Value: typeid) {
	slot:      Slot,
	accepted:  Maybe(Accepted(Value)),
	committed: Maybe(Value),
}

Durable_State :: struct($Value: typeid, $WINDOW_SLOTS: int = 256) {
	promised: Ballot,
	anchor:   Trim_Anchor,
	cells:    [WINDOW_SLOTS]Durable_Cell(Value),
}

durable_cell_index :: proc(slot: Slot, $WINDOW_SLOTS: int) -> int {
	return int((slot - 1) % Slot(WINDOW_SLOTS))
}

durable_accepted_at :: proc(state: ^Durable_State($Value, $WINDOW_SLOTS), slot: Slot) -> (Accepted(Value), bool) {
	if slot == 0 do return Accepted(Value){}, false
	cell := &state.cells[durable_cell_index(slot, WINDOW_SLOTS)]
	if cell.slot == slot && cell.accepted != nil {
		return cell.accepted.?, true
	}
	return Accepted(Value){}, false
}

durable_committed_at :: proc(state: ^Durable_State($Value, $WINDOW_SLOTS), slot: Slot) -> (Value, bool) {
	if slot == 0 do return Value{}, false
	cell := &state.cells[durable_cell_index(slot, WINDOW_SLOTS)]
	if cell.slot == slot && cell.committed != nil {
		return cell.committed.?, true
	}
	return Value{}, false
}

durable_claim :: proc(state: ^Durable_State($Value, $WINDOW_SLOTS), slot: Slot) -> (^Durable_Cell(Value), bool) {
	cell := &state.cells[durable_cell_index(slot, WINDOW_SLOTS)]
	if cell.slot == slot do return cell, true
	if cell.slot == 0 || (cell.slot < slot && cell.committed != nil) {
		cell^ = Durable_Cell(Value){slot = slot, accepted = nil, committed = nil}
		return cell, true
	}
	return nil, false
}

durable_apply :: proc(state: ^Durable_State($Value, $WINDOW_SLOTS), write: Write(Value)) -> Error {
	switch w in write {
	case Write_Promise:
		if ballot_less_than(w, state.promised) do return .PromiseRegression
		state.promised = w

	case Write_Accept(Value):
		if w.slot == 0 do return .InvalidSlot
		if ballot_less_than(w.ballot, state.promised) do return .PromiseRegression
		cell, ok := durable_claim(state, w.slot)
		if !ok do return .WindowOverrun
		if cell.accepted != nil {
			acc := cell.accepted.?
			if ballot_equal(acc.ballot, w.ballot) && !values_equal(acc.value, w.value) {
				return .ConflictingValue
			}
		}
		state.promised = w.ballot
		cell.accepted = Accepted(Value){ballot = w.ballot, value = w.value}

	case Write_Trim_Anchor:
		if w.trim_id < state.anchor.trim_id || w.chosen_trim_slot < state.anchor.chosen_trim_slot {
			return .TrimRegression
		}
		if w.trim_id == state.anchor.trim_id && state.anchor.trim_id != 0 && !values_equal(w, state.anchor) {
			return .TrimRegression
		}
		state.anchor = w

	case Write_Commit(Value):
		if w.slot == 0 do return .InvalidSlot
		cell, ok := durable_claim(state, w.slot)
		if !ok do return .None
		if cell.committed != nil {
			if !values_equal(cell.committed.?, w.value) {
				return .ConflictingCommit
			}
		}
		cell.committed = w.value
	}
	return .None
}

durable_replay_fold :: proc(state: ^Durable_State($Value, $WINDOW_SLOTS), write: Write(Value)) -> Error {
	switch w in write {
	case Write_Promise:
		if ballot_less_than(state.promised, w) {
			state.promised = w
		}
	case Write_Accept(Value):
		if w.slot == 0 do return .InvalidSlot
		cell, ok := durable_claim(state, w.slot)
		if !ok {
			held := &state.cells[durable_cell_index(w.slot, WINDOW_SLOTS)]
			if held.slot > w.slot do return .None
			return .WindowOverrun
		}
		if cell.accepted != nil {
			acc := cell.accepted.?
			if ballot_equal(acc.ballot, w.ballot) && !values_equal(acc.value, w.value) {
				return .ConflictingValue
			}
		}
		if ballot_less_than(state.promised, w.ballot) {
			state.promised = w.ballot
		}
		cell.accepted = Accepted(Value){ballot = w.ballot, value = w.value}
	case Write_Commit(Value), Write_Trim_Anchor:
		return durable_apply(state, write)
	}
	return .None
}

// -------------------------------------------------------------
// Core Node State Machine
// -------------------------------------------------------------

Recovered_Cell :: struct($Value: typeid) {
	slot:     Slot,
	accepted: Maybe(Accepted(Value)),
}

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

Lead_Cell :: struct($Value: typeid, $MAX_MEMBERS: int = 7) {
	slot:             Slot,
	proposal:         Maybe(Value),
	acknowledgements: bit_set[0..<MAX_MEMBERS],
}

Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = 7,
	$WINDOW_SLOTS: int = 256,
	$CHUNK_SLOTS: int = 64,
	$GATE: Durability_Gate = .Enforced,
) {
	id:                                  NodeId,
	membership:                          Membership(MAX_MEMBERS),
	durable:                             Durable_State(Value, WINDOW_SLOTS),
	role:                                Role,
	ballot:                              Ballot,
	highest_observed_round:              u64,
	leader_hint:                         Maybe(NodeId),
	next_slot:                           Slot,
	leader_base:                         Slot,
	delivered_through:                   Slot,
	leader_priority:                     u32,
	voting_member:                       bool,
	campaign_enabled:                    bool,
	election_ticks:                      u32,
	heartbeat_ticks:                     u32,
	resend_ticks:                        u32,
	peer_decided_through:                [MAX_MEMBERS]Slot,
	election_timeout_ticks:              u32,
	heartbeat_interval_ticks:            u32,
	resend_interval_ticks:               u32,
	gate_proposals_on_inherited_prefix:  bool,

	noop:                                Value,
	noop_set:                            bool,
	election:                            [MAX_MEMBERS]Election_Peer,
	promise_seen:                        [MAX_MEMBERS]Bit_Set(WINDOW_SLOTS),
	recover_base:                        Slot,
	resend_cursor:                       [MAX_MEMBERS]int,
	recovered:                           [WINDOW_SLOTS]Recovered_Cell(Value),
	lead:                                [WINDOW_SLOTS]Lead_Cell(Value, MAX_MEMBERS),
	memory_floor:                        Slot,
}

@(private="file")
clear_election :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) {
	for i in 0..<MAX_MEMBERS {
		node.election[i] = {}
		bit_set_reset(&node.promise_seen[i])
	}
	node.recover_base = 0
	for i in 0..<WINDOW_SLOTS {
		node.recovered[i] = {}
		node.lead[i] = {}
	}
}

@(private="file")
durable_assert_valid :: proc(state: ^Durable_State($Value, $WINDOW_SLOTS)) {
	when ODIN_DEBUG {
		for i in 0..<WINDOW_SLOTS {
			cell := &state.cells[i]
			if cell.slot != 0 {
				assert(durable_cell_index(cell.slot, WINDOW_SLOTS) == i, "Durable cell index invariant broken")
			}
			if cell.accepted != nil {
				assert(!ballot_less_than(state.promised, cell.accepted.?.ballot), "Promised ballot invariant broken")
			}
		}
	}
}

@(private="file")
node_assert_valid :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) {
	when ODIN_DEBUG {
		assert(node.id != 0, "Node ID cannot be zero")
		if node.voting_member {
			assert(membership_contains(node.membership, node.id), "Voting member must be in membership")
		} else {
			assert(!membership_contains(node.membership, node.id), "Non-voter cannot be in membership")
			assert(!node.campaign_enabled, "Non-voter cannot campaign")
		}
		assert(small_array.len(node.membership.members) > 0, "Membership cannot be empty")
		assert(small_array.len(node.membership.members) <= MAX_MEMBERS, "Membership exceeds MAX_MEMBERS")
		assert(node.next_slot >= 1, "Next slot must be at least 1")
		durable_assert_valid(&node.durable)
	}
}

// Initializes a voting node in follower status with default leader priority.
node_init :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
) -> Error {
	return node_init_with_priority(node, id, membership, 0)
}

// Initializes a voting node with a static election priority for deterministic tie-breaking.
node_init_with_priority :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	priority: u32,
) -> Error {
	if !membership_contains(membership, id) do return .NotMember

	node.id = id
	node.membership = membership
	node.durable = {}
	node.role = .Follower
	node.ballot = ballot_zero
	node.highest_observed_round = 0
	node.leader_hint = nil
	node.next_slot = 1
	node.leader_base = 1
	node.delivered_through = 0
	node.leader_priority = priority
	node.voting_member = true
	node.campaign_enabled = true
	node.election_ticks = 0
	node.heartbeat_ticks = 0
	node.resend_ticks = 0
	node.election_timeout_ticks = 10
	node.heartbeat_interval_ticks = 3
	node.resend_interval_ticks = 10
	node.gate_proposals_on_inherited_prefix = false
	node.noop_set = false
	node.recover_base = 0
	node.memory_floor = 0

	for i in 0..<MAX_MEMBERS {
		node.peer_decided_through[i] = 0
		node.resend_cursor[i] = 0
	}
	clear_election(node)
	node_assert_valid(node)
	return .None
}

// Initializes a non-voting learner participant.
node_init_learner :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
) -> Error {
	if id == 0 do return .InvalidNodeId
	if membership_contains(membership, id) do return .LearnerIsVoter

	err := node_init_with_priority(node, small_array.get(membership.members, 0), membership, 0)
	if err != .None do return err
	node.id = id
	node.voting_member = false
	node.campaign_enabled = false
	node_assert_valid(node)
	return .None
}

// Restores a node from replayed durable state at floor zero with default priority.
node_restore :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	durable: Durable_State(Value, WINDOW_SLOTS),
) -> Error {
	return node_restore_with_priority(node, id, membership, durable, 0)
}

// Restores a prioritized node from replayed durable state at floor zero.
node_restore_with_priority :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	durable: Durable_State(Value, WINDOW_SLOTS),
	priority: u32,
) -> Error {
	return node_restore_at(node, id, membership, durable, 0, priority)
}

// Restores a node from replayed durable state resuming at the specified memory floor.
node_restore_at :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	durable: Durable_State(Value, WINDOW_SLOTS),
	floor: Slot,
	priority: u32 = 0,
) -> Error {
	err := node_init_with_priority(node, id, membership, priority)
	if err != .None do return err
	node.durable = durable

	base := math.max(floor, node.durable.anchor.chosen_trim_slot)
	for &cell in node.durable.cells {
		if cell.slot == 0 || cell.slot > base do continue
		if cell.committed == nil {
			cell = {}
		}
	}
	node.memory_floor = base
	node.delivered_through = base
	node.next_slot = math.max(highest_used_slot(node), base) + 1
	node.leader_base = node.next_slot
	node_assert_valid(node)
	return .None
}

// Resumes an empty node on the same slot line carrying an inherited trim anchor across a handover.
node_continue_at :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	floor: Slot,
	anchor: Trim_Anchor,
	priority: u32 = 0,
) -> Error {
	if anchor.chosen_trim_slot > floor do return .TrimRegression
	err := node_init_with_priority(node, id, membership, priority)
	if err != .None do return err
	node.durable.anchor = anchor
	node.memory_floor = floor
	node.delivered_through = floor
	node.next_slot = floor + 1
	node.leader_base = node.next_slot
	node_assert_valid(node)
	return .None
}

// Resets this node onto an installed state snapshot image at anchor; history prefix ends at anchor.
node_begin_recovery :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	anchor: Trim_Anchor,
) -> Error {
	node_assert_valid(node)
	if anchor.chosen_trim_slot < node.durable.anchor.chosen_trim_slot {
		return .TrimRegression
	}
	node.durable.anchor = anchor
	for &cell in node.durable.cells {
		cell = {}
	}
	node.memory_floor = anchor.chosen_trim_slot
	node.delivered_through = anchor.chosen_trim_slot
	node.next_slot = anchor.chosen_trim_slot + 1
	node.role = .Follower
	clear_election(node)
	node_assert_valid(node)
	return .None
}

// Restores a non-voting learner from its commit-only journal.
node_restore_learner :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	id: NodeId,
	membership: Membership(MAX_MEMBERS),
	durable: Durable_State(Value, WINDOW_SLOTS),
) -> Error {
	err := node_init_learner(node, id, membership)
	if err != .None do return err
	node.durable = durable
	node.next_slot = highest_used_slot(node) + 1
	node_assert_valid(node)
	return .None
}

// Records that the host has durably consumed every released entry through through.
node_advance_memory_floor :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	through: Slot,
) -> Error {
	node_assert_valid(node)
	if through > node.delivered_through do return .InvalidSlot
	if through > node.memory_floor {
		node.memory_floor = through
	}
	node_assert_valid(node)
	return .None
}

// Returns the memory floor: the greatest slot whose cell the host has released for reuse.
node_memory_floor :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	return node.memory_floor
}

// Returns the adopted chosen-trim anchor.
node_trim_anchor :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Trim_Anchor {
	return node.durable.anchor
}

// Adopts a chosen trim record; emits Write_Trim_Anchor for durability.
node_install_chosen_trim :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	anchor: Trim_Anchor,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	node_assert_valid(node)
	effects_reset(effects)
	if anchor.chosen_trim_slot > node.delivered_through {
		return .InvalidSlot
	}
	current := &node.durable.anchor
	if anchor.trim_id <= current.trim_id do return .None
	if anchor.chosen_trim_slot < current.chosen_trim_slot {
		return .TrimRegression
	}
	effects_add_write(effects, Write_Trim_Anchor(anchor))
	node.durable.anchor = anchor
	if anchor.chosen_trim_slot > node.memory_floor {
		node.memory_floor = math.min(anchor.chosen_trim_slot, node.delivered_through)
	}
	node_assert_valid(node)
	return .None
}

// Enables or disables election campaigning for this node.
node_set_campaign_enabled :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	enabled: bool,
) {
	node.campaign_enabled = enabled
	if !enabled && node.role == .Preparing {
		node.role = .Follower
	}
}

// Returns true if election campaigning is currently enabled.
node_is_campaign_enabled :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> bool {
	return node.campaign_enabled
}

// Returns the current leader ID hint if known.
node_current_leader :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
) -> (NodeId, bool) {
	if node.leader_hint != nil do return node.leader_hint.?, true
	return 0, false
}

// Returns the greatest contiguous slot released to application.
node_decided_through :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	return node.delivered_through
}

// Returns the slot line index where leadership began.
node_leader_base :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	return node.leader_base
}

// Returns the slot the next proposal would take.
node_proposal_frontier :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	return node.next_slot
}

// Reports whether delivered prefix has caught up to leader base, licensing read-only state queries.
node_is_leader_caught_up :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> bool {
	return node.delivered_through + 1 >= node.leader_base
}

// Returns the current role of the node (Follower, Preparing, Leader).
node_role :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Role {
	return node.role
}

// Returns the current ballot number of this node.
node_ballot :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Ballot {
	return node.ballot
}

// Returns the local node ID.
node_id :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> NodeId {
	return node.id
}

// Returns true if this node is a voting member of the consensus group.
node_is_voting_member :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> bool {
	return node.voting_member
}

// Returns a pointer to this node's internal durable state for inspection.
node_durable_state :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
) -> ^Durable_State(Value, WINDOW_SLOTS) {
	return &node.durable
}

node_committed_at :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	slot: Slot,
) -> (Value, bool) {
	return durable_committed_at(&node.durable, slot)
}

node_read_decided :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from_slot: Slot,
	output: []Committed(Value),
) -> (int, Error) {
	if from_slot == 0 do return 0, .InvalidSlot
	if from_slot > node.delivered_through do return 0, .None
	if from_slot <= node.memory_floor do return 0, .Trimmed

	count := int(node.delivered_through - from_slot + 1)
	if len(output) < count do return 0, .ReadBufferTooSmall

	for i in 0..<count {
		slot := from_slot + Slot(i)
		val, ok := node_committed_at(node, slot)
		if !ok do return 0, .Trimmed
		output[i] = Committed(Value){slot = slot, value = val}
	}
	return count, .None
}

// -------------------------------------------------------------
// Internal Protocol Helpers
// -------------------------------------------------------------

@(private="file")
claim_live :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	slot: Slot,
) -> (^Durable_Cell(Value), bool) {
	if slot <= node.memory_floor do return nil, false
	cell := &node.durable.cells[durable_cell_index(slot, WINDOW_SLOTS)]
	if cell.slot == slot do return cell, true
	if cell.slot == 0 || (cell.slot <= node.memory_floor && cell.committed != nil) {
		cell^ = Durable_Cell(Value){slot = slot, accepted = nil, committed = nil}
		return cell, true
	}
	return nil, false
}

@(private="file")
broadcast_peers :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
	msg: Message(Value),
) {
	for peer in small_array.slice(&node.membership.members) {
		if peer != node.id {
			effects_add_message(effects, Envelope(Value){from = node.id, to = peer, message = msg})
		}
	}
}

@(private="file")
broadcast_all :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
	msg: Message(Value),
) {
	for peer in small_array.slice(&node.membership.members) {
		effects_add_message(effects, Envelope(Value){from = node.id, to = peer, message = msg})
	}
}

@(private="file")
send_to :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	peer: NodeId,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
	msg: Message(Value),
) {
	effects_add_message(effects, Envelope(Value){from = node.id, to = peer, message = msg})
}

@(private="file")
emit_contiguous :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) {
	for {
		next := node.delivered_through + 1
		val, ok := durable_committed_at(&node.durable, next)
		if !ok do break
		effects_add_committed(effects, Committed(Value){slot = next, value = val})
		node.delivered_through = next
	}
}

@(private="file")
send_nack :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	to: NodeId,
	rejected: Ballot,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) {
	send_to(node, to, effects, Nack_Message{
		rejected        = rejected,
		promised        = node.durable.promised,
		decided_through = node.delivered_through,
	})
}

@(private="file")
observe_leader :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	ballot: Ballot,
) {
	node.leader_hint = from
	node.election_ticks = 0
	node.highest_observed_round = math.max(node.highest_observed_round, ballot.round)
	if !ballot_equal(node.ballot, ballot) {
		node.role = .Follower
	}
}

@(private="file")
chunk_limit :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	return node.recover_base + Slot(CHUNK_SLOTS - 1)
}

@(private="file")
highest_used_slot :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	max_s: Slot = 0
	for cell in node.durable.cells {
		if (cell.accepted != nil || cell.committed != nil) && cell.slot > max_s {
			max_s = cell.slot
		}
	}
	return max_s
}

@(private="file")
highest_recovered_slot :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Slot {
	max_s: Slot = 0
	for cell in node.recovered {
		if cell.accepted != nil && cell.slot > max_s {
			max_s = cell.slot
		}
	}
	for cell in node.durable.cells {
		if cell.committed != nil && cell.slot > max_s {
			max_s = cell.slot
		}
	}
	return max_s
}

Fences :: struct {
	trim:        Slot,
	chosen:      Slot,
	chosen_peer: Maybe(NodeId),
}

@(private="file")
quorum_fences :: proc(node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE)) -> Fences {
	max_trim: Slot = node.durable.anchor.chosen_trim_slot
	max_chosen: Slot = node.delivered_through
	chosen_peer: Maybe(NodeId) = nil

	for i in 0..<small_array.len(node.membership.members) {
		peer := &node.election[i]
		if peer.anchor.chosen_trim_slot > max_trim {
			max_trim = peer.anchor.chosen_trim_slot
		}
		if peer.chosen_through > max_chosen {
			max_chosen = peer.chosen_through
			chosen_peer = small_array.get(node.membership.members, i)
		}
	}
	return Fences{trim = max_trim, chosen = max_chosen, chosen_peer = chosen_peer}
}

// -------------------------------------------------------------
// Consensus Transitions
// -------------------------------------------------------------

node_campaign :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	noop: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	effects_reset(effects)
	if !node.voting_member do return .NotVoter
	if !node.campaign_enabled do return .CampaignDisabled
	return start_campaign(node, noop, effects)
}

@(private="file")
start_campaign :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	noop: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	greatest := math.max(node.highest_observed_round, node.ballot.round)
	greatest = math.max(greatest, node.durable.promised.round)
	if greatest == math.max(u64) do return .BallotExhausted

	node.ballot = Ballot{
		round    = greatest + 1,
		priority = node.leader_priority,
		node     = node.id,
	}
	node.role = .Preparing
	node.leader_hint = nil
	node.noop = noop
	node.noop_set = true
	node.election_ticks = 0

	for i in 0..<small_array.len(node.membership.members) {
		node.election[i] = {}
		bit_set_reset(&node.promise_seen[i])
	}
	for i in 0..<WINDOW_SLOTS {
		node.recovered[i] = {}
	}

	node.recover_base = node.delivered_through + 1
	broadcast_all(node, effects, Prepare_Message{
		ballot = node.ballot,
		first  = node.recover_base,
	})
	return .None
}

@(private="file")
on_prepare :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	ballot: Ballot,
	first: Slot,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if ballot_less_than(ballot, node.durable.promised) {
		send_nack(node, from, ballot, effects)
		return .None
	}
	if first == 0 do return .InvalidSlot

	if !ballot_equal(ballot, node.durable.promised) {
		node.durable.promised = ballot
		effects_add_write(effects, Write_Promise(ballot))
	}
	observe_leader(node, from, ballot)
	if ballot_less_than(node.ballot, ballot) {
		node.role = .Follower
	}

	limit := first + Slot(CHUNK_SLOTS - 1)
	accepted_count: u32 = 0
	more := false

	for &cell in node.durable.cells {
		if cell.slot < first || cell.slot == 0 do continue
		if cell.slot <= node.durable.anchor.chosen_trim_slot do continue
		if cell.slot > limit {
			more = true
			continue
		}

		known := cell.accepted
		if known == nil && cell.committed != nil {
			known = Accepted(Value){ballot = ballot_zero, value = cell.committed.?}
		}

		if known != nil {
			accepted_count += 1
			send_to(node, from, effects, Promise_Message(Value){
				ballot   = ballot,
				slot     = cell.slot,
				accepted = known.?,
			})
		}
	}

	send_to(node, from, effects, Promise_Range_Message{
		ballot         = ballot,
		anchor         = node.durable.anchor,
		chosen_through = node.delivered_through,
		first          = first,
		last           = limit,
		accepted_count = accepted_count,
		more           = more,
	})
	return .None
}

@(private="file")
on_promise :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Promise_Message(Value),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if node.role != .Preparing do return .None
	if !ballot_equal(msg.ballot, node.ballot) do return .None
	if msg.slot < node.recover_base do return .None
	if msg.slot > chunk_limit(node) do return .None

	member, found := membership_index_of(node.membership, from)
	if !found do return .None

	idx := durable_cell_index(msg.slot, WINDOW_SLOTS)
	if bit_set_insert(&node.promise_seen[member], idx) {
		node.election[member].received_in_range += 1
	}

	cell := &node.recovered[idx]
	if cell.slot != msg.slot {
		cell^ = Recovered_Cell(Value){slot = msg.slot, accepted = nil}
	}
	if cell.accepted != nil {
		if ballot_less_than(cell.accepted.?.ballot, msg.accepted.ballot) {
			cell.accepted = msg.accepted
		}
	} else {
		cell.accepted = msg.accepted
	}
	return maybe_resolve_chunk(node, effects)
}

@(private="file")
on_promise_range :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Promise_Range_Message,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if node.role != .Preparing do return .None
	if !ballot_equal(msg.ballot, node.ballot) do return .None
	if msg.accepted_count > u32(CHUNK_SLOTS) do return .InvalidPromise
	if msg.last < msg.first do return .InvalidPromise

	member, found := membership_index_of(node.membership, from)
	if !found do return .None

	peer := &node.election[member]
	if msg.anchor.chosen_trim_slot > peer.anchor.chosen_trim_slot {
		peer.anchor = msg.anchor
	}
	peer.chosen_through = math.max(peer.chosen_through, msg.chosen_through)
	if msg.first != node.recover_base do return .None

	peer.range_first = msg.first
	peer.range_last = msg.last
	peer.expected_in_range = msg.accepted_count
	peer.range_described = true
	peer.more = msg.more
	return maybe_resolve_chunk(node, effects)
}

@(private="file")
maybe_resolve_chunk :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	complete := 0
	any_more := false
	for i in 0..<small_array.len(node.membership.members) {
		peer := &node.election[i]
		if !peer.range_described do continue
		if peer.received_in_range >= peer.expected_in_range {
			complete += 1
			if peer.more do any_more = true
		}
	}
	if complete < membership_read_quorum(node.membership) do return .None
	if !node.noop_set do return .MissingNoop

	resolved, err := resolve_chunk(node, any_more, effects)
	if err != .None do return err
	if !resolved do return .None

	if any_more {
		begin_next_chunk(node, effects)
		return .None
	}
	become_leader(node, effects)
	return .None
}

@(private="file")
resolve_chunk :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	any_more: bool,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> (ok: bool, err: Error) {
	fences := quorum_fences(node)
	fence := math.max(fences.trim, fences.chosen)
	slot := math.max(node.recover_base, fence + 1)

	known_high := math.max(highest_used_slot(node), highest_recovered_slot(node))
	known_high = math.max(known_high, fence)

	limit := chunk_limit(node) if any_more else math.min(chunk_limit(node), known_high)
	drive_limit := math.min(limit, node.memory_floor + Slot(WINDOW_SLOTS))

	for slot <= drive_limit {
		val, committed := durable_committed_at(&node.durable, slot)
		if committed {
			broadcast_peers(node, effects, Commit_Message(Value){slot = slot, value = val})
			slot += 1
			continue
		}

		vote, has_vote := recovered_at(node, slot)
		if has_vote {
			if vote.ballot.round == 0 {
				record_commit(node, slot, vote.value, effects) or_return
				broadcast_peers(node, effects, Commit_Message(Value){slot = slot, value = vote.value})
			} else {
				send_accept(node, slot, vote.value, effects) or_return
			}
		} else {
			send_accept(node, slot, node.noop, effects) or_return
		}
		slot += 1
	}

	if fences.chosen > node.delivered_through && fences.chosen_peer != nil {
		send_to(node, fences.chosen_peer.?, effects, Learn_Message{
			from_slot = node.delivered_through + 1,
			count     = u32(CHUNK_SLOTS),
		})
	}
	return drive_limit >= limit, .None
}

@(private="file")
recovered_at :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	slot: Slot,
) -> (Accepted(Value), bool) {
	cell := &node.recovered[durable_cell_index(slot, WINDOW_SLOTS)]
	if cell.slot == slot && cell.accepted != nil {
		return cell.accepted.?, true
	}
	return Accepted(Value){}, false
}

@(private="file")
begin_next_chunk :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) {
	node.recover_base = chunk_limit(node) + 1
	for i in 0..<small_array.len(node.membership.members) {
		node.election[i] = {}
		bit_set_reset(&node.promise_seen[i])
	}
	for i in 0..<WINDOW_SLOTS {
		node.recovered[i] = {}
	}
	broadcast_all(node, effects, Prepare_Message{
		ballot = node.ballot,
		first  = node.recover_base,
	})
}

@(private="file")
become_leader :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) {
	node.role = .Leader
	node.leader_hint = node.id
	fences := quorum_fences(node)
	highest := math.max(highest_used_slot(node), math.max(fences.trim, fences.chosen))
	node.next_slot = math.max(node.next_slot, highest + 1)
	node.leader_base = node.next_slot
	emit_contiguous(node, effects)
}

@(private="file")
send_accept :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	slot: Slot,
	value: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	assert(slot != 0)
	idx := durable_cell_index(slot, WINDOW_SLOTS)
	lead := &node.lead[idx]
	if lead.slot == slot {
		if lead.proposal != nil && !values_equal(lead.proposal.?, value) {
			return .ConflictingValue
		}
	} else {
		lead^ = Lead_Cell(Value, MAX_MEMBERS){slot = slot}
	}
	lead.proposal = value
	lead.acknowledgements = {}

	node.durable.promised = node.ballot
	cell, ok := claim_live(node, slot)
	if !ok do return .WindowOverrun

	cell.accepted = Accepted(Value){ballot = node.ballot, value = value}
	effects_add_write(effects, Write_Accept(Value){ballot = node.ballot, slot = slot, value = value})

	local_member, _ := membership_index_of(node.membership, node.id)
	lead.acknowledgements += {local_member}

	if membership_quorum(node.membership) == 1 {
		record_commit(node, slot, value, effects) or_return
	}

	broadcast_peers(node, effects, Accept_Message(Value){
		ballot = node.ballot,
		slot   = slot,
		value  = value,
	})
	return .None
}

@(private="file")
on_accept :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Accept_Message(Value),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if msg.slot == 0 do return .InvalidSlot
	if msg.slot <= node.durable.anchor.chosen_trim_slot do return .None
	if ballot_less_than(msg.ballot, node.durable.promised) {
		send_nack(node, from, msg.ballot, effects)
		return .None
	}

	cell, ok := claim_live(node, msg.slot)
	if !ok do return .None

	if cell.accepted != nil {
		acc := cell.accepted.?
		if ballot_equal(acc.ballot, msg.ballot) {
			if !values_equal(acc.value, msg.value) do return .ConflictingValue
			send_to(node, from, effects, Accepted_Message{
				ballot          = msg.ballot,
				slot            = msg.slot,
				decided_through = node.delivered_through,
			})
			return .None
		}
	}

	node.durable.promised = msg.ballot
	cell.accepted = Accepted(Value){ballot = msg.ballot, value = msg.value}
	observe_leader(node, from, msg.ballot)

	effects_add_write(effects, Write_Accept(Value){
		ballot = msg.ballot,
		slot   = msg.slot,
		value  = msg.value,
	})
	send_to(node, from, effects, Accepted_Message{
		ballot          = msg.ballot,
		slot            = msg.slot,
		decided_through = node.delivered_through,
	})
	return .None
}

@(private="file")
on_accepted :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Accepted_Message,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if node.role != .Leader do return .None
	if !ballot_equal(msg.ballot, node.ballot) do return .None
	if msg.slot == 0 do return .InvalidSlot

	cell := &node.lead[durable_cell_index(msg.slot, WINDOW_SLOTS)]
	if cell.slot != msg.slot do return .None

	member, found := membership_index_of(node.membership, from)
	if !found do return .None

	cell.acknowledgements += {member}
	if card(cell.acknowledgements) < membership_write_quorum(node.membership) {
		return .None
	}
	if _, ok := durable_committed_at(&node.durable, msg.slot); ok do return .None

	val := cell.proposal.? or_else cell.proposal.?
	if cell.proposal == nil do return .MissingProposedValue

	record_commit(node, msg.slot, val, effects) or_return
	broadcast_peers(node, effects, Commit_Message(Value){slot = msg.slot, value = val})
	return .None
}

@(private="file")
on_commit :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Commit_Message(Value),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	node.leader_hint = from
	node.election_ticks = 0
	return record_commit(node, msg.slot, msg.value, effects)
}

@(private="file")
record_commit :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	slot: Slot,
	value: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if slot == 0 do return .InvalidSlot
	if slot <= node.memory_floor do return .None
	if slot <= node.durable.anchor.chosen_trim_slot do return .None

	cell, ok := claim_live(node, slot)
	if !ok {
		if slot == node.delivered_through + 1 {
			effects_add_write(effects, Write_Commit(Value){slot = slot, value = value})
			effects_add_committed(effects, Committed(Value){slot = slot, value = value})
			node.delivered_through = slot
			emit_contiguous(node, effects)
		}
		return .None
	}

	if cell.committed != nil {
		if !values_equal(cell.committed.?, value) do return .ConflictingCommit
		emit_contiguous(node, effects)
		return .None
	}

	cell.committed = value
	effects_add_write(effects, Write_Commit(Value){slot = slot, value = value})
	emit_contiguous(node, effects)
	return .None
}

@(private="file")
on_heartbeat :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Heartbeat_Message,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) {
	if ballot_less_than(msg.ballot, node.durable.promised) {
		send_nack(node, from, msg.ballot, effects)
		return
	}
	if !ballot_equal(msg.ballot, node.durable.promised) do return
	observe_leader(node, from, msg.ballot)

	if msg.decided_through > node.delivered_through {
		send_to(node, from, effects, Learn_Message{
			from_slot = node.delivered_through + 1,
			count     = u32(CHUNK_SLOTS),
		})
	}
}

@(private="file")
on_learn :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Learn_Message,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	if msg.from_slot == 0 do return .InvalidSlot
	if msg.count == 0 || msg.count > u32(CHUNK_SLOTS) do return .InvalidSlot

	limit := msg.from_slot + Slot(msg.count - 1)
	if msg.from_slot <= node.memory_floor {
		served_through := math.min(limit, node.memory_floor)
		effects_add_request(effects, Serve_Range_Request{
			peer  = from,
			first = msg.from_slot,
			count = u32(served_through - msg.from_slot + 1),
		})
	}

	for &cell in node.durable.cells {
		if cell.slot < msg.from_slot || cell.slot == 0 do continue
		if cell.slot > limit do continue
		if cell.committed != nil {
			send_to(node, from, effects, Commit_Message(Value){
				slot  = cell.slot,
				value = cell.committed.?,
			})
		}
	}
	return .None
}

@(private="file")
on_nack :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	msg: Nack_Message,
) {
	if !ballot_equal(msg.rejected, node.ballot) do return
	if !ballot_less_than(node.ballot, msg.promised) do return
	node.role = .Follower
	node.leader_hint = msg.promised.node
	node.highest_observed_round = math.max(node.highest_observed_round, msg.promised.round)
}

// Proposes a single value after phase one has established this node as leader.
node_propose :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	value: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> (Slot, Error) {
	effects_reset(effects)
	if !node.voting_member do return 0, .NotVoter
	if node.role != .Leader do return 0, .NotLeader
	if node.gate_proposals_on_inherited_prefix && node.delivered_through < node.leader_base - 1 {
		return 0, .LeaderCatchingUp
	}
	if node.next_slot == math.max(Slot) do return 0, .GlobalSlotExhausted
	if node.next_slot - node.memory_floor > Slot(WINDOW_SLOTS) {
		return 0, .WindowFull
	}

	slot := node.next_slot
	node.next_slot += 1
	err := send_accept(node, slot, value, effects)
	if err != .None do return 0, err
	return slot, .None
}

// Proposes a batch of values into consecutive log slots.
node_propose_batch :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	values: []Value,
	slots: []Slot,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> ([]Slot, Error) {
	effects_reset(effects)
	if !node.voting_member do return nil, .NotVoter
	if node.role != .Leader do return nil, .NotLeader
	if node.gate_proposals_on_inherited_prefix && node.delivered_through < node.leader_base - 1 {
		return nil, .LeaderCatchingUp
	}
	if len(values) == 0 do return nil, .EmptyBatch
	if len(values) > CHUNK_SLOTS do return nil, .BatchTooLarge
	if len(slots) < len(values) do return nil, .SlotBufferTooSmall
	if Slot(len(values)) > math.max(Slot) - node.next_slot {
		return nil, .GlobalSlotExhausted
	}

	occupied := node.next_slot - 1 - node.memory_floor
	if occupied >= Slot(WINDOW_SLOTS) do return nil, .WindowFull
	free_space := Slot(WINDOW_SLOTS) - occupied
	if Slot(len(values)) > free_space do return nil, .WindowFull

	for val, i in values {
		s := node.next_slot
		node.next_slot += 1
		slots[i] = s
		err := send_accept(node, s, val, effects)
		if err != .None do return nil, err
	}
	return slots[:len(values)], .None
}

// Advances failure detection, heartbeats, and retransmission timeouts.
node_tick :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	noop: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	effects_reset(effects)
	if !node.voting_member do return .None

	node.election_ticks += 1
	node.heartbeat_ticks += 1
	node.resend_ticks += 1

	if node.role == .Leader {
		if node.heartbeat_ticks >= node.heartbeat_interval_ticks {
			node.heartbeat_ticks = 0
			broadcast_peers(node, effects, Heartbeat_Message{
				ballot          = node.ballot,
				decided_through = node.delivered_through,
			})
		}
		if node.resend_ticks >= node.resend_interval_ticks {
			node.resend_ticks = 0
			for peer in small_array.slice(&node.membership.members) {
				if peer != node.id {
					resend_to(node, peer, effects)
				}
			}
		}
	} else if node.role == .Preparing && node.election_ticks < node.election_timeout_ticks {
		maybe_resolve_chunk(node, effects) or_return
	} else if node.campaign_enabled && node.election_ticks >= node.election_timeout_ticks {
		start_campaign(node, noop, effects) or_return
	}
	return .None
}

@(private="file")
resend_to :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	peer: NodeId,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) {
	peer_idx, found := membership_index_of(node.membership, peer)
	if !found do return

	peer_decided := node.peer_decided_through[peer_idx]
	from_slot := math.max(peer_decided + 1, node.memory_floor + 1)
	limit := from_slot + Slot(CHUNK_SLOTS - 1)

	for &cell in node.durable.cells {
		if cell.slot < from_slot || cell.slot == 0 do continue
		if cell.slot > limit do continue
		if cell.committed != nil {
			send_to(node, peer, effects, Commit_Message(Value){
				slot  = cell.slot,
				value = cell.committed.?,
			})
		} else if cell.accepted != nil && ballot_equal(cell.accepted.?.ballot, node.ballot) {
			send_to(node, peer, effects, Accept_Message(Value){
				ballot = node.ballot,
				slot   = cell.slot,
				value  = cell.accepted.?.value,
			})
		}
	}
}

// Processes one authenticated message addressed to this node.
node_step :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	envelope: Envelope(Value),
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	effects_reset(effects)
	if envelope.to != node.id do return .WrongRecipient

	member, found := membership_index_of(node.membership, envelope.from)
	if !found do return .NotMember

	#partial switch msg in envelope.message {
	case Accepted_Message:
		node.peer_decided_through[member] = math.max(node.peer_decided_through[member], msg.decided_through)
	case Heartbeat_Message:
		node.peer_decided_through[member] = math.max(node.peer_decided_through[member], msg.decided_through)
	case Nack_Message:
		node.peer_decided_through[member] = math.max(node.peer_decided_through[member], msg.decided_through)
	}

	if !node.voting_member {
		#partial switch msg in envelope.message {
		case Commit_Message(Value):
			return on_commit(node, envelope.from, msg, effects)
		case:
			return .LearnerMessageForbidden
		}
	}

	switch msg in envelope.message {
	case Prepare_Message:
		return on_prepare(node, envelope.from, msg.ballot, msg.first, effects)
	case Promise_Message(Value):
		return on_promise(node, envelope.from, msg, effects)
	case Promise_Range_Message:
		return on_promise_range(node, envelope.from, msg, effects)
	case Accept_Message(Value):
		return on_accept(node, envelope.from, msg, effects)
	case Accepted_Message:
		return on_accepted(node, envelope.from, msg, effects)
	case Commit_Message(Value):
		return on_commit(node, envelope.from, msg, effects)
	case Learn_Message:
		return on_learn(node, envelope.from, msg, effects)
	case Nack_Message:
		on_nack(node, envelope.from, msg)
		return .None
	case Heartbeat_Message:
		on_heartbeat(node, envelope.from, msg, effects)
		return .None
	}
	return .None
}

// Installs one value host has certified as chosen by the current acceptor configuration.
node_learn_chosen :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	from: NodeId,
	slot: Slot,
	value: Value,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	effects_reset(effects)
	if node.voting_member do return .NotLearner
	if !membership_contains(node.membership, from) do return .NotMember
	return on_commit(node, from, Commit_Message(Value){slot = slot, value = value}, effects)
}

node_reconnected :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	peer: NodeId,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	effects_reset(effects)
	if !membership_contains(node.membership, peer) do return .NotMember
	if peer == node.id do return .InvalidPeer

	if node.role == .Leader {
		resend_to(node, peer, effects)
	} else if node.leader_hint != nil && node.leader_hint.? == peer {
		send_to(node, peer, effects, Learn_Message{
			from_slot = node.delivered_through + 1,
			count     = u32(CHUNK_SLOTS),
		})
	}
	return .None
}

node_request_catch_up :: proc(
	node: ^Node($Value, $MAX_MEMBERS, $WINDOW_SLOTS, $CHUNK_SLOTS, $GATE),
	peer: NodeId,
	from_slot: Slot,
	effects: ^Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE),
) -> Error {
	effects_reset(effects)
	if !membership_contains(node.membership, peer) do return .NotMember
	if from_slot == 0 do return .InvalidSlot

	send_to(node, peer, effects, Learn_Message{
		from_slot = from_slot,
		count     = u32(CHUNK_SLOTS),
	})
	return .None
}
