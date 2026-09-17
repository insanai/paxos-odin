#!/usr/bin/env python3
"""Build portable release artifacts and check tag/version parity."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'python/paxodin'
DIST = ROOT / 'release-dist'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def version():
    value = tomllib.loads((PROJECT / 'pyproject.toml').read_text())['project']['version']
    core = re.search(r'VERSION :: "([^"]+)"', (ROOT / 'src/paxos.odin').read_text())[1]
    python = re.search(r'__version__ = "([^"]+)"', (PROJECT / 'src/paxodin/__init__.py').read_text())[1]
    cli_version = re.search(r'VERSION :: "([^"]+)"', (ROOT / "cli/main.odin").read_text())[1]
    assert value == core == python == cli_version, (value, core, python, cli_version)
    if os.environ.get('GITHUB_REF_TYPE') == 'tag':
        assert os.environ['GITHUB_REF_NAME'] == f'v{value}', 'tag must match package and core'
    return value


def cli(target):
    release = version()
    binary = 'paxodin.exe' if sys.platform == 'win32' else 'paxodin'
    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp) / f'paxodin-{release}-{target}'
        stage.mkdir()
        flags = ['-microarch:generic'] if target == 'macos-arm64' else ['-microarch:x86-64-v2']
        if sys.platform == 'darwin':
            flags += ['-minimum-os-version:12.0']
        run('odin', 'build', str(ROOT / 'cli'), '-o:speed', *flags, f'-out:{stage / binary}')
        output = run(str(stage / binary), '--version', capture_output=True, text=True, cwd=temp)
        assert output.stdout.strip() == f'paxodin {release}'
        run(str(stage / binary), '--help', cwd=temp)
        failure = subprocess.run([str(stage / binary), 'invalid-command'], capture_output=True)
        assert failure.returncode != 0 and b'Hint:' in failure.stderr
        for name in ('LICENSE', 'README.md'):
            shutil.copy2(ROOT / name, stage / name)
        kind = 'zip' if sys.platform == 'win32' else 'gztar'
        shutil.make_archive(str(DIST / stage.name), kind, temp, stage.name)


def wheel():
    version()
    # Rebuild from an sdist outside the checkout on every release platform.
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        run('uv', 'build', '--sdist', '--out-dir', str(work), cwd=PROJECT)
        sdist = next(work.glob('*.tar.gz'))
        with tarfile.open(sdist) as archive:
            archive.extractall(work, filter='data')
        source = next(p for p in work.iterdir() if p.is_dir())
        assert (source / 'native/core/src/paxos.odin').is_file()
        run('uv', 'build', '--wheel', '--out-dir', str(DIST), cwd=source)
        if sys.platform == 'linux':
            shutil.copy2(sdist, DIST / sdist.name)


def smoke():
    wheels = list(DIST.glob('*.whl'))
    assert len(wheels) == 1, wheels
    with zipfile.ZipFile(wheels[0]) as archive:
        names = archive.namelist()
        assert any('_paxodin.' in name for name in names)
        assert any(name.endswith('/py.typed') for name in names)
        assert not any('_paxodin_enforced' in name for name in names)
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        for py in ('3.12', '3.13', '3.14'):
            venv = work / py
            run('uv', 'venv', '--python', py, str(venv))
            exe = venv / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')
            run('uv', 'pip', 'install', '--python', str(exe), str(wheels[0]))
            # Explicitly isolate imports from the checkout and omit the compiler PATH.
            env = dict(os.environ, PATH=str(exe.parent))
            run(str(exe), '-I', str(ROOT / 'tools/release_smoke.py'), cwd=work, env=env)


def checksums():
    paths = sorted(p for p in DIST.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
    (DIST / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in paths
    ))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['version', 'cli', 'wheel', 'smoke', 'checksums'])
    parser.add_argument('--target')
    args = parser.parse_args()
    DIST.mkdir(exist_ok=True)
    if args.command == 'cli':
        cli(args.target)
    else:
        result = globals()[args.command]()
        if result:
            print(result)
