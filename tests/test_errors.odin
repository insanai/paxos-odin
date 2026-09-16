package paxos_tests

import "core:testing"
import "core:strings"
import paxos "../src"

@(test)
test_errors_explain :: proc(t: ^testing.T) {
	msg_empty := paxos.explain_error(.Empty_Membership)
	testing.expect(t, strings.contains(msg_empty, "-- EMPTY MEMBERSHIP"), "empty membership header")
	testing.expect(t, strings.contains(msg_empty, "Hint: Pass a slice"), "Contains hint")

	msg_not_leader := paxos.explain_error(.Not_Leader)
	testing.expect(t, strings.contains(msg_not_leader, "-- NOT LEADER"), "Contains not leader header")

	msg_window_full := paxos.explain_error(.Window_Full)
	testing.expect(t, strings.contains(msg_window_full, "-- WINDOW FULL"), "Contains window full header")

	msg_promise_reg := paxos.explain_error(.Promise_Regression)
	testing.expect(t, strings.contains(msg_promise_reg, "-- PROMISE REGRESSION"), "regression header")

	msg_log_sealed := paxos.explain_error(.Log_Sealed)
	testing.expect(t, strings.contains(msg_log_sealed, "-- LOG SEALED"), "Contains log sealed header")
}

@(test)
test_every_error_explains_problem_and_recovery :: proc(t: ^testing.T) {
	for err in paxos.Error {
		if err == .None do continue
		message := paxos.explain_error(err)
		testing.expect(t, strings.contains(message, "-- "), "Every error needs a descriptive title")
		testing.expect(t, strings.contains(message, "\n\n"), "Separate the title from the explanation")
		testing.expect(t, strings.contains(message, "Hint: "), "every failure offers a corrective action")
		testing.expect(t, !strings.contains(message, "UNEXPECTED ERROR"), "every value is explained")
	}
}
