#import "theme.typ": *

= Reproducing Measurements

The drivers in `bench/matched/` measure the libraries without adding adapters to
the consensus core. Run the commands below from the repository root. The library has
no dependency on C, Rust, Valgrind, network services, storage, or threads.

== Run

Set `ZIG`, `ODIN`, and `CARGO` when the compilers are not on PATH. The Zig checkout
is selected with `PAXOS_ZIG_DIR` (default `../paxos-zig`). LibPaxos must already be
available at `LIBPAXOS_SOURCE`, or the sibling benchmark cache. Its revision is
checked against `d255f8b67a32d5e0ef43ac1a393b72cee23d8e0e`. OmniPaxos is pinned to
0.2.2 with a checked-in Cargo lockfile. No upstream sources are edited.

```sh
python3 tools/bench_compare.py --matched --smoke
python3 tools/matched_compare.py --baseline-root=/path/to/preserved/odin/tree
python3 tools/matched_compare.py --profile-build --build-only --output=bin/profile-build.json
python3 tools/matched_profile.py bin/profile-build.json
python3 tools/profile_recovery.py --baseline-root=/path/to/preserved/odin/tree
python3 tools/test_matched_tools.py
```

`--only=3,1024,64` selects members, payload bytes, and outstanding commands.
`--implementations=odin,zig` restricts a run. Defaults cover all four implementations,
three/five voters, 8/64/1024-byte payloads, and depths 1/8/64. Profiles use three
representative rows; recovery, moving windows, and retransmission have separate
Odin profiles. Unavailable tools fail with diagnostics; missing results are never
reported as zero cost.

== Workload contract

Each measured epoch starts with an elected stable leader and submits 4,096 unique
commands. A separate epoch warms the process. Each outstanding group is delivered
until its message queue is empty. Decision completion is timed; full ordered payload
validation at every configured learner follows outside the timing interval.
Payloads are fixed arrays of 64-bit words with the sequence number in the first
word and zero padding. Drivers validate all words, not merely checksum sums.

There is no serialization, I/O, journal replay mirror, or network delay. Odin/Zig
have window 4,096, chunk 256, and a caller-owned effects buffer. Their durable-write
barrier is a no-op in this cost model. Rust uses the upstream in-memory backend.
LibPaxos uses its native memory backend and one learner per voting member; its
phase-one preexecution remains timed. C's delivered-value buffer belongs to the
benchmark host and is included in process memory measurements.

The pipeline depth bounds outstanding client commands, not protocol message count.
OmniPaxos may coalesce them. LibPaxos's proposer and one learner are co-located when
counting accepted-message deliveries. These native differences are reported, not
removed by rewriting library behavior. No cross-language source translation is
used in the Odin library. Rust driver setup/delivery helpers are adapted from the
MIT-licensed paxos-zig benchmark; the other matched drivers are local harnesses.

This is a finite-retention comparison. It does not claim identical long-running
trim behavior or feature coverage. API batching, ownership, and durable modes are
explicitly outside the common matrix; the existing Odin benchmark retains those
additional scenarios separately. Ownership settling in the historical benchmark
is outside its timed interval, unlike decision completion in this common matrix.

== Timing and evidence

The runner pins one allowed CPU where possible, records container CPU/memory limits,
rotates execution order, and collects nine samples. A common epoch count is chosen
from pilots, targeting 20 ms for the fastest implementation, capped at 16 epochs.
This cap bounds slow-driver cost; raw samples reveal remaining timer/noise effects.
Compilation and warm-up are excluded. Production builds use each language's
optimized native target; profile builds retain symbols and use portable targets.

Results retain raw samples, medians, quartiles, message counts, source and binary
hashes, dependency versions, commands, and static components where available. A
paired deterministic bootstrap estimates candidate/baseline ratios. The regression
gate fails when its 95% interval is entirely above a 5% slowdown. Smoke measurements
are report-only and never support performance claims. Existing results are not
overwritten unless the caller explicitly supplies their path.

Do not run a timing comparison concurrently with builds, tests, or instrumented
profiles. Different host/toolchain/build-policy measurements are not attributable
solely to source changes. A baseline tree must be preserved before editing; the
runner uses the same current driver against both library trees.

== CPU and memory profiles

Callgrind collection is toggled only inside `measured_epoch`, excluding warm-up,
setup, and validation. Its cache and branch results are simulations, not hardware
counters. Instrumented elapsed times are never included in comparison rows.

Massif reports allocated heap, allocation overhead, and stack use. It does not count
static/BSS storage, which is substantial in Zig's fixed-capacity driver. Post-exec
`/proc` high-water RSS is sampled separately over eight epochs; it is null if the
child exits before observation. This avoids counting Python's inherited pre-exec
RSS. RSS includes runtime/libraries and resident static storage, and can be lower
than reserved heap capacity because untouched pages need not be resident.

`tools/memory_report.odin` reports core Odin sizes independently. Node already
includes its ledger; do not add the two. Do not add static capacity, Massif, and RSS
together: they overlap and describe different aspects of memory use.

== Reconstructing the recorded baseline

`bench/results/recovery-baseline.json` identifies a repository commit and a patch that
reconstruct the exact pre-refactor `src` tree. Apply that patch in an isolated
checkout of the recorded commit, then pass that checkout as `--baseline-root`.
The reconstruction was checked against its recorded source SHA-256. The benchmark
uses the current matched driver for both source trees; older timing harnesses are
not mixed into the before/after comparison.

== Measuring the static memory budget

Run from the repository root:

```sh
odin run tools/memory_report.odin -file -out:/tmp/paxos-memory-report
```

The CSV reports actual instantiated type sizes. `node_bytes` already includes
`ledger_bytes`; `total_bytes` adds one caller-owned effects buffer to one node.
It excludes transport queues, serialization buffers, journals, allocator overhead,
application state, and process/runtime memory. A host may share one effects buffer
between nodes if it consumes or copies each batch before reuse.

On x86-64 (Odin dev-2026-09-nightly:a2fb372), after chunk-local recovery:

#let memory_rows = csv("/bench/results/recovery-memory-after.csv").slice(1)
#table(
  columns: (0.7fr, 0.6fr, 0.7fr, 0.6fr, 1fr, 1fr, 1fr),
  table.header([*Bytes / value*], [*Voters*], [*Window*], [*Chunk*],
    [*Node bytes*], [*Effects bytes*], [*Total bytes*]),
  ..memory_rows.map(r => (r.at(0), r.at(1), r.at(2), r.at(3),
    r.at(4), r.at(6), r.at(7))).flatten(),
)

For three members and 1 KiB values, the previous node+effects sizes were 633,120
bytes at window 256/chunk 64 and 9,080,448 bytes at window 4,096/chunk 256.
The reductions are 199,944 bytes (31.6%) and 3,998,880 bytes (44.0%) respectively.

Borrowed payloads keep effects storage independent of payload size. The node now
has one window of ledger values, one *chunk* of recovery values, and a chunk-sized
resubmission queue. Recovery metadata and per-peer duplicate bitmaps also scale
with the chunk. Selection-freeze flags occupy existing alignment space rather than
adding another allocation. Public procedures and journal/wire formats are unchanged;
consumers must recompile for the new internal Node layout.

Canonical membership removes the separate member index. Duplicate validation scans
adjacent sorted IDs rather than comparing every pair of input IDs.

=== Comparing implementations

Match member count, window, recovery chunk, payload, durability policy, and enabled
features. Measure transport queues and peak resident memory separately from these
static sizes. The matched suite reports Odin/Zig inline storage and measures all four processes
with Massif and sampled post-exec RSS; see the workload contract above.

The matched measurements in POD 0009 show workload-dependent
advantages. Odin leads the recorded large-payload cases; Zig and OmniPaxos lead
some small-payload cases. Static sizes do not establish a universal memory winner:
the report includes heap/stack profiles and sampled resident memory separately.

The older ownership harness settles gaps outside its timed interval, so those rows
are not measurements of end-to-end completion latency. Historical files remain
attributable to their recorded source and harness; the matched results are archived
separately in `bench/results/recovery-matched-20260917.json`.

== Measuring the Python SDK across its four paths

The native benchmark measures neither Python object creation nor a Python
journal, so the SDK is measured on its own terms: the same workload driven
through native Odin, the raw C ABI, the typed `Node` and the durable `Session`,
with membership, payload, capacities and completion rule held equal.

```sh
python3 tools/paxodin_measure.py --iterations 10000 --samples 9
python3 tools/paxodin_measure.py --smoke          # one sample, for a quick check
```

It builds `tools/paxodin_native_bench.odin` with the same flags the benchmark
uses, then drives each Python path through `tools/paxodin_paths.py`, and writes
`bench/results/paxodin-paths-<date>.json`. That file records the CPU, the Odin and
Python versions, the core revision, whether the tree was dirty, a SHA-256 over
every source that took part, the exact commands, and every raw sample. Ratios are
paired bootstrap medians with a 95% interval.

Two rules govern reading the result. *Transition-only work and durable host work
are separate measurements*: the `native`, `abi` and `node` paths touch no storage
and no network, `session_memory` adds framing and an in-memory journal, and
`session_durable` adds an `fsync` per batch. Comparing across that boundary --
a Python `fsync` against a native in-memory transition -- measures nothing. And
*the counts matter more than the times*: each row reports boundary crossings,
bytes copied across the ABI and sync calls per value, which is what tells you
whether a batched binding or a compiled extension would address the cost at all.

Run it with nothing else on the machine. A concurrent Typst compile or test run
has visibly skewed this repository's benchmarks before.
