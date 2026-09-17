"""A replicated counter across three in-process participants.

The Python mirror of ``examples/counter.odin``. Every command is a signed delta;
applying the log in order gives every member the same counter.

Run it with::

    uv run python examples/counter.py
"""

from __future__ import annotations

import struct

from paxodin import EntryKind
from paxodin.testing import Cluster

_DELTA = struct.Struct(">q")


def encode(delta: int) -> bytes:
    """Encode one counter command.

    Args:
        delta: How much to add.

    Returns:
        The command bytes.
    """
    return _DELTA.pack(delta)


def apply_log(cluster: Cluster, node_id: int) -> int:
    """Fold one member's released prefix into a counter.

    A no-op is a hole a leader filled during recovery, not a command. Folding it
    as if it were data is exactly the bug ``EntryKind`` exists to prevent.

    Args:
        cluster: The running cluster.
        node_id: Which member to read.

    Returns:
        That member's counter.
    """
    total = 0
    for entry in cluster.committed(node_id):
        if entry.entry.kind is EntryKind.COMMAND:
            total += _DELTA.unpack(entry.entry.body)[0]
    return total


def main() -> None:
    """Replicate three commands and show every member agreeing."""
    with Cluster(3) as cluster:
        leader = cluster.elect()
        print(f"node {leader.state().node_id} is the leader")

        for delta in (10, 25, -5):
            receipt = cluster.append(encode(delta))
            print(f"slot {receipt.slot}: {delta:+d} -> counter = {apply_log(cluster, 1)}")

        totals = {node: apply_log(cluster, node) for node in cluster.members}
        assert len(set(totals.values())) == 1, totals
        print(f"counter = {totals[1]} on all {len(totals)} nodes")


if __name__ == "__main__":
    main()
