= The Multi-Paxos Protocol Core

== Ballots and Lexicographic Total Order

A ballot uniquely identifies a presidential proposal attempt:
```odin
Ballot :: struct {
    round:    u64,
    priority: u32,
    node:     NodeId,
}
```

Ballots are compared lexicographically:
1. `round` (higher round dominates),
2. `priority` (host-configured election preference),
3. `node` (unique tie-breaker).

== Two-Phase Consensus Mechanics

Consensus over a sequence of log slots occurs in two phases:

=== Phase 1: Preparation and Recovery
When a node starts an election or recovers leadership:
1. It allocates a ballot strictly greater than any observed round.
2. It broadcasts `Prepare_Message{ballot, first: recover_base}` to all voting members.
3. Acceptors reply with:
   - `Promise_Message`: Returning the highest vote cast for each resident slot in the active chunk.
   - `Promise_Range_Message`: Stating the range bounds, total votes returned, and trim anchor fences.
4. Once a read quorum ($Q_R = floor(N/2) + 1$) of complete promises is assembled:
   - For every slot in the chunk, the candidate selects the vote with the highest ballot among all promises.
   - Any gap below known state is filled with the deterministic `noop` value.
   - The candidate drives these values in Phase 2, resolving inherited history before accepting new application proposals.

=== Phase 2: Proposal and Commit
1. The leader sends `Accept_Message{ballot, slot, value}` to all peers.
2. Acceptors verify that `ballot >= promised`. If true, they persist `Write_Accept` to disk and reply with `Accepted_Message`.
3. When the leader gathers acknowledgments from a write quorum ($Q_W = floor(N/2) + 1$), the slot is *chosen*.
4. The leader persists `Write_Commit`, releases `Committed` to the application, and broadcasts `Commit_Message` to peers.
