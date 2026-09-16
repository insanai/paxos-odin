package paxos_sim

import "core:fmt"
import "core:math"
import "core:os"
import paxos "../src"

MAX_SIM_NODES     :: 5
MAX_SIM_SLOTS     :: 4096
MAX_SIM_JOURNAL   :: 8192
MAX_SIM_MESSAGES  :: 4096

// Deterministic 64-bit SplitMix PRNG
Prng :: struct {
	state: u64,
}

prng_init :: proc(p: ^Prng, seed: u64) {
	p.state = seed != 0 ? seed : 0x853c49e6748fea9b
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

// Fault probabilities expressed in permille (0..1000).
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
}

Simulator :: struct {
	config:         Config,
	prng:           Prng,
	membership:     paxos.Membership(MAX_SIM_NODES),
	nodes:          [MAX_SIM_NODES]paxos.Node(u64, MAX_SIM_NODES, 256, 64),
	alive:          [MAX_SIM_NODES]bool,
	journals:       [MAX_SIM_NODES][MAX_SIM_JOURNAL]paxos.Write(u64),
	journal_counts: [MAX_SIM_NODES]int,
	queue:          [MAX_SIM_MESSAGES]paxos.Envelope(u64),
	queue_count:    int,
	partitions:     [MAX_SIM_NODES][MAX_SIM_NODES]bool,
	golden:         [MAX_SIM_SLOTS]Maybe(u64),
	golden_max:     paxos.Slot,
	proposal_seq:   u64,
}

sim_init :: proc(sim: ^Simulator, cfg: Config) {
	sim.config = cfg
	prng_init(&sim.prng, cfg.seed)

	node_ids: [MAX_SIM_NODES]paxos.NodeId
	for i in 0..<cfg.node_count {
		node_ids[i] = paxos.NodeId(i + 1)
	}
	_ = paxos.membership_init(&sim.membership, node_ids[:cfg.node_count])

	for i in 0..<cfg.node_count {
		_ = paxos.node_init_with_priority(&sim.nodes[i], node_ids[i], sim.membership, u32(i))
		sim.alive[i] = true
		sim.journal_counts[i] = 0
	}
	for i in 0..<MAX_SIM_NODES {
		for j in 0..<MAX_SIM_NODES {
			sim.partitions[i][j] = false
		}
	}
	for i in 0..<MAX_SIM_SLOTS {
		sim.golden[i] = nil
	}
	sim.golden_max = 0
	sim.proposal_seq = 100
	sim.queue_count = 0
}

@(private="file")
check_and_record_commits :: proc(sim: ^Simulator, node_id: paxos.NodeId, committed: []paxos.Committed(u64)) {
	for c in committed {
		if c.slot >= MAX_SIM_SLOTS {
			fmt.eprintf("Simulator: slot %d exceeds max capacity %d\n", c.slot, MAX_SIM_SLOTS)
			os.exit(1)
		}
		if sim.golden[c.slot] != nil {
			expected := sim.golden[c.slot].?
			if expected != c.value {
				fmt.eprintf(
					"FATAL AGREEMENT VIOLATION: Slot %d committed value %d by Node %d, but golden oracle has %d!\n",
					c.slot, c.value, node_id, expected,
				)
				os.exit(1)
			}
		} else {
			sim.golden[c.slot] = c.value
			sim.golden_max = math.max(sim.golden_max, c.slot)
			if sim.config.verbose {
				fmt.printf("  [Slot %d Decided] = %d (by Node %d)\n", c.slot, c.value, node_id)
			}
		}
	}
}

@(private="file")
process_effects :: proc(
	sim: ^Simulator,
	node_idx: int,
	effects: ^paxos.Effects(u64, MAX_SIM_NODES, 256),
) {
	node_id := sim.membership.ids[node_idx]

	// 1. Host Write-Ahead Log: Persist writes
	writes := paxos.effects_writes_slice(effects)
	for w in writes {
		assert(sim.journal_counts[node_idx] < MAX_SIM_JOURNAL, "Journal full")
		sim.journals[node_idx][sim.journal_counts[node_idx]] = w
		sim.journal_counts[node_idx] += 1
	}

	// 2. Check and record committed entries into golden oracle
	committed := paxos.effects_committed_slice(effects)
	check_and_record_commits(sim, node_id, committed)

	// 3. Confirm durability before transmitting outbound messages
	paxos.effects_confirm_writes_durable(effects)

	// 4. Queue outbound messages
	msgs := paxos.effects_messages_slice(effects)
	for env in msgs {
		if sim.queue_count < MAX_SIM_MESSAGES {
			sim.queue[sim.queue_count] = env
			sim.queue_count += 1
		}
	}
}

@(private="file")
sim_crash_node :: proc(sim: ^Simulator, node_idx: int) {
	if !sim.alive[node_idx] do return
	sim.alive[node_idx] = false
	if sim.config.verbose {
		fmt.printf("  [Fault: Crash] Node %d crashed\n", sim.membership.ids[node_idx])
	}
}

@(private="file")
sim_restart_node :: proc(sim: ^Simulator, node_idx: int) {
	if sim.alive[node_idx] do return
	id := sim.membership.ids[node_idx]

	// Reset node state and replay journal
	_ = paxos.node_init_with_priority(&sim.nodes[node_idx], id, sim.membership, u32(node_idx))
	for j in 0..<sim.journal_counts[node_idx] {
		w := sim.journals[node_idx][j]
		_ = paxos.durable_replay_fold(&sim.nodes[node_idx].durable, w)
	}
	sim.alive[node_idx] = true
	if sim.config.verbose {
		fmt.printf("  [Recovery: Restart] Node %d restarted and replayed %d journal writes\n", id, sim.journal_counts[node_idx])
	}
}

sim_run :: proc(sim: ^Simulator) {
	if sim.config.verbose {
		fmt.printf("Starting Paxos simulation with seed %d, %d steps, %d nodes\n", sim.config.seed, sim.config.steps, sim.config.node_count)
	}

	eff: paxos.Effects(u64, MAX_SIM_NODES, 256)

	// Bootstrap: start campaign from node 0
	paxos.effects_init(&eff)
	_ = paxos.node_campaign(&sim.nodes[0], 0, &eff)
	process_effects(sim, 0, &eff)

	for step in 1..=sim.config.steps {
		action := prng_int_max(&sim.prng, 6)

		switch action {
		case 0: // Propose value on random alive node
			node_idx := prng_int_max(&sim.prng, sim.config.node_count)
			if sim.alive[node_idx] {
				paxos.effects_init(&eff)
				sim.proposal_seq += 1
				val := sim.proposal_seq
				_, err := paxos.node_propose(&sim.nodes[node_idx], val, &eff)
				if err == .None {
					process_effects(sim, node_idx, &eff)
				}
			}

		case 1: // Tick random alive node
			node_idx := prng_int_max(&sim.prng, sim.config.node_count)
			if sim.alive[node_idx] {
				paxos.effects_init(&eff)
				_ = paxos.node_tick(&sim.nodes[node_idx], 0, &eff)
				process_effects(sim, node_idx, &eff)
			}

		case 2: // Deliver random in-flight message
			if sim.queue_count > 0 {
				idx := prng_int_max(&sim.prng, sim.queue_count)
				env := sim.queue[idx]
				// Remove message from queue by swapping with last
				sim.queue[idx] = sim.queue[sim.queue_count - 1]
				sim.queue_count -= 1

				from_idx, f_ok := paxos.membership_index_of(sim.membership, env.from)
				to_idx, t_ok := paxos.membership_index_of(sim.membership, env.to)

				if f_ok && t_ok {
					// Check partition
					if !sim.partitions[from_idx][to_idx] && sim.alive[to_idx] {
						// Drop check
						if prng_int_max(&sim.prng, 1000) >= sim.config.faults.drop_permille {
							paxos.effects_init(&eff)
							err := paxos.node_step(&sim.nodes[to_idx], env, &eff)
							if err == .None {
								process_effects(sim, to_idx, &eff)
							}
						}
						// Duplicate check
						if prng_int_max(&sim.prng, 1000) < sim.config.faults.duplicate_permille && sim.queue_count < MAX_SIM_MESSAGES {
							sim.queue[sim.queue_count] = env
							sim.queue_count += 1
						}
					}
				}
			}

		case 3: // Partition cut / heal toggle
			a := prng_int_max(&sim.prng, sim.config.node_count)
			b := prng_int_max(&sim.prng, sim.config.node_count)
			if a != b {
				current := sim.partitions[a][b]
				sim.partitions[a][b] = !current
				sim.partitions[b][a] = !current
				if sim.config.verbose {
					state_str := "cut" if !current else "healed"
					fmt.printf("  [Fault: Link] Link (%d <-> %d) %s\n", sim.membership.ids[a], sim.membership.ids[b], state_str)
				}
			}

		case 4: // Crash node
			if prng_int_max(&sim.prng, 1000) < sim.config.faults.crash_permille {
				alive_count := 0
				for a in sim.alive[:sim.config.node_count] {
					if a do alive_count += 1
				}
				// Keep at least a majority alive to allow progress
				if alive_count > paxos.membership_read_quorum(sim.membership) {
					target := prng_int_max(&sim.prng, sim.config.node_count)
					sim_crash_node(sim, target)
				}
			}

		case 5: // Restart crashed node
			target := prng_int_max(&sim.prng, sim.config.node_count)
			if !sim.alive[target] {
				sim_restart_node(sim, target)
			}
		}
	}

	// -------------------------------------------------------------
	// Quiescence Phase: heal partitions, restart nodes, drain queue
	// -------------------------------------------------------------
	if sim.config.verbose {
		fmt.println("\nBeginning Quiescence Phase (healing all partitions, restarting all nodes)...")
	}

	for i in 0..<sim.config.node_count {
		sim_restart_node(sim, i)
		for j in 0..<sim.config.node_count {
			sim.partitions[i][j] = false
		}
	}

	// Drain network and run ticks until network is quiescent
	for round in 1..=400 {
		// Deliver all queued messages
		for sim.queue_count > 0 {
			env := sim.queue[0]
			for i in 0..<sim.queue_count - 1 {
				sim.queue[i] = sim.queue[i + 1]
			}
			sim.queue_count -= 1

			to_idx, ok := paxos.membership_index_of(sim.membership, env.to)
			if ok && sim.alive[to_idx] {
				paxos.effects_init(&eff)
				err := paxos.node_step(&sim.nodes[to_idx], env, &eff)
				if err == .None {
					process_effects(sim, to_idx, &eff)
				}
			}
		}

		// Tick all nodes
		for i in 0..<sim.config.node_count {
			if sim.alive[i] {
				paxos.effects_init(&eff)
				_ = paxos.node_tick(&sim.nodes[i], 0, &eff)
				process_effects(sim, i, &eff)
			}
		}

		if sim.queue_count == 0 && round > 50 {
			break
		}
	}

	// Verify that all alive nodes have agreed on the golden prefix
	if sim.golden_max > 0 {
		for slot in 1..=sim.golden_max {
			expected := sim.golden[slot]
			if expected != nil {
				for i in 0..<sim.config.node_count {
					val, committed := paxos.node_committed_at(&sim.nodes[i], slot)
					if committed && val != expected.? {
						fmt.eprintf("Quiescence check failed: Node %d slot %d has %d, expected %d\n", sim.membership.ids[i], slot, val, expected.?)
						os.exit(1)
					}
				}
			}
		}
	}

	fmt.printf(
		"Simulation passed successfully! Seed=%d, Steps=%d, DecidedSlots=%d. Invariants preserved.\n",
		sim.config.seed, sim.config.steps, sim.golden_max,
	)
}
