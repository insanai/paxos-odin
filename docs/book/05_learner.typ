= Non-Voting Learners and Contiguous Delivery

== Learner Role in Cluster Topologies

Consensus clusters often require non-voting observer nodes:
- Read replicas serving client queries without participating in quorums.
- Analytics consumers tailing the state machine.
- Backup agents archiving historical decisions.

== Contiguous Delivery Guarantees

A naive learner might process out-of-order commits directly, exposing inconsistent intermediate state to application queries.

`paxos-odin`'s `Learner` enforces strict monotonicity:
- A ring-buffer window of size `MAX_ENTRIES` buffers future slots when gaps exist below them.
- Values are only released to the application as a contiguous prefix:
```odin
learner_learn_chosen(learner, conf_id, slot, value)
```
- If slot $s$ arrives while slot $s-1$ is missing, slot $s$ is buffered (`Learn_Result.Buffered`).
- When the missing slot $s-1$ arrives, both slots advance together (`Learn_Result.Advanced`).
- Duplicate deliveries are idempotent (`Learn_Result.Duplicate`).
- Conflicting values for the same slot return `Error.ConflictingChosenValue`.
