// The in-memory benchmark: cost per committed value with an in-process transport and
// no serialisation. Workloads mirror the sibling harnesses so results can sit in one
// table: three or five voters, 8-byte or 1 KiB values, synchronous, pipelined, or
// batched proposals. Run with --durable for the journal-and-fsync modes.
package paxos_bench

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import paxos "../src"

BENCH_WINDOW    :: 4096
BENCH_CHUNK     :: 256
BENCH_QUEUE_CAP :: 32768
SAMPLE_COUNT    :: 5

// A one-kibibyte value.
Blob :: [128]u64

Benchmark_Config :: struct {
	iterations:  int,
	json_output: bool,
	durable:     bool,
	journal_dir: string,
	// Run only this workload (for profiling); empty means all.
	only:        string,
}

Result :: struct {
	impl:            string,
	workload:        string,
	mode:            string,
	nodes:           int,
	payload_bytes:   int,
	values:          int,
	ops_per_sec:     f64,
	ns_per_value:    f64,
	syncs_per_value: f64,
}

// An envelope in flight with its value copied out, as a codec would do.
Packet :: struct($Value: typeid) {
	envelope: paxos.Envelope(Value),
	value:    Value,
}

packet_of :: proc(envelope: paxos.Envelope($Value)) -> (packet: Packet(Value)) {
	packet.envelope = envelope
	if value, carries := paxos.message_value(envelope.message); carries do packet.value = value^
	return
}

packet_envelope :: proc(packet: ^Packet($Value)) -> paxos.Envelope(Value) {
	envelope := packet.envelope
	#partial switch &m in envelope.message {
	case paxos.Promise_Message(Value): m.value = &packet.value
	case paxos.Accept_Message(Value):  m.value = &packet.value
	case paxos.Commit_Message(Value):  m.value = &packet.value
	}
	return envelope
}

Cluster :: struct($Value: typeid, $N: int) {
	ownership:   bool,
	nodes:       [N]paxos.Node(Value, N, BENCH_WINDOW, BENCH_CHUNK),
	queue:       [BENCH_QUEUE_CAP]Packet(Value),
	queue_count: int,
	effects:     paxos.Effects(Value, N, BENCH_WINDOW, BENCH_CHUNK),
}

make_value :: proc($Value: typeid, i: int) -> Value {
	when Value == u64 {
		return u64(i)
	} else {
		return Value{0 = u64(i)}
	}
}

cluster_init :: proc(c: ^Cluster($Value, $N), ownership: bool) {
	c.ownership = ownership
	ids: [N]paxos.Node_Id
	for &id, i in ids do id = paxos.Node_Id(i + 1)
	m: paxos.Membership(N)
	// Asserts must never wrap a call with side effects: -disable-assert would drop the call.
	init_err := paxos.init(&m, ids[:])
	assert(init_err == .None)
	for &node, i in c.nodes {
		options := paxos.Node_Options{priority = u8(i), rotating_ownership = ownership}
		node_err := paxos.init(&node, ids[i], m, options)
		assert(node_err == .None)
	}
	if ownership do return
	campaign_err := paxos.campaign(&c.nodes[0], make_value(Value, 0), &c.effects)
	assert(campaign_err == .None)
	cluster_flush(c)
	cluster_drain(c)
	assert(paxos.role(&c.nodes[0]) == .Leader, "node 1 must lead")
}

// The host commit sequence with a no-op journal: confirm, then queue the messages.
cluster_flush :: proc(c: ^Cluster($Value, $N)) {
	paxos.confirm_writes_durable(&c.effects)
	for envelope in paxos.messages_slice(&c.effects) {
		if c.queue_count < BENCH_QUEUE_CAP {
			c.queue[c.queue_count] = packet_of(envelope)
			c.queue_count += 1
		}
	}
}

cluster_drain :: proc(c: ^Cluster($Value, $N)) {
	head := 0
	for head < c.queue_count {
		envelope := packet_envelope(&c.queue[head])
		head += 1
		to := int(envelope.to - 1)
		if paxos.step(&c.nodes[to], envelope, &c.effects) == .None do cluster_flush(c)
	}
	c.queue_count = 0
	decided := paxos.decided_through(&c.nodes[0])
	for &node in c.nodes {
		_ = paxos.advance_memory_floor(&node, min(decided, paxos.decided_through(&node)))
	}
}

// Proposes `depth` values one at a time, then delivers everything. Under rotating
// ownership the proposals go round-robin to every owner.
propose_pipelined :: proc(c: ^Cluster($Value, $N), first, depth: int) {
	for i in 0..<depth {
		proposer := (first + i) % N if c.ownership else 0
		_, err := paxos.propose(&c.nodes[proposer], make_value(Value, first + i), &c.effects)
		assert(err == .None, paxos.explain_error(err))
		cluster_flush(c)
	}
	cluster_drain(c)
}

// Proposes `depth` values as one batch, then delivers everything.
propose_batched :: proc(c: ^Cluster($Value, $N), first, depth: int) {
	values: [BENCH_CHUNK]Value
	slots: [BENCH_CHUNK]paxos.Slot
	for i in 0..<depth do values[i] = make_value(Value, first + i)
	_, err := paxos.propose_batch(&c.nodes[0], values[:depth], slots[:depth], &c.effects)
	assert(err == .None, paxos.explain_error(err))
	cluster_flush(c)
	cluster_drain(c)
}

run_sample :: proc(
	$Value: typeid,
	$N: int,
	iterations, window: int,
	batched, ownership: bool,
) -> f64 {
	c := new(Cluster(Value, N))
	defer free(c)
	cluster_init(c, ownership)
	propose_pipelined(c, 1000, 50) // warm-up

	start := time.now()
	executed := 0
	for executed < iterations {
		depth := min(window, iterations - executed)
		if batched {
			propose_batched(c, executed + 1000, depth)
		} else {
			propose_pipelined(c, executed + 1000, depth)
		}
		executed += depth
	}
	return time.duration_seconds(time.since(start)) * 1e9 / f64(iterations)
}

// Median of SAMPLE_COUNT runs, in nanoseconds per committed value.
run_mode :: proc(
	$Value: typeid,
	$N: int,
	iterations, window: int,
	batched: bool,
	ownership := false,
) -> f64 {
	samples: [SAMPLE_COUNT]f64
	for &sample in samples do sample = run_sample(Value, N, iterations, window, batched, ownership)
	slice.sort(samples[:])
	return samples[SAMPLE_COUNT / 2]
}

Mode :: struct {
	name:    string,
	window:  int,
	batched: bool,
}

record :: proc(
	results: ^[dynamic]Result,
	workload: string,
	mode: Mode,
	nodes,
	payload,
	values: int,
	ns: f64,
) {
	append(results, Result{
		impl = "paxos-odin", workload = workload, mode = mode.name, nodes = nodes,
		payload_bytes = payload, values = values, ops_per_sec = 1e9 / ns, ns_per_value = ns,
	})
}

run_workloads :: proc(results: ^[dynamic]Result, iterations: int, only: string) {
	u64_3n := [?]Mode{{"sync", 1, false}, {"pipeline8", 8, false}, {"pipeline64", 64, false},
	                  {"batch16", 16, true}, {"batch256", 256, true}}
	for mode in u64_3n {
		if only != "" && only != "u64-3n" do break
		ns := run_mode(u64, 3, iterations, mode.window, mode.batched)
		record(results, "u64-3n", mode, 3, 8, iterations, ns)
	}
	five := max(iterations / 2, 64)
	for mode in ([?]Mode{{"sync", 1, false}, {"pipeline8", 8, false}}) {
		if only != "" && only != "u64-5n" do break
		record(results, "u64-5n", mode, 5, 8, five, run_mode(u64, 5, five, mode.window, mode.batched))
	}
	for mode in ([?]Mode{{"sync", 1, false}, {"pipeline8", 8, false}}) {
		if only != "" && only != "owned-3n" do break
		ns := run_mode(u64, 3, iterations, mode.window, mode.batched, ownership = true)
		record(results, "owned-3n", mode, 3, 8, iterations, ns)
	}
	blob := max(iterations / 8, 64)
	for mode in ([?]Mode{{"sync", 1, false}, {"pipeline8", 8, false}}) {
		if only != "" && only != "blob1k-3n" do break
		record(results, "blob1k-3n", mode, 3, size_of(Blob), blob,
			run_mode(Blob, 3, blob, mode.window, mode.batched))
	}
}

run_durable_workloads :: proc(
	results: ^[dynamic]Result,
	iterations: int,
	directory: string,
) -> bool {
	durable_iterations := max(iterations / 64, 64)
	for mode in ([?]Mode{{"durable-sync", 1, false}, {"durable-pipeline8", 8, false}}) {
		ns, syncs, ok := run_durable_sample(durable_iterations, mode.window, directory)
		if !ok do return false
		append(results, Result{
			impl = "paxos-odin", workload = "u64-3n-durable", mode = mode.name, nodes = 3,
			payload_bytes = 8, values = durable_iterations, ops_per_sec = 1e9 / ns,
			ns_per_value = ns, syncs_per_value = syncs,
		})
	}
	return true
}

parse_config :: proc() -> (cfg: Benchmark_Config) {
	cfg = {iterations = 131072, journal_dir = "."}
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--iterations=") {
			if value, ok := strconv.parse_int(strings.trim_prefix(arg, "--iterations=")); ok {
				cfg.iterations = value
			}
		} else if strings.has_prefix(arg, "--journal-dir=") {
			cfg.journal_dir = strings.trim_prefix(arg, "--journal-dir=")
		} else if arg == "--json" {
			cfg.json_output = true
		} else if arg == "--durable" {
			cfg.durable = true
		} else if strings.has_prefix(arg, "--only=") {
			cfg.only = strings.trim_prefix(arg, "--only=")
		}
	}
	if cfg.iterations <= 0 {
		fmt.eprintln(
			"-- INVALID ITERATION COUNT --\n\nA benchmark needs at least one operation.\n" +
			"Hint: Pass a positive count, for example --iterations=1024.",
		)
		os.exit(1)
	}
	return
}

print_table :: proc(results: []Result, iterations: int) {
	fmt.println("================================================================================")
	fmt.println("  PAXOS-ODIN BENCHMARK  (in-process transport, no serialisation)")
	fmt.printf("  Values in the u64-3n modes: %d; other workloads scale down proportionally\n", iterations)
	fmt.println("================================================================================")
	fmt.printf("%-12s %-18s %6s %8s %12s %14s\n",
		"Workload", "Mode", "Nodes", "Values", "ns / value", "fsync / value")
	fmt.println("--------------------------------------------------------------------------------")
	for r in results {
		syncs := "-" if r.syncs_per_value == 0 else fmt.tprintf("%.2f", r.syncs_per_value)
		fmt.printf("%-12s %-18s %6d %8d %12s %14s\n", r.workload, r.mode, r.nodes, r.values,
			fmt.tprintf("%.1f", r.ns_per_value), syncs)
	}
	fmt.println("================================================================================")
}

main :: proc() {
	cfg := parse_config()
	results: [dynamic]Result
	defer delete(results)

	run_workloads(&results, cfg.iterations, cfg.only)
	if cfg.durable && !run_durable_workloads(&results, cfg.iterations, cfg.journal_dir) do os.exit(1)

	if !cfg.json_output {
		print_table(results[:], cfg.iterations)
		return
	}
	report := struct {iterations: int, results: []Result}{cfg.iterations, results[:]}
	data, err := json.marshal(report)
	defer delete(data)
	if err != nil {
		fmt.eprintln("Cannot encode benchmark results:", err)
		os.exit(1)
	}
	fmt.println(string(data))
}
