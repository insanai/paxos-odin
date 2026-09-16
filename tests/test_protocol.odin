package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_membership_validation :: proc(t: ^testing.T) {
	m: paxos.Membership(7)
	nodes := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.membership_init(&m, nodes[:]))
	testing.expect_value(t, paxos.membership_count(&m), 3)
	testing.expect_value(t, paxos.membership_read_quorum(&m), 2)
	testing.expect_value(t, paxos.membership_write_quorum(&m), 2)
	testing.expect(t, paxos.membership_contains(&m, 2))
	testing.expect(t, !paxos.membership_contains(&m, 4))

	testing.expect_value(t, paxos.membership_init(&m, []paxos.Node_Id{}), paxos.Error.Empty_Membership)
	dup := [3]paxos.Node_Id{1, 2, 1}
	testing.expect_value(t, paxos.membership_init(&m, dup[:]), paxos.Error.Duplicate_Node_Id)
	zero := [2]paxos.Node_Id{0, 2}
	testing.expect_value(t, paxos.membership_init(&m, zero[:]), paxos.Error.Invalid_Node_Id)
	// A failed init leaves the previous membership intact.
	testing.expect_value(t, paxos.membership_count(&m), 3)
}

@(test)
test_ballot_ordering :: proc(t: ^testing.T) {
	b1 := paxos.ballot_make(1, 0, 1)
	b2 := paxos.ballot_make(1, 0, 2)
	b3 := paxos.ballot_make(1, 1, 1)
	b4 := paxos.ballot_make(2, 0, 1)
	testing.expect(t, b1 < b2, "node breaks ties")
	testing.expect(t, b1 < b3, "priority beats node")
	testing.expect(t, b3 < b4, "round beats priority")
	testing.expect(t, b1 == b1 && b1 != b2)
	testing.expect_value(t, paxos.ballot_round(b4), u64(2))
	testing.expect_value(t, paxos.ballot_priority(b3), u8(1))
	testing.expect_value(t, paxos.ballot_node(b2), paxos.Node_Id(2))
	top := paxos.ballot_make(paxos.MAX_ROUND, 255, 65535)
	testing.expect(t, top > paxos.ballot_make(paxos.MAX_ROUND, 255, 65534))
}

@(test)
test_single_node_consensus :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, nodes[:]))
	node: paxos.Node(u64, 1, 64, 16)
	expect_ok(t, paxos.init(&node, 1, m))

	e: paxos.Effects(u64, 1, 64, 16)
	expect_ok(t, paxos.campaign(&node, 0, &e))
	paxos.confirm_writes_durable(&e)
	prepares := paxos.messages_slice(&e)
	testing.expect_value(t, len(prepares), 1)

	replies: [dynamic]Packet(u64)
	defer delete(replies)
	step_e: paxos.Effects(u64, 1, 64, 16)
	expect_ok(t, paxos.step(&node, prepares[0], &step_e))
	paxos.confirm_writes_durable(&step_e)
	enqueue_all(&replies, paxos.messages_slice(&step_e))
	for &reply in replies {
		feed: paxos.Effects(u64, 1, 64, 16)
		expect_ok(t, paxos.step(&node, packet_envelope(&reply), &feed))
		paxos.confirm_writes_durable(&feed)
	}
	testing.expect_value(t, node.role, paxos.Role.Leader)

	slot, err := paxos.propose(&node, 42, &e)
	expect_ok(t, err)
	testing.expect_value(t, slot, paxos.Slot(1))
	committed := paxos.committed_slice(&e)
	testing.expect_value(t, len(committed), 1)
	testing.expect(t, committed[0].slot == 1 && committed[0].value^ == 42)
	testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(1))
	paxos.confirm_writes_durable(&e)
}

@(test)
test_three_node_cluster_agreement :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)

	e: Review_Effects
	slot, err := paxos.propose(&c.nodes[0], 999, &e)
	expect_ok(t, err)
	testing.expect_value(t, slot, paxos.Slot(1))
	// The leader's own vote is durable before the two accepts leave.
	testing.expect_value(t, len(paxos.writes_slice(&e)), 1)
	paxos.confirm_writes_durable(&e)
	accepts := paxos.messages_slice(&e)
	testing.expect_value(t, len(accepts), 2)

	// Node 2 votes; node 3 never hears anything.
	packet := packet_of(accepts[0])
	e2: Review_Effects
	expect_ok(t, paxos.step(&c.nodes[1], packet_envelope(&packet), &e2))
	paxos.confirm_writes_durable(&e2)
	testing.expect_value(t, len(paxos.messages_slice(&e2)), 1)

	// One acknowledgement plus the leader's own vote is a majority.
	ack := packet_of(paxos.messages_slice(&e2)[0])
	e3: Review_Effects
	expect_ok(t, paxos.step(&c.nodes[0], packet_envelope(&ack), &e3))
	committed := paxos.committed_slice(&e3)
	testing.expect_value(t, len(committed), 1)
	testing.expect(t, committed[0].slot == 1 && committed[0].value^ == 999)
	paxos.confirm_writes_durable(&e3)
	commits := paxos.messages_slice(&e3)
	testing.expect_value(t, len(commits), 2)

	commit := packet_of(commits[0])
	e4: Review_Effects
	expect_ok(t, paxos.step(&c.nodes[1], packet_envelope(&commit), &e4))
	paxos.confirm_writes_durable(&e4)
	testing.expect_value(t, paxos.decided_through(&c.nodes[1]), paxos.Slot(1))
	value, ok := paxos.committed_at(&c.nodes[1], 1)
	testing.expect(t, ok && value == 999)
}

@(test)
test_unified_surface :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	node: paxos.Node(u64, 1, 64, 16)
	expect_ok(t, paxos.init(&node, 1, m))
	testing.expect_value(t, paxos.id(&node), paxos.Node_Id(1))
	testing.expect(t, paxos.is_voting_member(&node))
	testing.expect_value(t, paxos.role(&node), paxos.Role.Follower)

	e: paxos.Effects(u64, 1, 64, 16)
	expect_ok(t, paxos.campaign(&node, 0, &e))
	paxos.confirm_writes_durable(&e)
	queue: [dynamic]Packet(u64)
	defer delete(queue)
	enqueue_all(&queue, paxos.messages_slice(&e))
	for i := 0; i < len(queue); i += 1 {
		packet := queue[i]
		step_e: paxos.Effects(u64, 1, 64, 16)
		expect_ok(t, paxos.step(&node, packet_envelope(&packet), &step_e))
		paxos.confirm_writes_durable(&step_e)
		enqueue_all(&queue, paxos.messages_slice(&step_e))
	}
	testing.expect_value(t, paxos.role(&node), paxos.Role.Leader)
	testing.expect(t, paxos.is_leader_caught_up(&node))

	slot, err := paxos.propose(&node, 8888, &e)
	expect_ok(t, err)
	testing.expect_value(t, slot, paxos.Slot(1))
	paxos.confirm_writes_durable(&e)
	testing.expect_value(t, len(paxos.committed_slice(&e)), 1)
	testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(1))
	value, ok := paxos.committed_at(&node, 1)
	testing.expect(t, ok && value == 8888)
	expect_ok(t, paxos.advance_memory_floor(&node, 1))
	testing.expect_value(t, paxos.memory_floor(&node), paxos.Slot(1))
	testing.expect_value(t, paxos.advance_memory_floor(&node, 2), paxos.Error.Invalid_Slot)
}

@(test)
test_node_restore_and_recovery :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	node: paxos.Node(u64, 1, 64, 16)
	expect_ok(t, paxos.init(&node, 1, m))
	e: paxos.Effects(u64, 1, 64, 16)
	journal: [dynamic]Journal_Record(u64)
	defer delete(journal)

	expect_ok(t, paxos.campaign(&node, 0, &e))
	journal_append(&journal, paxos.writes_slice(&e))
	paxos.confirm_writes_durable(&e)
	queue: [dynamic]Packet(u64)
	defer delete(queue)
	enqueue_all(&queue, paxos.messages_slice(&e))
	for i := 0; i < len(queue); i += 1 {
		packet := queue[i]
		expect_ok(t, paxos.step(&node, packet_envelope(&packet), &e))
		journal_append(&journal, paxos.writes_slice(&e))
		paxos.confirm_writes_durable(&e)
		enqueue_all(&queue, paxos.messages_slice(&e))
	}
	_, err := paxos.propose(&node, 101, &e)
	expect_ok(t, err)
	journal_append(&journal, paxos.writes_slice(&e))
	paxos.confirm_writes_durable(&e)

	// Replay the journal into a fresh ledger and restore.
	ledger: paxos.Ledger(u64, 64)
	expect_ok(t, journal_replay(journal[:], &ledger))
	restored: paxos.Node(u64, 1, 64, 16)
	expect_ok(t, paxos.restore(&restored, 1, m, ledger))
	testing.expect_value(t, paxos.proposal_frontier(&restored), paxos.Slot(2))
	value, ok := paxos.committed_at(&restored, 1)
	testing.expect(t, ok && value == 101, "the decision survives replay")

	// Continue across a handover with an inherited anchor.
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 1}
	cont: paxos.Node(u64, 1, 64, 16)
	expect_ok(t, paxos.continue_at(&cont, 1, m, 1, anchor))
	testing.expect_value(t, paxos.memory_floor(&cont), paxos.Slot(1))
	testing.expect_value(t, paxos.proposal_frontier(&cont), paxos.Slot(2))
	testing.expect_value(t, paxos.continue_at(&cont, 1, m, 0, anchor), paxos.Error.Trim_Regression)

	expect_ok(t, paxos.begin_recovery(&restored, anchor))
	testing.expect_value(t, paxos.memory_floor(&restored), paxos.Slot(1))
	testing.expect_value(t, paxos.role(&restored), paxos.Role.Follower)
}

// Lamport's B3: a candidate re-proposes the value of the greatest vote reported by its
// phase-one quorum, never its own preference.
@(test)
test_lamport_b3_max_vote_rule :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)

	// Node 1 proposes 777; only node 2 votes, then node 1 falls silent.
	e: Review_Effects
	_, err := paxos.propose(&c.nodes[0], 777, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	accept := packet_of(paxos.messages_slice(&e)[0])
	e2: Review_Effects
	expect_ok(t, paxos.step(&c.nodes[1], packet_envelope(&accept), &e2))
	paxos.confirm_writes_durable(&e2)
	vote, _, voted := paxos.ledger_vote_at(&c.nodes[1].ledger, 1)
	testing.expect(t, voted && vote == c.nodes[0].ballot)

	// Node 3 campaigns with no-op 999; its quorum is {2, 3}.
	e3: Review_Effects
	expect_ok(t, paxos.campaign(&c.nodes[2], 999, &e3))
	paxos.confirm_writes_durable(&e3)
	for envelope in paxos.messages_slice(&e3) {
		if envelope.to == 1 do continue
		append(&c.queue, packet_of(envelope))
	}
	review_drain(t, &c)
	testing.expect_value(t, c.nodes[2].role, paxos.Role.Leader)
	for &node in c.nodes {
		if node.id == 1 do continue
		value, ok := paxos.committed_at(&node, 1)
		testing.expect(t, ok && value == 777, "B3: the recovered vote wins, not the no-op")
	}
}
