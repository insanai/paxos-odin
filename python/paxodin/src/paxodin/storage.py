"""Reference storage adapters.

These are hosts, not library internals. They live here the way
``examples/counter.odin`` and ``bench/durable.odin`` live outside the Odin
``src/``: useful, replaceable, and deliberately not the only way to satisfy the
:class:`~paxodin.protocols.Journal` contract.

:class:`FileJournal` is the durable one. :class:`MemoryJournal` is for tests and
examples and says so loudly -- it survives nothing.
"""

from __future__ import annotations

import os
import struct
import sys
import zlib

if sys.platform != "win32":
    import fcntl
from pathlib import Path
from typing import TYPE_CHECKING, Final

from paxodin import _native
from paxodin.errors import InvalidArgument, JournalCorrupt, JournalNotOpen, StorageError
from paxodin.models import EntryKind, LogEntry, WriteKind, WriteRecord

if TYPE_CHECKING:
    import io
    from collections.abc import Sequence

    from paxodin.models import Slot

_JOURNAL_MAGIC: Final = b"PXDJ"
_JOURNAL_FORMAT: Final = 1

_HEADER: Final = struct.Struct(">4sHHQQ")
_RECORD_PREFIX: Final = struct.Struct(">II")
_RECORD_BODY: Final = struct.Struct(">BBBBQQQQI")
_HISTORY_PREFIX: Final = struct.Struct(">QBI")


def _encode_record(record: WriteRecord) -> bytes:
    """Serialise one durable record, value included.

    The value travels inline, never by reference: replay folds each record by
    dereferencing its value, so a journal that stored a pointer to somewhere
    else could not be replayed at all.
    """
    body = record.entry.body
    payload = (
        _RECORD_BODY.pack(
            int(record.kind),
            1 if record.requires_barrier else 0,
            int(record.entry.kind),
            0,
            record.ballot,
            record.slot,
            record.trim_id,
            record.trim_slot,
            len(body),
        )
        + body
    )
    return _RECORD_PREFIX.pack(len(payload), zlib.crc32(payload)) + payload


def _decode_record(payload: bytes) -> WriteRecord:
    """Rebuild one durable record from its payload."""
    (kind, barrier, entry_kind, _pad, ballot, slot, trim_id, trim_slot, length) = (
        _RECORD_BODY.unpack_from(payload)
    )
    body = payload[_RECORD_BODY.size : _RECORD_BODY.size + length]
    return WriteRecord(
        kind=WriteKind(kind),
        ballot=ballot,
        slot=slot,
        trim_id=trim_id,
        trim_slot=trim_slot,
        entry=LogEntry(kind=EntryKind(entry_kind), body=body),
        requires_barrier=bool(barrier),
    )


class MemoryJournal:
    """A journal that keeps records in memory.

    Warning:
        This is **not durable**. It exists for tests and in-process examples. A
        process that exits loses everything it held, so a node backed by one can
        never be restarted -- use :class:`FileJournal` for anything real.
    """

    __slots__ = ("_records", "_synced")

    def __init__(self) -> None:
        """Create an empty, non-durable journal."""
        self._records: list[WriteRecord] = []
        self._synced = 0

    def open(self, *, node_id: int, configuration_id: int) -> None:
        """Accept any identity; there is no storage to bind it to.

        Args:
            node_id: Ignored.
            configuration_id: Ignored.
        """
        del node_id, configuration_id

    def append(self, records: Sequence[WriteRecord]) -> None:
        """Append records in order.

        Args:
            records: The batch, in the order the core produced it.
        """
        self._records.extend(records)

    def sync(self) -> None:
        """Mark everything appended as "durable", which here means nothing."""
        self._synced = len(self._records)

    def replay(self) -> Sequence[WriteRecord]:
        """Return every record synced so far.

        Returns:
            The records, in append order. Anything appended but never synced is
            excluded, mirroring what a crash would have left behind.
        """
        return list(self._records[: self._synced])

    def close(self) -> None:
        """Drop the records."""
        self._records.clear()
        self._synced = 0


class FileJournal:
    """A durable, checksummed, append-only journal in one node directory.

    The directory is locked exclusively for the journal's lifetime, so two
    processes cannot both believe they are the same node. The header binds the
    file to a node identity, a configuration and a capacity profile: opening it
    as a different node, or with a differently sized build, is refused rather
    than silently misread.

    Recovery distinguishes two things that look alike. A trailing record that is
    demonstrably incomplete is a torn tail from a crash mid-write, and is
    discarded. A *complete* record whose checksum fails is corruption, and stops
    recovery with the offset -- because skipping it would silently drop a
    promise or a vote that a peer already acted on.
    """

    __slots__ = ("_base", "_file", "_lock_fd", "_path", "_synced")

    def __init__(self, directory: str | os.PathLike[str]) -> None:
        """Name a node's journal directory. Nothing is touched until :meth:`open`.

        Args:
            directory: The node's own directory. Created on open if absent.
        """
        self._base = Path(directory)
        self._path = self._base / "journal.bin"
        self._file: io.BufferedRandom | None = None
        self._lock_fd = -1
        self._synced = True

    def open(self, *, node_id: int, configuration_id: int) -> None:
        """Claim the directory and validate or write the header.

        Args:
            node_id: This member's identity, bound into the header.
            configuration_id: The configuration, bound into the header.

        Raises:
            StorageError: If the directory is already locked by another process.
            InvalidArgument: If the header names a different node, configuration
                or capacity profile.
            JournalCorrupt: If the header itself is unreadable.
        """
        if self._file is not None:
            return
        self._base.mkdir(parents=True, exist_ok=True)
        self._lock_fd = self._acquire_lock(self._base / "journal.lock")
        try:
            self._open(node_id, configuration_id)
        except BaseException:
            os.close(self._lock_fd)
            self._lock_fd = -1
            raise

    def _live(self) -> io.BufferedRandom:
        """Return the open file, refusing use before :meth:`open`."""
        if self._file is None:
            raise JournalNotOpen(self._path)
        return self._file

    @staticmethod
    def _acquire_lock(path: Path) -> int:
        """Take an exclusive lock on the node directory.

        Args:
            path: The lock file.

        Returns:
            The open descriptor holding the lock.

        Raises:
            StorageError: If another process already holds it.
        """
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
        if sys.platform == "win32":  # pragma: no cover - no flock there
            return descriptor
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(descriptor)
            message = (
                f"another process holds the node directory lock at {path}.\n"
                "Hint: one node per directory. Two processes sharing a journal "
                "would each believe they are the same member and could vote "
                "differently for one slot."
            )
            raise StorageError(message) from exc
        return descriptor

    def _open(self, node_id: int, configuration_id: int) -> None:
        """Open the journal file and validate or write its header."""
        exists = self._path.exists() and self._path.stat().st_size > 0
        self._file = self._path.open("r+b" if exists else "w+b")
        if exists:
            self._check_header(node_id, configuration_id)
            self._file.seek(0, os.SEEK_END)
            return
        self._file.write(
            _HEADER.pack(
                _JOURNAL_MAGIC,
                _JOURNAL_FORMAT,
                node_id,
                configuration_id,
                _native.PROFILE.fingerprint,
            )
        )
        self._file.flush()
        os.fsync(self._file.fileno())

    def _check_header(self, node_id: int, configuration_id: int) -> None:
        """Refuse a journal that belongs to a different node or build."""
        file = self._live()
        file.seek(0)
        raw = file.read(_HEADER.size)
        if len(raw) != _HEADER.size:
            message = f"{self._path} is too short to hold a journal header."
            raise JournalCorrupt(message)
        magic, fmt, stored_node, stored_config, fingerprint = _HEADER.unpack(raw)
        if magic != _JOURNAL_MAGIC:
            message = f"{self._path} is not a paxodin journal."
            raise JournalCorrupt(message)
        if fmt != _JOURNAL_FORMAT:
            raise InvalidArgument(format_version=fmt, supported=_JOURNAL_FORMAT)
        if stored_node != node_id:
            # Adopting another node's journal would import its promises as ours.
            raise InvalidArgument(journal_node_id=stored_node, opened_as=node_id)
        if stored_config != configuration_id:
            raise InvalidArgument(journal_configuration=stored_config, opened_as=configuration_id)
        if fingerprint != _native.PROFILE.fingerprint:
            raise InvalidArgument(
                journal_profile=fingerprint, local_profile=_native.PROFILE.fingerprint
            )

    def append(self, records: Sequence[WriteRecord]) -> None:
        """Append records in order.

        Args:
            records: The batch, in the order the core produced it.

        Raises:
            StorageError: If the write fails. Persistence is then uncertain and
                the caller must replay rather than confirm.
        """
        if not records:
            return
        file = self._live()
        try:
            file.write(b"".join(_encode_record(record) for record in records))
        except OSError as exc:
            message = (
                f"could not append to {self._path}: {exc}.\n"
                "Hint: progress has stopped with persistence uncertain. Reopen "
                "the node and replay its journal; never confirm these writes."
            )
            raise StorageError(message) from exc
        self._synced = False

    def sync(self) -> None:
        """Flush and fsync, making every appended record durable.

        Raises:
            StorageError: If durability could not be established.
        """
        if self._synced or self._file is None:
            return
        try:
            self._file.flush()
            os.fsync(self._file.fileno())
        except OSError as exc:
            message = (
                f"could not sync {self._path}: {exc}.\n"
                "Hint: treat these writes as never having landed. Reopen the "
                "node and replay its journal."
            )
            raise StorageError(message) from exc
        self._synced = True

    def replay(self) -> Sequence[WriteRecord]:
        """Return every intact record, in append order.

        Returns:
            The records needed to rebuild the node.

        Raises:
            JournalCorrupt: If a complete record fails its checksum. The offset
                is reported; recovery stops rather than skipping it.
        """
        file = self._live()
        file.seek(_HEADER.size)
        blob = file.read()
        records: list[WriteRecord] = []
        offset = 0
        while offset < len(blob):
            if offset + _RECORD_PREFIX.size > len(blob):
                break  # torn tail: the length itself never landed
            length, checksum = _RECORD_PREFIX.unpack_from(blob, offset)
            start = offset + _RECORD_PREFIX.size
            if start + length > len(blob):
                break  # torn tail: the payload is short
            payload = blob[start : start + length]
            if zlib.crc32(payload) != checksum:
                absolute = _HEADER.size + offset
                message = (
                    f"checksum failure in a complete record at offset {absolute} "
                    f"of {self._path}.\n"
                    "Hint: this is corruption, not a truncated tail. Restore this "
                    "node's directory from a backup or rebuild it from a peer. "
                    "Never skip an interior record."
                )
                raise JournalCorrupt(message, offset=absolute)
            records.append(_decode_record(payload))
            offset = start + length
        file.seek(0, os.SEEK_END)
        return records

    def close(self) -> None:
        """Sync, release the lock, and close the file. Safe before open."""
        if self._file is None:
            return
        try:
            self.sync()
        finally:
            self._file.close()
            self._file = None
            if self._lock_fd >= 0:
                os.close(self._lock_fd)
                self._lock_fd = -1


class MemoryHistory:
    """Retained history kept in memory, for tests and in-process examples.

    Warning:
        Not durable. A node backed by one cannot serve catch-up after a restart.
    """

    __slots__ = ("_cursor", "_entries")

    def __init__(self) -> None:
        """Create empty history."""
        self._entries: dict[int, tuple[bytes, int]] = {}
        self._cursor = 0

    def record(self, slot: Slot, payload: bytes, kind: int) -> None:
        """Retain one released entry.

        Args:
            slot: Its position in the log.
            payload: Its bytes.
            kind: Its entry kind.
        """
        self._entries[slot] = (payload, kind)
        while self._cursor + 1 in self._entries:
            self._cursor += 1

    def read(self, first: Slot, count: int) -> Sequence[tuple[Slot, bytes, int]]:
        """Return retained entries for a catch-up peer.

        Args:
            first: The first slot wanted.
            count: How many to return at most.

        Returns:
            ``(slot, payload, kind)`` triples, in slot order.
        """
        out: list[tuple[Slot, bytes, int]] = []
        for slot in range(first, first + count):
            found = self._entries.get(slot)
            if found is not None:
                out.append((slot, found[0], found[1]))
        return out

    def cursor(self) -> Slot:
        """Return the contiguous prefix retained.

        Returns:
            The last slot retained with no gap before it, or zero.
        """
        return self._cursor

    def close(self) -> None:
        """Drop the retained entries."""
        self._entries.clear()
        self._cursor = 0


class FileHistory:
    """Durable retained history in one append-only file.

    Advancing the node's memory floor hands an entry over to the host. This is
    where it lands, so a restarted member can still answer a catch-up peer for
    slots its bounded window let go.

    V1 never trims this file. Bounded memory is not bounded disk, and saying so
    plainly is better than a compaction scheme with no trim-anchor contract
    behind it.
    """

    __slots__ = ("_cursor", "_file", "_index", "_path", "_synced")

    def __init__(self, directory: str | os.PathLike[str]) -> None:
        """Open or create the history file.

        Args:
            directory: The node's own directory. Created if absent.
        """
        base = Path(directory)
        base.mkdir(parents=True, exist_ok=True)
        self._path = base / "history.bin"
        exists = self._path.exists()
        self._file = self._path.open("r+b" if exists else "w+b")
        self._index: dict[int, tuple[bytes, int]] = {}
        self._cursor = 0
        self._synced = True
        if exists:
            self._load()

    def _load(self) -> None:
        """Rebuild the index from the file, discarding a torn tail."""
        self._file.seek(0)
        blob = self._file.read()
        offset = 0
        while offset + _HISTORY_PREFIX.size <= len(blob):
            slot, kind, length = _HISTORY_PREFIX.unpack_from(blob, offset)
            start = offset + _HISTORY_PREFIX.size
            if start + length > len(blob):
                break
            self._index[slot] = (blob[start : start + length], kind)
            offset = start + length
        while self._cursor + 1 in self._index:
            self._cursor += 1
        self._file.seek(0, os.SEEK_END)

    def record(self, slot: Slot, payload: bytes, kind: int) -> None:
        """Durably retain one released entry.

        Args:
            slot: Its position in the log.
            payload: Its bytes.
            kind: Its entry kind.

        Raises:
            StorageError: If the write fails.
        """
        if slot in self._index:
            return
        try:
            self._file.write(_HISTORY_PREFIX.pack(slot, kind, len(payload)) + payload)
            self._file.flush()
            os.fsync(self._file.fileno())
        except OSError as exc:
            message = (
                f"could not retain slot {slot} in {self._path}: {exc}.\n"
                "Hint: the node's memory floor must not advance past an entry "
                "this host cannot hold. Stop admitting work until storage "
                "recovers."
            )
            raise StorageError(message) from exc
        self._index[slot] = (payload, kind)
        while self._cursor + 1 in self._index:
            self._cursor += 1

    def read(self, first: Slot, count: int) -> Sequence[tuple[Slot, bytes, int]]:
        """Return retained entries for a catch-up peer.

        Args:
            first: The first slot wanted.
            count: How many to return at most.

        Returns:
            ``(slot, payload, kind)`` triples, in slot order.
        """
        out: list[tuple[Slot, bytes, int]] = []
        for slot in range(first, first + count):
            found = self._index.get(slot)
            if found is not None:
                out.append((slot, found[0], found[1]))
        return out

    def cursor(self) -> Slot:
        """Return the contiguous prefix durably retained.

        Returns:
            The last slot retained with no gap before it, or zero.
        """
        return self._cursor

    def close(self) -> None:
        """Close the history file."""
        self._file.close()
