#import "theme.typ": *

#part_page("VII", [Desk reference], [
  Messages, effects, invariant definitions, state transition matrices, and Odin APIs
  collected in one comprehensive reference.
])

= Consensus Desk Reference

== Protocol Message Reference

#table(
  columns: (auto, 1.2fr, 1.55fr),
  table.header([*Message*], [*Struct Fields*], [*Protocol Meaning*]),
  [`Prepare`], [`ballot: Ballot, first: Slot`], [Queries acceptors to promise this ballot and answer the recovery chunk starting at `first`.],
  [`Promise`], [`ballot: Ballot, slot: Slot, accepted: Maybe(Accepted)`], [Reports an accepted vote for a specific slot during Phase 1 recovery.],
  [`Promise_Range`], [`ballot, anchor, chosen_through, first, last, accepted_count, more`], [Chunk descriptor: states how many `Promise` entries complete the chunk and reports the acceptor's trim anchor.],
  [`Accept`], [`ballot: Ballot, slot: Slot, value: Value`], [Leader instructs acceptors to vote for `value` in `slot` under `ballot`.],
  [`Accepted`], [`ballot: Ballot, slot: Slot, decided_through: Slot`], [Acceptor confirms a durable vote and reports its local decided watermark.],
  [`Commit`], [`slot: Slot, value: Value`], [Broadcasts a chosen value that a correct leader knows reached quorum agreement.],
  [`Learn`], [`from_slot: Slot, count: u32`], [Catch-up request for contiguous committed entries from a peer node.],
  [`Nack`], [`rejected: Ballot, promised: Ballot, decided_through: Slot`], [Rejects a stale ballot and informs the sender of a higher promised ballot.],
  [`Heartbeat`], [`ballot: Ballot, decided_through: Slot`], [Periodic leader keepalive preventing unnecessary follower campaigns.],
)

== Effect Ordering and Durability Matrix

#table(
  columns: (auto, 1.1fr, 1.65fr),
  table.header([*Write Type*], [*Payload Data*], [*Must Be Durable on Disk Before*]),
  [`Write_Promise`], [`ballot: Ballot`], [Transmitting any `Promise` or `Promise_Range` message referencing this ballot.],
  [`Write_Accept`], [`ballot: Ballot, slot: Slot, value: Value`], [Transmitting `Accepted` or making any local claim based on this vote.],
  [`Write_Commit`], [`slot: Slot, value: Value`], [Emitting `Commit` messages, delivering to application state, or answering catch-up.],
  [`Write_Trim_Anchor`], [`anchor: Trim_Anchor`], [Releasing memory below the trim slot or vouching for a truncated log prefix.],
)

#callout([Strict Draining Order], [
  Always consume an `Effects` batch in this sequence:
  1. Append all `writes` to disk.
  2. Call `fsync()` to enforce physical disk durability.
  3. Call `paxos.effects_confirm_writes_durable(&effects)`.
  4. Transmit all `messages` across the network.
  5. Apply all `committed` entries to your application state machine.
])

== The Invariant Catalog

#table(
  columns: (auto, 1.1fr, 1.65fr),
  table.header([*ID*], [*Invariant Name*], [*Formal Definition / Rule*]),
  [$B_1$], [Ballot Uniqueness], [$b_1 = b_2 <=> b_1."round" = b_2."round" and b_1."node" = b_2."node"$. No two leaders ever issue the same ballot.],
  [$B_2$], [Quorum Overlap], [$forall Q_1, Q_2 in "Quorums" : Q_1 ∩ Q_2 ≠ ∅$. Any two majorities intersect in at least one witness node.],
  [$B_3$], [Max-Vote Preservation], [If a value was chosen in ballot $b$, every quorum collected for ballot $b' > b$ reports that value with the highest accepted ballot.],
  [$D_1$], [Indelible Ink], [Promised ballots and accepted votes stored in `Durable_State` are monotonically non-decreasing across crashes.],
  [$L_1$], [Contiguous Delivery], [Learners and state machines apply slots strictly in contiguous sequence: $1, 2, 3, dots, k$.],
  [$S_1$], [Stop-Sign Sealing], [Once a `Stop_Sign` is chosen in slot $s$, no value is ever chosen for any slot $s' > s$ in that configuration.],
)

== State Machine Transition Matrix

#table(
  columns: (auto, auto, 1.2fr, auto),
  table.header([*Role*], [*Event / Message*], [*Action & State Mutation*], [*Next Role*]),
  [Follower], [Election timeout], [Increment ballot round; emit `Prepare` to all peers.], [Candidate],
  [Candidate], [`Promise` (quorum reached)], [Resolve chunk; fill holes with no-ops; re-propose accepted values.], [Leader],
  [Leader], [`node_propose(value)`], [Assign next slot; append `Write_Accept`; emit `Accept` to peers.], [Leader],
  [Any], [`Accept` ($b >= "promised"$)],[Update promised ballot; append `Write_Accept`; emit `Accepted`.], [Follower],
  [Leader], [`Accepted` (quorum reached)], [Append `Write_Commit`; emit `Commit` broadcast; release committed entry.], [Leader],
  [Any], [`Commit`], [Record commit; advance `decided_through`; release contiguous entries to app.], [No change],
  [Any], [Message with $b > "promised"$], [Adopt higher ballot; reset election timers.], [Follower],
)
