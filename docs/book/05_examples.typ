#import "theme.typ": *
#import "figures.typ": *

#part_page("V", [Three worked systems], [
  We step through the runnable three-node counter, design a fault-tolerant
  key-value store, and inspect a multi-region deployment architecture.
])

= Three Worked Systems

#objectives([
  By the end of this chapter you should be able to implement an end-to-end consensus
  event loop in Odin, integrate a persistent key-value state machine, enforce request
  deduplication, and design a partitioned multi-shard consensus cluster.
])

== Example 1: The Three-Node Replicated Counter

To see `paxos-odin` in action, we construct a complete, self-contained replicated
counter running across three in-memory nodes.

=== 1. Defining the Application Command

#code_file("examples/counter.odin", [
```odin
package main

import "core:fmt"
import paxos "../src"

Command :: struct {
	client_id:  u32,
	request_id: u32,
	amount:     i64,
}

CLUSTER_SIZE :: 3
WINDOW_SIZE  :: 64

Counter_Node :: paxos.Node(Command, CLUSTER_SIZE, WINDOW_SIZE)
Counter_Eff  :: paxos.Effects(Command, CLUSTER_SIZE, WINDOW_SIZE)
```
])

=== 2. Cluster Setup and Leader Election

We initialize three nodes and trigger node 1's campaign to become the stable leader:

#code_file("examples/counter.odin", [
```odin
main :: proc() {
	m: paxos.Membership(CLUSTER_SIZE)
	ids := [CLUSTER_SIZE]paxos.NodeId{1, 2, 3}
	paxos.membership_init(&m, ids[:])

	nodes: [CLUSTER_SIZE]Counter_Node
	for i in 0..<CLUSTER_SIZE {
		paxos.node_init_with_priority(&nodes[i], ids[i], m, u32(i))
	}

	eff: Counter_Eff
	paxos.effects_init(&eff)

	// Node 1 campaigns for leadership
	paxos.node_campaign(&nodes[0], 0, &eff)
	drain_cluster(&nodes, &eff)
	fmt.println("Node 1 successfully established as Multi-Paxos leader!")
}
```
])

=== 3. The Core Event Loop and Effect Draining

Whenever a proposal is issued, the host drains generated effects:

#code_file("examples/counter.odin", [
```odin
drain_cluster :: proc(nodes: ^[CLUSTER_SIZE]Counter_Node, eff: ^Counter_Eff) {
	// 1. Persist durable writes to disk
	paxos.effects_confirm_writes_durable(eff)

	// 2. Deliver outbound network messages to peer nodes
	for env in paxos.effects_messages_slice(eff) {
		to_idx := int(env.to - 1)
		child_eff: Counter_Eff
		paxos.effects_init(&child_eff)

		err := paxos.node_step(&nodes[to_idx], env, &child_eff)
		if err == .None {
			drain_cluster(nodes, &child_eff)
		}
	}

	// 3. Apply newly committed decrees to the state machine
	for c in paxos.effects_committed_slice(eff) {
		fmt.printf("Committed slot %d: adding %d\n", c.slot, c.value.amount)
	}
}
```
])

=== 4. Proposing Commands

With node 1 as leader, subsequent commands commit in 1 RTT:

```odin
paxos.node_propose(&nodes[0], Command{client_id = 1, request_id = 101, amount = 10}, &eff)
drain_cluster(&nodes, &eff)

paxos.node_propose(&nodes[0], Command{client_id = 1, request_id = 102, amount = 25}, &eff)
drain_cluster(&nodes, &eff)
```

All three nodes converge on the exact same committed sequence: counter = 35.

== Example 2: A Key-Value Host Design

In a production key-value service, the consensus engine orders operations, while
the host application handles storage, deduplication, and read semantics:

1. *Exactly-Once Execution*: The client attaches a `client_id` and monotonic `sequence_id`.
   The state machine maintains a table of `last_seen_sequence[client_id]`. If a retry
   arrives, the state machine returns the cached result without re-executing.
2. *Linearizable Reads (Leases)*: Read requests do not need to pass through the log
   if the leader holds an active leader lease verified by majority heartbeat ticks.
   Otherwise, the leader issues a lightweight Phase 2 commit to determine the current
   linearizable read watermark.
3. *Snapshotting*: Periodically, the key-value store flushes its database to an SSTable
   or RocksDB snapshot, records a `Trim_Anchor` in `paxos-odin`, and advances the log floor.

== Example 3: Multi-Region Deployment Architecture

For high availability across cloud regions:
- A 5-node cluster is deployed across 3 availability zones: Zone A (2 nodes), Zone B (2 nodes), Zone C (1 node).
- Any single zone failure leaves at least 3 nodes active, maintaining a majority quorum.
- Network partitions are resolved automatically without human intervention.
