#!/usr/bin/env python3
"""Run the same workloads against paxos-odin, paxos-zig, OmniPaxos, and LibPaxos3 on this
machine, sequentially, and record one attributable results file under bench/results/.

The book and README cite only recorded files, never numbers typed by hand.

Environment:
  PAXOS_ZIG_DIR  path to the paxos-zig checkout (default ../paxos-zig)
  ZIG            path to the zig binary (default: zig on PATH)
  ODIN           path to the odin binary (default: odin on PATH)
Flags:
  --iterations=N   values per u64-3n mode for paxos-odin (default 131072)
  --skip=a,b       skip harnesses: odin, zig, zig-durable, omnipaxos, libpaxos
"""
import argparse
import datetime
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIG_DIR = Path(os.environ.get('PAXOS_ZIG_DIR', ROOT.parent / 'paxos-zig')).resolve()
ZIG = os.environ.get('ZIG', 'zig')
ODIN = os.environ.get('ODIN', 'odin')
RESULTS = ROOT / 'bench' / 'results'

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--iterations', type=int, default=131072)
parser.add_argument('--skip', default='')
args = parser.parse_args()
skip = set(filter(None, args.skip.split(',')))


def say(text):
    print(f'== {text}', file=sys.stderr, flush=True)


def json_lines(output):
    rows = []
    for line in output.splitlines():
        if line.startswith('{'):
            rows.append(json.loads(line))
    return rows


def run_capture(command, cwd, env=None, timeout=3600):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        sys.stderr.write(result.stdout[-4000:] + result.stderr[-4000:])
        raise SystemExit(f'{command[0]} failed with status {result.returncode}')
    return result.stdout + result.stderr


def normalize(row):
    """Keep the fields every harness reports so rows from different harnesses line up."""
    keep = ('impl', 'workload', 'mode', 'nodes', 'payload_bytes', 'values', 'ns_per_value',
            'syncs_per_value', 'messages')
    return {k: row[k] for k in keep if k in row}


runs = []
zig_env = dict(os.environ)
if ZIG != 'zig':
    zig_env['PATH'] = str(Path(ZIG).parent) + os.pathsep + zig_env.get('PATH', '')

if 'odin' not in skip:
    say('paxos-odin: building and running the benchmark (in-memory and durable)')
    binary = ROOT / 'bin' / 'paxos-bench'
    binary.parent.mkdir(exist_ok=True)
    run_capture([ODIN, 'build', 'bench', f'-out:{binary}', '-o:speed', '-no-bounds-check', '-microarch:native'], ROOT)
    out = run_capture([str(binary), f'--iterations={args.iterations}', '--durable', f'--journal-dir={binary.parent}',
                       '--json'], ROOT)
    runs += [normalize(r) for r in json.loads(out)['results']]

if 'zig' not in skip:
    say('paxos-zig: zig build benchmark-zig')
    runs += [normalize(r) for r in json_lines(run_capture([ZIG, 'build', 'benchmark-zig'], ZIG_DIR, zig_env))]

if 'zig-durable' not in skip:
    say('paxos-zig: zig build benchmark-durable')
    for row in json_lines(run_capture([ZIG, 'build', 'benchmark-durable'], ZIG_DIR, zig_env)):
        row.setdefault('impl', 'paxos-zig')
        runs.append(normalize(row))

if 'omnipaxos' not in skip:
    say('OmniPaxos: cargo run --release --locked')
    out = run_capture(['cargo', 'run', '--release', '--locked', '--manifest-path',
                       str(ZIG_DIR / 'benchmarks' / 'omnipaxos-rust' / 'Cargo.toml')], ZIG_DIR)
    runs += [normalize(r) for r in json_lines(out)]

if 'libpaxos' not in skip:
    say('LibPaxos3: benchmarks/libpaxos-c/run.sh (needs zig cc and network on first run)')
    runs += [normalize(r) for r in json_lines(run_capture(['sh', 'benchmarks/libpaxos-c/run.sh'], ZIG_DIR, zig_env))]


def tool_version(command, cwd=None, env=None):
    try:
        return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 'unavailable'


cpu = 'unknown'
try:
    for line in open('/proc/cpuinfo'):
        if line.startswith('model name'):
            cpu = line.split(':', 1)[1].strip()
            break
except OSError:
    pass

report = {
    'meta': {
        'date': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'host': platform.node(),
        'cpu': cpu,
        'os': f'{platform.system()} {platform.release()}',
        'odin': tool_version([ODIN, 'version']),
        'zig': tool_version([ZIG, 'version']),
        'rustc': tool_version(['rustc', '--version']),
        'git': tool_version(['git', 'rev-parse', '--short', 'HEAD'], ROOT),
        'paxos_zig_git': tool_version(['git', 'rev-parse', '--short', 'HEAD'], ZIG_DIR),
        'odin_build': '-o:speed -no-bounds-check -microarch:native',
    },
    'runs': runs,
}
RESULTS.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now().strftime('%Y%m%d')
path = RESULTS / f'{stamp}-{platform.node()}.json'
text = json.dumps(report, indent=1)
path.write_text(text)
(RESULTS / 'latest.json').write_text(text)
say(f'recorded {len(runs)} rows in {path.relative_to(ROOT)} and bench/results/latest.json')
for row in runs:
    print(f"{row['impl']:<12} {row['workload']:<16} {row['mode']:<18} {row.get('ns_per_value', 0):>12.1f} ns/value")
