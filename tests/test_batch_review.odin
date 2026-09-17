// Regressions from the third adversarial review: an ownership tick stays within the
// effect capacities under any supported quorum, ownership batches are admitted on the
// owner's own frontier, a rejected batch leaves nothing behind, and a recovery report of
// an older vote after a decision is not a conflict.
package paxos_tests

import "core:container/small_array"
import "core:testing"
import paxos "../src"

Batch_Node    :: paxos.Node(u64, 3, 8, 2)
Batch_Effects :: paxos.Effects(u64, 3, 8, 2)

batch_init :: proc(
	t: ^testing.T,
	n: ^Batch_Node,
	ownership: bool,
	write_quorum := 2,
	timeout: u32 = 10,
) {
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.membership_init(&m, ids[:], 4 - write_quorum, write_quorum))
	options := paxos.Node_Options{rotating_ownership = ownership, election_timeout_ticks = timeout}
	expect_ok(t, paxos.init(n, 1, m, options))
}

batch_step :: proc(
	t: ^testing.T,
	n: ^Batch_Node,
	e: ^Batch_Effects,
	from: paxos.Node_Id,
	message: paxos.Message(u64),
) -> paxos.Error {
	paxos.confirm_writes_durable(e)
	return paxos.step(n, envelope(from, 1, message), e)
}

// Read quorum 3, write quorum 1, chunk 2: every skip decides at once (two writes), and
// the stall timeout lands on the same tick. The revocation must wait for its own tick.
@(test)
batch_review_ownership_tick_fits_effects_under_write_quorum_one :: proc(t: ^testing.T) {
	n: Batch_Node
	e: Batch_Effects
	batch_init(t, &n, true, 1, 1)
	ten: u64 = 10
	accept := paxos.Accept_Message(u64){ballot = paxos.ownership_ballot(3), slot = 6, value = &ten}
	expect_ok(t, batch_step(t, &n, &e, 3, paxos.Message(u64)(accept)))
	paxos.confirm_writes_durable(&e)
	for round in 0..<4 {
		expect_ok(t, paxos.tick(&n, 0, &e))
		testing.expect(t, len(paxos.writes_slice(&e)) <= 2 * 2 + 1, "writes stay within capacity")
		paxos.confirm_writes_durable(&e)
		_ = round
	}
}

// Ownership admission uses the owner's own frontier, not the single-leader next_slot.
@(test)
batch_review_ownership_batch_admitted_after_floor_advances :: proc(t: ^testing.T) {
	n: Batch_Node
	e: Batch_Effects
	batch_init(t, &n, true)
	ten: u64 = 10
	commit := paxos.Commit_Message(u64){slot = 1, value = &ten}
	expect_ok(t, batch_step(t, &n, &e, 2, paxos.Message(u64)(commit)))
	paxos.confirm_writes_durable(&e)
	expect_ok(t, paxos.advance_memory_floor(&n, 1))
	values := [1]u64{42}
	slots: [1]paxos.Slot
	assigned, err := paxos.propose_batch(&n, values[:], slots[:], &e)
	expect_ok(t, err)
	testing.expect_value(t, len(assigned), 1)
	testing.expect_value(t, assigned[0], paxos.Slot(4))
}

// A batch that cannot fit once revoked own slots are stepped over is refused whole,
// with nothing written and the frontier untouched.
@(test)
batch_review_rejected_ownership_batch_leaves_nothing_behind :: proc(t: ^testing.T) {
	n: Batch_Node
	e: Batch_Effects
	batch_init(t, &n, true)
	// A revoker fences own slot 7; slot 1 is already suggested. Slots 4 and 10 remain,
	// and 10 lies outside the window of eight above floor 0.
	prepare := paxos.Prepare_Message{
		ballot = paxos.ballot_make(1, 0, 2), first = 7, last = 7, scope = .Bounded,
	}
	expect_ok(t, batch_step(t, &n, &e, 2, paxos.Message(u64)(prepare)))
	paxos.confirm_writes_durable(&e)
	_, err := paxos.propose(&n, 10, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	frontier := n.own_next
	values := [2]u64{20, 30}
	slots: [2]paxos.Slot
	assigned, batch_err := paxos.propose_batch(&n, values[:], slots[:], &e)
	testing.expect_value(t, batch_err, paxos.Error.Window_Full)
	testing.expect_value(t, len(assigned), 0)
	testing.expect_value(t, len(paxos.writes_slice(&e)), 0)
	testing.expect_value(t, n.own_next, frontier)
	_, voted := paxos.ledger_cell(paxos.ledger(&n), 4)
	testing.expect(t, !voted, "no vote for slot 4 was written")
	// A one-value batch fits and lands in slot 4.
	one := [1]u64{20}
	assigned, batch_err = paxos.propose_batch(&n, one[:], slots[:], &e)
	expect_ok(t, batch_err)
	testing.expect_value(t, assigned[0], paxos.Slot(4))
}

// An acceptor outside the deciding quorum may report an older, unchosen vote after
// another acceptor reported the decision. Both orders keep the decision.
@(test)
batch_review_older_vote_after_decision_is_not_a_conflict :: proc(t: ^testing.T) {
	for chosen_first in ([2]bool{true, false}) {
		n: Batch_Node
		e: Batch_Effects
		batch_init(t, &n, false)
		prepare := paxos.Prepare_Message{ballot = paxos.ballot_make(2, 0, 2), first = 1, last = 2}
		expect_ok(t, batch_step(t, &n, &e, 2, paxos.Message(u64)(prepare)))
		paxos.confirm_writes_durable(&e)
		expect_ok(t, paxos.campaign(&n, 0, &e))
		paxos.confirm_writes_durable(&e)
		ten, twenty: u64 = 10, 20
		decided := paxos.Promise_Message(u64){
			ballot = n.ballot, slot = 1, vote = paxos.ballot_make(2, 0, 2), state = .Chosen,
			value = &twenty,
		}
		older := paxos.Promise_Message(u64){
			ballot = n.ballot, slot = 1, vote = paxos.ballot_make(1, 0, 1), state = .Voted, value = &ten,
		}
		first, second := decided, older
		if !chosen_first do first, second = older, decided
		expect_ok(t, batch_step(t, &n, &e, 2, paxos.Message(u64)(first)))
		expect_ok(t, batch_step(t, &n, &e, 3, paxos.Message(u64)(second)))
		testing.expect_value(t, n.recovered_state[0], paxos.Cell_State.Chosen)
		testing.expect_value(t, n.recovered_value[0], twenty)
	}
}

// Ownership order is ascending id whatever order the host lists the members in.
@(test)
batch_review_ownership_order_is_ascending_id :: proc(t: ^testing.T) {
	shuffled := [3]paxos.Node_Id{3, 1, 2}
	m: paxos.Membership(3)
	expect_ok(t, paxos.init(&m, shuffled[:]))
	testing.expect_value(t, paxos.membership_get(&m, 0), paxos.Node_Id(1))
	n: Batch_Node
	expect_ok(t, paxos.init(&n, 2, m, paxos.Node_Options{rotating_ownership = true}))
	testing.expect_value(t, paxos.owner_of(&n, 1), paxos.Node_Id(1))
	testing.expect_value(t, paxos.owner_of(&n, 2), paxos.Node_Id(2))
	testing.expect_value(t, paxos.owner_of(&n, 3), paxos.Node_Id(3))
	testing.expect_value(t, n.own_next, paxos.Slot(2))
}

// Resubmission is best effort: a value the bounded queue cannot hold is counted.
@(test)
batch_review_resubmit_overflow_is_reported :: proc(t: ^testing.T) {
	n: Batch_Node
	e: Batch_Effects
	batch_init(t, &n, true)
	testing.expect_value(t, paxos.resubmits_dropped(&n), u32(0))
	for i in 0..<2 do small_array.push_back(&n.resubmit, u64(100 + i))
	// Slot 1 holds our suggestion; a revoker decides the no-op there while the queue is full.
	_, err := paxos.propose(&n, 42, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	zero: u64
	commit := paxos.Commit_Message(u64){slot = 1, value = &zero}
	expect_ok(t, batch_step(t, &n, &e, 2, paxos.Message(u64)(commit)))
	testing.expect_value(t, paxos.resubmits_dropped(&n), u32(1))
}
