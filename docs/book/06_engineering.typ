#import "theme.typ": *
#import "figures.typ": *

#part_page("VI", [Evidence], [
  A proof obligation, a unit test, a seeded fault run, and a benchmark answer four
  different questions. This part says which question each one answers, what the
  repository actually runs today, and what none of it can tell you.
])

= Validation, Testing, and Operations

#objectives([
  After completing this chapter, you will be able to:
  - Classify the specific guarantees provided by formal proofs, unit tests, deterministic chaos simulation, and benchmarks.
  - Execute the full verification harness and interpret diagnostic outputs.
  - Replay and debug failing distributed schedules using deterministic simulation seeds.
  - Evaluate comparative benchmark results without conflating CPU throughput with end-to-end service latency.
  - Design operational chaos drills with rigorous pass/fail criteria.
])

#checkpoint([Vocabulary Check], [
  Ensure precise command of these three distinct events:
  - *Chosen:* A write quorum has durably accepted a value under a ballot.
  - *Committed:* A node has received evidence that a value is chosen (or certified it locally).
  - *Applied:* The host state machine has executed the command in sequence.
  The simulator oracles below verify invariants across each of these boundaries.
])

== Four kinds of confidence

#table(
  columns: (auto, 1.25fr, 1.35fr),
  table.header([*Evidence*], [*Question it answers*], [*What it cannot answer*]),
  [1. Safety argument (Parts I--III, the lemmas in the safety-argument chapter)],
    [Why every legal transition preserves agreement, and why each departure from the textbook keeps the theorem.],
    [Whether the Odin code and the host actually follow the argument.],
  [2. Deterministic unit tests (`tests/`)],
    [Whether specific schedules, including reordered and duplicated messages, produce the required state.],
    [Whether unvisited interleavings are safe.],
  [3. Seeded fault simulation (`sim/`, `tests/test_reconfiguration_sim.odin`)],
    [Whether agreement, validity, monotonicity, contiguity, and convergence survive thousands of random crashes, drops, duplicates, and partitions, with one leader and with every node proposing in its own slots.],
    [Whether a real disk lies about durability, or whether a real network authenticates peers.],
  [4. Benchmarks (`bench/`)],
    [How much CPU one committed value costs in this process, and what one storage barrier costs on this disk.],
    [Service latency on a real network, or how the libraries compare on hardware other than the recording host.],
)

Each row is necessary and none is sufficient. A passing simulation is finite executable
evidence; it is not a proof, and this book never calls it one. No model-checked
specification ships with this repository.

== What the repository tests today

`odin test tests` runs 79 deterministic tests. They are grouped below by file, with representative
procedure names where a particular rule needs a direct reference.

#table(
  columns: (auto, auto, 1.6fr),
  table.header([*File*], [*Tests*], [*What is pinned down*]),
  [`test_protocol.odin`], [7],
    [Membership validation, ballot ordering, single-node and three-node consensus, the proc-group surface, restore and `continue_at`, and Lamport's greatest-vote rule (`test_lamport_b3_max_vote_rule`).],
  [`test_election_matrix.odin`], [1 (972 cases)],
    [Every assignment of no vote / ballot 1 / ballot 2 to three voters, every first-response order, and all six intersecting quorum pairs: if an earlier write quorum chose a value, every later decision preserves it.],
  [`test_review.odin`], [21],
    [Regressions found in review: campaigns discard prior-term proposals, fences survive chunk boundaries, retries make progress across chunks, snapshots keep votes above the anchor, trim identity conflicts fail closed, duplicate acknowledgements never make a quorum, 128 and 1,024 voters reach a quorum through the sorted membership array, a leader fetches decisions from a follower that is ahead, and more.],
  [`test_ownership.odin`], [5],
    [Rotating ownership: three owners decide concurrently without a campaign, idle owners skip, a crashed owner's slots are revoked, a revocation keeps a vote it finds (Lamport's B3), and a suggestion revoked to the no-op is resubmitted in a later own slot.],
  [`test_window_review.odin`], [8],
    [The second adversarial review: a follower refuses slots beyond its window, the pass-through releases one decision per transition with its own value, a stale acknowledgement is not an error, an owner keeps proposing after the floor passes its next slot, a far accept cannot wedge an owner, a suggestion the owner itself overwrites is resubmitted, a revocation range stays inside the window, and a leader whose inherited gap stalls re-runs phase one.],
  [`test_batch_review.odin`], [6],
    [The third adversarial review: an ownership tick fits the effect capacities under write quorum one, an ownership batch is admitted on the owner's own frontier after the floor advances, a rejected batch leaves nothing behind, an older vote reported after a decision is not a conflict, ownership order is ascending id whatever order the host gave, and a resubmission the bounded queue cannot hold is counted.],
  [`test_recovery_chunk.odin`], [7],
    [Chunk sizes 1, 3, and 8; ring crossings; reordered and duplicate reports;
    stale reports; window backpressure; large payloads; frozen phase-two selection;
    sparse retransmission without duplicate sends.],
  [`test_slot_exhaustion.odin`], [3],
    [Boundary behaviour near the largest representable slot.],
  [`test_reconfiguration.odin`], [2],
    [A three-node handover with a delayed old-configuration message rejected by the checked `Log_Envelope` step; stop-sign initialisation with aliased slices.],
  [`test_reconfiguration_sim.odin`], [4 (16 seeds each)],
    [Seeded, shuffled delivery on a replicated log: a seal survives a dropped, a duplicated, and a reordered accept; a 1,2,3 to 2,3,4 handover; a one-for-one voter replacement; under rotating ownership, decisions other owners reach above the stop sign are abandoned and re-decided by the next configuration. Each run checks seal agreement, nothing released past the seal, replay keeps the seal, and the next configuration decides new commands on the same slot line.],
  [`test_replicated_log.odin`], [3],
    [Commands, a stop sign that seals the epoch, and the handover initialisers.],
  [`test_learner.odin`], [3],
    [Contiguous release, window wrap with `Trimmed` and `Window_Full`, configuration mismatch.],
  [`test_durability.odin`], [4],
    [`requires_power_loss_barrier`, the pre-durable accept iterator, the host-managed gate, and a zero-initialised batch being ready without an init call.],
  [`test_errors.odin`], [2],
    [Every `Error` value has a title, an explanation, and a `Hint:`; adding a value without one fails the build's tests.],
  [`test_bit_set.odin`], [3],
    [The bounded slot set and the native `bit_set` operators.],
)

Two checks run outside `odin test` because they need separate processes. The script
`tools/check_contracts.py` compiles nine programs that must be *rejected*: a zero
member capacity and one of 65,536, a zero window and a window that is not a power of
two, a zero chunk and a chunk larger than the window, a zero learner window, a
non-comparable `Value`, and an `Effects` whose parameters differ from its `Node`. It
then builds four programs in both debug and optimized modes: two must stop
with a `DURABILITY ORDER VIOLATION` diagnostic (reading messages before confirming
writes; resetting a batch with unconfirmed writes), and two must exit cleanly (the
correct order; a zero-initialised batch used without any init call).

== The deterministic fault harness

`sim/simulation.odin` drives one to five voters from a single seed. Every choice comes
from a SplitMix64 generator, so a failure is replayed exactly by the command the
failure prints. With `--ownership` every node is started with rotating ownership and
proposes in its own slots; the same oracles apply, and the liveness probe may be
answered by any node.

#code_file("shell", [
```sh
./bin/paxos-sim --seed=1337 --steps=10000 --nodes=5 --verbose
./bin/paxos-sim --seed=1337 --steps=10000 --nodes=5 --ownership
```
])

Each step rolls one action:

#table(
  columns: (auto, auto, 1.6fr),
  table.header([*Share*], [*Action*], [*Faults applied*]),
  [45%], [Deliver one queued envelope], [Dropped at 6% (default), duplicated at 4%, blocked by a cut link, or lost because the target is down.],
  [20%], [Tick a live node], [Elections, heartbeats, retransmission.],
  [15%], [Propose at a random live node], [One in four proposals is a two-value batch. `Not_Leader`, `Window_Full`, and `Leader_Catching_Up` are expected backpressure.],
  [6%], [Cut or heal one link], [Asymmetric partitions accumulate.],
  [4%], [Crash a node], [Only while more than a read quorum stays alive.],
  [6%], [Restart a crashed node], [Journal replay with `ledger_replay_fold`, then `restore` at the host's consumed floor.],
  [4%], [Report a reconnected peer], [`reconnected` triggers retransmission or a catch-up request.],
)

The host side of every transition is itself a fault site. With probability
`crash_permille` the process dies at one of three points of its commit sequence:
before any write, after a random durable prefix of the writes with no message sent,
or after every write with only a prefix of the messages sent. Accept requests at a
campaign ballot may leave before the barrier, exactly as `pre_durable_messages`
permits; an owner's round-zero suggestion may not, and it was this harness, at the
vote level, that showed why: a restarted owner reused its ballot for a different value
until the exception was narrowed. The memory floor is advanced only half of the time
so that full-window and cell-reuse paths run.

The oracles run after every observed transition:

#table(
  columns: (auto, 1.7fr),
  table.header([*Oracle*], [*What it rejects*]),
  [Agreement], [A durable decision for a slot that differs from the first durable decision for that slot. Decisions are observed at the *vote* level: a write quorum of identical durable votes counts, whether or not any leader announced it.],
  [Validity], [A decided value that is neither the no-op nor a value some node proposed.],
  [Promise monotonicity], [A `Write_Promise` below an earlier promise, or a `Write_Vote` below the current promise, on the same node.],
  [Contiguity], [A node releasing slot $s$ before slot $s - 1$.],
  [Liveness probe], [After all faults stop, the healed cluster must decide one fresh proposal; a run that never decided anything cannot pass vacuously.],
  [Convergence], [After quiescence every node must have applied every slot of the golden log.],
)

`make check` runs 240 simulations of ten thousand steps: 120 with the default
window (one, three, and five voters; twenty seeds; both leadership modes), and
120 with an eight-slot window and three-slot chunks (three voters; majority,
read-all/write-one, and read-one/write-all quorums; twenty seeds; both modes).
It also checks style, tests in both build modes, contract fixtures, the example,
the benchmark's JSON contract, and CLI failure propagation.

The recovery review used `python3 tools/check.py --seeds=100`: 600 default-window
runs plus the 120 focused runs, for 7.2 million steps. The focused matrix caps each
configuration at twenty seeds. These are two different runs; the larger count is
recorded evidence, not the default of `make check`.

#predict([
  The simulator crashes a node after a random *prefix* of its writes has been journaled.
  Why can recovery safely replay that prefix if no reply relying on a lost promise
  or vote was sent? Contrast this with sending Accepted before its vote was durable.
])

== Matched CPU measurements

First decide what a row means. The matched drivers in `bench/matched/` compare the
cost of completing an ordered stream in memory. Every library processes the same
4,096 values per epoch, with the same voter count, payload size, and limit on
outstanding work. Every learner's ordered payloads are checked. A separate warm-up
precedes timing; repeated runs rotate the execution order. There is no disk,
serialization, or network delay in this measurement.

The matrix covers three and five voters, 8-, 64-, and 1,024-byte values, and depths
1, 8, and 64. The four implementations retain their native algorithms: OmniPaxos can
coalesce entries, and LibPaxos3 performs phase-one preexecution. Equal workload does
not mean identical work inside each implementation. The Odin baseline preserves the
source from before the recovery-storage changes.

#matched_comparison_table()

The table is loaded directly from
`bench/results/recovery-matched-20260917.json` when the book compiles. That file also
records raw samples, source and binary hashes, compiler versions and flags, CPU
affinity, and the paired comparison intervals. Use `make bench-matched` to repeat the
workloads; see `docs/book/06_measurement_methods.typ` for dependency paths and baseline reconstruction.

=== Read across workloads before naming a winner

#book_figure(
  [Three slices of the same matrix. Bar length is median time per value and starts
  at zero. Each panel has its own scale, printed in nanoseconds beside every bar.
  The best result changes with payload, voter count, and outstanding work.],
  matched_cost_picture(),
)

For three voters and 1 KiB values, the paired median cost decreased by about
16–26% relative to the Odin baseline. Several small-payload workloads became about
1–3% slower. At five voters, 1 KiB, and depth 64, the paired ratio is 1.047 with a
95% bootstrap interval of 0.928–1.089. That interval includes both an improvement
and a regression, so this row does not establish either.

The regression gate rejects a workload when its entire paired 95% interval exceeds
1.05. All workloads passed this gate; passing does not prove that every slowdown is
smaller than 5%. The five-voter interval above illustrates the distinction. Zig and
OmniPaxos lead some categories. These measurements support specific workload claims,
not a claim that one library is always fastest.

#predict([
  Odin is faster at three voters and 1 KiB, but slower than Zig at five voters and
  8 bytes. Which row would you use to estimate your service? Name two costs the
  benchmark leaves out before interpreting the number as request latency.
])

== Memory: count the storage you mean

Recovery reports are temporary; ledger entries must remain available until the host
releases them. Reducing the former from a window to a chunk removes payload storage,
metadata, and per-peer bitmap words. For three voters and 1 KiB values:

#table(
  columns: (1fr, 1fr, 1fr, 0.7fr), align: (left, right, right, right),
  table.header([*Window / chunk*], [*Before, bytes*], [*After, bytes*], [*Reduction*]),
  [256 / 64], [633,120], [433,176], [31.6%],
  [4,096 / 256], [9,080,448], [5,081,568], [44.0%],
)

#book_figure(
  [One node plus one effects buffer, three voters and 1 KiB values. Each pair uses
  its own zero-based scale and prints the byte count. The data comes from the
  recorded CSV files; the bars exclude queues and application memory.],
  recovery_memory_picture(),
)

These totals count one node plus one effects buffer. They exclude transport queues,
application state, and runtime overhead. When chunk and window sizes are equal,
the node's size is unchanged. The CSV files `recovery-memory-before.csv` and
`recovery-memory-after.csv` under `bench/results/` record the configurations.

Three measurements answer different questions:

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Measure*], [*Counts*], [*Does not establish*]),
  [Inline size], [Bytes reserved by the configured structs.], [Total process memory.],
  [Massif], [Instrumented heap and stack allocation.], [Static/BSS storage or resident pages.],
  [Sampled peak RSS], [Resident process pages observed after execution begins.],
    [Which library field caused the footprint, or every possible peak.],
)

In the recorded three-voter, 1 KiB, depth-64 profile, Odin's sampled peak RSS was
25.4 MB, compared with 52.8 MB for Zig, 32.9 MB for OmniPaxos, and 27.9 MB for
LibPaxos3 (decimal MB). Odin did not have the smallest RSS in the small-payload
profiles. Massif can exceed RSS when allocated pages are untouched, or miss static
storage entirely; never add the two measurements together.

== Profiling an optimisation

A useful profile tests an explanation. The retransmission hypothesis was that a
sparse bitmap scan revisited the same occupied cell until it exhausted the chunk
budget. A regression test now requires one retry for one used slot. The retained
scan wraps at most once and visits each used cell at most once per sweep.

In the dedicated retransmission workload, Callgrind instructions fell from
12,591,988 to 10,139,090 (19.5%). A first attempt that counted occupied cells before
scanning used 17,833,184 instructions and was discarded. The retained change's paired
native timing ratio was 0.877, with a 95% interval of 0.820–0.905. The steady-state
matrix above checks the broader effect; the dedicated result is not a promised
speedup for every workload.

`make bench-profile` builds symbolised drivers and collects Callgrind and Massif
profiles. Instrumented elapsed time is not a native timing result. Raw traces,
annotations, and both retry experiments are archived in
`bench/results/recovery-profiles-20260917.tar.gz`; the associated JSON and
POD 0009 describe the measurements and their limits.

== Historical durability measurements

The earlier harness also measured a journal and storage barrier. Its CPU rows use a
different host path, including a journal replay mirror, so their nanoseconds cannot
be compared directly with the matched matrix. The durability table below is retained
as evidence from its recorded revision and machine, not as a fresh run of the current
source.

#benchmark_durable_table()

On that disk, one barrier per host commit round cost tens of milliseconds per value;
grouping eight values reduced the cost to a few milliseconds. The lesson is a
workload question: if storage dominates the service, a faster consensus transition
may make little difference to end-to-end latency. `make bench-compare` runs this
historical harness; the matched CPU and profile commands are separate.

== Capability map: exact boundaries

#table(
  columns: (1.1fr, auto, 1.6fr),
  table.header([*Concern*], [*Core*], [*Boundary*]),
  [Ballots, promises, votes, commits], [yes], [`Node` and `Ledger`.],
  [Rotating slot ownership: suggest, skip, revoke, resubmit], [yes], [`Node_Options.rotating_ownership`; `owner_of` names the proposer of a slot.],
  [Chunked recovery, no-op filling, fences], [yes], [`start_campaign` through `become_leader`.],
  [Bounded window, memory floor, trim anchors], [yes], [Host licenses reuse with `advance_memory_floor`; host serves `Serve_Range_Request`.],
  [Stop-sign reconfiguration, configuration-checked envelopes], [yes], [`Replicated_Log_Node`, `Log_Envelope`.],
  [Non-voting learners], [yes], [`Learner` and `node_init_learner`.],
  [Runtime durability gate], [yes], [`Effects` under `.Enforced`; `.Host_Managed` is an audited exception.],
  [Journal format, fsync, replay loop], [no], [Host: persist `Write` records in order, copying each value out of the ledger; replay with `ledger_replay_fold`.],
  [Transport, codec, authentication], [no], [Host: `Envelope` in, `Envelope` out; the core trusts `from`.],
  [Client sessions and deduplication], [no], [Host state machine; see the key-value design in Part V.],
  [Snapshot store and state images], [no], [Host; the core only carries `Trim_Anchor`.],
  [Linearizable reads, leases], [no], [Not implemented. `is_leader_caught_up` reports prefix progress only. Leases are a proposal (POD 0004).],
  [Byzantine tolerance], [no], [Out of scope by design.],
)

== Operating drills with exit criteria

Every drill below can be run against the simulator today and against a real deployment
once a host exists. A drill without an exit criterion is a demonstration, not a test.

#table(
  columns: (auto, 1.3fr, 1.3fr),
  table.header([*Drill*], [*Procedure*], [*Passes when*]),
  [Follower crash], [Kill one follower mid-stream; keep proposing.], [Throughput continues; on restart the follower's `decided_through` reaches the leader's within one resend interval.],
  [Leader crash during a vote], [Kill the leader after `Write_Vote` is durable and before `Commit` leaves.], [A new leader is elected; the vote's value is chosen, never a different one; the client that timed out sees its request applied exactly once after retry.],
  [Minority partition], [Isolate fewer than a read quorum of voters.], [The majority keeps deciding; the minority's leader, if any, steps down on the first `Nack`; on healing the minority catches up without a divergent slot.],
  [Disk full or sync failure], [Make the journal append or `fsync` fail on one node.], [The host never calls `confirm_writes_durable` for that batch; it stops the node and restarts from the journal; no message from the failed batch was sent.],
  [Corrupt state image], [Install a state image whose anchor does not match the certified trim.], [`begin_recovery` or `install_chosen_trim` returns `Trim_Regression`; the node does not resume.],
  [Window backpressure], [Stop applying on one node while the leader keeps proposing.], [`propose` returns `Window_Full` at the leader once the unapplied prefix reaches `WINDOW_SLOTS`; it resumes when the floor advances.],
  [Crashed owner], [Under rotating ownership, kill one owner while the others keep proposing.], [After `election_timeout_ticks` of stall a survivor revokes the stalled chunk; the log advances with no-ops in the dead owner's slots; on restart the owner resumes in its own slots above the revoked range.],
)

#exercise("19.1", [
  Add an oracle to the simulator that rejects a `Commit_Message` whose value differs
  from a durable write-quorum decision for the same slot, even when the sender is not
  the leader. Say which existing oracle already implies it and why the new one is still
  worth its cost.
])

#teach_back([
  Compare the complementary roles of testing and formal reasoning:
  - Why a green unit test suite only verifies pre-selected execution traces.
  - How pseudo-random fault injection explores vast schedule permutations against continuous invariant oracles.
  - Why even extensive empirical simulation cannot substitute for the mathematical safety argument established in Part III.
])
