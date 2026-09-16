# paxos-odin

A Paxos library that does no I/O, written in Odin.

English · [한국어](README.ko.md)

## The problem, and the trick

Three computers must keep one list, in the same order, forever. Any of them may
crash and come back, and the network between them may lose, duplicate, delay,
or reorder messages. That is the problem Paxos solves, and it is the whole of
what this library does.

The trick is that the library owns nothing. It has no sockets, no threads, no
clock, no files. A `Node` is a value in your memory. You hand it a message, a
tick, or a proposal; it hands you back an `Effects` batch: records to persist,
envelopes to send, entries that are now decided, and history a peer asked for.
Your program does the I/O.

Inside the node, Lamport's three variables per decree (the promise, the vote's
ballot, the vote's value) live in parallel arrays over a fixed window, with
bitmaps for the slots in use and the slots decided. A ballot is one 64-bit
integer. Values are never copied on the way out: a record or a message points
at the value inside the ledger, and the host copies it when it serialises.

There is one rule. **Persist every write in a batch before transmitting any
message from the same batch**, then call `confirm_writes_durable`. Reading the
messages before confirming, or resetting a batch that still holds unconfirmed
writes, stops the process with a diagnostic that names the violation and the
fix. That gate is on by default; it can be switched off for a host that has
been audited against four written rules (see below).

## Quick facts

- Classic (single-decree) and Multi-Paxos with a stable leader and chunked recovery.
- Rotating slot ownership as an option: every member proposes in its own slots
  with no phase one, idle owners skip, a crashed owner is revoked, and a revoked
  value is resubmitted (after Mencius, on the Synod's ballot rules).
- Written for Odin `dev-2026-09`; depends only on `base:` and `core:`.
- No allocation and no value copies in a transition. Every capacity is a
  compile-time parameter; the durable state is a struct of arrays.
- Tolerates crash and restart, message loss, duplication, delay, and reordering. Non-Byzantine.
- Up to 65,535 members; a window of any power of two; 1,024-voter quorums are tested.
- A safety argument in the book: axioms, sixteen lemmas, and the agreement theorem,
  each lemma naming the procedure that discharges it (POD 0008).
- A reconfigurable replicated log: stop signs seal a configuration, and
  configuration-checked envelopes reject traffic from an old one.
- Non-voting learners, both as a `Node` and as a small contiguous-release `Learner`.
- Every error value explains itself: `explain_error` returns a title, the cause, and a hint.

## Getting it

Copy or submodule the repository and import the `src` package by path:

```odin
import paxos "path/to/paxos-odin/src"
```

Or register it as a collection at build time and import it by name:

```sh
odin build . -collection:paxos=path/to/paxos-odin
```

```odin
import paxos "paxos:src"
```

Requirements: Odin `dev-2026-09` or newer for the library and tools; Typst 0.15
to build the book and the PODs; Python 3 for `make check`.

## A taste of the API

`Node` and `Effects` are declared with the same parameters: the value type, the
member capacity, the window size (a power of two), and the recovery chunk. The
compiler rejects a mismatch. The zero value of `Effects` is ready to use.

```odin
package main

import "core:fmt"
import paxos "../src"

Command :: struct {
	client_id:  u32,
	request_id: u32,
	amount:     i64,
}

// Node and Effects must be declared with the same parameters.
Node    :: paxos.Node(Command, 3, 64, 16)
Effects :: paxos.Effects(Command, 3, 64, 16)

// The host loop: persist, confirm, transmit, apply.
host_commit :: proc(effects: ^Effects) {
	for w in paxos.writes_slice(effects) {
		_ = w // append to the journal; a vote or decision points at its value
	}
	// fsync the journal here
	paxos.confirm_writes_durable(effects)
	for envelope in paxos.messages_slice(effects) {
		_ = envelope // hand to the transport
	}
	for entry in paxos.committed_slice(effects) {
		_ = entry.value^ // apply in slot order; the pointer is valid until the next transition
	}
	for request in paxos.requests_slice(effects) {
		_ = request // serve trimmed history from the host's journal
	}
}

main :: proc() {
	membership: paxos.Membership(3)
	ids := [3]paxos.Node_Id{1, 2, 3}
	assert(paxos.init(&membership, ids[:]) == .None)

	node: Node
	assert(paxos.init(&node, 1, membership) == .None)
	// or, with a tie-breaking priority:
	assert(paxos.init(&node, 1, membership, paxos.Node_Options{priority = 1}) == .None)

	effects: Effects
	noop := Command{}
	assert(paxos.campaign(&node, noop, &effects) == .None)
	host_commit(&effects)

	// For every envelope the transport decodes for this node:
	envelope: paxos.Envelope(Command)
	if err := paxos.step(&node, envelope, &effects); err != .None {
		fmt.eprintln(paxos.explain_error(err))
	}
	host_commit(&effects)

	// Once the node is leader, propose. The slot is returned with the error.
	slot, err := paxos.propose(&node, Command{client_id = 1, request_id = 7, amount = 10}, &effects)
	if err != .None {
		fmt.eprintln(paxos.explain_error(err))
	}
	host_commit(&effects)
	fmt.println("proposed in slot", slot)

	// Advance the logical clock once per host tick.
	assert(paxos.tick(&node, noop, &effects) == .None)
	host_commit(&effects)
}
```

`paxos.init`, `paxos.campaign`, `paxos.propose`, `paxos.step`, and
`paxos.tick` are proc groups that dispatch on the receiver; the long spellings
(`node_propose`, `replicated_log_propose`, `learner_learn_chosen`) remain
available. Records and envelopes point at values inside the node's ledger and
stay valid until that node's next transition; an in-process transport copies
the value when it queues an envelope, exactly as a codec would (the `Packet`
type in the example). The complete runnable version of this loop is
[`examples/counter.odin`](examples/counter.odin). Its output:

```
$ odin run examples/counter.odin -file
node 1 is the leader
proposed request 101 in slot 1
slot 1: +10 -> counter = 10
proposed request 102 in slot 2
slot 2: +25 -> counter = 35
proposed request 201 in slot 3
slot 3: -5 -> counter = 30
counter = 30 on all 3 nodes
```

With rotating ownership there is no campaign: every node proposes in the slots
it owns, and the cluster decides them concurrently.

```odin
owners: [3]Node
for &node, i in owners {
	assert(paxos.init(&node, paxos.Node_Id(i + 1), membership,
		paxos.Node_Options{rotating_ownership = true}) == .None)
}
slot, err := paxos.propose(&owners[1], Command{amount = 5}, &effects) // node 2 owns slots 2, 5, 8, ...
```

The replicated log wraps a `Node` whose value type is `Entry`: either a command
or a stop sign that seals the configuration and names the next one.

```odin
Log         :: paxos.Replicated_Log_Node(Command, 3, 64, 16)
Entry       :: paxos.Entry(Command, 3)
Log_Effects :: paxos.Effects(Entry, 3, 64, 16)

log: Log
effects: Log_Effects
assert(paxos.init(&log, 1, 1, membership) == .None)     // node 1, configuration 1
assert(paxos.campaign(&log, Command{}, &effects) == .None)

// Seal configuration 1 and name configuration 2.
next := [3]paxos.Node_Id{1, 2, 4}
if _, err := paxos.log_reconfigure(&log, 2, next[:], nil, &effects); err != .None {
	fmt.eprintln(paxos.explain_error(err))
}

// Stamp outbound messages with the configuration; check inbound ones.
for m in paxos.messages_slice(&effects) {
	stamped := paxos.log_envelope(&log, m)
	_ = paxos.log_step(&log, stamped, &effects)   // .Configuration_Mismatch on a stale one
}

// Once the stop sign is decided, the next configuration starts at stop_slot + 1.
if stop, decided := paxos.log_stop_sign(&log); decided {
	next_log: Log
	_ = paxos.log_init_from_stop(&next_log, 1, stop, paxos.log_stop_slot(&log), paxos.log_trim_anchor(&log))
}
```

A host that groups several transitions behind one storage barrier may declare
`Node` and `Effects` with a fifth parameter, `.Host_Managed`, which disables the
runtime gate. That is an audited exception, not a mode. Such a host must
guarantee, by construction, that:

1. every write of a transition is durable before any message of that transition reaches a peer;
2. a batch is never discarded while it still holds unconfirmed writes;
3. committed entries are applied only after their commit record is durable;
4. a crash between the writes and the barrier is recovered from the journal,
   never by confirming writes that did not complete.

The full API reference is Part VII of the book: run `make docs` and open
`docs/build/paxos-spec.pdf`.

## How do we know it works

**The safety argument.** The book states the model as axioms and proves
agreement from Lamport's B1--B3, then proves that chunked recovery, the bounded
window, durability ordering, rotating ownership, and stop signs each preserve
the theorem. Every lemma names the procedure that discharges its premise and
the test or oracle that exercises it (POD 0008).

**Tests.** `make test` runs 55 tests in `tests/`. They include a 972-case
election matrix (every three-voter assignment of no vote / ballot 1 / ballot 2,
every first-response order, every intersecting quorum pair; a value chosen by an
earlier quorum must survive), 21 regression tests from the review recorded in
POD 0007, 5 rotating-ownership scenarios (concurrent owners, skips, revocation
of a crashed owner, a revocation that keeps a vote it finds, resubmission), and
4 reconfiguration scenarios each run under 16 seeds of drop, duplicate, and
reorder faults, one of them under rotating ownership.

**The simulator.** `sim/` drives one to five voters from one seed, with one
leader or, under `--ownership`, with every node proposing in its own slots. Each step
delivers a random queued envelope, ticks a node, proposes (sometimes a batch),
cuts or heals a link, crashes a node (keeping a read quorum alive), restarts a
node from its replayed journal, or reports a reconnection. A crash can land at
three points inside the host commit sequence: before any write, after a prefix
of the writes, or after every write and a prefix of the messages. Oracles run
after every transition: agreement (one value per slot, fixed by the first
durable quorum), validity (only proposed values or the no-op), no promise
regression, no vote below a promise, one value per ballot per slot, and
contiguous release. After the fault phase the harness heals every link,
restarts every node, and requires a fresh proposal to be decided and every
node to hold the whole golden log. A failure prints the replay command:
`paxos-sim --seed=N --steps=N --nodes=N --verbose`. This harness, checking
agreement at the vote level rather than at the commit level, is what found the
one safety bug of the redesign: an owner's round-zero accept leaving before the
storage barrier, so that a restarted owner reused its ballot for a new value.
Round-zero accepts now wait for the barrier.

**Contract fixtures.** `tools/check_contracts.py` compiles nine programs that
must be rejected (zero window, a window that is not a power of two, zero chunk,
chunk larger than window, zero members, 65,536 members, zero learner window, a
non-comparable value type, `Effects` parameters that differ from the `Node`'s)
and checks that each
diagnostic carries a hint. It then builds four durability fixtures in both
`-debug` and `-o:speed` and requires the two misuses to abort with the named
diagnostic and the two correct orderings to run.

**`make check`.** Runs style (the Zen constraints from POD 0001, `-vet -strict-style`), the tests in
`-debug` and `-o:speed`, the contract fixtures, 120 simulations of 10,000 steps
(1, 3, and 5 nodes × 20 seeds × both modes; `--seeds` and `--steps` widen it), the counter
example, the benchmark JSON schema, and a check that the CLI propagates a
failing subprocess. Everything is built in a temporary directory so a stale
binary cannot mask a failure.

There is no model-checked specification in this repository. The evidence is
finite and executable, not exhaustive.

## Benchmarks

Four implementations ran the same workloads on this machine in one session,
one after another: this library, [paxos-zig](https://github.com/insanai/paxos-zig)
0.7.0, [OmniPaxos](https://github.com/haraldng/omnipaxos) 0.2.2 (Rust), and
[LibPaxos3](https://bitbucket.org/sciascid/libpaxos) (C). `make bench-compare`
runs them and records one attributable results file; the tables below are read
from it, never typed by hand.

Host: AMD Ryzen 7 5800H with Radeon Graphics, Linux 7.0.0-28-generic, odin version dev-2026-09-nightly:a2fb372, zig 0.16.0, rustc 1.98.1 (48a229cea 2026-09-01); Odin built with `-o:speed -no-bounds-check -microarch:native`; recorded 2026-09-16T14:40:24Z in `bench/results/latest.json`.

Nanoseconds per committed value, in-process transport, no serialisation,
median of repeated samples (lower is better):

| workload | paxos-odin | paxos-zig | OmniPaxos | LibPaxos3 |
|---|---:|---:|---:|---:|
| 3 voters, 8 B, one at a time | 165 | 117 | 997 | 2,247 |
| 3 voters, 8 B, 8 in flight | 149 | 117 | 196 | – |
| 3 voters, 8 B, 64 in flight | 149 | 112 | 78 | – |
| 5 voters, 8 B, one at a time | 225 | 210 | 2,714 | – |
| 5 voters, 8 B, 8 in flight | 197 | 206 | 445 | – |
| 3 voters, 1 KiB, one at a time | 486 | 2,700 | 1,244 | – |
| 3 voters, 1 KiB, 8 in flight | 521 | 2,740 | 419 | – |
| 3 owners, 8 B, one at a time, rotating ownership | 169 | – | – | – |
| 3 owners, 8 B, 8 in flight, rotating ownership | 161 | – | – | – |

With a journal file per node and a storage barrier (`fsync`) per host commit
round, on the same ZFS volume:

| library | mode | per value | fsync per value |
|---|---|---:|---:|
| paxos-odin | fsync per commit round, one value | 27.99 ms | 6.00 |
| paxos-odin | fsync per commit round, 8 values | 3.82 ms | 0.75 |
| paxos-zig | fsync-each | 28.07 ms | – |
| paxos-zig | group8 | 3.65 ms | – |

Read these for what they are. On three voters with 8-byte values paxos-zig is
between a fifth and thirty percent cheaper per value than this library; with
five voters the two are within a tenth of each other, this library ahead with
eight in flight; with 1 KiB values this library is more than five times
cheaper, because a value is never copied between proposal and commit: records
and messages point at the one copy in the ledger. Rotating ownership costs
within a tenth of a single leader per value on the same three nodes, and in
exchange every node proposes with no round trip to a leader. OmniPaxos pays for
allocation and locking in the one-at-a-time mode and wins in two rows, at 64
values in flight and with 1 KiB values at eight in flight, where it coalesces
many entries into few envelopes; this library and paxos-zig always send one
envelope per value. LibPaxos3 runs a heavier
twelve-envelope path with phase-one pre-execution. None of these numbers is a
service latency, and the durable rows show that the disk, not the protocol, is
the bill: both bounded libraries land within a few percent of each other once
an `fsync` sits in the path.

```sh
make bench                                   # this library, in-memory modes
make bench-durable                           # adds the journal-and-fsync modes
make bench-compare                           # all four implementations, records bench/results/
./bin/paxos-bench --iterations=N --json      # machine-readable report
```

## The book and the PODs

`make docs` compiles `docs/book.typ` to `docs/build/paxos-spec.pdf`, the POD
index to `docs/build/pod-index.pdf`, and every registered POD record to
`docs/build/pod-NNNN-<slug>.pdf`.

The book has a preface, a chapter on how it teaches, and eight parts:

| part | chapter |
|---|---|
| I. One decision | Foundations of Consensus |
| II. The complete ballot | The Single-Decree Protocol |
| III. A sequence of decisions | Multi-Paxos Log Replication |
| III. (continued) | The Safety Argument: axioms, lemmas, and the agreement theorem |
| IV. The Odin library | Bounded Core State Machine; Advanced Replicated Log Features; Rotating Slot Ownership; Writing Reviewable Consensus Code |
| V. Three worked systems | The replicated counter, a key-value host design, a multi-region deployment |
| VI. Evidence | Validation, Testing, and Operations |
| VII. Desk reference | Consensus Desk Reference |
| VIII. Conformance | Lamport Conformance Appendix |

Paxos Odin Discussions (PODs) are the design records, one Typst file each under
`docs/pod/records/`. `docs/pod/registry.typ` is the source of truth for the
list; at the time of writing it holds:

| POD | title | state |
|---|---|---|
| 0001 | The Paxos Odin Discussion Process | committed |
| 0002 | Paxos-Odin: Architecture and Pure State Machine Design | committed |
| 0003 | Durability Contracts, Window Reuse, and Trim Anchors | committed |
| 0004 | Fast-Path Leader Leases and Linearizable Read Verification | discussion |
| 0005 | The Idiomatic Odin API Surface | committed |
| 0006 | Reconfiguration and Epoch Isolation | committed |
| 0007 | Review Findings and Verification Evidence | committed |
| 0008 | Safety Argument: Axioms, Lemmas, and Proof Obligations | committed |
| 0009 | The Data-Oriented Ledger | committed |
| 0010 | Rotating Slot Ownership | committed |

`./bin/paxos-cli pod list`, `pod new <slug>`, and `pod promote <slug>` manage
the records.

## Scope and operational contract

- **Membership is fixed per `Node`.** A configuration change is a new `Node` (or
  `Replicated_Log_Node`) started from a decided stop sign; the old one is sealed.
- **Slots are global `u64` values that never reset.** The next configuration
  continues at the stop slot plus one. `Global_Slot_Exhausted` ends a log; it
  never wraps.
- **Backpressure is `Window_Full`.** A proposal that would put more than
  `WINDOW_SLOTS` open slots above the memory floor is refused. Deliver the
  released prefix, persist it, and call `advance_memory_floor`.
- **`committed_slice` is not a recovery feed.** It carries only the entries
  decided by this transition. History below the memory floor comes from the
  host's journal or image, on a `Serve_Range_Request`.
- **Values are fixed-size and referenced, not copied.** The ledger stores one
  value per window cell; records, messages, and committed entries point at it
  and are valid until that node's next transition. Serialise or copy before
  then. Values are compared with `==`; prefer fixed-size records or ids.
- **The window is a power of two.** `WINDOW_SLOTS` is masked, not divided, to
  find a cell; the compiler rejects any other size with a hint.
- **Ownership order is membership order.** Under rotating ownership slot `s`
  belongs to member `(s - 1) mod N` in sorted membership order. A stalled prefix
  is revoked after `election_timeout_ticks`; a full window applies backpressure
  to every owner.
- **Node ids are non-zero and never reused.** Zero is a sentinel. An id names
  one durable journal for the life of the cluster.
- **A timed-out proposal is not known to have failed.** It may still be chosen
  later. Re-proposing it can decide it twice; give commands an id and let the
  application deduplicate.
- **`is_leader_caught_up` is not a lease.** It reports that the leader has
  delivered its inherited prefix. Linearizable reads need a host quorum,
  read barrier, or a correctly implemented lease, none of which this library
  provides.

## Development

| command | what it does |
|---|---|
| `make build` | Build `bin/paxos.o`, `bin/paxos-sim`, `bin/paxos-bench`, and `bin/paxos-cli` |
| `make test` | `odin test tests` |
| `make vet` | `odin check` every package with `-vet -strict-style` |
| `make check` | The full verification run in `tools/check.py` |
| `make sim` | One seeded simulation (`--seed=42 --steps=1024`) |
| `make bench` | The in-memory benchmark |
| `make bench-durable` | The benchmark with a journal and `fsync` per commit round |
| `make example` | `odin run examples/counter.odin -file` |
| `make docs` | Compile the book and the POD records to PDF |
| `make clean` | Remove `bin/` and `docs/build/` |

`./build.sh` bootstraps `bin/paxos-cli`. Its commands are `build
[all|lib|test|sim|bench|cli]`, `test`, `sim [--seed=N] [--steps=N] [--nodes=N]
[--verbose]`, `bench [--iterations=N] [--json] [--durable] [--journal-dir=PATH]`,
`example`, `docs [all|book|index|pod|pod-NNNN|releases|html]`, `check`, and
`pod list|new|promote`. `sim` also takes `--ownership`; `bench` takes
`--only=WORKLOAD`.

Style: the Zen of Odin for InsanAI (POD 0001): 99 columns soft, 108 hard, files at most 1,408 lines, procedure bodies at most 70 lines of logic, tabs, `-vet -strict-style` clean in every package. The
library is fully parametric, so its bodies are checked through the packages
that instantiate it. Documentation other than the two READMEs and
[`CONTRIBUTING.md`](CONTRIBUTING.md) is written in Typst; see
`CONTRIBUTING.md` before opening a change.

## Directory structure

```
paxos-odin/
├── src/                     The library package
│   ├── paxos.odin           VERSION, defaults, proc groups, short spellings
│   ├── ballot.odin          Node_Id, Slot, the packed Ballot, cell_of
│   ├── bit_set.odin         Bit_Set(N): fixed bitmaps with word-wise scans
│   ├── membership.odin      Membership with a sorted index and quorum sizes
│   ├── ledger.odin          Ledger: Lamport's variables in columns; the Write records
│   ├── messages.odin        The nine messages, Envelope, Committed, host requests
│   ├── effects.odin         Effects and the durability gate
│   ├── node.odin            Node, Node_Options, init/restore/queries
│   ├── election.odin        Phase one: campaigns, promises, chunked recovery
│   ├── consensus.odin       Phase two: accepts, decisions, ticks, step
│   ├── ownership.odin       Rotating slot ownership: suggest, skip, revoke, resubmit
│   ├── replicated_log.odin  Replicated_Log_Node, Stop_Sign, Entry, Log_Envelope
│   ├── learner.odin         Learner: contiguous release of certified decisions
│   └── errors.odin          Error and explain_error
├── examples/counter.odin    Three-node replicated counter
├── tests/                   55 tests (odin test tests) and the shared harness
├── sim/                     Deterministic fault simulator (paxos-sim), both modes
├── bench/                   In-memory and durable benchmark (paxos-bench); results/
├── cli/                     paxos-cli: build, test, sim, bench, example, check, docs, pod
├── tools/                   check.py, check_style.py, check_contracts.py, bench_compare.py
├── docs/
│   ├── book.typ, book/      The book (Typst)
│   ├── pod/                 POD records, registry, index, bundle, template
│   ├── shared/              Typst theme and POD layout
│   ├── releases/            Release notes (Typst; 0.1.0.typ, 0.2.0.typ)
│   └── build/               Compiled PDFs and HTML
├── Makefile
├── build.sh
├── CONTRIBUTING.md
└── LICENSE
```

## License

MIT. See [LICENSE](LICENSE).
