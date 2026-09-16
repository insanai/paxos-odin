#let pod-number = "0001"
#let pod-title = "The Paxos Odin Discussion Process"
#let pod-state = "committed"
#let pod-created = "2026-09-16"
#let pod-discussion = "Established the POD RFC process and CLI toolchain"
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

= References

- Lamport, Leslie. "The Part-Time Parliament." ACM TOCS, 1998.
- Zenfmt Monorepo ZDS Architecture (insanai/zenfmt).
