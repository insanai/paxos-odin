"""The interfaces a host supplies.

The library owns the *order* of the durability contract. It never owns the
mechanism. Storage, transport and the clock are all supplied by the caller
through the structural protocols below, which is what keeps this package free of
sockets, TLS policy, retry loops and filesystem assumptions -- exactly as the
Odin core keeps them out of ``src/``.

None of these are base classes. They are :class:`typing.Protocol` definitions, so
any object with the right shape satisfies them without importing anything.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Protocol, runtime_checkable

if TYPE_CHECKING:
    from collections.abc import Sequence

    from paxodin.models import NodeId, Slot, WriteRecord


@runtime_checkable
class Journal(Protocol):
    """Ordered, durable storage for the records a transition produces.

    The contract is the one the core states: persist every record of a
    transition, in order, and make it durable before any message of that
    transition leaves. A journal that reordered or dropped a record could let a
    crash revert a promise a peer has already acted on.
    """

    def open(self, *, node_id: NodeId, configuration_id: int) -> None:
        """Bind the journal to one participant before anything is read or written.

        The session calls this with its own identity, so a caller states it once.
        A durable journal uses it to refuse a file that belongs to another member
        or another configuration: adopting a foreign journal would import its
        promises as this node's own.

        Args:
            node_id: The member this journal belongs to.
            configuration_id: The configuration it belongs to.

        Raises:
            InvalidArgument: If existing storage names a different identity.
            StorageError: If the storage cannot be claimed.
        """
        ...

    def append(self, records: Sequence[WriteRecord]) -> None:
        """Append records in order.

        Args:
            records: The batch, in the order the core produced it.

        Raises:
            StorageError: If the records could not be written.
        """
        ...

    def sync(self) -> None:
        """Make every appended record durable.

        Raises:
            StorageError: If durability could not be established. The caller
                must then treat persistence as uncertain and replay, never
                confirm.
        """
        ...

    def replay(self) -> Sequence[WriteRecord]:
        """Return every durable record, in the order it was appended.

        Returns:
            The records needed to rebuild the node.

        Raises:
            JournalCorrupt: If a complete record fails its checksum. That is
                corruption, not a truncated tail, and must stop recovery.
        """
        ...

    def close(self) -> None:
        """Release the journal's resources."""
        ...


@runtime_checkable
class Transport(Protocol):
    """Moves opaque frames between peers.

    The adapter owns framing, connection management and, critically,
    authentication: a sender id inside a frame is a claim, not proof. It must
    preserve frame boundaries and bound the bytes it queues.

    A failed send may still have reached the peer. That is safe here, because
    protocol retransmission tolerates duplicates -- but it means a send failure
    must never roll back a durable transition.
    """

    def send(self, *, peer: NodeId, frame: bytes) -> None:
        """Deliver one frame to one peer, best effort.

        Args:
            peer: The recipient's identity.
            frame: The encoded envelope.

        Raises:
            TransportError: If the frame could not be queued.
        """
        ...

    def receive(self, *, timeout: float) -> tuple[NodeId, bytes] | None:
        """Wait for one frame.

        Args:
            timeout: Seconds to wait, on a monotonic clock.

        Returns:
            The authenticated sender and the frame, or ``None`` on timeout.
        """
        ...

    def close(self) -> None:
        """Release the transport's resources."""
        ...


@runtime_checkable
class Clock(Protocol):
    """A monotonic time source.

    Monotonic, not wall-clock: a timeout measured against a clock that can step
    backwards is not a timeout. The core itself reads no clock at all; this
    exists only so the session can give its logical ticks a duration.
    """

    def monotonic(self) -> float:
        """Return a monotonically non-decreasing time in seconds."""
        ...

    def sleep(self, seconds: float) -> None:
        """Pause for approximately ``seconds``.

        Args:
            seconds: How long to wait. Never negative.
        """
        ...


@runtime_checkable
class History(Protocol):
    """Durable storage for entries released past the node's memory window.

    Advancing the memory floor transfers responsibility for those entries from
    the bounded node to the host. They must already be here when that happens,
    because the node will not hold them again and a catch-up peer may ask.
    """

    def record(self, slot: Slot, payload: bytes, kind: int) -> None:
        """Durably retain one released entry.

        Args:
            slot: Its position in the log.
            payload: Its bytes.
            kind: Its entry kind, so a no-op stays distinguishable from a
                command that carried no bytes.
        """
        ...

    def read(self, first: Slot, count: int) -> Sequence[tuple[Slot, bytes, int]]:
        """Return retained entries for a catch-up peer.

        Args:
            first: The first slot wanted.
            count: How many to return at most.

        Returns:
            ``(slot, payload, kind)`` triples, in slot order.
        """
        ...

    def cursor(self) -> Slot:
        """Return the contiguous prefix this host has durably retained.

        This is the application cursor, and it is deliberately separate from the
        node's released prefix. It is what a restart resumes from: a node told a
        floor it cannot actually serve would advertise history it has lost.

        Returns:
            The last slot retained with no gap before it, or zero.
        """
        ...

    def close(self) -> None:
        """Release the history's resources."""
        ...
