#let pod-number = "0003"
#let pod-title = "Durability Contracts, Window Reuse, and Trim Anchors"
#let pod-state = "committed"
#let pod-created = "2026-09-16"
#let pod-discussion = "Formal contract for host persistence barriers and window trimming"
#let pod-labels = ("durability", "storage", "protocol")
#let pod-authors = ("Vikrant Varma <vikrant@insan.ai>", "Paxos Odin Contributors")
#let pod-category = "Protocol Specification"
#let pod-status = "Committed"
#let pod-last-updated = "2026-09-16"

#import "../../shared/pod.typ": pod-document

#show: doc => pod-document(
  pod-number,
  pod-title,
  doc,
  authors: pod-authors,
  state: pod-state,
  created: pod-created,
  discussion: pod-discussion,
  labels: pod-labels,
  category: pod-category,
  status: pod-status,
  last-updated: pod-last-updated,
)

= Abstract

This specification details the durability invariants, host integration rules, and memory garbage collection mechanisms in `paxos-odin`. It formalizes the fundamental *Write-Before-Send* rule, the runtime enforcement gate, the pre-durable pipelining boundary, and log trimming via certified *Trim Anchors*.

= The Core Durability Contract

The entire safety guarantee of Paxos across node crashes and restarts depends on a single rule:

#align(center)[
  #block(
    fill: rgb("f1f5f9"),
    stroke: 1pt + rgb("cbd5e1"),
    inset: 12pt,
    radius: 4pt,
  )[
    *The Durability Rule:* \
    _Persist and sync every record in `Effects.writes` before transmitting any `Effects.messages` from the same operation._
  ]
]

If a node broadcasts a promise or acceptance message over the network before the corresponding write is committed to non-volatile storage, a crash can cause the node to lose its promise or vote. Upon reboot, the node could vote for a different candidate or value, violating Paxos agreement.

= The Runtime Durability Gate

To prevent subtle host-side implementation bugs, `paxos-odin` includes an active runtime gate (`Durability_Gate.Enforced`):
1. Any transition generating writes sets `effects.writes_confirmed = false`.
2. Calling `effects_messages_slice(effects)` while `writes_confirmed == false` immediately aborts the process with the diagnostic:
   ```
   paxos: messages_slice before confirm_writes_durable
   ```
3. Resetting effects without confirming unwritten writes triggers:
   ```
   paxos: reset discarded unconfirmed writes
   ```
4. Only hosts using the audited `host_managed` namespace may bypass this gate.

= Pre-Durable Pipelining

While promises and acceptance confirmations cannot be sent before disk fsync, Phase 2 `Accept` proposals are an exception:
- An `Accept` message asks remote peers to persist a vote; it does not claim that the leader's own vote is durable yet.
- The `effects_pre_durable_messages` iterator yields only `Accept` messages.
- A pipelined leader can transmit `Accept` requests to peers in parallel with its local disk write barrier, overlapping disk and network latencies.

= Window Recycling and Trim Anchors

In a long-running system, 64-bit log slots grow indefinitely, while memory is finite ($W = 256$ slots).

1. *Memory Floor*: The host advances `memory_floor` when committed entries have been journaled or applied to local application snapshots.
2. *Eviction*: A cell is recyclable only if `slot <= memory_floor` and its entry is committed.
3. *Trim Anchors*: A `Trim_Anchor(trim_id, chosen_trim_slot, history_hash)` proves that all slots $<= "chosen_trim_slot"$ were committed. An acceptor with an active trim anchor answers Phase 1 queries with the anchor itself, guaranteeing that empty ring-buffer cells are never misinterpreted as open/undecided slots.

= References

- Lamport, Leslie. "Fast Paxos." Distributed Computing, 2006.
- Paxos-Zig ZDS 0011: Bounded Consensus Window and Anchored Trims.
