#import "theme.typ": *
#import "figures.typ": *

#part_page("I", [One decision], [
  We begin with one blank line in a ledger and three librarians who cannot meet.
  We end with three rules that decide whether any Paxos message is legal.
])

= Foundations of Consensus

#objectives([
  After completing this chapter, you will be able to:
  - Distinguish safety invariants from liveness conditions in asynchronous systems.
  - Calculate valid read and write quorum configurations in `membership_init` and explain why invalid sizes are rejected.
  - Order ballots structured as `(round, priority, node)` triples using lexicographical integer comparison.
  - State Lamport's ballot invariants B1, B2, and B3, and identify the Odin procedures that enforce each rule.
  - Explain why quorum intersection guarantees safety across crashes only when acceptors persist promises and votes to non-volatile storage.
])

#checkpoint([Prerequisites], [
  This chapter assumes familiarity with basic set theory, integer arithmetic, and the asynchronous network model (where messages may be delayed, duplicated, or dropped, and nodes may fail by stopping). If you already know Paxos, review the self-test exercises at the end of the chapter to verify that your mental model relies on highest-ballot selection rather than counting votes.
])

== The empty ledger

Three librarians sit in three separate rooms. Each keeps a copy of the same ledger,
and the next line of every copy is blank. Two merchants arrive at the front desk at
the same moment. One wants the line to read `olive_oil = 50`; the other wants
`olive_oil = 80`. Each merchant hires runners to carry slips to the librarians.

The librarians cannot leave their rooms; they talk only through runners, and the
runners are unreliable. A runner may take an hour or a week, deliver slips out of the
order they were written, deliver the same slip twice, or never arrive. The one thing
a runner never does is change the words on a slip.

What we want is easy to state. At most one value may ever be marked final on that line.
Tentative votes may differ; final decisions must agree. A merchant may be told a value only after it is settled. And
if runners deliver, a majority of librarians stay at their desks, and one proposer
can finish without repeated interruption, the line should
eventually be filled. The first two wishes say what must never happen; the third says
what should eventually happen. They are different kinds of promise.

#definition([Safety], [
  Nothing bad ever happens. For one ledger line, two different values are never
  chosen, and a chosen value stays chosen. A safety property can be violated only by
  something that has already happened, so it never depends on how fast a runner is.
])

#definition([Liveness], [
  Something good eventually happens. For one ledger line, some proposed value is
  eventually chosen, provided enough librarians are awake, enough runners deliver,
  and one merchant is left alone long enough to finish.
])

A library where nobody writes anything is perfectly safe. That sounds like a joke,
but it lets us design the rules that keep us safe first, with no assumption about
time, and add the rules that make progress afterwards. Every rule in this chapter is
a safety rule.

#predict([
  Librarians 1 and 2 have each written `olive_oil = 50` in ink and told nobody.
  Librarian 3 has an empty line. Is the value chosen? Write one sentence before you
  read on, and do not use the phrase "the merchant knows" in it.
])

== Three tempting answers

Each of these designs is the first thing a careful engineer proposes. Each fails, and
each contributes a piece that survives into the final protocol.

*First writer wins.* Each librarian writes whichever slip reaches her first. Runner A
reaches librarian 1 first, runner B reaches librarian 2 first, and now copy 1 says 50
and copy 2 says 80, forever. What survives: every librarian keeps local state and
answers from it. What fails: nothing ties the local decisions together.

*One master.* Appoint librarian 1 as the only writer; the others copy her. This works
until she falls asleep. If librarian 2 takes over, she must know whether librarian 1
already wrote something that reached a copy, and she cannot ask a sleeping colleague.
What survives: one active proposer at a time keeps the protocol simple. What fails: a
takeover has no safe way to learn the past.

*Unanimity.* Write a value only when all three librarians agree. Nobody can ever
disagree, but if one librarian is asleep or one runner is lost, the line stays blank
forever. What survives: a value is settled by a *set* of acceptances, not by one
person. What fails: the set is too large to survive a single absence.

The final protocol combines the three survivors: durable local state, ordered attempts by proposers,
and quorums that connect each new attempt to earlier decisions. Concurrent proposers
can delay progress, but must not break agreement.

#exercise([1.1], [
  A cluster has four voters. Write down two sets of two voters that do not intersect.
  Describe one execution in which each set accepts a different value for slot 1, and
  name the invariant that fails.
])

== The failure model

A proof is only as good as the world it assumes. This library assumes four rules.

+ *Nodes may crash and recover.* A node runs the algorithm exactly until it halts, and it may
  halt between any two instructions. After halting it says nothing. It comes back
  only if the host rebuilds it from a durable journal, and is then the same member
  only because it remembers what it wrote.
+ *The network is asynchronous.* There is no bound on how long a message takes. The
  core reads no clock; the host feeds it logical ticks, which affect only liveness.
+ *Runners lose, duplicate and reorder.* Any message may be dropped, delivered twice,
  or delivered after a message sent later. Every handler in `src/election.odin` and
  `src/consensus.odin` must be harmless under duplicates and correct under reordering.
+ *Nobody lies.* A delivered message is exactly what its sender wrote, and the sender
  followed the algorithm: the non-Byzantine assumption. `node_step` rejects senders
  outside the membership with `.Not_Member` but does not authenticate; that is the
  host transport's job.

#warning([The disk is part of the algorithm], [
  Rule one hides the whole difficulty. A node that halts and forgets can break a
  promise it already made. The only defence is to make the promise durable before
  anyone else can act on it; the section on durable storage shows the code.
])

== Quorums

We cannot wait for everyone, and we cannot let anyone act alone. A *quorum* is large
enough to matter and small enough to assemble.
#definition([Quorum], [
  A set of acceptors whose acceptance settles a value. The defining property is not
  size but overlap: any quorum used to read the past and any quorum used to write a
  value share at least one acceptor.
])

With $N$ acceptors and simple majorities, a quorum has at least $floor(N / 2) + 1$
members. Two majorities of an $N$-element set cannot be disjoint, because together
they would hold more than $N$ elements. The overlapping member is the witness who
carries the past into the future.

#book_figure(
  [Any two majority quorums share at least one acceptor. That acceptor is the only
  link between a value chosen earlier and a leader elected later.],
  quorum_picture(),
)

The library does not hard-code majorities. It stores a read quorum size for phase one
and a write quorum size for phase two, defaults both to the majority, and validates
only the property that matters:

#code_file("src/membership.odin", [
```odin
	majority := total / 2 + 1
	read := read_quorum_override if read_quorum_override != 0 else majority
	write := write_quorum_override if write_quorum_override != 0 else majority
	if read <= 0 || read > total do return .Invalid_Read_Quorum
	if write <= 0 || write > total do return .Invalid_Write_Quorum
	if read + write <= total do return .Non_Intersecting_Quorums
	validated.read_quorum_size, validated.write_quorum_size = read, write
```
])

Odin's integer division makes `5 / 2 + 1` evaluate to `3`: five members with default
quorums need three promises and three acceptances. A host may lower the write quorum
to two only if it raises the read quorum to four, because the sum must exceed `total`.
The error names the consequence, not the arithmetic: `.Non_Intersecting_Quorums`.

Why odd counts? Three acceptors need two and survive one crash. Four need three and
still survive only one: the fourth member costs a machine, a journal and a link and
does not increase the number of crashes tolerated by majority quorums. Five need three and survive two. Voting groups are usually three or five.

=== Intersection is not memory

Suppose acceptors 1 and 2 accept `olive_oil = 50`. Later a new leader asks acceptors 2
and 3 what they have accepted. The sets intersect at acceptor 2, so on paper the
leader must learn about the 50.

Now suppose acceptor 2 kept its vote only in RAM and lost power in between. It
restarts with an empty line and says it has never voted. The new leader proposes 80 to
acceptors 2 and 3, they accept, and the ledger has chosen two values. The intersection
still exists; the knowledge does not. Overlap is a property of sets; safety also needs
a property of memory, the subject of the section on durable storage.

== Ballots

Because proposers fail, we must allow many attempts to fill one line and be able to
say which attempt is later. Each attempt is a *ballot*; ballots are unique and totally
ordered.

#code_file("src/ballot.odin", [
```odin
// A ballot is one 64-bit integer, so B1 (a total order on ballots) is integer
// comparison and every message and record carries eight bytes:
//
//   bits 63..24  round      (40 bits, the campaign counter; round 0 is reserved for
//                            slot owners under rotating ownership)
//   bits 23..16  priority   (8 bits, breaks ties between rounds)
//   bits 15..0   node       (16 bits, the proposer; makes every ballot unique)
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

ballot_priority :: #force_inline proc(b: Ballot) -> u8 {
	return u8(u64(b) >> 16)
}

ballot_node :: #force_inline proc(b: Ballot) -> Node_Id {
	return Node_Id(u64(b))
}
```
])

A ballot is a triple `(round, priority, node)` packed into one unsigned integer, with
the round in the high 40 bits, the priority in the next 8 and the 16-bit `Node_Id` in
the low bits. Because each field sits above the fields that rank below it, the plain
integer order `<` on two ballots is exactly the lexicographic order on the triples.
A greater `round` always wins. Within a round, a greater `priority` wins; the host
sets it through `Node_Options.priority` to prefer some members as leaders. Within a
round and a priority, the greater `node` id wins, and because node ids are unique
inside a membership, two members never produce the same ballot. `ballot_make` packs
the triple and `ballot_round`, `ballot_priority` and `ballot_node` unpack it;
everything else in the library compares ballots with `<` and `==`. Forty round bits
are enough for `MAX_ROUND` campaigns before `.Ballot_Exhausted`; `BALLOT_ZERO` is
`Ballot(0)`, below every ballot a campaign can produce. Round 0 itself is reserved
for slot owners under rotating ownership, which a later chapter covers.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Left*], [*Right*], [*`left < right`*]),
  [`(4, 0, 2)`], [`(5, 0, 1)`], [`true`: the higher round dominates.],
  [`(7, 2, 9)`], [`(7, 3, 1)`], [`true`: same round, priority decides.],
  [`(9, 0, 1)`], [`(9, 0, 4)`], [`true`: same round and priority, node id decides.],
)

#exercise([2.1], [
  Order the ballots (round 2, priority 0, node 1), (1, 5, 3), (2, 0, 3), (1, 5, 1).
  Which one wins a contest, and why does priority sit between round and node?
])

== Votes and the meaning of "chosen"

An acceptor *votes* by accepting a proposal: it records a ballot and a value for the
slot, in the `vote_ballot` and `value` columns of its `Ledger`, and holds at most one
vote per slot, the latest.

#definition([Chosen], [
  A value $v$ is chosen for a slot when a write quorum of acceptors has each accepted
  $v$ under the same ballot. Being chosen is a fact about the acceptors' durable
  state. It does not require any proposer, learner or client to know that it happened.
])

The moment the last acceptor of a write quorum makes its vote durable, the value is
chosen, even if that acceptor's reply is lost, even if the leader dies in the next
microsecond, even if no learner ever hears. Every later rule exists to make sure a
fact nobody knows about is still respected.

#predict([
  A leader collects acceptances for `olive_oil = 50` from acceptors 1 and 2 out of
  three, then crashes before it sends a single commit. A new leader starts a ballot.
  What value must the new leader end up proposing, and which acceptor will tell it?
])

== Three invariants

Lamport's proof of the Synod protocol rests on three conditions on ballots, each of
which the library keeps in a specific place.

#table(
  columns: (auto, 1fr, 1.1fr),
  table.header([*Rule*], [*Statement*], [*Where the library keeps it*]),
  [B1], [Every ballot is unique.],
    [`start_campaign` builds `ballot_make(greatest + 1, node.priority, node.id)`;
     `membership_init` rejects `.Duplicate_Node_Id` and `.Invalid_Node_Id`.],
  [B2], [Every phase-one quorum intersects every phase-two quorum.],
    [`membership_init` returns `.Non_Intersecting_Quorums` unless
     `read_quorum_size + write_quorum_size > total`.],
  [B3], [If any acceptor in the phase-one quorum has voted, the new ballot proposes
     the value of the greatest-ballot vote reported.],
    [`on_promise` keeps only the greatest vote per slot, and a reported decision
     dominates every vote; `resolve_chunk` passes that value to `send_accept`.],
)

B1 makes "later" well defined. B2 makes sure a later ballot cannot avoid meeting a
witness. B3 tells the later ballot what to do with what the witness says, and it is
the rule people get wrong. It is not "the value with the most votes" and not "the most
recent value you heard". Among the votes reported by your read quorum, find the one
with the greatest ballot and propose its value; if nobody reported a vote, propose
what you like. Older votes may belong to attempts that never reached a quorum, so
counting them counts noise. The proof below shows that the greatest-ballot vote
carries the chosen value whenever a choice was made.

== The greatest-vote proof

Here is the proof that B1, B2 and B3 together keep safety. The single-decree chapter uses it to
explain why each message field exists, and the safety-argument chapter restates it as
formal lemmas, each mapped to the procedure that keeps it.

*Claim.* Suppose value $v$ is chosen at ballot $b$, so a write quorum $W$ of acceptors
each accepted $(b, v)$. Then every ballot $b' > b$ whose leader sends an Accept sends
the value $v$.

*Proof.* By strong induction on $b'$. Fix $b' > b$ and assume the claim for every
ballot strictly between $b$ and $b'$.

The leader of $b'$ finished phase one, so a read quorum $R$ promised $b'$. By B2, $R$
and $W$ share some acceptor $a$. Acceptor $a$ did two things: it accepted $(b, v)$ and
it promised $b'$. Had it promised $b'$ first, then when $(b, v)$ arrived, $b < b'$
would have been below its promise and it would have refused, contradicting $a in W$.
So $a$ accepted $(b, v)$ *before* promising $b'$.

When $a$ answered the prepare for $b'$, its slot therefore held a vote with ballot at
least $b$: either $(b, v)$ itself, or a later vote at some $b''$ with $b < b'' < b'$
that overwrote it. By the induction hypothesis every such $b''$ carried $v$. So the
greatest-ballot vote reported by $R$ has ballot at least $b$ and value $v$, and by B3
the leader of $b'$ proposes $v$. $qed$

Three facts had to hold, and each is a line of code. Acceptors refuse ballots below
their promise: `on_accept` calls `send_nack` when `msg.ballot < l.promised`, where `l`
is the acceptor's `Ledger`. Acceptors report their vote in the promise: `on_prepare`
sends one `Promise_Message` per used cell. And acceptor $a$ still remembered both when
asked, which is where durable storage enters.

#exercise([4.2], [
  Complete the reasoning for ballot succession:
  Suppose value $x$ was chosen at ballot 12 by write quorum $W$. A subsequent leader at ballot 20 collects promises from read quorum $R$.

  1. Because $R$ and $W$ intersect at acceptor $a$, and $a$ could not have promised ballot 20 before accepting ballot 12 (otherwise it would have rejected the proposal at ballot 12), what is the minimum ballot number $a$ will report in its promise?
  2. By the inductive hypothesis, what value must any reported vote with a ballot strictly between 12 and 20 carry?
  3. What value must the greatest-ballot reported vote carry?
  4. Which ballot invariant (B1, B2, or B3) obligates the leader at ballot 20 to propose this value?
], hint: [Review the induction step in the greatest-vote proof above.])

== Why durable storage is mandatory

The proof used the phrase "still remembered". An acceptor that votes, replies, and then
loses the vote to a power failure has told the leader something no longer true. Worse,
an acceptor that promises $b'$, replies, and then forgets may later accept a ballot
below $b'$, which is exactly the refusal the proof relied on.

Lamport's priests wrote in indelible ink. Here, a promise or a vote is a `Write` record
the host must append to a journal and sync before any message from the same transition
leaves the machine. The `Ledger` that holds the durable state refuses to move backwards:

#code_file("src/ledger.odin", [
```odin
ledger_apply :: proc(l: ^Ledger($Value, $WINDOW), write: Write(Value)) -> Error {
	switch w in write {
	case Write_Promise:
		if w.ballot < l.promised do return .Promise_Regression
		l.promised = w.ballot
	// ...
	case Write_Vote(Value):
		if w.slot == 0 do return .Invalid_Slot
		if w.ballot < l.promised do return .Promise_Regression
		// ...
```
])

`.Promise_Regression` is not a protocol message. It is a self-check: a `Write_Promise`
or `Write_Vote` that would lower the promised ballot is refused, because the protocol
never produces one. A host that sees it has a journal written out of order or
corrupted, and the hint in `explain_error` says to stop the node. The other half of
indelible ink lives in `Effects`: every transition returns its writes and messages in
one batch, and with the default `Durability_Gate.Enforced` the batch refuses to hand
out messages until the host calls `confirm_writes_durable`. The single-decree chapter walks through
that gate at every crash point.

#exercise([4.1], [
  A node writes `Write_Promise` for ballot (5, 0, 2) but crashes before the write is
  synced, then restarts and receives Prepare for ballot (4, 0, 3). What may it answer,
  and which rule of the host contract decides?
])

== From rules to messages

We can now derive the messages from their purpose. Read the invariants as
obligations on a proposer and ask what evidence it must request and send.

+ B1 says: pick a ballot greater than any you have seen. That needs no message, only a
  memory of the greatest round observed.
+ B3 needs the votes of a read quorum, and the proof needs those acceptors to refuse
  everything below your ballot from now on. One message asks for both: *Prepare*,
  carrying the ballot. The reply, *Promise*, carries the acceptor's vote for the slot
  if it has one.
+ B2 says: count promises until you have a read quorum, then apply B3 and pick.
+ Send the ballot and the value to the acceptors: *Accept*. An acceptor that has not
  promised anything greater records the vote durably and replies *Accepted*.
+ Count Accepted replies until you have a write quorum. The value is chosen. Tell
  everyone: *Commit*.

#book_figure(
  [The five messages in order. Phase one earns the right to propose and learns the
  past; phase two writes the future.],
  phase_flow(),
)

One more message follows from liveness rather than safety. An acceptor that receives a
Prepare or an Accept below its promise answers *Nack* with the ballot it has
promised. This lets the proposer react promptly instead of waiting for a timeout.
The single-decree chapter shows the exchange.

#checkpoint([Synthesis Check], [
  Before proceeding to the single-decree protocol, verify your understanding of these core questions:
  1. Why does a four-member cluster tolerate no more crash failures than a three-member cluster under majority quorums?
  2. Which ballot invariant (B1, B2, or B3) does the error `.Non_Intersecting_Quorums` enforce?
  3. If a read quorum reports three votes—`((3, 0, 1), apple)`, `((9, 0, 2), apple)`, and `((7, 0, 3), pear)`—which value must the new leader propose, and why?
  4. What safety violation occurs if the acceptor that reported `((9, 0, 2), apple)` held that vote in volatile RAM and rebooted before responding?
])

#teach_back([
  Explain why a simple majority agreement is insufficient to preserve consistency across crashes and leader transitions:
  - How an acceptor crash can erase volatile state unless writes are committed to durable storage.
  - How overlapping read and write quorums guarantee that at least one surviving acceptor witnessed prior votes.
  - Why the new leader must adopt the value with the *highest ballot number* rather than the most frequently reported value.
  - Why `Write_Promise` and `Write_Vote` must be synced to disk before acknowledging transitions.
])
