package matched

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import p "paxos:src"

Payload :: [#config(PAYLOAD_WORDS, 1)]u64
N :: #config(MEMBERS, 3)
W :: 4096
C :: 256
CAP :: 8192
Packet :: struct { envelope: p.Envelope(Payload), value: Payload }
Cluster :: struct {
	nodes: [N]p.Node(Payload, N, W, C),
	e: p.Effects(Payload, N, W, C),
	queue: [CAP]Packet,
	count: int,
	messages: u64,
}

value_of :: proc(seq: u64) -> (v: Payload) {
	v[0] = seq
	return
}

check :: proc(err: p.Error) {
	if err != .None do panic(p.explain_error(err))
}

flush :: proc(c: ^Cluster) {
	p.confirm_writes_durable(&c.e)
	for envelope in p.messages_slice(&c.e) {
		if c.count == CAP do panic("Queue full. Hint: Increase matched queue capacity.")
		packet := &c.queue[c.count]
		packet.envelope = envelope
		if v, ok := p.message_value(envelope.message); ok do packet.value = v^
		c.count += 1
		c.messages += 1
	}
}

drain :: proc(c: ^Cluster) {
	for head := 0; head < c.count; head += 1 {
		packet := &c.queue[head]
		env := packet.envelope
		#partial switch &m in env.message {
		case p.Promise_Message(Payload): m.value = &packet.value
		case p.Accept_Message(Payload): m.value = &packet.value
		case p.Commit_Message(Payload): m.value = &packet.value
		}
		check(p.step(&c.nodes[env.to - 1], env, &c.e))
		flush(c)
	}
	c.count = 0
}

// Stable symbol for Callgrind collection. Includes completion, excludes setup/validation.
drive_epoch :: proc(c: ^Cluster, depth: int) {
	for first := 1; first <= W; first += depth {
		for seq in first..<min(first + depth, W + 1) {
			_, err := p.propose(&c.nodes[0], value_of(u64(seq)), &c.e)
			check(err)
			flush(c)
		}
		drain(c)
	}
}

measured_epoch :: #force_no_inline proc(c: ^Cluster, depth: int) { drive_epoch(c, depth) }

epoch :: proc(depth: int, warmup := false) -> (f64, u64) {
	c := new(Cluster)
	defer free(c)
	m: p.Membership(N)
	ids: [N]p.Node_Id
	for &id, i in ids do id = p.Node_Id(i + 1)
	check(p.init(&m, ids[:]))
	for &node, i in c.nodes do check(p.init(&node, ids[i], m))
	check(p.campaign(&c.nodes[0], Payload{}, &c.e))
	flush(c)
	drain(c)
	c.messages = 0
	start := time.now()
	if warmup { drive_epoch(c, depth) } else { measured_epoch(c, depth) }
	ns := time.duration_seconds(time.since(start)) * 1e9
	for &node in c.nodes {
		assert(p.decided_through(&node) == W)
		for slot in 1..=W {
			v, ok := p.committed_at(&node, p.Slot(slot))
			assert(ok && v == value_of(u64(slot)), "Invalid delivery. Hint: Inspect the matched trace.")
		}
	}
	return ns, c.messages
}

main :: proc() {
	assert(len(os.args) == 3, "Hint: Pass pipeline depth and epoch count.")
	depth, ok := strconv.parse_int(os.args[1])
	assert(ok && (depth == 1 || depth == 8 || depth == 64))
	epochs, valid := strconv.parse_int(os.args[2])
	assert(valid && epochs > 0)
	epoch(depth, true) // Separate warm-up cluster.
	total: f64
	messages: u64
	for _ in 0..<epochs {
		ns, count := epoch(depth)
		total += ns
		messages += count
	}
	fmt.printf("%s%.0f%s%d%s%d", "{\"ns_total\":", total,
		",\"messages\":", messages, ",\"values\":", W * epochs)
	fmt.printf("%s%d%s%d%s%d%s\n", ",\"node_inline_bytes\":", size_of(p.Node(Payload, N, W, C)),
		",\"effects_inline_bytes\":", size_of(p.Effects(Payload, N, W, C)),
		",\"driver_capacity_bytes\":", size_of(Cluster), ",\"validated\":true}")
}
