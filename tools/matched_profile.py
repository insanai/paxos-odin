#!/usr/bin/env python3
"""Profile matched drivers from a --profile-build report using Callgrind and Massif.
Example: python3 tools/matched_profile.py bin/profile-build.json --rows=3,8,1
Instrumented times are intentionally never reported as performance results.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from matched_compare import ROOT, run


def process_memory(command):
    # Poll the child's post-exec high-water mark; wait4 can include the Python
    # parent's inherited pre-exec RSS and overstate the memory of a small binary.
    with tempfile.TemporaryFile(mode='w+') as output:
        p = subprocess.Popen(command, stdout=output, stderr=output)
        peak = 0
        deadline = time.monotonic() + 600
        while p.poll() is None:
            if time.monotonic() > deadline:
                p.kill(); p.wait(); raise RuntimeError('Memory run timed out')
            try:
                if os.readlink(f'/proc/{p.pid}/exe') == os.path.realpath(command[0]):
                    for line in Path(f'/proc/{p.pid}/status').read_text().splitlines():
                        if line.startswith('VmHWM:'): peak=max(peak,int(line.split()[1])*1024)
            except (FileNotFoundError, ProcessLookupError): pass
            time.sleep(.0005)
        output.seek(0)
        text=output.read()
        if p.returncode or '"validated":true' not in text:
            raise RuntimeError('Memory run failed. Hint: inspect driver output.\n'+text)
        return peak or None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('report',type=Path)
    ap.add_argument('--rows',default='3,8,1;5,8,1;3,1024,64')
    ap.add_argument('--implementations',default='odin,zig,omnipaxos,libpaxos')
    ap.add_argument('--output',type=Path,default=ROOT/'bin/profiles')
    args = ap.parse_args()
    report = json.loads(args.report.read_text())
    if not report['meta']['profile_build']:
        ap.error('Use a --profile-build report; native instructions may not run under Valgrind.')
    for binary, expected in report['meta'].get('binary_sha256', {}).items():
        if hashlib.sha256(Path(binary).read_bytes()).hexdigest() != expected:
            raise RuntimeError('Profile binary changed. Hint: rebuild the report before profiling.')
    args.output.mkdir(parents=True,exist_ok=True)
    results=[]
    for row in args.rows.split(';'):
        n,p,d = map(int,row.split(','))
        for impl in args.implementations.split(','):
            command = report['meta']['commands'][f'{impl}/{n}/{p}']+[str(d),'1']
            label=f'{impl}-{n}-{p}-{d}'
            print('Profiling',label,flush=True)
            cg=args.output/f'{label}.callgrind'
            ms=args.output/f'{label}.massif'
            log=run(['valgrind','--tool=callgrind','--collect-atstart=no',
                     '--toggle-collect=*measured_epoch*', '--cache-sim=yes','--branch-sim=yes',
                     f'--callgrind-out-file={cg}',*command])
            (args.output/f'{label}.callgrind.log').write_text(log)
            annotation=run(['callgrind_annotate','--inclusive=yes',str(cg)])
            (args.output/f'{label}.annotated.txt').write_text(annotation)
            text=cg.read_text()
            events=next(line.split()[1:] for line in text.splitlines() if line.startswith('events:'))
            totals=next(line.split()[1:] for line in text.splitlines() if line.startswith('summary:'))
            counters=dict(zip(events,map(int,totals)))
            if counters.get('Ir',0)==0:
                raise RuntimeError('Empty Callgrind collection. Hint: inspect the measured_epoch symbol.')
            log=run(['valgrind','--tool=massif','--stacks=yes',f'--massif-out-file={ms}',*command])
            (args.output/f'{label}.massif.log').write_text(log)
            snapshots=[]; current={}
            for line in ms.read_text().splitlines():
                if line.startswith('snapshot='):
                    if current: snapshots.append(current)
                    current={}
                if line.startswith(('mem_heap_B=','mem_heap_extra_B=','mem_stacks_B=')):
                    key,val=line.split('=');current[key]=int(val)
            if current:snapshots.append(current)
            results.append({'impl':impl,'nodes':n,'payload_bytes':p,'depth':d,'values':4096,
                            'callgrind':counters,'peak_massif_bytes':max(sum(s.values()) for s in snapshots),
                            'peak_rss_bytes':process_memory(command[:-1]+['8']), 'rss_epochs':8,
                            'rss_method':'sampled post-exec /proc VmHWM; null if process finished before observation',
                            'static_storage_note':'Static/BSS may be absent from Massif; RSS includes it.',
                            'command':command})
            (args.output/'summary.json').write_text(json.dumps({'meta':report['meta'],'runs':results},indent=2)+'\n')
    print(args.output/'summary.json')


if __name__=='__main__':main()
