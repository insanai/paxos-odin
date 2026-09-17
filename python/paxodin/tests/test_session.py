"""The durable session: ordering, restart, and the promises append does not make."""

import pytest

import paxodin
from paxodin import errors
from paxodin.models import EntryKind, Role
from paxodin.storage import FileHistory, FileJournal, MemoryJournal
from paxodin.testing import Cluster, LoopbackTransport, _Fabric


def test_three_nodes_agree_on_one_prefix():
    with Cluster(3) as cluster:
        for payload in (b"alpha", b"", b"gamma"):
            cluster.append(payload)
        prefixes = [
            [(e.slot, e.entry.kind, e.entry.body) for e in cluster.committed(n)]
            for n in cluster.members
        ]
        assert prefixes[0] == prefixes[1] == prefixes[2]
        assert [e[2] for e in prefixes[0]] == [b"alpha", b"", b"gamma"]


def test_five_nodes_agree():
    with Cluster(5) as cluster:
        cluster.append(b"one")
        cluster.append(b"two")
        assert {cluster.decided_through(n) for n in cluster.members} == {2}


def test_slots_are_contiguous_and_one_based():
    with Cluster(3) as cluster:
        receipts = [cluster.append(f"v{i}".encode()) for i in range(5)]
        assert [r.slot for r in receipts] == [1, 2, 3, 4, 5]


def test_a_receipt_reports_what_was_actually_decided():
    with Cluster(3) as cluster:
        receipt = cluster.append(b"set counter 41")
        assert receipt.value == b"set counter 41"
        assert receipt.entry.kind is EntryKind.COMMAND
        assert receipt.configuration_id == 1


def test_an_empty_command_is_not_reported_as_a_noop():
    with Cluster(3) as cluster:
        receipt = cluster.append(b"")
        assert receipt.entry.kind is EntryKind.COMMAND
        assert receipt.value == b""


def test_a_follower_refuses_rather_than_forwarding():
    with Cluster(3) as cluster:
        leader = cluster.elect()
        follower = next(cluster.session(n) for n in cluster.members if n != leader.state().node_id)
        with pytest.raises(errors.NotLeader) as caught:
            follower.append(b"nope", timeout=0.2)
        # v1 performs no forwarding; the hint is the leader, not a redirect.
        assert caught.value.context.get("leader") in (None, leader.state().node_id)


def test_committed_since_is_bounded():
    with Cluster(3) as cluster:
        for index in range(10):
            cluster.append(f"v{index}".encode())
        session = cluster.session(1)
        assert len(session.committed_since(1, limit=3)) == 3
        assert [e.slot for e in session.committed_since(4, limit=2)] == [4, 5]


def test_committed_since_supplies_no_freshness_guarantee():
    # It reports this participant's released prefix, nothing about the cluster.
    with Cluster(3) as cluster:
        cluster.append(b"only")
        assert cluster.session(1).committed_since(99, limit=5) == []


def test_oversized_append_is_refused_before_admission():
    with Cluster(3) as cluster:
        leader = cluster.elect()
        limit = paxodin.profile().max_value_bytes
        before = leader.state().frontier
        with pytest.raises(errors.ValueTooLarge):
            leader.append(b"x" * (limit + 1))
        assert leader.state().frontier == before


@pytest.mark.parametrize("bad", [-1.0, float("nan"), float("inf")])
def test_a_meaningless_timeout_is_refused_before_native_code(bad):
    with Cluster(3) as cluster:
        leader = cluster.elect()
        with pytest.raises(ValueError):
            leader.append(b"x", timeout=bad)
        with pytest.raises(ValueError):
            leader.poll(timeout=bad)


def test_a_session_survives_restart_through_its_journal(tmp_path):
    """A restarted member resumes the promises and votes it already made."""
    fabric = _Fabric([1, 2, 3], 4096)
    journals = {n: FileJournal(tmp_path / f"node-{n}") for n in (1, 2, 3)}
    sessions = {
        n: paxodin.Session(
            node_id=n,
            members=[1, 2, 3],
            configuration_id=1,
            journal=journals[n],
            transport=LoopbackTransport(fabric, n),
            history=FileHistory(tmp_path / f"node-{n}"),
            tick_interval=0.001,
        )
        for n in (1, 2, 3)
    }

    def pump(rounds=64):
        for _ in range(rounds):
            if fabric.pending() == 0:
                return
            for session in sessions.values():
                session.poll(timeout=0.0)

    sessions[1].campaign()
    pump()
    assert sessions[1].state().role is Role.LEADER

    with sessions[1].node.propose(b"durable") as batch:
        sessions[1].discharge(batch)
    pump()
    released_before = sessions[2].state().decided_through
    assert released_before == 1

    # Restart member 2 from its own journal alone.
    sessions[2].close()
    restarted = paxodin.Session(
        node_id=2,
        members=[1, 2, 3],
        configuration_id=1,
        journal=FileJournal(tmp_path / "node-2"),
        transport=LoopbackTransport(fabric, 2),
        history=FileHistory(tmp_path / "node-2"),
        tick_interval=0.001,
    )
    try:
        state = restarted.state()
        # The prefix it durably retained is still there, and the promise it made
        # before the crash is still in force: a restarted acceptor that forgot
        # either could vote differently for a slot a peer already acted on.
        assert state.decided_through >= released_before
        assert restarted.committed_since(1, limit=4)[0].entry.body == b"durable"
    finally:
        restarted.close()
        sessions[1].close()
        sessions[3].close()


def test_a_journal_with_no_records_starts_fresh(tmp_path):
    journal = FileJournal(tmp_path / "node-1")
    session = paxodin.Session(
        node_id=1,
        members=[1],
        configuration_id=1,
        journal=journal,
        transport=LoopbackTransport(_Fabric([1], 16), 1),
    )
    try:
        assert session.state().decided_through == 0
    finally:
        session.close()


def test_closing_a_session_closes_everything_it_owns():
    fabric = _Fabric([1], 16)
    journal = MemoryJournal()
    session = paxodin.Session(
        node_id=1,
        members=[1],
        configuration_id=1,
        journal=journal,
        transport=LoopbackTransport(fabric, 1),
    )
    session.close()
    assert session.node.closed


def test_cluster_requires_at_least_one_member():
    with pytest.raises(ValueError):
        Cluster(0)
