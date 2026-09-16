#import "theme.typ": *

= How This Book Teaches

Paxos is notoriously difficult for a predictable psychological reason: a reader
must hold server crashes, network partitions, asynchronous message delays,
competing leader campaigns, stable storage syncs, and application state in mind
all at once. Adding more prose often makes cognitive overload worse.

This book therefore reveals one conceptual layer at a time, repeatedly returning
to one central question:

#callout([The Organizing Question], [
  What fact prevents two different values from becoming chosen in the same slot?
], kind: "idea")

Our learning architecture synthesizes five pedagogical principles:

1. *Cognitive Load Management*: Small conceptual units, integrated diagrams and
   code, worked traces before independent exercises, and gradual removal of hints.
   Working memory is limited; structured mental models allow an engineer to reason
   about multiple interacting distributed failure modes as a single unit.
2. *Self-Explanation Prompts*: Prompts ask you to justify *why* a protocol step is
   mathematically legal, rather than simply memorizing what happened.
3. *Plain-Language Teach-Backs*: Highlighting intuitive physical analogies
   (paper ledgers, parliament chambers, indelible ink) to ensure you can explain
   the invariant to another engineer without hiding behind jargon.
4. *Literate Systems Programming*: Code is organized around the human proof,
   not the compiler's internal file layout. The codebase remains idiomatic Odin;
   "literate" describes the clarity of exposition.
5. *Lamport's Hierarchy of Invariants*: State the safety goal, derive the inductive
   invariant, specify state transitions, and only then inspect wire messages and code.

== The Three Representations

Every major consensus concept appears across three distinct representations:

#table(
  columns: (auto, 1.2fr, 1.4fr),
  table.header([*Level*], [*Core Question*], [*Evidence of Mastery*]),
  [1. Safety Goal], [What must *never* happen?], [You can state the invariant in plain language without protocol jargon.],
  [2. State Transition], [Which state changes keep it true?], [You can trace an event and prove that no previous commitment was violated.],
  [3. Odin Effect], [Which struct field, disk write, and message implements it?], [You can use the `Node` and `Effects` API while strictly maintaining write-before-send durability.],
)

This three-tiered structure prevents split attention: an Odin code snippet is
presented directly beside the mathematical invariant that makes it necessary.

== The Six Moves of the Learning Loop

Every chapter proceeds through six systematic pedagogical moves:

1. *Orient*: Review the chapter's learning contract and prerequisite concepts.
2. *Predict*: Write down your prediction of an execution before the trace reveals it.
3. *Study a Worked Case*: Step through every message and state change with its justification.
4. *Complete a Faded Case*: Fill in missing votes, promises, or recovery choices.
5. *Teach It Back*: Close the text and explain the mechanism in plain words.
6. *Transfer*: Change the quorum size or network delay and verify if the property holds.

== Two Routes Through the Book

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Role*], [*Recommended Sequence*], [*Practical Exercises*]),
  [Protocol Learner], [Parts I through III, then Part V, followed by Part IV.],
    [Draw quorum intersection diagrams and complete every teach-back prompt from memory.],
  [Systems Builder], [This chapter, then Parts IV through VI, returning to Parts I--III as needed.],
    [Run `./bin/paxos-cli sim`, inspect the `Effects` ring buffer, and benchmark on your machine.],
)

== What the Paxos-Odin Codebase Supplies

To eliminate ambiguity, this repository explicitly implements:
- `paxos.Node`: A pure, bounded, allocation-free Multi-Paxos state machine.
- `paxos.Effects`: A caller-allocated buffer recording durable writes, outbound envelopes, and committed entries.
- `paxos.Replicated_Log`: A high-level replicated log supporting stop signs and configuration transitions.
- `paxos.Learner`: A non-voting learner window ensuring strictly gap-free contiguous delivery.
- Deterministic Unit Tests: 16 test cases verifying ballots, deduplication, hole filling, and durability barriers.
- Deterministic Chaos Simulator: Seeded fault injection testing packet drops, reordering, and node reboots with a central golden oracle.
- Benchmarking Tool: Five execution modes measuring sub-120 ns consensus latency in memory.
