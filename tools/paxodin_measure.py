#!/usr/bin/env python3
"""Matched four-path measurement for the paxodin SDK.

Runs one workload through native Odin, the raw C ABI, the typed Python `Node`,
and the durable `Session`, with the member count, payload, capacities and
completion rule held equal. Transition-only work and full durable host work are
measured separately, because comparing a Python fsync against a native in-memory
transition would say nothing.

Counts alongside the timings: boundary crossings, bytes copied across the ABI,
and sync calls. Instruction-level attribution is not attempted here; that is what
the Valgrind drivers in tools/matched_profile.py are for.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'python' / 'paxodin'
ODIN = os.environ.get('ODIN', 'odin')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iterations', type=int, default=20000)
parser.add_argument('--samples', type=int, default=9)
parser.add_argument('--payloads', default='8,64,1024')
parser.add_argument('--output', default='')
parser.add_argument('--smoke', action='store_true', help='one sample, small run')
args = parser.parse_args()
if args.smoke:
    args.samples, args.iterations = 1, 2000
PAYLOADS = tuple(int(value) for value in args.payloads.split(','))


def run(command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, timeout=1800, **options)


def cpu_model():
    try:
        for line in Path('/proc/cpuinfo').read_text().splitlines():
            if line.startswith('model name'):
                return line.split(':', 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or 'unknown'


def git(*arguments):
    result = subprocess.run(['git', '-C', str(ROOT), *arguments], capture_output=True, text=True)
    return result.stdout.strip()


def fingerprint(paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def bootstrap_ratio(fast, slow, rounds=4000):
    """Paired bootstrap of median(slow)/median(fast), reported with a 95% interval."""
    prng = random.Random(1729)
    ratios = []
    pairs = list(zip(fast, slow))
    for _ in range(rounds):
        sample = [pairs[prng.randrange(len(pairs))] for _ in pairs]
        left = statistics.median(value[0] for value in sample)
        right = statistics.median(value[1] for value in sample)
        if left > 0:
            ratios.append(right / left)
    ratios.sort()
    low = ratios[int(0.025 * len(ratios))]
    high = ratios[int(0.975 * len(ratios))]
    return statistics.median(ratios), low, high


NATIVE_BINARY = ROOT / 'bin' / 'paxodin-native-bench'
PYTHON_DRIVER = ROOT / 'tools' / 'paxodin_paths.py'


def build_native():
    NATIVE_BINARY.parent.mkdir(parents=True, exist_ok=True)
    run([ODIN, 'build', 'tools/paxodin_native_bench.odin', '-file', f'-collection:paxos={ROOT}',
         '-o:speed', '-no-bounds-check', '-microarch:x86-64-v2', f'-out:{NATIVE_BINARY}'],
        capture_output=True)


def sample_native(iterations, payload):
    output = run([str(NATIVE_BINARY), str(iterations), str(payload)], capture_output=True, text=True)
    return json.loads(output.stdout.strip().splitlines()[-1])


def sample_python(path, iterations, payload):
    output = subprocess.run(
        ['uv', 'run', '--quiet', 'python', str(PYTHON_DRIVER), path, str(iterations), str(payload)],
        cwd=PROJECT, check=True, capture_output=True, text=True, timeout=1800)
    return json.loads(output.stdout.strip().splitlines()[-1])


PATHS = ('native', 'abi', 'node', 'session_memory', 'session_durable')

build_native()
sources = [*(ROOT / 'src').glob('*.odin'), *(PROJECT / 'native').glob('*.odin'),
           *(PROJECT / 'src' / 'paxodin').glob('*.py'),
           ROOT / 'tools' / 'paxodin_native_bench.odin', PYTHON_DRIVER]

report = {
    'meta': {
        'date': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'host': platform.node(),
        'cpu_model': cpu_model(),
        'os': f'{platform.system()} {platform.release()}',
        'python': sys.version.split()[0],
        'odin': run([ODIN, 'version'], capture_output=True, text=True).stdout.strip(),
        'git': git('rev-parse', '--short', 'HEAD'),
        'git_dirty': bool(git('status', '--porcelain')),
        'source_sha256': fingerprint(sources),
        'iterations': args.iterations,
        'samples': args.samples,
        'odin_build': '-o:speed -no-bounds-check -microarch:x86-64-v2',
        'workload': 'single member, one value per transition, full batch lifecycle',
        'note': ('Transition-only paths (native, abi, node) perform no storage and no '
                 'network. session_memory adds owned Python objects, framing and an '
                 'in-memory journal; session_durable adds fsync per batch. The paths are '
                 'therefore not interchangeable and only same-path comparisons are valid.'),
        'commands': [
            f'{ODIN} build tools/paxodin_native_bench.odin -file -collection:paxos=. '
            f'-o:speed -no-bounds-check -microarch:x86-64-v2',
            'uv run python tools/paxodin_paths.py <path> <iterations> <payload>',
        ],
    },
    'runs': [],
}

for payload in PAYLOADS:
    collected = {}
    for path in PATHS:
        timings = []
        detail = {}
        for _ in range(args.samples):
            record = (sample_native(args.iterations, payload) if path == 'native'
                      else sample_python(path, args.iterations, payload))
            timings.append(record['ns_per_value'])
            detail = record
        collected[path] = timings
        report['runs'].append({
            'path': path,
            'payload_bytes': payload,
            'iterations': args.iterations,
            'samples_ns_per_value': timings,
            'ns_per_value_median': statistics.median(timings),
            'ffi_calls_per_value': detail.get('ffi_calls_per_value'),
            'bytes_copied_per_value': detail.get('bytes_copied_per_value'),
            'syncs_per_value': detail.get('syncs_per_value'),
            'released': detail.get('released'),
            'validated': detail.get('validated', False),
        })
        print(f'{path:16} payload={payload:5} median={statistics.median(timings):10.1f} ns/value',
              flush=True)
    for path in PATHS[1:]:
        ratio, low, high = bootstrap_ratio(collected['native'], collected[path])
        report.setdefault('ratios', []).append({
            'payload_bytes': payload, 'path': path, 'versus': 'native',
            'median_ratio': ratio, 'ci95_low': low, 'ci95_high': high,
        })
        print(f'  {path:14} is {ratio:6.2f}x native (95% CI {low:.2f}-{high:.2f})', flush=True)

destination = Path(args.output) if args.output else (
    ROOT / 'bench' / 'results' / f'paxodin-paths-{time.strftime("%Y%m%d")}.json')
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(report, indent=2) + '\n')
print(f'\nWrote {destination.relative_to(ROOT)}')
