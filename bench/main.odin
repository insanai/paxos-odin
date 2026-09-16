package paxos_bench

import "core:fmt"
import "core:time"
import "core:os"
import "core:strconv"
import "core:strings"
import paxos "../src"

BENCH_MAX_MEMBERS :: 3
BENCH_WINDOW      :: 4096
BENCH_CHUNK       :: 256
BENCH_QUEUE_CAP   :: 32768

Benchmark_Config :: struct {
	iterations: int,
	json_output: bool,
}

drain_network :: proc(
	nodes: ^[BENCH_MAX_MEMBERS]paxos.Node(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW, BENCH_CHUNK),
	queue: ^[BENCH_QUEUE_CAP]paxos.Envelope(u64),
	queue_count: ^int,
	eff: ^paxos.Effects(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW),
) {
	head := 0
	for head < queue_count^ {
		env := queue^[head]
		head += 1

		to_idx := int(env.to - 1)
		if to_idx >= 0 && to_idx < BENCH_MAX_MEMBERS {
			paxos.effects_init(eff)
			err := paxos.node_step(&nodes^[to_idx], env, eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				for m in paxos.effects_messages_slice(eff) {
					if queue_count^ < BENCH_QUEUE_CAP {
						queue^[queue_count^] = m
						queue_count^ += 1
					}
				}
			}
		}
	}
	queue_count^ = 0
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

	queue := new([BENCH_QUEUE_CAP]paxos.Envelope(u64))
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
	drain_network(nodes, queue, &queue_count, eff)

	// Run warm-up
	for i in 1..=50 {
		paxos.effects_init(eff)
		_, _ = paxos.node_propose(&nodes^[0], u64(i), eff)
		paxos.effects_confirm_writes_durable(eff)
		for msg in paxos.effects_messages_slice(eff) {
			queue^[queue_count] = msg
			queue_count += 1
		}
		drain_network(nodes, queue, &queue_count, eff)
		for j in 0..<BENCH_MAX_MEMBERS {
			_ = paxos.node_advance_memory_floor(&nodes^[j], paxos.node_decided_through(&nodes^[j]))
		}
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
					queue^[queue_count] = msg
					queue_count += 1
				}
				drain_network(nodes, queue, &queue_count, eff)
				executed += chunk
			}
		} else {
			paxos.effects_init(eff)
			_, err := paxos.node_propose(&nodes^[0], u64(executed + 1000), eff)
			if err == .None {
				paxos.effects_confirm_writes_durable(eff)
				for msg in paxos.effects_messages_slice(eff) {
					queue^[queue_count] = msg
					queue_count += 1
				}
				executed += 1
			}
			if executed % pipelined_window == 0 || executed == iterations {
				drain_network(nodes, queue, &queue_count, eff)
			}
		}

		// Keep memory floor moving to prevent window exhaustion
		decided := paxos.node_decided_through(&nodes^[0])
		if decided > 0 {
			for j in 0..<BENCH_MAX_MEMBERS {
				_ = paxos.node_advance_memory_floor(&nodes^[j], decided)
			}
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
		iterations = 131072,
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

	sync_ops, sync_lat := run_benchmark_mode("sync", cfg.iterations, 1, false)
	pipe8_ops, pipe8_lat := run_benchmark_mode("pipeline8", cfg.iterations, 8, false)
	pipe64_ops, pipe64_lat := run_benchmark_mode("pipeline64", cfg.iterations, 64, false)
	batch16_ops, batch16_lat := run_benchmark_mode("batch16", cfg.iterations, 16, true)
	batch256_ops, batch256_lat := run_benchmark_mode("batch256", cfg.iterations, 256, true)

	if cfg.json_output {
		fmt.println("{")
		fmt.printf("  \"iterations\": %d,\n", cfg.iterations)
		fmt.println("  \"results\": [")
		fmt.printf("    {\"mode\": \"sync\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f},\n", sync_ops, sync_lat)
		fmt.printf("    {\"mode\": \"pipeline8\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f},\n", pipe8_ops, pipe8_lat)
		fmt.printf("    {\"mode\": \"pipeline64\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f},\n", pipe64_ops, pipe64_lat)
		fmt.printf("    {\"mode\": \"batch16\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f},\n", batch16_ops, batch16_lat)
		fmt.printf("    {\"mode\": \"batch256\", \"ops_per_sec\": %.2f, \"avg_latency_ns\": %.2f}\n", batch256_ops, batch256_lat)
		fmt.println("  ]")
		fmt.println("}")
	} else {
		fmt.println("================================================================================")
		fmt.println("  PAXOS-ODIN BENCHMARK (Matching paxos-zig u64-3n workload)")
		fmt.println("  Cluster: 3 nodes | Pure State Machine (In-Memory, Zero OS I/O)")
		fmt.printf("  Values: %d per mode\n", cfg.iterations)
		fmt.println("================================================================================")
		fmt.printf("%-20s %18s %15s %12s\n", "Mode", "Throughput", "Latency / Op", "Values")
		fmt.println("--------------------------------------------------------------------------------")
		fmt.printf("%-20s %12s ops/s %15s %12s\n", "sync", fmt.tprintf("%d", int(sync_ops)), fmt.tprintf("%.1f ns", sync_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.printf("%-20s %12s ops/s %15s %12s\n", "pipeline8", fmt.tprintf("%d", int(pipe8_ops)), fmt.tprintf("%.1f ns", pipe8_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.printf("%-20s %12s ops/s %15s %12s\n", "pipeline64", fmt.tprintf("%d", int(pipe64_ops)), fmt.tprintf("%.1f ns", pipe64_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.printf("%-20s %12s ops/s %15s %12s\n", "batch16", fmt.tprintf("%d", int(batch16_ops)), fmt.tprintf("%.1f ns", batch16_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.printf("%-20s %12s ops/s %15s %12s\n", "batch256", fmt.tprintf("%d", int(batch256_ops)), fmt.tprintf("%.1f ns", batch256_lat), fmt.tprintf("%d", cfg.iterations))
		fmt.println("================================================================================")
	}
}
