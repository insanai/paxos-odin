package paxos

// Phase two and everything that keeps the log moving: proposals, votes, decisions,
// heartbeats, catch-up, retransmission, and the single dispatch point for messages.

// Claims the live cell for `slot`. The live window is (memory_floor, memory_floor + W]:
// below it the host has consumed the slot, above it the cell of `slot` still belongs to
// an earlier slot, so cells and live slots stay in bijection. Within it a cell may be
// reused only when the host has released its previous slot and that slot is decided.
@(private)
claim_live :: #force_inline proc(node: ^Node($V, $M, $W, $C, $G), slot: Slot) -> (int, bool) {
	if slot <= node.memory_floor || slot - node.memory_floor > Slot(W) do return 0, false
	l := &node.ledger
	cell := cell_of(slot, W)
	held := l.slot[cell]
	if held == slot do return cell, true
	if held == 0 || (held <= node.memory_floor && l.state[cell] == .Chosen) {
		ledger_open(l, cell, slot)
		return cell, true
	}
	return cell, false
}

// Releases every newly contiguous decision to the host.
@(private)
emit_contiguous :: proc(node: ^Node($V, $M, $W, $C, $G), effects: ^Effects(V, M, W, C, G)) {
	l := &node.ledger
	for node.delivered_through < max(Slot) {
		next := node.delivered_through + 1
		cell := cell_of(next, W)
		if l.slot[cell] != next || l.state[cell] != .Chosen do break
		effects_add_committed(effects, Committed(V){slot = next, value = &l.value[cell]})
		node.delivered_through = next
	}
}

// The leader votes for its own proposal first (durably), then asks the peers.
@(private)
send_accept :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	slot: Slot,
	ballot: Ballot,
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	l := &node.ledger
	cell, ok := claim_live(node, slot)
	if !ok do return .Window_Overrun
	// A decided cell keeps its decision; the caller's proposal is simply not needed.
	if l.state[cell] == .Chosen do return .None
	driving := node.lead_slot[cell] == slot && l.state[cell] == .Voted
	if driving && l.vote_ballot[cell] == ballot && l.value[cell] != value do return .Conflicting_Value
	if ballot < ledger_promise_for(l, cell) do return .Not_Leader
	node.lead_slot[cell] = slot
	node.lead_ballot[cell] = ballot
	node.acknowledgements[cell] = {}
	node.acknowledged[cell] = 0

	l.promised_at[cell] = max(l.promised_at[cell], ballot)
	ledger_record_vote(l, cell, ballot, value)
	effects_add_write(effects, Write_Vote(V){ballot = ballot, slot = slot, value = &l.value[cell]})

	if bit_set_insert(&node.acknowledgements[cell], node.self_index) do node.acknowledged[cell] += 1
	if membership_write_quorum(&node.membership) == 1 {
		record_commit(node, slot, value, effects) or_return
	}
	broadcast_peers(node, effects, Accept_Message(V){ballot = ballot, slot = slot, value = &l.value[cell]})
	return .None
}

// An acceptor votes when the ballot is at least its promise for that decree. A decided
// cell never votes again; the sender is told the decision instead.
@(private)
on_accept :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Accept_Message(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.slot == 0 do return .Invalid_Slot
	l := &node.ledger
	if msg.slot <= l.anchor.chosen_trim_slot do return .None
	// Round zero belongs to the slot's owner alone (B1 per decree under rotating ownership).
	if ballot_round(msg.ballot) == 0 {
		if !node.ownership || ballot_node(msg.ballot) != owner_of(node, msg.slot) do return .None
	}
	if msg.ballot < l.promised {
		send_nack(node, from, msg.ballot, l.promised, msg.slot, effects)
		return .None
	}
	cell, ok := claim_live(node, msg.slot)
	if !ok do return .None
	node.highest_seen = max(node.highest_seen, msg.slot)
	if msg.ballot < l.promised_at[cell] {
		send_nack(node, from, msg.ballot, l.promised_at[cell], msg.slot, effects)
		return .None
	}
	value := msg.value^
	acknowledgement := Accepted_Message{
		ballot = msg.ballot, slot = msg.slot,
		decided_through = node.delivered_through,
	}
	switch l.state[cell] {
	case .Chosen:
		if l.value[cell] == value {
			send_to(node, from, effects, acknowledgement)
		} else {
			decided := Commit_Message(V){slot = msg.slot, value = &l.value[cell]}
			send_to(node, from, effects, decided)
		}
		return .None
	case .Voted:
		if l.vote_ballot[cell] == msg.ballot {
			if l.value[cell] != value do return .Conflicting_Value
			send_to(node, from, effects, acknowledgement)
			return .None
		}
		// An owner whose own suggestion is being overwritten by a revoker's value proposes
		// it again in a later own slot (at least once: the slot may still decide it). The
		// vote's ballot identifies the suggestion; the lead columns may have been cleared
		// by a revocation this owner started itself.
		if node.ownership && l.vote_ballot[cell] == ownership_ballot(node.id) &&
		   l.value[cell] != value {
			queue_resubmit(node, l.value[cell])
		}
	case .Empty:
	}
	l.promised_at[cell] = msg.ballot
	ledger_record_vote(l, cell, msg.ballot, value)
	// An owner's suggestion says nothing about leadership; only a campaign ballot does.
	if ballot_round(msg.ballot) > 0 do observe_leader(node, from, msg.ballot)
	effects_add_write(effects, Write_Vote(V){
		ballot = msg.ballot, slot = msg.slot, value = &l.value[cell],
	})
	send_to(node, from, effects, acknowledgement)
	return .None
}

// The leader counts distinct voters; at a write quorum the decree is chosen.
@(private)
on_accepted :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	member: int,
	msg: Accepted_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.slot == 0 do return .Invalid_Slot
	cell := cell_of(msg.slot, W)
	if node.lead_slot[cell] != msg.slot || node.lead_ballot[cell] != msg.ballot do return .None
	if bit_set_insert(&node.acknowledgements[cell], member) do node.acknowledged[cell] += 1
	if int(node.acknowledged[cell]) < membership_write_quorum(&node.membership) do return .None

	l := &node.ledger
	// A late acknowledgement for a slot whose cell has moved on, or whose vote a higher
	// ballot replaced, is stale, not an error.
	if l.slot[cell] != msg.slot || l.state[cell] == .Chosen do return .None
	if l.state[cell] == .Voted && l.vote_ballot[cell] != msg.ballot do return .None
	if l.state[cell] != .Voted do return .Missing_Proposed_Value
	record_commit(node, msg.slot, l.value[cell], effects) or_return
	broadcast_peers(node, effects, Commit_Message(V){slot = msg.slot, value = &l.value[cell]})
	return .None
}

@(private)
on_commit :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Commit_Message(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	node.leader_hint = from
	node.election_ticks = 0
	return record_commit(node, msg.slot, msg.value^, effects)
}

// Records a decision. A decision for the slot just past the window edge is released
// straight to the host (through `pass_through`) so one transition can free the window.
@(private)
record_commit :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	slot: Slot,
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if slot == 0 do return .Invalid_Slot
	l := &node.ledger
	node.highest_seen = max(node.highest_seen, slot)
	if slot <= node.memory_floor || slot <= l.anchor.chosen_trim_slot do return .None
	cell, ok := claim_live(node, slot)
	if !ok {
		// One pass-through per transition: the record and the entry both point at
		// `pass_through`, so a second in the same batch would overwrite the first.
		released := effects_committed_slice(effects)
		if len(released) > 0 && released[len(released) - 1].value == &node.pass_through {
			return .None
		}
		if slot == node.delivered_through + 1 {
			node.pass_through = value
			effects_add_write(effects, Write_Chosen(V){slot = slot, value = &node.pass_through})
			effects_add_committed(effects, Committed(V){slot = slot, value = &node.pass_through})
			node.delivered_through = slot
			emit_contiguous(node, effects)
		}
		return .None
	}
	if l.state[cell] == .Chosen {
		if l.value[cell] != value do return .Conflicting_Commit
		emit_contiguous(node, effects)
		return .None
	}
	// An owner whose suggestion lost to a revocation proposes it again later.
	if node.ownership && l.state[cell] == .Voted &&
	   l.vote_ballot[cell] == ownership_ballot(node.id) && l.value[cell] != value {
		queue_resubmit(node, l.value[cell])
	}
	ledger_record_chosen(l, cell, value)
	effects_add_write(effects, Write_Chosen(V){slot = slot, value = &l.value[cell]})
	emit_contiguous(node, effects)
	return .None
}

@(private)
on_heartbeat :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Heartbeat_Message,
	effects: ^Effects(V, M, W, C, G),
) {
	l := &node.ledger
	if msg.ballot < l.promised {
		send_nack(node, from, msg.ballot, l.promised, 0, effects)
		return
	}
	// A heartbeat above the promise means this node missed the leader's prepare.
	// Promising is always safe, and it stops a needless election.
	if msg.ballot != l.promised {
		l.promised = msg.ballot
		effects_add_write(effects, Write_Promise{msg.ballot})
	}
	observe_leader(node, from, msg.ballot)
	if msg.decided_through > node.delivered_through do request_learn(node, from, effects)
}

@(private)
request_learn :: proc(node: ^Node($V, $M, $W, $C, $G), peer: Node_Id, effects: ^Effects(V, M, W, C, G)) {
	send_to(node, peer, effects, Learn_Message{from_slot = node.delivered_through + 1, count = u32(C)})
}

// Answers a catch-up request with the decisions still resident, and asks the host for
// anything below the memory floor.
@(private)
on_learn :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from: Node_Id,
	msg: Learn_Message,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	if msg.from_slot == 0 || msg.count == 0 || msg.count > u32(C) do return .Invalid_Slot
	limit := slot_add(msg.from_slot, Slot(msg.count - 1))
	if msg.from_slot <= node.memory_floor {
		served_through := min(limit, node.memory_floor)
		effects_add_request(effects, Serve_Range_Request{
			peer = from, first = msg.from_slot, count = u32(served_through - msg.from_slot + 1),
		})
	}
	l := &node.ledger
	cell, chosen := bit_set_next(l.chosen, 0)
	for chosen {
		slot := l.slot[cell]
		if slot >= msg.from_slot && slot <= limit {
			send_to(node, from, effects, Commit_Message(V){slot = slot, value = &l.value[cell]})
		}
		cell, chosen = bit_set_next(l.chosen, cell + 1)
	}
	return .None
}

@(private)
on_nack :: proc(node: ^Node($V, $M, $W, $C, $G), msg: Nack_Message) {
	node.highest_observed_round = max(node.highest_observed_round, ballot_round(msg.promised))
	if msg.rejected != node.ballot || msg.promised <= node.ballot do return
	node.role = .Follower
	node.election_ticks = 0
	node.leader_hint = ballot_node(msg.promised)
	node.highest_observed_round = max(node.highest_observed_round, ballot_round(msg.promised))
}

// ---------------------------------------------------------------------------------
// Proposals
// ---------------------------------------------------------------------------------

@(private)
proposal_gate :: proc(node: ^Node($V, $M, $W, $C, $G)) -> Error {
	if !node.voting_member do return .Not_Voter
	if node.ownership do return .None
	if node.role != .Leader do return .Not_Leader
	if node.gate_proposals_on_inherited_prefix && node.delivered_through < node.leader_base - 1 {
		return .Leader_Catching_Up
	}
	return .None
}

// Proposes one value in the next slot; the leader's own vote is written before any
// Accept leaves.
node_propose :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> (slot: Slot, err: Error) {
	effects_reset(effects)
	proposal_gate(node) or_return
	if node.ownership do return propose_owned(node, value, effects)
	if node.next_slot == max(Slot) do return 0, .Global_Slot_Exhausted
	if node.next_slot - node.memory_floor > Slot(W) do return 0, .Window_Full
	slot = node.next_slot
	node.next_slot += 1
	send_accept(node, slot, node.ballot, value, effects) or_return
	return slot, .None
}

// Proposes up to CHUNK_SLOTS values into consecutive slots as one batch. Either every
// value is admitted or none is.
node_propose_batch :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	values: []V,
	slots: []Slot,
	effects: ^Effects(V, M, W, C, G),
) -> (assigned: []Slot, err: Error) {
	effects_reset(effects)
	proposal_gate(node) or_return
	if len(values) == 0 do return nil, .Empty_Batch
	if len(values) > C do return nil, .Batch_Too_Large
	if len(slots) < len(values) do return nil, .Slot_Buffer_Too_Small
	if node.ownership {
		// Every target slot is probed first, so the batch is admitted whole or not at all.
		own_slots_available(node, len(values)) or_return
		for value, i in values do slots[i] = propose_owned(node, value, effects) or_return
		return slots[:len(values)], .None
	}
	if Slot(len(values)) > max(Slot) - node.next_slot do return nil, .Global_Slot_Exhausted
	occupied := node.next_slot - 1 - node.memory_floor
	if occupied >= Slot(W) || Slot(len(values)) > Slot(W) - occupied do return nil, .Window_Full
	for value, i in values {
		slots[i] = node.next_slot
		node.next_slot += 1
		send_accept(node, slots[i], node.ballot, value, effects) or_return
	}
	return slots[:len(values)], .None
}

// ---------------------------------------------------------------------------------
// Timers and repair
// ---------------------------------------------------------------------------------

@(private)
saturating_increment :: #force_inline proc(ticks: u32) -> u32 {
	return ticks + 1 if ticks < max(u32) else ticks
}

// Advances logical time: heartbeats and retransmission for a leader, chunk retries for
// a candidate, an election for a follower that has not heard from a leader.
node_tick :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	noop: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if !node.voting_member do return .None
	node.election_ticks = saturating_increment(node.election_ticks)
	node.heartbeat_ticks = saturating_increment(node.heartbeat_ticks)
	node.resend_ticks = saturating_increment(node.resend_ticks)
	if node.ownership do return tick_ownership(node, noop, effects)

	switch {
	case node.role == .Leader:
		if node.delivered_through < node.leader_base - 1 {
			// An inherited gap that no live peer can serve: after a timeout, run phase one
			// again with a fresh read quorum rather than wait for a dead peer forever.
			node.gap_ticks = saturating_increment(node.gap_ticks)
			if node.gap_ticks >= node.election_timeout_ticks {
				node.gap_ticks = 0
				return start_campaign(node, noop, effects)
			}
		} else {
			node.gap_ticks = 0
		}
		if node.heartbeat_ticks >= node.heartbeat_interval_ticks {
			node.heartbeat_ticks = 0
			broadcast_peers(node, effects, Heartbeat_Message{
				ballot = node.ballot, decided_through = node.delivered_through,
			})
		}
		if node.resend_ticks >= node.resend_interval_ticks {
			node.resend_ticks = 0
			for peer in membership_slice(&node.membership) {
				if peer != node.id do resend_to(node, peer, effects)
			}
		}
	case node.role == .Preparing && node.election_ticks < node.election_timeout_ticks:
		maybe_resolve_chunk(node, effects) or_return
	case node.campaign_enabled && node.election_ticks >= node.election_timeout_ticks:
		start_campaign(node, noop, effects) or_return
	}
	return .None
}

// Retransmits to one peer: a catch-up request if the peer is ahead, then at most one
// chunk of the decisions and open votes it has not acknowledged, rotating through the
// window so a quiet peer cannot pin retries to the first cells.
@(private)
resend_to :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	peer: Node_Id,
	effects: ^Effects(V, M, W, C, G),
) {
	peer_idx, found := membership_index_of(&node.membership, peer)
	if !found do return
	if node.peer_decided_through[peer_idx] > node.delivered_through do request_learn(node, peer, effects)
	l := &node.ledger
	sent := 0
	cursor := node.resend_cursor[peer_idx]
	for _ in 0..<W {
		cell, used := bit_set_next(l.used, cursor)
		if !used {
			cursor = 0
			cell, used = bit_set_next(l.used, 0)
			if !used do break
		}
		cursor = (cell + 1) % W
		slot := l.slot[cell]
		if slot <= node.peer_decided_through[peer_idx] do continue
		switch l.state[cell] {
		case .Chosen:
			send_to(node, peer, effects, Commit_Message(V){slot = slot, value = &l.value[cell]})
		case .Voted:
			if node.lead_slot[cell] != slot || l.vote_ballot[cell] != node.lead_ballot[cell] do continue
			send_to(node, peer, effects, Accept_Message(V){
				ballot = node.lead_ballot[cell], slot = slot, value = &l.value[cell],
			})
		case .Empty:
			continue
		}
		sent += 1
		if sent == C do break
	}
	node.resend_cursor[peer_idx] = cursor
}

// The sender's decided prefix, when the message kind reports it.
@(private)
message_decided_through :: #force_inline proc(message: Message($V)) -> (Slot, bool) {
	#partial switch msg in message {
	case Accepted_Message:      return msg.decided_through, true
	case Heartbeat_Message:     return msg.decided_through, true
	case Nack_Message:          return msg.decided_through, true
	case Promise_Range_Message: return msg.chosen_through, true
	case Prepare_Message:       return msg.first - 1, true
	case Learn_Message:         return msg.from_slot - 1, true
	}
	return 0, false
}

// Processes one authenticated envelope addressed to this node.
node_step :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	envelope: Envelope(V),
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if envelope.to != node.id do return .Wrong_Recipient
	member, found := membership_index_of(&node.membership, envelope.from)
	if !found do return .Not_Member
	if progress, known := message_decided_through(envelope.message); known {
		node.peer_decided_through[member] = max(node.peer_decided_through[member], progress)
	}
	if !node.voting_member {
		commit, is_commit := envelope.message.(Commit_Message(V))
		if !is_commit do return .Learner_Message_Forbidden
		return on_commit(node, envelope.from, commit, effects)
	}
	switch msg in envelope.message {
	case Prepare_Message:       return on_prepare(node, envelope.from, msg, effects)
	case Promise_Message(V):    return on_promise(node, member, msg, effects)
	case Promise_Range_Message: return on_promise_range(node, member, msg, effects)
	case Accept_Message(V):     return on_accept(node, envelope.from, msg, effects)
	case Accepted_Message:      return on_accepted(node, member, msg, effects)
	case Commit_Message(V):     return on_commit(node, envelope.from, msg, effects)
	case Learn_Message:         return on_learn(node, envelope.from, msg, effects)
	case Nack_Message:          on_nack(node, msg)
	case Heartbeat_Message:     on_heartbeat(node, envelope.from, msg, effects)
	}
	return .None
}

// Installs one value the host has certified as chosen by the current configuration.
node_learn_chosen :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	from: Node_Id,
	slot: Slot,
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if node.voting_member do return .Not_Learner
	if !membership_contains(&node.membership, from) do return .Not_Member
	node.leader_hint = from
	node.election_ticks = 0
	return record_commit(node, slot, value, effects)
}

// The transport reports a peer link came back: a leader retransmits, a follower asks its
// leader for what it missed.
node_reconnected :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	peer: Node_Id,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if !membership_contains(&node.membership, peer) do return .Not_Member
	if peer == node.id do return .Invalid_Peer
	if node.role == .Leader {
		resend_to(node, peer, effects)
	} else if hint, ok := node.leader_hint.?; ok && hint == peer {
		request_learn(node, peer, effects)
	}
	return .None
}

node_request_catch_up :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	peer: Node_Id,
	from_slot: Slot,
	effects: ^Effects(V, M, W, C, G),
) -> Error {
	effects_reset(effects)
	if !membership_contains(&node.membership, peer) do return .Not_Member
	if from_slot == 0 do return .Invalid_Slot
	send_to(node, peer, effects, Learn_Message{from_slot = from_slot, count = u32(C)})
	return .None
}
