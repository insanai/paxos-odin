"""The example in POD 0011 and book Part IX, kept runnable.

The design record's own example is a promise about the API's shape. If it ever
stops running, the record is lying, so it is a test rather than an illustration.
"""

from paxodin import FileJournal, Session
from paxodin.testing import LoopbackTransport, _Fabric


def test_the_pod_example_runs_as_written(tmp_path):
    fabric = _Fabric([1, 2, 3], 4096)
    peers = {
        n: Session(
            node_id=n,
            members=[1, 2, 3],
            configuration_id=1,
            journal=FileJournal(tmp_path / f"node-{n}"),
            transport=LoopbackTransport(fabric, n),
            tick_interval=0.001,
        )
        for n in (2, 3)
    }
    transport = LoopbackTransport(fabric, 1)

    class Pumping:
        """While node 1 waits, its peers get a turn, as they would in a cluster."""

        now = 0.0

        def monotonic(self):
            return self.now

        def sleep(self, seconds):
            self.now += seconds
            for _ in range(64):
                if not fabric.pending():
                    break
                for peer in peers.values():
                    peer.poll(timeout=0.0)

    try:
        # --- verbatim from the record, plus the clock the record leaves implicit ---
        with Session(
            node_id=1,
            members=[1, 2, 3],
            configuration_id=1,
            journal=FileJournal(tmp_path / "node-1"),
            transport=transport,
            clock=Pumping(),
        ) as session:
            session.campaign()
            Pumping().sleep(0)
            receipt = session.append(b"set counter 41", timeout=5.0)
            assert (receipt.configuration_id, receipt.slot) == (1, 1)
            assert receipt.value == b"set counter 41"
    finally:
        for peer in peers.values():
            peer.close()
