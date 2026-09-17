"""Turning C records into owned Python objects.

Every ``bytes`` produced here is a copy. The native records point into the node's
ledger and are valid only until its next transition, so a value that did not get
copied would change underneath its holder. Paying that copy at the boundary is
what lets a ``bytes`` returned today stay correct after any number of later
transitions.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, NamedTuple

from paxodin.models import (
    Accept,
    Accepted,
    CellState,
    Commit,
    Committed,
    EntryKind,
    Envelope,
    Heartbeat,
    Learn,
    LogEntry,
    Message,
    MessageKind,
    Nack,
    NodeState,
    Prepare,
    PrepareScope,
    Profile,
    Promise,
    PromiseRange,
    Role,
    ServeRange,
    StopSign,
    WriteKind,
    WriteRecord,
)

if TYPE_CHECKING:
    from paxodin import _native

_NO_ENTRY = LogEntry(EntryKind.NONE)

# Indexing a tuple beats Enum.__call__, which runs a lookup and a type check on
# every decoded record. The enums are contiguous from zero, so the index is the
# value; a stray value would raise IndexError rather than pass silently.
_ENTRY_KINDS = tuple(EntryKind)
_WRITE_KINDS = tuple(WriteKind)
_MESSAGE_KINDS = tuple(MessageKind)
_CELL_STATES = tuple(CellState)
_SCOPES = tuple(PrepareScope)
_ROLES = tuple(Role)


def entry(source: _native.CEntry) -> LogEntry:
    """Decode one log entry, copying its payload.

    Args:
        source: The native record.

    Returns:
        An owned entry. ``kind`` is what distinguishes an empty command from a
        recovery no-op; the payload alone cannot.
    """
    kind = _ENTRY_KINDS[source.kind]
    if kind is EntryKind.NONE:
        return _NO_ENTRY
    if kind is EntryKind.STOP_SIGN:
        stop = source.stop
        return LogEntry(
            kind=kind,
            stop_sign=StopSign(
                configuration_id=stop.configuration_id,
                members=tuple(stop.members[index] for index in range(stop.member_count)),
                metadata=memoryview(stop.metadata)[: stop.metadata_length].tobytes(),
            ),
        )
    # memoryview().tobytes() is one memcpy. Slicing the ctypes array directly
    # builds a Python list of ints first, which dominates the decode cost.
    return LogEntry(kind=kind, body=memoryview(source.body)[: source.length].tobytes())


def write(source: _native.CWrite) -> WriteRecord:
    """Decode one durable record.

    Args:
        source: The native record.

    Returns:
        An owned record the host can journal.
    """
    return WriteRecord(
        kind=_WRITE_KINDS[source.kind],
        ballot=source.ballot,
        slot=source.slot,
        trim_id=source.trim_id,
        trim_slot=source.trim_slot,
        entry=entry(source.entry),
        requires_barrier=bool(source.flags & 1),
    )


def _message(source: _native.CEnvelope) -> Message:  # noqa: PLR0911 -- nine message kinds
    """Build the typed message a native envelope carries."""
    kind = _MESSAGE_KINDS[source.kind]
    match kind:
        case MessageKind.PREPARE:
            return Prepare(
                ballot=source.ballot,
                first=source.first,
                last=source.last,
                scope=_SCOPES[source.scope],
            )
        case MessageKind.PROMISE:
            return Promise(
                ballot=source.ballot,
                slot=source.slot,
                vote=source.vote,
                state=_CELL_STATES[source.cell_state],
                entry=entry(source.entry),
            )
        case MessageKind.PROMISE_RANGE:
            return PromiseRange(
                ballot=source.ballot,
                first=source.first,
                last=source.last,
                reported=source.count,
                more=bool(source.more),
                decided_through=source.decided_through,
                trim_id=source.trim_id,
                trim_slot=source.trim_slot,
            )
        case MessageKind.ACCEPT:
            return Accept(ballot=source.ballot, slot=source.slot, entry=entry(source.entry))
        case MessageKind.ACCEPTED:
            return Accepted(
                ballot=source.ballot, slot=source.slot, decided_through=source.decided_through
            )
        case MessageKind.COMMIT:
            return Commit(slot=source.slot, entry=entry(source.entry))
        case MessageKind.LEARN:
            return Learn(from_slot=source.first, count=source.count)
        case MessageKind.NACK:
            return Nack(
                rejected=source.rejected,
                promised=source.promised,
                slot=source.slot,
                decided_through=source.decided_through,
            )
        case MessageKind.HEARTBEAT:
            return Heartbeat(ballot=source.ballot, decided_through=source.decided_through)
    message = f"native envelope carries unknown message kind {source.kind}"
    raise ValueError(message)


def envelope(source: _native.CEnvelope) -> Envelope:
    """Decode one outbound message.

    Args:
        source: The native record.

    Returns:
        An owned envelope, stamped with its configuration.
    """
    return Envelope(
        configuration_id=source.configuration_id,
        sender=source.sender,
        recipient=source.recipient,
        message=_message(source),
    )


def committed(source: _native.CCommitted) -> Committed:
    """Decode one released entry.

    Args:
        source: The native record.

    Returns:
        An owned entry, contiguous with everything released before it.
    """
    return Committed(slot=source.slot, entry=entry(source.entry))


def request(source: _native.CRequest) -> ServeRange:
    """Decode one host request.

    Args:
        source: The native record.

    Returns:
        The range a peer asked for that has fallen below the memory floor.
    """
    return ServeRange(peer=source.peer, first=source.first, count=source.count)


def state(source: _native.CState) -> NodeState:
    """Decode a node's read-only view.

    Args:
        source: The native record.

    Returns:
        An owned snapshot.
    """
    return NodeState(
        node_id=source.node_id,
        configuration_id=source.configuration_id,
        role=_ROLES[source.role],
        ballot=source.ballot,
        leader=source.leader if source.has_leader else None,
        decided_through=source.decided_through,
        memory_floor=source.memory_floor,
        leader_base=source.leader_base,
        frontier=source.frontier,
        stop_slot=source.stop_slot,
        trim_id=source.trim_id,
        trim_slot=source.trim_slot,
        sealed=bool(source.sealed),
        voting_member=bool(source.voting_member),
        campaign_enabled=bool(source.campaign_enabled),
        leader_caught_up=bool(source.leader_caught_up),
        resubmits_dropped=source.resubmits_dropped,
    )


def profile(source: _native.CProfile) -> Profile:
    """Decode the compiled capacity profile.

    Args:
        source: The native record.

    Returns:
        An owned profile.
    """
    return Profile(
        max_members=source.max_members,
        window_slots=source.window_slots,
        chunk_slots=source.chunk_slots,
        max_value_bytes=source.max_value_bytes,
        max_metadata_bytes=source.max_metadata_bytes,
        gate_enforced=bool(source.gate_enforced),
        node_bytes=source.node_bytes,
        effects_bytes=source.effects_bytes,
        max_writes_per_batch=source.max_writes_per_batch,
        max_messages_per_batch=source.max_messages_per_batch,
        max_committed_per_batch=source.max_committed_per_batch,
        max_requests_per_batch=source.max_requests_per_batch,
        capabilities=source.capabilities,
        fingerprint=source.fingerprint,
    )


class Flat(NamedTuple):
    """A message flattened to the nine-way record both the ABI and the wire use.

    This is the only place the flat form exists. A message is typed everywhere
    a Python developer sees it; the flattening happens at the two boundaries.
    """

    kind: int
    ballot: int = 0
    slot: int = 0
    vote: int = 0
    first: int = 0
    last: int = 0
    rejected: int = 0
    promised: int = 0
    decided_through: int = 0
    trim_id: int = 0
    trim_slot: int = 0
    range_count: int = 0
    scope: int = 0
    cell_state: int = 0
    more: int = 0
    entry: LogEntry = _NO_ENTRY


def flatten(message: Message) -> Flat:  # noqa: PLR0911 -- nine message kinds
    """Flatten a typed message for a boundary.

    Args:
        message: Any of the nine message classes.

    Returns:
        The flat record.
    """
    match message:
        case Prepare(ballot=b, first=f, last=last, scope=scope):
            return Flat(int(MessageKind.PREPARE), ballot=b, first=f, last=last, scope=int(scope))
        case Promise(ballot=b, slot=s, vote=v, state=state, entry=e):
            return Flat(
                int(MessageKind.PROMISE), ballot=b, slot=s, vote=v, cell_state=int(state), entry=e
            )
        case PromiseRange() as m:
            return Flat(
                int(MessageKind.PROMISE_RANGE),
                ballot=m.ballot,
                first=m.first,
                last=m.last,
                range_count=m.reported,
                more=1 if m.more else 0,
                decided_through=m.decided_through,
                trim_id=m.trim_id,
                trim_slot=m.trim_slot,
            )
        case Accept(ballot=b, slot=s, entry=e):
            return Flat(int(MessageKind.ACCEPT), ballot=b, slot=s, entry=e)
        case Accepted(ballot=b, slot=s, decided_through=d):
            return Flat(int(MessageKind.ACCEPTED), ballot=b, slot=s, decided_through=d)
        case Commit(slot=s, entry=e):
            return Flat(int(MessageKind.COMMIT), slot=s, entry=e)
        case Learn(from_slot=f, count=c):
            return Flat(int(MessageKind.LEARN), first=f, range_count=c)
        case Nack(rejected=r, promised=p, slot=s, decided_through=d):
            return Flat(int(MessageKind.NACK), rejected=r, promised=p, slot=s, decided_through=d)
        case Heartbeat(ballot=b, decided_through=d):
            return Flat(int(MessageKind.HEARTBEAT), ballot=b, decided_through=d)
    # No fallback: `Message` is a closed union and the type checker proves the
    # match exhaustive. A fallback would be dead code it could not verify.


def unflatten(flat: Flat) -> Message:  # noqa: PLR0911 -- nine message kinds
    """Rebuild a typed message from a flat record.

    Args:
        flat: The record, as a boundary produced it.

    Returns:
        The typed message.

    Raises:
        ValueError: If the kind is not one of the nine.
    """
    kind = _MESSAGE_KINDS[flat.kind]
    match kind:
        case MessageKind.PREPARE:
            return Prepare(flat.ballot, flat.first, flat.last, _SCOPES[flat.scope])
        case MessageKind.PROMISE:
            return Promise(
                flat.ballot, flat.slot, flat.vote, _CELL_STATES[flat.cell_state], flat.entry
            )
        case MessageKind.PROMISE_RANGE:
            return PromiseRange(
                flat.ballot,
                flat.first,
                flat.last,
                flat.range_count,
                bool(flat.more),
                flat.decided_through,
                flat.trim_id,
                flat.trim_slot,
            )
        case MessageKind.ACCEPT:
            return Accept(flat.ballot, flat.slot, flat.entry)
        case MessageKind.ACCEPTED:
            return Accepted(flat.ballot, flat.slot, flat.decided_through)
        case MessageKind.COMMIT:
            return Commit(flat.slot, flat.entry)
        case MessageKind.LEARN:
            return Learn(flat.first, flat.range_count)
        case MessageKind.NACK:
            return Nack(flat.rejected, flat.promised, flat.slot, flat.decided_through)
        case MessageKind.HEARTBEAT:
            return Heartbeat(flat.ballot, flat.decided_through)
    message_text = f"unknown message kind {flat.kind}"
    raise ValueError(message_text)
