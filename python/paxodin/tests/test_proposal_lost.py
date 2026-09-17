"""A leader that loses its ballot mid-flight drops the command it admitted.

In single-leader mode there is no resubmission: `queue_resubmit` is reachable
only under rotating ownership. So if a leader's accepts never reach a quorum and
another member wins a higher ballot, recovery can choose a different value for the
slot the command was admitted to, and the command is gone with no protocol signal.

Reporting success for that would be a lie, which is why `append` compares the
decided entry against what it submitted. These tests force the situation rather
than reasoning about it.
"""

import pytest

import paxodin
from paxodin import errors
from paxodin.models import Role
from paxodin.storage import MemoryHistory, MemoryJournal
from paxodin.testing import LoopbackTransport, _Fabric


class Partitionable(LoopbackTransport):
    """A loopback transport that can be cut off, in one direction or both."""

    __slots__ = ("blocked",)

    def __init__(self, fabric, node_id, blocked):
        super().__init__(fabric, node_id)
        self.blocked = blocked

    def send(self, *, peer, frame):
        if self._node_id in self.blocked:
            return  # the frame is simply lost, as a partition loses it
        super().send(peer=peer, frame=frame)


def build(members=(1, 2, 3)):
    """Three sessions over one fabric, with a shared partition switch."""
    fabric = _Fabric(list(members), 8192)
    blocked: set[int] = set()
    sessions = {
        node: paxodin.Session(
            node_id=node,
            members=list(members),
            configuration_id=1,
            journal=MemoryJournal(),
            transport=Partitionable(fabric, node, blocked),
            history=MemoryHistory(),
            tick_interval=1e9,  # ticks are driven explicitly, never by wall time
        )
        for node in members
    }
    return fabric, blocked, sessions


def pump(fabric, sessions, rounds=200):
    for _ in range(rounds):
        if fabric.pending() == 0:
            return
        for session in sessions.values():
            session.poll(timeout=0.0)


def test_a_dropped_accept_lets_another_leader_take_the_slot():
    """The premise: the core really can decide another value in an admitted slot."""
    fabric, blocked, sessions = build()
    try:
        sessions[1].campaign()
        pump(fabric, sessions)
        assert sessions[1].state().role is Role.LEADER

        # Admit a command, then lose every frame the leader sends.
        with sessions[1].node.propose(b"lost-command") as batch:
            admitted = batch.assigned_slot
            assert batch.status == 0
            blocked.add(1)
            sessions[1].discharge(batch)
        pump(fabric, sessions)
        assert admitted == 1
        assert sessions[2].state().decided_through == 0

        # A survivor wins a higher ballot with the quorum that never saw the vote.
        sessions[2].campaign()
        pump(fabric, sessions)
        assert sessions[2].state().role is Role.LEADER
        with sessions[2].node.propose(b"winning-command") as batch:
            assert batch.assigned_slot == admitted
            sessions[2].discharge(batch)
        pump(fabric, sessions)

        # The slot is decided, and not with the command the first leader admitted.
        decided = sessions[2].committed_since(admitted, limit=1)
        assert decided[0].entry.body == b"winning-command"
        assert decided[0].entry.body != b"lost-command"
    finally:
        for session in sessions.values():
            session.close()


def test_append_raises_proposal_lost_rather_than_reporting_success():
    """The mechanism: append refuses to hand back a receipt for a lost command."""
    fabric, blocked, sessions = build()

    class Scripted:
        """A clock whose sleeps stage the takeover, then heal the partition.

        The leader is cut off *before* it admits anything, so its accepts never
        reach a quorum. That is the only way the slot stays open for someone else.
        """

        def __init__(self):
            self.now = 0.0
            self.stage = 0

        def monotonic(self):
            return self.now

        def sleep(self, seconds):
            self.now += max(seconds, 1e-6)
            self.stage += 1
            if self.stage == 1:
                sessions[2].campaign()
                pump(fabric, sessions)
                with sessions[2].node.propose(b"winning-command") as batch:
                    sessions[2].discharge(batch)
                pump(fabric, sessions)
            elif self.stage == 2:
                blocked.discard(1)
                # Nothing pushes the truth at a rejoining member; it has to ask.
                with sessions[1].node.request_catch_up(2, 1) as batch:
                    sessions[1].discharge(batch)
                pump(fabric, sessions)
            else:
                pump(fabric, sessions)

    try:
        sessions[1].campaign()
        pump(fabric, sessions)
        assert sessions[1].state().role is Role.LEADER

        blocked.add(1)  # cut off before anything is admitted
        sessions[1]._clock = Scripted()

        with pytest.raises(errors.ProposalLost) as caught:
            sessions[1].append(b"lost-command", timeout=30.0)

        assert caught.value.context["slot"] == 1
        # The message must say the command was never chosen, not merely delayed.
        assert "different value" in str(caught.value)
        assert "command id" in caught.value.hint
        # And the slot really does hold the other member's command.
        assert sessions[1].committed_since(1, limit=1)[0].entry.body == b"winning-command"
    finally:
        for session in sessions.values():
            session.close()


def test_a_timeout_is_not_a_cancellation():
    """CommitTimeout reports that the wait ended, never that Paxos was stopped."""
    fabric, blocked, sessions = build()
    try:
        sessions[1].campaign()
        pump(fabric, sessions)
        blocked.add(1)  # nothing this leader sends will ever arrive
        with pytest.raises(errors.CommitTimeout) as caught:
            sessions[1].append(b"never-observed", timeout=0.05)
        assert caught.value.context["admitted"] is True
        assert "does not cancel" in caught.value.hint
    finally:
        for session in sessions.values():
            session.close()
