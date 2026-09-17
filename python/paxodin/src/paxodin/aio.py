"""The asyncio surface.

:class:`AsyncSession` is the same participant as :class:`paxodin.Session` with the
driving done for you: a receiver task delivers frames, a ticker task keeps the
engine's timers moving, and ``await session.append(...)`` resolves when the
command is released. There is no polling loop to remember.

Ownership is explicit because the engine allows exactly one transition at a
time. Every transition -- yours or the driver's -- runs under one
:class:`asyncio.Lock`, and journal syncs run in a worker thread so an ``fsync``
never stalls the event loop. Cancellation is honest: cancelling ``append`` stops
*waiting*, it does not un-propose. Paxos has no cancel, and this API will not
pretend otherwise.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections import deque
from typing import TYPE_CHECKING, Protocol, Self, Unpack, runtime_checkable

from paxodin import codec
from paxodin.errors import CommitTimeout, InvalidTimeout, NotLeader, ProposalLost, raise_for
from paxodin.models import EntryKind, Receipt, SessionOptions
from paxodin.session import DEFAULT_TICK_INTERVAL, Session

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator, Sequence

    from paxodin.models import Committed, Envelope, NodeId, NodeState, Slot
    from paxodin.node import Node, PendingBatch
    from paxodin.protocols import History, Journal


@runtime_checkable
class AsyncTransport(Protocol):
    """Moves opaque frames between peers, asynchronously.

    The adapter owns framing, connections and -- critically -- authentication: a
    sender id inside a frame is a claim, not proof. It must preserve frame
    boundaries and bound the bytes it queues.
    """

    async def send(self, *, peer: NodeId, frame: bytes) -> None:
        """Deliver one frame to one peer, best effort.

        Args:
            peer: The recipient's identity.
            frame: The encoded envelope.
        """
        ...

    async def receive(self) -> tuple[NodeId, bytes]:
        """Wait for the next frame.

        Returns:
            The authenticated sender and the frame.
        """
        ...

    async def close(self) -> None:
        """Release the transport's resources."""
        ...


class _Outbox:
    """The sync session's transport: it only queues. The driver flushes."""

    __slots__ = ("frames",)

    def __init__(self) -> None:
        self.frames: deque[tuple[NodeId, bytes]] = deque()

    def send(self, *, peer: NodeId, frame: bytes) -> None:
        self.frames.append((peer, frame))

    def receive(self, *, timeout: float) -> tuple[NodeId, bytes] | None:
        del timeout
        message = "the async session drives its own receiving"
        raise RuntimeError(message)

    def close(self) -> None:
        self.frames.clear()


class AsyncSession:
    """One participant, driven by asyncio.

    Example:
        >>> from paxodin.testing import AsyncCluster
        >>> async def main() -> int:
        ...     async with AsyncCluster(3) as cluster:
        ...         receipt = await cluster.append(b"set counter 41")
        ...         return receipt.slot
        >>> import asyncio
        >>> asyncio.run(main())
        1
    """

    __slots__ = (
        "_inflight",
        "_outbox",
        "_serial",
        "_sync",
        "_tasks",
        "_tick_interval",
        "_transport",
        "_waiters",
    )

    def __init__(
        self,
        *,
        node_id: NodeId,
        members: Sequence[NodeId],
        configuration_id: int,
        journal: Journal,
        transport: AsyncTransport,
        history: History | None = None,
        tick_interval: float = DEFAULT_TICK_INTERVAL,
        **options: Unpack[SessionOptions],
    ) -> None:
        """Open or restore a participant. Nothing runs until it is entered.

        Args:
            node_id: This member's stable, non-zero identity.
            members: Every voting member of the configuration.
            configuration_id: The non-zero identity of this configuration.
            journal: Where durable records go.
            transport: How frames reach peers. It owns authentication.
            history: Where released entries are retained. Defaults to memory.
            tick_interval: How often the engine is ticked while idle.
            **options: Tuning in seconds, as for :class:`paxodin.Session`.
        """
        self._outbox = _Outbox()
        self._transport = transport
        self._tick_interval = tick_interval
        self._sync = Session(
            node_id=node_id,
            members=members,
            configuration_id=configuration_id,
            journal=journal,
            transport=self._outbox,
            history=history,
            tick_interval=tick_interval,
            **options,
        )
        self._serial = asyncio.Lock()
        self._inflight: set[asyncio.Future[None]] = set()
        self._waiters: dict[Slot, asyncio.Future[None]] = {}
        self._tasks: list[asyncio.Task[None]] = []

    # ---- lifecycle ----------------------------------------------------------

    async def start(self) -> None:
        """Start the receiver and ticker tasks. Idempotent."""
        if self._tasks:
            return
        self._tasks = [
            asyncio.create_task(self._receive_forever(), name="paxodin-receiver"),
            asyncio.create_task(self._tick_forever(), name="paxodin-ticker"),
        ]

    async def close(self) -> None:
        """Stop driving, then close the node, journal, transport and history.

        Closing stops local work. It does not withdraw a proposal that peers may
        still choose.
        """
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        self._tasks = []
        # A discharge that was shielded from a cancellation may still be running
        # in its worker thread; the node must not close underneath it.
        if self._inflight:
            await asyncio.gather(*self._inflight, return_exceptions=True)
        for waiter in self._waiters.values():
            if not waiter.done():
                waiter.cancel()
        self._waiters.clear()
        try:
            self._sync.close()
        finally:
            await self._transport.close()

    async def __aenter__(self) -> Self:
        """Start driving and return the session."""
        await self.start()
        return self

    async def __aexit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Close on the way out."""
        await self.close()

    # ---- the one place a transition runs -------------------------------------

    async def _run(self, transition: Callable[[], PendingBatch]) -> PendingBatch:
        """Run one transition and discharge it, serialised and off the loop for I/O.

        The lock is the ownership model: the engine permits one transition at a
        time, and this is the only path to one. The journal sync inside
        ``discharge`` may block on ``fsync``, so it runs in a worker thread.
        """
        async with self._serial:
            batch = transition()
            # Shielded: a cancellation must not abandon a batch half-discharged,
            # with records handed to the journal but never confirmed. The
            # cancellation still propagates once the discharge has completed.
            work = asyncio.ensure_future(asyncio.to_thread(self._sync.discharge, batch))
            self._inflight.add(work)
            work.add_done_callback(self._inflight.discard)
            await asyncio.shield(work)
            await self._flush()
            self._settle_waiters()
            return batch

    async def _flush(self) -> None:
        """Hand everything the sync session queued to the async transport."""
        outbox = self._outbox.frames
        while outbox:
            peer, frame = outbox.popleft()
            with contextlib.suppress(Exception):
                await self._transport.send(peer=peer, frame=frame)

    def _settle_waiters(self) -> None:
        """Wake every append whose slot has now been released."""
        released = self._sync.last_committed
        for slot in [slot for slot in self._waiters if slot <= released]:
            waiter = self._waiters.pop(slot)
            if not waiter.done():
                waiter.set_result(None)

    async def _receive_forever(self) -> None:
        while True:
            _peer, frame = await self._transport.receive()
            await self._step(codec.decode(frame))

    async def _step(self, envelope: Envelope) -> None:
        await self._run(lambda: self._sync.node.step(envelope))

    async def _tick_forever(self) -> None:
        while True:
            await asyncio.sleep(self._tick_interval)
            await self._run(self._sync.node.tick)

    # ---- the API ------------------------------------------------------------

    async def campaign(self) -> None:
        """Stand for leadership now, without waiting for a timeout."""
        await self._run(self._sync.node.campaign)

    async def append(self, value: bytes, *, timeout: float = 5.0) -> Receipt:
        """Submit a command and wait until it is durably released here.

        Args:
            value: The command bytes, at most ``profile.max_value_bytes``.
            timeout: Seconds to wait for the decision.

        Returns:
            A receipt naming the configuration and slot that hold the command.

        Raises:
            NotLeader: This participant is a follower; nothing is forwarded.
            ValueTooLarge: The command exceeds the profile. Nothing was admitted.
            ProposalLost: A different value was decided in the admitted slot.
            CommitTimeout: The wait ended. Paxos was not cancelled and the value
                may still be chosen; it is also a ``TimeoutError``.
            asyncio.CancelledError: The wait was cancelled. The proposal stands:
                cancelling a coroutine cannot un-propose a value.

        Note:
            Success means agreement and release at *this* participant. It says
            nothing about peers having received it, and never that the
            application applied it.
        """
        if timeout != timeout or timeout < 0 or timeout == float("inf"):  # noqa: PLR0124
            raise InvalidTimeout(timeout)
        batch = await self._run(lambda: self._sync.node.propose(value))
        status, slot = batch.status, batch.assigned_slot
        if status == NotLeader.code:
            state = self._sync.state()
            raise NotLeader(leader=state.leader, node_id=state.node_id)
        raise_for(status, value_bytes=len(value))

        if self._sync.last_committed < slot:
            waiter = self._waiters.setdefault(slot, asyncio.get_running_loop().create_future())
            try:
                async with asyncio.timeout(timeout):
                    await waiter
            except TimeoutError as exc:
                self._waiters.pop(slot, None)
                raise CommitTimeout(admitted=True, slot=slot, seconds=timeout) from exc

        entry = self._sync[slot].entry
        if entry.kind is not EntryKind.COMMAND or entry.body != value:
            raise ProposalLost(slot=slot, submitted_bytes=len(value), decided_kind=entry.kind.name)
        return Receipt(
            configuration_id=self._sync.state().configuration_id, slot=slot, entry=entry
        )

    # ---- reads: no I/O, so they stay synchronous ------------------------------

    @property
    def node(self) -> Node:
        """The underlying participant, for hosts that need direct control."""
        return self._sync.node

    @property
    def node_id(self) -> NodeId:
        """This participant's identity."""
        return self._sync.node_id

    @property
    def is_leader(self) -> bool:
        """Whether this participant currently believes it leads. A belief, not a lease."""
        return self._sync.is_leader

    @property
    def leader(self) -> NodeId | None:
        """The member this participant thinks leads, if it has heard from one."""
        return self._sync.leader

    @property
    def last_committed(self) -> Slot:
        """The last slot released here, in order. Zero if none."""
        return self._sync.last_committed

    def state(self) -> NodeState:
        """Return a snapshot of this participant."""
        return self._sync.state()

    def entries(self, start: Slot = 1, *, limit: int | None = None) -> Iterator[Committed]:
        """Iterate released entries from ``start``. See :meth:`paxodin.Session.entries`."""
        return self._sync.entries(start, limit=limit)

    def __getitem__(self, slot: Slot) -> Committed:
        """Return the entry released at ``slot``, or raise ``KeyError``."""
        return self._sync[slot]
