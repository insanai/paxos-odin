// paxos-odin 0.2.0 release notes
#import "../shared/theme.typ": configure-document

#show: configure-document.with(title: "paxos-odin 0.2.0 release notes")

#align(center)[
  #text(20pt, weight: "bold")[paxos-odin 0.2.0 release notes]
  #v(0.4em)
  #text(11pt)[Released 2026-09-16 · `VERSION :: "0.2.0"` in `src/paxos.odin`]
]
#v(1em)

The core was rebuilt from the ground up around Lamport's variables laid out as
columns, one packed integer per ballot, and values that are referenced rather than
copied. The same release adds rotating slot ownership, so that every member may
propose without a phase one, and a safety argument in the book that proves each
departure from the textbook preserves agreement. The host contract is unchanged in
shape: one input, one `Effects` batch, persist then confirm then transmit then apply.

= Highlights

- *A data-oriented ledger.* `Ledger(Value, WINDOW_SLOTS)` holds the promise, the
  per-cell promise, the vote ballot, the cell state, and the value in parallel
  arrays, with bitmaps for the cells in use and the cells decided. Scans over the
  window walk the bitmaps word by word. The window is a power of two, so a slot's
  cell is a mask, not a division (POD 0009).
- *One integer per ballot.* `Ballot` packs round, priority, and node into a
  `distinct u64`; the lexicographic order of Lamport's triple is integer
  comparison. `Node_Id` is a `u16`, and a membership may hold up to 65,535
  members with a sorted index for lookup.
- *Values are referenced, never copied.* `Write_Vote`, `Write_Chosen`,
  `Promise_Message`, `Accept_Message`, `Commit_Message`, and `Committed` carry a
  `^Value` into the sender's ledger, valid until that node's next transition. The
  host copies at the journal and the codec, where a copy is needed anyway. 1 KiB
  values cost about half of what they did in 0.1.0.
- *Rotating slot ownership.* With `Node_Options{rotating_ownership = true}` slot
  $s$ belongs to member $(s - 1) mod N$, whose ballot in that slot has round zero.
  An owner proposes with no phase one; idle owners skip; a stalled prefix is
  revoked by a bounded phase one at a higher round; a value revoked to the no-op
  is resubmitted in the owner's next slot (POD 0010, after Mencius).
- *A safety argument.* The book's new chapter states five axioms, sixteen
  lemmas, and the agreement theorem, and maps each obligation to the procedure
  that discharges it and the test or oracle that exercises it (POD 0008).
- *Verification in both modes.* The simulator runs with one leader or with every
  node proposing; `make check` runs 120 seeded simulations. Five ownership tests
  and a fourth reconfiguration scenario join the suite, which now holds 69
  tests; the compiler fixtures grow to nine.

= What changed in the API

#table(
  columns: (auto, auto),
  align: (left, left),
  [*0.1.0*], [*0.2.0*],
  [`Durable_State`, `durable_state`, `durable_apply`, `durable_replay_fold`], [`Ledger`, `ledger`, `ledger_apply`, `ledger_replay_fold`],
  [`Write_Accept{ballot, slot, value}`], [`Write_Vote(V){ballot, slot, value: ^V}`],
  [`Write_Commit{slot, value}`], [`Write_Chosen(V){slot, value: ^V}`],
  [`Write_Promise{ballot}`], [unchanged; `Write_Promise_At{ballot, slot}` added for bounded phase one],
  [`Ballot{round, priority, node}` and `ballot_less_than`], [`Ballot :: distinct u64`; `ballot_make`, `ballot_round`, `ballot_priority`, `ballot_node`; compare with `<`],
  [`Node_Id :: u32`, `MAX_MEMBERS <= 128`], [`Node_Id :: u16`, `MAX_MEMBERS <= 65535`],
  [`WINDOW_SLOTS > 0`], [`WINDOW_SLOTS` a power of two],
  [`Trim_Anchor{trim_id, chosen_trim_slot, history_hash}`], [`Trim_Anchor{trim_id, chosen_trim_slot}`; the host binds its image checksum to `trim_id`],
  [`Committed{slot, value}` by value], [`Committed(V){slot, value: ^V}`],
  [`Prepare_Message{ballot, first, last}`], [adds `scope: Prepare_Scope` (`.Global` or `.Bounded`)],
  [`Promise_Message` reports a decision as a zero-ballot vote], [`Promise_Message.state == .Chosen`],
  [`Nack_Message{rejected, promised, decided_through}`], [adds `slot`],
  [`Node_Options.priority: u32`], [`u8`; adds `rotating_ownership: bool`],
  [`node_restore(&n, id, m, durable, floor, options)`], [`node_restore(&n, id, m, ledger, floor, options)`],
  [`replicated_log_durable_state`], [`replicated_log_ledger`],
  [`NodeId`, `Log_Slot`, `Vote_Ballot` aliases], [removed],
)

The proc groups keep their verbs. `ledger` replaces `durable_state` in the list;
everything else in `src/paxos.odin` is spelled as before.

= Pointer validity, stated once

An outbound pointer refers into the producing node's ledger and is valid until that
node's next transition. A host that journals a record copies the value into the
record it writes; a host that queues an envelope in memory copies the value into
the queue entry. `tests/harness.odin` and `examples/counter.odin` show the
`Packet` idiom. Nothing in the library retains a pointer a host handed in beyond
the call that received it.

= Rotating ownership, in brief

- Ownership order is membership order; ids are never reused.
- `campaign` returns `.Campaign_Disabled` under ownership; there is no standing leader.
- A stop sign is proposed in its owner's slot like any value. Decisions that other
  owners reach above a decided stop sign are abandoned by `Replicated_Log_Node`:
  never released, not readable, re-decided by the next configuration.
- `propose` at any node places the value in that node's next own slot, stepping over
  own slots that were revoked or already decided; `propose_batch` needs the whole
  batch to fit in the window.
- A round-zero accept is not a pre-durable message. Only accepts at round one and
  above may leave before the barrier. The vote-level agreement oracle in the
  simulator found the counter-example that fixed this rule.
- `owner_of(&node, slot)` names a slot's owner; `ownership_ballot(owner)` is its
  ballot; `SKIP_BURST` bounds skips per tick.

= Verification

- 69 tests under `tests/`, run in `-debug` and `-o:speed` by `make check`; a
  972-case election matrix; 21 review regressions; 5 ownership scenarios; 4
  reconfiguration scenarios under 16 seeds each; 128- and 1,024-voter quorums.
- The simulator in both modes: 120 runs of 10,000 steps in `make check`, with
  crashes at three points of the host commit sequence and agreement checked at the
  vote level.
- `tools/check_contracts.py`: nine programs the compiler must reject with a hint,
  four durability fixtures in both builds.
- `tools/check_style.py`: the Zen of Odin for InsanAI constraints (POD 0001).
- Profiling with callgrind guided the layout; `INVARIANT_CHECKS` is a build
  define (`-define:PAXOS_INVARIANT_CHECKS=true`) so a debug build can be profiled
  without the invariant walks.

= Benchmarks

`make bench-compare` records `bench/results/latest.json`; the book's evidence
chapter and the README read their tables from that file. On the recording host,
nanoseconds per committed value with an in-process transport were:

#table(
  columns: (auto, auto, auto, auto, auto),
  align: (left, right, right, right, right),
  [*workload*], [*paxos-odin*], [*paxos-zig*], [*OmniPaxos*], [*LibPaxos3*],
  [3 voters, 8 B, one at a time], [148], [113], [1,010], [2,280],
  [3 voters, 8 B, 8 in flight], [144], [115], [198], [–],
  [3 voters, 8 B, 64 in flight], [141], [113], [83], [–],
  [5 voters, 8 B, one at a time], [191], [219], [2,721], [–],
  [5 voters, 8 B, 8 in flight], [182], [210], [446], [–],
  [3 voters, 1 KiB, one at a time], [505], [2,719], [1,244], [–],
  [3 voters, 1 KiB, 8 in flight], [552], [2,707], [423], [–],
  [3 owners, 8 B, one at a time, rotating ownership], [161], [–], [–], [–],
  [3 owners, 8 B, 8 in flight, rotating ownership], [154], [–], [–], [–],
)

With a journal and one `fsync` per host commit round, this library costs
27.49 ms per value one at a time and 3.71 ms with group commit over eight
values; paxos-zig's equivalent modes cost 27.54 ms and 3.53 ms. The disk,
not the protocol, is the bill. Host: AMD Ryzen 7 5800H with Radeon Graphics, Linux 7.0.0-28-generic; recorded
2026-09-16T23:53:16Z.

= Known limits

- Membership is fixed per `Node`; a change is a new node started from a decided
  stop sign.
- Slots are global `u64` values that never reset; `Global_Slot_Exhausted` ends a log.
- `Window_Full` is the only backpressure; under ownership it applies to every owner.
- `committed_slice` carries only this transition's decisions; it is not a recovery
  feed.
- Values are fixed-size and compared with `==`; a value that references host memory
  must stay immutable and alive.
- A timed-out proposal is not known to have failed; under ownership a revoked value
  is resubmitted by the owner, which is at-least-once, so commands carry ids.
- `is_leader_caught_up` is not a lease; no leases or read barriers are implemented
  (POD 0004). Ownership has no read path.
- The gate tracks one `Effects` batch and cannot see a copy the host made.

== Recovery-storage and measurement follow-up

Recovery values, metadata, and per-peer duplicate bitmaps are now chunk-sized.
Indexes are relative to the active recovery base, with explicit range checks;
non-power-of-two chunks remain supported. The selected recovery values are frozen
before phase two so a window-limited retry cannot change a proposal under its
existing ballot. Public procedures and journal/wire formats are unchanged, but
consumers must recompile for the internal node-layout change.

Sparse retransmission scans visit each used cell at most once per sweep rather
than wrapping repeatedly over the same cells. The expanded simulator also fixes
its duplicate-packet payload lifetime and waits for actual convergence rather than
ending on a quiet tick with catch-up timers pending.

The separate matched harness compares four pure state machines and validates
ordered payloads at every learner. CPU and memory profiles use Callgrind and
Massif, with no additional library runtime services or dependencies. The recorded
measurement contract distinguishes static storage, heap capacity, RSS, and native
elapsed time; historical results remain attributable to their original harness.

= Public Monorepo Launch

The project launches at `insanai/paxos-odin`. The executable formerly named
`paxos-cli` is now `paxodin`; the Odin package remains `paxos`. Release archives
cover Linux x86-64, Windows x86-64 and macOS Apple Silicon. The Python SDK ships
as `paxodin` with platform wheels and a standalone source distribution, alongside
its synchronous and asynchronous sessions and typed low-level node API.

Tag-driven releases check version parity, the full Odin gate, both Python
durability gates and the installed native artifacts before publishing. The website
provides an HTML book, POD index, generated API reference and downloadable PDFs.

Authored by Vikrant Rathore, with assistance from Ronak Rathore. Copyright © 2026
Vikrant Rathore and Ronak Rathore. All project distributions use the MIT License.
