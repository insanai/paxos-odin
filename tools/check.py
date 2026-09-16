#!/usr/bin/env python3
"""Repeatable verification of the Odin library; requires Odin and Python 3.

Runs, in a temporary directory so stale binaries can never mask a failure:
style (the Zen constraints, vet, strict style), unit tests in debug and optimized builds,
compiler and durability contracts, seeded fault simulations, the counter example,
the benchmark JSON contract, and CLI failure propagation.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ODIN = os.environ.get('ODIN', 'odin')
PACKAGES = ('tests', 'sim', 'bench', 'cli')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seeds', type=int, default=20)
parser.add_argument('--steps', type=int, default=10000)
args = parser.parse_args()
if args.seeds < 1 or args.steps < 1:
    parser.error('seeds and steps must be positive')


def run(command, **options):
    return subprocess.run(command, cwd=ROOT, check=True, timeout=600, **options)


def check_style():
    run([sys.executable, 'tools/check_style.py'])
    # The library is fully parametric, so its bodies are checked through the packages that instantiate it.
    for package in PACKAGES:
        flags = ['-no-entry-point'] if package == 'tests' else []
        run([ODIN, 'check', package, '-vet', '-strict-style', *flags])
    run([ODIN, 'check', 'examples/counter.odin', '-file', '-vet', '-strict-style'])
    print('PASS style: Zen constraints, vet, strict style', flush=True)


with tempfile.TemporaryDirectory(prefix='paxos-check-') as work:
    work = Path(work)
    run([ODIN, 'version'])
    check_style()
    for profile in ('-debug', '-o:speed'):
        run([ODIN, 'test', 'tests', profile, f'-out:{work / "tests"}'])
    run([sys.executable, 'tools/check_contracts.py'])
    simulator = work / 'sim'
    run([ODIN, 'build', 'sim', '-debug', f'-out:{simulator}'])
    total_crashes, runs = 0, 0
    for mode in ((), ('--ownership',)):
        for nodes in (1, 3, 5):
            for seed in range(1, args.seeds + 1):
                command = [str(simulator), f'--nodes={nodes}', f'--seed={seed}', f'--steps={args.steps}', *mode]
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=300)
                if result.returncode:
                    raise SystemExit(f'Simulation failed: {command}\n{result.stdout}{result.stderr}')
                total_crashes += int(result.stdout.split('Crashes=')[1].split(' ')[0])
                runs += 1
    print(f'PASS {runs} simulations (single leader and rotating ownership), {runs * args.steps} fault steps, '
          f'{total_crashes} crashes inside the host commit sequence', flush=True)
    run([ODIN, 'run', 'examples/counter.odin', '-file', f'-out:{work / "counter"}'])
    benchmark = work / 'bench'
    run([ODIN, 'build', 'bench', '-o:speed', f'-out:{benchmark}'])
    report = json.loads(run([str(benchmark), '--iterations=1024', '--json'], capture_output=True, text=True).stdout)
    assert report['iterations'] == 1024 and len(report['results']) == 11
    assert all(row['ops_per_sec'] > 0 and row['ns_per_value'] > 0 for row in report['results'])
    print('PASS benchmark smoke test and JSON schema', flush=True)
    cli = work / 'cli'
    run([ODIN, 'build', 'cli', f'-out:{cli}'])
    # Ensure make/CI cannot report success after an underlying tool failure.
    fake_odin = work / 'odin'
    fake_odin.write_text('#!/bin/sh\nexit 17\n')
    fake_odin.chmod(0o755)
    env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ.get('PATH', ''))
    failure = subprocess.run([str(cli), 'test'], cwd=ROOT, env=env, capture_output=True, text=True, timeout=10)
    assert failure.returncode != 0 and 'Hint:' in failure.stderr
    print('PASS CLI propagates subprocess failure with recovery hint', flush=True)
print('All checks passed.')
