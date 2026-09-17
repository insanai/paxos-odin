// Regression scenarios found in review. Each one pins a behaviour that a plausible
// simplification would break.
package paxos_tests

import "core:testing"
import paxos "../src"

Review_Log         :: paxos.Replicated_Log_Node(u64, 1, 4, 2, 8)
Review_Entry       :: paxos.Entry(u64, 1, 8)
Review_Log_Effects :: paxos.Effects(Review_Entry, 1, 4, 2)

@(test)
review_flexible_quorums_and_window_reuse :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c, 3, 1)
	review_campaign(t, &c, 0)
	e: Review_Effects
	for slot in 1..=24 {
		s, err := paxos.propose(&c.nodes[0], u64(slot * 10), &e)
		expect_ok(t, err)
		testing.expect_value(t, s, paxos.Slot(slot))
		review_enqueue(&c, &e)
		review_drain(t, &c)
		// A write quorum of one chooses locally; followers catch up via heartbeats.
		for _ in 0..<3 do review_tick(t, &c, 0)
		for &node in c.nodes {
			testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(slot))
			expect_ok(t, paxos.advance_memory_floor(&node, paxos.Slot(slot)))
		}
	}
}

@(test)
review_campaign_discards_prior_term_proposals :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	// A previous unsuccessful term left leader bookkeeping for slot 1; a later term voted 20.
	c.nodes[0].lead_slot[0] = 1
	twenty: u64 = 20
	for &node in c.nodes {
		expect_ok(t, paxos.ledger_apply(&node.ledger, vote_record(paxos.ballot_make(5, 0, 2), 1, &twenty)))
	}
	review_campaign(t, &c, 0)
	for &node in c.nodes {
		value, ok := paxos.committed_at(&node, 1)
		testing.expect(t, ok && value == 20)
	}
}

@(test)
review_recovery_preserves_fences_across_chunks :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	e: Review_Effects
	expect_ok(t, paxos.campaign(&c.nodes[0], 0, &e))
	ballot := c.nodes[0].ballot
	for peer in 1..=2 {
		paxos.confirm_writes_durable(&e)
		range := paxos.Promise_Range_Message{
			ballot = ballot, first = 1, last = 2, more = true,
			anchor = {trim_id = 1, chosen_trim_slot = 6}, chosen_through = 6,
		}
		from := paxos.Node_Id(peer)
		expect_ok(t, paxos.step(&c.nodes[0], envelope(from, 1, paxos.Message(u64)(range)), &e))
	}
	testing.expect_value(t, c.nodes[0].recover_base, paxos.Slot(3))
	testing.expect_value(t, c.nodes[0].election[0].anchor.chosen_trim_slot, paxos.Slot(6))
	testing.expect_value(t, c.nodes[0].election[1].chosen_through, paxos.Slot(6))
	paxos.confirm_writes_durable(&e)
}

@(test)
review_multichunk_recovery_and_retry_progress :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	values: [7]u64
	for slot in 1..=6 do values[slot] = u64(slot * 10)
	for &node in c.nodes {
		for slot in 1..=6 {
			vote := vote_record(paxos.ballot_make(1, 0, 2), paxos.Slot(slot), &values[slot])
			expect_ok(t, paxos.ledger_apply(&node.ledger, vote))
		}
	}
	review_campaign(t, &c, 0)
	// Earlier chunk acknowledgements can arrive while preparing; retries must finish them.
	for _ in 0..<40 do review_tick(t, &c, 0)
	for &node in c.nodes do testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(6))
	testing.expect_value(t, paxos.proposal_frontier(&c.nodes[0]), paxos.Slot(7))
}

@(test)
review_missing_proposal_is_error :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	// Leader bookkeeping claims slot 1 with one acknowledgement, the ledger holds the slot,
	// but the vote is gone. (A cell that moved on to another slot is stale, not an error.)
	c.nodes[0].ledger.slot[0] = 1
	_ = paxos.bit_set_insert(&c.nodes[0].ledger.used, 0)
	c.nodes[0].lead_slot[0] = 1
	c.nodes[0].lead_ballot[0] = c.nodes[0].ballot
	c.nodes[0].acknowledged[0] = 1
	_ = paxos.bit_set_insert(&c.nodes[0].acknowledgements[0], 0)
	e: Review_Effects
	ack := envelope(2, 1, paxos.Message(u64)(paxos.Accepted_Message{ballot = c.nodes[0].ballot, slot = 1}))
	testing.expect_value(t, paxos.step(&c.nodes[0], ack, &e), paxos.Error.Missing_Proposed_Value)
}

@(test)
review_slot_exhaustion_and_learner_wrap :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	n: paxos.Node(u64, 1, 4, 2)
	expect_ok(t, paxos.continue_at(&n, 1, m, max(paxos.Slot), paxos.Trim_Anchor{}))
	testing.expect_value(t, n.next_slot, max(paxos.Slot))
	e: paxos.Effects(u64, 1, 4, 2)
	testing.expect_value(t, paxos.campaign(&n, 0, &e), paxos.Error.Global_Slot_Exhausted)
	l: paxos.Learner(u64, 4)
	expect_ok(t, paxos.init(&l, 1))
	l.released_through = max(paxos.Slot) - 1
	result, err := paxos.learner_learn_chosen(&l, 1, max(paxos.Slot), 42)
	expect_ok(t, err)
	testing.expect_value(t, result, paxos.Learn_Result.Advanced)
	out: [1]paxos.Chosen_Value(u64)
	count, read_err := paxos.learner_read_chosen(&l, max(paxos.Slot), out[:])
	expect_ok(t, read_err)
	testing.expect_value(t, count, 1)
}

@(test)
review_negative_quorums_and_learner_campaign :: proc(t: ^testing.T) {
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	testing.expect_value(t, paxos.init(&m, ids[:], -1, 0), paxos.Error.Invalid_Read_Quorum)
	testing.expect_value(t, paxos.init(&m, ids[:], 0, -1), paxos.Error.Invalid_Write_Quorum)
	expect_ok(t, paxos.init(&m, ids[:]))
	n: Review_Node
	expect_ok(t, paxos.node_init_learner(&n, 4, m))
	paxos.set_campaign_enabled(&n, true)
	testing.expect(t, !paxos.is_campaign_enabled(&n))
}

@(test)
review_stop_seal_restore_and_completed_history :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	n: Review_Log
	expect_ok(t, paxos.log_init(&n, 1, 1, m))
	e: Review_Log_Effects
	expect_ok(t, paxos.campaign(&n, 0, &e))
	paxos.confirm_writes_durable(&e)
	prepare := packet_of(paxos.messages_slice(&e)[0])
	expect_ok(t, paxos.step(&n, packet_envelope(&prepare), &e))
	paxos.confirm_writes_durable(&e)
	replies: [dynamic]Packet(Review_Entry)
	defer delete(replies)
	enqueue_all(&replies, paxos.messages_slice(&e))
	for &reply in replies do expect_ok(t, paxos.step(&n, packet_envelope(&reply), &e))
	slot, err := paxos.log_propose_stop_sign(&n, 2, ids[:], nil, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	testing.expect(t, paxos.log_is_sealed(&n), "a local decision seals immediately")
	testing.expect_value(t, paxos.log_stop_slot(&n), slot)
	restored: Review_Log
	expect_ok(t, paxos.restore(&restored, 1, 1, m, n.core.ledger))
	testing.expect(t, paxos.log_is_sealed(&restored), "a decided stop survives replay")
	testing.expect_value(t, paxos.log_stop_slot(&restored), slot)
	expect_ok(t, paxos.restore(&restored, 1, 2, m, n.core.ledger))
	testing.expect(t, !paxos.log_is_sealed(&restored), "an old handover is completed history")
}

@(test)
review_log_learner_observes_stop_and_catchup :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	n: Review_Log
	expect_ok(t, paxos.log_init_learner(&n, 2, 1, m))
	stop: paxos.Stop_Sign(1, 8)
	expect_ok(t, paxos.init(&stop, 2, ids[:], nil))
	e: Review_Log_Effects
	expect_ok(t, paxos.log_learn_chosen(&n, 1, 1, Review_Entry(stop), &e))
	testing.expect(t, paxos.log_is_sealed(&n))
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.log_request_catch_up(&n, 1, 2, &e))
	testing.expect_value(t, len(paxos.messages_slice(&e)), 1)
	expect_ok(t, paxos.log_reconnected(&n, 1, &e))
}

@(test)
review_snapshot_preserves_votes_above_anchor :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	ninety_nine: u64 = 99
	vote := vote_record(paxos.ballot_make(5, 0, 2), 2, &ninety_nine)
	expect_ok(t, paxos.ledger_apply(&c.nodes[0].ledger, vote))
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 1}
	expect_ok(t, paxos.begin_recovery(&c.nodes[0], anchor))
	_, value, voted := paxos.ledger_vote_at(&c.nodes[0].ledger, 2)
	testing.expect(t, voted && value^ == 99, "an installed image keeps votes above its anchor")
	testing.expect_value(t, c.nodes[0].next_slot, paxos.Slot(3))
	conflict := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 2}
	testing.expect_value(t, paxos.begin_recovery(&c.nodes[0], conflict), paxos.Error.Trim_Regression)
	testing.expect_value(t, c.nodes[0].ledger.anchor, anchor)
}

@(test)
review_live_trim_rejects_conflicting_identity :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	c.nodes[0].delivered_through = 2
	e: Review_Effects
	expect_ok(t, paxos.install_chosen_trim(&c.nodes[0], {trim_id = 1, chosen_trim_slot = 1}, &e))
	paxos.confirm_writes_durable(&e)
	twin := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 2}
	testing.expect_value(t, paxos.install_chosen_trim(&c.nodes[0], twin, &e), paxos.Error.Trim_Regression)
	testing.expect_value(t, len(paxos.writes_slice(&e)), 0)
}

@(test)
review_promise_reordering_deduplication_and_validation :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	e: Review_Effects
	expect_ok(t, paxos.campaign(&c.nodes[0], 0, &e))
	paxos.confirm_writes_durable(&e)
	ballot := c.nodes[0].ballot
	marker := paxos.Promise_Range_Message{ballot = ballot, first = 1, last = 2, reported = 1}
	for peer in 1..=2 {
		from := paxos.Node_Id(peer)
		expect_ok(t, paxos.step(&c.nodes[0], envelope(from, 1, paxos.Message(u64)(marker)), &e))
	}
	testing.expect_value(t, c.nodes[0].role, paxos.Role.Preparing)
	forty_two: u64 = 42
	promise := paxos.Promise_Message(u64){
		ballot = ballot, slot = 1, vote = paxos.ballot_make(1, 0, 9), state = .Voted, value = &forty_two,
	}
	// The same promise twice counts once.
	for _ in 0..<2 {
		expect_ok(t, paxos.step(&c.nodes[0], envelope(1, 1, paxos.Message(u64)(promise)), &e))
	}
	testing.expect_value(t, c.nodes[0].election[0].received_in_range, u32(1))
	testing.expect_value(t, c.nodes[0].role, paxos.Role.Preparing)
	marker.last = 1
	short := paxos.step(&c.nodes[0], envelope(2, 1, paxos.Message(u64)(marker)), &e)
	testing.expect_value(t, short, paxos.Error.Invalid_Promise)
	forty_three: u64 = 43
	promise.value = &forty_three
	conflict := paxos.step(&c.nodes[0], envelope(2, 1, paxos.Message(u64)(promise)), &e)
	testing.expect_value(t, conflict, paxos.Error.Conflicting_Value)
}

@(test)
review_batch_backpressure_is_atomic :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	values := [2]u64{10, 20}
	slots: [2]paxos.Slot
	_, err := paxos.propose_batch(&c.nodes[0], values[:], slots[:1], &e)
	testing.expect_value(t, err, paxos.Error.Slot_Buffer_Too_Small)
	testing.expect_value(t, c.nodes[0].next_slot, paxos.Slot(1))
	for _ in 0..<4 {
		_, err = paxos.propose_batch(&c.nodes[0], values[:], slots[:], &e)
		expect_ok(t, err)
		review_enqueue(&c, &e)
		review_drain(t, &c)
	}
	_, err = paxos.propose_batch(&c.nodes[0], values[:], slots[:], &e)
	testing.expect_value(t, err, paxos.Error.Window_Full)
	testing.expect_value(t, c.nodes[0].next_slot, paxos.Slot(9))
	testing.expect_value(t, len(paxos.writes_slice(&e)), 0)
}

@(test)
review_inherited_prefix_gate_and_nack :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	c.nodes[0].gate_proposals_on_inherited_prefix = true
	c.nodes[0].leader_base = 2
	_, err := paxos.propose(&c.nodes[0], 42, &e)
	testing.expect_value(t, err, paxos.Error.Leader_Catching_Up)
	nack := paxos.Nack_Message{rejected = c.nodes[0].ballot, promised = paxos.ballot_make(10, 0, 2)}
	expect_ok(t, paxos.step(&c.nodes[0], paxos.Envelope(u64){from = 2, to = 1, message = nack}, &e))
	testing.expect_value(t, c.nodes[0].role, paxos.Role.Follower)
	expect_ok(t, paxos.campaign(&c.nodes[0], 0, &e))
	testing.expect_value(t, paxos.ballot_round(c.nodes[0].ballot), u64(11))
}

@(test)
review_log_pending_stop_replaced_during_replay :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	stop: paxos.Stop_Sign(1, 8)
	expect_ok(t, paxos.init(&stop, 2, ids[:], nil))
	stop_entry := Review_Entry(stop)
	ledger: paxos.Ledger(Review_Entry, 4)
	expect_ok(t, paxos.ledger_apply(&ledger, vote_record(paxos.ballot_make(1, 0, 1), 1, &stop_entry)))
	n: Review_Log
	expect_ok(t, paxos.restore(&n, 1, 1, m, ledger))
	_, pending := paxos.log_pending_stop_sign(&n)
	testing.expect(t, pending && n.stop_pending)
	command := Review_Entry(u64(10))
	expect_ok(t, paxos.ledger_apply(&ledger, vote_record(paxos.ballot_make(2, 0, 1), 1, &command)))
	expect_ok(t, paxos.restore(&n, 1, 1, m, ledger))
	testing.expect(t, !n.stop_pending)
}

@(test)
review_replay_reuses_certified_trimmed_vote :: proc(t: ^testing.T) {
	ledger: paxos.Ledger(u64, 2)
	ballot := paxos.ballot_make(1, 0, 1)
	ten, thirty: u64 = 10, 30
	expect_ok(t, paxos.ledger_apply(&ledger, vote_record(ballot, 1, &ten)))
	// The certified trim remains durable even if a derived decision record does not.
	expect_ok(t, paxos.ledger_apply(&ledger, paxos.Write_Trim{trim_id = 1, chosen_trim_slot = 1}))
	expect_ok(t, paxos.ledger_apply(&ledger, vote_record(ballot, 3, &thirty)))
	_, value, voted := paxos.ledger_vote_at(&ledger, 3)
	testing.expect(t, voted && value^ == 30)
}

@(test)
review_out_of_order_chosen_stop_blocks_proposals :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	n: Review_Log
	expect_ok(t, paxos.log_init(&n, 1, 1, m))
	stop: paxos.Stop_Sign(1, 8)
	expect_ok(t, paxos.init(&stop, 2, ids[:], nil))
	stop_entry := Review_Entry(stop)
	e: Review_Log_Effects
	expect_ok(t, paxos.step(&n, commit_envelope(1, 1, 2, &stop_entry), &e))
	testing.expect(t, n.stop_pending, "a chosen stop behind a gap must block further proposals")
	paxos.confirm_writes_durable(&e)
}

@(test)
review_duplicate_acknowledgements_do_not_make_a_quorum :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c, 1, 3)
	review_campaign(t, &c, 0)
	e: Review_Effects
	_, err := paxos.propose(&c.nodes[0], 42, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	sent := paxos.messages_slice(&e)
	accepts := [2]Packet(u64){packet_of(sent[0]), packet_of(sent[1])}
	expect_ok(t, paxos.step(&c.nodes[1], packet_envelope(&accepts[0]), &e))
	paxos.confirm_writes_durable(&e)
	ack := paxos.messages_slice(&e)[0]
	for _ in 0..<5 {
		expect_ok(t, paxos.step(&c.nodes[0], ack, &e))
		testing.expect_value(t, paxos.decided_through(&c.nodes[0]), paxos.Slot(0))
	}
	expect_ok(t, paxos.step(&c.nodes[2], packet_envelope(&accepts[1]), &e))
	paxos.confirm_writes_durable(&e)
	ack = paxos.messages_slice(&e)[0]
	expect_ok(t, paxos.step(&c.nodes[0], ack, &e))
	testing.expect_value(t, paxos.decided_through(&c.nodes[0]), paxos.Slot(1))
	paxos.confirm_writes_durable(&e)
}

@(test)
review_hundred_twenty_eight_voters :: proc(t: ^testing.T) {
	m := new(paxos.Membership(128))
	defer free(m)
	ids: [128]paxos.Node_Id
	for &id, i in ids do id = paxos.Node_Id(i + 1)
	expect_ok(t, paxos.init(m, ids[:], 1, 128))
	n := new(paxos.Node(u64, 128, 4, 2))
	defer free(n)
	e := new(paxos.Effects(u64, 128, 4, 2))
	defer free(e)
	expect_ok(t, paxos.init(n, 1, m^))
	expect_ok(t, paxos.campaign(n, 0, e))
	paxos.confirm_writes_durable(e)
	prepare := packet_of(paxos.messages_slice(e)[0])
	expect_ok(t, paxos.step(n, packet_envelope(&prepare), e))
	paxos.confirm_writes_durable(e)
	promise := packet_of(paxos.messages_slice(e)[0])
	expect_ok(t, paxos.step(n, packet_envelope(&promise), e))
	for slot in 1..=7 {
		_, err := paxos.propose(n, u64(slot), e)
		expect_ok(t, err)
		paxos.confirm_writes_durable(e)
		for peer in 2..=128 {
			ack := paxos.Accepted_Message{ballot = n.ballot, slot = paxos.Slot(slot)}
			expect_ok(t, paxos.step(n, envelope(paxos.Node_Id(peer), 1, paxos.Message(u64)(ack)), e))
			if peer < 128 do testing.expect_value(t, paxos.decided_through(n), paxos.Slot(slot - 1))
		}
		paxos.confirm_writes_durable(e)
		testing.expect_value(t, paxos.decided_through(n), paxos.Slot(slot))
		expect_ok(t, paxos.advance_memory_floor(n, paxos.Slot(slot)))
	}
}

@(test)
review_leader_fetches_decisions_from_ahead_follower :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	// A follower learned the chosen decree while the leader missed the commit.
	forty_two: u64 = 42
	expect_ok(t, paxos.step(&c.nodes[1], commit_envelope(3, 2, 1, &forty_two), &e))
	paxos.confirm_writes_durable(&e)
	// An acknowledgement for another slot reports the follower's progress.
	ack := paxos.Accepted_Message{ballot = c.nodes[0].ballot, slot = 2, decided_through = 1}
	expect_ok(t, paxos.step(&c.nodes[0], paxos.Envelope(u64){from = 2, to = 1, message = ack}, &e))
	for _ in 0..<10 do review_tick(t, &c, 0)
	value, ok := paxos.committed_at(&c.nodes[0], 1)
	testing.expect(t, ok && value == 42, "a leader must fetch a follower's known chosen prefix")
}

// A thousand-voter membership: lookups go through the sorted index and quorum counting
// through the word-array bit set. Read quorum one, write quorum everyone.
@(test)
review_thousand_voters_reach_quorum :: proc(t: ^testing.T) {
	VOTERS :: 1024
	m := new(paxos.Membership(VOTERS))
	defer free(m)
	ids: [VOTERS]paxos.Node_Id
	// Ids out of order: the membership sorts them, so an id's stable index is its rank.
	for &id, i in ids do id = paxos.Node_Id((i * 7919) % VOTERS + 1)
	expect_ok(t, paxos.init(m, ids[:], 1, VOTERS))
	index, found := paxos.membership_index_of(m, 1000)
	testing.expect(t, found && index == 999, "sorted lookup returns the id's rank")
	testing.expect_value(t, paxos.membership_get(m, 0), paxos.Node_Id(1))
	_, missing := paxos.membership_index_of(m, VOTERS + 1)
	testing.expect(t, !missing)

	n := new(paxos.Node(u64, VOTERS, 4, 1))
	defer free(n)
	e := new(paxos.Effects(u64, VOTERS, 4, 1))
	defer free(e)
	expect_ok(t, paxos.init(n, ids[0], m^))
	expect_ok(t, paxos.campaign(n, 0, e))
	paxos.confirm_writes_durable(e)
	prepare := packet_of(paxos.messages_slice(e)[0])
	expect_ok(t, paxos.step(n, packet_envelope(&prepare), e))
	paxos.confirm_writes_durable(e)
	promise := packet_of(paxos.messages_slice(e)[0])
	expect_ok(t, paxos.step(n, packet_envelope(&promise), e))
	testing.expect_value(t, paxos.role(n), paxos.Role.Leader)

	_, err := paxos.propose(n, 42, e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(e)
	for peer in ids[1:] {
		ack := paxos.Accepted_Message{ballot = n.ballot, slot = 1}
		envelope := paxos.Envelope(u64){from = peer, to = ids[0], message = ack}
		expect_ok(t, paxos.step(n, envelope, e))
		paxos.confirm_writes_durable(e)
		// A duplicate acknowledgement must not count twice.
		expect_ok(t, paxos.step(n, envelope, e))
		paxos.confirm_writes_durable(e)
		if peer != ids[VOTERS - 1] do testing.expect_value(t, paxos.decided_through(n), paxos.Slot(0))
	}
	testing.expect_value(t, paxos.decided_through(n), paxos.Slot(1))
}
