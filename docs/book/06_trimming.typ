= Sliding Windows, Garbage Collection, and Trim Anchors

== Bounded State in an Unbounded Universe

The global Paxos slot is a 64-bit integer that never resets over the lifespan of a distributed database. However, node memory is bounded: `WINDOW_SLOTS` is typically 256 or 1024 slots.

To prevent memory exhaustion while retaining safety:
1. `(slot - 1) % WINDOW_SLOTS` maps infinite slots into physical cells.
2. A physical cell can only be claimed for a higher slot if its prior occupant is *evictable*.

== The Memory Floor

A cell is legally evictable if and only if:
1. Its slot index is at or below the host's `memory_floor`.
2. Its value has already committed.

The host advances `memory_floor` when committed entries have been durably written to stable long-term storage or folded into an application state snapshot.

== Trim Anchors

When a node trims its local in-memory window, an empty cell could be misinterpreted by an incoming Phase 1 prepare as an "undecided / open slot".

To solve this, `paxos-odin` uses *Trim Anchors*:
```odin
Trim_Anchor :: struct {
    trim_id:          u64,
    chosen_trim_slot: Slot,
    history_hash:     [32]u8,
}
```

During Phase 1, an acceptor returns its active trim anchor. The candidate learns that all slots $<= "chosen_trim_slot"$ were already chosen and never attempts to re-propose or overwrite them.
