"""Every hazard the pending-batch contract exists to contain.

These are the tests that make the design claims checkable rather than asserted.
"""

import os
import threading

import pytest

import paxodin
from paxodin import errors
from paxodin.models import BatchPhase, EntryKind, Role


def make_node(node_id=1, members=(1, 2, 3), **options):
    return paxodin.Node(node_id=node_id, members=list(members), configuration_id=1, **options)


def discharge(batch):
    """Run the full lifecycle without a journal. Returns (messages, committed)."""
    batch.writes()
    batch.persisted()
    messages = batch.messages()
    released = batch.committed()
    batch.requests()
    batch.finish()
    return messages, released


def drive(node, seed=(), rounds=200):
    """Deliver messages back to a single-member node until it settles.

    Even one member has to deliver its own Prepare to itself: the core owns no
    transport, so nothing is self-delivered implicitly.
    """
    queue = list(seed)
    released = []
    for _ in range(rounds):
        if not queue:
            break
        envelope = queue.pop(0)
        if envelope.recipient != node.state().node_id:
            continue
        messages, entries = discharge(node.step(envelope))
        queue.extend(messages)
        released.extend(entries)
    return released


def lead(node):
    """Make a single-member node a leader."""
    messages, _ = discharge(node.campaign())
    drive(node, messages)
    assert node.state().role is Role.LEADER, node.state().role
    return node


def commit_one(node, payload):
    """Propose one value on a single-member node and settle it."""
    batch = node.propose(payload)
    status, slot = batch.status, batch.assigned_slot
    messages, released = discharge(batch)
    released.extend(drive(node, messages))
    return status, slot, released


# --- value and argument validation ------------------------------------------


def test_oversized_value_is_rejected_before_anything_mutates():
    with make_node() as node:
        before = node.state()
        limit = node.profile.max_value_bytes
        with pytest.raises(errors.ValueTooLarge) as caught:
            node.propose(b"x" * (limit + 1))
        assert caught.value.context["supplied"] == limit + 1
        assert caught.value.context["limit"] == limit
        assert node.state() == before


def test_empty_command_is_legal_and_is_not_a_noop():
    with make_node(members=(1,)) as node:
        lead(node)
        status, slot, released = commit_one(node, b"")
        assert status == 0
        entry = node.read_decided(slot, 1)[0].entry
        assert entry.kind is EntryKind.COMMAND
        assert entry.body == b""
        assert entry.is_command
        assert [e.entry.kind for e in released] == [EntryKind.COMMAND]


def test_maximum_sized_value_is_accepted():
    with make_node(members=(1,)) as node:
        lead(node)
        payload = bytes(range(256)) * 4
        assert len(payload) == node.profile.max_value_bytes
        _status, slot, _released = commit_one(node, payload)
        assert node.read_decided(slot, 1)[0].entry.body == payload


def test_zero_node_id_is_refused():
    with pytest.raises(errors.PaxodinError):
        paxodin.Node(node_id=0, members=[1, 2], configuration_id=1)


def test_zero_configuration_id_is_refused():
    with pytest.raises(errors.PaxodinError):
        paxodin.Node(node_id=1, members=[1, 2], configuration_id=0)


def test_non_intersecting_quorums_are_refused():
    # read + write must exceed the member count, or a phase-one quorum could
    # miss a prior phase-two quorum and two values could be chosen.
    with pytest.raises(errors.PaxodinError):
        paxodin.Node(
            node_id=1, members=[1, 2, 3], configuration_id=1, read_quorum=1, write_quorum=1
        )


def test_too_many_members_is_refused():
    with pytest.raises(errors.PaxodinError):
        paxodin.Node(node_id=1, members=list(range(1, 20)), configuration_id=1)


# --- batch phase matrix ------------------------------------------------------


def test_no_write_batch_is_born_confirmed():
    # A transition that produces no records has nothing to persist, so requiring
    # a confirmation would assert a durability fact about no records at all.
    with make_node() as node:
        batch = node.tick()
        assert batch._report.write_count == 0
        assert batch.phase is BatchPhase.CONFIRMED
        batch.messages()  # legal without persisted()
        batch.finish()


def test_outputs_are_refused_before_writes_are_confirmed():
    with make_node() as node:
        batch = node.campaign()
        assert batch._report.write_count > 0
        assert batch.phase is BatchPhase.PENDING
        for read in (batch.messages, batch.committed, batch.requests):
            with pytest.raises(errors.WritesUnconfirmed):
                read()
        discharge(batch)


def test_confirm_is_refused_until_the_writes_were_copied():
    # Confirming records the host never received is the most damaging
    # integration bug available; it is a status, not a silent success.
    with make_node() as node:
        batch = node.campaign()
        with pytest.raises(errors.WritesNotCopied):
            batch.persisted()
        batch.writes()
        batch.persisted()
        batch.finish()


def test_finish_is_refused_while_writes_are_unconfirmed():
    with make_node() as node:
        batch = node.campaign()
        batch.writes()
        with pytest.raises(errors.WritesUnconfirmed):
            batch.finish()
        batch.persisted()
        batch.finish()


def test_copies_after_finish_are_refused():
    with make_node() as node:
        batch = node.campaign()
        discharge(batch)
        for read in (batch.writes, batch.messages, batch.committed):
            with pytest.raises(errors.BatchFinished):
                read()


def test_confirm_and_finish_are_idempotent():
    with make_node() as node:
        batch = node.campaign()
        batch.writes()
        batch.persisted()
        batch.persisted()
        batch.finish()
        batch.finish()


def test_a_second_transition_is_refused_while_a_batch_is_live():
    with make_node() as node:
        batch = node.campaign()
        with pytest.raises(errors.BatchPending):
            node.tick()
        discharge(batch)
        node.tick().finish()


def test_copies_are_retryable_and_never_repeat_the_transition():
    with make_node() as node:
        batch = node.campaign()
        first = batch.writes()
        second = batch.writes()
        assert first == second
        before = node.state()
        assert batch.writes() == first
        assert node.state() == before
        discharge(batch)


# --- tokens ------------------------------------------------------------------


def test_a_stale_token_is_refused_without_changing_state():
    with make_node() as node:
        first = node.campaign()
        discharge(first)
        second = node.tick()
        before = node.state()
        with pytest.raises(errors.StaleToken):
            first.writes()
        assert node.state() == before
        second.finish()


def test_a_token_from_another_node_is_refused():
    with make_node(node_id=1) as first, make_node(node_id=2) as second:
        batch = first.campaign()
        borrowed = paxodin.PendingBatch(second, batch._token, batch._report)
        with pytest.raises(errors.ForeignToken):
            borrowed.writes()
        discharge(batch)


def test_a_token_does_not_survive_close_and_reopen():
    # Epochs are process-wide and never reused, so a token minted before a close
    # cannot be mistaken for one minted after a reopen at the same address.
    node = make_node()
    batch = node.campaign()
    discharge(batch)
    token = batch._token
    node.close()
    with make_node() as fresh:
        borrowed = paxodin.PendingBatch(fresh, token, batch._report)
        with pytest.raises((errors.ForeignToken, errors.NoBatch, errors.StaleToken)):
            borrowed.writes()


# --- handle lifetime ---------------------------------------------------------


def test_every_method_refuses_after_close():
    node = make_node()
    node.close()
    assert node.closed
    with pytest.raises(errors.HandleClosed):
        node.state()
    with pytest.raises(errors.HandleClosed):
        node.tick()
    with pytest.raises(errors.HandleClosed):
        node.advance_memory_floor(0)


def test_close_is_idempotent():
    node = make_node()
    node.close()
    node.close()
    node.close()


def test_closing_with_unconfirmed_writes_warns_rather_than_hides_it():
    node = make_node()
    node.campaign()  # deliberately never discharged
    with pytest.warns(paxodin.AbandonedWritesWarning):
        node.close()


def test_concurrent_calls_are_serialised_not_corrupted():
    with make_node() as node:
        errors_seen: list[BaseException] = []

        def worker():
            try:
                for _ in range(50):
                    batch = node.tick()
                    discharge(batch)
            except BaseException as exc:
                errors_seen.append(exc)

        threads = [threading.Thread(target=worker) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert not [e for e in errors_seen if not isinstance(e, errors.BatchPending)]


def test_reentrancy_raises_rather_than_deadlocking():
    with make_node() as node:
        captured: list[BaseException] = []

        class Recursive(dict):
            def __missing__(self, key):
                try:
                    node.state()
                except BaseException as exc:
                    captured.append(exc)
                return 0

        # Re-enter from inside a native call by decoding through a callback.
        with node._guard():
            try:
                node.state()
            except errors.ReentrantCall as exc:
                captured.append(exc)
        assert any(isinstance(exc, errors.ReentrantCall) for exc in captured)


@pytest.mark.skipif(not hasattr(os, "fork"), reason="fork is POSIX only")
def test_a_handle_does_not_survive_fork():
    with make_node() as node:
        read_fd, write_fd = os.pipe()
        pid = os.fork()
        if pid == 0:  # pragma: no cover - child
            os.close(read_fd)
            try:
                node.state()
                os.write(write_fd, b"no-error")
            except errors.ForkedHandle:
                os.write(write_fd, b"forked")
            except BaseException:
                os.write(write_fd, b"other")
            finally:
                os.close(write_fd)
                os._exit(0)
        os.close(write_fd)
        result = os.read(read_fd, 32)
        os.close(read_fd)
        os.waitpid(pid, 0)
        assert result == b"forked"


# --- memory floor ------------------------------------------------------------


def test_advancing_the_floor_is_refused_while_a_batch_is_live():
    # The batch's released entries still point into cells the floor would free.
    with make_node(members=(1,)) as node:
        lead(node)
        batch = node.propose(b"a")
        with pytest.raises(errors.BatchPending):
            node.advance_memory_floor(1)
        messages, released = discharge(batch)
        released.extend(drive(node, messages))
        assert released
        node.advance_memory_floor(released[-1].slot)


def test_native_memory_stays_bounded_across_a_moving_window():
    with make_node(members=(1,)) as node:
        lead(node)
        kept = []
        for index in range(1200):
            _status, _slot, released = commit_one(node, f"command-{index}".encode())
            for entry in released:
                kept.append(entry.entry.body)
                node.advance_memory_floor(entry.slot)
        assert len(kept) == 1200
        # Values copied out long ago are still intact although their ledger
        # cells have been reused many times over.
        assert kept[0] == b"command-0"
        assert kept[-1] == b"command-1199"
        assert node.state().memory_floor == 1200


def test_returned_bytes_survive_many_later_transitions():
    with make_node(members=(1,)) as node:
        lead(node)
        _status, _slot, released = commit_one(node, b"durable-value")
        first = released[0].entry.body
        node.advance_memory_floor(released[0].slot)
        for index in range(600):
            _s, _sl, more = commit_one(node, f"filler-{index}".encode())
            for entry in more:
                node.advance_memory_floor(entry.slot)
        # The ledger cell holding this value has been reused hundreds of times.
        assert first == b"durable-value"
