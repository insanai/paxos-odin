package paxos_tests

import "core:testing"
import paxos "../src"

// The oracle is keyed by absolute slot, independently of either ring or chunk indexing.
chunk_oracle_run :: proc(t: ^testing.T, $C: int, reverse: bool) {
	n: paxos.Node(u64, 3, 8, C)
	e: paxos.Effects(u64, 3, 8, C)
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:], 3, 1))
	expect_ok(t, paxos.continue_at(&n, 1, m, 7, paxos.Trim_Anchor{}))
	expect_ok(t, paxos.ledger_apply(&n.ledger, paxos.Write_Promise{paxos.ballot_make(3, 0, 1)}))
	expect_ok(t, paxos.campaign(&n, 0, &e))
	ballot := n.ballot
	oracle: [32]u64
	for round in 0..<2 {
		base, last := n.recover_base, n.recover_last
		for slot in base..=last do oracle[slot] = slot * 20
		// Manifests can arrive before their values. The third peer has no prior votes.
		for peer in 1..=3 {
			paxos.confirm_writes_durable(&e)
			manifest := paxos.Promise_Range_Message{
				ballot = ballot, first = base, last = last,
				reported = u32(C) if peer < 3 else 0, more = round == 0,
			}
			expect_ok(t, paxos.step(&n, envelope(paxos.Node_Id(peer), 1,
				paxos.Message(u64)(manifest)), &e))
		}
		for offset in 0..<C {
			slot := base + paxos.Slot(C - 1 - offset if reverse else offset)
			for order in 0..<2 {
				peer := 2 - order if reverse else 1 + order
				value := slot * u64(peer * 10)
				report := paxos.Promise_Message(u64){
					ballot = ballot, slot = slot, vote = paxos.ballot_make(u64(peer), 0, 2),
					state = .Voted, value = &value,
				}
				// Duplicates never satisfy an additional member or an additional slot.
				for _ in 0..<2 {
					paxos.confirm_writes_durable(&e)
					expect_ok(t, paxos.step(&n, envelope(paxos.Node_Id(peer), 1,
						paxos.Message(u64)(report)), &e))
					for entry in paxos.committed_slice(&e) {
						testing.expect_value(t, entry.value^, oracle[entry.slot])
					}
				}
			}
		}
		testing.expect_value(t, n.delivered_through, last)
		for slot in base..=last {
			value, found := paxos.committed_at(&n, slot)
			testing.expect(t, found && value == oracle[slot])
		}
		paxos.confirm_writes_durable(&e)
		expect_ok(t, paxos.advance_memory_floor(&n, last))
	}
	testing.expect_value(t, n.role, paxos.Role.Leader)
}

@(test)
recovery_chunk_absolute_slot_oracle :: proc(t: ^testing.T) {
	for reverse in ([2]bool{false, true}) {
		chunk_oracle_run(t, 1, reverse)
		chunk_oracle_run(t, 3, reverse)
		chunk_oracle_run(t, 8, reverse)
	}
}

// A stale slot and an old ballot must be rejected before touching scratch or a value pointer.
@(test)
recovery_chunk_stale_reports_do_not_alias :: proc(t: ^testing.T) {
	n: paxos.Node(u64, 3, 8, 3)
	e: paxos.Effects(u64, 3, 8, 3)
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:]))
	expect_ok(t, paxos.continue_at(&n, 1, m, 7, paxos.Trim_Anchor{}))
	expect_ok(t, paxos.campaign(&n, 0, &e))
	ballot := n.ballot
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.campaign(&n, 0, &e))
	for slot in ([4]paxos.Slot{0, 5, 11, max(paxos.Slot)}) {
		paxos.confirm_writes_durable(&e)
		report := paxos.Promise_Message(u64){ballot = n.ballot, slot = slot, state = .Voted}
		expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(report)), &e))
	}
	report := paxos.Promise_Message(u64){ballot = ballot, slot = 8, state = .Voted}
	expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(report)), &e))
	testing.expect_value(t, n.election[1].received_in_range, u32(0))
	for state in n.recovered_state do testing.expect_value(t, state, paxos.Cell_State.Empty)
}

@(test)
recovery_chunk_payload_and_bitmap_sizes :: proc(t: ^testing.T) {
	n := new(paxos.Node([128]u64, 3, 256, 3))
	defer free(n)
	testing.expect_value(t, size_of(n.recovered_value), 3 * 1024)
	testing.expect_value(t, size_of(n.promise_seen[0]), 8)
	testing.expect_value(t, len(n.recovered_slot), 3)
}

// Backpressure must retain the current chunk until the host releases ledger cells.
@(test)
recovery_chunk_retry_keeps_values :: proc(t: ^testing.T) {
	n: paxos.Node(u64, 3, 8, 3)
	e: paxos.Effects(u64, 3, 8, 3)
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:], 3, 1))
	expect_ok(t, paxos.init(&n, 1, m))
	for slot in 1..=7 {
		value := u64(slot)
		paxos.confirm_writes_durable(&e)
		commit := paxos.Commit_Message(u64){slot = paxos.Slot(slot), value = &value}
		expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(commit)), &e))
	}
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.campaign(&n, 0, &e))
	for slot in 8..=10 {
		value := u64(slot * 10)
		paxos.confirm_writes_durable(&e)
		report := paxos.Promise_Message(u64){
			ballot = n.ballot, slot = paxos.Slot(slot), vote = paxos.ownership_ballot(2),
			state = .Voted, value = &value,
		}
		expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(report)), &e))
	}
	for peer in 1..=3 {
		paxos.confirm_writes_durable(&e)
		manifest := paxos.Promise_Range_Message{
			ballot = n.ballot, first = 8, last = 10, reported = 3 if peer == 2 else 0,
		}
		expect_ok(t, paxos.step(&n, envelope(paxos.Node_Id(peer), 1,
			paxos.Message(u64)(manifest)), &e))
	}
	testing.expect_value(t, n.role, paxos.Role.Preparing)
	testing.expect_value(t, n.delivered_through, paxos.Slot(8))
	testing.expect_value(t, n.recovered_value[2], u64(100))
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.advance_memory_floor(&n, 7))
	expect_ok(t, paxos.tick(&n, 0, &e))
	testing.expect_value(t, n.delivered_through, paxos.Slot(10))
	for slot in 8..=10 {
		value, ok := paxos.committed_at(&n, paxos.Slot(slot))
		testing.expect(t, ok && value == u64(slot * 10))
	}
}

@(test)
recovery_chunk_large_payload_survives_rollover :: proc(t: ^testing.T) {
	V :: [128]u64
	nodes: [3]paxos.Node(V, 3, 8, 3)
	e: paxos.Effects(V, 3, 8, 3)
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	queue: [dynamic]Packet(V)
	defer delete(queue)
	expect_ok(t, paxos.init(&m, ids[:]))
	for &n, i in nodes {
		expect_ok(t, paxos.continue_at(&n, ids[i], m, 7, paxos.Trim_Anchor{}))
		for slot in 8..=13 {
			v := V{0 = u64(slot), 127 = ~u64(slot)}
			write := paxos.Write_Vote(V){ballot = paxos.ballot_make(1, 0, 2),
				slot = paxos.Slot(slot), value = &v}
			expect_ok(t, paxos.ledger_apply(&n.ledger, paxos.Write(V)(write)))
		}
	}
	expect_ok(t, paxos.campaign(&nodes[0], V{}, &e))
	paxos.confirm_writes_durable(&e)
	enqueue_all(&queue, paxos.messages_slice(&e))
	for head := 0; head < len(queue); head += 1 {
		packet := queue[head]
		env := packet_envelope(&packet)
		expect_ok(t, paxos.step(&nodes[env.to - 1], env, &e))
		for entry in paxos.committed_slice(&e) {
			testing.expect(t, entry.value^ == V{0 = entry.slot, 127 = ~entry.slot})
		}
		paxos.confirm_writes_durable(&e)
		enqueue_all(&queue, paxos.messages_slice(&e))
	}
	for &n in nodes do testing.expect_value(t, n.delivered_through, paxos.Slot(13))
}

// Once phase two starts, later promises cannot change the proposal even if recovery
// is paused at the window boundary. Read quorum one makes that arrival order easy to reach.
@(test)
recovery_chunk_freezes_selection_before_partial_drive :: proc(t: ^testing.T) {
	n: paxos.Node(u64, 3, 8, 3)
	e: paxos.Effects(u64, 3, 8, 3)
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:], 1, 3))
	expect_ok(t, paxos.init(&n, 1, m))
	for slot in 1..=7 {
		v := u64(slot)
		paxos.confirm_writes_durable(&e)
		commit := paxos.Commit_Message(u64){slot = paxos.Slot(slot), value = &v}
		expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(commit)), &e))
	}
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.ledger_apply(&n.ledger, paxos.Write_Promise{paxos.ballot_make(3, 0, 1)}))
	expect_ok(t, paxos.campaign(&n, 0, &e))
	v: u64 = 80
	report := paxos.Promise_Message(u64){ballot = n.ballot, slot = 8,
		vote = paxos.ballot_make(1, 0, 2), state = .Voted, value = &v}
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(report)), &e))
	manifest := paxos.Promise_Range_Message{
		ballot = n.ballot, first = 8, last = 10, reported = 1, more = true,
	}
	expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(manifest)), &e))
	testing.expect_value(t, n.role, paxos.Role.Preparing)
	paxos.confirm_writes_durable(&e)
	v = 90
	report.vote = paxos.ballot_make(2, 0, 3)
	expect_ok(t, paxos.step(&n, envelope(3, 1, paxos.Message(u64)(report)), &e))
	_, voted, found := paxos.ledger_vote_at(&n.ledger, 8)
	testing.expect(t, found && voted^ == 80)
	testing.expect_value(t, n.recovered_value[0], u64(80))
}

// A sparse retry scan must not wrap and send the same slot C times in one transition.
@(test)
recovery_sparse_resend_visits_each_slot_once :: proc(t: ^testing.T) {
	c: Review_Cluster
	defer delete(c.queue)
	review_init(t, &c)
	review_campaign(t, &c, 0)
	e: Review_Effects
	_, err := paxos.propose(&c.nodes[0], 42, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.reconnected(&c.nodes[0], 2, &e))
	messages := paxos.messages_slice(&e)
	testing.expect_value(t, len(messages), 1)
	accept, ok := messages[0].message.(paxos.Accept_Message(u64))
	testing.expect(t, ok && accept.slot == 1 && accept.value^ == 42)
}
