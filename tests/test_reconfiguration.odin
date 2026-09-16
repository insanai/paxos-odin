package paxos_tests

import "core:testing"
import paxos "../src"

Epoch_Node     :: paxos.Replicated_Log_Node(u64, 3, 8, 2, 8)
Epoch_Entry    :: paxos.Entry(u64, 3, 8)
Epoch_Effects  :: paxos.Effects(Epoch_Entry, 3, 8, 2)
Epoch_Envelope :: paxos.Log_Envelope(u64, 3, 8)

// A configuration-stamped envelope in flight, with its value copied out.
Epoch_Packet :: struct {
	configuration_id: u64,
	packet:           Packet(Epoch_Entry),
}

Epoch_Cluster :: struct {
	nodes: [3]Epoch_Node,
	queue: [dynamic]Epoch_Packet,
}

epoch_enqueue :: proc(c: ^Epoch_Cluster, index: int, effects: ^Epoch_Effects) {
	paxos.confirm_writes_durable(effects)
	for message in paxos.messages_slice(effects) {
		stamped := paxos.log_envelope(&c.nodes[index], message)
		append(&c.queue, Epoch_Packet{stamped.configuration_id, packet_of(stamped.envelope)})
	}
}

epoch_deliver :: proc(
	c: ^Epoch_Cluster,
	item: ^Epoch_Packet,
	effects: ^Epoch_Effects,
) -> paxos.Error {
	envelope := Epoch_Envelope{item.configuration_id, packet_envelope(&item.packet)}
	return paxos.log_step(&c.nodes[envelope.envelope.to - 1], envelope, effects)
}

epoch_drain :: proc(t: ^testing.T, c: ^Epoch_Cluster) {
	e: Epoch_Effects
	for i := 0; i < len(c.queue); i += 1 {
		if !testing.expect(t, i < 10000, "network must settle") do break
		item := c.queue[i]
		expect_ok(t, epoch_deliver(c, &item, &e))
		epoch_enqueue(c, int(item.packet.envelope.to - 1), &e)
	}
	clear(&c.queue)
}

@(test)
reconfiguration_cluster_handover_rejects_old_epoch :: proc(t: ^testing.T) {
	c: Epoch_Cluster
	defer delete(c.queue)
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:]))
	for &node, i in c.nodes do expect_ok(t, paxos.init(&node, paxos.Node_Id(i + 1), 10, m))

	e: Epoch_Effects
	expect_ok(t, paxos.campaign(&c.nodes[0], 0, &e))
	epoch_enqueue(&c, 0, &e)
	epoch_drain(t, &c)
	_, err := paxos.propose(&c.nodes[0], 10, &e)
	expect_ok(t, err)
	epoch_enqueue(&c, 0, &e)
	delayed := c.queue[0]
	epoch_drain(t, &c)

	stop_slot, stop_err := paxos.log_reconfigure(&c.nodes[0], 11, ids[:], nil, &e)
	expect_ok(t, stop_err)
	epoch_enqueue(&c, 0, &e)
	epoch_drain(t, &c)
	for &node in c.nodes {
		testing.expect(t, paxos.log_is_sealed(&node))
		_, append_err := paxos.propose(&node, 99, &e)
		testing.expect_value(t, append_err, paxos.Error.Log_Sealed)
	}
	stop, has_stop := paxos.log_stop_sign(&c.nodes[0])
	testing.expect(t, has_stop)
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = stop_slot}
	for &node, i in c.nodes {
		expect_ok(t, paxos.log_init_from_stop(&node, paxos.Node_Id(i + 1), stop, stop_slot, anchor))
	}

	// The delayed old-configuration message is refused with no writes and no messages.
	testing.expect_value(t, epoch_deliver(&c, &delayed, &e), paxos.Error.Configuration_Mismatch)
	testing.expect_value(t, len(paxos.writes_slice(&e)), 0)
	testing.expect_value(t, len(paxos.messages_slice(&e)), 0)

	expect_ok(t, paxos.campaign(&c.nodes[1], 0, &e))
	epoch_enqueue(&c, 1, &e)
	epoch_drain(t, &c)
	slot, proposal_err := paxos.propose(&c.nodes[1], 20, &e)
	expect_ok(t, proposal_err)
	testing.expect_value(t, slot, stop_slot + 1)
	epoch_enqueue(&c, 1, &e)
	epoch_drain(t, &c)
	for &node in c.nodes {
		entry, ok := paxos.log_read(&node, slot)
		value, is_command := entry.(u64)
		testing.expect(t, ok && is_command && value == 20)
	}
}

@(test)
reconfiguration_stop_initializer_accepts_aliased_slices :: proc(t: ^testing.T) {
	stop: paxos.Stop_Sign(3, 8)
	ids := [3]paxos.Node_Id{1, 2, 3}
	metadata := [3]u8{7, 8, 9}
	expect_ok(t, paxos.init(&stop, 1, ids[:], metadata[:]))
	members := paxos.stop_sign_members_slice(&stop)
	expect_ok(t, paxos.init(&stop, 2, members, paxos.stop_sign_metadata_slice(&stop)))
	testing.expect_value(t, paxos.stop_sign_members_slice(&stop)[2], paxos.Node_Id(3))
	testing.expect_value(t, paxos.stop_sign_metadata_slice(&stop)[2], u8(9))
}
