#import "theme.typ": *
#import "figures.typ": *

#part_page("II", [The complete ballot], [
  We execute one ballot from start to finish. We halt at every write, every reply,
  and every crash point. At the end, we can recover without guessing.
])

= The Single-Decree Protocol

#objectives([
  By the end of this chapter you should be able to trace a complete single-decree
  ballot step-by-step, distinguish *accepted*, *chosen*, *committed*, and *applied*,
  place every required disk write before its dependent network message, and prove
  why Lamport's Max-Vote Rule ($B_3$) preserves safety across leader transitions.
])

#checkpoint([Foundation], [
  State the highest-vote rule from memory. If your answer says "majority value"
  or "latest timestamp", re-read Part I before proceeding.
])

== The Four Consensus Roles

To make consensus modular, Paxos separates the system into four logical roles:

#book_figure(
  [Clients issue commands; Proposers drive consensus rounds; Acceptors form the
  durable voting body; Learners observe chosen values and feed application state.],
  role_map(),
)

1. *Clients*: External applications that submit state machine proposals (e.g. `put("user:1", "alice")`).
2. *Proposers (Leaders / Coordinators)*: Active agents that run campaigns, initiate
   ballots, and propose values to the voting body.
3. *Acceptors (Voters / The Parliament)*: Passive agents that form the indelible
   memory of the cluster. They store promises, record votes, and never forget.
4. *Learners*: Passive observers that track which entries have reached quorum
   commitment and deliver them in order to the application state machine.

In `paxos-odin`, a single `Node` struct performs all four roles concurrently to
maximize hardware efficiency and eliminate inter-process latency.

== Phase One: Prepare and Promise

Phase One serves two essential purposes:
1. It establishes leadership by preempting any older, lower ballots.
2. It discovers any value that may have already been chosen in an earlier ballot.

#book_figure(
  [Phase 1 queries the past to guarantee safety; Phase 2 replicates the value
  to secure future decisions.],
  phase_flow(),
)

=== Step 1a: Prepare

A candidate node chooses a ballot higher than any it has observed, for example
$b = (1, 1)$, and emits a `Prepare` message to all acceptors:

#code_file("src/protocol.odin", [
```odin
Prepare_Message :: struct {
	ballot: Ballot,
	first:  Slot,
}
```
])

=== Step 1b: Promise

When an acceptor receives `Prepare(b)`, it checks its durable state:
- If $b <= "highest_promised"$, the message is stale; the acceptor rejects it (or sends a `Nack`).
- If $b > "highest_promised"$, the acceptor persists `Write_Promise(b)` to disk and returns a `Promise`.

#code_file("src/protocol.odin", [
```odin
Promise_Message :: struct($Value: typeid) {
	ballot:          Ballot,
	slot:            Slot,
	accepted_ballot: Ballot,
	accepted_value:  Value,
}
```
])

The promise represents an unbreakable contract:
#callout([The Acceptor's Promise], [
  *"I promise never to accept any proposal tagged with a ballot lower than $b$."*
], kind: "warning")

== Phase Two: Accept and Accepted

Once the proposer collects promises from a majority quorum $Q_1$, it enters Phase Two.

=== Step 2a: The Max-Vote Rule ($B_3$)

Before sending an `Accept` message, the leader must determine *which value* it is
permitted to propose. It inspects all promises returned by quorum $Q_1$:

#callout([Lamport's Max-Vote Invariant ($B_3$)], [
  1. Let $V$ be the set of all accepted values reported in promises from quorum $Q_1$.
  2. If $V$ is non-empty, the proposer *MUST* choose the value associated with
     the *highest accepted ballot* among all received promises.
  3. If $V$ is empty (no node in $Q_1$ has ever voted), the proposer is free to
     propose any new value submitted by a client.
], kind: "idea")

Why does this guarantee safety?
Suppose value $v$ was chosen in ballot $b$ by quorum $Q_0$.
Any subsequent proposer that forms a quorum $Q_1$ must share at least one node with
$Q_0$ (since $Q_0 ∩ Q_1 ≠ ∅$). That intersecting node was part of $Q_0$, so it voted
for $v$ in ballot $b$. Therefore, the new proposer is *forced* to discover $v$ and
re-propose it. A conflicting value $w ≠ v$ can never be proposed!

=== Step 2b: Accept

The leader persists `Write_Accept(b, v)` to its own disk, then transmits `Accept(b, v)`
to all acceptors:

#code_file("src/protocol.odin", [
```odin
Accept_Message :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  Value,
}
```
])

=== Step 2c: Accepted and Commit

When an acceptor receives `Accept(b, v)`:
- If $b < "highest_promised"$, it ignores the proposal because a higher leader has superseded it.
- If $b >= "highest_promised"$, it writes `Write_Accept(b, v)` to disk and emits `Accepted(b, v)`.

When the leader receives `Accepted` from a quorum of acceptors, the decree is
*chosen*! The leader then sends a `Commit` message to all nodes and learners.

== The Write-Before-Send Durability Gate

In `paxos-odin`, the safety contract is enforced at compile time and runtime through
an explicit durability barrier:

#code_file("src/protocol.odin", [
```odin
// Caller consumes generated effects
for w in paxos.effects_writes_slice(effects) {
    disk_append(w)
}
disk_sync() // fsync write-ahead log

// Unlock message transmission
paxos.effects_confirm_writes_durable(effects)

for env in paxos.effects_messages_slice(effects) {
    network_send(env)
}
```
])

If a host application attempts to read `effects_messages_slice` without first calling
`effects_confirm_writes_durable`, `paxos-odin` immediately triggers a diagnostic
abort (`host_order_violation`). It is physically impossible for a message to escape
onto the wire before its dependent state delta is flushed to disk.

#teach_back([
  Explain the difference between a value being *accepted* by an individual node,
  *chosen* by a quorum, and *applied* to an application state machine.
])
