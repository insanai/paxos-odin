= Durability Contracts and Host Integration

== Safety Guarantees Across Crashes

In Paxos, agreement requires that once a value $v$ is chosen for slot $s$, no future ballot can ever choose a different value $v' != v$ for slot $s$.

If an acceptor promises ballot $b$ and then reboots from power loss without having saved that promise to disk, it could subsequently promise a lower ballot $b_0 < b$. That lower ballot might then accept a different value, overwriting a decree already decided by a previous quorum.

== The Write-Before-Send Contract

To prevent this catastrophe:
1. Every write emitted in `Effects.writes` must reach non-volatile media before any message in `Effects.messages` is transmitted.
2. After the host's write-ahead log flush completes, the host calls `effects_confirm_writes_durable(effects)`.
3. Only after this confirmation can `effects_messages_slice(effects)` be called.

== Power-Loss Barrier Classification

Not all writes carry equal safety implications:
- *Critical Power-Loss Barrier*: `Write_Promise` and `Write_Accept`. A lost promise or vote can violate agreement after a reboot.
- *Derived / Idempotent Writes*: `Write_Commit` and `Write_Trim_Anchor`. These records represent state already durably certified by a quorum. If lost during a crash, they can be reconstructed during phase one recovery.

Hosts can inspect `effects_requires_power_loss_barrier(effects)` to decide whether an expensive device cache flush (`fsync` / `fdatasync`) is mandatory.

== Pre-Durable Pipelining

Phase 2 `Accept` proposals sent by a leader do not claim that the leader's own vote is durable yet; they merely ask remote peers to accept the vote.

The `effects_pre_durable_messages` iterator extracts only `Accept_Message` items from the batch. A high-performance host can initiate peer network transmissions concurrently with its local disk write, overlapping I/O latencies.
