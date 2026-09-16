#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [The Odin library], [
  The consensus proof becomes a bounded state machine. The host owns the disk,
  the network, the clock, and the application state. The boundary between them
  is the library API.
])

= Bounded Core State Machine

#objectives([
  By the end of this chapter you should be able to instantiate `Node`, execute each
  public state transition, safely drain an `Effects` batch, restore from durable
  disk state, and identify every operating system boundary owned by the host.
])

== Design Philosophy: Consensus Without I/O

`paxos-odin` deliberately excludes all sockets, kernel threads, filesystem calls,
serialization codecs, and wall-clock reads. The consensus protocol is a pure,
deterministic, mutating *effect machine*:
- A procedure call updates `Node`'s internal memory immediately.
- It records all required external actions in a caller-owned `Effects` structure.

#book_figure(
  [The consensus core takes input events and emits effects into caller-allocated buffers.
  The host application owns disk persistence, network transmission, and state updates.],
  effects_flow(),
)

This clean separation provides enormous engineering advantages:
1. *Deterministic Verifiability*: The exact same core code runs inside unit tests,
   a simulated network with dropped packets, a microsecond benchmark, or a Linux
   event loop.
2. *Zero Runtime Allocation*: All memory is statically sized at compile time.
   `paxos-odin` never invokes `context.allocator` during consensus transitions.
   Out-of-memory errors during runtime consensus are physically impossible.
3. *Explicit Durability Boundaries*: The host cannot accidentally transmit an
   unpersisted message because the library enforces a runtime gate.

== Defining the Protocol Configuration

In Odin, `Node` and `Effects` are parameterized cleanly:

#code_file("src/protocol.odin", [
```odin
package paxos

Node :: struct(
	Value:        typeid,
	MAX_MEMBERS:  int = 7,
	WINDOW_SLOTS: int = 256,
	CHUNK_SLOTS:  int = 64,
	GATE:         Durability_Gate = .Enforced,
) {
	id:         NodeId,
	role:       Role,
	ballot:     Ballot,
	membership: Membership(MAX_MEMBERS),
	durable:    Durable_State(Value, WINDOW_SLOTS),
	// ... internal ring buffers and election cells
}
```
])

Parameters:
- `Value`: The application command payload type (e.g. `u64`, `Command`, or a fixed-size struct).
- `MAX_MEMBERS`: Maximum cluster size (typically 3, 5, or 7).
- `WINDOW_SLOTS`: Sliding ring-buffer capacity (e.g. 256, 1024, or 4096 slots).
- `CHUNK_SLOTS`: Recovery batch size for Phase 1 synchronization (e.g. 64 or 256 slots).
- `GATE`: `.Enforced` halts on durability violations; `.Permissive` is for host-managed engines.

== The Caller-Allocated Effects Buffer

Whenever an event occurs, the caller supplies an `Effects` buffer:

#code_file("src/protocol.odin", [
```odin
Effects :: struct(
	Value:        typeid,
	MAX_MEMBERS:  int = 7,
	WINDOW_SLOTS: int = 256,
	GATE:         Durability_Gate = .Enforced,
) {
	writes:           small_array.Small_Array(1 + WINDOW_SLOTS, Write(Value)),
	messages:         small_array.Small_Array(MAX_MEMBERS * 2, Envelope(Value)),
	committed:        small_array.Small_Array(WINDOW_SLOTS, Committed(Value)),
	requests:         small_array.Small_Array(MAX_MEMBERS, Host_Request),
	writes_confirmed: bool,
}
```
])

The caller drains the buffer in four mandatory steps:
1. `effects_writes_slice(eff)`: Write all state deltas to write-ahead log (disk WAL).
2. `fsync()`: Flush disk writes to permanent storage.
3. `effects_confirm_writes_durable(eff)`: Unlock message transmission.
4. `effects_messages_slice(eff)`: Send network messages to peers over UDP, TCP, or shared memory.
5. `effects_committed_slice(eff)`: Apply newly decided entries to application state.

== The Four Public Transitions

A host interacts with `paxos.Node` through four primary procedures:

#table(
  columns: (auto, 1fr, 1.4fr),
  table.header([*Procedure*], [*Input Event*], [*Description*]),
  [`node_campaign`], [Ballot round], [Starts Phase 1 election to assume stable leadership.],
  [`node_propose`], [Client value], [Proposes a new value in Phase 2 under stable leadership.],
  [`node_propose_batch`], [Slice of values], [Proposes a contiguous batch of values with amortized ring overhead.],
  [`node_step`], [Received `Envelope`], [Processes an inbound peer message (Prepare, Promise, Accept, etc.).],
  [`node_tick`], [Logical timer], [Drives leader heartbeats, election timeouts, and retransmissions.],
)

All transitions return an `Error` enum (`.None`, `.StaleBallot`, `.WindowFull`, `.LogSealed`, etc.)
accompanied by Elm-style human diagnostics through `explain_error(err)`.

#teach_back([
  Why does `paxos-odin` require caller-allocated `Effects` buffers rather than
  calling `os.write` and `net.send` internally?
])
