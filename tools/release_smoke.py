"""Exercise an installed wheel without the checkout or Odin on PATH."""
from pathlib import Path
import shutil
import tempfile

import paxodin
from paxodin import FileJournal, StorageError
from paxodin.testing import Cluster

assert shutil.which('odin') is None
assert paxodin.__version__ == paxodin.core_version()
with Cluster(3) as cluster:
    receipt = cluster.append(b'packaged consensus')
    assert receipt.value == b'packaged consensus'
    assert {cluster.decided_through(n) for n in cluster.members} == {receipt.slot}
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp) / 'journal'
    first, second = FileJournal(path), FileJournal(path)
    first.open(node_id=1, configuration_id=1)
    try:
        try:
            second.open(node_id=1, configuration_id=1)
        except StorageError:
            pass
        else:
            raise AssertionError('the installed journal did not exclude another owner')
    finally:
        second.close()
        first.close()
    with_again = FileJournal(path)
    with_again.open(node_id=1, configuration_id=1)
    with_again.close()
print(f'PASS installed paxodin {paxodin.__version__}: consensus, lock and reopen')
