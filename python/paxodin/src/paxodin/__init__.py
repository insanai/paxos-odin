"""Idiomatic Python bindings for the paxos-odin consensus core.

The Odin core performs no I/O and owns no threads or clocks: it consumes messages
and fills a caller-owned batch of effects. This package keeps that split. It owns
the *order* of the durability contract -- persist, confirm, send, release -- and
the lifetime of the bytes it returns. Every actual byte moves through an adapter
the caller supplies, so there is no socket, no TLS policy and no retry loop here.

Three events are kept distinct throughout, because collapsing them is how a
consensus API starts lying:

* **agreement** -- a quorum chose the value;
* **release** -- this participant knows it, in order, durably;
* **application** -- the application has acted on it.

An ``append`` receipt reports the first two, at this participant only.

Example:
    >>> from paxodin.testing import Cluster
    >>> with Cluster(3) as cluster:
    ...     receipt = cluster.append(b"set counter 41")
    ...     receipt.slot
    1
"""

from __future__ import annotations

from paxodin._decode import profile as _decode_profile
from paxodin._native import EXPECTED_ABI_VERSION, PROFILE, capabilities, core_version, explain
from paxodin._native import status_count as status_count
from paxodin.aio import AsyncSession, AsyncTransport
from paxodin.errors import (
    AbandonedBatch,
    BatchError,
    BatchFinished,
    BatchPending,
    CommitTimeout,
    ConfigurationMismatch,
    ForeignToken,
    ForkedHandle,
    HandleClosed,
    InvalidArgument,
    InvalidTimeout,
    JournalCorrupt,
    JournalNotOpen,
    LogSealed,
    NoBatch,
    NotLeader,
    PaxodinError,
    ProposalLost,
    ProtocolError,
    ReentrantCall,
    StaleToken,
    StorageError,
    TransportError,
    Trimmed,
    UnsupportedCapability,
    UsageError,
    ValueTooLarge,
    WindowFull,
    WritesNotCopied,
    WritesUnconfirmed,
)
from paxodin.models import (
    Accept,
    Accepted,
    BatchPhase,
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
    NodeId,
    NodeOptions,
    NodeState,
    Prepare,
    PrepareScope,
    Profile,
    Promise,
    PromiseRange,
    Receipt,
    Role,
    ServeRange,
    SessionOptions,
    Slot,
    StopSign,
    WriteKind,
    WriteRecord,
)
from paxodin.node import AbandonedWritesWarning, Node, PendingBatch
from paxodin.protocols import Clock, History, Journal, Transport
from paxodin.session import (
    DEFAULT_ELECTION_TIMEOUT,
    DEFAULT_HEARTBEAT_INTERVAL,
    DEFAULT_RESEND_INTERVAL,
    DEFAULT_TICK_INTERVAL,
    Session,
)
from paxodin.storage import FileHistory, FileJournal, MemoryHistory, MemoryJournal

__version__ = "0.1.0.dev0"


def abi_version() -> int:
    """Return the C ABI version this package and its native library agree on.

    Returns:
        The ABI version. A library reporting anything else is rejected at import
        rather than allowed to misinterpret a struct.
    """
    return EXPECTED_ABI_VERSION


def profile() -> Profile:
    """Return the capacity profile the native library was compiled with.

    Returns:
        The compiled capacities, the measured static footprint of one node and
        one effects batch, and a fingerprint identifying the profile in journal
        headers and peer handshakes.
    """
    return _decode_profile(PROFILE)


__all__ = [
    "DEFAULT_ELECTION_TIMEOUT",
    "DEFAULT_HEARTBEAT_INTERVAL",
    "DEFAULT_RESEND_INTERVAL",
    "DEFAULT_TICK_INTERVAL",
    "AbandonedBatch",
    "AbandonedWritesWarning",
    "Accept",
    "Accepted",
    "AsyncSession",
    "AsyncTransport",
    "BatchError",
    "BatchFinished",
    "BatchPending",
    "BatchPhase",
    "CellState",
    "Clock",
    "Commit",
    "CommitTimeout",
    "Committed",
    "ConfigurationMismatch",
    "EntryKind",
    "Envelope",
    "FileHistory",
    "FileJournal",
    "ForeignToken",
    "ForkedHandle",
    "HandleClosed",
    "Heartbeat",
    "History",
    "InvalidArgument",
    "InvalidTimeout",
    "Journal",
    "JournalCorrupt",
    "JournalNotOpen",
    "Learn",
    "LogEntry",
    "LogSealed",
    "MemoryHistory",
    "MemoryJournal",
    "Message",
    "MessageKind",
    "Nack",
    "NoBatch",
    "Node",
    "NodeId",
    "NodeOptions",
    "NodeState",
    "NotLeader",
    "PaxodinError",
    "PendingBatch",
    "Prepare",
    "PrepareScope",
    "Profile",
    "Promise",
    "PromiseRange",
    "ProposalLost",
    "ProtocolError",
    "Receipt",
    "ReentrantCall",
    "Role",
    "ServeRange",
    "Session",
    "SessionOptions",
    "Slot",
    "StaleToken",
    "StopSign",
    "StorageError",
    "Transport",
    "TransportError",
    "Trimmed",
    "UnsupportedCapability",
    "UsageError",
    "ValueTooLarge",
    "WindowFull",
    "WriteKind",
    "WriteRecord",
    "WritesNotCopied",
    "WritesUnconfirmed",
    "__version__",
    "abi_version",
    "capabilities",
    "core_version",
    "explain",
    "profile",
    "status_count",
]
