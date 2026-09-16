// A replicated counter on three in-memory nodes.
//
// The host loop below is the whole integration contract in miniature: run one
// transition, persist its writes, confirm them, deliver its messages, apply its
// committed entries. Here "persist" is a no-op and "deliver" is a queue; a real
// host swaps those two lines for a journal and a socket.
package main

import "core:container/queue"
import "core:fmt"
import paxos "../src"

Command :: struct {
	client_id:  u32,
	request_id: u32,
	amount:     i64,
}

MEMBERS :: 3
WINDOW  :: 64
CHUNK   :: 16

Node    :: paxos.Node(Command, MEMBERS, WINDOW, CHUNK)
Effects :: paxos.Effects(Command, MEMBERS, WINDOW, CHUNK)

// An envelope in flight. A message points at a value inside the sender's ledger, so a
// transport copies the value when it queues the envelope, exactly as a codec would.
Packet :: struct {
	envelope: paxos.Envelope(Command),
	value:    Command,
}

packet_of :: proc(envelope: paxos.Envelope(Command)) -> (packet: Packet) {
	packet.envelope = envelope
	if value, carries := paxos.message_value(envelope.message); carries do packet.value = value^
	return
}

packet_envelope :: proc(packet: ^Packet) -> paxos.Envelope(Command) {
	envelope := packet.envelope
	#partial switch &m in envelope.message {
	case paxos.Promise_Message(Command): m.value = &packet.value
	case paxos.Accept_Message(Command):  m.value = &packet.value
	case paxos.Commit_Message(Command):  m.value = &packet.value
	}
	return envelope
}

Cluster :: struct {
	nodes:   [MEMBERS]Node,
	network: queue.Queue(Packet),
	counter: i64,
}

// Consumes one node's effects in the order the durability contract requires.
host_commit :: proc(cluster: ^Cluster, node_index: int, effects: ^Effects) {
	// 1. Append effects.writes to a journal and sync it. This example keeps no journal.
	// 2. Tell the batch its writes are durable; only then may messages leave.
	paxos.confirm_writes_durable(effects)
	// 3. Transmit.
	for envelope in paxos.messages_slice(effects) {
		queue.push_back(&cluster.network, packet_of(envelope))
	}
	// 4. Apply newly decided entries, in slot order. One node narrates.
	for entry in paxos.committed_slice(effects) {
		if node_index == 0 {
			cluster.counter += entry.value.amount
			fmt.printfln("slot %d: %+d -> counter = %d", entry.slot, entry.value.amount, cluster.counter)
		}
	}
}

// Delivers every queued envelope until the network is silent.
settle :: proc(cluster: ^Cluster) {
	effects: Effects
	for packet in queue.pop_front_safe(&cluster.network) {
		packet := packet
		envelope := packet_envelope(&packet)
		to := int(envelope.to - 1)
		err := paxos.step(&cluster.nodes[to], envelope, &effects)
		assert(err == .None, paxos.explain_error(err))
		host_commit(cluster, to, &effects)
	}
}

main :: proc() {
	cluster: Cluster
	queue.init(&cluster.network)
	defer queue.destroy(&cluster.network)

	membership: paxos.Membership(MEMBERS)
	ids := [MEMBERS]paxos.Node_Id{1, 2, 3}
	// Keep side effects out of assert: a release build may compile assertions away.
	membership_err := paxos.init(&membership, ids[:])
	assert(membership_err == .None)
	for &node, i in cluster.nodes {
		node_err := paxos.init(&node, ids[i], membership, paxos.Node_Options{priority = u8(i)})
		assert(node_err == .None)
	}

	// Node 1 runs phase one once; every later command commits in one round trip.
	effects: Effects
	noop := Command{}
	campaign_err := paxos.campaign(&cluster.nodes[0], noop, &effects)
	assert(campaign_err == .None)
	host_commit(&cluster, 0, &effects)
	settle(&cluster)
	assert(paxos.role(&cluster.nodes[0]) == .Leader)
	fmt.println("node 1 is the leader")

	commands := [?]Command{
		{client_id = 1, request_id = 101, amount = 10},
		{client_id = 1, request_id = 102, amount = 25},
		{client_id = 2, request_id = 201, amount = -5},
	}
	for command in commands {
		slot, err := paxos.propose(&cluster.nodes[0], command, &effects)
		assert(err == .None, paxos.explain_error(err))
		fmt.printfln("proposed request %d in slot %d", command.request_id, slot)
		host_commit(&cluster, 0, &effects)
		settle(&cluster)
	}

	// Every node holds the same decided log.
	for &node in cluster.nodes {
		assert(paxos.decided_through(&node) == len(commands))
		for slot in 1..=paxos.Slot(len(commands)) {
			value, ok := paxos.committed_at(&node, slot)
			assert(ok && value == commands[slot-1])
		}
	}
	fmt.printfln("counter = %d on all %d nodes", cluster.counter, MEMBERS)
	assert(cluster.counter == 30)
}
