package paxos_bench

import "core:fmt"
import "core:time"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:container/queue"
import paxos "../src"

BENCH_MAX_MEMBERS :: 3
BENCH_WINDOW      :: 1024
BENCH_CHUNK       :: 128

Benchmark_Config :: struct {
	iterations: int,
	json_output: bool,
}

drain_network :: proc(
	nodes: ^[BENCH_MAX_MEMBERS]paxos.Node(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW, BENCH_CHUNK),
	membership: paxos.Membership(BENCH_MAX_MEMBERS),
	q: ^queue.Queue(paxos.Envelope(u64)),
	eff: ^paxos.Effects(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW),
) {
	for queue.len(q^) > 0 {
		env := queue.pop_front(q)

		to_idx, ok := paxos.membership_index_of(membership, env.to)
		if ok {
			paxos.effects_init(eff)
			err := paxos.node_step(&nodes^[to_idx], env, eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				msgs := paxos.effects_messages_slice(eff)
				for m in msgs {
					_, _ = queue.push_back(q, m)
				}
			}
		}
	}
}

run_benchmark_mode :: proc(
	mode_name: string,
	iterations: int,
	pipelined_window: int,
	batched: bool,
) -> (ops_per_sec: f64, avg_latency_ns: f64) {
	m: paxos.Membership(BENCH_MAX_MEMBERS)
	nodes_ids := [BENCH_MAX_MEMBERS]paxos.NodeId{1, 2, 3}
	_ = paxos.membership_init(&m, nodes_ids[:])

	nodes := new([BENCH_MAX_MEMBERS]paxos.Node(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW, BENCH_CHUNK))
	defer free(nodes)

	for i in 0..<BENCH_MAX_MEMBERS {
		_ = paxos.node_init_with_priority(&nodes^[i], nodes_ids[i], m, u32(i))
	}

	backing := new([16384]paxos.Envelope(u64))
	defer free(backing)

	q: queue.Queue(paxos.Envelope(u64))
	queue.init_from_slice(&q, backing[:])

	eff := new(paxos.Effects(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW))
	defer free(eff)

	// Elect node 0 as leader
	paxos.effects_init(eff)
	_ = paxos.node_campaign(&nodes^[0], 0, eff)
	paxos.effects_confirm_writes_durable(eff)
	for msg in paxos.effects_messages_slice(eff) {
		queue.push_back(&q, msg)
	}
	drain_network(nodes, m, &q, eff)

	// Run warm-up
	for i in 1..=50 {
		paxos.effects_init(eff)
		_, _ = paxos.node_propose(&nodes^[0], u64(i), eff)
		paxos.effects_confirm_writes_durable(eff)
		for msg in paxos.effects_messages_slice(eff) {
			queue.push_back(&q, msg)
		}
		drain_network(nodes, m, &q, eff)
		// Advance memory floor to avoid window exhaustion
		_ = paxos.node_advance_memory_floor(&nodes^[0], paxos.Slot(i))
		_ = paxos.node_advance_memory_floor(&nodes^[1], paxos.Slot(i))
		_ = paxos.node_advance_memory_floor(&nodes^[2], paxos.Slot(i))
	}

	start := time.now()
	executed := 0

	batch_values: [BENCH_CHUNK]u64
	batch_slots: [BENCH_CHUNK]paxos.Slot

	for executed < iterations {
		if batched {
			chunk := pipelined_window
			if executed + chunk > iterations do chunk = iterations - executed
			for j in 0..<chunk {
				batch_values[j] = u64(executed + j + 1000)
			}
			paxos.effects_init(eff)
			_, err := paxos.node_propose_batch(&nodes^[0], batch_values[:chunk], batch_slots[:chunk], eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				for msg in paxos.effects_messages_slice(eff) {
					queue.push_back(&q, msg)
				}
				drain_network(nodes, m, &q, eff)
				executed += chunk
			}
		} else {
			paxos.effects_init(eff)
			_, err := paxos.node_propose(&nodes^[0], u64(executed + 1000), eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				for msg in paxos.effects_messages_slice(eff) {
					queue.push_back(&q, msg)
				}
				executed += 1
			}
			if executed % pipelined_window == 0 || executed == iterations {
				drain_network(nodes, m, &q, eff)
			}
		}

		// Keep memory floor moving
		curr_decided := paxos.node_decided_through(&nodes^[0])
		if curr_decided > 100 {
			floor := curr_decided - 50
			_ = paxos.node_advance_memory_floor(&nodes^[0], floor)
			_ = paxos.node_advance_memory_floor(&nodes^[1], floor)
			_ = paxos.node_advance_memory_floor(&nodes^[2], floor)
		}
	}

	elapsed := time.since(start)
	elapsed_sec := time.duration_seconds(elapsed)
	ops_per_sec = f64(iterations) / elapsed_sec
	avg_latency_ns = (elapsed_sec * 1e9) / f64(iterations)
	return ops_per_sec, avg_latency_ns
}

main :: proc() {
	cfg := Benchmark_Config{
		iterations = 10000,
		json_output = false,
	}

	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--iterations=") {
			val_str := strings.trim_prefix(arg, "--iterations=")
			if val, ok := strconv.parse_int(val_str); ok {
				cfg.iterations = val
			}
		} else if arg == "--json" {
			cfg.json_output = true
		}
	}

	sync_ops, sync_lat := run_benchmark_mode("Synchronous", cfg.iterations, 1, false)
	pipe_ops, pipe_lat := run_benchmark_mode("Pipelined (16)", cfg.iterations, 16, false)
	batch_ops, batch_lat := run_benchmark_mode("Batched (16)", cfg.iterations, 16, true)

	if cfg.json_output {
		fmt.println("{")
		fmt.printf("  \"iterations\": %d,\n", cfg.iterations)
		fmt.println("  \"results\": [")
		fmt.printf("    {\"mode\": \"synchronous\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f},\n", sync_ops, sync_lat)
		fmt.printf("    {\"mode\": \"pipelined_16\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f},\n", pipe_ops, pipe_lat)
		fmt.printf("    {\"mode\": \"batched_16\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f}\n", batch_ops, batch_lat)
		fmt.println("  ]")
		fmt.println("}")
	} else {
		fmt.println("================================================================================")
		fmt.println("  PAXOS-ODIN IN-MEMORY WORKLOAD BENCHMARK")
		fmt.println("  Cluster: 3 nodes | Pure State Machine (Zero-I/O, In-Memory)")
		fmt.printf("  Iterations: %d per mode\n", cfg.iterations)
		fmt.println("================================================================================")
		fmt.printf("%-25s %15s %20s %15s\n", "Mode", "Throughput", "Latency / Op", "Iterations")
		fmt.println("--------------------------------------------------------------------------------")
		fmt.printf("%-20s %15s ops/s %15s %12s\n", "Synchronous", fmt.tprintf("%d", int(sync_ops)), fmt.tprintf("%.1f ns", sync_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.printf("%-20s %15s ops/s %15s %12s\n", "Pipelined (16)", fmt.tprintf("%d", int(pipe_ops)), fmt.tprintf("%.1f ns", pipe_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.printf("%-20s %15s ops/s %15s %12s\n", "Batched (16)", fmt.tprintf("%d", int(batch_ops)), fmt.tprintf("%.1f ns", batch_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.println("================================================================================")
	}
}
