package paxos

// Phase one: a candidate promises itself a ballot, asks every acceptor to promise it for
// one chunk of decrees at a time, and re-proposes the greatest vote each decree received
// (Lamport's B3). Holes are filled with the host's no-op so the log stays contiguous.

@(private)
broadcast_peers :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
	msg: Message(V),
) {
	for peer in membership_slice(&node.membership) {
		if peer == node.id do continue
		effects_add_message(effects, Envelope(V){from = node.id, to = peer, message = msg})
	}
}

@(private)
broadcast_all :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
	msg: Message(V),
) {
	for peer in membership_slice(&node.membership) {
		effects_add_message(effects, Envelope(V){from = node.id, to = peer, message = msg})
	}
}

@(private)
send_to :: #force_inline proc(
	node: ^Node($V, $M, $W, $C, $G),
	peer: Node_Id,
	effects: ^Effects(V, M, W, C, G),
	msg: Message(V),
) {
	effects_add_message(effects, Envelope(V){from = node.id, to = peer, message = msg})
}

@(private)
send_nack :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	to: Node_Id,
	rejected, promised: Ballot,
	slot: Slot,
	effects: ^Effects(V, M, W, C, G),
) {
	send_to(node, to, effects, Nack_Message{
		rejected = rejected, promised = promised, slot = slot, decided_through = node.delivered_through,
	})
}

@(private)
observe_leader :: proc(node: ^Node($V, $M, $W, $C, $G), from: Node_Id, ballot: Ballot) {
	node.leader_hint = from
	node.election_ticks = 0
	node.highest_observed_round = max(node.highest_observed_round, ballot_round(ballot))
	if node.ballot != ballot do node.role = .Follower
}

@(private)
chunk_limit :: #force_inline proc(node: ^Node($V, $M, $W, $C, $G)) -> Slot {
	return node.recover_last
}

// Payloads need no clearing: state and absolute slot tags establish validity.
@(private)
reset_recovery_chunk :: proc(node: ^Node($V, $M, $W, $C, $G)) {
	node.promise_seen = {}
	node.recovered_slot = {}
	node.recovered_ballot = {}
	node.recovered_state = {}
}

// Check before subtracting or converting; chunks need not be powers of two.
@(private)
recovery_index :: #force_inline proc(
	node: ^Node($V, $M, $W, $C, $G), slot: Slot,
) -> (int, bool) {
	if slot < node.recover_base || slot > node.recover_last do return 0, false
	offset := slot - node.recover_base
	if offset >= Slot(C) do return 0, false
	return int(offset), true
}

@(private)
highest_recovered_slot :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Slot {
	highest := ledger_highest_used(&node.ledger)
	for cell in 0..<C {
		if node.recovered_state[cell] != .Empty {
			highest = max(highest, node.recovered_slot[cell])
		}
	}
	return highest
}

// The slots a new leader may not touch: everything at or below the greatest trim anchor
// and the greatest decided prefix any quorum member reported.
Fences :: struct {
	trim:        Slot,
	chosen:      Slot,
	chosen_peer: Maybe(Node_Id),
}

@(private)
quorum_fences :: proc(node: ^Node($V, $M, $W, $C, $G)) -> (fences: Fences) {
	fences.trim = node.ledger.anchor.chosen_trim_slot
	fences.chosen = node.delivered_through
	for i in 0..<membership_count(&node.membership) {
		peer := &node.election[i]
		fences.trim = max(fences.trim, peer.anchor.chosen_trim_slot)
		if peer.chosen_through > fences.chosen {
			fences.chosen = peer.chosen_through
			fences.chosen_peer = membership_get(&node.membership, i)
		}
	}
	return
}

// ---------------------------------------------------------------------------------
// Campaign
// ---------------------------------------------------------------------------------

node_campaign :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if !node.voting_member do return .Not_Voter
	if !node.campaign_enabled || node.ownership do return .Campaign_Disabled
	return start_campaign(node, noop, effects)
}

@(private)
start_campaign :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if node.delivered_through == max(Slot) do return .Global_Slot_Exhausted
	// Lamport: lastTried must exceed every ballot this priest has seen, including the
	// per-decree promises and votes still in its ledger.
	greatest := max(node.highest_observed_round, ballot_round(node.ballot))
	greatest = max(greatest, ballot_round(ledger_highest_ballot(&node.ledger)))
	if greatest >= MAX_ROUND do return .Ballot_Exhausted

	node.ballot = ballot_make(greatest + 1, node.priority, node.id)
	node.role = .Preparing
	node.leader_hint = nil
	node.noop = noop
	node.election_ticks = 0
	clear_election(node)
	node.recover_base = node.delivered_through + 1
	node.recover_last = slot_add(node.recover_base, Slot(C - 1))
	// The candidate is its own first acceptor: its promise is in this batch, so it is
	// durable before any Prepare leaves. A restart therefore always finds this ballot
	// in the ledger and campaigns above it, even if the first accepts left before the
	// barrier and no vote of its own was ever written.
	node.ledger.promised = node.ballot
	effects_add_write(effects, Write_Promise{node.ballot})
	broadcast_all(node, effects, Prepare_Message{
		ballot = node.ballot, first = node.recover_base, last = node.recover_last,
	})
	return .None
}

// An acceptor answers a prepare: it promises the ballot (durably, before replying),
// reports every vote or decision it holds in the chunk, then closes with a manifest.
@(private)
on_prepare :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Prepare_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	l := &node.ledger
	if msg.ballot < l.promised {
		send_nack(node, from, msg.ballot, l.promised, 0, effects)
		return .None
	}
	if msg.first == 0 || msg.last < msg.first do return .Invalid_Slot
	switch msg.scope {
	case .Global:
		if msg.ballot != l.promised {
			l.promised = msg.ballot
			effects_add_write(effects, Write_Promise{msg.ballot})
		}
		observe_leader(node, from, msg.ballot)
	case .Bounded:
		if !promise_bounded(node, msg, effects) do return .None
		node.highest_observed_round = max(node.highest_observed_round, ballot_round(msg.ballot))
	}

	reported: u32
	more := false
	cell, used := bit_set_next(l.used, 0)
	for used {
		slot := l.slot[cell]
		if slot > l.anchor.chosen_trim_slot && slot >= msg.first {
			if slot > msg.last {
				more = true
			} else {
				reported += 1
				send_to(node, from, effects, Promise_Message(V){
					ballot = msg.ballot, slot = slot, vote = l.vote_ballot[cell],
					state = l.state[cell], value = &l.value[cell],
				})
			}
		}
		cell, used = bit_set_next(l.used, cell + 1)
	}
	send_to(node, from, effects, Promise_Range_Message{
		ballot = msg.ballot, anchor = l.anchor, chosen_through = node.delivered_through,
		first = msg.first, last = msg.last, reported = reported, more = more,
	})
	return .None
}

// Promises every decree in [first, last] individually. Fails closed (no reply at all)
// when a slot in the range has no cell to carry its promise, so a candidate never counts
// a promise that was not recorded.
@(private)
promise_bounded :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	msg: Prepare_Message,
	effects: ^Effects(V, M, W, C, G),
) -> bool {
	l := &node.ledger
	if msg.last - msg.first >= Slot(C) do return false
	for offset in 0..=msg.last - msg.first {
		slot := msg.first + offset
		if slot <= node.memory_floor do continue
		cell, ok := claim_live(node, slot)
		if !ok || msg.ballot < l.promised_at[cell] do return false
	}
	for offset in 0..=msg.last - msg.first {
		slot := msg.first + offset
		if slot <= node.memory_floor do continue
		cell := cell_of(slot, W)
		if l.promised_at[cell] == msg.ballot do continue
		l.promised_at[cell] = msg.ballot
		effects_add_write(effects, Write_Promise_At{ballot = msg.ballot, slot = slot})
	}
	return true
}

// The candidate keeps, per decree, the greatest vote any acceptor reported; a reported
// decision dominates every vote.
@(private)
on_promise :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	member: int,
	msg: Promise_Message(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if node.role != .Preparing || msg.ballot != node.ballot do return .None
	cell, in_chunk := recovery_index(node, msg.slot)
	if !in_chunk do return .None
	if msg.state == .Empty do return .Invalid_Promise

	if bit_set_insert(&node.promise_seen[member], cell) {
		node.election[member].received_in_range += 1
	}

	if node.recovered_slot[cell] != msg.slot {
		node.recovered_slot[cell] = msg.slot
		node.recovered_state[cell] = .Empty
	}
	reported := msg.value^
	switch node.recovered_state[cell] {
	case .Empty:
		node.recovered_state[cell] = msg.state
		node.recovered_ballot[cell] = msg.vote
		node.recovered_value[cell] = reported
	case .Chosen:
		// An acceptor outside the deciding quorum may still hold an older, losing vote;
		// only another decision can contradict a decision.
		if msg.state == .Chosen && node.recovered_value[cell] != reported do return .Conflicting_Commit
	case .Voted:
		if msg.state == .Chosen {
			node.recovered_state[cell] = .Chosen
			node.recovered_value[cell] = reported
		} else if msg.vote == node.recovered_ballot[cell] {
			if node.recovered_value[cell] != reported do return .Conflicting_Value
		} else if msg.vote > node.recovered_ballot[cell] {
			node.recovered_ballot[cell] = msg.vote
			node.recovered_value[cell] = reported
		}
	}
	return maybe_resolve_chunk(node, effects)
}

@(private)
on_promise_range :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	member: int,
	msg: Promise_Range_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if node.role != .Preparing || msg.ballot != node.ballot do return .None
	if msg.reported > u32(C) || msg.last < msg.first do return .Invalid_Promise
	if msg.first == node.recover_base && msg.last != chunk_limit(node) do return .Invalid_Promise

	peer := &node.election[member]
	if msg.anchor.chosen_trim_slot > peer.anchor.chosen_trim_slot do peer.anchor = msg.anchor
	peer.chosen_through = max(peer.chosen_through, msg.chosen_through)
	if msg.first != node.recover_base do return .None
	peer.range_first, peer.range_last = msg.first, msg.last
	peer.expected_in_range = msg.reported
	peer.range_described = true
	peer.more = msg.more
	return maybe_resolve_chunk(node, effects)
}

// Once a read quorum has fully described the chunk, resolve it; then either move to the
// next chunk or become leader.
@(private)
maybe_resolve_chunk :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	complete := 0
	any_more := false
	for i in 0..<membership_count(&node.membership) {
		peer := &node.election[i]
		if !peer.range_described || peer.received_in_range < peer.expected_in_range do continue
		complete += 1
		if peer.more do any_more = true
	}
	if complete < membership_read_quorum(&node.membership) do return .None
	if node.noop == nil do return .Missing_Noop

	resolved := resolve_chunk(node, any_more, effects) or_return
	if !resolved do return .None
	if any_more {
		if chunk_limit(node) == max(Slot) do return .Global_Slot_Exhausted
		begin_next_chunk(node, effects)
		return .None
	}
	become_leader(node, effects)
	return .None
}

// Drives every decree of the chunk above the fences: rebroadcast a known decision,
// re-propose the greatest recovered vote, or propose the no-op for a hole. Returns false
// when the window bounded the drive and a tick must retry.
@(private)
resolve_chunk :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	any_more: bool,
	effects: ^Effects(V, M, W, C, G),
) -> (resolved: bool, err: Error) {
	fences := quorum_fences(node)
	fence := max(fences.trim, fences.chosen)
	if fence == max(Slot) do return false, .Global_Slot_Exhausted
	slot := max(node.recover_base, fence + 1)
	known_high := max(highest_recovered_slot(node), fence)
	// A revocation decides every promised decree so no owner is fenced out of a slot forever.
	drive_all := any_more || node.ownership
	limit := chunk_limit(node) if drive_all else min(chunk_limit(node), known_high)
	drive_limit := min(limit, slot_add(node.memory_floor, Slot(W)))

	for slot <= drive_limit {
		if slot == max(Slot) do return false, .Global_Slot_Exhausted
		cell, in_chunk := recovery_index(node, slot)
		assert(in_chunk, "Recovery slot outside chunk. Hint: Report this invariant failure.")
		if chosen, is_chosen := ledger_chosen_at(&node.ledger, slot); is_chosen {
			broadcast_peers(node, effects, Commit_Message(V){slot = slot, value = chosen})
		} else if node.recovered_slot[cell] == slot && node.recovered_state[cell] == .Chosen {
			record_commit(node, slot, node.recovered_value[cell], effects) or_return
			if decided, ok := ledger_chosen_at(&node.ledger, slot); ok {
				broadcast_peers(node, effects, Commit_Message(V){slot = slot, value = decided})
			}
		} else {
			value := node.noop.?
			if node.recovered_slot[cell] == slot && node.recovered_state[cell] == .Voted {
				value = node.recovered_value[cell]
			}
			accept_err := send_accept(node, slot, node.ballot, value, effects)
			if accept_err == .Not_Leader {
				// A higher ballot already holds this decree: this candidate lost. Step down
				// quietly; the winner (or the next timeout) finishes the range.
				node.role = .Follower
				return false, .None
			}
			accept_err or_return
		}
		slot += 1
	}
	if fences.chosen > node.delivered_through {
		if peer, ok := fences.chosen_peer.?; ok {
			request_learn(node, peer, effects)
		}
	}
	return drive_limit >= limit, .None
}

@(private)
begin_next_chunk :: proc(node: ^Node($V, $M, $W, $C, $G), effects: ^Effects(V, M, W, C, G)) {
	node.recover_base = chunk_limit(node) + 1
	node.recover_last = slot_add(node.recover_base, Slot(C - 1))
	if node.ownership {
		node.recover_last = min(node.recover_last, max(node.highest_seen, node.recover_base))
	}
	reset_recovery_chunk(node)
	for i in 0..<membership_count(&node.membership) {
		peer := &node.election[i]
		peer^ = Election_Peer{anchor = peer.anchor, chosen_through = peer.chosen_through}
	}
	broadcast_all(node, effects, Prepare_Message{
		ballot = node.ballot, first = node.recover_base, last = node.recover_last,
		scope = .Bounded if node.ownership else .Global,
	})
}

@(private)
become_leader :: proc(node: ^Node($V, $M, $W, $C, $G), effects: ^Effects(V, M, W, C, G)) {
	if node.ownership {
		// A revocation ends when its chunk is driven; there is no standing leader.
		node.role = .Follower
		node.stall_ticks = 0
		emit_contiguous(node, effects)
		return
	}
	node.role = .Leader
	node.leader_hint = node.id
	fences := quorum_fences(node)
	highest := max(ledger_highest_used(&node.ledger), fences.trim, fences.chosen)
	node.next_slot = max(node.next_slot, slot_add(highest, 1))
	node.leader_base = node.next_slot
	emit_contiguous(node, effects)
}
