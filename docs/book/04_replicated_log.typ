= Reconfigurable Log and Stop Signs

== Why Dynamic Membership is Hard

Naive membership changes in consensus algorithms often suffer from split-brain scenarios if two overlapping configurations are simultaneously active.

In Paxos, Lamport introduced the concept of *Stop Signs*: a special command in the replicated log that permanently halts and seals the current configuration.

== The Replicated Log Layer

`Replicated_Log_Node` layers on top of the pure `Node` state machine:
- Commands and Stop Signs share the same ordered 64-bit log space.
- An application proposes commands via `replicated_log_propose`.
- When reconfiguration or snapshotting is desired, the host calls:
```odin
replicated_log_propose_stop_sign(node, next_conf_id, next_members, metadata, effects)
```

== Sealing Semantics

1. Proposing a Stop Sign sets `stop_pending = true`.
2. While `stop_pending` or `stop_sign != nil`, any further proposals return `Error.LogSealed`.
3. When the Stop Sign commits, `stop_slot` is recorded and the configuration epoch is frozen.
4. The host extracts the handover metadata (e.g. state snapshot ID) and seamlessly initializes the next configuration epoch at slot `stop_slot + 1`.
