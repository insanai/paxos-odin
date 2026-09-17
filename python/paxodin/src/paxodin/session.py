"""The durable participant: one order, no mechanism.

:class:`Session` runs the sequence the core's contract requires -- persist the
writes, confirm them, release the decisions, send the messages, serve the
catch-up requests, finish the batch -- and nothing else. Every byte it moves
goes through an adapter the caller supplied, so this module contains no socket,
no filesystem assumption beyond the journal protocol, and no retry policy.

It reads a clock for exactly one reason: the core counts its election and
heartbeat timeouts in logical ticks and deliberately leaves their duration to the
host. ``tick_interval`` is where that decision is made, once, visibly.
"""

from __future__ import annotations

import contextlib
import time
from typing import TYPE_CHECKING, Final, Self, Unpack

from paxodin import codec
from paxodin.errors import (
    CommitTimeout,
    InvalidTimeout,
    NotLeader,
    ProposalLost,
    TransportError,
    Trimmed,
    raise_for,
)
from paxodin.models import (
    Commit,
    Committed,
    EntryKind,
    Envelope,
    LogEntry,
    NodeOptions,
    Receipt,
    SessionOptions,
)
from paxodin.node import Node
from paxodin.storage import MemoryHistory

if TYPE_CHECKING:
    from collections.abc import Iterator, Sequence

    from paxodin.models import NodeId, NodeState, Slot
    from paxodin.node import PendingBatch as _PendingBatch
    from paxodin.protocols import Clock, History, Journal, Transport

#: The engine counts timeouts in logical ticks; this is how long one tick lasts
#: inside a session. Callers give seconds and never see ticks.
DEFAULT_TICK_INTERVAL: Final = 0.05

DEFAULT_ELECTION_TIMEOUT: Final = 0.5
DEFAULT_HEARTBEAT_INTERVAL: Final = 0.15
DEFAULT_RESEND_INTERVAL: Final = 0.5


def _to_ticks(seconds: float | None, tick_interval: float) -> int:
    """Convert a duration to whole ticks, never fewer than one."""
    if seconds is None:
        return 0  # the engine's default
    return max(1, round(seconds / tick_interval))


def _node_options(tick_interval: float, options: SessionOptions) -> NodeOptions:
    """Translate second-based session tuning into the engine's tick-based form."""
    translated: NodeOptions = {}
    if "priority" in options:
        translated["priority"] = options["priority"]
    if "read_quorum" in options:
        translated["read_quorum"] = options["read_quorum"]
    if "write_quorum" in options:
        translated["write_quorum"] = options["write_quorum"]
    if "campaign_disabled" in options:
        translated["campaign_disabled"] = options["campaign_disabled"]
    if "gate_proposals_on_inherited_prefix" in options:
        translated["gate_proposals_on_inherited_prefix"] = options[
            "gate_proposals_on_inherited_prefix"
        ]
    if "election_timeout" in options:
        translated["election_timeout_ticks"] = _to_ticks(
            options["election_timeout"], tick_interval
        )
    if "heartbeat_interval" in options:
        translated["heartbeat_interval_ticks"] = _to_ticks(
            options["heartbeat_interval"], tick_interval
        )
    if "resend_interval" in options:
        translated["resend_interval_ticks"] = _to_ticks(options["resend_interval"], tick_interval)
    return translated


class _SystemClock:
    """The default clock: monotonic, so a timeout cannot be undone by NTP."""

    __slots__ = ()

    def monotonic(self) -> float:
        """Return a monotonically non-decreasing time in seconds."""
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        """Pause for approximately ``seconds``.

        Args:
            seconds: How long to wait.
        """
        time.sleep(seconds)


def _check_timeout(timeout: float) -> None:
    """Reject a timeout that cannot mean anything, before entering native code."""
    if timeout != timeout or timeout in (float("inf"), float("-inf")):  # noqa: PLR0124
        raise InvalidTimeout(timeout)
    if timeout < 0:
        raise InvalidTimeout(timeout)


class Session:
    """One participant, driven through a caller-supplied journal and transport.

    A session represents *this* member. The other members must also be running;
    nothing here starts them, forwards to them, or discovers them.

    Example:
        >>> from paxodin import Session
        >>> from paxodin.storage import FileJournal
        >>> with Session(  # doctest: +SKIP
        ...     node_id=1,
        ...     members=[1, 2, 3],
        ...     configuration_id=1,
        ...     journal=FileJournal("state/node-1", node_id=1, configuration_id=1),
        ...     transport=transport,
        ... ) as session:
        ...     receipt = session.append(b"set counter 41", timeout=5.0)
        ...     print(receipt.slot)

    Note:
        There is no background thread. Between appends, call :meth:`poll` to
        drive incoming traffic, ticks and retransmission.
    """

    __slots__ = (
        "_applied_through",
        "_clock",
        "_history",
        "_journal",
        "_last_tick",
        "_node",
        "_tick_interval",
        "_transport",
    )

    def __init__(
        self,
        *,
        node_id: NodeId,
        members: Sequence[NodeId],
        configuration_id: int,
        journal: Journal,
        transport: Transport,
        history: History | None = None,
        clock: Clock | None = None,
        tick_interval: float = DEFAULT_TICK_INTERVAL,
        **options: Unpack[SessionOptions],
    ) -> None:
        """Open or restore a participant.

        If the journal already holds records, the node is rebuilt from them
        rather than started fresh, so a restart resumes the promises and votes
        this member already made.

        Args:
            node_id: This member's stable, non-zero identity.
            members: Every voting member of the configuration.
            configuration_id: The non-zero identity of this configuration.
            journal: Where durable records go. Its contract is the durability
                rule: appended in order, synced before any message leaves.
            transport: How frames reach peers. It owns authentication; a sender
                id inside a frame is a claim, not proof.
            history: Where released entries are retained once the memory floor
                passes them. Defaults to a non-durable in-memory store.
            clock: The monotonic time source. Defaults to the system clock.
            tick_interval: How often the engine is ticked while idle. Its
                timeouts are counted in ticks, so this is the resolution of
                ``election_timeout`` and the others; it is not something to tune.
            **options: Tuning in seconds -- ``election_timeout`` (default 0.5),
                ``heartbeat_interval`` (0.15), ``resend_interval`` (0.5) -- plus
                ``priority``, quorum overrides and the campaign switches.

        Raises:
            ValueError: If ``tick_interval`` is not positive and finite.
        """
        _check_timeout(tick_interval)
        if tick_interval <= 0:
            raise InvalidTimeout(tick_interval)
        self._journal = journal
        self._transport = transport
        self._history: History = history if history is not None else MemoryHistory()
        self._clock: Clock = clock if clock is not None else _SystemClock()
        self._tick_interval = tick_interval
        self._applied_through: Slot = 0
        self._last_tick = self._clock.monotonic()

        # The identity is stated once, here; storage learns it rather than the
        # caller repeating it.
        tuning = _node_options(tick_interval, options)
        journal.open(node_id=node_id, configuration_id=configuration_id)
        existing = list(journal.replay())
        if existing:
            # The floor is what this host can still serve, which is what its
            # history holds -- not what the ledger happens to remember. A node
            # told a higher floor would advertise entries it has lost.
            self._applied_through = self._history.cursor()
            self._node = Node.restore(
                node_id=node_id,
                members=members,
                configuration_id=configuration_id,
                records=existing,
                floor=self._applied_through,
                **tuning,
            )
        else:
            self._node = Node(
                node_id=node_id,
                members=members,
                configuration_id=configuration_id,
                **tuning,
            )

    @property
    def node(self) -> Node:
        """The underlying participant, for hosts that need direct control."""
        return self._node

    def state(self) -> NodeState:
        """Return a snapshot of this participant.

        Returns:
            Its role, ballot, released prefix and seal state.

        Note:
            This is what *this* member knows. The core has no lease, so it is
            never a statement about the cluster right now.
        """
        return self._node.state()

    def discharge(self, batch: _PendingBatch) -> None:
        """Run the durability order for one batch through this session's adapters.

        Persist, confirm, release, send, serve, finish. The order is the whole
        point: a message that left before its record was durable can be reverted
        by a crash, and two different values can then be chosen for one slot.

        This is public so a host that drives :attr:`node` directly -- to batch
        proposals, or to sequence its own transitions -- can still hand each
        batch to the session for the part it must not get wrong.

        Args:
            batch: A pending batch produced by :attr:`node`.

        Raises:
            StorageError: If the journal could not persist the records. The batch
                is left unconfirmed and the node blocked; reopen and replay.
        """
        try:
            records = batch.writes()
            if records:
                self._journal.append(records)
                self._journal.sync()
            batch.persisted()

            for entry in batch.committed():
                self._release(entry)

            for envelope in batch.messages():
                self._send(envelope)

            for request in batch.requests():
                self._serve(request.peer, request.first, request.count)
        finally:
            # Finishing is what lets the next transition run. Leaving a batch
            # pending would block the node behind an error it could recover from.
            batch.finish()

        if self._applied_through:
            self._node.advance_memory_floor(self._applied_through)

    def _release(self, entry: Committed) -> None:
        """Retain a released entry, then record it as durably consumed.

        History is written *before* the memory floor moves past the entry,
        because advancing the floor is what transfers responsibility for it from
        the bounded node to this host. Doing it the other way round loses the
        entry with nothing holding it.
        """
        self._history.record(entry.slot, entry.entry.body, int(entry.entry.kind))
        self._applied_through = entry.slot

    def _send(self, envelope: object) -> None:
        """Encode and hand one envelope to the transport.

        A send failure never rolls back a durable transition: the peer may have
        received it, and protocol retransmission tolerates duplicates either way.
        """
        frame = codec.encode(envelope)  # type: ignore[arg-type]
        with contextlib.suppress(TransportError):
            self._transport.send(peer=envelope.recipient, frame=frame)  # type: ignore[attr-defined]

    def _serve(self, peer: NodeId, first: Slot, count: int) -> None:
        """Answer a catch-up request from retained history."""
        state = self._node.state()
        for slot, payload, kind in self._history.read(first, count):
            self._send(
                Envelope(
                    configuration_id=state.configuration_id,
                    sender=state.node_id,
                    recipient=peer,
                    message=Commit(slot=slot, entry=LogEntry(kind=EntryKind(kind), body=payload)),
                )
            )

    def poll(self, *, timeout: float = 0.0) -> int:
        """Drive incoming traffic, ticks and retransmission.

        There is no background worker, so a participant only makes progress
        while someone calls this or :meth:`append`.

        Args:
            timeout: Seconds to wait for traffic, on the monotonic clock. Zero
                processes everything already queued and returns without waiting.

        Returns:
            How many frames were processed.

        Raises:
            ValueError: If ``timeout`` is negative or not finite.
        """
        _check_timeout(timeout)
        deadline = self._clock.monotonic() + timeout
        processed = 0
        while True:
            self._maybe_tick()
            remaining = deadline - self._clock.monotonic()
            received = self._transport.receive(timeout=max(remaining, 0.0))
            if received is None:
                if remaining <= 0:
                    return processed
                # Yield rather than spin. A transport that returns immediately
                # would otherwise burn a core for the whole timeout, and a
                # logical clock would never advance at all.
                self._clock.sleep(min(self._tick_interval, remaining))
                continue
            _peer, frame = received
            envelope = codec.decode(frame)
            with self._node.step(envelope) as batch:
                self.discharge(batch)
            processed += 1
            # A zero timeout means "everything already here, without waiting":
            # only a real deadline cuts a drain short.
            if timeout > 0 and self._clock.monotonic() >= deadline:
                return processed

    def _maybe_tick(self) -> None:
        """Issue at most one tick per elapsed interval."""
        now = self._clock.monotonic()
        if now - self._last_tick < self._tick_interval:
            return
        self._last_tick = now
        with self._node.tick() as batch:
            self.discharge(batch)

    def campaign(self) -> None:
        """Stand for leadership immediately, without waiting for a timeout."""
        with self._node.campaign() as batch:
            self.discharge(batch)

    def append(self, value: bytes, *, timeout: float = 5.0) -> Receipt:
        """Submit a command and drive progress until it is durably released.

        Args:
            value: The command bytes, at most ``profile.max_value_bytes``. An
                empty command is legal and stays distinct from a no-op.
            timeout: Seconds to wait, on a monotonic clock.

        Returns:
            A receipt naming the configuration and slot that hold the command.

        Raises:
            NotLeader: This participant is a follower. No forwarding is
                performed; route the request to the leader yourself.
            ValueTooLarge: The command exceeds the profile. Nothing was admitted.
            ProposalLost: A different value was decided in the slot this command
                was admitted to. In single-leader mode there is no resubmission,
                so a leader that loses its ballot mid-flight drops the command.
            CommitTimeout: The wait ended. This did **not** cancel anything: the
                value may still be chosen. Keep polling and inspect local
                history; retry only behind an application-level command id.
            ValueError: If ``timeout`` is negative or not finite.

        Note:
            Success means agreement and release at *this* participant. It does
            not mean every peer received the command, and it never means the
            application applied it. Exactly-once application is an application
            protocol, not something a receipt can establish.
        """
        _check_timeout(timeout)
        deadline = self._clock.monotonic() + timeout

        # Consume whatever peers have already sent -- a campaign's promises, most
        # often -- so a member that has in fact won leadership is not refused for
        # want of reading its own mail. This is local progress, not forwarding.
        self.poll(timeout=0.0)

        with self._node.propose(value) as batch:
            status = batch.status
            slot = batch.assigned_slot
            self.discharge(batch)
        if status == NotLeader.code:
            state = self._node.state()
            raise NotLeader(leader=state.leader, node_id=state.node_id)
        raise_for(status, value_bytes=len(value))

        while self._node.state().decided_through < slot:
            if self._clock.monotonic() >= deadline:
                raise CommitTimeout(admitted=True, slot=slot, seconds=timeout)
            self.poll(timeout=min(self._tick_interval, max(deadline - self._clock.monotonic(), 0)))

        entry = self._entry_at(slot)
        state = self._node.state()
        if entry is None:
            raise CommitTimeout(admitted=True, slot=slot)
        # A leader that lost its ballot mid-flight is not resubmitted in
        # single-leader mode: recovery can choose another value for this slot.
        # Reporting success here would be a lie.
        if entry.kind is not EntryKind.COMMAND or entry.body != value:
            raise ProposalLost(slot=slot, submitted_bytes=len(value), decided_kind=entry.kind.name)
        return Receipt(configuration_id=state.configuration_id, slot=slot, entry=entry)

    def _entry_at(self, slot: Slot) -> LogEntry | None:
        """Return the entry decided at ``slot``, from history or the window.

        Retained history is consulted first because it is the durable record.
        Advancing the memory floor is precisely what hands an entry over to this
        host, so by the time a caller asks, the node has usually let it go.

        Args:
            slot: The position to read.

        Returns:
            The entry, or ``None`` if neither source holds it.
        """
        retained = self._history.read(slot, 1)
        for found_slot, payload, kind in retained:
            if found_slot == slot:
                return LogEntry(kind=EntryKind(kind), body=payload)
        try:
            decided = self._node.read_decided(slot, 1)
        except Trimmed:
            return None
        return decided[0].entry if decided else None

    @property
    def node_id(self) -> NodeId:
        """This participant's identity."""
        return self._node.state().node_id

    @property
    def is_leader(self) -> bool:
        """Whether this participant currently believes it leads.

        A belief, not a lease: the engine has no lease, so this can be stale the
        moment it is read. It says who will *try* to sequence a command.
        """
        return self._node.state().is_leader

    @property
    def leader(self) -> NodeId | None:
        """The member this participant thinks leads, if it has heard from one."""
        return self._node.state().leader

    @property
    def last_committed(self) -> Slot:
        """The last slot this participant has released, in order. Zero if none."""
        return self._node.state().decided_through

    def entries(self, start: Slot = 1, *, limit: int | None = None) -> Iterator[Committed]:
        """Iterate this participant's released entries from ``start``, in order.

        This reports what *this* member knows; it is not a freshness guarantee
        and may lag the cluster arbitrarily.

        Args:
            start: The first slot to yield.
            limit: Stop after this many, or run to the end of the released prefix.

        Yields:
            Entries in slot order, each an owned object.

        Example:
            >>> from paxodin.testing import Cluster
            >>> with Cluster(3) as cluster:
            ...     _ = cluster.append(b"a")
            ...     _ = cluster.append(b"b")
            ...     [e.entry.body for e in cluster.session(1).entries()] == [b"a", b"b"]
            True
        """
        start = max(start, 1)
        released = self.last_committed
        stop = released if limit is None else min(released, start + limit - 1)
        for position in range(start, stop + 1):
            entry = self._entry_at(position)
            if entry is None:
                return
            yield Committed(slot=position, entry=entry)

    def __getitem__(self, slot: Slot) -> Committed:
        """Return the entry released at ``slot``.

        Args:
            slot: A one-based position.

        Returns:
            The entry.

        Raises:
            KeyError: If this participant has not released that slot.
        """
        entry = self._entry_at(slot) if slot >= 1 else None
        if entry is None:
            raise KeyError(slot)
        return Committed(slot=slot, entry=entry)

    def committed_since(self, slot: Slot, *, limit: int = 128) -> list[Committed]:
        """Read up to ``limit`` released entries from ``slot``. See :meth:`entries`.

        Args:
            slot: The first slot wanted.
            limit: The most entries to return.

        Returns:
            The entries, in slot order.
        """
        return list(self.entries(slot, limit=limit))

    def close(self) -> None:
        """Close the node, the journal, the transport and the history.

        Closing stops local work. It does not withdraw a proposal that peers may
        still choose.
        """
        try:
            self._node.close()
        finally:
            try:
                self._journal.close()
            finally:
                try:
                    self._transport.close()
                finally:
                    self._history.close()

    def __enter__(self) -> Self:
        """Return this session for use in a ``with`` block."""
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Close the session on the way out."""
        self.close()
