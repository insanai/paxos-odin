"""An in-process cluster for examples, documentation and tests.

This is the Python analogue of the review cluster in the Odin test harness: real
participants, real transitions, real durability ordering -- over adapters that
keep nothing.

Warning:
    Memory-backed and therefore **not durable**. A cluster built here cannot be
    restarted, and it proves nothing about crash recovery. Use
    :class:`~paxodin.storage.FileJournal` and a real transport for that.
"""

from __future__ import annotations

import asyncio
from collections import deque
from typing import TYPE_CHECKING, Self, Unpack

from paxodin.aio import AsyncSession
from paxodin.models import Role, SessionOptions
from paxodin.session import Session
from paxodin.storage import MemoryHistory, MemoryJournal

if TYPE_CHECKING:
    from collections.abc import Sequence

    from paxodin.models import Committed, NodeId, Receipt, Slot


class LoopbackTransport:
    """Delivers frames between participants in one process.

    It preserves frame boundaries and bounds what it queues, like any transport
    must. It performs no authentication because there is nothing to
    authenticate: every peer is this process.
    """

    __slots__ = ("_fabric", "_node_id")

    def __init__(self, fabric: _Fabric, node_id: NodeId) -> None:
        """Bind a transport to one participant.

        Args:
            fabric: The shared set of mailboxes.
            node_id: The participant this transport belongs to.
        """
        self._fabric = fabric
        self._node_id = node_id

    def send(self, *, peer: NodeId, frame: bytes) -> None:
        """Queue one frame for a peer.

        Args:
            peer: The recipient.
            frame: The encoded envelope.
        """
        self._fabric.deliver(peer, self._node_id, frame)

    def receive(self, *, timeout: float) -> tuple[NodeId, bytes] | None:
        """Take one queued frame, if any.

        Args:
            timeout: Ignored; an in-process mailbox never waits.

        Returns:
            The sender and frame, or ``None`` when the mailbox is empty.
        """
        del timeout
        return self._fabric.take(self._node_id)

    def close(self) -> None:
        """Drop anything still queued for this participant."""
        self._fabric.clear(self._node_id)


class _Fabric:
    """The shared mailboxes behind every :class:`LoopbackTransport`."""

    __slots__ = ("_boxes", "delivered", "dropped")

    def __init__(self, members: Sequence[NodeId], depth: int) -> None:
        self._boxes: dict[NodeId, deque[tuple[NodeId, bytes]]] = {
            member: deque(maxlen=depth) for member in members
        }
        self.delivered = 0
        self.dropped = 0

    def deliver(self, peer: NodeId, sender: NodeId, frame: bytes) -> None:
        box = self._boxes.get(peer)
        if box is None:
            return
        if box.maxlen is not None and len(box) == box.maxlen:
            # A bounded queue drops rather than grows. Protocol retransmission
            # recovers from this, which is exactly why it is safe to drop.
            self.dropped += 1
        box.append((sender, frame))
        self.delivered += 1

    def take(self, node_id: NodeId) -> tuple[NodeId, bytes] | None:
        box = self._boxes.get(node_id)
        if not box:
            return None
        return box.popleft()

    def pending(self) -> int:
        return sum(len(box) for box in self._boxes.values())

    def clear(self, node_id: NodeId) -> None:
        box = self._boxes.get(node_id)
        if box is not None:
            box.clear()


class _ClusterClock:
    """A clock whose sleep advances the rest of the cluster.

    In one process nothing else runs while a participant waits, so waiting is
    precisely when its peers should be given a turn. Ticks advance logically
    rather than by wall time, which keeps the tests fast and deterministic.
    """

    __slots__ = ("_cluster", "_now")

    def __init__(self, cluster: Cluster) -> None:
        self._cluster = cluster
        self._now = 0.0

    def monotonic(self) -> float:
        """Return the logical time, in seconds."""
        return self._now

    def sleep(self, seconds: float) -> None:
        """Advance logical time and give every other participant a turn.

        Args:
            seconds: How far to advance.
        """
        self._now += max(seconds, 1e-6)
        self._cluster.pump()


class Cluster:
    """Several participants running in one process over memory storage.

    Example:
        >>> with Cluster(3) as cluster:
        ...     receipt = cluster.append(b"set counter 41")
        ...     receipt.slot
        1
        >>> with Cluster(3) as cluster:
        ...     first = cluster.append(b"one")
        ...     second = cluster.append(b"two")
        ...     [first.slot, second.slot]
        [1, 2]
    """

    __slots__ = ("_clock", "_fabric", "_members", "_pumping", "_sessions")

    def __init__(
        self,
        size: int = 3,
        *,
        configuration_id: int = 1,
        queue_depth: int = 4096,
        **options: Unpack[SessionOptions],
    ) -> None:
        """Start ``size`` participants wired to each other.

        Args:
            size: How many voting members to run.
            configuration_id: The configuration identity they share.
            queue_depth: Frames one mailbox holds before dropping.
            **options: Tuning passed to every participant.

        Raises:
            ValueError: If ``size`` is not at least one.
        """
        if size < 1:
            message = f"a cluster needs at least one member, got {size}"
            raise ValueError(message)
        self._members: list[NodeId] = list(range(1, size + 1))
        self._fabric = _Fabric(self._members, queue_depth)
        self._clock = _ClusterClock(self)
        self._pumping = False
        self._sessions: dict[NodeId, Session] = {
            member: Session(
                node_id=member,
                members=self._members,
                configuration_id=configuration_id,
                journal=MemoryJournal(),
                transport=LoopbackTransport(self._fabric, member),
                history=MemoryHistory(),
                clock=self._clock,
                tick_interval=0.01,
                **options,
            )
            for member in self._members
        }

    @property
    def members(self) -> list[NodeId]:
        """The voting membership."""
        return list(self._members)

    def session(self, node_id: NodeId) -> Session:
        """Return one participant.

        Args:
            node_id: Which member.

        Returns:
            That member's session.
        """
        return self._sessions[node_id]

    def pump(self, rounds: int = 64) -> int:
        """Give every participant a turn to drain its mailbox.

        Args:
            rounds: How many passes to make at most.

        Returns:
            How many frames were processed.
        """
        if self._pumping:
            # An adapter must never recursively drive the cluster that is
            # driving it; one level is enough and re-entering would nest
            # transitions inside a pending batch.
            return 0
        self._pumping = True
        processed = 0
        try:
            for _ in range(rounds):
                if self._fabric.pending() == 0:
                    break
                for session in self._sessions.values():
                    processed += session.poll(timeout=0.0)
        finally:
            self._pumping = False
        return processed

    def leader(self) -> Session | None:
        """Return the participant that currently believes it leads.

        Returns:
            The leader's session, or ``None`` if there is not one yet.
        """
        for session in self._sessions.values():
            if session.state().role is Role.LEADER:
                return session
        return None

    def elect(self, node_id: NodeId | None = None, rounds: int = 64) -> Session:
        """Ensure a leader exists, campaigning if necessary.

        Args:
            node_id: Which member should stand. Defaults to the first.
            rounds: How many pump passes to allow.

        Returns:
            The leading session.

        Raises:
            RuntimeError: If no leader emerged, which in one process means a
                configuration that cannot form a quorum.
        """
        existing = self.leader()
        if existing is not None:
            return existing
        candidate = self._sessions[node_id or self._members[0]]
        candidate.campaign()
        self.pump(rounds)
        leader = self.leader()
        if leader is None:
            message = "no leader emerged; check the membership and quorum sizes"
            raise RuntimeError(message)
        return leader

    def append(self, value: bytes, *, timeout: float = 5.0) -> Receipt:
        """Submit a command through whichever participant leads.

        Args:
            value: The command bytes.
            timeout: Seconds to wait, on the cluster's logical clock.

        Returns:
            The receipt for the decided slot.
        """
        leader = self.elect()
        receipt = leader.append(value, timeout=timeout)
        self.pump()
        return receipt

    def committed(self, node_id: NodeId, *, limit: int = 256) -> list[Committed]:
        """Read one participant's released prefix.

        Args:
            node_id: Which member.
            limit: The most entries to return.

        Returns:
            Its entries, in slot order.
        """
        return self._sessions[node_id].committed_since(1, limit=limit)

    def decided_through(self, node_id: NodeId) -> Slot:
        """Return one participant's released prefix length.

        Args:
            node_id: Which member.

        Returns:
            The last slot it has released.
        """
        return self._sessions[node_id].state().decided_through

    def close(self) -> None:
        """Close every participant."""
        for session in self._sessions.values():
            session.close()
        self._sessions.clear()

    def __enter__(self) -> Self:
        """Return this cluster for use in a ``with`` block."""
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Close the cluster on the way out."""
        self.close()


class AsyncLoopbackTransport:
    """An in-process :class:`~paxodin.aio.AsyncTransport` over asyncio queues."""

    __slots__ = ("_fabric", "_node_id")

    def __init__(self, fabric: AsyncFabric, node_id: NodeId) -> None:
        """Bind a transport to one participant.

        Args:
            fabric: The shared queues.
            node_id: The participant this transport belongs to.
        """
        self._fabric = fabric
        self._node_id = node_id

    async def send(self, *, peer: NodeId, frame: bytes) -> None:
        """Queue one frame for a peer.

        Args:
            peer: The recipient.
            frame: The encoded envelope.
        """
        if self._node_id in self._fabric.partitioned:
            return
        queue = self._fabric.queues.get(peer)
        if queue is not None:
            queue.put_nowait((self._node_id, frame))

    async def receive(self) -> tuple[NodeId, bytes]:
        """Wait for the next frame.

        Returns:
            The sender and the frame.
        """
        return await self._fabric.queues[self._node_id].get()

    async def close(self) -> None:
        """Nothing to release."""


class AsyncFabric:
    """The shared queues behind every :class:`AsyncLoopbackTransport`.

    ``partitioned`` is a set of members whose frames are silently dropped, for
    tests that need a leader to lose contact.
    """

    __slots__ = ("partitioned", "queues")

    def __init__(self, members: Sequence[NodeId], depth: int = 4096) -> None:
        """Create one bounded queue per member.

        Args:
            members: The membership.
            depth: Frames one queue holds before ``put`` blocks.
        """
        self.queues: dict[NodeId, asyncio.Queue[tuple[NodeId, bytes]]] = {
            member: asyncio.Queue(maxsize=depth) for member in members
        }
        self.partitioned: set[NodeId] = set()


class AsyncCluster:
    """Several :class:`~paxodin.aio.AsyncSession` participants in one event loop.

    Warning:
        Memory-backed and not durable, like :class:`Cluster`.

    Example:
        >>> import asyncio
        >>> async def main() -> list[int]:
        ...     async with AsyncCluster(3) as cluster:
        ...         first = await cluster.append(b"one")
        ...         second = await cluster.append(b"two")
        ...         return [first.slot, second.slot]
        >>> asyncio.run(main())
        [1, 2]
    """

    __slots__ = ("_fabric", "_members", "_sessions")

    def __init__(
        self,
        size: int = 3,
        *,
        configuration_id: int = 1,
        tick_interval: float = 0.005,
        **options: Unpack[SessionOptions],
    ) -> None:
        """Prepare ``size`` participants. They start when the cluster is entered.

        Args:
            size: How many voting members to run.
            configuration_id: The configuration identity they share.
            tick_interval: How often each participant is ticked while idle.
            **options: Tuning in seconds, passed to every participant.
        """
        self._members: list[NodeId] = list(range(1, size + 1))
        self._fabric = AsyncFabric(self._members)
        self._sessions: dict[NodeId, AsyncSession] = {
            member: AsyncSession(
                node_id=member,
                members=self._members,
                configuration_id=configuration_id,
                journal=MemoryJournal(),
                transport=AsyncLoopbackTransport(self._fabric, member),
                history=MemoryHistory(),
                tick_interval=tick_interval,
                **options,
            )
            for member in self._members
        }

    @property
    def members(self) -> list[NodeId]:
        """The voting membership."""
        return list(self._members)

    @property
    def fabric(self) -> AsyncFabric:
        """The queues, exposed so a test can partition a member."""
        return self._fabric

    def session(self, node_id: NodeId) -> AsyncSession:
        """Return one participant.

        Args:
            node_id: Which member.

        Returns:
            That member's session.
        """
        return self._sessions[node_id]

    def leader(self) -> AsyncSession | None:
        """Return the participant that currently believes it leads, if any."""
        for session in self._sessions.values():
            if session.is_leader:
                return session
        return None

    async def elect(self, node_id: NodeId | None = None, *, timeout: float = 2.0) -> AsyncSession:
        """Ensure a leader exists, campaigning if necessary.

        Args:
            node_id: Which member should stand. Defaults to the first.
            timeout: Seconds to wait for leadership to settle.

        Returns:
            The leading session.

        Raises:
            TimeoutError: If no leader emerged in time.
        """
        existing = self.leader()
        if existing is not None:
            return existing
        candidate = self._sessions[node_id or self._members[0]]
        await candidate.campaign()
        async with asyncio.timeout(timeout):
            while not candidate.is_leader:
                await asyncio.sleep(0.001)
        return candidate

    async def append(self, value: bytes, *, timeout: float = 5.0) -> Receipt:
        """Submit a command through whichever participant leads.

        Args:
            value: The command bytes.
            timeout: Seconds to wait for the decision.

        Returns:
            The receipt for the decided slot.
        """
        leader = await self.elect()
        return await leader.append(value, timeout=timeout)

    async def __aenter__(self) -> Self:
        """Start every participant."""
        for session in self._sessions.values():
            await session.start()
        return self

    async def __aexit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Close every participant."""
        for session in self._sessions.values():
            await session.close()
