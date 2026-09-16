#import "theme.typ": *
#import "figures.typ": *

#part_page("VI", [Evidence], [
  We separate mathematical proof obligations, deterministic unit tests, chaos
  simulation, and microsecond benchmarks. Each answers a different question.
])

= Validation, Testing, and Operations

#objectives([
  By the end of this chapter you should be able to design a deterministic chaos
  simulation harness, configure fault injection schedules, interpret empirical
  benchmark matrices, and verify safety with a centralized golden oracle.
])

== Four Kinds of Confidence

#table(
  columns: (auto, 1.25fr, 1.35fr),
  table.header([*Evidence Tier*], [*Question Answered*], [*What It Cannot Answer*]),
  [1. Invariant Proof], [Why every legal transition preserves agreement.],
    [Whether the written Odin code and host system faithfully follow the proof.],
  [2. Deterministic Tests], [Whether specific edge-case schedules execute cleanly.],
    [Whether unvisited adversarial message interleavings are safe.],
  [3. Chaos Simulator], [Whether safety holds across millions of randomized crashes, partitions, and reboots.],
    [Whether physical disk controllers corrupt sectors on power loss.],
  [4. Empirical Benchmarks], [How fast the in-memory state engine transitions under zero-I/O conditions.],
    [What overall latency will be over a WAN with TCP retransmissions.],
)

== Deterministic Unit Test Suite

The `tests/` directory contains 16 focused test suites verifying specific protocol rules:
- `test_ballot_ordering`: Lexicographical comparison of rounds and node identifiers.
- `test_leader_election`: Quorum promise gathering and preemption of lower ballots.
- `test_propose_and_commit`: End-to-end consensus flow from proposal to commitment.
- `test_duplicate_prepares`: Idempotence under retransmitted prepare packets.
- `test_duplicate_accepts`: Idempotence under retransmitted accept packets.
- `test_phase1_reordering`: Chunk recovery when `Promise_Range` manifests arrive before data packets.
- `test_highest_vote_recovery`: Verification of Lamport's Max-Vote Rule ($B_3$).
- `test_sliding_window_backpressure`: Error returned when all ring-buffer cells are occupied.
- `test_commit_replay`: Replay verification when stale commit notifications arrive.
- `test_durability_gate_misuse`: Proving that attempting to read messages before confirming disk writes halts the process.
- `test_replicated_log_stop_sign`: Sealing configurations and rejecting proposals past the stop sign.
- `test_learner_gap_buffering`: Ensuring learners buffer out-of-order commits and release strictly contiguous entries.
- `test_native_bit_set`: Verifying Odin's native `bit_set` operator mechanics and cardinality.

All 16 test suites run deterministically in under 600 microseconds via `./bin/paxos-cli test`.

== Deterministic Chaos Simulator (`paxos-sim`)

To test adversarial schedules that no human would think to write by hand, `paxos-odin`
includes a deterministic chaos simulator (`sim/simulation.odin`):

#code_file("sim/simulation.odin", [
```odin
// Run from CLI:
// ./bin/paxos-cli sim --seed=42 --steps=1024 --drop_pct=15 --partition_pct=10
```
])

Features of the simulator:
1. *SplitMix64 Deterministic PRNG*: Every choice (packet drop, delay, node crash,
   repartition) is derived from a single 64-bit seed. If a bug is found on step 942,
   re-running with the same seed reproduces the exact sequence of events down to the CPU instruction.
2. *Network Partition Matrix*: Nodes are dynamically grouped into disjoint partitions
   where messages cannot cross partition boundaries.
3. *Crash-Reboot & Journal Replay*: Nodes crash, lose volatile state, and reboot
   by replaying their durable disk journals from `small_array` logs.
4. *The Central Golden Oracle*: An independent oracle tracks every value chosen
   across all nodes and continuously asserts:
   - *No Divergence*: Two nodes never decide different values for the same slot.
   - *Monotonic Commits*: A node's decided prefix never regresses.
   - *Quiescent Convergence*: When faults stop, all living nodes converge to the identical log state.

== Empirical 3-Way Benchmark Results

We evaluated `paxos-odin`, `paxos-zig`, and `OmniPaxos` (Rust 0.2.2) on the exact
same 3-node in-memory workload (`u64-3n`, 131,072 values, zero OS I/O):

#benchmark_comparison_table()

#v(8pt)
=== Analysis of Results

1. *Paxos-Odin vs. Paxos-Zig*:
   With procedural inlining (`#force_inline`), native host compilation (`-microarch:native`),
   and bounds checking disabled (`-no-bounds-check`), `paxos-odin` slightly outperforms
   `paxos-zig` across all five execution modes, reaching *108.8 ns per operation*
   (*9.19 million operations/second*).
2. *Paxos-Odin vs. OmniPaxos (Rust)*:
   In synchronous 1-by-1 consensus (`sync`), `paxos-odin` is *9.0x faster* than
   OmniPaxos (114.7 ns vs. 1,031.1 ns). This massive difference stems from memory
   architecture:
   - OmniPaxos allocates heap memory per message, uses dynamic vectors, and wraps
     storage in trait and lock abstractions.
   - `paxos-odin` is a pure zero-allocation state machine that operates directly
     over pre-allocated ring buffers and standard library `core:container/small_array`.
