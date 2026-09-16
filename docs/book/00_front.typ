#import "theme.typ": *

#title_page()
#pagebreak()

#align(center)[
  #text(size: 15pt, weight: "bold")[About this book]
]

This book explains one fundamental algorithm: Leslie Lamport's Paxos consensus
protocol. It also explains one concrete, production-grade implementation of that
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
  three-node counter in memory, build an event-driven host application, and verify
  formal safety guarantees without confusing a consensus protocol contract with an
  application-level contract.
], kind: "idea")

#v(1fr)
#align(center, text(size: 8.5pt, fill: gray)[
  Paxos-Odin Edition 0.1.0 · Written for Odin Nightly (dev-2026-09) · Typst 0.15+
])

#pagebreak()

= Preface

The usual introduction to Paxos starts too late. It begins with "Prepare" and
"Accept" messages. Those messages then look like arbitrary rules from a game whose
underlying purpose was forgotten.

We shall start much earlier. We shall ask a simple question:

Three machines must write one value on three pieces of paper. A machine may stop
at any moment. A network messenger may vanish into thin air. No machine may ever
erase ink that was once written. How can the machines guarantee that two
different values are never declared final?

The answer will grow in small, inevitable steps. Each step will eliminate one
tempting but flawed solution. When Prepare and Accept finally appear, they will
have no mystery left: they are the shortest, most natural names for facts that we
already need.

The style of this book is mathematical, but it is never dry or terse. We compute
small, concrete traces. We predict outcomes before seeing answers, explain
transitions in plain English, and deliberately inspect adversarial failure
scenarios. We keep an unrelenting ledger of the facts that survive every machine
crash and message loss.

The implementation follows the exact same pedagogical order:
1. First come values, node identities, and ballot tuples.
2. Next come promises, durable ballots, and votes.
3. Then come multi-slot logs, leader elections, log hole filling, and stable storage.
4. Finally come bounded memory windows, stop signs, and state machine replication.

At each step, we ask two fundamental questions:
- *What can go wrong?*
- *Which invariant prevents it?*

== Accompanying Artifacts

The repository provides concrete, executable code alongside this text:
- The core protocol engine in `src/protocol.odin`, `src/replicated_log.odin`, and `src/learner.odin`.
- A runnable three-node counter in `bench/main.odin` and `tests/`.
- A seed-driven chaos simulator in `sim/` with network partitions, node reboots, and a golden linearizability oracle.
- A five-mode benchmark matrix measuring pure in-memory state machine throughput on your host.

#callout([A principle of verification], [
  Testing can reveal a broken invariant. It cannot create an invariant. We
  first state the formal mathematical reason that the consensus engine is safe.
  We then use deterministic simulation and unit tests to search for flaws in our
  code and our understanding.
])
