#import "theme.typ": *
#import "figures.typ": *

#part_page("VI", [Evidence], [
  A proof obligation, a unit test, a seeded fault run, and a benchmark answer four
  different questions. This part says which question each one answers, what the
  repository actually runs today, and what none of it can tell you.
])

= Validation, Testing, and Operations

#objectives([
  By the end of this chapter you should be able to say which kind of evidence supports
  which claim about `paxos-odin`, run the complete verification suite and read its
  output, replay a failing simulation from its seed, interpret the benchmark table
  without over-reading it, and write an operating drill with an exit criterion.
])

#checkpoint([Vocabulary], [
  You should be able to define *chosen*, *committed*, and *applied* without looking
  them up, and to say why a leader's `Commit` message is dissemination of a fact,
  not the fact itself. Both distinctions matter for the oracles below.
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

`odin test tests` runs 69 deterministic tests in about a second. They are grouped by
file; the names below are the actual test procedures.

#table(
  columns: (auto, auto, 1.6fr),
  table.header([*File*], [*Tests*], [*What is pinned down*]),
  [`test_protocol.odin`], [7],
    [Membership validation, ballot ordering, single-node and three-node consensus, the proc-group surface, restore and `continue_at`, and Lamport's greatest-vote rule (`test_lamport_b3_max_vote_rule`).],
  [`test_election_matrix.odin`], [1 (972 cases)],
    [Every assignment of no vote / ballot 1 / ballot 2 to three voters, every first-response order, and all six intersecting quorum pairs: if an earlier write quorum chose a value, every later decision preserves it.],
  [`test_review.odin`], [21],
    [Regressions found in review: campaigns discard prior-term proposals, fences survive chunk boundaries, retries make progress across chunks, snapshots keep votes above the anchor, trim identity conflicts fail closed, duplicate acknowledgements never make a quorum, 128 and 1,024 voters reach a quorum through the sorted membership index, a leader fetches decisions from a follower that is ahead, and more.],
  [`test_ownership.odin`], [5],
    [Rotating ownership: three owners decide concurrently without a campaign, idle owners skip, a crashed owner's slots are revoked, a revocation keeps a vote it finds (Lamport's B3), and a suggestion revoked to the no-op is resubmitted in a later own slot.],
  [`test_window_review.odin`], [8],
    [The second adversarial review: a follower refuses slots beyond its window, the pass-through releases one decision per transition with its own value, a stale acknowledgement is not an error, an owner keeps proposing after the floor passes its next slot, a far accept cannot wedge an owner, a suggestion the owner itself overwrites is resubmitted, a revocation range stays inside the window, and a leader whose inherited gap stalls re-runs phase one.],
  [`test_batch_review.odin`], [6],
    [The third adversarial review: an ownership tick fits the effect capacities under write quorum one, an ownership batch is admitted on the owner's own frontier after the floor advances, a rejected batch leaves nothing behind, an older vote reported after a decision is not a conflict, ownership order is ascending id whatever order the host gave, and a resubmission the bounded queue cannot hold is counted.],
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

`tools/check.py` runs one hundred and twenty simulations of ten thousand steps (one,
three, and five voters, twenty seeds each, in both modes) as part of `make check`,
together with style checks, the
tests in both build modes, the contract fixtures, the example, the benchmark's JSON
contract, and a check that the CLI cannot report success after a tool failure.

#predict([
  The simulator crashes a node after a random *prefix* of its writes has been journaled.
  Which of the four write kinds, if it is the one that was lost, can never cause a
  safety violation on restart? Answer before reading the next section.
])

== The CPU benchmark, against three other libraries

`bench/` runs the same three-voter and five-voter workloads as the sibling harnesses, and
`make bench-compare` (`tools/bench_compare.py`) runs this library, `paxos-zig`, OmniPaxos
(Rust), and LibPaxos3 (C) one after another on one machine and records a single
results file under `bench/results/`. The tables in this book are read from that file at
compile time; a number that is not in the file cannot appear here.

#benchmark_comparison_table()

Read the table for what it is. Every implementation ran in the same session with an
in-process transport and no serialisation, so the rows measure CPU cost per committed
value, not service latency. With three voters and 8-byte values `paxos-zig` is between
a fifth and thirty percent cheaper than this library; with five voters the two are
this library is about a tenth cheaper; with 1 KiB values this library is more than
five times cheaper, because a value is never copied between
proposal and commit: the ledger holds one copy and every record and message points at
it. The rotating-ownership rows cost within a tenth of the single-leader rows per value
on the same three nodes, and buy a log in which every node proposes without a round
trip to a leader. OmniPaxos pays for allocation and locking in the one-at-a-time mode
and wins in two rows, with sixty-four values in flight and with 1 KiB values at eight
in flight, where it coalesces many log entries into few envelopes; this library and
`paxos-zig` always send one envelope per value. LibPaxos3 runs a heavier twelve-envelope path with phase-one
pre-execution and reports it as its only mode.

#benchmark_durable_table()

The durable rows put the in-memory numbers in proportion. With every node appending
its `effects.writes` to a journal file and issuing one `fsync` per host commit round,
one value costs tens of milliseconds on this disk, and group commit over eight values
brings it to a few milliseconds; the two bounded libraries land within a few percent of
each other because the barrier, not the protocol, sets the pace. In the `durable-sync`
row every value costs six barriers (the leader's accept, two followers' accepts, and
three commit records); group commit cuts that to under one barrier per value.

Numbers move by tens of nanoseconds with cache state and machine load. Rerun
`make bench-compare` before drawing a conclusion finer than the ones above.

A profile explains the 8-byte rows. Under callgrind, one committed value on three
voters is seven transitions and about 1,200 library instructions, roughly 170 per
transition, with the in-process harness adding about a quarter of the program on top
for its `Packet` copies. At the measured nanoseconds that is several instructions per
cycle: the path is instruction-bound, and no single procedure dominates it. The
remaining cost is spread over the 72-byte envelope copies (the `Message` union is
sized by `Promise_Range_Message`), the union dispatch in `node_step`, the per-cell
ledger checks, and one membership lookup per message. POD 0009 records what would
move it (a smaller union, inline values for small `Value` types) and why each is a
wire-format decision rather than a patch.

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
  Explain to a colleague why "all tests pass" is a weaker statement than "one hundred
  and twenty seeded simulations of ten thousand steps passed", and why both are weaker
  than the safety argument in Part III. Use the words *schedule* and *oracle*.
])
