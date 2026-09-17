// Native baseline for the paxodin four-path measurement.
//
// It drives the same workload the Python paths drive: one member, a full batch
// lifecycle per value, no network and no storage. Build with
// -collection:paxos=. and pass iterations and payload bytes as arguments.
package paxodin_native_bench

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import p "paxos:src"

MAX_VALUE :: 1024
WINDOW    :: 256
CHUNK     :: 64
MEMBERS   :: 1

Command :: struct {
	kind:     u8,
	reserved: [3]u8,
	length:   u32,
	body:     [MAX_VALUE]u8,
}

Entry   :: p.Entry(Command, MEMBERS, p.DEFAULT_MAX_METADATA_BYTES)
Node    :: p.Replicated_Log_Node(Command, MEMBERS, WINDOW, CHUNK, p.DEFAULT_MAX_METADATA_BYTES)
Effects :: p.Effects(Entry, MEMBERS, WINDOW, CHUNK)

check :: proc(err: p.Error) {
	if err != .None {
		fmt.eprintln(p.explain_error(err))
		os.exit(1)
	}
}

// The host commit sequence, matching what the Python session runs: persist,
// confirm, release, send. Storage and transport are omitted in every path.
drain :: proc(node: ^Node, effects: ^Effects, queue: ^[dynamic]p.Envelope(Entry)) -> (released: int) {
	for w in p.writes_slice(effects) do _ = w
	p.confirm_writes_durable(effects)
	for c in p.committed_slice(effects) {
		released += 1
		_ = c.value^
	}
	for envelope in p.messages_slice(effects) do append(queue, envelope)
	return released
}

main :: proc() {
	iterations := 100_000
	payload := 64
	if len(os.args) > 1 do iterations, _ = strconv.parse_int(os.args[1])
	if len(os.args) > 2 do payload, _ = strconv.parse_int(os.args[2])

	node := new(Node)
	effects := new(Effects)
	defer free(node)
	defer free(effects)

	membership: p.Membership(MEMBERS)
	check(p.membership_init(&membership, []p.Node_Id{1}))
	check(p.log_init(node, 1, 1, membership))

	noop := Command{kind = 2}
	queue := make([dynamic]p.Envelope(Entry), 0, 64)
	defer delete(queue)

	check(p.log_campaign(node, noop, effects))
	_ = drain(node, effects, &queue)
	for len(queue) > 0 {
		envelope := pop_front(&queue)
		check(p.step(node, envelope, effects))
		_ = drain(node, effects, &queue)
	}
	if p.role(node) != .Leader {
		fmt.eprintln("did not become leader")
		os.exit(1)
	}

	value := Command{kind = 1, length = u32(payload)}
	for index in 0 ..< payload do value.body[index] = u8(index)

	released := 0
	start := time.now()
	for _ in 0 ..< iterations {
		_, err := p.log_propose(node, value, effects)
		check(err)
		released += drain(node, effects, &queue)
		for len(queue) > 0 {
			envelope := pop_front(&queue)
			check(p.step(node, envelope, effects))
			released += drain(node, effects, &queue)
		}
		check(p.log_advance_memory_floor(node, p.log_decided_through(node)))
	}
	elapsed := time.duration_nanoseconds(time.since(start))

	fmt.printf(
		`{{"path":"native","iterations":%d,"payload_bytes":%d,"released":%d,"ns_total":%d,"ns_per_value":%f,"validated":true}}` + "\n",
		iterations, payload, released, elapsed, f64(elapsed) / f64(iterations),
	)
}
