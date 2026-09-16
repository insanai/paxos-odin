package paxos

import "core:container/small_array"

// Rotating slot ownership (after Mao, Junqueira, and Marzullo's Mencius).
//
// The slot line is dealt round-robin: member i (in membership order) owns every slot s
// with (s - 1) mod N == i. The ballot space of each slot is partitioned so B1 still
// holds per decree: round 0 belongs to the owner alone (its ballot is
// ballot_make(0, 0, owner)), and rounds 1 and above belong to anyone. An owner therefore
// proposes in its own slot with no phase one at all, because no lower ballot exists in
// that decree; the Synod proof applies unchanged.
//
// Three rules keep the log contiguous and live:
//   - Skip: an owner with nothing to propose fills its own slots below the highest slot
//     it has seen with the no-op, so the log never waits on an idle owner.
//   - Revoke: when the decided prefix stalls, a member runs a bounded phase one over the
//     stalled chunk at a round above zero. Per-decree promises fence the owner out of
//     those slots only; the revoker re-proposes any vote it finds (B3) or the no-op.
//   - Resubmit: an owner whose suggestion was revoked to the no-op proposes the value
//     again in its next own slot. Nothing a client handed in is silently lost.

// The member that owns `slot`.
owner_of :: #force_inline proc(node: ^Node($V, $M, $W, $C, $G), slot: Slot) -> Node_Id {
	count := Slot(membership_count(&node.membership))
	return membership_get(&node.membership, int((slot - 1) % count))
}

// The ballot an owner proposes with: round zero, which no campaign ever uses.
ownership_ballot :: #force_inline proc(owner: Node_Id) -> Ballot {
	return ballot_make(0, 0, owner)
}

// The first slot at or after `from` that this node owns.
@(private)
own_slot_from :: proc(node: ^Node($V, $M, $W, $C, $G), from: Slot) -> Slot {
	count := Slot(membership_count(&node.membership))
	mine := Slot(node.self_index) + 1
	if from <= mine do return mine
	offset := (from - mine) % count
	return from if offset == 0 else from + (count - offset)
}

// The next own slot this node may still suggest in: one that is neither decided nor
// revoked (promised above round zero). Revoked or decided own slots are stepped over.
@(private)
next_usable_own_slot :: proc(node: ^Node($V, $M, $W, $C, $G)) -> (Slot, Error) {
	l := &node.ledger
	mine := ownership_ballot(node.id)
	for {
		slot := node.own_next
		if slot == max(Slot) do return 0, .Global_Slot_Exhausted
		if slot <= node.memory_floor {
			// The host consumed past our next slot (its decisions arrived as commits).
			node.own_next = own_slot_from(node, node.memory_floor + 1)
			continue
		}
		if slot - node.memory_floor > Slot(W) do return 0, .Window_Full
		cell := cell_of(slot, W)
		occupant := l.slot[cell]
		switch {
		case occupant == slot:
			if l.state[cell] != .Chosen && ledger_promise_for(l, cell) <= mine do return slot, .None
		case occupant == 0 || (occupant <= node.memory_floor && l.state[cell] == .Chosen):
			return slot, .None
		case:
			// The cell still holds an older open slot; wait for the host to release it.
			return 0, .Window_Full
		}
		node.own_next = own_slot_from(node, slot + 1)
	}
}

// How many consecutive own slots fit in the window from the next usable one.
@(private)
own_slots_available :: proc(node: ^Node($V, $M, $W, $C, $G), wanted: int) -> bool {
	count := Slot(membership_count(&node.membership))
	last := node.own_next + Slot(wanted - 1) * count
	return last >= node.own_next && last - node.memory_floor <= Slot(W)
}

// Proposes `value` in this node's next usable own slot.
@(private)
propose_owned :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> (slot: Slot, err: Error) {
	slot = next_usable_own_slot(node) or_return
	send_accept(node, slot, ownership_ballot(node.id), value, effects) or_return
	node.own_next = own_slot_from(node, slot + 1)
	node.highest_seen = max(node.highest_seen, slot)
	return slot, .None
}

// At most this many skips leave per tick, so an idle owner catching up does not flood.
SKIP_BURST :: 8

// Skips: no-ops in this node's own slots below the highest slot anyone has reached, at
// most `budget` (and never more than SKIP_BURST) per tick.
@(private)
skip_idle_slots :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	budget: int,
	effects: ^Effects(V, M, W, C, G),
) -> (sent: int, err: Error) {
	for node.own_next <= node.highest_seen && sent < min(budget, SKIP_BURST) {
		_, propose_err := propose_owned(node, noop, effects)
		if propose_err == .Window_Full do break
		if propose_err != .None do return sent, propose_err
		sent += 1
	}
	return sent, .None
}

// Revocation: a bounded phase one over the stalled chunk. The candidate keeps its role
// only until the chunk is resolved; ownership has no standing leader.
@(private)
start_revocation :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	greatest := max(node.highest_observed_round, ballot_round(node.ballot))
	greatest = max(greatest, ballot_round(ledger_highest_ballot(&node.ledger)))
	if greatest >= MAX_ROUND do return .Ballot_Exhausted
	base := node.delivered_through + 1
	chunk_end := slot_add(base, Slot(C - 1))
	last := min(chunk_end, max(node.highest_seen, base), node.memory_floor + Slot(W))
	prepare := Prepare_Message{
		ballot = ballot_make(greatest + 1, node.priority, node.id),
		first = base, last = last, scope = .Bounded,
	}
	// The revoker promises itself first, so its ballot is durable before the Prepare
	// leaves and a restart campaigns above it (the same rule as start_campaign). If a
	// cell of the range is still held by an older open slot, nothing has changed yet:
	// the node stays a follower and tries again after the next timeout.
	if !promise_bounded(node, prepare, effects) {
		node.stall_ticks = 0
		return .None
	}
	node.ballot = prepare.ballot
	node.role = .Preparing
	node.noop = noop
	node.election_ticks = 0
	node.stall_ticks = 0
	clear_election(node)
	node.recover_base = base
	node.recover_last = last
	broadcast_all(node, effects, prepare)
	return .None
}

// A suggestion revoked to another value is proposed again in a later own slot.
@(private)
queue_resubmit :: proc(node: ^Node($V, $M, $W, $C, $G), value: V) {
	if !small_array.push_back(&node.resubmit, value) {
		// The queue is bounded by one chunk; a burst beyond it is re-proposed by the host
		// through the ordinary timeout-and-retry discipline.
		return
	}
}

@(private)
drain_resubmits :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) -> (sent: int, err: Error) {
	for small_array.len(node.resubmit) > 0 {
		value := small_array.get(node.resubmit, 0)
		_, propose_err := propose_owned(node, value, effects)
		if propose_err == .Window_Full do return sent, .None
		if propose_err != .None do return sent, propose_err
		small_array.ordered_remove(&node.resubmit, 0)
		sent += 1
	}
	return sent, .None
}

// The ownership side of a tick: skips, retransmission, catch-up, and stall detection.
@(private)
tick_ownership :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if node.role == .Preparing {
		if node.election_ticks < node.election_timeout_ticks do return maybe_resolve_chunk(node, effects)
		return start_revocation(node, noop, effects)
	}
	// One tick proposes at most C values (resubmits first, then skips), so the batch
	// stays within the Effects capacities; retransmission waits for a quiet tick.
	proposed := drain_resubmits(node, effects) or_return
	skipped := skip_idle_slots(node, noop, C - proposed, effects) or_return
	proposed += skipped
	if proposed == 0 && node.resend_ticks >= node.resend_interval_ticks {
		node.resend_ticks = 0
		for peer in membership_slice(&node.membership) {
			if peer != node.id do resend_to(node, peer, effects)
		}
	}
	if node.delivered_through >= node.highest_seen {
		node.stall_ticks = 0
		return .None
	}
	node.stall_ticks = saturating_increment(node.stall_ticks)
	if node.stall_ticks >= node.election_timeout_ticks do return start_revocation(node, noop, effects)
	// Ask the owner of the stuck slot for what it knows before suspecting it.
	if node.stall_ticks % node.heartbeat_interval_ticks == 0 {
		owner := owner_of(node, node.delivered_through + 1)
		if owner != node.id do request_learn(node, owner, effects)
	}
	return .None
}
