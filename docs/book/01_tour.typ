= A Tour of the Pure State Machine

== The Problem of State Machine Replication

Suppose you have three independent computers connected by an unreliable asynchronous network. You want them to agree on an append-only log of commands, in identical order, without ever diverging.

Machines can crash and reboot with stale memory. Packets can be lost, duplicated, delayed, or reordered arbitrarily. Two distinct nodes may both believe they are the legitimate leader simultaneously. And yet, under all these conditions, no two nodes must ever commit different values for the same slot.

== The Pure State Machine Paradigm

Most distributed libraries open sockets, spawn threads, query system clocks, and write files directly. When an unexpected edge case occurs in production, debugging requires reproducing complex asynchronous thread interleavings and operating system timings.

`paxos-odin` rejects this model entirely:

```
                  +----------------------------------+
                  |         Host Application         |
                  +----------------------------------+
                        |                      ^
    Envelope / Proposal |                      | Effects (writes,
    or Logical Tick     v                      |          messages,
                  +----------------------------------+    commits)
                  |     Paxos-Odin State Machine     |
                  +----------------------------------+
```

1. *Deterministic Inputs*: The host feeds an event:
   - `node_step(node, envelope, effects)`
   - `node_propose(node, value, effects)`
   - `node_tick(node, noop, effects)`
2. *Pure Transitions*: The state machine transitions internal records in $O(1)$ time without allocating from the OS heap.
3. *Explicit Effects*: The output buffer receives:
   - `writes`: WAL deltas to write to disk.
   - `messages`: Wire envelopes to transmit over the network.
   - `committed`: Application decisions ready for consumption.

== The Single Golden Rule

Everything in Paxos durability hinges on one rule:

#align(center)[
  #block(
    fill: rgb("eff6ff"),
    stroke: 1pt + rgb("93c5fd"),
    inset: 12pt,
    radius: 4pt,
  )[
    *Persist every `Effects.writes` record before transmitting any `Effects.messages` record from the same transition.*
  ]
]

Every build mode enforces this rule at runtime. If a host attempts to read `effects_messages_slice` without calling `effects_confirm_writes_durable`, the process halts immediately with an Elm-style diagnostic.
