# paxos-odin

English · [한국어](README.ko.md)

A pure, deterministic, and bounded implementation of Classic and Multi-Paxos in the **Odin** programming language.

Translated from the rigorous verification principles of [`paxos-zig`](https://github.com/insanai/paxos-zig), `paxos-odin` models distributed consensus as a pure state machine without operating system resource ownership, threads, sockets, dynamic allocations, or system clocks. Its specification, RFC workflow, and documentation pipeline are modeled after [`zenfmt`](https://github.com/insanai/zenfmt), renaming the discussion record series to **POD** (**Paxos Odin Discussions**).

**Current release: 0.1.0.** The architecture is formally specified in [POD 0002](docs/pod/records/0002-paxos-odin-architecture.typ), durability contracts and window trimming in [POD 0003](docs/pod/records/0003-durability-and-trimming.typ), and the RFC process in [POD 0001](docs/pod/records/0001-pod-process.typ).

---

## Architectural Principles

1. **Pure State Machine with Explicit Effects:**
   A consensus node owns zero I/O resources. Every state transition accepts an incoming input event (`step`, `propose`, `tick`, `reconnected`) and populates a caller-allocated `Effects` container with:
   - `writes`: State transitions (`Promise`, `Accept`, `Commit`, `TrimAnchor`) that must be durably persisted.
   - `messages`: Outbound peer messages (`Envelope`) to be transmitted over the network.
   - `committed`: Contiguous stream of newly decided values released to the host state machine.
   - `requests`: Catch-up requests for log segments trimmed below local ring-buffer memory.

2. **Runtime-Enforced Durability Contract:**
   The fundamental Paxos safety invariant dictates:
   > **Persist every state write before transmitting any network message produced in the same transition.**

   `paxos-odin` enforces this invariant at runtime. Calling `messages_slice` or re-entering transition logic while uncommitted writes remain unconfirmed halts immediately with an Elm-style diagnostic report. An audited `pre_durable_messages` iterator permits pipelined Phase 2 proposals while preserving crash safety.

3. **Zero Dynamic Allocations:**
   All structures (`Node`, `Effects`, `Replicated_Log_Node`, `Learner`) are statically parameterized with compile-time bounds (`MAX_MEMBERS`, `WINDOW_SLOTS`, `CHUNK_SLOTS`). Bitsets (`Member_Set`, `Slot_Set`) provide $O(1)$ quorum and slot tracking without heap allocations or garbage collection pauses.

4. **Replicated Log with Stop Signs:**
   Supports distributed reconfigurations, clean epoch transitions, and cluster snapshots using Lamport's Stop Sign discipline. Once a Stop Sign is proposed at slot $S$, the log is sealed at $S$, rejecting subsequent proposals until a new epoch begins.

5. **Contiguous-Only Non-Voting Learner:**
   Implements an asynchronous sliding ring-buffer window (`MAX_ENTRIES`) with gap tracking. Delivers chosen entries strictly contiguously without exposing gaps to the consumer.

---

## Quickstart

### Prerequisites
- [Odin Compiler](https://odin-lang.org/) (`dev-2026-09` or newer)
- C Linker / LLVM (`clang` and `lld`)
- [Typst](https://typst.app/) (`0.13.0` or newer, for compiling specifications)

### Building the Toolchain
Use the bootstrap script to compile the unified management CLI:

```sh
./build.sh
```

Or using `make`:
```sh
make build
```

The compiled binary will be placed at `bin/paxos-cli`.

---

## CLI Reference (`paxos-cli`)

`paxos-cli` provides a complete workflow for building, testing, simulating, benchmarking, and generating specification documents:

```sh
# Build all targets (cli, sim, bench)
./bin/paxos-cli build all

# Run the full unit test suite (15 tests in < 1ms)
./bin/paxos-cli test

# Run the deterministic chaos simulator (packet drops, reorders, crashes, partitions)
./bin/paxos-cli sim --seed=42 --steps=1024 --nodes=3

# Run the in-memory consensus benchmark
./bin/paxos-cli bench

# Compile all Typst specifications into docs/build/
./bin/paxos-cli docs all

# Manage Paxos Odin Discussions (POD) RFCs
./bin/paxos-cli pod list
./bin/paxos-cli pod new fast-path-leases
./bin/paxos-cli pod promote fast-path-leases
```

---

## In-Memory Performance Benchmark

Running `./bin/paxos-cli bench` executes a pure in-memory cluster benchmark (3 nodes, zero OS syscalls) across three execution profiles:

```
================================================================================
  PAXOS-ODIN IN-MEMORY WORKLOAD BENCHMARK
  Cluster: 3 nodes | Pure State Machine (Zero-I/O, In-Memory)
  Iterations: 10000 per mode
================================================================================
Mode                      Throughput         Latency / Op      Iterations
--------------------------------------------------------------------------------
Synchronous              1,494,926 ops/s        668.9 ns            10,000
Pipelined (16)             567,952 ops/s      1,760.7 ns            10,000
Batched (16)               500,606 ops/s      1,997.6 ns            10,000
================================================================================
```

---

## Deterministic Chaos Simulator

The chaos simulator (`sim/`) exercises a multi-node cluster under adversarial conditions:
- **SplitMix64 Deterministic PRNG**: Fully reproducible runs with `--seed=<N>`.
- **Fault Matrix**:
  - Asymmetric network partitions (configurable peer reachability matrix).
  - Packet drops and duplicates.
  - Random node crash and reboot with durable journal recovery.
- **Safety Oracle Verification**:
  - Global oracle assertions on every step: no two nodes ever decide conflicting values for any slot.
  - Final quiescence test: all non-faulty nodes converge to identical decided logs.

```sh
# Run 1024 chaos steps with seed 1337
./bin/paxos-cli sim --seed=1337 --steps=1024 --nodes=5
```

---

## Documentation & Specification Pipeline

The specification is authored in [Typst](https://typst.app/), featuring academic paper layout, clean mathematical definitions, state diagrams, and a formal RFC pipeline.

### Document Hierarchy
- `docs/book.typ`: Comprehensive Paxos-Odin specification book:
  - Chapter 1: Tour & Quickstart
  - Chapter 2: Multi-Paxos Protocol & Transitions
  - Chapter 3: Durability Invariants & Host Boundary
  - Chapter 4: Replicated Command Log & Stop Signs
  - Chapter 5: Learner Ring Buffer & Gap Recovery
  - Chapter 6: Window Trimming & Garbage Collection
  - Chapter 7: Deterministic Chaos Simulation
- `docs/pod/`: **Paxos Odin Discussions** (RFC process):
  - [POD 0001](docs/pod/records/0001-pod-process.typ): The POD Process & Numbering Workflow
  - [POD 0002](docs/pod/records/0002-paxos-odin-architecture.typ): Pure State Machine Architecture
  - [POD 0003](docs/pod/records/0003-durability-and-trimming.typ): Durability Contracts & Trimming
  - [POD 0004](docs/pod/records/0004-fast-path-leases.typ): Fast-Path Leader Leases
- `docs/pod/registry.typ`: Central metadata index for all POD proposals.

### Compiling Documentation
```sh
# Compile book + index + all POD records
./bin/paxos-cli docs all

# Output documents are placed in docs/build/:
#   docs/build/paxos-spec.pdf
#   docs/build/pod-index.pdf
#   docs/build/pod-0001-pod-process.pdf
#   docs/build/pod-0002-paxos-odin-architecture.pdf
#   docs/build/pod-0003-durability-and-trimming.pdf
#   docs/build/pod-0004-fast-path-leases.pdf
```

---

## Directory Structure

```
paxos-odin/
├── README.md               # English documentation
├── README.ko.md            # Korean documentation
├── LICENSE                 # MIT License
├── Makefile                # Standard developer convenience commands
├── build.sh                # Bootstrap shell script
├── src/                    # Library package
│   ├── paxos.odin          # Package root and version constants
│   ├── bit_set.odin        # High-performance zero-heap bitsets
│   ├── protocol.odin       # Multi-Paxos state machine & transitions
│   ├── replicated_log.odin # Reconfigurable log, stop signs, epoch sealing
│   ├── learner.odin        # Contiguous non-voting learner window
│   ├── host_managed.odin   # Audited host-managed durability bypass
│   └── errors.odin         # Elm-style diagnostics and explanations
├── cli/                    # Toolchain CLI implementation
│   └── main.odin           # CLI entrypoint
├── tests/                  # Unit test suite
│   ├── test_protocol.odin  # State machine quorum and consensus tests
│   ├── test_durability.odin# Durability barrier enforcement tests
│   ├── test_replicated_log.odin # Configuration changes and stop signs
│   ├── test_learner.odin   # Learner gap buffering tests
│   ├── test_bit_set.odin   # BitSet tests
│   └── test_errors.odin    # Elm diagnostic formatting tests
├── sim/                    # Deterministic Chaos Simulator
│   ├── main.odin           # Simulator CLI harness
│   └── simulation.odin     # Network matrix, crash-replay, safety oracle
├── bench/                  # In-Memory Benchmark Suite
│   └── main.odin           # Sync, pipelined, and batched workloads
└── docs/                   # Documentation & Typst Specification Suite
    ├── book.typ            # Specification root document
    ├── book/               # Individual specification chapters
    ├── shared/             # Typst theme, layout, and POD styles
    └── pod/                # Paxos Odin Discussions (RFC records & registry)
```

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
