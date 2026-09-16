package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_replicated_log_normal_commands :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.NodeId{1}
	_ = paxos.membership_init(&m, nodes[:])

	log_node: paxos.Replicated_Log_Node(u64, 1, 64, 16)
	err := paxos.replicated_log_init(&log_node, 1, 10, m)
	testing.expect(t, err == .None, "Init replicated log")
	testing.expect(t, !paxos.replicated_log_is_sealed(&log_node), "Log should start unsealed")

	eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
	paxos.effects_init(&eff)

	// Campaign to become leader
	_ = paxos.replicated_log_campaign(&log_node, 0, &eff)
	paxos.effects_confirm_writes_durable(&eff)
	prepares := paxos.effects_messages_slice(&eff)

	step_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
	paxos.effects_init(&step_eff)
	_ = paxos.replicated_log_step(&log_node, prepares[0], &step_eff)
	paxos.effects_confirm_writes_durable(&step_eff)
	for rep in paxos.effects_messages_slice(&step_eff) {
		f_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
		paxos.effects_init(&f_eff)
		_ = paxos.replicated_log_step(&log_node, rep, &f_eff)
		paxos.effects_confirm_writes_durable(&f_eff)
	}

	testing.expect(t, log_node.core.role == .Leader, "Core should be leader")

	// Propose normal command
	prop_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
	paxos.effects_init(&prop_eff)
	slot, prop_err := paxos.replicated_log_propose(&log_node, 777, &prop_eff)
	testing.expect(t, prop_err == .None, "Propose command")
	testing.expect(t, slot == 1, "Slot is 1")

	committed := paxos.effects_committed_slice(&prop_eff)
	testing.expect(t, len(committed) == 1, "1 committed entry")
	#partial switch val in committed[0].value {
	case u64:
		testing.expect(t, val == 777, "Value is 777")
	case:
		testing.expect(t, false, "Expected u64 command")
	}
}

@(test)
test_replicated_log_stop_sign_seals_epoch :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.NodeId{1}
	_ = paxos.membership_init(&m, nodes[:])

	log_node: paxos.Replicated_Log_Node(u64, 1, 64, 16)
	_ = paxos.replicated_log_init(&log_node, 1, 10, m)

	eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
	paxos.effects_init(&eff)
	_ = paxos.replicated_log_campaign(&log_node, 0, &eff)
	paxos.effects_confirm_writes_durable(&eff)

	// Step self messages to become leader
	for msg in paxos.effects_messages_slice(&eff) {
		s_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
		paxos.effects_init(&s_eff)
		_ = paxos.replicated_log_step(&log_node, msg, &s_eff)
		paxos.effects_confirm_writes_durable(&s_eff)
		for rep in paxos.effects_messages_slice(&s_eff) {
			f_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
			paxos.effects_init(&f_eff)
			_ = paxos.replicated_log_step(&log_node, rep, &f_eff)
			paxos.effects_confirm_writes_durable(&f_eff)
		}
	}

	// Propose Stop Sign for next configuration 11
	next_nodes := [1]paxos.NodeId{2}
	meta := [4]u8{'s', 'n', 'a', 'p'}
	stop_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
	paxos.effects_init(&stop_eff)
	stop_slot, stop_err := paxos.replicated_log_propose_stop_sign(&log_node, 11, next_nodes[:], meta[:], &stop_eff)
	testing.expect(t, stop_err == .None, "Propose stop sign")
	testing.expect(t, stop_slot == 1, "Stop slot is 1")

	// Single node quorum: proposal immediately commits and step marks sealed
	// Let's check effects_committed_slice
	committed := paxos.effects_committed_slice(&stop_eff)
	testing.expect(t, len(committed) == 1, "Stop sign committed")
	#partial switch val in committed[0].value {
	case paxos.Stop_Sign(1, 256):
		testing.expect(t, val.configuration_id == 11, "Next conf ID is 11")
	case:
		testing.expect(t, false, "Expected Stop_Sign")
	}

	// Step an envelope or check sealed
	// In single node mode, `replicated_log_step` records the sealed stop sign
	// Since propose in single node called `record_commit`, let's verify if node is sealed
	// If not yet processed via step, let's step the commit envelope if any or check sealed
	paxos.effects_confirm_writes_durable(&stop_eff)
	commit_msgs := paxos.effects_messages_slice(&stop_eff)
	for cm in commit_msgs {
		c_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
		paxos.effects_init(&c_eff)
		_ = paxos.replicated_log_step(&log_node, cm, &c_eff)
		paxos.effects_confirm_writes_durable(&c_eff)
	}

	// Any subsequent proposal must be rejected with .LogSealed
	post_eff: paxos.Effects(paxos.Entry(u64, 1, 256), 1, 64)
	paxos.effects_init(&post_eff)
	_, sealed_err := paxos.replicated_log_propose(&log_node, 888, &post_eff)
	testing.expect(t, sealed_err == .LogSealed, "Subsequent proposals must fail with LogSealed")
}
