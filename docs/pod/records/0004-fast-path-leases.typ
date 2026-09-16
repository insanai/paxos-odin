#let pod-number = "0004"
#let pod-title = "Fast-Path Leader Leases and Linearizable Read Verification"
#let pod-state = "discussion"
#let pod-created = "2026-09-16"
#let pod-discussion = "Proposal for zero-round-trip linearizable reads via tick-bounded leader leases; unimplemented"
#let pod-labels = ("consensus", "reads", "leases", "performance")
#let pod-authors = ("Paxos Odin Contributors <team@insan.ai>")
#let pod-category = "Protocol Extension"
#let pod-status = "Open for Discussion"
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

In Multi-Paxos, a read-only query typically needs a consensus round or a phase-two quorum exchange to rule out a stale answer from a leader that has been superseded. This proposal sketches a tick-bounded *leader lease* for `paxos-odin`: bounded leader terms measured in the logical ticks the host already feeds to `node_tick` (the `paxos.tick` proc group), confirmed by majority heartbeat responses. A stable leader holding a live lease could then serve linearizable reads locally with no network round trip and no disk write. Nothing in this document is implemented; it is a proposal for discussion. Since `0.2.0` the core can also run with rotating slot ownership (POD 0010), in which there is no single leader at all; the section "Rotating ownership changes the question" states what that does to the proposal.

= Relationship to the Current Code

The core library in version `0.2.0` contains no lease and no read path. Three facts about the present code bound this proposal:

- `node_is_leader_caught_up` (proc group `is_leader_caught_up`; `replicated_log_is_leader_caught_up` for the log) returns `delivered_through >= leader_base - 1`. It reports that the leader has delivered every slot it inherited from earlier ballots and nothing more. Its doc comment states that it is not a lease and not a read barrier; a partitioned former leader can return true while another node leads. `Node_Options.gate_proposals_on_inherited_prefix` turns the same condition into `.Leader_Catching_Up` for proposals, and that is the only use the core makes of it.
- The only reads are of decided state: `node_committed_at`, `node_read_decided`, `replicated_log_read`, `replicated_log_read_decided`, and the learner readers. They answer from the local window and carry no freshness guarantee.
- `Heartbeat_Message{ballot, decided_through}` is one-way. A follower that receives one adopts the ballot if it is above its promise (writing `Write_Promise`) and may reply with a `Learn_Message`; it sends no acknowledgement that a leader could count. The lease below therefore needs a new message kind or a counted reply.

Hosts that need linearizable reads today must run a read barrier through consensus (propose a no-op and wait for it to be delivered) or implement a quorum read outside the library. POD 0007 records this limit.

= Introduction

While Multi-Paxos commits writes in one round trip once a leader is established, reading local state without consensus can return stale data if a higher ballot has been promised elsewhere. Systems such as Megastore, Spanner, and CockroachDB let leaders hold bounded time leases during which followers refuse to grant leadership to anyone else. Because `paxos-odin` is a pure state machine with no system clock, a lease would have to be expressed in the same logical ticks that already drive `election_timeout_ticks`, `heartbeat_interval_ticks`, and `resend_interval_ticks` in `Node_Options` (zero selects the defaults in `src/paxos.odin`).

= Terminology and Scope

- *Linearizable read*: a read that returns the latest state as of its invocation, never a superseded view.
- *Lease duration* ($T_"lease"$): the number of consecutive ticks during which a granting follower promises not to promise a higher ballot.
- *Lease renewal*: a quorum heartbeat exchange completed before the current lease expires.
- In scope: the pure state-machine bookkeeping for grants, renewal, expiry, and follower election backoff. Out of scope: clock synchronisation, and any change to the durability contract of POD 0003.

= Design Overview

== Tick-counted lease intervals

1. When a leader receives lease grants from a read quorum (as replies to heartbeats, or piggybacked on `Promise_Range_Message` during phase one), it acquires a lease valid for $T_"lease"$ ticks.
2. Every `node_tick` decrements the remaining lease.
3. If it reaches zero before a fresh quorum of grants arrives, the leader is *lease expired*: local reads must fall back to a consensus round.

== Follower election backoff

A follower that granted a lease to leader $L$ must not campaign or promise a competing ballot until $T_"lease" + T_"guard"$ ticks have elapsed since the grant. Today `node_tick` starts a campaign as soon as `campaign_enabled` and `election_ticks >= election_timeout_ticks`; the guard would have to be folded into that check, and `on_prepare` would have to answer a competing `.Global` `Prepare_Message` with a `Nack_Message` while a grant is live.

= Rotating Ownership Changes the Question

With `Node_Options{rotating_ownership = true}` (POD 0010) the cluster has no leader to lease. Every member proposes in its own slots at the round-zero ballot `ownership_ballot(node.id)` without phase one, `node_campaign` returns `.Campaign_Disabled`, and a revocation is a bounded phase one whose candidate returns to `.Follower` as soon as its chunk is driven (`become_leader` under `node.ownership`). `Role.Leader` is never assigned, `leader_hint` is only ever a hint, and `is_leader_caught_up` compares against a `leader_base` that ownership does not advance.

A lease as described above therefore applies only to the single-leader mode. Under ownership the linearizable-read question becomes: which member, if any, can know that no slot below some bound will be decided differently from what it holds? Because owners decide their own slots independently and a revocation can decide an owner's slot to the no-op behind its back (`ownership_revoked_suggestion_is_resubmitted`), the only local fact an owner has is its contiguous decided prefix (`decided_through`). Any read-your-writes or linearizable read under ownership would have to be a barrier through the log (propose a no-op in an own slot and wait for it to be delivered) or a new mechanism this proposal does not sketch. The open questions below are extended accordingly.

= Safety Considerations

1. *Tick drift.* Ticks come from the host. If the leader's host pauses (a virtual machine stall, a stop-the-world collection in the host) while followers keep ticking, the leader may believe its lease is live after followers consider it expired. Any concrete design needs a guard interval sized against the host's worst-case pause, and that sizing lives outside the pure core.
2. *Split brain.* At most one partition holds a read quorum, so at most one leader can renew; a minority leader's lease lapses after $T_"lease"$ ticks of its own clock, subject to the drift caveat above.
3. *Durability.* A grant is volatile leader state; it never needs a `Write`. A restarted follower has forgotten its grant, which is safe only if the guard interval also covers restart time.

= Open Questions

1. Should the query surface be a new procedure such as `node_can_serve_local_read(node) -> bool`, joining the `is_leader_caught_up` group, or a `Role` refinement?
2. Should $T_"lease"$ and $T_"guard"$ be fields of `Node_Options` (zero meaning "no lease") or compile-time parameters?
3. Should grants ride on a new message variant in `Message(Value)` or be a counted `Heartbeat_Message` reply? Either choice changes the `messages` capacity formula in `Effects`.
4. How does the seeded simulator in `sim/simulation.odin` model host pauses so that a lease-based read can be checked against its golden log?
5. Under rotating ownership (POD 0010), is there any lease-like construction at all, or is a log barrier the only linearizable read? If a lease exists only in single-leader mode, should the query procedure return false whenever `Node.ownership` is set, so a host cannot mistake an owner for a lease holder?

= References

- Lamport, Leslie. "Paxos Made Simple." ACM SIGACT News, 2001.
- Chandra, Tushar, Griesemer, Robert, and Redstone, Joshua. "Paxos Made Live." PODC, 2007.
- POD 0002: Paxos-Odin: Architecture and Pure State Machine Design.
- POD 0003: Durability Contracts, Window Reuse, and Trim Anchors.
- POD 0010: Rotating Slot Ownership.
