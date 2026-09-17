#!/usr/bin/env python3
"""Pure state-machine comparison. Builds drivers only; never edits dependency sources.
Use --smoke for one validated epoch per row; defaults to nine calibrated samples.
Dependencies: ODIN, ZIG, CARGO; PAXOS_ZIG_DIR and LIBPAXOS_SOURCE identify pinned sources.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
DRIVERS = ROOT / 'bench/matched'
LIB_REV = 'd255f8b67a32d5e0ef43ac1a393b72cee23d8e0e'


def run(cmd, cwd=ROOT, env=None, timeout=600):
    r = subprocess.run(list(map(str, cmd)), cwd=cwd, env=env, capture_output=True,
                       text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError(f'{cmd}\n{r.stdout[-5000:]}\n{r.stderr[-5000:]}\n'
                           'Hint: check toolchain paths and pinned dependency availability.')
    return r.stdout + r.stderr


def fingerprint(paths):
    h = hashlib.sha256()
    for base in paths:
        for p in sorted(base.rglob('*')) if base.is_dir() else [base]:
            if p.is_file() and p.suffix in ('.odin', '.zig', '.rs', '.c', '.toml', '.lock', '.py'):
                h.update(str(p.relative_to(base) if base.is_dir() else p.name).encode())
                h.update(p.read_bytes())
    return h.hexdigest()


def observation(command):
    output = run(command)
    rows = [json.loads(line) for line in output.splitlines() if line.startswith('{')]
    if len(rows) != 1 or rows[0].get('validated') is not True:
        raise RuntimeError('Missing validated result. Hint: inspect driver output.\n' + output)
    return rows[0]


def summarize(samples):
    ordered = sorted(samples)
    return {'median': statistics.median(samples), 'q1': ordered[len(ordered)//4],
            'q3': ordered[3*len(ordered)//4]}


def bootstrap_ratio(before, after):
    """Paired median ratios with deterministic resampling of pair indexes."""
    if len(before) != len(after) or not before:
        raise ValueError('Paired samples must have equal nonzero lengths')
    ratios = [b/a for a, b in zip(before, after)]
    rng = random.Random(1729)
    boots = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(2000))
    return {'median': statistics.median(ratios), 'ci95': [boots[50], boots[1949]]}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--smoke', action='store_true')
    ap.add_argument('--samples', type=int, default=9)
    ap.add_argument('--only', help='One row: members,payload_bytes,depth')
    ap.add_argument('--implementations', default='odin,zig,omnipaxos,libpaxos')
    ap.add_argument('--odin-root', type=Path, default=ROOT)
    ap.add_argument('--baseline-root', type=Path, help='Also compare a preserved Odin source tree')
    ap.add_argument('--profile-build', action='store_true', help='Portable symbolized builds for Valgrind')
    ap.add_argument('--build-only', action='store_true')
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    if args.samples < 1:
        ap.error('--samples must be positive')
    impls = args.implementations.split(',')
    if set(impls) - {'odin', 'zig', 'omnipaxos', 'libpaxos'}:
        ap.error('unknown implementation')
    if args.baseline_root:
        impls += ['odin-baseline']
    matrix = [(n,p,d) for n in (3,5) for p in (8,64,1024) for d in (1,8,64)]
    if args.only:
        selected = tuple(map(int, args.only.split(',')))
        if selected not in matrix:
            ap.error('--only must select a supported matrix row')
        matrix = [selected]
    stamp = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    out = args.output or ROOT / f'bench/results/matched-{stamp}.json'
    build = ROOT / 'bin/matched' / ('profile' if args.profile_build else 'release')
    build.mkdir(parents=True, exist_ok=True)
    zig_root = Path(os.environ.get('PAXOS_ZIG_DIR', ROOT.parent/'paxos-zig')).resolve()
    lib = Path(os.environ.get('LIBPAXOS_SOURCE', zig_root/f'.zig-cache/benchmarks/libpaxos-{LIB_REV}'))
    tools = {k: os.environ.get(k.upper(), k) for k in ('odin','zig','cargo')}
    source_before = fingerprint([args.odin_root/'src'])
    baseline_before = fingerprint([args.baseline_root/'src']) if args.baseline_root else None
    drivers_before = fingerprint([DRIVERS,Path(__file__)])
    commands = {}
    for n,p,_ in matrix:
        for impl in impls:
            key = (impl,n,p)
            if key in commands:
                continue
            binary = build / f'{impl}-{n}-{p}'
            print(f'Building {binary.name}', flush=True)
            if impl.startswith('odin'):
                source = args.baseline_root if impl == 'odin-baseline' else args.odin_root
                flags = ['-o:speed', '-debug', '-no-bounds-check', '-define:PAXOS_INVARIANT_CHECKS=false', '-microarch:generic'] if args.profile_build else ['-o:speed','-no-bounds-check','-microarch:native']
                run([tools['odin'],'build',DRIVERS/'odin',f'-collection:paxos={source.resolve()}',
                     f'-define:MEMBERS={n}',f'-define:PAYLOAD_WORDS={p//8}',f'-out:{binary}',*flags])
                commands[key] = [str(binary)]
            elif impl == 'zig':
                config = build/f'config-{n}-{p}.zig'
                config.write_text(f'pub const members = {n};\npub const words = {p//8};\n')
                run([tools['zig'],'build-exe','-O','ReleaseFast','-mcpu=baseline' if args.profile_build else '-mcpu=native',
                     '--dep','paxos','--dep','config',f'-Mroot={DRIVERS/"zig.zig"}',
                     f'-Mpaxos={zig_root/"src/root.zig"}',f'-Mconfig={config}',f'-femit-bin={binary}'])
                commands[key] = [str(binary)]
            elif impl == 'omnipaxos':
                env = dict(os.environ, PAYLOAD_WORDS=str(p//8), CARGO_TARGET_DIR=str(build/f'rust-{p}'),
                           RUSTFLAGS='-C debuginfo=2 -C target-cpu=x86-64' if args.profile_build else '-C target-cpu=native')
                run([tools['cargo'],'build','--release','--locked','--manifest-path',DRIVERS/'omnipaxos/Cargo.toml'],env=env)
                shutil.copy2(build/f'rust-{p}/release/paxos-omnipaxos-benchmark', binary)
                commands[key] = [str(binary),str(n)]
            else:
                actual = run(['git','rev-parse','HEAD'],cwd=lib).strip()
                if actual != LIB_REV:
                    raise RuntimeError('LibPaxos revision mismatch. Hint: use the pinned LIBPAXOS_SOURCE.')
                sources = ['paxos','acceptor','learner','proposer','carray','quorum','storage','storage_utils','storage_mem']
                run([tools['zig'],'cc','-O3','-g','-mcpu=baseline' if args.profile_build else '-march=native',
                     f'-DPAYLOAD_WORDS={p//8}','-I',lib/'paxos/include',DRIVERS/'libpaxos.c',
                     *[lib/f'paxos/{s}.c' for s in sources],'-o',binary])
                commands[key] = [str(binary),str(n)]
    if source_before != fingerprint([args.odin_root/'src']) or drivers_before != fingerprint([DRIVERS,Path(__file__)]):
        raise RuntimeError('Sources changed during build. Hint: rerun with a stable source tree.')
    if args.baseline_root and baseline_before != fingerprint([args.baseline_root/'src']):
        raise RuntimeError('Baseline changed during build. Hint: preserve an immutable baseline tree.')
    metadata = {'date':stamp,'host':platform.node(),'platform':platform.platform(),
                'source_sha256': source_before,
                'binary_sha256':{str(v[0]):hashlib.sha256(Path(v[0]).read_bytes()).hexdigest() for v in commands.values()},
                'drivers_sha256':fingerprint([DRIVERS,Path(__file__)]),
                'profile_build':args.profile_build,'epoch_values':4096,'window':4096,'chunk':256,
                'build_policy': {'odin':'speed, no-bounds-check, native (portable symbols for profiles)',
                    'zig':'ReleaseFast, native (baseline for profiles)', 'rust':'release LTO, native (x86-64 for profiles)',
                    'c':'O3, native (x86-64 for profiles)'}, 'commands':{'/'.join(map(str,k)):v for k,v in commands.items()},
                'quorum':'majority','timing':'in-process finite epoch through decision; no I/O',
                'unsupported_common_modes':['rotating ownership','API batching','durability'],
                'libpaxos_revision':LIB_REV}
    git = subprocess.run(['git','rev-parse','HEAD'],cwd=args.odin_root,capture_output=True,text=True)
    metadata['odin_git'] = git.stdout.strip() if git.returncode == 0 else None
    status = subprocess.run(['git','status','--porcelain'],cwd=args.odin_root,capture_output=True,text=True)
    metadata['odin_dirty'] = bool(status.stdout) if status.returncode == 0 else None
    metadata['cpu_model'] = next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), 'unknown')
    if args.baseline_root:
        metadata['baseline_sha256'] = baseline_before
    for name,exe in tools.items():
        if shutil.which(exe):
            metadata[name] = run([exe,'version' if name in ('odin','zig') else '--version']).strip()
    if 'zig' in impls:
        metadata['zig_revision'] = run(['git','rev-parse','HEAD'],cwd=zig_root).strip()
        metadata['zig_source_sha256'] = fingerprint([zig_root/'src'])
    metadata['cpu_affinity'] = sorted(os.sched_getaffinity(0)) if hasattr(os,'sched_getaffinity') else None
    for path in ('/sys/fs/cgroup/cpu.max','/sys/fs/cgroup/memory.max'):
        if Path(path).exists(): metadata[path] = Path(path).read_text().strip()
    if hasattr(os,'sched_setaffinity'):
        try:
            cpu = min(os.sched_getaffinity(0)); os.sched_setaffinity(0,{cpu}); metadata['pinned_cpu'] = cpu
        except OSError as error:
            metadata['affinity_error'] = str(error)
    report = {'meta':metadata,'runs':[]}
    if not args.build_only:
        for n,p,d in matrix:
            # Calibrate once for the whole matched group, never separately per library.
            pilot = [observation(commands[(i,n,p)]+[str(d),'1'])['ns_total'] for i in impls]
            epochs = 1 if args.smoke else min(16,max(1,math.ceil(20_000_000/max(1,min(pilot)))))
            samples = {i:[] for i in impls}; counts = {i:[] for i in impls}; sizes = {}
            for sample in range(1 if args.smoke else args.samples):
                order = impls[sample%len(impls):]+impls[:sample%len(impls)]
                for i in order:
                    row = observation(commands[(i,n,p)]+[str(d),str(epochs)])
                    if row['values'] != 4096*epochs:
                        raise RuntimeError('Mismatched command count')
                    samples[i].append(row['ns_total']/row['values']); counts[i].append(row['messages'])
                    sizes[i] = {k:v for k,v in row.items() if k.endswith('_bytes')}
            for i in impls:
                row = {'impl':i,'nodes':n,'payload_bytes':p,'depth':d,'epochs':epochs,'values':4096*epochs,
                       'samples_ns_per_value':samples[i],'messages':counts[i],'validated':True,
                       'summary':summarize(samples[i]), 'static_components':sizes[i]}
                report['runs'].append(row)
                print(n,p,d,i,round(row['summary']['median'],2),flush=True)
            if args.baseline_root:
                report.setdefault('odin_changes',[]).append({'nodes':n,'payload_bytes':p,'depth':d,
                    'ratio':bootstrap_ratio(samples['odin-baseline'],samples['odin'])})
            out.parent.mkdir(parents=True,exist_ok=True)
            out.write_text(json.dumps(report,indent=2)+'\n')
    else:
        out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(report,indent=2)+'\n')
    regressions = [r for r in report.get('odin_changes',[]) if r['ratio']['ci95'][0] > 1.05]
    report['regression_gate'] = {'threshold':1.05,'regressions':regressions,
                                 'status':'fail' if regressions else ('pass' if args.baseline_root and not args.smoke and not args.build_only else 'report-only')}
    out.write_text(json.dumps(report,indent=2)+'\n')
    print(out)
    if regressions and not args.smoke: raise SystemExit('Performance regression gate failed; see recorded rows.')


if __name__ == '__main__':
    main()
