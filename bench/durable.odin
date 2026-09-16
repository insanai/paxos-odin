// The durable benchmark: the same three-voter workload with every node appending its
// effects.writes to a journal file and issuing one storage barrier (fsync) per host
// commit round before its messages leave. It measures what safety costs once the
// disk, not the protocol, sets the pace.
package paxos_bench

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import paxos "../src"

BENCH_MAX_MEMBERS :: 3
Bench_Node    :: paxos.Node(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW, BENCH_CHUNK)
Bench_Effects :: paxos.Effects(u64, BENCH_MAX_MEMBERS, BENCH_WINDOW, BENCH_CHUNK)

Durable_Host :: struct {
	journals: [BENCH_MAX_MEMBERS]^os.File,
	pending:  [BENCH_MAX_MEMBERS][dynamic]Packet(u64),
	dirty:    bit_set[0..<BENCH_MAX_MEMBERS],
	syncs:    int,
}

durable_open :: proc(host: ^Durable_Host, directory: string) -> bool {
	for &journal, i in host.journals {
		path := fmt.tprintf("%s/paxos-bench-journal-%d.log", directory, i + 1)
		file, err := os.open(path, {.Write, .Create, .Trunc})
		if err != nil {
			fmt.eprintfln("-- CANNOT OPEN JOURNAL --\n\n%s: %v.\n\n" +
				"Hint: Pass a writable directory with --journal-dir=PATH.", path, err)
			return false
		}
		journal = file
	}
	return true
}

durable_close :: proc(host: ^Durable_Host, directory: string) {
	for journal, i in host.journals {
		if journal != nil do os.close(journal)
		os.remove(fmt.tprintf("%s/paxos-bench-journal-%d.log", directory, i + 1))
		delete(host.pending[i])
	}
}

// Appends the batch's writes to the node's journal and parks its messages until the
// next barrier. The journal format is the raw record image; it is a cost model, not a codec.
durable_stage :: proc(host: ^Durable_Host, node: int, effects: ^Bench_Effects) {
	for &w in paxos.writes_slice(effects) {
		// The record image plus the value it references: the shape a real codec writes.
		_, err := os.write(host.journals[node], mem.ptr_to_bytes(&w))
		assert(err == nil, "journal append failed")
		#partial switch x in w {
		case paxos.Write_Vote(u64):   _, err = os.write(host.journals[node], mem.ptr_to_bytes(x.value))
		case paxos.Write_Chosen(u64): _, err = os.write(host.journals[node], mem.ptr_to_bytes(x.value))
		}
		assert(err == nil, "journal append failed")
		host.dirty += {node}
	}
	// The contract permits accept requests to leave before the barrier; this host
	// keeps the simpler rule and sends everything after the sync.
	paxos.confirm_writes_durable(effects)
	for envelope in paxos.messages_slice(effects) do append(&host.pending[node], packet_of(envelope))
}

// One storage barrier per dirty journal, then every parked message may leave.
durable_barrier :: proc(
	host: ^Durable_Host,
	queue: ^[BENCH_QUEUE_CAP]Packet(u64),
	queue_count: ^int,
) {
	for node in 0..<BENCH_MAX_MEMBERS {
		if node in host.dirty {
			flush_err := os.flush(host.journals[node])
			assert(flush_err == nil, "fsync failed")
			host.syncs += 1
		}
		for packet in host.pending[node] {
			if queue_count^ < BENCH_QUEUE_CAP {
				queue^[queue_count^] = packet
				queue_count^ += 1
			}
		}
		clear(&host.pending[node])
	}
	host.dirty = {}
}

// Delivers every queued envelope; each round of deliveries ends with one barrier.
durable_drain :: proc(
	host: ^Durable_Host,
	nodes: ^[BENCH_MAX_MEMBERS]Bench_Node,
	queue: ^[BENCH_QUEUE_CAP]Packet(u64),
	queue_count: ^int,
	effects: ^Bench_Effects,
) {
	for queue_count^ > 0 {
		round := queue_count^
		for head in 0..<round {
			envelope := packet_envelope(&queue^[head])
			to := int(envelope.to - 1)
			if paxos.step(&nodes^[to], envelope, effects) == .None {
				durable_stage(host, to, effects)
			}
		}
		// Shift out the delivered round; messages produced by it were parked, not queued.
		queue_count^ = 0
		durable_barrier(host, queue, queue_count)
	}
}

run_durable_sample :: proc(
	iterations: int,
	window: int,
	directory: string,
) -> (avg_latency_ns: f64, syncs_per_value: f64, ok: bool) {
	host: Durable_Host
	if !durable_open(&host, directory) do return 0, 0, false
	defer durable_close(&host, directory)

	m: paxos.Membership(BENCH_MAX_MEMBERS)
	ids := [BENCH_MAX_MEMBERS]paxos.Node_Id{1, 2, 3}
	_ = paxos.init(&m, ids[:])
	nodes := new([BENCH_MAX_MEMBERS]Bench_Node)
	defer free(nodes)
	for &node, i in nodes do _ = paxos.init(&node, ids[i], m, paxos.Node_Options{priority = u8(i)})
	queue := new([BENCH_QUEUE_CAP]Packet(u64))
	defer free(queue)
	queue_count := 0
	effects := new(Bench_Effects)
	defer free(effects)

	_ = paxos.campaign(&nodes[0], 0, effects)
	durable_stage(&host, 0, effects)
	durable_barrier(&host, queue, &queue_count)
	durable_drain(&host, nodes, queue, &queue_count, effects)
	assert(paxos.role(&nodes[0]) == .Leader)
	host.syncs = 0

	start := time.now()
	executed := 0
	for executed < iterations {
		depth := min(window, iterations - executed)
		for i in 0..<depth {
			_, err := paxos.propose(&nodes[0], u64(executed + i + 1000), effects)
			assert(err == .None)
			durable_stage(&host, 0, effects)
		}
		durable_barrier(&host, queue, &queue_count)
		durable_drain(&host, nodes, queue, &queue_count, effects)
		executed += depth
		decided := paxos.decided_through(&nodes[0])
		for &node in nodes {
			_ = paxos.advance_memory_floor(&node, min(decided, paxos.decided_through(&node)))
		}
	}
	elapsed := time.duration_seconds(time.since(start))
	return elapsed * 1e9 / f64(iterations), f64(host.syncs) / f64(iterations), true
}
