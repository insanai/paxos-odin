#!/usr/bin/env python3
"""Profile Odin recovery/reuse/retransmission, optionally against a preserved source tree."""
import argparse
import json
import os
from pathlib import Path
from matched_compare import ROOT, fingerprint, run


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-root',type=Path)
    ap.add_argument('--output',type=Path,default=ROOT/'bin/recovery-profiles')
    args=ap.parse_args(); args.output.mkdir(parents=True,exist_ok=True)
    rows=[]
    sources=[('candidate',ROOT)]
    if args.baseline_root:sources.insert(0,('baseline',args.baseline_root))
    for name,root in sources:
        binary=args.output/name
        run([os.environ.get('ODIN','odin'),'build',ROOT/'tools/profile_recovery.odin','-file',
             f'-collection:paxos={root.resolve()}','-o:speed','-debug','-no-bounds-check',
             '-define:PAXOS_INVARIANT_CHECKS=false','-microarch:generic',f'-out:{binary}'])
        for scenario in ('recovery','moving','resend'):
            cg=args.output/f'{name}-{scenario}.callgrind'
            output=run(['valgrind','--tool=callgrind','--collect-atstart=no',
                        '--toggle-collect=*measured_epoch*','--cache-sim=yes',
                        f'--callgrind-out-file={cg}',binary,scenario])
            if f'Validated {scenario}' not in output:raise RuntimeError(output)
            (args.output/f'{name}-{scenario}.annotated.txt').write_text(
                run(['callgrind_annotate','--inclusive=yes',cg]))
            text=cg.read_text().splitlines()
            events=next(x.split()[1:] for x in text if x.startswith('events:'))
            counts=next(x.split()[1:] for x in text if x.startswith('summary:'))
            counters=dict(zip(events,map(int,counts)))
            if counters.get('Ir',0)==0:raise RuntimeError('Empty collection')
            rows.append({'source':name,'scenario':scenario,'source_sha256':fingerprint([root/'src']),
                         'driver_sha256':fingerprint([ROOT/'tools/profile_recovery.odin']),
                         'counters':counters,'validated':True})
            print(name,scenario,counters['Ir'],flush=True)
            (args.output/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')


if __name__=='__main__':main()
