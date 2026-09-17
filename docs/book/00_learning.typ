#import "theme.typ": *

#heading(level: 1, numbering: none)[Pedagogical Approach and Structure]

Distributed consensus is notoriously difficult because one must simultaneously account for
process crashes, network partitions, message loss, arbitrary delays, competing leaders, and
non-volatile storage invariants. Verbose descriptions rarely help; rigorous structure and progressive
disclosure do. This book builds understanding in deliberate layers, repeatedly anchored to one central
question.

#callout([The Central Question], [
  What fundamental invariant prevents two distinct values from ever being chosen in the same slot?
], kind: "idea")

Our editorial approach is guided by four core principles, directly reflecting the architectural
values articulated in POD 0001:

1. *Visualize concrete scenarios first.* We begin with three voters, one value, and a single slot
   before introducing generalized quorums and multi-slot logs. We describe the physical situation
   in clear language before introducing formal symbols.
2. *Make the reasoning inspectable.* We state explicit assumptions, precisely define terms such as
   "chosen", and formulate safety invariants before presenting the state transitions that preserve them.
   Safety guarantees are kept strictly distinct from liveness conditions.
3. *Treat code as executable specification.* We place Odin implementation excerpts directly beside
   the mathematical proof obligations they satisfy. We trace entire message flows whenever distributed
   interactions become subtle.
4. *Exercise mechanical sympathy.* We assign each variable a single unambiguous meaning, cleanly
   distinguish buffer indices from consensus slots, and use targeted counterexamples to demonstrate
   why tempting shortcuts fail.

Diagrams are designed to perform explanatory work: clarifying which participant witnessed an earlier vote,
which event must complete before sending a reply, and when storage may be safely reused. Labels convey
essential semantic ordering, while colour serves as a reinforcing cue.

== The Three Levels of Understanding

Every consensus mechanism in this book is examined at three distinct levels:

#table(
  columns: (auto, 1.2fr, 1.4fr),
  table.header([*Level*], [*Core Question*], [*Evidence of Mastery*]),
  [1. Safety Invariant], [What must never happen?], [You can articulate the invariant clearly in plain language.],
  [2. State Transition], [Which state change preserves the invariant?], [You can trace protocol events and verify that no past commitments are violated.],
  [3. Odin Implementation], [Which struct field, durable write, and message?], [You can navigate `Node` and `Effects` while maintaining the strict persist-before-send contract.],
)

Placing Odin excerpts directly alongside theoretical invariants is intentional: the code is the proof
obligation made concrete, and the invariant provides the exact rationale for why the code is structured as it is.

== Chapter Structure

To ensure concepts are internalized and verifiable, instructional chapters follow a structured progression:

1. *Objectives & Prerequisites:* Clear statements of concepts and skills introduced in the chapter.
2. *Thought Experiment:* An initial prediction exercise that highlights subtle failure modes before presenting the solution.
3. *Worked Derivation:* Step-by-step analysis of messages, state mutations, and underlying justifications.
4. *Code Inspection:* Concrete Odin procedures and data structures implementing the mechanism.
5. *Review & Exercises:* Structured questions and failure variations to test understanding.

== Suggested Reading Pathways

#table(
  columns: (auto, 1fr, 1.1fr),
  table.header([*Focus*], [*Recommended Sequence*], [*Practical Verification*]),
  [Protocol Engineer], [Parts I–III (Foundations, Single-Decree, Multi-Paxos, and Safety Argument), then Part VII (Reference), followed by Parts IV–VI.],
    [Diagram quorum intersections from memory; complete the protocol exercises before inspecting solutions.],
  [Systems Implementer], [This introduction, followed by Parts IV–VI (Library Architecture, Applications, and Evidence), returning to Parts I–III when protocol rationales are needed.],
    [Run `make check`; trace transitions in the replicated counter example; inspect simulation assertions under injected network and crash faults.],
)

== Repository Architecture

The principles and claims in this book correspond directly to runnable software in the repository:

- `src/`: The pure consensus engine. A bounded Multi-Paxos `Node` whose state resides in a columnar
  `Ledger`; a caller-owned `Effects` batch; optional rotating slot ownership; a `Replicated_Log_Node`
  supporting epoch isolation via stop-sign reconfiguration; a non-voting `Learner`; and an `Error` enum
  with explanatory diagnostic hints for every condition.
- `examples/counter.odin`: A standalone three-node replicated counter illustrating the complete host
  integration loop in approximately 130 lines of code.
- `tests/`: 79 deterministic test suites, including an exhaustive election test matrix, seeded reconfiguration
  scenarios, and rotating slot ownership tests.
- `sim/`: A deterministic fault simulator verifying safety invariants (agreement, validity, monotonic commitments,
  contiguity, and liveness) across single-leader and multi-proposer rotating configurations.
- `bench/`: Matched CPU benchmarks comparing Odin against Zig, Rust (OmniPaxos), and C (LibPaxos3), accompanied
  by callgrind and memory profile datasets.
- `tools/check.py`: Complete verification harness covering code style, multi-build compilation, durability contracts,
  and extensive simulation runs.

== Prerequisite Self-Assessment

Before proceeding to Part I, test your intuition against these four foundational questions:

1. Three nodes must agree on a single value in an asynchronous network. Why is a policy of "the first proposal to arrive wins" unsafe?
2. What fundamental guarantee does a majority quorum provide, and under what conditions can asymmetric read and write quorums provide the same safety guarantee?
3. What state must an acceptor persist to durable storage across crashes, and what failure occurs if this state is lost?
4. What is the precise distinction between a value being *chosen* versus being *known to be chosen*?

Revisit your answers after completing Part III. The conceptual distance between the two marks the core contribution of this book.

