package paxos_tests

import "core:testing"
import paxos "../src"

// An owner with no representable next slot must report exhaustion, not wrap to an
// earlier slot or misdiagnose the available window as full.
@(test)
ownership_slot_exhaustion_does_not_wrap :: proc(t: ^testing.T) {
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:]))
	for id in ids {
		for distance in 0..=3 {
			n: Batch_Node
			e: Batch_Effects
			floor := max(paxos.Slot) - paxos.Slot(distance)
			expect_ok(t, paxos.continue_at(&n, id, m, floor, paxos.Trim_Anchor{},
				paxos.Node_Options{rotating_ownership = true}))
			for _ in 0..<2 {
				slot, err := paxos.propose(&n, 42, &e)
				if err == .None {
					testing.expect(t, slot > floor && slot < max(paxos.Slot))
					paxos.confirm_writes_durable(&e)
				} else {
					testing.expect_value(t, err, paxos.Error.Global_Slot_Exhausted)
				}
			}
		}
	}
}

// A bounded prepare ending at the last representable slot must terminate. Iterating
// the slots directly would wrap the loop counter back to zero.
@(test)
ownership_terminal_bounded_prepare_finishes :: proc(t: ^testing.T) {
	n: Batch_Node
	e: Batch_Effects
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:]))
	last := max(paxos.Slot)
	expect_ok(t, paxos.continue_at(&n, 1, m, last - 2, paxos.Trim_Anchor{},
		paxos.Node_Options{rotating_ownership = true}))
	prepare := paxos.Prepare_Message{
		ballot = paxos.ballot_make(1, 0, 2), first = last - 1, last = last, scope = .Bounded,
	}
	expect_ok(t, paxos.step(&n, envelope(2, 1, paxos.Message(u64)(prepare)), &e))
	testing.expect_value(t, len(paxos.writes_slice(&e)), 2)
}

// Exhaustion during admission must leave even the last available own slot untouched.
@(test)
ownership_exhausted_batch_is_atomic :: proc(t: ^testing.T) {
	n: Batch_Node
	e: Batch_Effects
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:]))
	expect_ok(t, paxos.continue_at(&n, 1, m, max(paxos.Slot) - 3, paxos.Trim_Anchor{},
		paxos.Node_Options{rotating_ownership = true}))
	frontier := n.own_next
	values := [2]u64{10, 20}
	slots: [2]paxos.Slot
	_, err := paxos.propose_batch(&n, values[:], slots[:], &e)
	testing.expect_value(t, err, paxos.Error.Global_Slot_Exhausted)
	testing.expect_value(t, n.own_next, frontier)
	testing.expect(t, paxos.is_empty(&e))
}
