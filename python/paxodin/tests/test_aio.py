"""The asyncio surface: no polling, one owner per transition, honest cancellation."""

import asyncio

import pytest

from paxodin import errors
from paxodin.aio import AsyncSession
from paxodin.models import EntryKind
from paxodin.storage import MemoryJournal
from paxodin.testing import AsyncCluster, AsyncFabric, AsyncLoopbackTransport


async def test_three_nodes_agree_without_anyone_polling():
    async with AsyncCluster(3) as cluster:
        receipts = [await cluster.append(v) for v in (b"alpha", b"", b"gamma")]
        assert [r.slot for r in receipts] == [1, 2, 3]
        await asyncio.sleep(0.05)  # let the followers absorb the last commit
        prefixes = [
            [(e.slot, e.entry.kind, e.entry.body) for e in cluster.session(n).entries()]
            for n in cluster.members
        ]
        assert prefixes[0] == prefixes[1] == prefixes[2]
        assert [p[2] for p in prefixes[0]] == [b"alpha", b"", b"gamma"]


async def test_concurrent_appends_get_distinct_contiguous_slots():
    async with AsyncCluster(3) as cluster:
        leader = await cluster.elect()
        receipts = await asyncio.gather(*(leader.append(f"v{i}".encode()) for i in range(12)))
        assert sorted(r.slot for r in receipts) == list(range(1, 13))
        for receipt in receipts:
            assert leader[receipt.slot].entry.body == receipt.value


async def test_a_follower_refuses_rather_than_forwarding():
    async with AsyncCluster(3) as cluster:
        leader = await cluster.elect()
        follower = next(cluster.session(n) for n in cluster.members if n != leader.node_id)
        with pytest.raises(errors.NotLeader):
            await follower.append(b"nope", timeout=0.2)


async def test_a_timeout_is_a_timeout_error_and_does_not_cancel_paxos():
    async with AsyncCluster(3) as cluster:
        leader = await cluster.elect()
        cluster.fabric.partitioned.add(leader.node_id)
        with pytest.raises(TimeoutError) as caught:
            await leader.append(b"stranded", timeout=0.05)
        assert isinstance(caught.value, errors.CommitTimeout)
        assert caught.value.context["admitted"] is True
        # The partition heals; the stranded proposal is still in flight and can
        # still be chosen -- nothing was cancelled.
        cluster.fabric.partitioned.discard(leader.node_id)
        follow_up = await leader.append(b"after", timeout=2.0)
        assert leader[1].entry.body == b"stranded"
        assert follow_up.slot == 2


async def test_cancelling_the_wait_leaves_the_proposal_standing():
    async with AsyncCluster(3) as cluster:
        leader = await cluster.elect()
        cluster.fabric.partitioned.add(leader.node_id)
        task = asyncio.create_task(leader.append(b"cancelled-wait", timeout=5.0))
        await asyncio.sleep(0.02)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        cluster.fabric.partitioned.discard(leader.node_id)
        await leader.append(b"next", timeout=2.0)
        assert leader[1].entry.body == b"cancelled-wait"


async def test_reads_are_synchronous_and_iterable():
    async with AsyncCluster(3) as cluster:
        for value in (b"a", b"b", b"c"):
            await cluster.append(value)
        leader = cluster.leader()
        assert leader is not None
        assert leader.last_committed == 3
        assert [e.entry.body for e in leader.entries(2)] == [b"b", b"c"]
        assert leader[1].entry.kind is EntryKind.COMMAND
        with pytest.raises(KeyError):
            leader[99]


async def test_close_stops_the_driver_tasks():
    fabric = AsyncFabric([1])
    session = AsyncSession(
        node_id=1,
        members=[1],
        configuration_id=1,
        journal=MemoryJournal(),
        transport=AsyncLoopbackTransport(fabric, 1),
    )
    await session.start()
    assert session._tasks
    await session.close()
    assert not session._tasks
    assert session.node.closed


async def test_a_meaningless_timeout_is_refused():
    async with AsyncCluster(3) as cluster:
        leader = await cluster.elect()
        with pytest.raises(ValueError):
            await leader.append(b"x", timeout=-1.0)
