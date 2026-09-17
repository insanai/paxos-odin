"""The reference journal: durability, locking, torn tails and corruption."""

import pytest

from paxodin import errors
from paxodin.models import EntryKind, LogEntry, WriteKind, WriteRecord
from paxodin.storage import FileJournal, MemoryJournal


def opened(directory, node_id=1, configuration_id=1):
    """A journal bound to an identity, the way a Session binds it."""
    journal = FileJournal(directory)
    journal.open(node_id=node_id, configuration_id=configuration_id)
    return journal


def record(slot=1, payload=b"value", kind=WriteKind.VOTE):
    return WriteRecord(
        kind=kind,
        ballot=16777217,
        slot=slot,
        trim_id=0,
        trim_slot=0,
        entry=LogEntry(EntryKind.COMMAND, payload),
        requires_barrier=kind in (WriteKind.PROMISE, WriteKind.PROMISE_AT, WriteKind.VOTE),
    )


def test_memory_journal_replays_only_what_was_synced():
    journal = MemoryJournal()
    journal.append([record(1)])
    journal.sync()
    journal.append([record(2)])
    # Never synced, so a crash would not have kept it.
    assert [r.slot for r in journal.replay()] == [1]


def test_file_journal_round_trips_every_field(tmp_path):
    journal = opened(tmp_path, node_id=1, configuration_id=1)
    original = [record(1, b"first"), record(2, b"", WriteKind.CHOSEN), record(3, b"x" * 1024)]
    journal.append(original)
    journal.sync()
    journal.close()

    reopened = opened(tmp_path, node_id=1, configuration_id=1)
    assert list(reopened.replay()) == original
    reopened.close()


def test_the_value_travels_inline_so_replay_can_dereference_it(tmp_path):
    journal = opened(tmp_path, node_id=1, configuration_id=1)
    journal.append([record(1, b"inline-value")])
    journal.sync()
    journal.close()
    reopened = opened(tmp_path, node_id=1, configuration_id=1)
    assert reopened.replay()[0].entry.body == b"inline-value"
    reopened.close()


def test_a_torn_tail_is_discarded(tmp_path):
    journal = opened(tmp_path, node_id=1, configuration_id=1)
    journal.append([record(1, b"complete"), record(2, b"interrupted")])
    journal.sync()
    journal.close()

    path = tmp_path / "journal.bin"
    with path.open("r+b") as handle:
        handle.truncate(path.stat().st_size - 20)

    reopened = opened(tmp_path, node_id=1, configuration_id=1)
    # The first record is intact; the second never finished landing.
    assert [r.entry.body for r in reopened.replay()] == [b"complete"]
    reopened.close()


def test_a_corrupt_complete_record_stops_recovery(tmp_path):
    journal = opened(tmp_path, node_id=1, configuration_id=1)
    journal.append([record(1, b"first"), record(2, b"second")])
    journal.sync()
    journal.close()

    path = tmp_path / "journal.bin"
    blob = bytearray(path.read_bytes())
    blob[-3] ^= 0xFF  # flip a byte inside a complete record
    path.write_bytes(bytes(blob))

    reopened = opened(tmp_path, node_id=1, configuration_id=1)
    with pytest.raises(errors.JournalCorrupt) as caught:
        reopened.replay()
    # Skipping it would silently drop a promise a peer already acted on.
    assert "offset" in caught.value.context
    reopened.close()


def test_opening_as_another_node_is_refused(tmp_path):
    opened(tmp_path, node_id=1, configuration_id=1).close()
    with pytest.raises(errors.InvalidArgument):
        opened(tmp_path, node_id=2, configuration_id=1)


def test_opening_with_another_configuration_is_refused(tmp_path):
    opened(tmp_path, node_id=1, configuration_id=1).close()
    with pytest.raises(errors.InvalidArgument):
        opened(tmp_path, node_id=1, configuration_id=2)


def test_two_journals_cannot_hold_one_directory(tmp_path):
    first = opened(tmp_path, node_id=1, configuration_id=1)
    try:
        with pytest.raises(errors.StorageError):
            opened(tmp_path, node_id=1, configuration_id=1)
    finally:
        first.close()


def test_a_journal_refuses_use_before_open(tmp_path):
    journal = FileJournal(tmp_path)
    with pytest.raises(errors.StorageError):
        journal.append([record(1)])
    journal.close()  # closing an unopened journal is harmless


def test_an_empty_append_is_a_no_op(tmp_path):
    journal = opened(tmp_path, node_id=1, configuration_id=1)
    journal.append([])
    journal.sync()
    assert list(journal.replay()) == []
    journal.close()


def test_failed_open_releases_file_and_lock(tmp_path):
    opened(tmp_path, node_id=1, configuration_id=1).close()
    journal = FileJournal(tmp_path)
    with pytest.raises(errors.InvalidArgument):
        journal.open(node_id=2, configuration_id=1)
    journal.open(node_id=1, configuration_id=1)
    journal.close()
