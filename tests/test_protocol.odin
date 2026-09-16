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
