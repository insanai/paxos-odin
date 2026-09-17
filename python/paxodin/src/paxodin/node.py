"""The low-level participant: one transition at a time, no I/O.

``Node`` is the Python face of the Odin effect machine. It performs no I/O, owns
no thread and reads no clock. A transition mutates the node and leaves a
:class:`PendingBatch` describing what the host must now do -- persist these
records, send these messages, release these entries -- in that order.

Most applications want :class:`paxodin.Session`, which runs that order for them.
Reach for ``Node`` when the host needs to own scheduling or batching itself.
"""

from __future__ import annotations

import ctypes
import os
import threading
import warnings
import weakref
from typing import TYPE_CHECKING, Any, Final, Self, Unpack

from paxodin import _decode, _native
from paxodin.errors import (
    AbandonedBatch,
    ForkedHandle,
    HandleClosed,
    ReentrantCall,
    ValueTooLarge,
    raise_for,
)
from paxodin.models import BatchPhase, EntryKind, NodeOptions

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

    from paxodin.models import (
        Committed,
        Envelope,
        NodeId,
        NodeState,
        Profile,
        ServeRange,
        Slot,
        WriteRecord,
    )

# Copy chunk sizes. A message is ~1.4 KiB and a batch can hold 463 of them, so
# copying everything at once would ask for two thirds of a megabyte in one
# allocation -- making the MemoryError this design exists to survive more likely,
# not less. Chunking bounds the cost of a failed copy to one chunk.
_WRITE_CHUNK: Final = 64
_MESSAGE_CHUNK: Final = 16
_COMMITTED_CHUNK: Final = 32

_FORK_GENERATION = 0


def _note_fork() -> None:
    global _FORK_GENERATION  # noqa: PLW0603
    _FORK_GENERATION += 1


os.register_at_fork(after_in_child=_note_fork)


class AbandonedWritesWarning(UserWarning):
    """A node was closed while it still held unconfirmed writes.

    Those records were handed out but never acknowledged durable, so the node
    must be rebuilt by journal replay rather than resumed.
    """


class _HandleBox:
    """Holds the raw handle so a finalizer can release it without the Node."""

    __slots__ = ("handle",)

    def __init__(self, handle: int) -> None:
        """Hold a raw handle.

        Args:
            handle: The native pointer, as an integer.
        """
        self.handle: int | None = handle


def _release(box: _HandleBox) -> None:
    """Close the native handle exactly once, reporting abandoned writes."""
    handle, box.handle = box.handle, None
    if handle is None:
        return
    abandoned = ctypes.c_uint32()
    _native.LIB.paxodin_node_close(handle, ctypes.byref(abandoned))
    if abandoned.value:
        warnings.warn(
            f"closed a node holding {abandoned.value} unconfirmed write(s); those "
            "records were never acknowledged durable. Replay the journal before "
            "restarting this node rather than resuming it.",
            AbandonedWritesWarning,
            stacklevel=2,
        )


class PendingBatch:
    """One retained effects batch: a durability obligation, not a result.

    The order is fixed and the type enforces it::

        writes -> append and sync -> persisted() -> messages / committed
        -> requests -> finish()

    Every probe and copy is idempotent, so a failed allocation can be retried
    without rerunning the transition that produced it.

    Note:
        ``status`` is the protocol outcome and is independent of the effects. A
        transition can report an error *and* leave writes the host must still
        persist, so checking the status is never a substitute for discharging
        the batch.
    """

    __slots__ = ("_buffers", "_node", "_report", "_token")

    def __init__(self, node: Node, token: _native.CToken, report: _native.CReport) -> None:
        """Wrap the batch a transition left behind.

        Args:
            node: The node that produced it.
            token: Its generation token.
            report: Its counts and phase.
        """
        self._node = node
        self._token = token
        self._report = report
        # One buffer per record type, reused across chunks and retries: a fresh
        # ctypes array per copy would allocate and zero kilobytes per value.
        self._buffers: dict[type, ctypes.Array[Any]] = {}

    @property
    def status(self) -> int:
        """The protocol status of the transition, independent of its effects."""
        return int(self._report.status)

    @property
    def assigned_slot(self) -> Slot:
        """The slot a proposal was admitted to, or zero."""
        return int(self._report.assigned_slot)

    @property
    def requires_barrier(self) -> bool:
        """True when the batch holds a promise or a vote.

        A decision or a trim record is derived state a host may persist behind a
        cheaper barrier; a promise or a vote is the indelible ink whose loss lets
        a crash choose two values for one slot.
        """
        return bool(self._report.requires_barrier)

    @property
    def phase(self) -> BatchPhase:
        """Where the batch has got to, so an interrupted caller can resume."""
        self.refresh()
        return BatchPhase(self._report.phase)

    def refresh(self) -> None:
        """Re-read the batch report from the node."""
        with self._node._guard() as handle:
            raise_for(
                _native.LIB.paxodin_batch_report(
                    handle, ctypes.byref(self._token), ctypes.byref(self._report)
                )
            )

    def _copy[S: ctypes.Structure, T](
        self,
        function: Callable[..., int],
        ctype: type[S],
        total: int,
        decode: Callable[[S], T],
        chunk: int,
    ) -> list[T]:
        """Probe-then-copy in bounded chunks, retryable at any offset."""
        out: list[T] = []
        written = ctypes.c_uint32()
        size = max(1, min(chunk, total))
        buffer = self._buffers.get(ctype)
        if buffer is None or len(buffer) < size:
            buffer = (ctype * size)()
            self._buffers[ctype] = buffer
        if total == 0:
            # Still make one call. An empty result is not permission to skip the
            # phase check: asking for outputs before confirming the writes is the
            # same mistake whether or not this transition produced any.
            with self._node._guard() as handle:
                status = function(
                    handle, ctypes.byref(self._token), 0, 0, buffer, ctypes.byref(written)
                )
            raise_for(status)
            return out
        offset = 0
        while offset < total:
            want = min(size, total - offset)
            with self._node._guard() as handle:
                status = function(
                    handle, ctypes.byref(self._token), offset, want, buffer, ctypes.byref(written)
                )
            raise_for(status)
            # Decoding allocates. If it raises, the native batch is untouched and
            # the whole copy can be retried from any offset.
            out.extend(decode(buffer[index]) for index in range(written.value))
            offset += written.value
        return out

    def writes(self) -> list[WriteRecord]:
        """Return the durable records, in journal order.

        Returns:
            Every record of this transition. Append them in order and sync before
            calling :meth:`persisted`.
        """
        return self._copy(
            _native.LIB.paxodin_copy_writes,
            _native.CWrite,
            self._report.write_count,
            _decode.write,
            _WRITE_CHUNK,
        )

    def persisted(self) -> None:
        """Declare every record from :meth:`writes` appended and synced.

        This is the only call that unblocks the outputs, because transmitting a
        reply or releasing a decision before its record is on stable storage is
        exactly what lets a crash choose two values for one slot.

        Raises:
            WritesNotCopied: If :meth:`writes` never returned the whole batch.
                The bridge refuses to acknowledge records the host never got.
            StaleToken: If a later transition superseded this batch.
        """
        with self._node._guard() as handle:
            raise_for(_native.LIB.paxodin_confirm(handle, ctypes.byref(self._token)))

    def messages(self) -> list[Envelope]:
        """Return the outbound envelopes.

        Returns:
            Owned envelopes, each stamped with its configuration.

        Raises:
            WritesUnconfirmed: If the writes are not yet confirmed durable.
        """
        return self._copy(
            _native.LIB.paxodin_copy_messages,
            _native.CEnvelope,
            self._report.message_count,
            _decode.envelope,
            _MESSAGE_CHUNK,
        )

    def committed(self) -> list[Committed]:
        """Return the entries released by this transition, in slot order.

        Returns:
            Owned entries, contiguous with everything released before them.

        Raises:
            WritesUnconfirmed: If the writes are not yet confirmed durable.
        """
        return self._copy(
            _native.LIB.paxodin_copy_committed,
            _native.CCommitted,
            self._report.committed_count,
            _decode.committed,
            _COMMITTED_CHUNK,
        )

    def requests(self) -> list[ServeRange]:
        """Return history ranges peers asked for below this node's memory floor.

        Serving one means transmitting commits from retained history, which is a
        send like any other, so it waits on the same confirmation.

        Returns:
            Owned request records.

        Raises:
            WritesUnconfirmed: If the writes are not yet confirmed durable.
        """
        return self._copy(
            _native.LIB.paxodin_copy_requests,
            _native.CRequest,
            self._report.request_count,
            _decode.request,
            _native.PROFILE.max_requests_per_batch,
        )

    def assigned_slots(self) -> list[Slot]:
        """Return the slots a batch proposal was admitted to.

        Returns:
            One slot per submitted value, in submission order.
        """
        total = self._report.assigned_count
        if total == 0:
            return []
        buffer = (ctypes.c_uint64 * total)()
        written = ctypes.c_uint32()
        with self._node._guard() as handle:
            raise_for(
                _native.LIB.paxodin_copy_assigned_slots(
                    handle, ctypes.byref(self._token), 0, total, buffer, ctypes.byref(written)
                )
            )
        return [buffer[index] for index in range(written.value)]

    def finish(self) -> None:
        """Release the batch so the next transition may run.

        Raises:
            WritesUnconfirmed: If the batch still holds unconfirmed writes.
                Releasing here would discard records the journal never took.
        """
        with self._node._guard() as handle:
            raise_for(_native.LIB.paxodin_finish(handle, ctypes.byref(self._token)))

    def __enter__(self) -> Self:
        """Return this batch for use in a ``with`` block."""
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Finish a confirmed batch. Never confirm one.

        Auto-confirming would assert a durability fact this package cannot
        observe. An unconfirmed batch is therefore left pending, so the next
        transition refuses and says how to recover, rather than proceeding over
        records that may never have reached disk.
        """
        self.refresh()
        phase = BatchPhase(self._report.phase)
        if phase is BatchPhase.FINISHED:
            return
        if phase is BatchPhase.CONFIRMED:
            self.finish()
            return
        if exc_type is None:
            raise AbandonedBatch


class Node:
    """One local participant, driven one transition at a time.

    A node owns an opaque native handle. Exactly one call may be inside that
    handle at a time: a second thread blocks, and the same thread re-entering
    raises :class:`ReentrantCall` rather than deadlocking. Every value a node
    returns is an owned Python object whose lifetime is independent of the
    native window.

    Example:
        >>> node = Node(node_id=1, members=[1, 2, 3], configuration_id=1)
        >>> with node.campaign() as batch:
        ...     records = batch.writes()  # append and sync these
        ...     batch.persisted()
        ...     outbound = batch.messages()
        >>> node.close()
    """

    __slots__ = (
        "__weakref__",
        "_box",
        "_finalizer",
        "_fork_generation",
        "_guard_instance",
        "_lock",
        "_owner",
    )

    def __init__(
        self,
        *,
        node_id: NodeId,
        members: Sequence[NodeId],
        configuration_id: int,
        priority: int = 0,
        read_quorum: int = 0,
        write_quorum: int = 0,
        election_timeout_ticks: int = 0,
        heartbeat_interval_ticks: int = 0,
        resend_interval_ticks: int = 0,
        campaign_disabled: bool = False,
        gate_proposals_on_inherited_prefix: bool = False,
    ) -> None:
        """Open a participant in a fresh configuration.

        Args:
            node_id: This member's stable, non-zero identity.
            members: Every voting member of the configuration.
            configuration_id: The non-zero identity of this configuration.
            priority: Breaks ballot ties between rounds; higher wins.
            read_quorum: Phase-one quorum size. Zero selects a majority.
            write_quorum: Phase-two quorum size. Zero selects a majority.
            election_timeout_ticks: Ticks without leader contact before
                campaigning. Zero selects the core default.
            heartbeat_interval_ticks: Ticks between heartbeats. Zero selects the
                core default.
            resend_interval_ticks: Ticks between retransmission scans. Zero
                selects the core default.
            campaign_disabled: Start as an acceptor that never campaigns.
            gate_proposals_on_inherited_prefix: Refuse proposals until every
                inherited slot has been delivered.

        Raises:
            PaxodinError: If the configuration is not one the core accepts --
                a zero id, a duplicate member, or quorums that cannot intersect.
        """
        config = _build_config(
            node_id=node_id,
            members=members,
            configuration_id=configuration_id,
            priority=priority,
            read_quorum=read_quorum,
            write_quorum=write_quorum,
            election_timeout_ticks=election_timeout_ticks,
            heartbeat_interval_ticks=heartbeat_interval_ticks,
            resend_interval_ticks=resend_interval_ticks,
            campaign_disabled=campaign_disabled,
            gate_proposals_on_inherited_prefix=gate_proposals_on_inherited_prefix,
        )
        handle = ctypes.c_void_p()
        raise_for(
            _native.LIB.paxodin_node_open(ctypes.byref(config), ctypes.byref(handle)),
            node_id=node_id,
            configuration_id=configuration_id,
        )
        self._box = _HandleBox(handle.value or 0)
        self._lock = threading.Lock()
        self._owner: int | None = None
        self._fork_generation = _FORK_GENERATION
        self._guard_instance = _Guard(self)
        self._finalizer = weakref.finalize(self, _release, self._box)

    @classmethod
    def restore(
        cls,
        *,
        node_id: NodeId,
        members: Sequence[NodeId],
        configuration_id: int,
        records: Sequence[WriteRecord],
        floor: Slot = 0,
        **options: Unpack[NodeOptions],
    ) -> Node:
        """Rebuild a participant from its journal.

        The records are folded with the lifetime fold, which tolerates the
        out-of-order promises a journal legitimately accumulates across restarts.
        The ledger never crosses the ABI: the bridge owns it for the duration of
        the replay and hands the core a finished one.

        Args:
            node_id: This member's identity.
            members: Every voting member of the configuration.
            configuration_id: The configuration this journal belongs to.
            records: Every durable record, in append order.
            floor: The last slot the host durably consumed. Cells at or below it
                that hold only an open vote are cleared.
            **options: The same tuning arguments :meth:`__init__` accepts.

        Returns:
            The restored node.

        Raises:
            PaxodinError: If a record contradicts the ledger, which means the
                journal is corrupt or was replayed out of order.
        """
        node = cls.__new__(cls)
        config = _build_config(
            node_id=node_id,
            members=members,
            configuration_id=configuration_id,
            priority=options.get("priority", 0),
            read_quorum=options.get("read_quorum", 0),
            write_quorum=options.get("write_quorum", 0),
            election_timeout_ticks=options.get("election_timeout_ticks", 0),
            heartbeat_interval_ticks=options.get("heartbeat_interval_ticks", 0),
            resend_interval_ticks=options.get("resend_interval_ticks", 0),
            campaign_disabled=options.get("campaign_disabled", False),
            gate_proposals_on_inherited_prefix=options.get(
                "gate_proposals_on_inherited_prefix", False
            ),
        )
        handle = ctypes.c_void_p()
        raise_for(
            _native.LIB.paxodin_node_open_for_replay(ctypes.byref(config), ctypes.byref(handle)),
            node_id=node_id,
        )
        node._box = _HandleBox(handle.value or 0)
        node._lock = threading.Lock()
        node._owner = None
        node._fork_generation = _FORK_GENERATION
        node._guard_instance = _Guard(node)
        node._finalizer = weakref.finalize(node, _release, node._box)
        try:
            raw = _native.CWrite()
            for index, record in enumerate(records):
                _fill_write(raw, record)
                with node._guard() as live:
                    status = _native.LIB.paxodin_replay_apply(live, ctypes.byref(raw))
                raise_for(status, record_index=index, slot=record.slot)
            with node._guard() as live:
                status = _native.LIB.paxodin_replay_restore(live, floor)
            raise_for(status, floor=floor)
        except BaseException:
            node.close()
            raise
        return node

    def _guard(self) -> _Guard:
        """Take the handle for one call, rejecting reentrancy and stale forks.

        The guard holds no per-call state, so one instance serves every call and
        the hot path allocates nothing.
        """
        return self._guard_instance

    @property
    def profile(self) -> Profile:
        """The capacities this build was compiled with."""
        return _decode.profile(_native.PROFILE)

    @property
    def closed(self) -> bool:
        """True once the native handle has been released."""
        return self._box.handle is None

    def state(self) -> NodeState:
        """Return a snapshot of this participant.

        Returns:
            The role, ballot, leader, released prefix, memory floor and seal
            state, gathered in one call so they cannot disagree with each other.

        Note:
            ``decided_through`` is this participant's released prefix. It is not
            a freshness guarantee: the core has no lease, so a local read can be
            arbitrarily stale.
        """
        raw = _native.CState()
        with self._guard() as handle:
            raise_for(_native.LIB.paxodin_state(handle, ctypes.byref(raw)))
        return _decode.state(raw)

    def _begin(self, call: Callable[..., int], *args: object) -> PendingBatch:
        """Run one transition and wrap the batch it leaves behind."""
        token, report = _native.CToken(), _native.CReport()
        with self._guard() as handle:
            status = call(handle, *args, ctypes.byref(token), ctypes.byref(report))
        raise_for(status)
        return PendingBatch(self, token, report)

    def campaign(self) -> PendingBatch:
        """Start a campaign for leadership.

        Returns:
            The batch this transition produced.
        """
        return self._begin(_native.LIB.paxodin_begin_campaign)

    def tick(self) -> PendingBatch:
        """Advance the logical clock by one tick.

        A tick is a logical unit, not a duration: the core counts election and
        heartbeat timeouts in ticks and leaves their real-time meaning to the
        host. :class:`paxodin.Session` binds it to a wall clock.

        Returns:
            The batch this transition produced.
        """
        return self._begin(_native.LIB.paxodin_begin_tick)

    def propose(self, value: bytes) -> PendingBatch:
        """Submit one command.

        Args:
            value: The command bytes, at most ``profile.max_value_bytes``. An
                empty command is legal and stays distinguishable from a no-op.

        Returns:
            The batch this transition produced. Its ``assigned_slot`` names the
            slot the command was admitted to when the status is success.

        Raises:
            ValueTooLarge: If the command exceeds the profile. No proposal was
                admitted and the node is unchanged.
        """
        entry = _entry_for(value)
        return self._begin(_native.LIB.paxodin_begin_propose, ctypes.byref(entry))

    def propose_batch(self, values: Sequence[bytes]) -> PendingBatch:
        """Submit several commands, admitted whole or not at all.

        Args:
            values: Between one and ``profile.chunk_slots`` commands.

        Returns:
            The batch this transition produced. Read the slots with
            ``assigned_slots()``.

        Raises:
            ValueTooLarge: If any command exceeds the profile.
            InvalidArgument: If the count is zero or above ``chunk_slots``.
        """
        count = len(values)
        array = (_native.CEntry * max(count, 1))()
        for index, value in enumerate(values):
            _fill_entry(array[index], value)
        return self._begin(_native.LIB.paxodin_begin_propose_batch, array, count)

    def step(self, envelope: Envelope) -> PendingBatch:
        """Deliver one received message.

        The configuration stamp is checked before the core sees anything: a
        mismatch resets the batch and reports it, with no writes, no messages
        and no state change. Stale traffic is refused, never relabelled.

        Args:
            envelope: The decoded message, as the caller's codec produced it.

        Returns:
            The batch this transition produced.
        """
        raw = _encode_envelope(envelope)
        return self._begin(_native.LIB.paxodin_begin_step, ctypes.byref(raw))

    def reconnected(self, peer: NodeId) -> PendingBatch:
        """Tell the node a peer is reachable again.

        Args:
            peer: The peer's identity.

        Returns:
            The batch this transition produced.
        """
        return self._begin(_native.LIB.paxodin_begin_reconnected, peer)

    def request_catch_up(self, peer: NodeId, from_slot: Slot) -> PendingBatch:
        """Ask a peer for decided history from ``from_slot``.

        Args:
            peer: The peer to ask.
            from_slot: The first slot wanted.

        Returns:
            The batch this transition produced.
        """
        return self._begin(_native.LIB.paxodin_begin_request_catch_up, peer, from_slot)

    def install_chosen_trim(self, trim_id: int, chosen_trim_slot: Slot) -> PendingBatch:
        """Adopt a trim anchor certified by the host.

        Args:
            trim_id: The host's identity for the state image.
            chosen_trim_slot: The slot the image folds in, inclusive.

        Returns:
            The batch this transition produced.
        """
        return self._begin(
            _native.LIB.paxodin_begin_install_chosen_trim, trim_id, chosen_trim_slot
        )

    def advance_memory_floor(self, through: Slot) -> None:
        """Record that released entries through ``through`` are durably consumed.

        This frees window cells for reuse, which is why it refuses while a batch
        is live: the batch's released entries still point into those cells, and
        losing them would silently break a contiguously released prefix.

        Args:
            through: The last durably consumed slot.

        Raises:
            BatchPending: If a batch has not been finished.
        """
        with self._guard() as handle:
            raise_for(_native.LIB.paxodin_advance_memory_floor(handle, through))

    def set_campaign_enabled(self, enabled: bool) -> None:
        """Allow or forbid this participant from starting elections.

        Args:
            enabled: Whether campaigning is permitted.
        """
        with self._guard() as handle:
            raise_for(_native.LIB.paxodin_set_campaign_enabled(handle, 1 if enabled else 0))

    def decided_span(self, from_slot: Slot) -> int:
        """Return how many decided entries sit at or above ``from_slot``.

        Args:
            from_slot: The first slot of interest.

        Returns:
            The count, so a caller can size a buffer before reading.

        Raises:
            Trimmed: If ``from_slot`` has fallen below the memory floor. Read it
                from retained history instead; the node no longer holds it.
        """
        out = ctypes.c_uint64()
        with self._guard() as handle:
            raise_for(_native.LIB.paxodin_decided_span(handle, from_slot, ctypes.byref(out)))
        return out.value

    def read_decided(self, from_slot: Slot, limit: int) -> list[Committed]:
        """Read a bounded window of the decided prefix.

        Args:
            from_slot: The first slot to read.
            limit: The most entries to return.

        Returns:
            Up to ``limit`` entries, in slot order.

        Raises:
            Trimmed: If ``from_slot`` has fallen below the memory floor.
        """
        if limit <= 0:
            return []
        buffer = (_native.CCommitted * limit)()
        written = ctypes.c_uint32()
        next_slot = ctypes.c_uint64()
        with self._guard() as handle:
            raise_for(
                _native.LIB.paxodin_read_decided(
                    handle,
                    from_slot,
                    limit,
                    buffer,
                    ctypes.byref(written),
                    ctypes.byref(next_slot),
                )
            )
        return [_decode.committed(buffer[index]) for index in range(written.value)]

    def close(self) -> None:
        """Release the native handle. Calling this again does nothing.

        Closing while a batch still holds unconfirmed writes abandons them and
        warns: those records were handed out but never acknowledged durable, so
        the node must be rebuilt by journal replay rather than resumed.

        Raises:
            ReentrantCall: If called from inside another call on this handle.
        """
        if self._owner == threading.get_ident():
            raise ReentrantCall
        with self._lock:
            self._owner = threading.get_ident()
            try:
                self._finalizer()
            finally:
                self._owner = None

    def __enter__(self) -> Self:
        """Return this node for use in a ``with`` block."""
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Close the node on the way out."""
        self.close()


class _Guard:
    """Takes a node's handle for the duration of one native call."""

    __slots__ = ("_node",)

    def __init__(self, node: Node) -> None:
        """Bind the guard to a node.

        Args:
            node: The node whose handle this guard takes.
        """
        self._node = node

    def __enter__(self) -> int:
        """Take the handle, rejecting reentrancy, a stale fork and a close.

        Returns:
            The raw native handle.

        Raises:
            ReentrantCall: If this thread is already inside a call on it.
            ForkedHandle: If the handle was created in another process.
            HandleClosed: If the node has been closed.
        """
        node = self._node
        identity = threading.get_ident()
        if node._owner == identity:
            raise ReentrantCall
        node._lock.acquire()
        node._owner = identity
        problem: type[ForkedHandle] | type[HandleClosed] | None = None
        if node._fork_generation != _FORK_GENERATION:
            problem = ForkedHandle
        elif node._box.handle is None:
            problem = HandleClosed
        if problem is not None:
            node._owner = None
            node._lock.release()
            raise problem
        handle = node._box.handle
        assert handle is not None  # noqa: S101  # established immediately above
        return handle

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        """Release the handle."""
        self._node._owner = None
        self._node._lock.release()


def _fill_entry(entry: _native.CEntry, value: bytes) -> None:
    """Write a command payload into a native entry, rejecting an oversized one."""
    limit = _native.PROFILE.max_value_bytes
    if len(value) > limit:
        raise ValueTooLarge(supplied=len(value), limit=limit)
    entry.kind = int(EntryKind.COMMAND)
    entry.length = len(value)
    if value:
        ctypes.memmove(entry.body, value, len(value))


def _fill_write(raw: _native.CWrite, record: WriteRecord) -> None:
    """Write a journal record into its native form for replay."""
    raw.kind = int(record.kind)
    raw.flags = 1 if record.requires_barrier else 0
    raw.ballot = record.ballot
    raw.slot = record.slot
    raw.trim_id = record.trim_id
    raw.trim_slot = record.trim_slot
    entry = record.entry
    raw.entry.kind = int(entry.kind)
    raw.entry.length = len(entry.body)
    ctypes.memset(raw.entry.body, 0, _native.MAX_VALUE_BYTES)
    if entry.body:
        ctypes.memmove(raw.entry.body, entry.body, len(entry.body))


def _entry_for(value: bytes) -> _native.CEntry:
    """Build a native entry holding one command."""
    entry = _native.CEntry()
    _fill_entry(entry, value)
    return entry


def _encode_envelope(envelope: Envelope) -> _native.CEnvelope:
    """Build the native form of a received message."""
    flat = _decode.flatten(envelope.message)
    raw = _native.CEnvelope(
        configuration_id=envelope.configuration_id,
        ballot=flat.ballot,
        slot=flat.slot,
        vote=flat.vote,
        first=flat.first,
        last=flat.last,
        rejected=flat.rejected,
        promised=flat.promised,
        decided_through=flat.decided_through,
        trim_id=flat.trim_id,
        trim_slot=flat.trim_slot,
        kind=flat.kind,
        count=flat.range_count,
        sender=envelope.sender,
        recipient=envelope.recipient,
        scope=flat.scope,
        cell_state=flat.cell_state,
        more=flat.more,
    )
    entry = flat.entry
    raw.entry.kind = int(entry.kind)
    if entry.kind is EntryKind.COMMAND or entry.kind is EntryKind.NOOP:
        raw.entry.length = len(entry.body)
        if entry.body:
            ctypes.memmove(raw.entry.body, entry.body, len(entry.body))
    return raw


def _build_config(
    *,
    node_id: NodeId,
    members: Sequence[NodeId],
    configuration_id: int,
    priority: int,
    read_quorum: int,
    write_quorum: int,
    election_timeout_ticks: int,
    heartbeat_interval_ticks: int,
    resend_interval_ticks: int,
    campaign_disabled: bool,
    gate_proposals_on_inherited_prefix: bool,
) -> _native.CConfig:
    """Build the native configuration record, validating what C cannot express."""
    if len(members) > _native.MAX_MEMBERS:
        raise ValueTooLarge(supplied=len(members), limit=_native.MAX_MEMBERS)
    flags = 0
    if campaign_disabled:
        flags |= 1 << 0
    if gate_proposals_on_inherited_prefix:
        flags |= 1 << 1
    config = _native.CConfig(
        configuration_id=configuration_id,
        member_count=len(members),
        read_quorum=read_quorum,
        write_quorum=write_quorum,
        election_timeout_ticks=election_timeout_ticks,
        heartbeat_interval_ticks=heartbeat_interval_ticks,
        resend_interval_ticks=resend_interval_ticks,
        flags=flags,
        node_id=node_id,
        priority=priority,
    )
    for index, member in enumerate(members):
        config.members[index] = member
    return config
