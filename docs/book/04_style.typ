#import "theme.typ": *

= Writing Reviewable Consensus Code

#objectives([
  By the end of this chapter you should be able to apply idiomatic Odin patterns
  to distributed systems, eliminate hidden memory allocations, leverage native bit sets,
  and structure consensus logic so that human reviewers can verify safety at a glance.
])

== Why Zero Allocation Matters

In typical web software, memory is allocated on the heap whenever a new object is
needed. If memory runs out, the garbage collector pauses or the OS kills the process.

In a consensus engine, a runtime out-of-memory crash is unacceptable. If a node
crashes midway through an election because the heap fragmented, cluster availability
collapses.

`paxos-odin` follows strict zero-allocation systems principles:
1. *Zero Runtime Allocation*: All memory is statically bounded at startup or on
   the stack. The consensus core never calls `new()`, `make()`, or `context.allocator`.
2. *Static Capacity Bounds*: Cluster size (`MAX_MEMBERS`), sliding windows (`WINDOW_SLOTS`),
   and message buffers are verified at compile time.
3. *Fail-Fast Invariants*: Recoverable condition failures return explicit `Error`
   values; protocol safety invariants are guarded by assertions that halt immediately
   if internal state is corrupted.

== Idiomatic Odin Data Structures

Rather than porting low-level C or Zig idioms directly, `paxos-odin` leverages Odin's
native language strengths:

=== 1. Native Built-in `bit_set`

In C and Zig, tracking voter quorums requires manual bit manipulation over `u64` words.
In Odin, `bit_set` is a first-class language feature:

#code_file("src/protocol.odin", [
```odin
acknowledgements: bit_set[0..<MAX_MEMBERS],

// Adding a voter acknowledgement
cell.acknowledgements += {from_member_idx}

// Checking quorum cardinality
if card(cell.acknowledgements) > len(node.membership.members) / 2 {
    // Quorum reached!
}
```
])

Odin's `bit_set` compiles directly to single-instruction bitwise operations (`bts`,
`btr`, `popcnt`), providing maximum clarity and optimal assembly codegen.

=== 2. `core:container/small_array`

Rather than managing raw pointers and manual capacity variables, bounded collections
in `paxos-odin` use Odin's standard library `small_array`:

#code_file("src/protocol.odin", [
```odin
import "core:container/small_array"

writes: small_array.Small_Array(1 + WINDOW_SLOTS, Write(Value)),
```
])

`Small_Array` keeps the entire collection inline inside the struct (zero heap pointer
indirection) while providing safe bounds-checked `push_back`, `slice`, and `clear` methods.

=== 3. Elm-Style Diagnostic Errors

When a consensus operation fails, standard error codes like `ERR_INVALID` provide zero
debugging context. `paxos-odin` pairs a clean `Error` enum with human recovery hints:

#code_file("src/errors.odin", [
```odin
Error :: enum {
	None,
	NodeNotInMembership,
	StaleBallot,
	WindowFull,
	LogSealed,
	DurabilityOrderViolation,
	// ...
}

explain_error :: proc(err: Error) -> string {
	switch err {
	case .WindowFull:
		return "The sliding window is exhausted. Host must call node_advance_memory_floor."
	case .LogSealed:
		return "The log has been sealed by a Stop Sign. Propose under the new configuration."
	// ...
	}
}
```
])

== Control Flow and Reviewability

Consensus code must be transparent. A reviewer should not have to trace complex
abstractions or inheritance hierarchies:

- *Flat Control Flow*: Return early on precondition failures to keep the happy path unindented.
- *Explicit Message Dispatch*: A single flat `switch msg in envelope.message` procedure
  dispatches every packet.
- *No Dynamic Dispatch*: Zero interface vtables or runtime reflection.
- *No Hidden Allocations*: Procedures take explicit `^Effects` pointers rather than
  allocating return slices.
- *Bounded Loops*: Every loop has a compile-time bound or an explicit slice length.

#teach_back([
  Explain why avoiding dynamic heap allocations in a consensus core improves
  latency predictability and simplifies failure modeling.
])
