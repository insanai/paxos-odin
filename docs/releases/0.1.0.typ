// paxos-odin 0.1.0 release notes
#import "../shared/theme.typ": configure-document

#show: configure-document.with(title: "paxos-odin 0.1.0 release notes")

#align(center)[
  #text(20pt, weight: "bold")[paxos-odin 0.1.0 release notes]
  #v(0.4em)
  #text(11pt)[Released 2026-09-16 · `VERSION :: "0.1.0"` in `src/paxos.odin`]
]
#v(1em)

The first tagged release of paxos-odin: a Paxos library that does no I/O,
written in Odin. A `Node` is a value; every transition consumes one input
and fills a caller-owned `Effects` batch. The host persists the writes,
confirms them, transmits the messages, and applies the committed entries.

= Highlights

- *Classic and Multi-Paxos in one bounded state machine.* Phase one runs in
  chunks of `CHUNK_SLOTS`; a stable leader then decides each value in one
  round trip. Recovery re-proposes the highest-ballot vote seen and fills holes
  with the host's no-op.
- *No I/O, no allocation.* The library imports only `base:` and `core:`.
  `Node`, `Effects`, `Membership`, `Replicated_Log_Node`, and `Learner` are
  parameterised by compile-time capacities; no transition allocates.
- *An enforced durability gate.* Reading `messages_slice` or calling `reset`
  while a batch holds unconfirmed writes stops the process with a diagnostic
  and a hint. `.Host_Managed` disables the gate for audited hosts.
- *A reconfigurable replicated log.* `Replicated_Log_Node` places commands and
  stop signs on one global slot line. A decided stop sign seals its
  configuration; `Log_Envelope` carries the configuration id so a delayed
  message from an old configuration is rejected with `.Configuration_Mismatch`.
- *Bounded windows with trim anchors.* The host advances a memory floor as it
  consumes the released prefix; a `Trim_Anchor` lets an acceptor answer phase
  one for history it no longer holds, and `Serve_Range_Request` asks the host
  to serve evicted history to a peer.
- *Non-voting learners.* A `Node` initialised with `node_init_learner` accepts
  commits only; the small `Learner` type releases certified decisions in
  contiguous order.
- *Errors that explain themselves.* All 42 non-`None` `Error` values have a
  title, a cause, and a `Hint:` from `explain_error`; a test enumerates the enum so a
  new value cannot ship without one.

= The API surface

One verb per operation, dispatched on the receiver:

```odin
paxos.init(&membership, ids[:])            paxos.init(&node, 1, membership)
paxos.init(&log, 1, epoch, membership)     paxos.init(&learner, epoch)
paxos.campaign(&node, noop, &effects)      paxos.propose(&node, value, &effects)
paxos.step(&node, envelope, &effects)      paxos.tick(&node, noop, &effects)
```

The proc groups in `src/paxos.odin`: `init`, `init_learner`, `restore`,
`restore_learner`, `continue_at`, `begin_recovery`, `campaign`, `propose`,
`propose_batch`, `step`, `tick`, `reconnected`, `request_catch_up`,
`learn_chosen`, `set_campaign_enabled`, `advance_memory_floor`,
`install_chosen_trim`, `current_leader`, `decided_through`, `leader_base`,
`proposal_frontier`, `committed_at`, `read_decided`, `is_leader_caught_up`,
`is_campaign_enabled`, `memory_floor`, `trim_anchor`, `role`, `ballot`, `id`,
`is_voting_member`, `durable_state`.

Effects: `reset`, `confirm_writes_durable`, `writes_slice`, `messages_slice`,
`committed_slice`, `requests_slice`, `requires_power_loss_barrier`,
`pre_durable_messages`, `is_empty`.

The long spellings (`node_*`, `replicated_log_*`, `learner_*`) and the short
log spellings (`log_init`, `log_reconfigure`, `log_envelope`, `log_step`,
`log_init_from_stop`, ...) remain available. Compatibility aliases `NodeId`,
`Log_Slot`, and `Vote_Ballot` are kept for one release.

Types declared together must share parameters:

```odin
Node    :: paxos.Node(Command, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS)
Effects :: paxos.Effects(Command, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS)
```

with `1 <= MAX_MEMBERS <= 128`, `WINDOW_SLOTS > 0`, and
`1 <= CHUNK_SLOTS <= WINDOW_SLOTS`. Defaults are 7, 256, and 64. A fifth
parameter, `GATE: Durability_Gate = .Enforced`, selects the gate.

The complete reference is Part VII of the book (`make docs`, then
`docs/build/paxos-spec.pdf`).

= Verification

- 48 tests under `tests/`, run by `make test` in both `-debug` and `-o:speed`
  by `make check`. They include a 972-case election matrix, 21 regression
  tests from the review in `docs/REVIEW.md`, and 3 reconfiguration scenarios
  each run under 16 fault seeds.
- A deterministic simulator (`sim/`) for 1 to 5 voters with drops,
  duplicates, link cuts, crashes at three points inside the host commit
  sequence, and restarts from a replayed journal. Oracles check agreement,
  validity, promise monotonicity, votes above promises, one value per ballot
  per slot, and contiguous release; a quiescence phase requires a fresh
  decision and full convergence.
- `tools/check_contracts.py`: eight programs the compiler must reject with a
  hint, and four durability fixtures in both build modes.
- `make check` runs all of the above plus style, the example, the benchmark
  JSON schema, and CLI failure propagation, in a temporary directory.

There is no model-checked specification in this repository. The evidence is
finite and executable, not exhaustive.

= Benchmarks

`make bench-compare` runs this library, paxos-zig 0.7.0, OmniPaxos 0.2.2, and LibPaxos3
one after another on one machine and records `bench/results/latest.json`; the book's
evidence chapter and the README read their tables from that file. On the recording host
(AMD Ryzen 7 5800H with Radeon Graphics, Linux 7.0.0-28-generic), nanoseconds per committed value with an in-process
transport were:

#table(
  columns: (auto, auto, auto, auto, auto),
  align: (left, right, right, right, right),
  [*workload*], [*paxos-odin*], [*paxos-zig*], [*OmniPaxos*], [*LibPaxos3*],
  [3 voters, 8 B, one at a time], [145], [114], [1,121], [2,265],
  [3 voters, 8 B, 8 in flight], [144], [116], [220], [–],
  [3 voters, 8 B, 64 in flight], [143], [115], [86], [–],
  [5 voters, 8 B, one at a time], [185], [208], [2,928], [–],
  [5 voters, 8 B, 8 in flight], [179], [207], [482], [–],
  [3 voters, 1 KiB, one at a time], [1,091], [2,744], [1,328], [–],
  [3 voters, 1 KiB, 8 in flight], [1,081], [2,735], [444], [–],
)

With a journal and one `fsync` per host commit round, this library costs
27.15 ms per value one at a time and
3.58 ms with group commit over eight values;
paxos-zig's equivalent modes cost 26.49 ms and
3.37 ms. The disk, not the protocol, is the bill.
In-memory numbers are a regression signal that moves with cache state and load; they
are not service latencies. Run `make bench`, `make bench-durable`, `make bench-compare`,
or `./bin/paxos-bench --iterations=N --json`.

= Known limits

- Membership is fixed per `Node`; a change is a new node started from a
  decided stop sign.
- Slots are global `u64` values that never reset; `Global_Slot_Exhausted`
  ends a log.
- `Window_Full` is the only backpressure. The host must consume the released
  prefix and call `advance_memory_floor`.
- `committed_slice` carries only this transition's decisions; it is not a
  recovery feed.
- Values are copied and compared with `==`; reference-bearing values must
  stay immutable and alive.
- Node ids are non-zero and must never be reused.
- A timed-out proposal is not known to have failed.
- `is_leader_caught_up` is not a lease. No leader leases or linearizable-read
  barriers are implemented (POD 0004 is an open discussion).
- All peers must use the same `CHUNK_SLOTS`; batches are bounded by it.
- The gate tracks one `Effects` batch. It cannot catch a host that copies the
  messages out through another buffer.

= Upgrading from the pre-release naming

#table(
  columns: (auto, auto),
  align: (left, left),
  [*before*], [*0.1.0*],
  [`NodeId`], [`Node_Id` (`NodeId` remains as an alias)],
  [CamelCase error values, e.g. `.NotLeader`], [Ada_Case, e.g. `.Not_Leader`],
  [`node_init_with_priority(&n, id, m, priority)`], [`node_init(&n, id, m, Node_Options{priority = priority})`],
  [`node_restore_at(&n, id, m, durable, floor, priority)`], [`node_restore(&n, id, m, durable, floor, Node_Options{priority = priority})`; `floor` and `options` default],
  [`Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, GATE)`], [`Effects(Value, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE)`; must match the `Node`],
  [`Host_Managed_Node` (`src/host_managed.odin`)], [Removed. Declare `Node(..., .Host_Managed)` and `Effects(..., .Host_Managed)`],
  [`replicated_log_init_from_stop(&n, id, stop, anchor, floor, priority)`], [`replicated_log_init_from_stop(&n, id, stop, stop_slot, anchor, options)`],
)

Every `Error` value is now Ada_Case and `explain_error` covers all of them; a
switch over the enum that named the old spellings will fail to compile, which
is the intended migration signal.
