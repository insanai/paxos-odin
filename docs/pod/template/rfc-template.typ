#let pod-number = "XXXXX"
#let pod-title = "Title Goes Here"
#let pod-state = "prediscussion"
#let pod-created = "YYYY-MM-DD"
#let pod-discussion = "Draft discussion note"
#let pod-labels = ("documentation", "engineering")
#let pod-authors = ("Your Name <you@insan.ai>")
#let pod-category = "Engineering Discussion"
#let pod-status = "Internal Draft"
#let pod-last-updated = "None"

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

State the problem, the proposed direction, and the reason this document exists.

= Introduction

Provide the background and the constraints that make the topic worth discussing now.

= Terminology and Scope

Define the terms used in the document and state what is in scope versus explicitly out of scope.

= Problem Statement

Describe the gap in the current system, workflow, or design.

= Goals and Non-Goals

== Goals
- List the properties the proposal must satisfy.

== Non-Goals
- List adjacent problems that this document does not solve.

= Design Overview

Explain the high-level proposal in a way that lets the reader understand the rest of the document.

= Detailed Design

Break the design into the main mechanisms, data flows, interfaces, or document structures.

= Security & Correctness Considerations

Discuss invariants, fault handling, durability guarantees, and safety proofs.

= Operational Considerations

Document runtime, memory footprint, recovery steps, or contributor workflow implications.

= Alternatives Considered

List the main rejected options and why they were rejected.

= Open Questions

Capture unresolved questions that must be answered before the document can move to active discussion or publication.

= References

- Add links to related POD documents, code, or external papers.
