#let pod-number = "0002"
#let pod-title = "Paxos-Odin: Architecture and Pure State Machine Design"
#let pod-state = "committed"
#let pod-created = "2026-09-16"
#let pod-discussion = "Complete architectural specification of the idiomatic Odin Paxos core"
#let pod-labels = ("architecture", "consensus", "odin")
#let pod-authors = ("Vikrant Varma <vikrant@insan.ai>", "Paxos Odin Contributors")
#let pod-category = "Architectural Specification"
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

This document specifies the architecture of `paxos-odin`: a pure, bounded implementation of Classic and Multi-Paxos written in idiomatic Odin. The core library performs zero I/O, owns no OS threads or clocks, and performs no runtime heap allocation. All side effects are returned explicitly to the host caller through pre-allocated `Effects` buffers.

= Architecture Overview

Traditional consensus libraries bundle network runtimes, disk I/O threads, and RPC protocols together with algorithmic logic. This tight coupling makes testing under adversarial conditions difficult and obscures algorithmic invariants.

`paxos-odin` decouples consensus logic completely:
1. *Deterministic Inputs*: The host delivers events via `node_step(node, envelope, effects)`, `node_propose(node, val, effects)`, or `node_tick(node, noop, effects)`.
2. *Pure Transitions*: The state machine updates its internal ring-buffer cells and bitsets deterministically.
3. *Explicit Output Effects*: The transition populates caller-owned buffers:
   - `writes`: WAL delta records (`Promise`, `Accept`, `Commit`, `TrimAnchor`).
   - `messages`: Outbound network messages addressed to cluster members.
   - `committed`: Newly decided log entries released in contiguous slot order.
   - `requests`: Catch-up queries for history below the memory floor.

= Core Data Structures

== Ballot Representation
A ballot is a tuple `(round: u64, priority: u32, node: NodeId)` with a total lexicographic order:
```odin
ballot_less_than :: proc(a, b: Ballot) -> bool {
    if a.round < b.round do return true
    if a.round > b.round do return false
    if a.priority < b.priority do return true
    if a.priority > b.priority do return false
    return a.node < b.node
}
```

== Ring-Buffer Window
Unresolved and locally cached consensus cells are mapped via `(slot - 1) % WINDOW_SLOTS`. Old slots are evictable once their slot index is at or below the `memory_floor` and their entry has committed.

== Fixed Bitsets for Quorum Accounting
Rather than allocating dynamically, membership quorums and phase-two acknowledgments use fixed-size bitsets (`Bit_Set(N)`). Majority checks take $O(1)$ via single-cycle population count (`bits.count_ones`).

= Reconfigurable Command Log

The `Replicated_Log_Node` layers a command log on top of the consensus core. It allows application commands to interleave with configuration change records called *Stop Signs*:
- Proposing a Stop Sign sets `stop_pending = true`.
- Once committed, the stop sign seals the epoch.
- Any subsequent proposals are rejected with `Error.LogSealed`.
- The host captures application state and starts the next configuration epoch cleanly.

= Verification Strategy

Correctness is validated through three distinct layers:
1. *Unit Test Suite*: Exercising quorum validation, ballot comparisons, and single-node/three-node consensus.
2. *Deterministic Simulator*: Chaos fixture injecting message drops, duplications, partitions, crashes, and restarts against a golden oracle.
3. *In-Memory Workload Benchmark*: Verifying sub-microsecond latency and millions of proposals per second across synchronous, pipelined, and batched workloads.

= References

- Lamport, Leslie. "Paxos Made Simple." ACM SIGACT News, 2001.
- Ongaro, Diego and Ousterhout, John. "In Search of an Understandable Consensus Algorithm." USENIX ATC, 2014.
