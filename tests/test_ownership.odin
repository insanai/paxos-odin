// Rotating slot ownership: every member proposes in its own slots without phase one.
package paxos_tests

import "core:testing"
import paxos "../src"

Owned_Node    :: paxos.Node(u64, 3, 16, 4)
Owned_Effects :: paxos.Effects(u64, 3, 16, 4)
Owned_Cluster :: struct {
	nodes: [3]Owned_Node,
	queue: [dynamic]Packet(u64),
	// Deliveries to a silenced node are dropped, as if it had crashed.
	silent: Maybe(paxos.Node_Id),
	// Messages from a muted node are dropped; it still hears everything.
	mute:   Maybe(paxos.Node_Id),
}

owned_init :: proc(t: ^testing.T, c: ^Owned_Cluster) {
	m: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	expect_ok(t, paxos.init(&m, ids[:]))
	for &node, i in c.nodes {
		expect_ok(t, paxos.init(&node, ids[i], m, paxos.Node_Options{rotating_ownership = true}))
	}
}

owned_commit :: proc(c: ^Owned_Cluster, e: ^Owned_Effects) {
	paxos.confirm_writes_durable(e)
	enqueue_all(&c.queue, paxos.messages_slice(e))
}

owned_drain :: proc(t: ^testing.T, c: ^Owned_Cluster) {
	e: Owned_Effects
	for i := 0; i < len(c.queue); i += 1 {
		if !testing.expect(t, i < 10000, "network must settle") do break
		packet := c.queue[i]
		if silent, ok := c.silent.?; ok {
			if packet.envelope.to == silent || packet.envelope.from == silent do continue
		}
		if mute, ok := c.mute.?; ok && packet.envelope.from == mute do continue
		expect_ok(t, paxos.step(&c.nodes[packet.envelope.to - 1], packet_envelope(&packet), &e))
		owned_commit(c, &e)
	}
	clear(&c.queue)
}

owned_propose :: proc(t: ^testing.T, c: ^Owned_Cluster, index: int, value: u64) -> paxos.Slot {
	e: Owned_Effects
	slot, err := paxos.propose(&c.nodes[index], value, &e)
	expect_ok(t, err)
	owned_commit(c, &e)
	return slot
}

owned_tick_all :: proc(t: ^testing.T, c: ^Owned_Cluster, rounds: int) {
	e: Owned_Effects
	for _ in 0..<rounds {
		for &node, i in c.nodes {
			if silent, ok := c.silent.?; ok && node.id == silent do continue
			expect_ok(t, paxos.tick(&node, 0, &e))
			owned_commit(c, &e)
			_ = i
		}
		owned_drain(t, c)
	}
}

owned_expect_decided :: proc(
	t: ^testing.T,
	c: ^Owned_Cluster,
	slot: paxos.Slot,
	value: u64,
	loc := #caller_location,
) {
	for &node in c.nodes {
		if silent, ok := c.silent.?; ok && node.id == silent do continue
		decided, has := paxos.committed_at(&node, slot)
		testing.expect(t, has && decided == value, "every member decides the same value", loc = loc)
	}
}

@(test)
ownership_three_owners_propose_concurrently :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	// Nobody campaigns; each member owns slots 1, 2, 3 (then 4, 5, 6) in membership order.
	testing.expect_value(t, paxos.owner_of(&c.nodes[0], 1), paxos.Node_Id(1))
	testing.expect_value(t, paxos.owner_of(&c.nodes[0], 5), paxos.Node_Id(2))
	testing.expect_value(t, owned_propose(t, &c, 0, 10), paxos.Slot(1))
	testing.expect_value(t, owned_propose(t, &c, 1, 20), paxos.Slot(2))
	testing.expect_value(t, owned_propose(t, &c, 2, 30), paxos.Slot(3))
	testing.expect_value(t, owned_propose(t, &c, 0, 40), paxos.Slot(4))
	owned_drain(t, &c)
	for slot, i in ([?]paxos.Slot{1, 2, 3, 4}) do owned_expect_decided(t, &c, slot, u64(10 * (i + 1)))
	for &node in c.nodes do testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(4))
	e: Owned_Effects
	testing.expect_value(t, paxos.campaign(&c.nodes[0], 0, &e), paxos.Error.Campaign_Disabled)
}

@(test)
ownership_idle_owners_skip :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	// Only member 1 has traffic: slots 1 and 4. Members 2 and 3 must skip 2 and 3.
	testing.expect_value(t, owned_propose(t, &c, 0, 11), paxos.Slot(1))
	testing.expect_value(t, owned_propose(t, &c, 0, 14), paxos.Slot(4))
	owned_drain(t, &c)
	owned_tick_all(t, &c, 3)
	owned_expect_decided(t, &c, 2, 0)
	owned_expect_decided(t, &c, 3, 0)
	owned_expect_decided(t, &c, 4, 14)
	for &node in c.nodes do testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(4))
}

@(test)
ownership_revokes_a_crashed_owner :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	c.silent = paxos.Node_Id(3)
	testing.expect_value(t, owned_propose(t, &c, 0, 11), paxos.Slot(1))
	testing.expect_value(t, owned_propose(t, &c, 1, 12), paxos.Slot(2))
	testing.expect_value(t, owned_propose(t, &c, 0, 14), paxos.Slot(4))
	owned_drain(t, &c)
	// Slot 3 belongs to the silent member; the prefix stalls until a revocation fills it.
	for &node in c.nodes[:2] do testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(2))
	owned_tick_all(t, &c, 30)
	owned_expect_decided(t, &c, 3, 0)
	owned_expect_decided(t, &c, 4, 14)
	for &node in c.nodes[:2] do testing.expect_value(t, paxos.decided_through(&node), paxos.Slot(4))
	// The revoker holds no standing leadership afterwards.
	for &node in c.nodes[:2] do testing.expect_value(t, paxos.role(&node), paxos.Role.Follower)
}

@(test)
ownership_revocation_keeps_a_seen_vote :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	// Member 3 suggests 33 in slot 3, and only member 2 hears it before member 3 falls silent.
	e: Owned_Effects
	slot, err := paxos.propose(&c.nodes[2], 33, &e)
	expect_ok(t, err)
	testing.expect_value(t, slot, paxos.Slot(3))
	paxos.confirm_writes_durable(&e)
	for envelope in paxos.messages_slice(&e) {
		if envelope.to == 2 do append(&c.queue, packet_of(envelope))
	}
	owned_drain(t, &c)
	c.silent = paxos.Node_Id(3)
	testing.expect_value(t, owned_propose(t, &c, 0, 11), paxos.Slot(1))
	testing.expect_value(t, owned_propose(t, &c, 1, 12), paxos.Slot(2))
	testing.expect_value(t, owned_propose(t, &c, 0, 14), paxos.Slot(4))
	owned_drain(t, &c)
	owned_tick_all(t, &c, 30)
	// B3: the revoker found member 2's vote for 33 and re-proposed it, not the no-op.
	owned_expect_decided(t, &c, 3, 33)
	owned_expect_decided(t, &c, 4, 14)
}

@(test)
ownership_revoked_suggestion_is_resubmitted :: proc(t: ^testing.T) {
	c: Owned_Cluster
	defer delete(c.queue)
	owned_init(t, &c)
	// Member 3's suggestion for slot 3 reaches nobody; members 1 and 2 revoke it to the no-op.
	e: Owned_Effects
	_, err := paxos.propose(&c.nodes[2], 33, &e)
	expect_ok(t, err)
	paxos.confirm_writes_durable(&e)
	c.silent = paxos.Node_Id(3)
	testing.expect_value(t, owned_propose(t, &c, 0, 11), paxos.Slot(1))
	testing.expect_value(t, owned_propose(t, &c, 1, 12), paxos.Slot(2))
	testing.expect_value(t, owned_propose(t, &c, 0, 14), paxos.Slot(4))
	owned_drain(t, &c)
	owned_tick_all(t, &c, 30)
	owned_expect_decided(t, &c, 3, 0)
	// Member 3 comes back, learns its suggestion lost, and proposes 33 again in slot 6.
	c.silent = nil
	owned_tick_all(t, &c, 30)
	decided, has := paxos.committed_at(&c.nodes[2], 3)
	testing.expect(t, has && decided == 0, "the returning owner learns the revocation")
	found := false
	for slot in 4..=paxos.Slot(12) {
		if value, ok := paxos.committed_at(&c.nodes[0], slot); ok && value == 33 do found = true
	}
	testing.expect(t, found, "the revoked suggestion is proposed again in a later own slot")
}
