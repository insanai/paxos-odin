#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [The Odin library], [
  The proof becomes a bounded value in memory. The host owns the disk, the
  network, the clock, and the application state. The boundary between them is a
  small set of procedures and one caller-owned batch of effects.
])

= Bounded Core State Machine

#objectives([
  By the end of this chapter you should be able to declare a `Node` and its
  matching `Effects`, read Lamport's acceptor variables off the `Ledger`, run
  every public transition, consume one batch in the order the durability
  contract requires, copy a value out of a batch before the pointer to it goes
  stale, rebuild a node from replayed `Write` records, and say which conditions
  return an `Error`, which fail compilation, and which stop the process.
])

== Design Philosophy: Consensus Without I/O

The library performs no I/O and owns no threads or clocks. Every public
transition has the same shape: it *mutates the node in place* and *fills a
caller-owned `Effects` value* with what the host must now do. There is no
callback, no socket handle, no allocator, and no wall-clock read in `src/`.

#book_figure(
  [One transition consumes an event and fills three lists in a caller-owned batch.
  The host persists the writes, transmits the messages, and applies the committed
  entries, in that order.],
  effects_flow(),
)

The reason is determinism. Given the same node state and the same event, a
transition produces the same mutation and the same batch, whether it runs under
`odin test`, inside the seeded fault simulator in `sim/`, or behind a real
journal and a real socket. A failing simulation prints its seed and can be
replayed step for step, because nothing inside a transition depends on time,
memory layout, or scheduling. A transition is not a pure function, though, and
the in-memory node is not a substitute for the writes it returns: when a call
mutates `node.ledger`, it appends the matching `Write` record to the batch, and
the node's memory is only a cache of what the journal will hold once the host has
appended and synced those records.

== Defining the Configuration

Two parametric structs carry the same five parameters. The first is the node.

#code_file("src/node.odin", [
```odin
// One Multi-Paxos participant: proposer, acceptor, and learner in one bounded value.
// Every array is indexed by window cell or by stable member index; there is no
// per-slot struct, so a scan touches only the columns it needs.
//
// The host persists only the ledger, and only through the Write records it receives.
Node :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	id:                                 Node_Id,
	membership:                         Membership(MAX_MEMBERS),
	ledger:                             Ledger(Value, WINDOW_SLOTS),
```
])

The defaults live in `src/paxos.odin`: `DEFAULT_MAX_MEMBERS` is 7,
`DEFAULT_WINDOW_SLOTS` is 256, and `DEFAULT_CHUNK_SLOTS` is 64. `MAX_MEMBERS`
bounds the voting membership, `WINDOW_SLOTS` is the number of slot cells kept in
memory, and `CHUNK_SLOTS` is how many slots one phase-one round recovers at a
time (the Multi-Paxos chapter). `GATE` selects whether the durability contract
is checked at runtime; leave it at `.Enforced` unless you have read the
host-managed section.

The second struct is the batch, declared with the same parameters as the node it
serves. The compiler rejects a mismatch: the fixture `effects_must_match_node` in
`tools/check_contracts.py` pairs `paxos.Node(u64, 1, 4, 1)` with
`paxos.Effects(u64, 1, 4, 2)` and asserts that `paxos.campaign(&n, 0, &e)` fails
to type-check.

#code_file("src/effects.odin", [
```odin
// Caller-owned output of one transition. Declare it with the same parameters as the
// Node it serves; the compiler rejects a mismatch. The zero value is ready to use.
//
// Nothing in a batch owns a value: writes, messages, and committed entries point into
// the node's ledger. Capacities are per-transition maxima: one recovery chunk of votes,
// each possibly followed by a local decision, plus one promise; one chunk per peer plus
// prepares, heartbeats, and one catch-up request (an ownership tick proposes at most
// one chunk and retransmits only on a quiet tick); one window plus one pass-through
// entry of decisions.
Effects :: struct(
	$Value: typeid,
	$MAX_MEMBERS: int = DEFAULT_MAX_MEMBERS,
	$WINDOW_SLOTS: int = DEFAULT_WINDOW_SLOTS,
	$CHUNK_SLOTS: int = DEFAULT_CHUNK_SLOTS,
	$GATE: Durability_Gate = .Enforced,
) where intrinsics.type_is_comparable(Value) {
	writes:         small_array.Small_Array(2 * CHUNK_SLOTS + 1, Write(Value)),
	messages:       small_array.Small_Array(
		MAX_MEMBERS * CHUNK_SLOTS + 2 * MAX_MEMBERS + 1, Envelope(Value),
	),
	committed:      small_array.Small_Array(WINDOW_SLOTS + 1, Committed(Value)),
	requests:       small_array.Small_Array(MAX_MEMBERS, Host_Request),
	// True while this batch holds writes the host has not confirmed durable.
	writes_pending: bool,
}
```
])

=== Compile-time contracts

Capacity mistakes are caught before the program exists. `node_init` opens with
three `#assert` statements: `MAX_MEMBERS` must lie in `1..=65535`,
`WINDOW_SLOTS` must be a positive power of two, and `CHUNK_SLOTS` must satisfy
`1 <= CHUNK_SLOTS <= WINDOW_SLOTS`. Each message carries a `Hint:` naming the
fix, for example "Invalid window. Hint: WINDOW_SLOTS must be a power of two."

The window is a power of two because a slot's cell is one mask, `cell_of` in
`src/ballot.odin`: `(slot - 1) & (WINDOW - 1)`. `MAX_SUPPORTED_MEMBERS` is
65535 because a member's index and the node field of a ballot are both 16 bits
wide; per-member sets are the library's own `Bit_Set(MAX_MEMBERS)` from
`src/bit_set.odin`, not a native `bit_set`, so the member count is not capped
at a machine word. The `where intrinsics.type_is_comparable(Value)` clause on
both structs rejects a value type the language cannot compare with `==`; the
fixture `non_comparable_value` shows `paxos.Node(map[int]int, 1, 4, 1)` refused
with a diagnostic naming the `where` clause. `tools/check_contracts.py` runs
nine compile-fail fixtures: a zero window, a zero chunk, a window of 3 slots
(`window_not_power_of_two`), a chunk larger than its window, zero members, a
`Membership(65536)` (`too_many_members`), a zero learner window, the
non-comparable value, and the mismatched batch.

#api_anchor([`Node(Value, MAX_MEMBERS, WINDOW_SLOTS, CHUNK_SLOTS, GATE)`], [
  One participant with every role. `Effects` takes the same five parameters, and a
  node only accepts a batch of its own configuration.
], source: [`src/node.odin`])

=== What a `Value` may be

The `where` clause on `Ledger`, `Node`, and `Effects` states the rule: `Value`
must be comparable, because it is stored in the ledger's `value` column and
compared with `==` to detect a conflicting vote or decision. Odin equality
compares active union variants and string contents. A fixed-size struct of
integers, such as the `Command` in `examples/counter.odin`, needs nothing more.
A value that references memory compares by contents inside one process, but
the reference means nothing to a peer; the host defines its own wire and
journal encoding and keeps the referenced bytes immutable while any cell may
hold the value.

== The Ledger: Lamport's Variables in Columns

The acceptor state of *The Part-Time Parliament* is three variables per decree:
the greatest ballot promised, the ballot of the last vote, and the value of that
vote. The `Ledger` is those variables laid out as parallel arrays over the
window, with a fourth column for the decision and two bitmaps for the scans
that phase one and catch-up need:

#code_file("src/ledger.odin", [
```odin
Ledger :: struct($Value: typeid, $WINDOW: int = DEFAULT_WINDOW_SLOTS)
	where intrinsics.type_is_comparable(Value) {
	promised:    Ballot,
	anchor:      Trim_Anchor,
	slot:        [WINDOW]Slot,
	promised_at: [WINDOW]Ballot,
	vote_ballot: [WINDOW]Ballot,
	state:       [WINDOW]Cell_State,
	value:       [WINDOW]Value,
	// Bitmaps over cells: `used` has a vote or a decision, `chosen` has a decision.
	used:        Bit_Set(WINDOW),
	chosen:      Bit_Set(WINDOW),
}
```
])

`promised` is Lamport's `maxBal`, one global promise that covers every decree
at or above the base of the campaign that made it. `promised_at[c]` is a
per-decree promise, used only by bounded prepares under rotating ownership;
the effective promise of a cell is the larger of the two
(`ledger_promise_for`). `vote_ballot[c]` and `value[c]` are `maxVBal` and
`maxVal`. `state[c]` is a `Cell_State`: `.Empty`, `.Voted`, or `.Chosen`, and
once a cell is `.Chosen` its `value` is the decision. `slot[c]` tags which slot
owns cell `c`, so a reused cell is never mistaken for an older one. The anchor
is the chosen-trim record covered in the next chapter:

#code_file("src/ledger.odin", [
```odin
// The trim anchor: every slot at or below `chosen_trim_slot` is chosen and has been
// folded into a host state image identified by `trim_id`. The core compares anchors
// by identity; the host binds the image's checksum to the id itself.
Trim_Anchor :: struct {
	trim_id:          u64,
	chosen_trim_slot: Slot,
}
```
])

Four queries read the ledger without touching the node. `ledger_vote_at(l,
slot)` returns `(Ballot, ^Value, bool)` for a cell in state `.Voted`;
`ledger_chosen_at(l, slot)` returns `(^Value, bool)` for a `.Chosen` cell;
`ledger_highest_used(l)` walks the `used` bitmap for the greatest slot held;
and `ledger_highest_ballot(l)` returns the greatest ballot anywhere in the
ledger, which a campaign must exceed. `node_ledger(&node)` hands the host a
`^Ledger(Value, WINDOW_SLOTS)` for inspection.

== The Effect Contract

A batch carries four kinds of output. Writes are the durable records:

#code_file("src/ledger.odin", [
```odin
// The durable records the host journals, in order. Values are referenced, not copied:
// a pointer is valid until the next transition on the node that produced it, and a
// host persists every write before it runs another transition.
Write_Promise :: struct {
	ballot: Ballot,
}

// A promise for one decree only (a revocation under rotating ownership).
Write_Promise_At :: struct {
	ballot: Ballot,
	slot:   Slot,
}

Write_Vote :: struct($Value: typeid) {
	ballot: Ballot,
	slot:   Slot,
	value:  ^Value,
}

Write_Chosen :: struct($Value: typeid) {
	slot:  Slot,
	value: ^Value,
}

Write_Trim :: Trim_Anchor

Write :: union($Value: typeid) {
	Write_Promise,
	Write_Promise_At,
	Write_Vote(Value),
	Write_Chosen(Value),
	Write_Trim,
}
```
])

Messages are `Envelope(Value)` values, each with a `from`, a `to`, and a
`Message(Value)` union holding one of the nine wire messages from the protocol
chapter. The three that carry a value do so by pointer:
`Promise_Message(V){ballot, slot, vote, state, value: ^V}`,
`Accept_Message(V){ballot, slot, value: ^V}`, and
`Commit_Message(V){slot, value: ^V}`; `message_value(message)` returns that
pointer and whether the kind carries one. Committed entries are
`Committed(Value){slot, value: ^V}`, released in slot order without gaps.
Requests are `Host_Request` values; today the union has one variant,
`Serve_Range_Request{peer, first, count}`, which asks the host to serve
history below this node's memory floor from its own journal or state image.

=== Values travel by pointer

Nothing in a batch owns a value. A `Write_Vote`, an `Accept_Message`, and a
`Committed` entry all point at the `value` column of the ledger cell the
transition just wrote. The rule is stated at the top of `src/messages.odin`:

#code_file("src/messages.odin", [
```odin
// Wire messages. Every variant is small and fixed-size; a value travels by pointer.
// Outbound, the pointer refers into the sending node's ledger and stays valid until
// that node's next transition, so a host serialises before then. Inbound, the host
// points it at the decoded value for the duration of the `step` call. An in-process
// transport that queues envelopes copies the value at enqueue time, as a codec would.
```
])

A real host serialises each write and each message before it steps the node
again, and the copy happens inside its codec. An in-process transport has no
codec, so it copies the value itself when it queues an envelope. The counter
example names that pair a `Packet`:

#code_file("examples/counter.odin", [
```odin
// An envelope in flight. A message points at a value inside the sender's ledger, so a
// transport copies the value when it queues the envelope, exactly as a codec would.
Packet :: struct {
	envelope: paxos.Envelope(Command),
	value:    Command,
}

packet_of :: proc(envelope: paxos.Envelope(Command)) -> (packet: Packet) {
	packet.envelope = envelope
	if value, carries := paxos.message_value(envelope.message); carries do packet.value = value^
	return
}

packet_envelope :: proc(packet: ^Packet) -> paxos.Envelope(Command) {
	envelope := packet.envelope
	#partial switch &m in envelope.message {
	case paxos.Promise_Message(Command): m.value = &packet.value
	case paxos.Accept_Message(Command):  m.value = &packet.value
	case paxos.Commit_Message(Command):  m.value = &packet.value
	}
	return envelope
}
```
])

`packet_of` copies the value out at enqueue time; `packet_envelope` points the
message back at the packet's own copy for the duration of the `step` call. The
same idiom, generic over the value type, is `Packet(V)` in
`tests/harness.odin`. The one exception to "into the ledger" is a decision for
the slot just past the window edge: `record_commit` releases it through the
node's `pass_through` field, which is why the `committed` list has room for
`WINDOW_SLOTS + 1` entries. The pointer rule is the same either way: valid
until the node's next transition.

=== The host commit sequence

The host consumes one batch in a fixed order. The counter's `host_commit`
(the examples chapter) is this sequence with the journal left out:

```odin
err := paxos.step(&node, envelope, &effects)
if err != .None { /* see the section on errors */ }

// 1. Append every write, in slice order, copying each referenced value; then sync.
for w in paxos.writes_slice(&effects) do journal_append(&journal, w)
journal_sync(&journal)

// 2. Only now may anything leave the process.
paxos.confirm_writes_durable(&effects)

// 3. Transmit, copying each referenced value into the wire encoding.
for envelope in paxos.messages_slice(&effects) do transport_send(envelope)

// 4. Apply decided entries in slot order.
for entry in paxos.committed_slice(&effects) do apply(&state, entry.slot, entry.value^)

// 5. Serve history a peer asked for from below the memory floor.
for request in paxos.requests_slice(&effects) {
	switch r in request {
	case paxos.Serve_Range_Request: serve_from_journal(&journal, r.peer, r.first, r.count)
	}
}
```

`journal_append`, `journal_sync`, `transport_send`, `apply`, and
`serve_from_journal` are the host's own procedures; the library supplies none.
Two consequences of the order are easy to miss: a committed entry is applied
only after its `Write_Chosen` record is durable, because step 4 follows step 2;
and the next transition on the same batch calls `effects_reset`, so the whole
sequence must finish, and every pointer must have been followed, before the
node is stepped again.

Once the host has durably consumed a released prefix, it calls
`paxos.advance_memory_floor(&node, through)`, which licenses reuse of the cells
at or below `through`. A host that never advances the floor eventually receives
`.Window_Full` from every proposal; that is backpressure, not a bug in the log.

=== The runtime gate

With the default `.Enforced` gate, reading the messages or resetting the batch
while `writes_pending` is still true stops the process:

```text
-- DURABILITY ORDER VIOLATION --------------------------------------------------

messages_slice before confirm_writes_durable.

Hint: Persist and sync the pending writes before calling confirm_writes_durable(),
then transmit messages and reset the batch. Never confirm a failed write.
Recover from the durable journal before restarting this stopped node.
```

`host_order_violation` prints this, or the variant `reset discarded unconfirmed
writes`, and calls `os.exit(1)`; it is declared `-> !`. The check is a
`when G == .Enforced` branch, not a debug assertion, so it is present in
optimised builds; `tools/check_contracts.py` builds each of its four
durability fixtures with `-debug` and again with `-o:speed` and requires the
named diagnostic and a `Hint:` line in both. Because every transition begins
with `effects_reset`, a host that forgets `confirm_writes_durable` is stopped
at its next call even if it never reads the messages.

The zero value of `Effects` is ready to use; the fixture `zero_value_is_ready`
resets and reads a fresh batch with no initialisation call. Two procedures clear
a batch. `effects_init` (`paxos.init(&effects)`) clears without checking the
gate, for fresh memory or for a batch a crashed process can never complete; the
simulator calls it after a simulated crash. `effects_reset`
(`paxos.reset(&effects)`) clears after checking the gate, and every transition
calls it on entry.

Two further queries help a host tune its storage. `requires_power_loss_barrier`
is true when the batch carries a `Write_Promise`, a `Write_Promise_At`, or a
`Write_Vote`; decision and trim records are derived state a host may persist
with a cheaper barrier. `pre_durable_messages` returns an iterator whose
`pre_durable_next` yields only `Accept_Message` envelopes whose ballot has a
round above zero, the class the library documents as pipelinable before the
local sync barrier completes. The comment explains the exclusion:

#code_file("src/effects.odin", [
```odin
// Accept requests at a campaign ballot may leave before the local barrier: they ask peers
// to persist a vote and claim nothing about the sender's own durability, and a restarted
// proposer always campaigns at a fresh ballot. An owner's round-zero suggestion is the
// exception: its own vote is the only durable record that the instance was used, so it
// must wait for the barrier or a restart could reuse the ballot for another value.
```
])

The gate does not check this iterator, so a host that uses it takes on the
reasoning itself.

#predict([
  A transition returns `.None`; its batch holds one `Write_Vote` and two
  `Accept_Message` envelopes. The host calls `confirm_writes_durable`, sends both
  envelopes, and the machine loses power before the journal is synced. Which
  rule did the host break, and why could the library not catch it?
])

#warning([A failed sync invalidates the live node], [
  The transition has already mutated the node. If the append or the sync fails,
  do not confirm the batch and do not keep stepping that node. Discard it, repair
  storage, replay only the records that did complete into a fresh `Ledger`, and
  restore a fresh node from that.
])

=== The host-managed exception

A host that groups several transitions behind one storage barrier may declare
its node and batch with `GATE = .Host_Managed`. That removes the runtime check
and transfers the obligation to the host. The rules are written on the type:

#code_file("src/effects.odin", [
```odin
// .Host_Managed disables that check for hosts that own the durability boundary
// themselves, for example by grouping several transitions behind one storage barrier.
// Such a host must guarantee, by construction, that:
//   1. every write of a transition is durable before any message of that transition
//      reaches a peer;
//   2. a batch is never discarded while it still holds unconfirmed writes;
//   3. committed entries are applied only after their commit record is durable;
//   4. a crash between the writes and the barrier is recovered from the journal, never by
//      confirming writes that did not complete.
Durability_Gate :: enum {
	Enforced,
	Host_Managed,
}
```
])

The spelling is deliberately searchable: `paxos.Node(u64, 1, 64, 16,
.Host_Managed)` and its `Effects` in `tests/test_durability.odin` are the only
such declarations in the repository, and a reviewer can find every audited
exception with one grep.

== The Public Transition Surface

`src/paxos.odin` groups each verb over its receiver types, so `paxos.propose`
dispatches on whether the first argument is a `^Node` or a
`^Replicated_Log_Node`. The table gives the `Node` signatures; parameter order
matches the source.

#table(
  columns: (1.15fr, 1.35fr, 1.6fr),
  table.header([*Verb*], [*Signature after the node*], [*What it does*]),
  [`init`], [`(id, membership, options = {}) -> Error`],
    [Voting follower at slot 1; `.Not_Member` if `id` is not in the membership.],
  [`campaign`], [`(noop, &effects) -> Error`],
    [Starts phase one with a fresh ballot; `noop` fills recovered holes.
    `.Campaign_Disabled` when campaigning is off or ownership is on.],
  [`propose`], [`(value, &effects) -> (Slot, Error)`],
    [Assigns the next slot on a leader, votes for it locally, and broadcasts
    `Accept_Message`.],
  [`propose_batch`], [`(values, slots, &effects) -> ([]Slot, Error)`],
    [Up to `CHUNK_SLOTS` values into consecutive slots; `slots` is the caller's
    output buffer.],
  [`step`], [`(envelope, &effects) -> Error`],
    [Processes one authenticated envelope addressed to this node.],
  [`tick`], [`(noop, &effects) -> Error`],
    [Advances election, heartbeat, and resend counters by one interval.],
  [`reconnected`], [`(peer, &effects) -> Error`],
    [A leader resends to the peer; a follower asks the peer to learn if it is
    the leader hint. `.Invalid_Peer` for the node itself.],
  [`request_catch_up`], [`(peer, from_slot, &effects) -> Error`],
    [Sends `Learn_Message` for one chunk from `from_slot`.],
  [`learn_chosen`], [`(from, slot, value, &effects) -> Error`],
    [Installs a host-certified decision on a non-voting node.],
  [`set_campaign_enabled`], [`(enabled)`],
    [Turns campaigning on or off; a `.Preparing` node drops to `.Follower`.],
  [`advance_memory_floor`], [`(through) -> Error`],
    [Licenses cell reuse through `through`; `.Invalid_Slot` above `decided_through`.],
  [`install_chosen_trim`], [`(anchor, &effects) -> Error`],
    [Adopts a chosen trim anchor and emits `Write_Trim`.],
)

Queries read plain fields and never touch the batch:

#table(
  columns: (1.1fr, 1fr, 1.9fr),
  table.header([*Query*], [*Returns*], [*Meaning*]),
  [`role`], [`Role`], [`.Follower`, `.Preparing`, or `.Leader`.],
  [`ballot`], [`Ballot`], [The ballot this node last campaigned with.],
  [`id`], [`Node_Id`], [The local identity.],
  [`current_leader`], [`(Node_Id, bool)`], [The leader hint, if any; not a lease.],
  [`decided_through`], [`Slot`], [The greatest contiguous slot released to the host.],
  [`leader_base`], [`Slot`], [The first slot this leadership assigned.],
  [`proposal_frontier`], [`Slot`], [The slot the next proposal would take.],
  [`committed_at`], [`(Value, bool)`], [A copy of one decided value still resident in the window.],
  [`read_decided`], [`(int, Error)`], [Fills a caller buffer of `Committed(Value)` from `from_slot`;
    `.Trimmed` below the floor, `.Read_Buffer_Too_Small` if it does not fit.],
  [`is_leader_caught_up`], [`bool`], [Every inherited slot is delivered; the doc
    comment adds "not a lease and not a read barrier".],
  [`memory_floor`], [`Slot`], [The greatest slot whose cell the host released for reuse.],
  [`trim_anchor`], [`Trim_Anchor`], [The adopted chosen-trim anchor.],
  [`is_voting_member`], [`bool`], [False for a learner made by `init_learner`.],
  [`is_campaign_enabled`], [`bool`], [Whether a timeout may start a campaign.],
  [`ledger`], [`^Ledger(Value, WINDOW_SLOTS)`], [A pointer to the durable columns, for inspection.],
)

#api_anchor([`paxos.step(&node, envelope, &effects)`], [
  The one transition a transport calls. It rejects `.Wrong_Recipient` and
  `.Not_Member` before touching state, records the sender's decided prefix, and
  dispatches on the message variant.
], source: [`src/consensus.odin`])

== `Node_Options` and What Zero Means

`init` takes an optional `Node_Options` whose zero value selects every default,
so `paxos.init(&node, id, membership)` and `paxos.init(&node, id, membership,
paxos.Node_Options{priority = 2})` both read naturally.

#code_file("src/node.odin", [
```odin
Node_Options :: struct {
	// Breaks ballot ties between rounds: higher wins. Zero is the lowest priority.
	priority:                           u8,
	// Follower ticks without leader contact before it campaigns. Zero means the default.
	election_timeout_ticks:             u32,
	// Leader ticks between heartbeat broadcasts. Zero means the default.
	heartbeat_interval_ticks:           u32,
	// Leader ticks between bounded retransmission scans. Zero means the default.
	resend_interval_ticks:              u32,
	// Refuse proposals with .Leader_Catching_Up until every inherited slot is delivered.
	gate_proposals_on_inherited_prefix: bool,
	// Start as an acceptor that promises and votes but never campaigns.
	campaign_disabled:                  bool,
	// Rotating slot ownership: every member proposes in its own slots without phase one.
	// Campaigns are refused; stalls are repaired by bounded revocations.
	rotating_ownership:                 bool,
}
```
])

The timer defaults are 10 election ticks, 3 heartbeat ticks, and 10 resend
ticks. A tick is whatever interval the host calls `tick` at; the library never
reads a clock. `priority` is a `u8` because it occupies eight bits of the
packed ballot; `rotating_ownership` selects the second way to lead, which has
its own chapter.

== Restoring State After a Crash

A restarted process has an empty `Node` and a journal of `Write` records. Two
procedures fold records into a `Ledger`. `ledger_apply` is strict: a promise
lower than the current one is `.Promise_Regression`, two values under one
ballot and slot are `.Conflicting_Value`, a second value for a chosen slot is
`.Conflicting_Commit`, a record addressing a cell still held by an earlier
slot is `.Window_Overrun`, and an anchor that moves backward is
`.Trim_Regression`; use it for one configuration's journal, where each of
these is corruption. `ledger_replay_fold` is for a lifetime journal: promises
fold to their maximum, a vote whose cell has since been claimed by a newer
slot is skipped as dead history, and decisions and trim records keep the
strict rules.

Because a `Write_Vote` or `Write_Chosen` carries a pointer, the journal must
hold the value alongside the record and point the record back at it during
replay. `tests/harness.odin` is the reference pattern:

#code_file("tests/harness.odin", [
```odin
// One journaled record with its value copied out of the ledger.
Journal_Record :: struct($Value: typeid) {
	write: paxos.Write(Value),
	value: Value,
}

journal_append :: proc(journal: ^[dynamic]Journal_Record($V), writes: []paxos.Write(V)) {
	for w in writes {
		record := Journal_Record(V){write = w}
		#partial switch x in w {
		case paxos.Write_Vote(V):   record.value = x.value^
		case paxos.Write_Chosen(V): record.value = x.value^
		}
		append(journal, record)
	}
}

// Rebuilds a ledger from a journal with the lifetime fold.
journal_replay :: proc(
	journal: []Journal_Record($V),
	ledger: ^paxos.Ledger(V, $W),
) -> paxos.Error {
	for &record in journal {
		write := record.write
		#partial switch &x in write {
		case paxos.Write_Vote(V):   x.value = &record.value
		case paxos.Write_Chosen(V): x.value = &record.value
		}
		paxos.ledger_replay_fold(ledger, write) or_return
	}
	return .None
}
```
])

The simulator's restart path does the same fold inline and then restores every
derived frontier:

#code_file("sim/simulation.odin", [
```odin
	// Replay the lifetime journal into fresh durable state, then restore every derived frontier.
	ledger: paxos.Ledger(u64, SIM_WINDOW)
	for &record in small_array.slice(&sim.journals[node_idx]) {
		write := record.write
		#partial switch &w in write {
		case paxos.Write_Vote(u64):   w.value = &record.value
		case paxos.Write_Chosen(u64): w.value = &record.value
		}
		sim_check(paxos.ledger_replay_fold(&ledger, write))
	}
	options := paxos.Node_Options{priority = u8(node_idx), rotating_ownership = sim.config.ownership}
	floor := sim.consumed[node_idx]
	sim_check(paxos.restore(&sim.nodes[node_idx], id, sim.membership, ledger, floor, options))
```
])

Four restore procedures differ in what they keep and what they clear:

- `restore(node, id, membership, ledger, floor = 0, options = {})` runs `init`
  first, so every volatile field starts fresh: role `.Follower`, zero ballot,
  no leader hint, no election state. It installs `ledger`, clears every cell at
  or below `max(floor, ledger.anchor.chosen_trim_slot)` that holds only an
  open vote, and resumes `memory_floor` and `decided_through` at that base.
  `floor` is the slot through which the host has durably consumed the log;
  zero for a node that never released anything.
- `continue_at(node, id, membership, floor, anchor, options = {})` starts an
  *empty* node on the same slot line with an inherited trim anchor, for a
  configuration handover or a state-image install; `.Trim_Regression` if the
  anchor lies above `floor`.
- `begin_recovery(node, anchor)` acts on a live node. It applies the anchor
  through `ledger_apply`, clears open votes at or below it, and drops the node
  to `.Follower` with its election state cleared. It keeps the promised ballot
  and every vote or decision above the anchor, because such a vote can belong
  to a chosen quorum this node has not yet learned about. It takes no batch, so
  the host persists the image and anchor itself before stepping the node
  again.
- `restore_learner(node, id, membership, ledger)` rebuilds a non-voting learner
  from its decision-only journal.

None of these restores application state, client sessions, or transport queues.
The host restores its state image and applied slot from its own durable data
and replays committed records above that slot idempotently before serving.

== Errors

Every transition returns an `Error`; `.None` is zero, so `if err != .None` is
the whole test. The enum in `src/errors.odin` groups its members as membership,
input and addressing, role and capability, liveness and progress, durability
and safety, and replicated-log and window errors. Not every error is
retryable: `.Not_Leader` and `.Window_Full` describe a state the host can wait
out, while `.Conflicting_Commit` and `.Promise_Regression` are safety incidents
whose hints tell the operator to stop and keep the evidence. `explain_error`
returns an operator-facing banner for each; the table `EXPLANATIONS` is
indexed by the enum, so a value without an entry fails the exhaustive test in
`tests/test_errors.odin`. This is the text for `.Not_Leader`:

```text
-- NOT LEADER ------------------------------------------------------------------

This node has not completed phase one for its current ballot.
Hint: Route to current_leader() or wait for a successful campaign.
```

The counter example passes that string as the message of an `assert`; a host
logs it and decides on retry or shutdown by the error's group.

#teach_back([
  Draw a vertical line labelled library and host. Place `Node`, `Ledger`,
  `Effects`, the value a `Write_Vote` points at, journal bytes, socket bytes,
  tick scheduling, application state, and the state image on the correct side.
  Then mark the one arrow that is forbidden until a sync has completed, name
  the library call that stops the process if the host draws it too early, and
  say at which call every pointer in the batch becomes invalid.
])
