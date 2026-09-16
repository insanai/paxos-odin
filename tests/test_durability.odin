package paxos_tests

import "core:testing"
import paxos "../src"

@(test)
test_effects_power_loss_barrier_flag :: proc(t: ^testing.T) {
	eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&eff)
	testing.expect(t, !paxos.effects_requires_power_loss_barrier(&eff), "Empty effects requires no barrier")

	// Commit-only batch
	paxos.effects_add_write(&eff, paxos.Write_Commit(u64){slot = 1, value = 100})
	testing.expect(t, !paxos.effects_requires_power_loss_barrier(&eff), "Commit-only requires no power loss barrier")

	// Add promise -> now requires barrier
	paxos.effects_add_write(&eff, paxos.Write_Promise(paxos.Ballot{round = 1, node = 1}))
	testing.expect(t, paxos.effects_requires_power_loss_barrier(&eff), "Promise requires power loss barrier")
}

@(test)
test_pre_durable_messages_iterator :: proc(t: ^testing.T) {
	eff: paxos.Effects(u64, 3, 64)
	paxos.effects_init(&eff)

	// Add a Heartbeat message
	paxos.effects_add_message(&eff, paxos.Envelope(u64){
		from = 1,
		to = 2,
		message = paxos.Heartbeat_Message{ballot = {round = 1, node = 1}, decided_through = 0},
	})
	// Add an Accept message (safe to pipeline)
	paxos.effects_add_message(&eff, paxos.Envelope(u64){
		from = 1,
		to = 2,
		message = paxos.Accept_Message(u64){ballot = {round = 1, node = 1}, slot = 1, value = 42},
	})
	// Add a Commit message
	paxos.effects_add_message(&eff, paxos.Envelope(u64){
		from = 1,
		to = 2,
		message = paxos.Commit_Message(u64){slot = 1, value = 42},
	})

	it := paxos.effects_pre_durable_messages(&eff)
	msg, ok := paxos.pre_durable_next(&it)
	testing.expect(t, ok, "Iterator should return an accept message")
	#partial switch val in msg.message {
	case paxos.Accept_Message(u64):
		testing.expect(t, val.slot == 1 && val.value == 42, "Accept slot 1 value 42")
	case:
		testing.expect(t, false, "Expected Accept message")
	}

	_, ok2 := paxos.pre_durable_next(&it)
	testing.expect(t, !ok2, "No more pre-durable messages should exist")
}

@(test)
test_host_managed_durability_bypass :: proc(t: ^testing.T) {
	m: paxos.Membership(1)
	nodes := [1]paxos.NodeId{1}
	_ = paxos.membership_init(&m, nodes[:])

	hnode: paxos.Host_Managed_Node(u64, 1, 64, 16)
	err := paxos.host_managed_node_init(&hnode, 1, m)
	testing.expect(t, err == .None, "Host managed node init")

	eff: paxos.Effects(u64, 1, 64, .Host_Managed)
	paxos.effects_init(&eff)

	// In host_managed mode, calling messages_slice without confirm_writes_durable does not panic
	paxos.effects_add_write(&eff, paxos.Write_Promise(paxos.Ballot{round = 1, node = 1}))
	paxos.effects_add_message(&eff, paxos.Envelope(u64){
		from = 1,
		to = 1,
		message = paxos.Heartbeat_Message{ballot = {round = 1, node = 1}, decided_through = 0},
	})

	msgs := paxos.effects_messages_slice(&eff)
	testing.expect(t, len(msgs) == 1, "Messages can be retrieved when host manages durability")
}
