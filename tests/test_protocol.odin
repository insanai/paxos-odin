package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_membership_validation :: proc(t: ^testing.T) {
	m: paxos.Membership(7)
	nodes := [3]paxos.NodeId{1, 2, 3}

	err := paxos.membership_init(&m, nodes[:])
	testing.expect(t, err == .None, "Membership init should succeed")
	testing.expect(t, paxos.membership_count(m) == 3, "Count is 3")
	testing.expect(t, paxos.membership_read_quorum(m) == 2, "Read quorum should be 2")
	testing.expect(t, paxos.membership_write_quorum(m) == 2, "Write quorum should be 2")
	testing.expect(t, paxos.membership_contains(m, 2), "Membership contains 2")
	testing.expect(t, !paxos.membership_contains(m, 4), "Membership does not contain 4")

	// Empty membership
	empty_err := paxos.membership_init(&m, []paxos.NodeId{})
	testing.expect(t, empty_err == .EmptyMembership, "Empty membership rejected")

	// Duplicate node ID
	dup_nodes := [3]paxos.NodeId{1, 2, 1}
	dup_err := paxos.membership_init(&m, dup_nodes[:])
	testing.expect(t, dup_err == .DuplicateNodeId, "Duplicate ID rejected")

	// Zero node ID
	zero_nodes := [2]paxos.NodeId{0, 2}
	zero_err := paxos.membership_init(&m, zero_nodes[:])
	testing.expect(t, zero_err == .InvalidNodeId, "Zero ID rejected")
}

@(test)
test_ballot_ordering :: proc(t: ^testing.T) {
	b1 := paxos.Ballot{round = 1, priority = 0, node = 1}
	b2 := paxos.Ballot{round = 1, priority = 0, node = 2}
	b3 := paxos.Ballot{round = 1, priority = 1, node = 1}
	b4 := paxos.Ballot{round = 2, priority = 0, node = 1}

	testing.expect(t, paxos.ballot_less_than(b1, b2), "b1 < b2 by node")
	testing.expect(t, paxos.ballot_less_than(b1, b3), "b1 < b3 by priority")
	testing.expect(t, paxos.ballot_less_than(b1, b4), "b1 < b4 by round")
	testing.expect(t, paxos.ballot_equal(b1, b1), "b1 == b1")
	testing.expect(t, !paxos.ballot_equal(b1, b2), "b1 != b2")
}

@(test)
test_single_node_consensus :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.NodeId{1}
	_ = paxos.membership_init(&m, nodes[:])

	node: paxos.Node(u64, 1, 64, 16)
	err := paxos.node_init(&node, 1, m)
	testing.expect(t, err == .None, "Node init")

	effects: paxos.Effects(u64, 1, 64)
	paxos.effects_init(&effects)

	// Campaign to become leader
	camp_err := paxos.node_campaign(&node, 0, &effects)
	testing.expect(t, camp_err == .None, "Campaign should succeed")

	// Step self prepare message
	paxos.effects_confirm_writes_durable(&effects)
	msgs := paxos.effects_messages_slice(&effects)
	testing.expect(t, len(msgs) == 1, "Emitted 1 prepare message to self")

	step_effects: paxos.Effects(u64, 1, 64)
	paxos.effects_init(&step_effects)

	step_err := paxos.node_step(&node, msgs[0], &step_effects)
	testing.expect(t, step_err == .None, "Step prepare on self")

	paxos.effects_confirm_writes_durable(&step_effects)
	replies := paxos.effects_messages_slice(&step_effects)
	// Expect promise and promise range
	for rep in replies {
		feed_effects: paxos.Effects(u64, 1, 64)
		paxos.effects_init(&feed_effects)
		_ = paxos.node_step(&node, rep, &feed_effects)
		paxos.effects_confirm_writes_durable(&feed_effects)
	}

	testing.expect(t, node.role == .Leader, "Single node should become leader")

	// Propose a value
	prop_effects: paxos.Effects(u64, 1, 64)
	paxos.effects_init(&prop_effects)
	slot, prop_err := paxos.node_propose(&node, 42, &prop_effects)
	testing.expect(t, prop_err == .None, "Proposal should succeed")
	testing.expect(t, slot == 1, "Proposal slot should be 1")

	// Since quorum = 1, local write immediately commits
	committed := paxos.effects_committed_slice(&prop_effects)
	testing.expect(t, len(committed) == 1, "Should have 1 committed entry")
	testing.expect(t, committed[0].slot == 1 && committed[0].value == 42, "Committed value 42")
	testing.expect(t, paxos.node_decided_through(&node) == 1, "Decided through should be 1")
}

@(test)
test_three_node_cluster_agreement :: proc(t: ^testing.T) {
	m: paxos.Membership(3)
	nodes := [3]paxos.NodeId{1, 2, 3}
	_ = paxos.membership_init(&m, nodes[:])

	n1: paxos.Node(u64, 3, 64, 16)
	n2: paxos.Node(u64, 3, 64, 16)
	n3: paxos.Node(u64, 3, 64, 16)

	_ = paxos.node_init(&n1, 1, m)
	_ = paxos.node_init(&n2, 2, m)
	_ = paxos.node_init(&n3, 3, m)

	eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&eff)

	// Node 1 campaigns
	_ = paxos.node_campaign(&n1, 0, &eff)
	paxos.effects_confirm_writes_durable(&eff)
	prepares := paxos.effects_messages_slice(&eff)
	testing.expect(t, len(prepares) == 3, "Sent 3 prepares (including self)")

	// Step prepare on N1 and N2 (forming quorum of 2)
	eff1: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&eff1)
	_ = paxos.node_step(&n1, prepares[0], &eff1)
	paxos.effects_confirm_writes_durable(&eff1)

	eff2: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&eff2)
	_ = paxos.node_step(&n2, prepares[1], &eff2)
	paxos.effects_confirm_writes_durable(&eff2)

	// Feed replies from N1 and N2 back to N1
	feed_eff: paxos.Effects(u64, 3, 64)
	for msg in paxos.effects_messages_slice(&eff1) {
		paxos.effects_init(&feed_eff)
		_ = paxos.node_step(&n1, msg, &feed_eff)
		paxos.effects_confirm_writes_durable(&feed_eff)
	}
	for msg in paxos.effects_messages_slice(&eff2) {
		paxos.effects_init(&feed_eff)
		_ = paxos.node_step(&n1, msg, &feed_eff)
		paxos.effects_confirm_writes_durable(&feed_eff)
	}

	testing.expect(t, n1.role == .Leader, "Node 1 should become leader after majority promises")

	// Node 1 proposes value 999
	prop_eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&prop_eff)
	slot, prop_err := paxos.node_propose(&n1, 999, &prop_eff)
	testing.expect(t, prop_err == .None, "Propose on N1")
	testing.expect(t, slot == 1, "Slot is 1")

	paxos.effects_confirm_writes_durable(&prop_eff)
	accept_msgs := paxos.effects_messages_slice(&prop_eff)
	// Node 1 broadcasts accept to peers (N2 and N3)
	testing.expect(t, len(accept_msgs) == 2, "Accept sent to 2 peers")

	// Node 2 steps Accept
	n2_accept_eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&n2_accept_eff)
	_ = paxos.node_step(&n2, accept_msgs[0], &n2_accept_eff)
	paxos.effects_confirm_writes_durable(&n2_accept_eff)

	// Node 2 emits Accepted reply
	n2_replies := paxos.effects_messages_slice(&n2_accept_eff)
	testing.expect(t, len(n2_replies) == 1, "Node 2 emits 1 Accepted reply")

	// Node 1 steps Accepted reply from Node 2
	n1_commit_eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&n1_commit_eff)
	_ = paxos.node_step(&n1, n2_replies[0], &n1_commit_eff)
	paxos.effects_confirm_writes_durable(&n1_commit_eff)

	// Now Node 1 has quorum (local vote + N2 vote) -> COMMITS!
	committed := paxos.effects_committed_slice(&n1_commit_eff)
	testing.expect(t, len(committed) == 1, "Node 1 committed the entry")
	testing.expect(t, committed[0].slot == 1 && committed[0].value == 999, "Committed value is 999")
	testing.expect(t, paxos.node_decided_through(&n1) == 1, "Node 1 decided through is 1")

	// Node 1 broadcasts Commit to peers
	commits := paxos.effects_messages_slice(&n1_commit_eff)
	testing.expect(t, len(commits) == 2, "Node 1 broadcasts 2 commit envelopes")

	// Node 2 steps Commit
	n2_step_commit_eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&n2_step_commit_eff)
	_ = paxos.node_step(&n2, commits[0], &n2_step_commit_eff)
	paxos.effects_confirm_writes_durable(&n2_step_commit_eff)

	testing.expect(t, paxos.node_decided_through(&n2) == 1, "Node 2 decided through is 1")
	val2, ok2 := paxos.node_committed_at(&n2, 1)
	testing.expect(t, ok2 && val2 == 999, "Node 2 committed value is 999")
}

@(test)
test_idiomatic_api :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.NodeId{1}
	paxos.init(&m, nodes[:])

	node: paxos.Node(u64, 1, 64, 16)
	err := paxos.init(&node, 1, m)
	testing.expect(t, err == .None, "paxos.init node")
	testing.expect(t, paxos.id(&node) == 1, "paxos.id")
	testing.expect(t, paxos.is_voting_member(&node), "paxos.is_voting_member")
	testing.expect(t, paxos.role(&node) == .Follower, "paxos.role follower")

	eff: paxos.Effects(u64, 1, 64)
	paxos.init(&eff)

	camp_err := paxos.campaign(&node, 0, &eff)
	testing.expect(t, camp_err == .None, "paxos.campaign")
	paxos.confirm_writes_durable(&eff)

	for msg in paxos.messages_slice(&eff) {
		step_eff: paxos.Effects(u64, 1, 64)
		paxos.init(&step_eff)
		_ = paxos.step(&node, msg, &step_eff)
		paxos.confirm_writes_durable(&step_eff)
		for rep in paxos.messages_slice(&step_eff) {
			feed_eff: paxos.Effects(u64, 1, 64)
			paxos.init(&feed_eff)
			_ = paxos.step(&node, rep, &feed_eff)
			paxos.confirm_writes_durable(&feed_eff)
		}
	}
	testing.expect(t, paxos.role(&node) == .Leader, "paxos.role leader")
	testing.expect(t, paxos.is_leader_caught_up(&node), "paxos.is_leader_caught_up")

	prop_eff: paxos.Effects(u64, 1, 64)
	paxos.init(&prop_eff)
	slot, prop_err := paxos.propose(&node, 8888, &prop_eff)
	testing.expect(t, prop_err == .None, "paxos.propose")
	testing.expect(t, slot == 1, "Slot is 1")
	paxos.confirm_writes_durable(&prop_eff)

	testing.expect(t, len(paxos.committed_slice(&prop_eff)) == 1, "paxos.committed_slice")
	testing.expect(t, paxos.decided_through(&node) == 1, "paxos.decided_through")

	val, ok := paxos.committed_at(&node, 1)
	testing.expect(t, ok && val == 8888, "paxos.committed_at")

	floor_err := paxos.advance_memory_floor(&node, 1)
	testing.expect(t, floor_err == .None, "paxos.advance_memory_floor")
	testing.expect(t, paxos.memory_floor(&node) == 1, "paxos.memory_floor")

	inv_err := paxos.advance_memory_floor(&node, 2)
	testing.expect(t, inv_err == .InvalidSlot, "Advancing past delivered returns InvalidSlot")
}

@(test)
test_node_restore_and_recovery :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.NodeId{1}
	_ = paxos.membership_init(&m, nodes[:])

	node: paxos.Node(u64, 1, 64, 16)
	_ = paxos.node_init(&node, 1, m)

	eff: paxos.Effects(u64, 1, 64)
	paxos.effects_init(&eff)
	_ = paxos.node_campaign(&node, 0, &eff)
	paxos.effects_confirm_writes_durable(&eff)
	for msg in paxos.effects_messages_slice(&eff) {
		step_eff: paxos.Effects(u64, 1, 64)
		paxos.effects_init(&step_eff)
		_ = paxos.node_step(&node, msg, &step_eff)
		paxos.effects_confirm_writes_durable(&step_eff)
		for rep in paxos.effects_messages_slice(&step_eff) {
			feed_eff: paxos.Effects(u64, 1, 64)
			paxos.effects_init(&feed_eff)
			_ = paxos.node_step(&node, rep, &feed_eff)
			paxos.effects_confirm_writes_durable(&feed_eff)
		}
	}

	prop_eff: paxos.Effects(u64, 1, 64)
	paxos.effects_init(&prop_eff)
	_, _ = paxos.node_propose(&node, 101, &prop_eff)
	paxos.effects_confirm_writes_durable(&prop_eff)

	// Save durable state and restore new node
	dur := paxos.node_durable_state(&node)^
	restored: paxos.Node(u64, 1, 64, 16)
	rest_err := paxos.node_restore(&restored, 1, m, dur)
	testing.expect(t, rest_err == .None, "Node restore success")
	testing.expect(t, paxos.node_proposal_frontier(&restored) == 2, "Frontier resumes at 2")

	// Test continue_at across configuration handover
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 1, history_hash = {}}
	cont: paxos.Node(u64, 1, 64, 16)
	cont_err := paxos.node_continue_at(&cont, 1, m, 1, anchor)
	testing.expect(t, cont_err == .None, "Continue at floor 1")
	testing.expect(t, paxos.node_memory_floor(&cont) == 1, "Memory floor is 1")
	testing.expect(t, paxos.node_proposal_frontier(&cont) == 2, "Frontier is 2")

	// Trim regression error check
	bad_cont_err := paxos.node_continue_at(&cont, 1, m, 0, anchor)
	testing.expect(t, bad_cont_err == .TrimRegression, "Anchor ahead of floor rejected")

	// Begin recovery onto installed image
	rec_err := paxos.node_begin_recovery(&restored, anchor)
	testing.expect(t, rec_err == .None, "Begin recovery onto anchor")
	testing.expect(t, paxos.node_memory_floor(&restored) == 1, "Memory floor is 1 after recovery")
	testing.expect(t, paxos.node_role(&restored) == .Follower, "Role reset to follower after recovery")
}

@(test)
test_lamport_b3_max_vote_rule :: proc(t: ^testing.T) {
	// Lamport Theorem B3: A candidate preparing in ballot b must propose the value with the
	// highest ballot among promises received from a quorum for slot s, or noop if unvoted.
	m: paxos.Membership(3)
	nodes := [3]paxos.NodeId{1, 2, 3}
	_ = paxos.membership_init(&m, nodes[:])

	n1: paxos.Node(u64, 3, 64, 16)
	n2: paxos.Node(u64, 3, 64, 16)
	n3: paxos.Node(u64, 3, 64, 16)

	_ = paxos.node_init(&n1, 1, m)
	_ = paxos.node_init(&n2, 2, m)
	_ = paxos.node_init(&n3, 3, m)

	// Step 1: Node 1 campaigns in round 1, proposes value 777 to slot 1
	eff1: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&eff1)
	_ = paxos.node_campaign(&n1, 0, &eff1)
	paxos.effects_confirm_writes_durable(&eff1)
	prepares := paxos.effects_messages_slice(&eff1)

	// Node 1 and Node 2 promise to Node 1
	p_eff1: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&p_eff1)
	_ = paxos.node_step(&n1, prepares[0], &p_eff1)
	paxos.effects_confirm_writes_durable(&p_eff1)

	p_eff2: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&p_eff2)
	_ = paxos.node_step(&n2, prepares[1], &p_eff2)
	paxos.effects_confirm_writes_durable(&p_eff2)

	// Feed replies to Node 1
	feed_eff: paxos.Effects(u64, 3, 64)
	for msg in paxos.effects_messages_slice(&p_eff1) {
		paxos.effects_init(&feed_eff)
		_ = paxos.node_step(&n1, msg, &feed_eff)
		paxos.effects_confirm_writes_durable(&feed_eff)
	}
	for msg in paxos.effects_messages_slice(&p_eff2) {
		paxos.effects_init(&feed_eff)
		_ = paxos.node_step(&n1, msg, &feed_eff)
		paxos.effects_confirm_writes_durable(&feed_eff)
	}
	testing.expect(t, n1.role == .Leader, "Node 1 is leader for ballot round 1")

	// Node 1 proposes 777 in slot 1
	prop_eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&prop_eff)
	_, _ = paxos.node_propose(&n1, 777, &prop_eff)
	paxos.effects_confirm_writes_durable(&prop_eff)
	accept_msgs := paxos.effects_messages_slice(&prop_eff)

	// Only Node 2 receives and accepts the vote (Node 3 was unreachable, Node 1 crashes)
	acc_eff2: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&acc_eff2)
	_ = paxos.node_step(&n2, accept_msgs[0], &acc_eff2)
	paxos.effects_confirm_writes_durable(&acc_eff2)

	// Node 2 has accepted vote (ballot round 1, value 777)
	acc_val, has_acc := paxos.durable_accepted_at(&n2.durable, 1)
	testing.expect(t, has_acc && acc_val.value == 777, "Node 2 accepted 777 in slot 1")

	// Step 2: Node 3 campaigns in round 2 with noop = 999
	camp_eff3: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&camp_eff3)
	_ = paxos.node_campaign(&n3, 999, &camp_eff3)
	paxos.effects_confirm_writes_durable(&camp_eff3)
	prepares3 := paxos.effects_messages_slice(&camp_eff3)

	// Node 2 steps prepare from Node 3 (ballot round 2)
	p3_eff2: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&p3_eff2)
	_ = paxos.node_step(&n2, prepares3[1], &p3_eff2)
	paxos.effects_confirm_writes_durable(&p3_eff2)

	// Node 3 steps its own prepare
	p3_eff3: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&p3_eff3)
	_ = paxos.node_step(&n3, prepares3[2], &p3_eff3)
	paxos.effects_confirm_writes_durable(&p3_eff3)

	// Feed replies to Node 3 (forming quorum of Node 3 and Node 2)
	resolve_eff: paxos.Effects(u64, 3, 64)
	for msg in paxos.effects_messages_slice(&p3_eff3) {
		paxos.effects_init(&resolve_eff)
		_ = paxos.node_step(&n3, msg, &resolve_eff)
		paxos.effects_confirm_writes_durable(&resolve_eff)
	}
	for msg in paxos.effects_messages_slice(&p3_eff2) {
		paxos.effects_init(&resolve_eff)
		_ = paxos.node_step(&n3, msg, &resolve_eff)
		paxos.effects_confirm_writes_durable(&resolve_eff)
	}

	// Per Lamport B3, Node 3 MUST resolve slot 1 by proposing the max-voted value (777), NOT 999!
	testing.expect(t, n3.role == .Leader, "Node 3 becomes leader")
	lead_slot1 := n3.lead[paxos.durable_cell_index(1, 64)]
	testing.expect(t, lead_slot1.proposal != nil, "Slot 1 has proposal")
	testing.expect(t, lead_slot1.proposal.? == 777, "Lamport B3: adopted value 777 from Node 2 promise")
}
