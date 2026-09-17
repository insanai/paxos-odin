"""Immutable value types returned across the public API.

Every result object is frozen and slotted: a value handed to an application is
owned by that application and never mutates underneath it. This mirrors the
core's own discipline, where a host copies a borrowed effect value out of the
ledger before the node's next transition invalidates the pointer.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import TypedDict

type Slot = int
"""A one-based position in the global decree log. Zero means "no slot"."""

type NodeId = int
"""A stable, non-zero identity for one member. Zero is reserved as a sentinel."""


class EntryKind(IntEnum):
    """What a log entry actually is.

    The distinction is load bearing. An application that treated all three as
    opaque bytes would apply a recovery filler as if it were a command, and
    mistake a reconfiguration for data.
    """

    NONE = 0
    COMMAND = 1
    """An application command. Its payload may legitimately be empty."""
    NOOP = 2
    """A filler a leader chose into a hole during recovery. Never a command."""
    STOP_SIGN = 3
    """A sealing reconfiguration record, not application data."""


class WriteKind(IntEnum):
    """Which durable record the host must journal."""

    NONE = 0
    PROMISE = 1
    PROMISE_AT = 2
    VOTE = 3
    CHOSEN = 4
    TRIM = 5


class MessageKind(IntEnum):
    """Which protocol message an envelope carries."""

    NONE = 0
    PREPARE = 1
    PROMISE = 2
    PROMISE_RANGE = 3
    ACCEPT = 4
    ACCEPTED = 5
    COMMIT = 6
    LEARN = 7
    NACK = 8
    HEARTBEAT = 9


class Role(IntEnum):
    """Proposer status. A follower still acts as acceptor and learner."""

    FOLLOWER = 0
    PREPARING = 1
    LEADER = 2


class CellState(IntEnum):
    """What an acceptor holds for one decree."""

    EMPTY = 0
    VOTED = 1
    CHOSEN = 2


class BatchPhase(IntEnum):
    """Where a pending batch has got to.

    A batch with no writes is born ``CONFIRMED``: there is nothing to persist, so
    requiring a confirmation would assert a durability fact about no records.
    """

    IDLE = 0
    PENDING = 1
    CONFIRMED = 2
    FINISHED = 3


class NodeOptions(TypedDict, total=False):
    """Tuning for one participant, at the level of the effect machine.

    Timers here are counted in logical ticks, because that is how the engine
    counts them and ``Node`` does not own a clock. :class:`paxodin.Session`
    takes seconds instead and converts. Zero selects the default for everything.
    """

    priority: int
    read_quorum: int
    write_quorum: int
    election_timeout_ticks: int
    heartbeat_interval_ticks: int
    resend_interval_ticks: int
    campaign_disabled: bool
    gate_proposals_on_inherited_prefix: bool


class SessionOptions(TypedDict, total=False):
    """Tuning for a session, in seconds.

    These are the same knobs as :class:`NodeOptions` with the engine's tick unit
    converted away: a developer reasons about how long failover takes, not how
    many ticks it is.
    """

    priority: int
    read_quorum: int
    write_quorum: int
    election_timeout: float
    heartbeat_interval: float
    resend_interval: float
    campaign_disabled: bool
    gate_proposals_on_inherited_prefix: bool


@dataclass(frozen=True, slots=True)
class Profile:
    """The capacities the loaded native library was compiled with.

    The Odin core is fully parametric, but a shared library fixes its capacities
    at compile time because values are stored inline in the ledger. A profile
    therefore describes this build, not a limit of the algorithm.

    Attributes:
        max_members: Largest voting membership this build accepts.
        window_slots: Size of the sliding decree window. Always a power of two.
        chunk_slots: Recovery chunk size, and the largest proposal batch.
        max_value_bytes: Largest command payload this build accepts.
        max_metadata_bytes: Largest reconfiguration metadata blob.
        gate_enforced: True for the test-only library that compiles the core's
            own durability gate in, where a violation ends the process.
        node_bytes: Measured static footprint of one node.
        effects_bytes: Measured static footprint of one effects batch.
        max_writes_per_batch: Most durable records one transition can produce.
        max_messages_per_batch: Most envelopes one transition can produce.
        max_committed_per_batch: Most entries one transition can release.
        max_requests_per_batch: Most host requests one transition can produce.
        capabilities: Bitmask of optional features this build supports.
        fingerprint: Identifies this profile in journal headers and handshakes,
            so a mismatch is caught before a node reads foreign state.
    """

    max_members: int
    window_slots: int
    chunk_slots: int
    max_value_bytes: int
    max_metadata_bytes: int
    gate_enforced: bool
    node_bytes: int
    effects_bytes: int
    max_writes_per_batch: int
    max_messages_per_batch: int
    max_committed_per_batch: int
    max_requests_per_batch: int
    capabilities: int
    fingerprint: int


@dataclass(frozen=True, slots=True)
class StopSign:
    """A sealing record that ends one configuration and names the next."""

    configuration_id: int
    members: tuple[NodeId, ...]
    metadata: bytes


@dataclass(frozen=True, slots=True)
class LogEntry:
    """One decoded log entry.

    Attributes:
        kind: Which of the three things this entry is.
        body: The command payload. Empty for a no-op or a stop sign, and also
            legitimately empty for a command that carried no bytes -- read
            ``kind`` to tell them apart.
        stop_sign: The sealing record when ``kind`` is ``STOP_SIGN``.
    """

    kind: EntryKind
    body: bytes = b""
    stop_sign: StopSign | None = None

    @property
    def is_command(self) -> bool:
        """True when this entry is application data the caller submitted."""
        return self.kind is EntryKind.COMMAND


@dataclass(frozen=True, slots=True)
class Committed:
    """One entry released to the application, contiguous with everything before.

    Release is not application: receiving this means the participant knows the
    decision in order, not that the application has acted on it.
    """

    slot: Slot
    entry: LogEntry


@dataclass(frozen=True, slots=True)
class WriteRecord:
    """One durable record the host must append, in order, before sending.

    Attributes:
        requires_barrier: True for a promise or a vote -- the indelible ink whose
            loss lets a crash choose twice. A decision or trim record is derived
            state a host may persist behind a cheaper barrier.
    """

    kind: WriteKind
    ballot: int
    slot: Slot
    trim_id: int
    trim_slot: Slot
    entry: LogEntry
    requires_barrier: bool


class PrepareScope(IntEnum):
    """What a prepare asks an acceptor to promise."""

    GLOBAL = 0
    """Every decree from ``first`` on: the Multi-Paxos takeover."""
    BOUNDED = 1
    """Only the decrees in ``[first, last]``: a revocation under ownership."""


@dataclass(frozen=True, slots=True)
class Prepare:
    """Phase one: promise ``ballot`` for the decrees in scope and report votes."""

    ballot: int
    first: Slot
    last: Slot
    scope: PrepareScope = PrepareScope.GLOBAL


@dataclass(frozen=True, slots=True)
class Promise:
    """One reported vote or decision for one decree, in answer to a prepare."""

    ballot: int
    slot: Slot
    vote: int
    state: CellState
    entry: LogEntry


@dataclass(frozen=True, slots=True)
class PromiseRange:
    """The manifest that closes a phase-one answer for one chunk."""

    ballot: int
    first: Slot
    last: Slot
    reported: int
    more: bool
    decided_through: Slot
    trim_id: int
    trim_slot: Slot


@dataclass(frozen=True, slots=True)
class Accept:
    """Phase two: vote for ``entry`` in ``slot`` under ``ballot``."""

    ballot: int
    slot: Slot
    entry: LogEntry


@dataclass(frozen=True, slots=True)
class Accepted:
    """An acceptor's vote, with how far it has decided."""

    ballot: int
    slot: Slot
    decided_through: Slot


@dataclass(frozen=True, slots=True)
class Commit:
    """A decision. It carries no ballot because a chosen value is final."""

    slot: Slot
    entry: LogEntry


@dataclass(frozen=True, slots=True)
class Learn:
    """A catch-up request for decided slots starting at ``from_slot``."""

    from_slot: Slot
    count: int


@dataclass(frozen=True, slots=True)
class Nack:
    """A refusal: ``rejected`` lost to ``promised``."""

    rejected: int
    promised: int
    slot: Slot
    decided_through: Slot


@dataclass(frozen=True, slots=True)
class Heartbeat:
    """A leader's liveness signal, with how far it has decided."""

    ballot: int
    decided_through: Slot


type Message = (
    Prepare | Promise | PromiseRange | Accept | Accepted | Commit | Learn | Nack | Heartbeat
)
"""One of the nine protocol messages. Match on the class, not on a tag.

Example:
    >>> from paxodin import Accept, Commit
    >>> def describe(message: Message) -> str:
    ...     match message:
    ...         case Accept(slot=slot):
    ...             return f"vote requested for slot {slot}"
    ...         case Commit(slot=slot):
    ...             return f"slot {slot} decided"
    ...         case _:
    ...             return type(message).__name__
"""


@dataclass(frozen=True, slots=True)
class Envelope:
    """One protocol message with its addressing and configuration stamp.

    The stamp is what lets a receiver refuse traffic from another epoch instead
    of relabelling it. Everything else about the message lives in ``message``,
    which is one of the nine classes above.
    """

    configuration_id: int
    sender: NodeId
    recipient: NodeId
    message: Message


@dataclass(frozen=True, slots=True)
class ServeRange:
    """History a peer asked for that has fallen below this node's memory floor.

    The core no longer holds it; the host serves it from retained history.
    """

    peer: NodeId
    first: Slot
    count: int


@dataclass(frozen=True, slots=True)
class NodeState:
    """A read-only view of one participant, gathered in a single call."""

    node_id: NodeId
    configuration_id: int
    role: Role
    ballot: int
    leader: NodeId | None
    decided_through: Slot
    memory_floor: Slot
    leader_base: Slot
    frontier: Slot
    stop_slot: Slot
    trim_id: int
    trim_slot: Slot
    sealed: bool
    voting_member: bool
    campaign_enabled: bool
    leader_caught_up: bool
    resubmits_dropped: int

    @property
    def is_leader(self) -> bool:
        """True when this participant is running phase two for its own slots."""
        return self.role is Role.LEADER


@dataclass(frozen=True, slots=True)
class Receipt:
    """Where a submitted command ended up.

    Attributes:
        configuration_id: The configuration that holds the slot.
        slot: The position the command occupies.
        entry: What was actually decided there.

    Note:
        A receipt reports agreement and release at *this* participant. It does
        not say every peer received the command, and it never says the
        application applied it.
    """

    configuration_id: int
    slot: Slot
    entry: LogEntry

    @property
    def value(self) -> bytes:
        """The decided payload."""
        return self.entry.body
