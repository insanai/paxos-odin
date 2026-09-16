= Deterministic Simulation and Chaos Verification

== Why Conventional Testing Fails

Unit tests with static message sequences verify the happy path, but distributed consensus algorithms fail in unpredictable corner cases:
- Dual leaders campaigning simultaneously.
- Asymmetric network partitions (node A talks to B, but B cannot talk to A).
- A node crashing halfway through a transition.
- Dropped phase-two votes followed by out-of-order retransmissions.

== The Chaos Simulation Harness

`paxos-odin` includes a seed-driven, deterministic simulation harness (`sim/`):
- Operates on virtual logical time rather than system wall-clocks.
- Injects randomized faults based on configurable permille probabilities:
  - Packet drops (`drop_permille`)
  - Packet duplications (`duplicate_permille`)
  - Sudden node crashes (`crash_permille`)
  - Dynamic network partition severing and healing (`link_permille`)

== The Golden Oracle Invariant

A central golden oracle observes every committed value across all cluster members. If two distinct nodes ever commit differing values for the same slot $s$, the simulation immediately halts with a fatal invariant violation:

```odin
if sim.golden[c.slot] != nil {
    expected := sim.golden[c.slot].?
    if expected != c.value {
        panic("FATAL AGREEMENT VIOLATION")
    }
}
```

== Quiescence Verification

At the conclusion of the random fault phase, the harness enters a *Quiescence Phase*:
1. All network partitions are permanently healed.
2. All crashed nodes are rebooted and their journals replayed.
3. The network message queue is drained and periodic ticks are issued until traffic subsides.
4. Every alive node's committed log is asserted to match the golden oracle prefix identically.
