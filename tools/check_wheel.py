#!/usr/bin/env python3
"""Build a wheel from the sdist outside the repository and smoke-test it.

An installed source distribution must not depend on the surrounding checkout, so
the wheel is built in a temporary directory with no path back to `src/`. The
resulting wheel is then installed into a clean environment with Odin removed from
PATH, because a wheel user never needs the compiler.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'python' / 'paxodin'
PYTHONS = ('3.12', '3.13', '3.14')

SMOKE = '''
import shutil, paxodin
from paxodin.testing import Cluster
assert shutil.which("odin") is None, "a wheel user must not need Odin"
with Cluster(3) as cluster:
    receipt = cluster.append(b"from a wheel")
    assert receipt.value == b"from a wheel"
    assert {cluster.decided_through(n) for n in cluster.members} == {1}
print(json.dumps({
    "package": paxodin.__version__,
    "core": paxodin.core_version(),
    "abi": paxodin.abi_version(),
    "fingerprint": paxodin.profile().fingerprint,
}))
'''


def run(command, **options):
    return subprocess.run(command, check=True, timeout=900, **options)


sdists = sorted((PROJECT / 'dist').glob('*.tar.gz'))
if not sdists:
    raise SystemExit('No sdist found.\nHint: run `uv build --sdist` in python/paxodin first.')
sdist = sdists[-1]

with tempfile.TemporaryDirectory(prefix='paxodin-wheel-') as work:
    work = Path(work)
    with tarfile.open(sdist) as archive:
        archive.extractall(work, filter='data')
    unpacked = next(path for path in work.iterdir() if path.is_dir())
    staged = unpacked / 'native' / 'core' / 'src' / 'paxos.odin'
    if not staged.is_file():
        raise SystemExit(f'The sdist does not carry the core at {staged}.\n'
                         'Hint: the sdist build hook must stage it; a wheel cannot reach ../../src.')
    assert not (unpacked.parents[1] / 'src' / 'paxos.odin').exists(), 'repo is reachable from the build dir'
    run(['uv', 'build', '--wheel', '--out-dir', str(work / 'wheels')], cwd=unpacked)
    wheel = next((work / 'wheels').glob('*.whl'))
    if wheel.name.endswith('-any.whl') or 'abi3' in wheel.name:
        raise SystemExit(f'{wheel.name} is not a platform wheel.\n'
                         'Hint: a ctypes library needs a platform tag, not `any` or `abi3`.')
    print(f'PASS wheel built from sdist outside the repository: {wheel.name}', flush=True)

    clean = dict(os.environ, PATH='/usr/bin:/bin')
    for version in PYTHONS:
        venv = work / f'venv-{version}'
        run(['uv', 'venv', '--python', version, str(venv)], capture_output=True)
        python = venv / 'bin' / 'python'
        run(['uv', 'pip', 'install', '--python', str(python), str(wheel)], capture_output=True)
        result = run([str(python), '-c', 'import json\n' + SMOKE], capture_output=True, text=True, env=clean)
        report = json.loads(result.stdout.strip().splitlines()[-1])
        print(f'PASS CPython {version}: paxodin {report["package"]}, core {report["core"]}, '
              f'ABI {report["abi"]}, three-node consensus', flush=True)

print('All wheel checks passed.')
