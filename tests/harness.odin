// Shared test helpers. Records and envelopes reference values inside a node's ledger,
// valid only until that node's next transition; anything a test keeps longer (a journal,
// a network queue) copies the value out, exactly as a codec would on a real host.
package paxos_tests

import "core:testing"
import paxos "../src"

// One journaled record with its value copied out of the ledger.
Journal_Record :: struct($Value: typeid) {
	write: paxos.Write(Value),
	value: Value,
}

journal_append :: proc(journal: ^[dynamic]Journal_Record($V), writes: []paxos.Write(V)) {
	for w in writes {
		record := Journal_Record(V){write = w}
		#partial switch x in w {
		case paxos.Write_Vote(V):   record.value = x.value^
		case paxos.Write_Chosen(V): record.value = x.value^
		}
		append(journal, record)
	}
}

// Rebuilds a ledger from a journal with the lifetime fold.
journal_replay :: proc(
	journal: []Journal_Record($V),
	ledger: ^paxos.Ledger(V, $W),
) -> paxos.Error {
	for &record in journal {
		write := record.write
		#partial switch &x in write {
		case paxos.Write_Vote(V):   x.value = &record.value
		case paxos.Write_Chosen(V): x.value = &record.value
		}
		paxos.ledger_replay_fold(ledger, write) or_return
	}
	return .None
}

// An envelope in flight, with its value copied so the sender may move on.
Packet :: struct($Value: typeid) {
	envelope: paxos.Envelope(Value),
	value:    Value,
}

packet_of :: proc(envelope: paxos.Envelope($V)) -> (packet: Packet(V)) {
	packet.envelope = envelope
	if value, carries := paxos.message_value(envelope.message); carries do packet.value = value^
	return
}

// The envelope of a packet, pointing at the packet's own copy of the value. The packet
// must outlive the `step` call.
packet_envelope :: proc(packet: ^Packet($V)) -> paxos.Envelope(V) {
	envelope := packet.envelope
	#partial switch &m in envelope.message {
	case paxos.Promise_Message(V): m.value = &packet.value
	case paxos.Accept_Message(V):  m.value = &packet.value
	case paxos.Commit_Message(V):  m.value = &packet.value
	}
	return envelope
}

enqueue_all :: proc(queue: ^[dynamic]Packet($V), envelopes: []paxos.Envelope(V)) {
	for envelope in envelopes do append(queue, packet_of(envelope))
}

// Helpers that make a vote or a decision record from a value the test owns.
vote_record :: proc(ballot: paxos.Ballot, slot: paxos.Slot, value: ^$V) -> paxos.Write(V) {
	return paxos.Write_Vote(V){ballot = ballot, slot = slot, value = value}
}

chosen_record :: proc(slot: paxos.Slot, value: ^$V) -> paxos.Write(V) {
	return paxos.Write_Chosen(V){slot = slot, value = value}
}

commit_envelope :: proc(
	from,
	to: paxos.Node_Id,
	slot: paxos.Slot,
	value: ^$V,
) -> paxos.Envelope(V) {
	return {from = from, to = to, message = paxos.Commit_Message(V){slot = slot, value = value}}
}

envelope :: proc(from, to: paxos.Node_Id, message: paxos.Message($V)) -> paxos.Envelope(V) {
	return {from = from, to = to, message = message}
}

expect_ok :: proc(t: ^testing.T, err: paxos.Error, loc := #caller_location) {
	testing.expect_value(t, err, paxos.Error.None, loc = loc)
}

// ---------------------------------------------------------------------------------
// A small in-memory cluster of core nodes with a shuffle-free delivery loop.
// ---------------------------------------------------------------------------------

Review_Node :: paxos.Node(u64, 3, 8, 2)
Review_Effects :: paxos.Effects(u64, 3, 8, 2)
Review_Cluster :: struct {
	nodes: [3]Review_Node,
	queue: [dynamic]Packet(u64),
}

review_init :: proc(t: ^testing.T, c: ^Review_Cluster, read_quorum := 0, write_quorum := 0) {
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.membership_init(&m, ids[:], read_quorum, write_quorum))
	for &node, i in c.nodes do expect_ok(t, paxos.node_init(&node, paxos.Node_Id(i + 1), m))
}

review_enqueue :: proc(c: ^Review_Cluster, e: ^Review_Effects) {
	paxos.confirm_writes_durable(e)
	enqueue_all(&c.queue, paxos.messages_slice(e))
}

review_drain :: proc(t: ^testing.T, c: ^Review_Cluster) {
	e: Review_Effects
	for i := 0; i < len(c.queue); i += 1 {
		if !testing.expect(t, i < 10000, "network must settle") do break
		packet := c.queue[i]
		expect_ok(t, paxos.step(&c.nodes[packet.envelope.to - 1], packet_envelope(&packet), &e))
		review_enqueue(c, &e)
	}
	clear(&c.queue)
}

review_campaign :: proc(t: ^testing.T, c: ^Review_Cluster, index: int) {
	e: Review_Effects
	expect_ok(t, paxos.campaign(&c.nodes[index], 0, &e))
	review_enqueue(c, &e)
	review_drain(t, c)
	testing.expect_value(t, c.nodes[index].role, paxos.Role.Leader)
}

review_tick :: proc(t: ^testing.T, c: ^Review_Cluster, index: int) {
	e: Review_Effects
	expect_ok(t, paxos.tick(&c.nodes[index], 0, &e))
	review_enqueue(c, &e)
	review_drain(t, c)
}
