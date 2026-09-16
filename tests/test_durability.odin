package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_effects_power_loss_barrier_flag :: proc(t: ^testing.T) {
	e: paxos.Effects(u64, 3, 64, 16)
	value: u64 = 100
	testing.expect(t, !paxos.requires_power_loss_barrier(&e), "empty batch needs no barrier")
	paxos.effects_add_write(&e, chosen_record(1, &value))
	testing.expect(t, !paxos.requires_power_loss_barrier(&e), "decisions need no barrier")
	paxos.effects_add_write(&e, paxos.Write_Promise{paxos.ballot_make(1, 0, 1)})
	testing.expect(t, paxos.requires_power_loss_barrier(&e), "a promise needs a barrier")
	paxos.confirm_writes_durable(&e)
}

@(test)
test_pre_durable_messages_iterator :: proc(t: ^testing.T) {
	e: paxos.Effects(u64, 3, 64, 16)
	value: u64 = 42
	b := paxos.ballot_make(1, 0, 1)
	heartbeat := paxos.Message(u64)(paxos.Heartbeat_Message{ballot = b})
	accept_msg := paxos.Message(u64)(paxos.Accept_Message(u64){ballot = b, slot = 1, value = &value})
	commit := paxos.Message(u64)(paxos.Commit_Message(u64){slot = 1, value = &value})
	paxos.effects_add_message(&e, envelope(1, 2, heartbeat))
	paxos.effects_add_message(&e, envelope(1, 2, accept_msg))
	paxos.effects_add_message(&e, envelope(1, 2, commit))

	it := paxos.pre_durable_messages(&e)
	envelope, ok := paxos.pre_durable_next(&it)
	testing.expect(t, ok, "the accept is available before the barrier")
	accept, is_accept := envelope.message.(paxos.Accept_Message(u64))
	testing.expect(t, is_accept && accept.slot == 1 && accept.value^ == 42)
	_, more := paxos.pre_durable_next(&it)
	testing.expect(t, !more, "nothing else may leave before the barrier")
}

@(test)
test_host_managed_gate :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	node: paxos.Node(u64, 1, 64, 16, .Host_Managed)
	expect_ok(t, paxos.init(&node, 1, m))

	e: paxos.Effects(u64, 1, 64, 16, .Host_Managed)
	paxos.effects_add_write(&e, paxos.Write_Promise{paxos.ballot_make(1, 0, 1)})
	paxos.effects_add_message(&e, envelope(1, 1, paxos.Message(u64)(paxos.Heartbeat_Message{})))
	// Under the host-managed gate the messages are readable before confirmation.
	testing.expect_value(t, len(paxos.messages_slice(&e)), 1)
	paxos.reset(&e)
}

@(test)
test_zero_value_effects_are_ready :: proc(t: ^testing.T) {
	e: paxos.Effects(u64, 3, 64, 16)
	testing.expect(t, paxos.is_empty(&e))
	paxos.reset(&e)
	testing.expect_value(t, len(paxos.messages_slice(&e)), 0)
}
