package paxos_tests

import "core:testing"
import paxos "../src"

// Enumerate every three-voter assignment of no vote / ballot 1 / ballot 2, every
// first-response order, and all intersecting three-member quorum pairs. If an initial
// write quorum exists, every final decision must preserve it (B3 in the small).
@(test)
election_matrix_preserves_chosen_values :: proc(t: ^testing.T) {
	orders := [6][3]int{{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}}
	quorums := [6][2]int{{1, 3}, {2, 2}, {2, 3}, {3, 1}, {3, 2}, {3, 3}}
	cases := 0
	for quorum in quorums {
		for pattern in 0..<27 {
			rounds := [3]int{pattern % 3, (pattern / 3) % 3, pattern / 9}
			counts: [3]int
			for round in rounds do counts[round] += 1
			// When earlier votes form a quorum, higher ballots must carry that value.
			lower_chosen := counts[1] >= quorum[1]
			upper_value: u64 = 11 if lower_chosen else 22
			expected: Maybe(u64)
			if lower_chosen do expected = u64(11)
			if counts[2] >= quorum[1] do expected = upper_value
			for order in orders {
				c: Review_Cluster
				review_init(t, &c, quorum[0], quorum[1])
				values := [3]u64{0, 11, upper_value}
				for round, i in rounds {
					if round == 0 do continue
					ballot := paxos.ballot_make(u64(round), 0, paxos.Node_Id(round))
					vote := vote_record(ballot, 1, &values[round])
					expect_ok(t, paxos.ledger_apply(&c.nodes[i].ledger, vote))
				}
				c.nodes[2].highest_observed_round = 2
				e: Review_Effects
				expect_ok(t, paxos.campaign(&c.nodes[2], 0, &e))
				paxos.confirm_writes_durable(&e)
				messages := paxos.messages_slice(&e)
				for index in order do append(&c.queue, packet_of(messages[index]))
				review_drain(t, &c)
				// Recovery is permitted to leave an entirely unknown slot unallocated.
				if c.nodes[2].next_slot == 1 {
					_, err := paxos.propose(&c.nodes[2], 33, &e)
					expect_ok(t, err)
					review_enqueue(&c, &e)
					review_drain(t, &c)
				}
				for _ in 0..<12 do review_tick(t, &c, 2)
				chosen, has_chosen := paxos.committed_at(&c.nodes[2], 1)
				testing.expect(t, has_chosen)
				if value, ok := expected.?; ok do testing.expect_value(t, chosen, value)
				for &node in c.nodes {
					value, ok := paxos.committed_at(&node, 1)
					testing.expect(t, ok && value == chosen)
				}
				delete(c.queue)
				cases += 1
			}
		}
	}
	testing.expect_value(t, cases, 972)
}
