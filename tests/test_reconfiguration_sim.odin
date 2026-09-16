// Seeded reconfiguration scenarios on a three-voter replicated log.
//
// Delivery order is shuffled per seed, journals persist every write before any
// message leaves, and targeted faults drop or duplicate the accept that carries the
// stop sign. Every scenario checks: seal agreement, nothing decided past the seal,
// replay keeps the seal, and the next configuration decides new commands on the same
// slot line.
package paxos_tests

import "core:testing"
import paxos "../src"

SEAL_MEMBERS  :: 4
SEAL_WINDOW   :: 8
SEAL_CHUNK    :: 2
SEAL_METADATA :: 32
SEAL_SEEDS    :: 16

Seal_Log      :: paxos.Replicated_Log_Node(u64, SEAL_MEMBERS, SEAL_WINDOW, SEAL_CHUNK, SEAL_METADATA)
Seal_Entry    :: paxos.Entry(u64, SEAL_MEMBERS, SEAL_METADATA)
Seal_Effects  :: paxos.Effects(Seal_Entry, SEAL_MEMBERS, SEAL_WINDOW, SEAL_CHUNK)
Seal_Envelope :: paxos.Log_Envelope(u64, SEAL_MEMBERS, SEAL_METADATA)
Seal_Stop     :: paxos.Stop_Sign(SEAL_MEMBERS, SEAL_METADATA)

Seal_Packet :: struct {
	configuration_id: u64,
	packet:           Packet(Seal_Entry),
}

Seal_Target :: struct {
	slot: paxos.Slot,
	to:   paxos.Node_Id,
}

Seal_Cluster :: struct {
	t:          ^testing.T,
	prng:       u64,
	nodes:      [SEAL_MEMBERS]Seal_Log,
	journals:   [SEAL_MEMBERS][dynamic]Journal_Record(Seal_Entry),
	network:    [dynamic]Seal_Packet,
	// Targeted faults: drop or duplicate the next accept for `slot` addressed to `to`.
	drop:       Maybe(Seal_Target),
	duplicate:  Maybe(Seal_Target),
	dropped:    int,
	duplicated: int,
}

seal_next :: proc(c: ^Seal_Cluster) -> u64 {
	c.prng += 0x9e3779b97f4a7c15
	z := c.prng
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

seal_init :: proc(
	t: ^testing.T,
	c: ^Seal_Cluster,
	seed: u64,
	members: []paxos.Node_Id,
	configuration_id: u64,
	options := paxos.Node_Options{},
) {
	c.t = t
	c.prng = seed
	m: paxos.Membership(SEAL_MEMBERS)
	expect_ok(t, paxos.init(&m, members))
	for id in members do expect_ok(t, paxos.init(&c.nodes[id - 1], id, configuration_id, m, options))
}

seal_destroy :: proc(c: ^Seal_Cluster) {
	for &journal in c.journals do delete(journal)
	delete(c.network)
}

// The host commit sequence: journal, confirm, then transmit (with targeted faults).
seal_commit :: proc(c: ^Seal_Cluster, index: int, effects: ^Seal_Effects) {
	// Oracle: a log sealed by a decided stop sign never releases an entry above it.
	if _, sealed := paxos.log_stop_sign(&c.nodes[index]); sealed {
		for entry in paxos.committed_slice(effects) {
			testing.expectf(c.t, entry.slot <= paxos.log_stop_slot(&c.nodes[index]),
				"node %d released slot %d above its seal at %d (configuration %d)",
				index + 1, entry.slot, paxos.log_stop_slot(&c.nodes[index]),
				paxos.log_configuration_id(&c.nodes[index]))
		}
	}
	journal_append(&c.journals[index], paxos.writes_slice(effects))
	paxos.confirm_writes_durable(effects)
	for message in paxos.messages_slice(effects) {
		stamped := paxos.log_envelope(&c.nodes[index], message)
		item := Seal_Packet{stamped.configuration_id, packet_of(message)}
		if accept, is_accept := message.message.(paxos.Accept_Message(Seal_Entry)); is_accept {
			if target, armed := c.drop.?; armed && target.slot == accept.slot && target.to == message.to {
				c.drop = nil
				c.dropped += 1
				continue
			}
			twin, twinned := c.duplicate.?
			if twinned && twin.slot == accept.slot && twin.to == message.to {
				c.duplicate = nil
				c.duplicated += 1
				append(&c.network, item)
			}
		}
		append(&c.network, item)
	}
}

// Delivers queued envelopes in a seeded random order until the network is silent.
seal_settle :: proc(c: ^Seal_Cluster, rounds := 64) {
	effects: Seal_Effects
	for _ in 0..<rounds {
		if len(c.network) == 0 do break
		for len(c.network) > 0 {
			index := int(seal_next(c) % u64(len(c.network)))
			item := c.network[index]
			unordered_remove(&c.network, index)
			to := int(item.packet.envelope.to - 1)
			envelope := Seal_Envelope{item.configuration_id, packet_envelope(&item.packet)}
			err := paxos.step(&c.nodes[to], envelope, &effects)
			if err == .Configuration_Mismatch do continue
			expect_ok(c.t, err)
			seal_commit(c, to, &effects)
		}
		for &node, i in c.nodes {
			if paxos.id(&node) == 0 do continue
			expect_ok(c.t, paxos.tick(&node, 0, &effects))
			seal_commit(c, i, &effects)
		}
	}
}

seal_elect :: proc(c: ^Seal_Cluster, index: int) {
	effects: Seal_Effects
	expect_ok(c.t, paxos.campaign(&c.nodes[index], 0, &effects))
	seal_commit(c, index, &effects)
	seal_settle(c)
	testing.expect_value(c.t, paxos.role(&c.nodes[index]), paxos.Role.Leader)
}

seal_append :: proc(c: ^Seal_Cluster, index: int, value: u64) -> paxos.Slot {
	effects: Seal_Effects
	slot, err := paxos.propose(&c.nodes[index], value, &effects)
	expect_ok(c.t, err)
	seal_commit(c, index, &effects)
	return slot
}

seal_reconfigure :: proc(
	c: ^Seal_Cluster,
	index: int,
	next_id: u64,
	members: []paxos.Node_Id,
) -> paxos.Slot {
	effects: Seal_Effects
	metadata := [4]u8{'i', 'm', 'g', '1'}
	slot, err := paxos.log_reconfigure(&c.nodes[index], next_id, members, metadata[:], &effects)
	expect_ok(c.t, err)
	seal_commit(c, index, &effects)
	return slot
}

// Oracle: every member decided the same stop sign in the same slot, and their sealed
// prefixes are identical entry by entry.
seal_expect_agreement :: proc(
	c: ^Seal_Cluster,
	members: []paxos.Node_Id,
) -> (stop: Seal_Stop, stop_slot: paxos.Slot) {
	first := true
	for id in members {
		node := &c.nodes[id - 1]
		this_stop, sealed := paxos.log_stop_sign(node)
		testing.expect(c.t, sealed, "every member must observe the seal")
		this_slot := paxos.log_stop_slot(node)
		testing.expect_value(c.t, paxos.decided_through(node), this_slot)
		if first {
			stop, stop_slot = this_stop, this_slot
			first = false
			continue
		}
		testing.expect_value(c.t, this_slot, stop_slot)
		testing.expect(c.t, this_stop == stop, "stop signs must match")
		for slot in 1..=stop_slot {
			a, ok_a := paxos.committed_at(&c.nodes[members[0] - 1], slot)
			b, ok_b := paxos.committed_at(node, slot)
			testing.expect(c.t, ok_a && ok_b && a == b, "sealed prefixes must match")
		}
	}
	return
}

// Oracle: nothing past the seal is decided and appends are refused.
seal_expect_nothing_after :: proc(
	c: ^Seal_Cluster,
	members: []paxos.Node_Id,
	stop_slot: paxos.Slot,
) {
	effects: Seal_Effects
	for id in members {
		node := &c.nodes[id - 1]
		_, decided := paxos.committed_at(node, stop_slot + 1)
		testing.expect(c.t, !decided, "no slot past the seal may be decided")
		_, err := paxos.propose(node, 999, &effects)
		testing.expect_value(c.t, err, paxos.Error.Log_Sealed)
	}
}

// Oracle: replaying the journal restores the seal.
seal_expect_replay_keeps_seal :: proc(
	c: ^Seal_Cluster,
	members: []paxos.Node_Id,
	configuration_id: u64,
	stop_slot: paxos.Slot,
) {
	m: paxos.Membership(SEAL_MEMBERS)
	expect_ok(c.t, paxos.init(&m, members))
	for id in members {
		ledger: paxos.Ledger(Seal_Entry, SEAL_WINDOW)
		expect_ok(c.t, journal_replay(c.journals[id - 1][:], &ledger))
		replayed: Seal_Log
		expect_ok(c.t, paxos.restore(&replayed, id, configuration_id, m, ledger))
		testing.expect(c.t, paxos.log_is_sealed(&replayed), "replay must rediscover the seal")
		testing.expect_value(c.t, paxos.log_stop_slot(&replayed), stop_slot)
	}
}

// Oracle: the next configuration continues the slot line and decides new commands.
seal_expect_next_epoch_decides :: proc(
	c: ^Seal_Cluster,
	stop: Seal_Stop,
	stop_slot: paxos.Slot,
	leader: paxos.Node_Id,
) {
	stop := stop
	members := paxos.stop_sign_members_slice(&stop)
	anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = stop_slot}
	for id in members {
		expect_ok(c.t, paxos.log_init_from_stop(&c.nodes[id - 1], id, stop, stop_slot, anchor))
		clear(&c.journals[id - 1])
	}
	clear(&c.network)
	seal_elect(c, int(leader - 1))
	values := [3]u64{31, 32, 33}
	for value, i in values {
		testing.expect_value(c.t, seal_append(c, int(leader - 1), value), stop_slot + paxos.Slot(i) + 1)
	}
	seal_settle(c)
	for id in members {
		for value, i in values {
			entry, ok := paxos.committed_at(&c.nodes[id - 1], stop_slot + paxos.Slot(i) + 1)
			decided, is_command := entry.(u64)
			testing.expect(c.t, ok && is_command && decided == value, "next epoch decides every command")
		}
		testing.expect_value(c.t, paxos.log_configuration_id(&c.nodes[id - 1]), stop.configuration_id)
	}
}

@(test)
reconfiguration_sim_seal_survives_drop_duplicate_and_reorder :: proc(t: ^testing.T) {
	members := [3]paxos.Node_Id{1, 2, 3}
	for seed in 1..=SEAL_SEEDS {
		c: Seal_Cluster
		defer seal_destroy(&c)
		seal_init(t, &c, u64(seed), members[:], 1)
		seal_elect(&c, 0)
		seal_append(&c, 0, 11)
		seal_settle(&c)
		// A command and the seal race; the seal's accept is dropped once and duplicated once.
		racing := paxos.proposal_frontier(&c.nodes[0])
		c.drop = Seal_Target{slot = racing + 1, to = 2}
		c.duplicate = Seal_Target{slot = racing + 1, to = 3}
		seal_append(&c, 0, 12)
		stop_slot := seal_reconfigure(&c, 0, 2, members[:])
		testing.expect_value(t, stop_slot, racing + 1)
		seal_settle(&c)
		testing.expect_value(t, c.dropped, 1)
		testing.expect_value(t, c.duplicated, 1)
		stop, agreed_slot := seal_expect_agreement(&c, members[:])
		testing.expect_value(t, agreed_slot, stop_slot)
		seal_expect_nothing_after(&c, members[:], stop_slot)
		seal_expect_replay_keeps_seal(&c, members[:], 1, stop_slot)
		seal_expect_next_epoch_decides(&c, stop, stop_slot, 1)
	}
}

@(test)
reconfiguration_sim_membership_handover_reaches_new_configuration :: proc(t: ^testing.T) {
	old_members := [3]paxos.Node_Id{1, 2, 3}
	new_members := [3]paxos.Node_Id{2, 3, 4}
	for seed in 1..=SEAL_SEEDS {
		c: Seal_Cluster
		defer seal_destroy(&c)
		seal_init(t, &c, u64(seed), old_members[:], 1)
		seal_elect(&c, 0)
		seal_append(&c, 0, 21)
		stop_slot := seal_reconfigure(&c, 0, 2, new_members[:])
		seal_settle(&c)
		stop, _ := seal_expect_agreement(&c, old_members[:])
		seal_expect_nothing_after(&c, old_members[:], stop_slot)
		seal_expect_replay_keeps_seal(&c, old_members[:], 1, stop_slot)
		// The removed voter is refused by the next configuration.
		anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = stop_slot}
		removed: Seal_Log
		removed_err := paxos.log_init_from_stop(&removed, 1, stop, stop_slot, anchor)
		testing.expect_value(t, removed_err, paxos.Error.Not_Member)
		seal_expect_next_epoch_decides(&c, stop, stop_slot, 2)
	}
}

@(test)
reconfiguration_sim_one_for_one_voter_replacement :: proc(t: ^testing.T) {
	old_members := [3]paxos.Node_Id{1, 2, 3}
	new_members := [3]paxos.Node_Id{1, 2, 4}
	for seed in 1..=SEAL_SEEDS {
		c: Seal_Cluster
		defer seal_destroy(&c)
		seal_init(t, &c, u64(seed), old_members[:], 7)
		seal_elect(&c, 2)
		seal_append(&c, 2, 41)
		seal_append(&c, 2, 42)
		stop_slot := seal_reconfigure(&c, 2, 8, new_members[:])
		seal_settle(&c)
		stop, _ := seal_expect_agreement(&c, old_members[:])
		seal_expect_nothing_after(&c, old_members[:], stop_slot)
		anchor := paxos.Trim_Anchor{trim_id = 1, chosen_trim_slot = stop_slot}
		removed: Seal_Log
		removed_err := paxos.log_init_from_stop(&removed, 3, stop, stop_slot, anchor)
		testing.expect_value(t, removed_err, paxos.Error.Not_Member)
		seal_expect_next_epoch_decides(&c, stop, stop_slot, 1)
	}
}

// Under rotating ownership an owner seals in its own slot while the other owners, not yet
// aware of the seal, get suggestions decided above it. Those decisions are abandoned:
// never released, invisible to reads, and re-decided by the next configuration.
@(test)
reconfiguration_sim_ownership_abandons_decisions_above_the_seal :: proc(t: ^testing.T) {
	members := [3]paxos.Node_Id{1, 2, 3}
	for seed in 1..=SEAL_SEEDS {
		c: Seal_Cluster
		defer seal_destroy(&c)
		seal_init(t, &c, u64(seed), members[:], 1, paxos.Node_Options{rotating_ownership = true})
		testing.expect_value(t, seal_append(&c, 0, 11), paxos.Slot(1))
		seal_settle(&c)
		stop_slot := seal_reconfigure(&c, 1, 2, members[:])
		testing.expect_value(t, stop_slot, paxos.Slot(2))
		// Owners 3 and 1 suggest above the seal before any decision on it reaches them.
		testing.expect_value(t, seal_append(&c, 2, 13), paxos.Slot(3))
		testing.expect_value(t, seal_append(&c, 0, 14), paxos.Slot(4))
		seal_settle(&c)
		stop, agreed_slot := seal_expect_agreement(&c, members[:])
		testing.expect_value(t, agreed_slot, stop_slot)
		decided_above := 0
		for id in members {
			node := &c.nodes[id - 1]
			// The old configuration really did decide slot 3; the log hides it.
			if _, chosen := paxos.ledger_chosen_at(paxos.ledger(node), 3); chosen do decided_above += 1
			testing.expect_value(t, paxos.decided_through(node), stop_slot)
			_, visible := paxos.committed_at(node, 3)
			testing.expect(t, !visible, "an abandoned decision must not be readable")
			buffer: [4]paxos.Committed(Seal_Entry)
			count, err := paxos.read_decided(node, 1, buffer[:])
			expect_ok(t, err)
			testing.expect_value(t, count, 2)
		}
		testing.expect(t, decided_above > 0, "the scenario must reach a decision above the seal")
		seal_expect_nothing_after(&c, members[:], stop_slot)
		seal_expect_replay_keeps_seal(&c, members[:], 1, stop_slot)
		seal_expect_next_epoch_decides(&c, stop, stop_slot, 1)
	}
}
