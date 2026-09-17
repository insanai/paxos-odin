#import "theme.typ": *

#heading(level: 1, numbering: none)[How This Book Teaches]

Paxos is hard for a predictable reason: the reader must hold crashes, lost and
reordered messages, competing leaders, stable storage, and application state in mind
at once. More prose does not help; more structure does. This book therefore reveals
one layer at a time and keeps returning to a single question.

#callout([The organising question], [
  What fact prevents two different values from becoming chosen in the same slot?
], kind: "idea")

The editorial aim draws on four habits associated with Feynman, Lamport, Knuth,
and Dijkstra. These are our working principles, not quotations or claims that the
book reproduces any author's voice:

1. *Start with something the reader can picture.* Use three voters and one value
   before introducing a general set of quorums. Explain the example in ordinary
   language, then give its formal name.
2. *Make the reasoning inspectable.* State assumptions, define “chosen”, and name
   the invariant before presenting the transition that preserves it. Separate a
   safety claim from a condition for progress.
3. *Read the program as an explanation.* Place a small code excerpt beside the
   reason it exists. Show an entire trace when local rules are hard to compose.
4. *Spend complexity carefully.* Give each variable one meaning, distinguish an
   index from a slot, and use a counterexample to test a tempting simplification.

A diagram should answer a question: who remembers the earlier vote, which event
must precede a reply, or which storage may be reused? Labels carry that meaning;
colour is a second cue. The text explains the diagram's conclusion and its limits.

== The three representations

Read each major idea at three levels. Moving between them is a useful check on
understanding.

#table(
  columns: (auto, 1.2fr, 1.4fr),
  table.header([*Level*], [*Core question*], [*Evidence of understanding*]),
  [1. Safety goal], [What must never happen?], [You can state the invariant in plain words.],
  [2. State transition], [Which state changes keep it true?], [You can trace an event and show that no earlier commitment was broken.],
  [3. Odin effect], [Which field, which durable record, which message?], [You can use `Node` and `Effects` while keeping the write-before-send order.],
)

Placing the Odin excerpt beside the invariant that requires it is deliberate: the code
is the proof obligation made concrete, and the invariant is the reason the code has
that shape.

== The learning loop

The chapters use the following learning loop; reference sections can be consulted
directly:

1. *Orient*: the learning contract and a checkpoint on prerequisites.
2. *Predict*: write down what you think happens before the text shows it.
3. *Worked case*: every message and state change with its justification.
4. *Faded case*: an exercise with the middle missing.
5. *Teach it back*: explain the mechanism in plain words.
6. *Transfer*: change a quorum size, a delay, or a crash point and see what survives.

== Two routes through the book

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Reader*], [*Sequence*], [*Do, not only read*]),
  [Protocol learner], [Parts I--III including the safety argument, then VII (reference), then IV--VI.],
    [Draw the quorum-intersection picture from memory; complete the protocol exercises before reading the answers.],
  [Systems builder], [This chapter, then Parts IV--VI, returning to I--III when a rule needs its reason.],
    [Run `make check`; read the effects of one transition in the counter example; run the simulator with a seed of your own and read its oracles.],
)

== What this repository supplies

The claims in this book are backed by artefacts you can run:

- `src/`: the library. A pure, bounded Multi-Paxos `Node` whose durable state is a
  `Ledger` laid out as columns; a caller-owned `Effects` batch; rotating slot
  ownership as an option, so every member may propose; a `Replicated_Log_Node` with
  stop-sign reconfiguration and configuration-checked envelopes; a non-voting
  `Learner`; an `Error` enum in which every value has an explanation and a
  corrective hint.
- `examples/counter.odin`: a three-node replicated counter that shows the whole host
  contract in one file of about a hundred and thirty lines.
- `tests/`: 79 deterministic tests, including a 972-case election matrix, four
  seeded reconfiguration scenarios, and five rotating-ownership scenarios.
- `sim/`: a seeded fault simulator with agreement, validity, monotonicity,
  contiguity, liveness, and convergence oracles, run with one leader and with every
  node proposing in its own slots.
- `bench/`: matched CPU drivers, recorded profiles, and a separate historical
  harness with a journal-and-`fsync` variant.
- `tools/check.py`: style, unit tests in both build modes, contract fixtures, fault
  simulations, and smoke checks. Full timing and profiling runs are separate.

What the repository does not supply is listed just as plainly in Part VI, under the
capability map. There is no transport, no journal format, no client protocol, no lease,
and no model-checked specification here; each is either the host's job or a design
proposal in the POD series.

== Start with retrieval, not recognition

Before Part I, take a blank page and answer these four questions from whatever you
already believe. Keep the page.

1. Three machines must agree on one value. Why is "the first message to arrive wins"
   wrong?
2. What does a majority guarantee, and could different read and write quorum sizes
   provide the same guarantee?
3. What must a machine remember across a crash, and why?
4. When is a value *chosen*, as opposed to *known to be chosen*?

Answer them again after Part III and compare. The difference between the two pages
is what this book is for.
