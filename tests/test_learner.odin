package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_learner_contiguous_release :: proc(t: ^testing.T) {
	learner: paxos.Learner(u64, 4)
	err := paxos.learner_init(&learner, 7)
	testing.expect(t, err == .None, "Init learner")

	// Learn slot 2 (gap at slot 1): should buffer
	res, lerr := paxos.learner_learn_chosen(&learner, 7, 2, 22)
	testing.expect(t, lerr == .None, "Learn slot 2")
	testing.expect(t, res == .Buffered, "Slot 2 should be buffered")
	testing.expect(t, learner.released_through == 0, "Released should still be 0")

	// Learn slot 1: should advance to 2
	res, lerr = paxos.learner_learn_chosen(&learner, 7, 1, 11)
	testing.expect(t, lerr == .None, "Learn slot 1")
	testing.expect(t, res == .Advanced, "Slot 1 should advance release prefix")
	testing.expect(t, learner.released_through == 2, "Released should now be 2")

	// Duplicate of slot 2
	res, lerr = paxos.learner_learn_chosen(&learner, 7, 2, 22)
	testing.expect(t, lerr == .None, "Learn duplicate slot 2")
	testing.expect(t, res == .Duplicate, "Duplicate should return .Duplicate")

	// Conflicting value for slot 2
	_, conf_err := paxos.learner_learn_chosen(&learner, 7, 2, 999)
	testing.expect(t, conf_err == .Conflicting_Chosen_Value, "Conflicting value should be detected")
}

@(test)
test_learner_window_wrap_and_backpressure :: proc(t: ^testing.T) {
	learner: paxos.Learner(u64, 4)
	_ = paxos.learner_init(&learner, 100)

	// Fill slots 1..10
	for s in 1..=10 {
		res, err := paxos.learner_learn_chosen(&learner, 100, paxos.Slot(s), u64(s * 10))
		testing.expect(t, err == .None, "Learn sequence")
		testing.expect(t, res == .Advanced, "Sequence should advance")
	}
	testing.expect(t, learner.released_through == 10, "Released through 10")

	val, ok := paxos.learner_chosen_at(&learner, 10)
	testing.expect(t, ok && val == 100, "Chosen at 10 should be 100")

	// Slot 5 was overwritten in the 4-element ring buffer by slot 9
	_, ok_stale := paxos.learner_chosen_at(&learner, 5)
	testing.expect(t, !ok_stale, "Slot 5 should have rolled out of resident window")

	// Reading slot 5 should return Trimmed
	output_buf: [4]paxos.Chosen_Value(u64)
	_, read_err := paxos.learner_read_chosen(&learner, 5, output_buf[:])
	testing.expect(t, read_err == .Trimmed, "Reading slot 5 should return Trimmed")

	// Gap beyond window capacity should fail with Window_Full
	_, full_err := paxos.learner_learn_chosen(&learner, 100, 16, 160)
	testing.expect(t, full_err == .Window_Full, "Out of window gap should trigger Window_Full")
}

@(test)
test_learner_rejects_wrong_configuration :: proc(t: ^testing.T) {
	learner: paxos.Learner(u64, 4)
	_ = paxos.learner_init(&learner, 42)

	_, err := paxos.learner_learn_chosen(&learner, 99, 1, 10)
	testing.expect(t, err == .Configuration_Mismatch, "Wrong configuration must be rejected")
}
