#import "theme.typ": *

#title_page()
#pagebreak()

#align(center)[
  #text(size: 15pt, weight: "bold")[About this book]
]

*Authorship and license.* The code is authored by Vikrant Rathore, with
assistance from Ronak Rathore. Copyright © 2026 Vikrant Rathore and Ronak Rathore.
The library, Python SDK, CLI and documentation are released under the MIT License;
the repository's `LICENSE` contains the complete terms.

The public monorepo is #link("https://github.com/insanai/paxos-odin")[insanai/paxos-odin].
The #link("https://insanai.github.io/paxos-odin/")[project website] provides this book
and the PODs as HTML, their PDFs, and the generated Python API reference.

This book explains one fundamental algorithm: Leslie Lamport's Paxos consensus
protocol. It also explains one concrete, bounded implementation of that
algorithm written in the *Odin* programming language: `paxos-odin`.

The two tasks are kept together throughout this text. A line of systems code is
easier to trust when we understand the mathematical proof obligation that requires
it. Conversely, a proof of safety is easier to remember when we can point directly
to the struct field that carries its meaning.

The source is written in Typst. The diagrams use Fletcher and CeTZ. The code is
idiomatic Odin. The consensus protocol is grounded in Leslie Lamport's seminal
papers, "The Part-Time Parliament" (ACM TOCS 1998) and "Paxos Made Simple" (2001);
the reconfiguration and epoch-sealing layer is derived from the stop-sign
construction described in Lamport, Malkhi, and Zhou's "Reconfiguring a State Machine".

#book_quote([
  Early in this millennium, the Aegean island of Paxos was a thriving mercantile
  center. Though its citizens were very busy with their business, they needed
  a government to lead them and make communal decisions.
], [Leslie Lamport, "The Part-Time Parliament"])

#v(8mm)
#callout([The primary promise], [
  A careful reader should be able to derive the core Paxos safety invariant, trace
  it directly into the struct fields and effects of `paxos-odin`, run a replicated
  three-node counter in memory, build an event-driven host application, and inspect
  the safety argument and its assumptions without confusing a consensus protocol contract with an
  application-level contract.
], kind: "idea")

#v(1fr)
#align(center, text(size: 8.5pt, fill: gray)[
  paxos-odin 0.2.0 · Odin dev-2026-09 · Typst 0.15
])

#pagebreak()

#heading(level: 1, numbering: none)[Preface]

The usual introduction to Paxos starts too late. It begins with "Prepare" and
"Accept" messages. Those messages then look like arbitrary rules from a game whose
underlying purpose was forgotten.

We shall start much earlier. We shall ask a simple question:

Three machines must write one value on three pieces of paper. A machine may stop
at any moment. A network messenger may vanish into thin air. No machine may ever
erase ink that was once written. How can the machines guarantee that two
different values are never declared final?

We build the answer by testing small examples. Each example exposes a flaw in a
tempting solution and gives us a condition the next solution must satisfy. Prepare
and Accept then become messages that carry those conditions between machines.

We compute small traces, predict outcomes before seeing answers, and explain each
transition in plain language. Then we move a crash or delay a message and ask which
facts still hold. The formal argument collects those facts into invariants.

The implementation follows the exact same pedagogical order:
1. First come values, node identities, and ballots.
2. Next come promises, durable ballots, and votes.
3. Then come multi-slot logs, leader elections, log hole filling, and stable storage,
   and the chapter that proves the whole construction safe.
4. Finally come bounded memory windows, rotating slot ownership, stop signs, and
   state machine replication.

At each step, we ask two fundamental questions:
- *What can go wrong?*
- *Which invariant prevents it?*

== How to read the book

Parts I through III derive the protocol from one safety question, end with a
sequence of decisions, and close with the safety argument: axioms, lemmas, and the
proof that each departure from the textbook preserves agreement. Part IV is the
library: the bounded state machine, the host contract, the advanced features,
rotating slot ownership, and the coding rules that keep the code reviewable.
Part V builds three systems on it. Part VI is the evidence and its limits. Part VII is
the desk reference, with the answers to selected exercises, and Part VIII maps
Lamport's paper to the procedures that implement it. Part IX develops the proposed
Python SDK, keeping its future interface distinct from the implemented Odin core.

== Audience and prerequisites

You need sets, integer arithmetic, and the willingness to accept that a process can
stop between any two instructions. Odin is read, not required: every excerpt is short
and explained. If you already know Paxos, start with the checkpoint at the top of
Part I and skip forward when it passes.

== Notation

- $N$ voters; a quorum $Q$; $Q_1$ the phase-one (read) quorum and $Q_2$ the phase-two
  (write) quorum. Intersection is written $Q_1 inter Q_2 != emptyset$.
- A ballot is the triple $(r, p, n)$: round, priority, node, ordered
  lexicographically. The library packs the triple into one 64-bit integer so that
  the lexicographic order is integer comparison.
- The owner of slot $s$ under rotating ownership is member $(s - 1) mod N$ in
  ascending node-id order; its ballot in that slot has round $0$.
- Slots are one-based; $s = 0$ means "no slot".
- Code identifiers appear in `monospace`; Odin types are `Ada_Case`, procedures are
  `snake_case`, error values are written with a leading dot, as in `.Not_Leader`.

== Commands used in the book

#code_file("shell", [
```sh
make build                       # library object, simulator, benchmark, CLI into bin/
make test                        # odin test tests
make check                       # style, tests in two builds, contracts, 240 seeded simulations, smoke runs
make example                     # the three-node counter
./bin/paxos-sim --seed=7 --steps=10000 --nodes=5 --verbose
./bin/paxos-sim --seed=7 --steps=10000 --nodes=5 --ownership   # every node proposes
./bin/paxos-bench --durable      # in-memory modes plus journal-and-fsync modes
make bench-matched               # matched CPU workloads across four libraries
make bench-profile               # Callgrind and Massif evidence
make bench-compare               # historical harness, including durable modes
make docs                        # this book and the POD records as PDF
```
])

== Accompanying artefacts

- The library in `src/`: the core in ten files (`ballot.odin`, `bit_set.odin`,
  `membership.odin`, `ledger.odin`, `messages.odin`, `effects.odin`, `node.odin`,
  `election.odin`, `consensus.odin`, `ownership.odin`), then `replicated_log.odin`
  (stop signs and configuration-checked envelopes), `learner.odin`, `errors.odin`,
  and `paxos.odin` (the unified surface).
- `examples/counter.odin`: the three-node replicated counter walked through in Part V.
- `sim/`: the seeded fault simulator with its oracles, in single-leader and
  rotating-ownership modes.
- `bench/`: the in-memory and durable benchmarks.
- `tools/check.py`: the complete verification run.

#callout([A principle of verification], [
  Testing can reveal a broken invariant. It cannot create an invariant. We
  first state the formal mathematical reason that the consensus engine is safe.
  We then use deterministic simulation and unit tests to search for flaws in our
  code and our understanding.
])
