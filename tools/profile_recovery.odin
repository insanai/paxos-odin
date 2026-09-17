// CPU profiles for recovery, window reuse, and quiet-leader retransmission.
// Build with -collection:paxos=. and select a scenario as the sole runtime argument.
package profile_recovery

import "core:fmt"
import "core:os"
import "core:time"
import p "paxos:src"

W :: 256
C :: 3
V :: [128]u64
N :: 3
Packet :: struct { envelope: p.Envelope(V), value: V }
Cluster :: struct {
	nodes: [N]p.Node(V, N, W, C),
	e: p.Effects(V, N, W, C),
	queue: [8192]Packet,
	head, count: int,
	consumed: [N]p.Slot,
}

check :: proc(err: p.Error) {
	if err != .None do panic(p.explain_error(err))
}

flush :: proc(c: ^Cluster, node: int) {
	p.confirm_writes_durable(&c.e)
	for entry in p.committed_slice(&c.e) {
		assert(entry.slot == c.consumed[node] + 1)
		assert(entry.value^[0] == entry.slot)
		c.consumed[node] = entry.slot
	}
	for env in p.messages_slice(&c.e) {
		assert(c.count < len(c.queue))
		packet := &c.queue[(c.head + c.count) % len(c.queue)]
		packet.envelope = env
		if v, ok := p.message_value(env.message); ok do packet.value = v^
		c.count += 1
	}
}

drain :: proc(c: ^Cluster) {
	for c.count > 0 {
		packet := &c.queue[c.head]
		env := packet.envelope
		#partial switch &m in env.message {
		case p.Promise_Message(V): m.value = &packet.value
		case p.Accept_Message(V): m.value = &packet.value
		case p.Commit_Message(V): m.value = &packet.value
		}
		index := int(env.to - 1)
		check(p.step(&c.nodes[index], env, &c.e))
		c.head = (c.head + 1) % len(c.queue)
		c.count -= 1
		flush(c, index)
	}
}

initialize :: proc(c: ^Cluster, recovery: bool) {
	m: p.Membership(N)
	ids := [N]p.Node_Id{1, 2, 3}
	check(p.init(&m, ids[:]))
	for &node, i in c.nodes {
		check(p.init(&node, ids[i], m))
		if recovery {
			for slot in 1..=W {
				v := V{0 = u64(slot)}
				w := p.Write_Vote(V){ballot = p.ballot_make(1, 0, 2), slot = p.Slot(slot), value = &v}
				check(p.ledger_apply(&node.ledger, p.Write(V)(w)))
			}
		}
	}
}

measured_epoch :: #force_no_inline proc(c: ^Cluster, scenario: string) {
	if scenario == "recovery" {
		check(p.campaign(&c.nodes[0], V{}, &c.e))
		flush(c, 0)
		drain(c)
		for &node in c.nodes do assert(p.decided_through(&node) == W)
		return
	}
	for slot in 1..=2 * W {
		_, err := p.propose(&c.nodes[0], V{0 = u64(slot)}, &c.e)
		check(err)
		flush(c, 0)
		drain(c)
		if scenario == "resend" {
			for _ in 0..<10 {
				check(p.tick(&c.nodes[0], V{}, &c.e))
				flush(c, 0)
				drain(c)
			}
		}
		for &node, i in c.nodes do check(p.advance_memory_floor(&node, c.consumed[i]))
	}
}

main :: proc() {
	assert(len(os.args) == 2, "Hint: Pass recovery, moving, or resend.")
	scenario := os.args[1]
	assert(scenario == "recovery" || scenario == "moving" || scenario == "resend")
	c := new(Cluster)
	defer free(c)
	initialize(c, scenario == "recovery")
	if scenario != "recovery" {
		check(p.campaign(&c.nodes[0], V{}, &c.e))
		flush(c, 0)
		drain(c)
	}
	start := time.now()
	measured_epoch(c, scenario)
	ns := time.duration_seconds(time.since(start)) * 1e9
	fmt.printf("%s%.0f%s\n", "{\"ns_total\":", ns, ",\"validated\":true}")
	fmt.println("Validated", scenario)
}
