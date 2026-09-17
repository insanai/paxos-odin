#import "theme.typ": *

= Writing Reviewable Consensus Code

#objectives([
  By the end of this chapter you should be able to recognise the Odin idioms the
  library is built from, explain why each one was chosen for a consensus core,
  tell an `Error` from an assertion from a process stop, and review a change to
  `src/` in the order a proof would be read.
])

== The Zen of Odin for InsanAI

Before any rule, the creed. Every guideline in this chapter is a consequence of one of
these lines, and every review comment on this repository can cite one.

#book_quote([
    Data is real; code is just the stream. \
  Explicit is better than a hidden scheme. \
  Simple blocks beat abstractions built too high, \
  A mere mortal should see how the segments tie. \
  Keep close to the metal, let allocations show, \
  Pass your contexts cleanly so the lifetimes flow. \
  Errors are values, never cast aside, \
  Handle them explicitly; let nothing hide. \
  Fail with grace, let diagnostics guide: \
  Show the break, the hint, the fix inside. \
  Design for speed, let safety lead the pace, \
  Waste no cycle, leave no leaking trace. \
  Keep it simple to use, explain, and maintain, \
  So years from now, the logic remains plain. \
  Coherence beats purity when real problems strike, \
  But structure your memory as hardware would like.
], [The Zen of Odin for InsanAI, POD 0001])

The creed has teeth. `tools/check_style.py` enforces the structural constraints on every
Odin file, and `make vet`, `make check`, and `paxodin check` run it first:

#table(
  columns: (auto, 1fr, 1.2fr),
  table.header([*Constraint*], [*Limit*], [*How this repository meets it*]),
  [File boundary], [At most 1,408 physical lines per file.],
    [The core is ten files, each one concern: `ballot.odin`, `bit_set.odin`,
    `membership.odin`, `ledger.odin`, `messages.odin`, `effects.odin`, `node.odin`,
    `election.odin`, `consensus.odin`, `ownership.odin`; around them
    `replicated_log.odin`, `learner.odin`, `errors.odin`, and `paxos.odin`.],
  [Line width], [99 columns soft, 108 columns hard (tabs count as four); a longer line fails the build.],
    [Long parametric signatures are broken one parameter per line.],
  [Procedure density], [At most 70 lines of logic per body; blank, comment, and divider lines do not count.],
    [`EXPLANATIONS` is a data table, `node_step` is a dispatch, phase one is
    `on_prepare`, `on_promise`, `on_promise_range`, `maybe_resolve_chunk`, and
    `resolve_chunk` rather than one procedure.],
  [Elm-style diagnostics], [Context, hint, and remediation in every error.],
    [`Error` plus `explain_error`; the durability gate's banner; every `#assert` message.],
  [Performance and longevity], [Mechanical sympathy, safety by visibility, the mere-mortal explainability test.],
    [Columns and bitmaps in the `Ledger`, a ballot in one integer, inline buffers;
    `where` clauses and the runtime gate; no clever code that a reviewer cannot restate.],
)

== Why Zero Allocation Matters

A transition that can fail on allocation has one more failure path than the
proof accounts for. Allocation failure is not itself a safety violation; a node
that stops cleanly on it stays fail-stop. But it adds latency variance,
fragmentation, and ownership questions to every transition. The library removes
the question instead of answering it.

No procedure in `src/` calls `context.allocator`, `new`, or `make`. Every
capacity is a type parameter: `MAX_MEMBERS`, `WINDOW_SLOTS`, and `CHUNK_SLOTS`
on `Node` and `Effects`, `WINDOW` on `Ledger`, `MAX_METADATA_BYTES` on
`Replicated_Log_Node`, and `MAX_ENTRIES` on `Learner`. The size of a node, a
batch, and a ledger is therefore a compile-time constant, and the exact
per-transition maxima in the `Effects` comment are the reason a batch can never
overflow. Values are not copied into batches either: a write, a message, or a
committed entry points into the ledger, and the host's transport and journal determine how many copies occur. The hosts that surround the core are free to allocate: the
counter uses `core:container/queue` for its network and `tests/harness.odin`
keeps its journal and its queue in a `[dynamic]` array. The line is drawn at
the package boundary, not at the process.

== The Odin Idioms This Library Uses

Each idiom below appears in the source as quoted. They are not decoration; each
one removes a class of review question.

=== Struct of arrays, with bitmaps for the scans

The ledger is not an array of cell structs. Each of Lamport's variables is its
own column, and two bitmaps say which cells are worth visiting:

#code_file("src/ledger.odin", [
```odin
	slot:        [WINDOW]Slot,
	promised_at: [WINDOW]Ballot,
	vote_ballot: [WINDOW]Ballot,
	state:       [WINDOW]Cell_State,
	value:       [WINDOW]Value,
	// Bitmaps over cells: `used` has a vote or a decision, `chosen` has a decision.
	used:        Bit_Set(WINDOW),
	chosen:      Bit_Set(WINDOW),
```
])

A phase-one answer walks `used` and reads `slot`, `vote_ballot`, and `state`;
the metadata walk does not load the payload bytes. Producing and consuming the
reply still costs work: the host copies or serialises each reported value. The walk itself is `bit_set_next`, which
counts trailing zeros in a 64-bit word instead of testing every cell:

#code_file("src/ledger.odin", [
```odin
// The greatest slot held by any used cell.
ledger_highest_used :: proc(l: ^Ledger($Value, $WINDOW)) -> Slot {
	highest: Slot
	cell, more := bit_set_next(l.used, 0)
	for more {
		highest = max(highest, l.slot[cell])
		cell, more = bit_set_next(l.used, cell + 1)
	}
	return highest
}
```
])

The same loop shape answers a `Learn_Message` over `chosen` and drives a
resend sweep over `used`. The reviewer's question changes from "did this loop
visit every cell?" to "is the bitmap kept in step with the `state` column?",
and `node_assert_valid` asks exactly that.

=== A ballot is one integer

Lamport's B1 needs a total order on ballots. The library packs the round, the
priority, and the proposer into one `u64` so that the order is integer
comparison and every record and message carries eight bytes:

#code_file("src/ballot.odin", [
```odin
Ballot :: distinct u64

BALLOT_ZERO      :: Ballot(0)
BALLOT_ROUND_BITS :: 40
MAX_ROUND        :: u64(1) << BALLOT_ROUND_BITS - 1

ballot_make :: #force_inline proc(round: u64, priority: u8, node: Node_Id) -> Ballot {
	return Ballot(round << 24 | u64(priority) << 16 | u64(node))
}

ballot_round :: #force_inline proc(b: Ballot) -> u64 {
	return u64(b) >> 24
}
```
])

`distinct` matters: a `Ballot` is not a `u64` to the compiler, so a slot or a
count cannot be passed where a ballot belongs, while `<` and `max` still work
because the underlying type is an integer. The fields are read with
`ballot_round`, `ballot_priority`, and `ballot_node`, never with a shift at a
call site.

=== `#force_inline` helpers

The one-line accessors on the hot path are marked `#force_inline`, so a helper
that exists for naming costs no call:

#code_file("src/ballot.odin", [
```odin
// The window index of a slot. WINDOW is a power of two, so this is one mask.
cell_of :: #force_inline proc(slot: Slot, $WINDOW: int) -> int {
	return int((slot - 1) & Slot(WINDOW - 1))
}
```
])

`ledger_promise_for`, `ledger_cell`, `ledger_record_vote`, the `bit_set_`
accessors, and the `effects_add_` producers follow the same rule. The
attribute is reserved for bodies a reviewer can read in one glance; a
procedure with a loop or a branch that matters is a plain `proc`.

=== Pointers into the ledger instead of copies

A transition never copies a value into its batch. The `Committed` entry, the
`Write_Vote`, and the `Accept_Message` all point at the ledger cell:

#code_file("src/consensus.odin", [
```odin
	l.promised_at[cell] = max(l.promised_at[cell], ballot)
	ledger_record_vote(l, cell, ballot, value)
	effects_add_write(effects, Write_Vote(V){ballot = ballot, slot = slot, value = &l.value[cell]})
```
])

The lifetime is the contract stated in `src/messages.odin`: the pointer is
valid until that node's next transition, and every transition begins with
`effects_reset`. This is "pass your contexts cleanly so the lifetimes flow" in
its narrowest form. The host's side of the idiom is the `Packet` in
`examples/counter.odin`, which copies the value at enqueue time.

=== Proc groups

Odin's procedure groups let one verb serve several receiver types. The public
surface in `src/paxos.odin` is a list of such groups:

#code_file("src/paxos.odin", [
```odin
campaign             :: proc{node_campaign, replicated_log_campaign}
propose              :: proc{node_propose, replicated_log_propose}
propose_batch        :: proc{node_propose_batch, replicated_log_propose_batch}
step                 :: proc{node_step, replicated_log_step, replicated_log_step_checked}
```
])

`paxos.propose(&node, value, &effects)` resolves to `node_propose` when the first
argument is a `^Node` and to `replicated_log_propose` when it is a
`^Replicated_Log_Node`; `paxos.step` further distinguishes a bare `Envelope` from
a `Log_Envelope` that carries a configuration id. `paxos.init` covers six
receivers, from `Node` to `Stop_Sign`. The long spellings stay available for a
call site that wants to name its receiver.

=== Parametric structs with defaults and `where` clauses

The `Node` header from the library chapter shows all three features at once:
`$Value: typeid` makes the struct generic over the command type, `$MAX_MEMBERS:
int = DEFAULT_MAX_MEMBERS` gives each capacity a default, and `where
intrinsics.type_is_comparable(Value)` rejects a value type the library could not
compare. A procedure over such a struct binds the parameters once with `$` and
then spells the batch with the bound names:

#code_file("src/consensus.odin", [
```odin
node_propose :: proc(
	node: ^Node($V, $M, $W, $C, $G),
	value: V,
	effects: ^Effects(V, M, W, C, G),
) -> (slot: Slot, err: Error) {
```
])

Because `effects` is spelled with `V, M, W, C, G` rather than fresh `$`
parameters, a batch of a different configuration does not match; that is the
whole mechanism behind "the compiler rejects a mismatch".

=== Tagged unions and flat dispatch

`Message(Value)` is a tagged union of nine structs, and `node_step` dispatches on
it with one `switch`:

#code_file("src/consensus.odin", [
```odin
	switch msg in envelope.message {
	case Prepare_Message:       return on_prepare(node, envelope.from, msg, effects)
	case Promise_Message(V):    return on_promise(node, member, msg, effects)
	case Promise_Range_Message: return on_promise_range(node, member, msg, effects)
	case Accept_Message(V):     return on_accept(node, envelope.from, msg, effects)
	case Accepted_Message:      return on_accepted(node, member, msg, effects)
	case Commit_Message(V):     return on_commit(node, envelope.from, msg, effects)
	case Learn_Message:         return on_learn(node, envelope.from, msg, effects)
	case Nack_Message:          on_nack(node, msg)
	case Heartbeat_Message:     on_heartbeat(node, envelope.from, msg, effects)
	}
```
])

`member` is the sender's stable membership index, resolved once by
`membership_index_of` before the switch; the handlers that count promises or
acknowledgements take it instead of the id. A non-`#partial` switch over a union
must name every variant, so adding a tenth message kind fails to compile until
every dispatcher handles it. The `Write`
union is consumed the same way by `ledger_apply`, `ledger_replay_fold`, and
`effects_requires_power_loss_barrier`; `message_value` uses `#partial switch`
deliberately, because most kinds carry no value.

=== `Maybe` for absent values

Optional state is a `Maybe(T)`, never a sentinel inside `T`. `leader_hint` is
`Maybe(Node_Id)`, the remembered `noop` is `Maybe(Value)`, and a log's decided
`stop_sign` is `Maybe(Stop_Sign(...))`. Unwrapping uses `.?`, either directly
where absence is impossible or in the two-value form where it must be tested:

#code_file("src/consensus.odin", [
```odin
	if node.role == .Leader {
		resend_to(node, peer, effects)
	} else if hint, ok := node.leader_hint.?; ok && hint == peer {
		request_learn(node, peer, effects)
	}
```
])

`node_current_leader` returns `node.leader_hint.?` unchanged, which is why its
result is `(Node_Id, bool)`. Where absence is a normal state of a cell, the
library uses an enum instead: `Cell_State` has an explicit `.Empty`, because a
cell has three states, not two.

=== Bit sets, native and wrapped

Odin's native `bit_set` holds at most one machine word of members, and both
windows and memberships may be larger, so `src/bit_set.odin` wraps an array of
`bit_set[0..<64]` words. Insertion reports whether the member was new, which
is what a vote counter needs:

#code_file("src/bit_set.odin", [
```odin
// Inserts an index. Returns true when it was not present before.
bit_set_insert :: #force_inline proc(bs: ^Bit_Set($N), index: int) -> bool {
	w, b := index / WORD_BITS, index % WORD_BITS
	if b in bs.words[w] do return false
	bs.words[w] += {b}
	return true
}
```
])

A leader counts votes per slot in `acknowledgements[cell]`, a
`Bit_Set(MAX_MEMBERS)`, and keeps the count in `acknowledged[cell]` so the
quorum test is one comparison; a duplicate reply cannot inflate it:

#code_file("src/consensus.odin", [
```odin
	if bit_set_insert(&node.acknowledgements[cell], member) do node.acknowledged[cell] += 1
	if int(node.acknowledged[cell]) < membership_write_quorum(&node.membership) do return .None
```
])

=== `core:container/small_array` for bounded lists

Every bounded list is a `small_array.Small_Array(N, T)`: the membership's
members, a stop sign's members and metadata, an owner's resubmit queue, and the
four lists in `Effects`. The storage is inline in the struct, `push_back`
reports overflow as a `bool` instead of growing, and `slice` hands the host a
view without a copy. The library's own append helpers write into the inline
storage directly and treat an overrun as a bug rather than as backpressure
(`effects_overrun` panics with a hint), because the capacity was computed to
make overflow impossible:

#code_file("src/effects.odin", [
```odin
effects_add_write :: #force_inline proc(e: ^Effects($V, $M, $W, $C, $G), w: Write(V)) {
	n := e.writes.len
	if n >= len(e.writes.data) do effects_overrun("writes")
	#no_bounds_check e.writes.data[n] = w
	e.writes.len = n + 1
	e.writes_pending = true
}
```
])

=== `or_return` and named results

A procedure that returns an `Error` last can propagate a callee's error with
`or_return`, which keeps the happy path unindented. Named results make the
propagation read as a sentence:

#code_file("src/consensus.odin", [
```odin
) -> (slot: Slot, err: Error) {
	effects_reset(effects)
	proposal_gate(node) or_return
	if node.ownership do return propose_owned(node, value, effects)
	if node.next_slot == max(Slot) do return 0, .Global_Slot_Exhausted
	if node.next_slot - node.memory_floor > Slot(W) do return 0, .Window_Full
	slot = node.next_slot
	node.next_slot += 1
	send_accept(node, slot, node.ballot, value, effects) or_return
	return slot, .None
}
```
])

=== `for &record in` when the element's address matters

Iterating by reference makes it explicit at the loop header that the body
takes the element's address or mutates it in place. The journal replay in the
test harness needs the address, because the record it hands to the ledger must
point at the journal's own copy of the value:

#code_file("tests/harness.odin", [
```odin
	for &record in journal {
		write := record.write
		#partial switch &x in write {
		case paxos.Write_Vote(V):   x.value = &record.value
		case paxos.Write_Chosen(V): x.value = &record.value
		}
		paxos.ledger_replay_fold(ledger, write) or_return
	}
```
])

A loop written `for record in` copies each element, and `&record.value` would
then point at a temporary that dies with the iteration; the `&` is the
difference a reviewer looks for. Inside `src/`, scans over the ledger index the
columns directly, `for cell in 0..<W`, because there is no element struct to
take the address of.

=== `when INVARIANT_CHECKS` invariant checks

Structural invariants are asserted in every lifecycle procedure (`node_init`,
`node_init_learner`, `node_begin_recovery`, and the shared `node_resume_at`),
but only when `INVARIANT_CHECKS` is set, so the release benchmark
measures the protocol rather than the checker:

#code_file("src/node.odin", [
```odin
@(private)
node_assert_valid :: proc(node: ^Node($V, $M, $W, $C, $G)) {
	when INVARIANT_CHECKS {
		assert(node.id != 0, "node id cannot be zero")
		if node.voting_member {
			assert(membership_contains(&node.membership, node.id), "voter outside membership")
		} else {
			assert(!membership_contains(&node.membership, node.id), "non-voter inside membership")
			assert(!node.campaign_enabled, "non-voter cannot campaign")
		}
```
])

`INVARIANT_CHECKS` is `#config(PAXOS_INVARIANT_CHECKS, ODIN_DEBUG)` in
`src/paxos.odin`: on in debug builds, off in release builds, and overridable
either way with `-define:PAXOS_INVARIANT_CHECKS=true` or `=false`. `when` is a
compile-time branch: the body is not compiled out by an optimiser's choice but
omitted from the program in the first place. Nothing the host can observe
depends on these checks, which is the test for whether a `when
INVARIANT_CHECKS` guard is appropriate.

== Control-Flow Rules

- *Return early.* A transition tests its preconditions first and returns the
  matching `Error`, so the mutation that follows is unconditional:
  `proposal_gate` opens `node_propose` with `.Not_Voter`, `.Not_Leader`, and
  `.Leader_Catching_Up` before a slot is assigned.
- *Dispatch flat.* One `switch` per union, one handler per variant, no handler
  table and no reflection.
- *Bound every loop.* A loop runs over a fixed array, a `small_array` slice, a
  bitmap, or a range no larger than a type parameter. `resend_to` iterates at
  most `WINDOW_SLOTS` times and stops after `CHUNK_SLOTS` sends, so one
  transition cannot emit more than the batch was sized for.
- *Never wrap.* Slot arithmetic goes through `slot_add`, which saturates at
  `max(Slot)`, and the counters in `tick` use `saturating_increment`.
- *No hidden allocation.* A transition receives its output buffer as a
  `^Effects` argument and never returns a slice it had to allocate.

== Memory and Type Guidelines

- Types are `Ada_Case` (`Node_Options`, `Write_Vote`, `Durability_Gate`);
  procedures are `snake_case`.
- Procedures are prefixed with their receiver: `node_`, `effects_`,
  `membership_`, `ledger_`, `ballot_`, `bit_set_`, `replicated_log_`,
  `learner_`. The proc groups in `src/paxos.odin` add the short verbs on top;
  they do not replace the long names.
- `Node_Id :: u16` and `Slot :: u64` are plain aliases, not distinct types. The
  compiler will not stop a host from passing a slot where an id belongs, so the
  names must carry that weight at every call site. `Ballot :: distinct u64` is
  the exception, because a ballot is compared but never used as an index or a
  count.
- Zero is reserved as a sentinel wherever an identity or position is
  one-based: node id zero, slot zero, configuration id zero, and `BALLOT_ZERO`.
  `membership_init` rejects a zero id with `.Invalid_Node_Id`, and every
  transition that addresses a log entry rejects slot zero with `.Invalid_Slot`.
- Large values are written through destination pointers. `node_init` assigns
  `node^ = Node(V, M, W, C, G){...}`; nothing returns a `Node` or a `Ledger` by
  value.

== State and Invariant Safety

The ledger moves in one direction. `ledger_apply` refuses a lower promise, a
second value under one ballot and slot, a second value for one chosen slot, and
a record that would overrun a cell an earlier slot still holds;
`install_chosen_trim` refuses an anchor that moves backward or disagrees with
the adopted one under the same `trim_id`. The window is a ring, so a cell is
claimed only when it is empty or its previous occupant is safe to forget:
`claim_live` reuses a cell only below the memory floor and only if it held a
decision. A vote above the floor is never overwritten by the library, because
it may be part of a quorum that chose a value this node has not learned.

Every mutation of `node.ledger` is paired with the `Write` that will make it
durable, in the same procedure, a few lines apart: `ledger_record_vote` with
`Write_Vote`, `ledger_record_chosen` with `Write_Chosen`, an assignment to
`promised` with `Write_Promise`. When reviewing, find the mutation and find
the `effects_add_write`; if one is present without the other, the in-memory
node and the journal will disagree after a restart.

== Errors Versus Assertions

Three kinds of failure use three different mechanisms, and the choice is part of
the design.

- *Return an `Error`* for any condition the host can cause or observe: a
  message from a non-member, a proposal on a follower, a full window, a journal
  record that regresses a promise. The host decides whether to retry, route
  elsewhere, or stop, and `explain_error` tells an operator which.
- *Assert* only what the library itself guarantees. The capacity check in
  `effects_add_write` and its three siblings in `src/effects.odin` (one branch,
  then `effects_overrun`) guards a capacity the library computed. If one of
  these fires, the bug is in `src/`, not in the host. The invariant checks in `node_assert_valid` are the same class, gated
  by `INVARIANT_CHECKS`.
- *Stop the process* only for the durability gate. `host_order_violation` is
  declared `-> !`, prints its banner, and calls `os.exit(1)`. The violation is
  the host's, but it cannot be returned as an error, because a host that reached
  this point has already shown it does not check the order; and it cannot be a
  debug assertion, because the danger is greatest in production.

`#assert` is the fourth tool, for anything decidable at compile time: capacity
bounds, the power-of-two window, and the comparability of `Value`.

== Comments and Documentation

Every public procedure carries a doc comment directly above it that states what
the host must know: ordering, durability, bounds, or ownership. The comment on
`node_is_leader_caught_up` is the model, because it says what the query does not
promise as clearly as what it does:

#code_file("src/node.odin", [
```odin
// Reports prefix catch-up only. This is not a lease and not a read barrier.
node_is_leader_caught_up :: proc(node: ^Node($V, $M, $W, $C, $G)) -> bool {
	return node.delivered_through >= node.leader_base - 1
}
```
])

Inside a procedure, a comment explains *why* a line exists, not what it does.
`node_begin_recovery` explains why votes above the anchor survive;
`on_heartbeat` explains why a follower promises to a ballot it never saw a
prepare for; `record_commit` explains why a decision past the window edge
takes the `pass_through` path. Unsupported behaviour is stated where a reader
would look for it, as in the example above, rather than left for the reader to
infer.

== Tests and Measurements

`tools/check.py` is the repeatable verification entry point. It runs in a
temporary directory so a stale binary can never mask a failure, and it performs,
in order:

+ *Style*: every `.odin` file within the Zen constraints (108 columns, 1,408 lines, 70-line bodies), then
  `odin check -vet -strict-style` on `tests`, `sim`, `bench`, `cli`, and
  `examples/counter.odin`. The library is fully parametric, so its bodies are
  checked through the packages that instantiate it.
+ *Unit tests in two builds*: `odin test tests` with `-debug` and again with
  `-o:speed`, so a test cannot pass only because an invariant check was present.
+ *Contracts*: `tools/check_contracts.py`, the nine compile-fail fixtures and
  the four durability fixtures from the library chapter, the latter built with
  `-debug` and with `-o:speed`.
+ *Seeded simulations*: the `sim` binary for one, three, and five nodes across a
  range of seeds and steps (twenty seeds of ten thousand steps by default),
  once with a single leader and once with `--ownership`, with crashes injected
  inside the host commit sequence and oracles run after every transition. Another
  120 runs use window 8/chunk 3 and majority or extreme flexible quorums.
+ *The example*: `examples/counter.odin` must run to completion.
+ *Benchmark schema*: the `bench` binary with `--iterations=1024 --json` must
  report eleven results with positive throughput and latency; the numbers
  themselves are not asserted.
+ *CLI failure propagation*: with a fake `odin` that exits non-zero on the path,
  `cli test` must fail and print a `Hint:` line, so a wrapper can never report
  success over a failed tool.

A protocol bug found by any of these gets a deterministic test of its schedule
before it is fixed.

== Review Checklist: A Human Proof Outline

Read a change to `src/` in this order. Each question is a proof obligation, and
a change that cannot answer one is not ready.

+ *Which invariant does this touch?* Name it: B1 ballot uniqueness, B2 quorum
  intersection, B3 max-vote preservation, D1 indelible ink, L1 contiguous
  delivery, or S1 stop-sign sealing, as listed at the top of `src/paxos.odin`.
+ *Is every ledger mutation paired with its `Write`?* Find the
  `ledger_record_vote`, `ledger_record_chosen`, or assignment to `promised` or
  `promised_at`, and the matching `effects_add_write`.
+ *Does the message leave only after the write?* The write is appended to the
  batch before the message, and the host order does the rest; a new message that
  depends on a new write must follow the same pattern.
+ *Does every pointer in the batch point at something that outlives the
  batch?* Into the ledger, or into `pass_through`; never at a local.
+ *Is the handler idempotent?* Deliver the message twice, and once late. A
  duplicate `Accepted_Message` must not count twice; a stale `Prepare_Message`
  must draw a `Nack_Message`, not a promise.
+ *Is every loop bounded?* By a fixed array, a `small_array` length, a bitmap,
  or a type parameter; and is the batch capacity still the exact maximum?
+ *Are the bitmaps in step with the columns?* A cell that becomes `.Voted` or
  `.Chosen` is inserted into `used` (and `chosen`); a cell that is reopened is
  removed from both.
+ *Does zero still mean what it did?* A new field's zero must be a valid state,
  and a new option's zero must be the default.
+ *Is the failure classified correctly?* Host-caused conditions return an
  `Error` with a banner; library guarantees are asserted; only the gate stops
  the process.
+ *What does restore do with it?* If the change adds durable state, both
  `ledger_apply` and `ledger_replay_fold` must fold it, and `node_resume_at`
  must recompute any frontier derived from it.
+ *Which test reproduces the bug or exercises the feature?* A unit test with a
  fixed schedule, and where delivery order matters, a simulator oracle in both
  leadership modes.
+ *Can a colleague read the diff as a proof?* Precondition, protected state,
  durable change, emitted evidence, duplicate behaviour, failure behaviour, in
  that order, without opening this book.

#teach_back([
  Choose `on_accept` or `ledger_apply`. Before reading it, write its proof
  outline in the order of the checklist: precondition, state protected, durable
  change, emitted evidence, behaviour on a duplicate, behaviour on a failure.
  Then read the procedure and list every line your outline did not predict.
])
