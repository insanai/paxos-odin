package paxos_tests

import "core:testing"
import "core:strings"
import paxos "../src"

@(test)
test_errors_explain :: proc(t: ^testing.T) {
	msg_empty := paxos.explain_error(.EmptyMembership)
	testing.expect(t, strings.contains(msg_empty, "-- EMPTY MEMBERSHIP"), "Contains empty membership header")
	testing.expect(t, strings.contains(msg_empty, "Hint: Pass a slice"), "Contains hint")

	msg_not_leader := paxos.explain_error(.NotLeader)
	testing.expect(t, strings.contains(msg_not_leader, "-- NOT LEADER"), "Contains not leader header")

	msg_window_full := paxos.explain_error(.WindowFull)
	testing.expect(t, strings.contains(msg_window_full, "-- WINDOW FULL"), "Contains window full header")

	msg_promise_reg := paxos.explain_error(.PromiseRegression)
	testing.expect(t, strings.contains(msg_promise_reg, "-- PROMISE REGRESSION"), "Contains promise regression header")

	msg_log_sealed := paxos.explain_error(.LogSealed)
	testing.expect(t, strings.contains(msg_log_sealed, "-- LOG SEALED"), "Contains log sealed header")
}
