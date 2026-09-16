#import "theme.typ": *
#import "figures.typ": *

#part_page("I", [One decision], [
  We begin with one empty line in a ledger. We end with the fundamental safety rule
  that governs every legal Paxos message.
])

= Foundations of Consensus

#objectives([
  By the end of this chapter you should be able to distinguish safety from liveness,
  calculate quorum intersection constraints, order Odin's two-component `Ballot`
  tuples lexicographically, and explain why quorum overlap without indelible stable
  storage is insufficient to preserve agreement.
])

#checkpoint([Prior Knowledge], [
  You need only sets, integer arithmetic, and the realization that a computer process
  can stop between any two CPU instructions. If you already know Paxos, skip to the
  teach-back at the end: can you explain why a new leader must adopt the value with
  the *highest accepted ballot* rather than the value with the most votes?
])

== The Empty Ledger

Imagine three librarians sitting in separate rooms on the island of Paxos, each
holding a physical ledger. The first line of this ledger is currently blank.

Two merchants arrive simultaneously at the library's reception desk:
- Merchant 1 sends a runner asking the librarians to write `"olive_oil = 50"`.
- Merchant 2 sends another runner asking the librarians to write `"olive_oil = 80"`.

The librarians cannot communicate directly; they can only send written slips
through runners across the courtyard. These runners can be delayed indefinitely,
fall asleep, deliver notes out of order, or disappear entirely. However, the runners
never forge or alter the words on a delivered slip.

Our goal is deceptively simple:
1. *Agreement*: The librarians must never decide two conflicting values for that blank line.
2. *Validity*: Any value declared final must have been proposed by a merchant.
3. *Eventual Choice*: If runners can deliver notes and the librarians remain awake,
   a decision should eventually be reached.

#definition([Safety], [
  Nothing bad happens. For Paxos, two different values are never chosen for the
  same slot. Once a value is chosen, it remains chosen forever across all space and time.
])

#definition([Liveness], [
  Something good eventually happens. For Paxos, a proposed value is eventually
  chosen when a quorum of nodes can communicate and one coordinator remains active
  long enough to complete a round of messages.
])

A stopped system is 100% safe. It performs no work, but it never contradicts itself.
This insight allows us to separate our design: we enforce ironclad safety rules
first, without relying on network timing or message delivery speed.

#predict([
  Nodes 1 and 2 have durably accepted `"olive_oil = 50"`, but the coordinator
  crashes before sending confirmation to learners. Is `"olive_oil = 50"` chosen?
  Write one sentence before reading on.
])

== Three Tempting but Broken Solutions

When engineers first encounter distributed consensus, three intuitive designs
almost always arise:

1. *First to Arrive Wins*: Each librarian adopts whichever runner arrives first.
   *Flaw*: If runner 1 reaches Node 1 first, while runner 2 reaches Node 2 first,
   a permanent split brain occurs. Neither value has majority support, yet both
   nodes have committed.
2. *Unanimous Agreement ($N$ out of $N$)*: Require all three librarians to agree.
   *Flaw*: If a single librarian takes a nap or one runner gets lost, the entire
   system halts forever. Unanimity offers zero fault tolerance.
3. *Majority Voting Without Rounds*: A value is chosen if a majority of nodes
   accept it.
   *Flaw*: If the network partitions while a proposal is in flight, the nodes in
   one partition may later accept a different proposal from a new coordinator,
   overwriting the previously chosen value.

== The Quorum Intersection Principle

To tolerate failures while preventing split brain, Paxos relies on *quorums*.
In a cluster of $N$ nodes, a majority quorum $Q$ contains at least:

$ |Q| >= floor(frac(N, 2)) + 1 $

For a 3-node cluster, any quorum contains at least 2 nodes. For a 5-node cluster,
a quorum contains at least 3 nodes.

#book_figure(
  [The Pigeonhole Principle guarantees that any two majority quorums $Q_1$ and $Q_2$
  must overlap in at least one common witness node: $Q_1 ∩ Q_2 ≠ ∅$.],
  quorum_picture(),
)

Because any two quorums must intersect:
$ |Q_1 ∩ Q_2| = |Q_1| + |Q_2| - |Q_1 ∪ Q_2| >= (frac(N+1, 2) + frac(N+1, 2)) - N = 1 $

Every quorum you could ever assemble contains at least one node that was present
in any previously assembled quorum! That overlapping node serves as the *witness*.

== Ballots and Lexicographical Ordering

Nodes may attempt to coordinate the cluster at the same time. To avoid ambiguity,
every attempt is tagged with a globally unique, strictly ordered *Ballot*.

In `paxos-odin`, a `Ballot` is defined in `src/protocol.odin`:

#code_file("src/protocol.odin", [
```odin
Ballot :: struct {
	round: u32,
	node:  NodeId,
}

ballot_cmp :: proc(a, b: Ballot) -> int {
	if a.round < b.round do return -1
	if a.round > b.round do return 1
	if a.node < b.node   do return -1
	if a.node > b.node   do return 1
	return 0
}
```
])

The ballot consists of two components:
- `round`: A monotonically increasing integer counter.
- `node`: The unique identifier of the proposing node ($1, 2, dots, N$).

Because no two nodes share the same `node` ID, ballot equality implies identical
proposers:
$ b_1 = b_2 <=> b_1."round" = b_2."round" and b_1."node" = b_2."node" $

Ballots are ordered lexicographically:
$ b_1 > b_2 <=> (b_1."round" > b_2."round") or (b_1."round" = b_2."round" and b_1."node" > b_2."node") $

== Why Durable Storage is Mandatory

Quorum intersection proves that at least one node witnessed the previous decision.
However, that guarantee holds *only if the witness remembers what it saw*.

Suppose Node 1 and Node 2 accept ballot $(1, 1)$ with value `"A"`. Value `"A"` is now
chosen by majority quorum $\{1, 2\}$.
Now Node 2 crashes, reboots, and forgets its memory because it was stored in volatile RAM.
A new leader emerges with ballot $(2, 3)$ and queries quorum $\{2, 3\}$.
Because Node 2 forgot its vote, it tells Leader 3: *"I have never voted for anything!"*
Leader 3 then proposes `"B"`, and quorum $\{2, 3\}$ accepts it.

*Catastrophe!* Slot 1 has now chosen both `"A"` and `"B"`.

#warning([The Indelible Memory Invariant], [
  In Lamport's original Paxos paper, the priests of Paxos wrote all ledger
  entries in indelible ink. In systems software, this means a node MUST
  synchronize its promises and votes to stable storage (such as an append-only
  write-ahead log with `fsync`) *before* acknowledging any message to peers.
])

#teach_back([
  Explain to a colleague why simple majority voting fails when servers can restart,
  and how combining majority quorums with write-ahead disk logging guarantees safety.
])
