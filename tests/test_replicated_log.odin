package paxos_tests

import "core:testing"
import paxos "../src"

Log1        :: paxos.Replicated_Log_Node(u64, 1, 64, 16)
Log1_Entry  :: paxos.Entry(u64, 1, 256)
Log1_Effects :: paxos.Effects(Log1_Entry, 1, 64, 16)

// Drives a single-member log to leadership by delivering its own messages.
log1_elect :: proc(t: ^testing.T, node: ^Log1) {
	e: Log1_Effects
	expect_ok(t, paxos.campaign(node, 0, &e))
	paxos.confirm_writes_durable(&e)
	queue: [dynamic]Packet(Log1_Entry)
	defer delete(queue)
	enqueue_all(&queue, paxos.messages_slice(&e))
	for i := 0; i < len(queue); i += 1 {
		packet := queue[i]
		step_e: Log1_Effects
		expect_ok(t, paxos.step(node, packet_envelope(&packet), &step_e))
		paxos.confirm_writes_durable(&step_e)
		enqueue_all(&queue, paxos.messages_slice(&step_e))
	}
	testing.expect_value(t, paxos.role(node), paxos.Role.Leader)
}

@(test)
test_replicated_log_normal_commands :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	node: Log1
	expect_ok(t, paxos.init(&node, 1, 10, m))
	testing.expect(t, !paxos.log_is_sealed(&node))
	log1_elect(t, &node)

	e: Log1_Effects
	slot, err := paxos.propose(&node, 777, &e)
	expect_ok(t, err)
	testing.expect_value(t, slot, paxos.Slot(1))
	committed := paxos.committed_slice(&e)
	testing.expect_value(t, len(committed), 1)
	value, is_command := committed[0].value^.(u64)
	testing.expect(t, is_command && value == 777)
	paxos.confirm_writes_durable(&e)
}

@(test)
test_replicated_log_stop_sign_seals_epoch :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	ids := [1]paxos.Node_Id{1}
	expect_ok(t, paxos.init(&m, ids[:]))
	node: Log1
	expect_ok(t, paxos.init(&node, 1, 10, m))
	log1_elect(t, &node)

	next := [1]paxos.Node_Id{2}
	meta := [4]u8{'s', 'n', 'a', 'p'}
	e: Log1_Effects
	stop_slot, err := paxos.log_propose_stop_sign(&node, 11, next[:], meta[:], &e)
	expect_ok(t, err)
	testing.expect_value(t, stop_slot, paxos.Slot(1))
	committed := paxos.committed_slice(&e)
	testing.expect_value(t, len(committed), 1)
	stop, is_stop := committed[0].value^.(paxos.Stop_Sign(1, 256))
	testing.expect(t, is_stop && stop.configuration_id == 11)
	paxos.confirm_writes_durable(&e)

	testing.expect(t, paxos.log_is_sealed(&node), "a local decision seals immediately")
	_, sealed_err := paxos.propose(&node, 888, &e)
	testing.expect_value(t, sealed_err, paxos.Error.Log_Sealed)
	_, again := paxos.log_propose_stop_sign(&node, 12, next[:], nil, &e)
	testing.expect_value(t, again, paxos.Error.Log_Sealed)
}

@(test)
test_replicated_log_handover_and_recovery :: proc(t: ^testing.T) {
	next := [1]paxos.Node_Id{2}
	meta := [3]u8{'r', 'f', 'c'}
	stop, err := paxos.stop_sign_create(paxos.Stop_Sign(1, 256), 20, next[:], meta[:])
	expect_ok(t, err)
	testing.expect_value(t, paxos.stop_sign_members_slice(&stop)[0], paxos.Node_Id(2))

	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = 1}
	node: Log1
	expect_ok(t, paxos.log_init_from_stop(&node, 2, stop, 1, anchor))
	testing.expect_value(t, paxos.log_configuration_id(&node), u64(20))
	testing.expect_value(t, paxos.memory_floor(&node), paxos.Slot(1))
	testing.expect_value(t, paxos.proposal_frontier(&node), paxos.Slot(2))

	m: paxos.Membership(1)
	expect_ok(t, paxos.init(&m, next[:]))
	cont: Log1
	expect_ok(t, paxos.continue_at(&cont, 2, 21, m, 1, anchor))
	testing.expect_value(t, paxos.log_configuration_id(&cont), u64(21))
	expect_ok(t, paxos.begin_recovery(&cont, anchor))
	testing.expect_value(t, paxos.memory_floor(&cont), paxos.Slot(1))
	testing.expect_value(t, paxos.stop_sign_validate_members(next[:], 1), paxos.Error.None)
	dup := [2]paxos.Node_Id{2, 2}
	testing.expect_value(t, paxos.stop_sign_validate_members(dup[:], 4), paxos.Error.Duplicate_Node_Id)
}
