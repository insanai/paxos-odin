#import "theme.typ": *

#part_page("VIII", [Conformance], [
  A direct, line-by-line mapping from Leslie Lamport's original 1998 paper
  to the Odin source code and the simulator oracles.
])

= Lamport Conformance Appendix

This appendix maps the basic Synod protocol and the multi-decree refinements from
Leslie Lamport's foundational paper, #emph[The Part-Time Parliament] (ACM Transactions
on Computer Systems, 1998), directly to the implementation in `src/protocol.odin` and
`src/replicated_log.odin`.

== The Basic Synod Protocol, Step by Step

#table(
  columns: (auto, 1.4fr, 1.4fr),
  table.header([*Paper Section*], [*Lamport's Formal Rule*], [*Paxos-Odin Implementation (`src/protocol.odin`)*]),
  [Section 2.3, Step 1],
    [Priest chooses ballot $b > "lastTried"$, owned by this priest.],
    [`node_campaign`: `round = max(own, promised, observed) + 1` with unique `node` ID as tie-breaker (`ballot_cmp`).],
  [Section 2.3, Step 2],
    [On $"NextBallot"(b)$ with $b >= "nextBal"$, set $"nextBal" := b$ and reply $"LastVote"$ with highest vote.],
    [`on_prepare`: checks $b >= "promised"$, emits `Write_Promise(b)`, transmits per-slot `Promise` and `Promise_Range` chunk descriptors.],
  [Section 2.3, Step 3],
    [With $"LastVote"$ from a majority quorum, propose decree of highest-ballot vote, else any decree ($B_3$).],
    [`on_promise` and `resolve_chunk`: tracks highest accepted ballot per slot; re-proposes recovered entries and fills holes with no-op decrees.],
  [Section 2.3, Step 4],
    [On $"BeginBallot"(b, d)$ with $b >= "nextBal"$, cast vote and write into indelible ledger.],
    [`on_accept`: checks $b >= "promised"$, records `Write_Accept(b, slot, value)` to stable storage, emits `Accepted`.],
  [Section 2.3, Step 5],
    [With $"Voted"$ from every quorum member, the decree passes.],
    [`on_accepted`: counts distinct voters via `card(acknowledgements) > len(members)/2`, records commitment on majority.],
  [Section 2.3, Step 6],
    [On $"Success"(d)$, write decree into ledger and release to learners.],
    [`on_commit`: advances `decided_through` and releases contiguous newly committed decrees to the host via `committed`.],
)

== Multi-Decree Refinements

#table(
  columns: (auto, 1.4fr, 1.4fr),
  table.header([*Paper Section*], [*Refinement Specification*], [*Paxos-Odin Implementation*]),
  [Section 3.1: One Ballot for All Decrees],
    [A single $"NextBallot"(b, n)$ message covers all uncommitted decrees; replies convey votes for all instances after $n$.],
    [`on_prepare` queries all slots above the trim boundary in bounded chunks `[first, first + CHUNK_SLOTS - 1]`; leadership covers all subsequent slots.],
  [Section 3.2: Filling Ledger Holes],
    [If an unresolved decree exists below the highest known decree, the leader must propose a blank decree (no-op).],
    [`resolve_chunk` detects empty slots between recovered entries and automatically proposes `no-op` decrees to preserve contiguous sequencing.],
  [Section 3.3: Reconfiguring the Parliament],
    [A special decree chosen through the standard consensus protocol seals the current configuration and defines the next parliament.],
    [`src/replicated_log.odin` implements `Stop_Sign`; once chosen in slot $s$, the log is sealed and configuration $C_"new"$ takes effect for slots $> s$.],
)

== Formal Verification and TLA+ Invariant Equivalence

The invariants verified by our deterministic chaos simulator (`sim/simulation.odin`)
directly correspond to the inductive safety invariants proven in Lamport's paper:

#table(
  columns: (auto, 1.3fr, 1.5fr),
  table.header([*Paper Invariant*], [*Mathematical Definition*], [*Simulator Golden Oracle Assertion*]),
  [$B_1(cal(B))$], [Ballot Uniqueness], [Asserts that two leaders never share the same ballot round and node identifier.],
  [$B_2(cal(B))$], [Quorum Intersection], [Asserts that every collected promise and vote set satisfies $|Q| > N/2$.],
  [$B_3(cal(B))$], [Max-Vote Invariant], [Asserts that a new leader never alters an already-chosen value across reboots or failovers.],
  [Agreement], [Uniform Consensus], [Golden oracle checks `decided[node_a, s] == decided[node_b, s]` on every simulated step.],
)
