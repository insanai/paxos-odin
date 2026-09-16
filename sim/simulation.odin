// A deterministic fault simulator for the core protocol.
//
// One seed fixes every choice: which envelope is delivered, which is dropped or
// duplicated, which link is cut, which node crashes and where inside its host commit
// sequence. Oracles run after every transition. A failure prints the seed so the run
// can be replayed step for step.
package paxos_sim

import "base:intrinsics"
import "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:os"
import paxos "../src"

MAX_SIM_NODES    :: 5
SIM_WINDOW       :: 256
SIM_CHUNK        :: 64
MAX_SIM_SLOTS    :: 4096
MAX_SIM_JOURNAL  :: 32768
MAX_SIM_MESSAGES :: 32768
SIM_BATCH        :: 2
// The first proposed value; the no-op is zero and every proposal is larger.
FIRST_PROPOSAL   :: 100

Sim_Node    :: paxos.Node(u64, MAX_SIM_NODES, SIM_WINDOW, SIM_CHUNK)
Sim_Effects :: paxos.Effects(u64, MAX_SIM_NODES, SIM_WINDOW, SIM_CHUNK)

// A journaled record with its value copied out of the ledger, and an envelope in flight
// with its value copied out, exactly as a codec would do on a real host.
Sim_Record :: struct {
	write: paxos.Write(u64),
	value: u64,
}

Sim_Packet :: struct {
	envelope: paxos.Envelope(u64),
	value:    u64,
}

packet_of :: proc(envelope: paxos.Envelope(u64)) -> (packet: Sim_Packet) {
	packet.envelope = envelope
	if value, carries := paxos.message_value(envelope.message); carries do packet.value = value^
	return
}

// The envelope of a packet, pointing at the packet's own copy of the value.
packet_envelope :: proc(packet: ^Sim_Packet) -> paxos.Envelope(u64) {
	envelope := packet.envelope
	#partial switch &m in envelope.message {
	case paxos.Promise_Message(u64): m.value = &packet.value
	case paxos.Accept_Message(u64):  m.value = &packet.value
	case paxos.Commit_Message(u64):  m.value = &packet.value
	}
	return envelope
}

// Deterministic 64-bit SplitMix PRNG.
Prng :: struct {
	state: u64,
}

prng_init :: proc(p: ^Prng, seed: u64) {
	p.state = seed if seed != 0 else 0x853c49e6748fea9b
}

prng_next_u64 :: proc(p: ^Prng) -> u64 {
	p.state += 0x9e3779b97f4a7c15
	z := p.state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

prng_int_max :: proc(p: ^Prng, max_val: int) -> int {
	if max_val <= 0 do return 0
	return int(prng_next_u64(p) % u64(max_val))
}

prng_chance :: proc(p: ^Prng, permille: int) -> bool {
	return prng_int_max(p, 1000) < permille
}

// Fault probabilities in permille (0..1000).
Faults :: struct {
	drop_permille:      int,
	duplicate_permille: int,
	crash_permille:     int,
	link_permille:      int,
}

default_faults :: proc() -> Faults {
	return Faults{
		drop_permille      = 60,
		duplicate_permille = 40,
		crash_permille     = 20,
		link_permille      = 25,
	}
}

Config :: struct {
	seed:       u64,
	steps:      int,
	node_count: int,
	faults:     Faults,
	verbose:    bool,
	// Rotating slot ownership instead of a single stable leader.
	ownership:  bool,
}

// Where a simulated crash interrupts the host commit sequence.
Crash_Point :: enum {
	Before_Writes,   // nothing of this transition survives
	Partial_Writes,  // a durable prefix of the writes, no message sent
	Partial_Messages, // every write durable, a prefix of the messages sent
}

Sim_Vote :: struct {
	ballot: paxos.Ballot,
	value:  u64,
}

Simulator :: struct {
	config:          Config,
	prng:            Prng,
	membership:      paxos.Membership(MAX_SIM_NODES),
	nodes:           [MAX_SIM_NODES]Sim_Node,
	alive:           bit_set[0..<MAX_SIM_NODES],
	journals:        [MAX_SIM_NODES]small_array.Small_Array(MAX_SIM_JOURNAL, Sim_Record),
	queue:           small_array.Small_Array(MAX_SIM_MESSAGES, Sim_Packet),
	partitions:      [MAX_SIM_NODES]bit_set[0..<MAX_SIM_NODES],
	// The golden log: the first durable decision per slot fixes it forever.
	golden:          [MAX_SIM_SLOTS]Maybe(u64),
	golden_max:      paxos.Slot,
	applied:         [MAX_SIM_NODES][MAX_SIM_SLOTS]Maybe(u64),
	consumed:        [MAX_SIM_NODES]paxos.Slot,
	promised:        [MAX_SIM_NODES]paxos.Ballot,
	votes:           [MAX_SIM_NODES][MAX_SIM_SLOTS]Maybe(Sim_Vote),
	faults_enabled:  bool,
	crashes:         [Crash_Point]int,
	proposal_seq:    u64,
}

sim_init :: proc(sim: ^Simulator, cfg: Config) {
	// Zero in place: a compound literal would build a whole Simulator on the stack.
	intrinsics.mem_zero(sim, size_of(Simulator))
	sim.config = cfg
	sim.faults_enabled = true
	sim.proposal_seq = FIRST_PROPOSAL
	prng_init(&sim.prng, cfg.seed)

	node_ids: [MAX_SIM_NODES]paxos.Node_Id
	for i in 0..<cfg.node_count do node_ids[i] = paxos.Node_Id(i + 1)
	sim_check(paxos.init(&sim.membership, node_ids[:cfg.node_count]))

	for i in 0..<cfg.node_count {
		options := paxos.Node_Options{priority = u8(i), rotating_ownership = cfg.ownership}
		sim_check(paxos.init(&sim.nodes[i], node_ids[i], sim.membership, options))
		sim.alive += {i}
	}
}

@(private="file")
sim_fail :: proc(sim: ^Simulator, format: string, args: ..any) -> ! {
	fmt.eprintf("FATAL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintf("\nqueued messages: %d\n", small_array.len(sim.queue))
	for i in 0..<sim.config.node_count {
		n := &sim.nodes[i]
		fmt.eprintf(
			"node %d: alive=%v role=%v ballot=%v promised=%v next=%d base=%d delivered=%d floor=%d " +
			"leader=%v ticks=%d observed_round=%d consumed=%d\n",
			n.id, i in sim.alive, n.role, n.ballot, n.ledger.promised, n.next_slot, n.leader_base,
			n.delivered_through, n.memory_floor, n.leader_hint, n.election_ticks, n.highest_observed_round,
			sim.consumed[i],
		)
	}
	fmt.eprintf("\nReplay with: paxos-sim --seed=%d --steps=%d --nodes=%d --verbose\n",
		sim.config.seed, sim.config.steps, sim.config.node_count)
	os.exit(1)
}

// Agreement and validity: one value per slot, forever, and only proposed values or the no-op.
@(private="file")
record_decision :: proc(sim: ^Simulator, node_id: paxos.Node_Id, slot: paxos.Slot, value: u64) {
	if slot >= MAX_SIM_SLOTS do sim_fail(sim, "slot %d exceeds the capacity %d", slot, MAX_SIM_SLOTS)
	if value != 0 && (value <= FIRST_PROPOSAL || value > sim.proposal_seq) {
		sim_fail(sim, "VALIDITY: node %d decided %d in slot %d; nobody proposed it", node_id, value, slot)
	}
	if expected, decided := sim.golden[slot].?; decided {
		if expected != value {
			sim_fail(sim, "AGREEMENT: slot %d decided %d by node %d, but the golden log holds %d",
				slot, value, node_id, expected)
		}
		return
	}
	sim.golden[slot] = value
	sim.golden_max = math.max(sim.golden_max, slot)
	if sim.config.verbose do fmt.printf("  [slot %d decided] = %d (by node %d)\n", slot, value, node_id)
}

// The oracle watches durable votes directly: a quorum chooses a value even if the
// leader crashes before announcing it, and a promise may never move backwards.
@(private="file")
persist_sim_write :: proc(sim: ^Simulator, node_idx: int, write: paxos.Write(u64)) {
	record := Sim_Record{write = write}
	node_id := paxos.Node_Id(node_idx + 1)
	switch w in write {
	case paxos.Write_Promise:
		if w.ballot < sim.promised[node_idx] {
			sim_fail(sim, "PROMISE REGRESSION: node %d promised %v after %v",
				node_id, w.ballot, sim.promised[node_idx])
		}
		sim.promised[node_idx] = w.ballot
	case paxos.Write_Promise_At:
	case paxos.Write_Vote(u64):
		record.value = w.value^
		if w.ballot < sim.promised[node_idx] {
			sim_fail(sim, "VOTE BELOW PROMISE: node %d voted %v after promising %v",
				node_id, w.ballot, sim.promised[node_idx])
		}
		if w.slot >= MAX_SIM_SLOTS do sim_fail(sim, "slot %d exceeds the simulator capacity", w.slot)
		sim.votes[node_idx][w.slot] = Sim_Vote{ballot = w.ballot, value = record.value}
		count := 0
		for i in 0..<sim.config.node_count {
			if vote, ok := sim.votes[i][w.slot].?; ok && vote.ballot == w.ballot {
				if vote.value != record.value {
					sim_fail(sim, "ballot %v accepted two values in slot %d", w.ballot, w.slot)
				}
				count += 1
			}
		}
		if count >= paxos.membership_write_quorum(&sim.membership) {
			record_decision(sim, node_id, w.slot, record.value)
		}
	case paxos.Write_Chosen(u64):
		record.value = w.value^
		record_decision(sim, node_id, w.slot, record.value)
	case paxos.Write_Trim:
	}
	if !small_array.push_back(&sim.journals[node_idx], record) {
		sim_fail(sim, "journal of node %d is full", node_idx + 1)
	}
}

@(private="file")
enqueue :: proc(sim: ^Simulator, envelope: paxos.Envelope(u64)) {
	if !small_array.push_back(&sim.queue, packet_of(envelope)) do sim_fail(sim, "network queue is full")
}

// The host commit sequence with a crash possible at each of its points.
@(private="file")
process_effects :: proc(sim: ^Simulator, node_idx: int, effects: ^Sim_Effects) {
	node_id := paxos.membership_get(&sim.membership, node_idx)

	// Accept requests alone may leave before the local durability barrier.
	if sim.faults_enabled {
		iterator := paxos.pre_durable_messages(effects)
		for message in paxos.pre_durable_next(&iterator) do enqueue(sim, message)
	}

	crash := sim.faults_enabled && prng_chance(&sim.prng, sim.config.faults.crash_permille)
	point := Crash_Point.Partial_Messages
	if crash do point = Crash_Point(prng_int_max(&sim.prng, len(Crash_Point)))
	writes := paxos.writes_slice(effects)
	kept := len(writes)
	if crash {
		switch point {
		case .Before_Writes:    kept = 0
		case .Partial_Writes:   kept = prng_int_max(&sim.prng, len(writes) + 1)
		case .Partial_Messages: kept = len(writes)
		}
	}
	for w in writes[:kept] do persist_sim_write(sim, node_idx, w)

	if crash && point != .Partial_Messages {
		sim.crashes[point] += 1
		sim_crash_node(sim, node_idx)
		// The crashed process loses this volatile batch. Reuse the harness buffer only
		// after discarding it, never by falsely confirming writes.
		paxos.init(effects)
		return
	}

	// Decided entries reach the application only after their commit record is durable.
	for c in paxos.committed_slice(effects) {
		record_decision(sim, node_id, c.slot, c.value^)
		if c.slot != sim.consumed[node_idx] + 1 {
			sim_fail(sim, "CONTIGUITY: node %d released slot %d after %d",
				node_id, c.slot, sim.consumed[node_idx])
		}
		sim.applied[node_idx][c.slot] = c.value^
		sim.consumed[node_idx] = c.slot
	}
	// Licence window reuse only half of the time so full-window paths are exercised.
	if !sim.faults_enabled || prng_chance(&sim.prng, 500) {
		sim_check(paxos.advance_memory_floor(&sim.nodes[node_idx], sim.consumed[node_idx]))
	}

	paxos.confirm_writes_durable(effects)

	// Serve evicted history from the host's durable application image.
	for request in paxos.requests_slice(effects) {
		switch r in request {
		case paxos.Serve_Range_Request:
			for offset in 0..<r.count {
				slot := r.first + paxos.Slot(offset)
				if slot >= MAX_SIM_SLOTS do continue
				if value, ok := &sim.applied[node_idx][slot].?; ok {
					commit := paxos.Commit_Message(u64){slot = slot, value = value}
					enqueue(sim, paxos.Envelope(u64){from = node_id, to = r.peer, message = commit})
				}
			}
		}
	}

	messages := paxos.messages_slice(effects)
	sent := len(messages)
	if crash {
		sent = prng_int_max(&sim.prng, len(messages) + 1)
	}
	for envelope in messages[:sent] do enqueue(sim, envelope)
	if crash {
		sim.crashes[point] += 1
		sim_crash_node(sim, node_idx)
	}
}

@(private="file")
sim_crash_node :: proc(sim: ^Simulator, node_idx: int) {
	if !(node_idx in sim.alive) do return
	sim.alive -= {node_idx}
	if sim.config.verbose {
		fmt.printf("  [fault: crash] node %d\n", paxos.membership_get(&sim.membership, node_idx))
	}
}

@(private="file")
sim_restart_node :: proc(sim: ^Simulator, node_idx: int) {
	if node_idx in sim.alive do return
	id := paxos.membership_get(&sim.membership, node_idx)

	// Replay the lifetime journal into fresh durable state, then restore every derived frontier.
	ledger: paxos.Ledger(u64, SIM_WINDOW)
	for &record in small_array.slice(&sim.journals[node_idx]) {
		write := record.write
		#partial switch &w in write {
		case paxos.Write_Vote(u64):   w.value = &record.value
		case paxos.Write_Chosen(u64): w.value = &record.value
		}
		sim_check(paxos.ledger_replay_fold(&ledger, write))
	}
	options := paxos.Node_Options{priority = u8(node_idx), rotating_ownership = sim.config.ownership}
	floor := sim.consumed[node_idx]
	sim_check(paxos.restore(&sim.nodes[node_idx], id, sim.membership, ledger, floor, options))

	sim.alive += {node_idx}
	if sim.config.verbose {
		fmt.printf("  [recovery] node %d restarted from %d journal records\n",
			id, small_array.len(sim.journals[node_idx]))
	}
}

@(private="file")
random_alive :: proc(sim: ^Simulator) -> (int, bool) {
	index := prng_int_max(&sim.prng, sim.config.node_count)
	return index, index in sim.alive
}

@(private="file")
deliver_one :: proc(sim: ^Simulator, effects: ^Sim_Effects) {
	queued := small_array.len(sim.queue)
	if queued == 0 do return
	index := prng_int_max(&sim.prng, queued)
	packet := small_array.get(sim.queue, index)
	small_array.unordered_remove(&sim.queue, index)
	envelope := packet_envelope(&packet)

	from_idx, from_ok := paxos.membership_index_of(&sim.membership, envelope.from)
	to_idx, to_ok := paxos.membership_index_of(&sim.membership, envelope.to)
	if !from_ok || !to_ok do return
	if to_idx in sim.partitions[from_idx] || !(to_idx in sim.alive) do return

	if !prng_chance(&sim.prng, sim.config.faults.drop_permille) {
		sim_check(paxos.step(&sim.nodes[to_idx], envelope, effects))
		process_effects(sim, to_idx, effects)
	}
	if prng_chance(&sim.prng, sim.config.faults.duplicate_permille) do enqueue(sim, packet.envelope)
}

@(private="file")
propose_random :: proc(sim: ^Simulator, effects: ^Sim_Effects) {
	node_idx, alive := random_alive(sim)
	if !alive do return
	node := &sim.nodes[node_idx]
	err: paxos.Error
	if prng_chance(&sim.prng, 250) {
		values: [SIM_BATCH]u64
		slots: [SIM_BATCH]paxos.Slot
		for &value in values {
			sim.proposal_seq += 1
			value = sim.proposal_seq
		}
		_, err = paxos.propose_batch(node, values[:], slots[:], effects)
	} else {
		sim.proposal_seq += 1
		_, err = paxos.propose(node, sim.proposal_seq, effects)
	}
	// Backpressure is expected; the burnt sequence number still counts as proposed for validity.
	if err == .Not_Leader || err == .Window_Full || err == .Leader_Catching_Up do return
	sim_check(err)
	process_effects(sim, node_idx, effects)
}

@(private="file")
toggle_link :: proc(sim: ^Simulator) {
	if !prng_chance(&sim.prng, sim.config.faults.link_permille) do return
	a := prng_int_max(&sim.prng, sim.config.node_count)
	b := prng_int_max(&sim.prng, sim.config.node_count)
	if a == b do return
	cut := b in sim.partitions[a]
	if cut {
		sim.partitions[a] -= {b}
		sim.partitions[b] -= {a}
	} else {
		sim.partitions[a] += {b}
		sim.partitions[b] += {a}
	}
	if sim.config.verbose {
		fmt.printf("  [fault: link] %d <-> %d %s\n", paxos.membership_get(&sim.membership, a),
			paxos.membership_get(&sim.membership, b), "healed" if cut else "cut")
	}
}

sim_run :: proc(sim: ^Simulator) {
	if sim.config.verbose {
		fmt.printf("simulation: seed %d, %d steps, %d nodes\n",
			sim.config.seed, sim.config.steps, sim.config.node_count)
	}
	effects: Sim_Effects
	// Bootstrap: node 1 campaigns (owners need no campaign).
	if !sim.config.ownership {
		sim_check(paxos.campaign(&sim.nodes[0], 0, &effects))
		process_effects(sim, 0, &effects)
	}

	for _ in 1..=sim.config.steps do run_fault_step(sim, &effects)

	probe_slot := run_quiescence(sim, &effects)
	if probe_slot == 0 || sim.golden[probe_slot] == nil {
		sim_fail(sim, "LIVENESS: the healed cluster did not decide a fresh proposal")
	}
	verify_convergence(sim)

	total_crashes := 0
	for count in sim.crashes do total_crashes += count
	fmt.printf(
		"Simulation passed. Seed=%d Steps=%d Nodes=%d DecidedSlots=%d Crashes=%d PartialCrashes=%d. " +
		"Invariants preserved.\n",
		sim.config.seed, sim.config.steps, sim.config.node_count, sim.golden_max, total_crashes,
		sim.crashes[.Partial_Writes],
	)
}

// One seeded step: deliver, tick, propose, cut or heal a link, crash, restart, or reconnect.
@(private="file")
run_fault_step :: proc(sim: ^Simulator, effects: ^Sim_Effects) {
	roll := prng_int_max(&sim.prng, 1000)
	switch {
	case roll < 450:
		deliver_one(sim, effects)
	case roll < 650:
		if node_idx, alive := random_alive(sim); alive {
			sim_check(paxos.tick(&sim.nodes[node_idx], 0, effects))
			process_effects(sim, node_idx, effects)
		}
	case roll < 800:
		propose_random(sim, effects)
	case roll < 860:
		toggle_link(sim)
	case roll < 900:
		// Keep a read quorum alive so the run can make progress.
		if prng_chance(&sim.prng, sim.config.faults.crash_permille) &&
		   card(sim.alive) > paxos.membership_read_quorum(&sim.membership) {
			sim_crash_node(sim, prng_int_max(&sim.prng, sim.config.node_count))
		}
	case roll < 960:
		if target := prng_int_max(&sim.prng, sim.config.node_count); !(target in sim.alive) {
			sim_restart_node(sim, target)
		}
	case:
		// A transport reports a peer link came back; the node repairs it proactively.
		if node_idx, alive := random_alive(sim); alive {
			peer := paxos.membership_get(&sim.membership, prng_int_max(&sim.prng, sim.config.node_count))
			if peer != sim.nodes[node_idx].id {
				sim_check(paxos.reconnected(&sim.nodes[node_idx], peer, effects))
				process_effects(sim, node_idx, effects)
			}
		}
	}
}

// Heals every link, restarts every node, drains the network, and requires one fresh
// decision so a run without progress cannot pass vacuously. Returns the probe's slot.
@(private="file")
run_quiescence :: proc(sim: ^Simulator, effects: ^Sim_Effects) -> (probe_slot: paxos.Slot) {
	if sim.config.verbose do fmt.println("quiescence: healing links, restarting nodes, draining")
	sim.faults_enabled = false
	for i in 0..<sim.config.node_count {
		sim_restart_node(sim, i)
		sim.partitions[i] = {}
		paxos.set_campaign_enabled(&sim.nodes[i], i == 0)
	}
	if !sim.config.ownership {
		sim_check(paxos.campaign(&sim.nodes[0], 0, effects))
		process_effects(sim, 0, effects)
	}

	for round in 1..=400 {
		for small_array.len(sim.queue) > 0 {
			packet := small_array.pop_front(&sim.queue)
			envelope := packet_envelope(&packet)
			to_idx, ok := paxos.membership_index_of(&sim.membership, envelope.to)
			if !ok || !(to_idx in sim.alive) do continue
			sim_check(paxos.step(&sim.nodes[to_idx], envelope, effects))
			process_effects(sim, to_idx, effects)
		}
		for i in 0..<sim.config.node_count {
			sim_check(paxos.tick(&sim.nodes[i], 0, effects))
			process_effects(sim, i, effects)
		}
		// Whoever leads the healed cluster (a surviving leader, or node 1 after its
		// campaign) must decide one fresh value.
		for i in 0..<sim.config.node_count {
			if probe_slot != 0 do continue
			if !sim.config.ownership && paxos.role(&sim.nodes[i]) != .Leader do continue
			sim.proposal_seq += 1
			err: paxos.Error
			probe_slot, err = paxos.propose(&sim.nodes[i], sim.proposal_seq, effects)
			// Backpressure is not failure: the window drains as the loop delivers.
			if err == .Window_Full || err == .Not_Leader || err == .Leader_Catching_Up do continue
			sim_check(err)
			process_effects(sim, i, effects)
		}
		if small_array.len(sim.queue) == 0 && round > 50 do break
	}
	return
}

// Convergence: every node applied the whole golden log.
@(private="file")
verify_convergence :: proc(sim: ^Simulator) {
	for slot in 1..=sim.golden_max {
		expected, decided := sim.golden[slot].?
		if !decided do continue
		for i in 0..<sim.config.node_count {
			value, applied := sim.applied[i][slot].?
			if applied && value == expected do continue
			sim_fail(sim, "CONVERGENCE: node %d slot %d has %v, expected %d",
				paxos.membership_get(&sim.membership, i), slot, sim.applied[i][slot], expected)
		}
	}
}

@(private="file")
sim_check :: proc(err: paxos.Error, loc := #caller_location) {
	if err != .None {
		fmt.eprintln("Simulation protocol failure at", loc, paxos.explain_error(err))
		os.exit(1)
	}
}
