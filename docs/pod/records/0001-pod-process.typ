#let pod-number = "0001"
#let pod-title = "The Paxos Odin Discussion Process"
#let pod-state = "committed"
#let pod-created = "2026-09-16"
#let pod-discussion = "The POD process, the Zen of Odin for InsanAI, and its enforced structural constraints"
#let pod-labels = ("process", "documentation", "cli")
#let pod-authors = ("Vikrant Varma <vikrant@insan.ai>", "Paxos Odin Contributors")
#let pod-category = "Process Memo"
#let pod-status = "Committed"
#let pod-last-updated = "2026-09-16"

#import "../../shared/pod.typ": pod-document

#show: doc => pod-document(
  pod-number,
  pod-title,
  doc,
  authors: pod-authors,
  state: pod-state,
  created: pod-created,
  discussion: pod-discussion,
  labels: pod-labels,
  category: pod-category,
  status: pod-status,
  last-updated: pod-last-updated,
)

= Abstract

This document defines the *Paxos Odin Discussions (POD)* RFC process, metadata schema, authoring lifecycle, and CLI tooling for `paxos-odin`. Modeled directly after the Zen Discussion Series (ZDS) from `zenfmt`, POD records serve as immutable architectural specifications, protocol derivations, and process memos for consensus engineering.

= Introduction

Distributed consensus libraries require uncompromising precision. Subtle design choices—such as write-ahead ordering, sliding-window recycling, and quorum intersections—cannot be captured solely in inline source comments or transient issue tracker threads.

POD provides a structured, versioned, Typst-rendered specification pipeline embedded in the repository.

= The POD Lifecycle

A POD document progresses through five standardized states:

1. *Prediscussion (Draft)*: A placeholder file named `XXXXX-<slug>.typ` created from `docs/pod/template/rfc-template.typ`. In this state, authors outline ideas and gather initial informal feedback.
2. *Discussion*: A numbered document (`NNNN-<slug>.typ`) actively reviewed by maintainers and contributors.
3. *Committed*: Consensus has been reached, the design is accepted, and implementation is scheduled or completed.
4. *Published*: The specification is finalized and frozen as a permanent reference.
5. *Abandoned*: The proposal was withdrawn or superseded by another record.

= Numbering & Promotion Workflow

To prevent Git merge conflicts on sequence numbers across branches, new proposals begin with the placeholder `XXXXX`.

The `paxos-cli` automation manages the entire lifecycle:
```sh
# 1. Create a new draft
./bin/paxos-cli pod new leader-leases

# 2. List all active records and draft placeholders
./bin/paxos-cli pod list

# 3. Promote the draft to the next permanent 4-digit number
./bin/paxos-cli pod promote leader-leases

# 4. Compile PDFs via Typst
./bin/paxos-cli docs pod
```

= Registry and Compilation

Every promoted record is registered in `docs/pod/registry.typ`. The document suite is compiled to PDF using the installed `typst` binary:
- Individual records: `docs/build/pod-NNNN-<slug>.pdf`
- Master Index: `docs/build/pod-index.pdf`
- Complete Book: `docs/build/paxos-spec.pdf`

= The Zen of Odin for InsanAI

Every POD, and every line of Odin in this repository, is written under one short creed.
It is quoted in full so that a reviewer can point at the line a change violates.

#block(
  width: 100%,
  inset: 12pt,
  radius: 4pt,
  fill: rgb("f8fafc"),
  stroke: 0.6pt + rgb("cbd5e1"),
)[
  #set text(style: "italic")
    Data is real; code is just the stream. \
  Explicit is better than a hidden scheme. \
  Simple blocks beat abstractions built too high, \
  A mere mortal should see how the segments tie. \
  Keep close to the metal, let allocations show, \
  Pass your contexts cleanly so the lifetimes flow. \
  Errors are values, never cast aside, \
  Handle them explicitly; let nothing hide. \
  Fail with grace, let diagnostics guide: \
  Show the break, the hint, the fix inside. \
  Design for speed, let safety lead the pace, \
  Waste no cycle, leave no leaking trace. \
  Keep it simple to use, explain, and maintain, \
  So years from now, the logic remains plain. \
  Coherence beats purity when real problems strike, \
  But structure your memory as hardware would like.
]

= Structural Constraints

The creed is enforced by `tools/check_style.py`, which `make vet`, `make check`, and the
`paxos-cli check` command run before anything else. A hard limit fails the build.

== 1. File boundary

- *Maximum file length:* a single source file must not exceed 1,408 physical lines,
  including comments and blank lines. The core protocol is therefore ten files, each
  with one responsibility: `ballot.odin`, `bit_set.odin`, `membership.odin`,
  `ledger.odin` (durable state), `messages.odin`, `effects.odin`, `node.odin`
  (lifecycle and queries), `election.odin` (phase one), `consensus.odin` (phase two,
  timers, dispatch), and `ownership.odin` (rotating slot ownership).

== 2. Line width boundaries

- *Soft limit (99 columns):* lines should be wrapped at or before 99 columns; the checker
  lists offenders with `--soft`.
- *Hard limit (108 columns):* no line may exceed 108 columns; a longer line fails the
  build. Tabs count as four columns.

== 3. Procedure code density

- *Maximum scope (70 lines):* the body of a procedure must not exceed 70 lines of actual
  execution logic.
- *Exclusions:* blank lines, whitespace-only lines, comment lines, and ornamental divider
  lines are not counted.

== 4. Elm-style error handling and diagnostics

- *Actionable reporting:* an error never only states what failed; it explains why and
  gives a path to resolution. In code this is the `Error` enum plus `explain_error`, a
  data table with one entry per value, and a test that fails when a value has no entry.
- *Diagnostic structure:* every error block or runtime diagnostic carries three parts:
  the *context* (the failing input or state), the *hint* (the assumption or constraint that
  was breached), and the *remediation* (how to fix it). The durability gate's
  `-- DURABILITY ORDER VIOLATION --` banner and every compile-time `#assert` message follow
  the same shape.

== 5. Performance and longevity architecture

- *Resource-optimum design:* memory layouts favour mechanical sympathy: contiguous arrays
  (the `Ledger` columns and bitmaps, the inline `small_array` effect buffers),
  predictable transformations, no value copies and no pointer chasing in a transition.
- *Safety via visibility:* performance never buys unvetted cleverness. The library leans
  on Odin's type checking, explicit bounds (`#assert`, `where` clauses), and the runtime
  gate rather than on trust.
- *Long-term maintainability:* every engineering decision must pass the "mere mortal
  explainability test". An optimisation that cannot be explained simply to a teammate is
  refactored into a simpler, flatter structure.

= References

- Lamport, Leslie. "The Part-Time Parliament." ACM TOCS, 1998.
- Zenfmt Monorepo ZDS Architecture (insanai/zenfmt).
