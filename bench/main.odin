package paxos_bench

import "core:fmt"
import "core:time"
import "core:os"
import "core:strconv"
import "core:strings"
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
	queue: ^[4096]paxos.Envelope(u64),
	queue_count: ^int,
	eff: ^paxos.Effects(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW),
) {
	for queue_count^ > 0 {
		env := queue^[0]
		for i in 0..<queue_count^ - 1 {
			queue^[i] = queue^[i + 1]
		}
		queue_count^ -= 1

		to_idx, ok := paxos.membership_index_of(membership, env.to)
		if ok {
			paxos.effects_init(eff)
			err := paxos.node_step(&nodes^[to_idx], env, eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				msgs := paxos.effects_messages_slice(eff)
				for m in msgs {
					if queue_count^ < len(queue^) {
						queue^[queue_count^] = m
						queue_count^ += 1
					}
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

	queue := new([4096]paxos.Envelope(u64))
	defer free(queue)
	queue_count := 0

	eff := new(paxos.Effects(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW))
	defer free(eff)

	// Elect node 0 as leader
	paxos.effects_init(eff)
	_ = paxos.node_campaign(&nodes^[0], 0, eff)
	paxos.effects_confirm_writes_durable(eff)
	for msg in paxos.effects_messages_slice(eff) {
		queue^[queue_count] = msg
		queue_count += 1
	}
	drain_network(nodes, m, queue, &queue_count, eff)

	// Run warm-up
	for i in 1..=50 {
		paxos.effects_init(eff)
		_, _ = paxos.node_propose(&nodes^[0], u64(i), eff)
		paxos.effects_confirm_writes_durable(eff)
		for msg in paxos.effects_messages_slice(eff) {
			queue^[queue_count] = msg
			queue_count += 1
		}
		drain_network(nodes, m, queue, &queue_count, eff)
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
					if queue_count < len(queue^) {
						queue^[queue_count] = msg
						queue_count += 1
					}
				}
				drain_network(nodes, m, queue, &queue_count, eff)
				executed += chunk
			}
		} else {
			paxos.effects_init(eff)
			_, err := paxos.node_propose(&nodes^[0], u64(executed + 1000), eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				for msg in paxos.effects_messages_slice(eff) {
					if queue_count < len(queue^) {
						queue^[queue_count] = msg
						queue_count += 1
					}
				}
				executed += 1
			}
			if executed % pipelined_window == 0 || executed == iterations {
				drain_network(nodes, m, queue, &queue_count, eff)
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
		iterations  = 10000,
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
		} else if arg == "--help" || arg == "-h" {
			fmt.println("Usage: paxos-bench [--iterations=N] [--json]")
			return
		}
	}

	if !cfg.json_output {
		fmt.println("================================================================================")
		fmt.println("  PAXOS-ODIN IN-MEMORY WORKLOAD BENCHMARK")
		fmt.println("  Cluster: 3 nodes | Pure State Machine (Zero-I/O, In-Memory)")
		fmt.printf("  Iterations: %d per mode\n", cfg.iterations)
		fmt.println("================================================================================")
		fmt.printf("%-20s %15s %20s %15s\n", "Mode", "Throughput", "Latency / Op", "Iterations")
		fmt.println("--------------------------------------------------------------------------------")
	}

	// 1. Synchronous (drain after every single proposal)
	ops_sync, lat_sync := run_benchmark_mode("Synchronous", cfg.iterations, 1, false)
	if !cfg.json_output {
		fmt.printf("%-20s %10d ops/s %14.1f ns %15d\n", "Synchronous", int(ops_sync), lat_sync, cfg.iterations)
	}

	// 2. Pipelined (window of 16 proposals)
	ops_pipe, lat_pipe := run_benchmark_mode("Pipelined (16)", cfg.iterations, 16, false)
	if !cfg.json_output {
		fmt.printf("%-20s %10d ops/s %14.1f ns %15d\n", "Pipelined (16)", int(ops_pipe), lat_pipe, cfg.iterations)
	}

	// 3. Batched (batch size 16)
	ops_batch, lat_batch := run_benchmark_mode("Batched (16)", cfg.iterations, 16, true)
	if !cfg.json_output {
		fmt.printf("%-20s %10d ops/s %14.1f ns %15d\n", "Batched (16)", int(ops_batch), lat_batch, cfg.iterations)
		fmt.println("================================================================================")
	} else {
		fmt.printf(
			"{ \"iterations\": %d, \"synchronous_ops_sec\": %d, \"pipelined_ops_sec\": %d, \"batched_ops_sec\": %d }\n",
			cfg.iterations, int(ops_sync), int(ops_pipe), int(ops_batch),
		)
	}
}
