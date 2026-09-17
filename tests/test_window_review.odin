// Regressions from the second adversarial review of 0.2.0: the live window is a
// bijection between cells and slots, one pass-through per transition, stale
// acknowledgements are not errors, and an owner is never wedged by its own bookkeeping.
package paxos_tests

import "core:testing"
import paxos "../src"

// A follower refuses a slot more than WINDOW_SLOTS above its memory floor, so a cell can
// never be tagged with a slot whose predecessor in that cell is still live.
@(test)
window_follower_refuses_slots_beyond_its_window :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	// The leader's window is 8; a peer whose floor is 0 must not vote for slot 9.
	accept := paxos.Accept_Message(u64){
		ballot = c.nodes[0].ballot, slot = 9, value = &c.nodes[0].pass_through,
	}
	expect_ok(t, paxos.step(&c.nodes[1], envelope(1, 2, paxos.Message(u64)(accept)), &e))
	testing.expect_value(t, len(paxos.writes_slice(&e)), 0)
	_, _, voted := paxos.ledger_vote_at(paxos.ledger(&c.nodes[1]), 9)
	testing.expect(t, !voted, "a slot beyond the follower's window is not voted")
	// Within the window it is.
	accept.slot = 8
	expect_ok(t, paxos.step(&c.nodes[1], envelope(1, 2, paxos.Message(u64)(accept)), &e))
	_, _, voted = paxos.ledger_vote_at(paxos.ledger(&c.nodes[1]), 8)
	testing.expect(t, voted, "a slot inside the window is voted")
}

// A decision just past a full window is released through the pass-through value, one
// per transition, and each record carries its own slot's value.
@(test)
window_pass_through_releases_one_decision_per_transition :: proc(t: ^testing.T) {
	n: paxos.Node(u64, 1, 2, 2)
	e: paxos.Effects(u64, 1, 2, 2)
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	expect_ok(t, paxos.init(&n, 1, m))
	expect_ok(t, paxos.campaign(&n, 0, &e))
	paxos.confirm_writes_durable(&e)
	queue: [dynamic]Packet(u64)
	defer delete(queue)
	enqueue_all(&queue, paxos.messages_slice(&e))
	for i := 0; i < len(queue); i += 1 {
		packet := queue[i]
		expect_ok(t, paxos.step(&n, packet_envelope(&packet), &e))
		paxos.confirm_writes_durable(&e)
		enqueue_all(&queue, paxos.messages_slice(&e))
	}
	testing.expect_value(t, paxos.role(&n), paxos.Role.Leader)
	for value in 11..=12 {
		_, err := paxos.propose(&n, u64(value), &e)
		expect_ok(t, err)
		paxos.confirm_writes_durable(&e)
	}
	testing.expect_value(t, paxos.decided_through(&n), paxos.Slot(2))
	// The host has not consumed anything, so slots 3 and 4 have no cell: each commit
	// passes through, and the record written for it points at that slot's value.
	for value in 13..=14 {
		payload := u64(value)
		commit := paxos.Commit_Message(u64){slot = paxos.Slot(value - 10), value = &payload}
		expect_ok(t, paxos.step(&n, envelope(1, 1, paxos.Message(u64)(commit)), &e))
		released := paxos.committed_slice(&e)
		testing.expect_value(t, len(released), 1)
		testing.expect_value(t, released[0].value^, payload)
		writes := paxos.writes_slice(&e)
		testing.expect_value(t, len(writes), 1)
		chosen, is_chosen := writes[0].(paxos.Write_Chosen(u64))
		testing.expect(t, is_chosen && chosen.value^ == payload, "the record carries this slot's value")
		paxos.confirm_writes_durable(&e)
	}
	testing.expect_value(t, paxos.decided_through(&n), paxos.Slot(4))
}

// A late duplicate acknowledgement for a slot whose cell has moved on is ignored.
@(test)
window_stale_acknowledgement_is_not_an_error :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	slot, err := paxos.propose(&c.nodes[0], 42, &e)
	expect_ok(t, err)
	review_enqueue(&c, &e)
	review_drain(t, &c)
	testing.expect_value(t, paxos.decided_through(&c.nodes[0]), slot)
	expect_ok(t, paxos.advance_memory_floor(&c.nodes[0], slot))
	// Slots 2..8 fill the window, then slot 9 reuses slot 1's cell.
	for value in 2..=9 {
		_, err = paxos.propose(&c.nodes[0], u64(value), &e)
		expect_ok(t, err)
		review_enqueue(&c, &e)
		review_drain(t, &c)
	}
	ack := paxos.Accepted_Message{ballot = c.nodes[0].ballot, slot = slot}
	expect_ok(t, paxos.step(&c.nodes[0], envelope(2, 1, paxos.Message(u64)(ack)), &e))
	expect_ok(t, paxos.step(&c.nodes[0], envelope(3, 1, paxos.Message(u64)(ack)), &e))
}

// An owner whose own slots were decided by commits keeps proposing after the host
// advances the floor past them.
@(test)
ownership_owner_keeps_proposing_after_floor_passes_its_next_slot :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	// Owners 2 and 3 decide slots 2, 3, 5, 6, 8, 9; owner 1 skips 1, 4, 7 via ticks.
	for value in 21..=23 {
		owned_propose(t, &c, 1, u64(value))
		owned_propose(t, &c, 2, u64(value) + 10)
	}
	owned_drain(t, &c)
	owned_tick_all(t, &c, 3)
	testing.expect_value(t, paxos.decided_through(&c.nodes[0]), paxos.Slot(9))
	expect_ok(t, paxos.advance_memory_floor(&c.nodes[0], 9))
	// Owner 1's next own slot must be above the floor: 10.
	testing.expect_value(t, owned_propose(t, &c, 0, 100), paxos.Slot(10))
	owned_drain(t, &c)
	owned_expect_decided(t, &c, 10, 100)
}

// An owner is not wedged when a peer's accept for a far slot arrives before its own
// slot in that cell was used: the far slot is refused, the own slot stays usable.
@(test)
ownership_far_accept_does_not_wedge_owner :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	e: Owned_Effects
	// Window is 16; slot 19 shares cell with slot 3 (owner 3). Owner 1 at floor 0 refuses.
	accept := paxos.Accept_Message(u64){
		ballot = paxos.ownership_ballot(3), slot = 19, value = &c.nodes[2].pass_through,
	}
	expect_ok(t, paxos.step(&c.nodes[0], envelope(3, 1, paxos.Message(u64)(accept)), &e))
	for round in 0..<3 {
		expect_ok(t, paxos.tick(&c.nodes[0], 0, &e))
		owned_commit(&c, &e)
		_ = round
	}
	testing.expect_value(t, owned_propose(t, &c, 0, 7), paxos.Slot(1))
	owned_drain(t, &c)
	owned_expect_decided(t, &c, 1, 7)
}

// A suggestion the owner itself overwrites with a revoker's no-op is resubmitted.
@(test)
ownership_overwritten_suggestion_is_resubmitted :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	e: Owned_Effects
	// Owner 1 suggests 42 in slot 1; its accepts never leave.
	slot, err := paxos.propose(&c.nodes[0], 42, &e)
	expect_ok(t, err)
	testing.expect_value(t, slot, paxos.Slot(1))
	paxos.confirm_writes_durable(&e)
	// Owner 2 makes slot 2 known; the others see a stall at slot 1 and revoke it. Owner 1
	// hears the revoker's prepare, accept, and commit, but nothing it sends gets through.
	c.mute = 1
	owned_propose(t, &c, 1, 5)
	owned_drain(t, &c)
	owned_tick_all(t, &c, 12)
	for &node in c.nodes {
		decided, has := paxos.committed_at(&node, 1)
		testing.expect(t, has && decided == 0, "the revoked slot decides the no-op everywhere")
	}
	// While muted, owner 1 already re-proposed 42 in a later own slot and that accept
	// was lost too; once it can speak again, retransmission or a further revocation and
	// resubmission gets 42 decided.
	c.mute = nil
	owned_tick_all(t, &c, 30)
	found := false
	for s in 1..=paxos.decided_through(&c.nodes[0]) {
		if v, ok := paxos.committed_at(&c.nodes[0], s); ok && v == 42 do found = true
	}
	testing.expect(t, found, "42 was proposed again after its slot was revoked")
}

// A stall reported from beyond the window is revoked within the window: the range is
// clamped to memory_floor + WINDOW_SLOTS, so the revoker can always promise itself.
@(test)
ownership_revocation_range_stays_inside_the_window :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	e: Owned_Effects
	for value in 1..=5 {
		owned_propose(t, &c, 0, u64(value))
		owned_propose(t, &c, 1, u64(value) + 10)
		owned_propose(t, &c, 2, u64(value) + 20)
	}
	owned_drain(t, &c)
	testing.expect_value(t, paxos.decided_through(&c.nodes[0]), paxos.Slot(15))
	// A commit for slot 17 is beyond owner 1's window (floor 0, width 16): not stored,
	// but the stall it reveals is real.
	c.silent = 2
	commit := paxos.Commit_Message(u64){slot = 17, value = &c.nodes[1].pass_through}
	expect_ok(t, paxos.step(&c.nodes[0], envelope(2, 1, paxos.Message(u64)(commit)), &e))
	_, stored := paxos.committed_at(&c.nodes[0], 17)
	testing.expect(t, !stored, "a slot beyond the window is not stored")
	for round in 0..<12 {
		expect_ok(t, paxos.tick(&c.nodes[0], 0, &e))
		owned_commit(&c, &e)
		_ = round
	}
	testing.expect_value(t, paxos.role(&c.nodes[0]), paxos.Role.Preparing)
	testing.expect_value(t, c.nodes[0].recover_last, paxos.Slot(16))
}

// A leader whose inherited gap no live peer can serve runs phase one again.
@(test)
leader_recampaigns_when_inherited_gap_stalls :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	// Leader 1 decides slot 1 with node 2; node 3 hears nothing of it.
	untouched := c.nodes[2]
	_, err := paxos.propose(&c.nodes[0], 11, &e)
	expect_ok(t, err)
	review_enqueue(&c, &e)
	review_drain(t, &c)
	c.nodes[2] = untouched
	// Node 2 trims through slot 1. Node 1 is down. Node 3 campaigns; node 2 answers the
	// prepare (fencing slot 1 as its trimmed history) and then dies.
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 1}
	expect_ok(t, paxos.install_chosen_trim(&c.nodes[1], anchor, &e))
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.campaign(&c.nodes[2], 0, &e))
	review_enqueue(&c, &e)
	for i := 0; i < len(c.queue); i += 1 {
		packet := c.queue[i]
		if packet.envelope.to == 1 do continue
		expect_ok(t, paxos.step(&c.nodes[packet.envelope.to - 1], packet_envelope(&packet), &e))
		paxos.confirm_writes_durable(&e)
		for message in paxos.messages_slice(&e) {
			#partial switch _ in message.message {
			case paxos.Promise_Message(u64), paxos.Promise_Range_Message:
				append(&c.queue, packet_of(message))
			case:
				if message.from != 2 do append(&c.queue, packet_of(message))
			}
		}
	}
	clear(&c.queue)
	testing.expect_value(t, paxos.role(&c.nodes[2]), paxos.Role.Leader)
	testing.expect_value(t, paxos.decided_through(&c.nodes[2]), paxos.Slot(0))
	// Node 1 is back; node 2 stays dead. Within a few timeouts node 3 must re-run phase
	// one with {1, 3} and recover slot 1 from node 1.
	for round in 0..<40 {
		for i in 0..<3 {
			if i == 1 do continue
			expect_ok(t, paxos.tick(&c.nodes[i], 0, &e))
			review_enqueue(&c, &e)
		}
		for i := 0; i < len(c.queue); i += 1 {
			packet := c.queue[i]
			if packet.envelope.to == 2 do continue
			expect_ok(t, paxos.step(&c.nodes[packet.envelope.to - 1], packet_envelope(&packet), &e))
			review_enqueue(&c, &e)
		}
		clear(&c.queue)
		_ = round
	}
	testing.expect_value(t, paxos.decided_through(&c.nodes[2]), paxos.Slot(1))
	value, ok := paxos.committed_at(&c.nodes[2], 1)
	testing.expect(t, ok && value == 11, "the gap holds the value slot 1 already chose")
}
