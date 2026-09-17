#import "theme.typ": *

= How This Book Teaches

Paxos is hard for a predictable reason: the reader must hold crashes, lost and
reordered messages, competing leaders, stable storage, and application state in mind
at once. More prose does not help; more structure does. This book therefore reveals
one layer at a time and keeps returning to a single question.

#callout([The organising question], [
  What fact prevents two different values from becoming chosen in the same slot?
], kind: "idea")

The design of the book borrows five ideas from the learning sciences and states them
as constraints, not guarantees:

1. *Small units, worked before faded.* Every mechanism appears first as a fully worked
   case, then as a case with gaps to fill, then as a transfer question. This follows
   the worked-example research of Sweller and Renkl: novices learn more from studying
   a complete solution than from solving too early.
2. *Self-explanation prompts.* The `Predict` and `Teach it back` boxes ask you to
   state *why* a step is legal, not only what happened. Chi's studies found that the
   act of explaining is where the learning happens.
3. *Retrieval, not recognition.* Exercises appear without their answers; the answers
   sit in the desk reference so you can check yourself after an attempt. Roediger and
   Karpicke showed that recalling beats re-reading.
4. *Plain-language teach-backs.* Each chapter ends by asking you to explain the
   mechanism without protocol vocabulary. If the explanation needs the word
   "ballot" to work, you have memorised a name rather than understood a fact.
5. *Lamport's order.* State the safety goal, derive the inductive invariant, specify
   the state transitions, and only then look at wire messages and code. Lamport wrote
   his paper in that order; this book keeps it.

== The three representations

Every major idea appears at three levels, and mastery means moving between them
freely.

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

Each chapter moves through six steps:

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
    [Draw the quorum-intersection picture from memory; complete exercises 1.1 to 12.1 before reading the answers.],
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
- `tests/`: 69 deterministic tests, including a 972-case election matrix, four
  seeded reconfiguration scenarios, and five rotating-ownership scenarios.
- `sim/`: a seeded fault simulator with agreement, validity, monotonicity,
  contiguity, liveness, and convergence oracles, run with one leader and with every
  node proposing in its own slots.
- `bench/`: an in-memory cost benchmark and a durable variant with a journal and
  `fsync`.
- `tools/check.py`: one command that runs all of the above in both build modes.

What the repository does not supply is listed just as plainly in Part VI, under the
capability map. There is no transport, no journal format, no client protocol, no lease,
and no model-checked specification here; each is either the host's job or a design
proposal in the POD series.

== Start with retrieval, not recognition

Before Part I, take a blank page and answer these four questions from whatever you
already believe. Keep the page.

1. Three machines must agree on one value. Why is "the first message to arrive wins"
   wrong?
2. Why must a majority be involved, and what exactly does a majority guarantee?
3. What must a machine remember across a crash, and why?
4. When is a value *chosen*, as opposed to *known to be chosen*?

Answer them again after Part III and compare. The difference between the two pages
is what this book is for.
