#!/usr/bin/env python3
"""Check compile-time capacity contracts and runtime durability gates in separate Odin processes.

Every compile-fail fixture must be rejected with a diagnostic that carries a hint; every
durability fixture must abort in both debug and optimized builds with the named diagnostic.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ODIN = os.environ.get('ODIN', 'odin')
PREFIX = 'package main\nimport paxos "review:src"\n'
INIT = '''
    m: paxos.Membership(1)
    ids := [1]paxos.Node_Id{1}
    _ = paxos.init(&m, ids[:])
'''

COMPILE_FAIL = {
    # name: (declarations, body, expected diagnostic fragments)
    'zero_window': ('', ' n: paxos.Node(u64, 1, 0, 1)\n _ = paxos.init(&n, 1, m)\n', ('#assert', 'Hint:')),
    'zero_chunk': ('', ' n: paxos.Node(u64, 1, 4, 0)\n _ = paxos.init(&n, 1, m)\n', ('#assert', 'Hint:')),
    'window_not_power_of_two': ('', ' n: paxos.Node(u64, 1, 3, 1)\n _ = paxos.init(&n, 1, m)\n', ('#assert', 'Hint:')),
    'chunk_exceeds_window': ('', ' n: paxos.Node(u64, 1, 4, 5)\n _ = paxos.init(&n, 1, m)\n', ('#assert', 'Hint:')),
    'zero_members': ('', ' z: paxos.Membership(0)\n n: paxos.Node(u64, 0, 4, 1)\n _ = paxos.init(&n, 1, z)\n', ('',)),
    'too_many_members': (
        '', ' big: paxos.Membership(65536)\n _ = paxos.init(&big, ids[:])\n',
        ('#assert', 'Hint:'),
    ),
    'zero_learner_window': ('', ' l: paxos.Learner(u64, 0)\n _ = paxos.init(&l, 1)\n', ('#assert', 'Hint:')),
    'non_comparable_value': ('', ' n: paxos.Node(map[int]int, 1, 4, 1)\n', ('where',)),
    'effects_must_match_node': (
        '', ' n: paxos.Node(u64, 1, 4, 1)\n _ = paxos.init(&n, 1, m)\n e: paxos.Effects(u64, 1, 4, 2)\n'
        ' _ = paxos.campaign(&n, 0, &e)\n',
        ('',),
    ),
}

DURABILITY = (
    ('messages_before_confirm', '_ = paxos.messages_slice(&e)', 'messages_slice before'),
    ('reset_before_confirm', 'paxos.reset(&e)', 'reset discarded'),
    ('correct_order', 'paxos.confirm_writes_durable(&e)\n _ = paxos.messages_slice(&e)\n paxos.reset(&e)', None),
    ('zero_value_is_ready', 'paxos.reset(&e)\n _ = paxos.messages_slice(&e)', None),
)


def run_check(source):
    return subprocess.run(
        [ODIN, 'check', str(source), '-file', f'-collection:review={ROOT}'], capture_output=True, text=True,
    )


with tempfile.TemporaryDirectory(prefix='paxos-contracts-') as directory:
    directory = Path(directory)
    source, binary = directory / 'main.odin', directory / 'check'

    for name, (declarations, body, expected) in COMPILE_FAIL.items():
        source.write_text(PREFIX + declarations + 'main :: proc() {' + INIT + body + '}\n')
        result = run_check(source)
        if result.returncode == 0 or any(fragment not in result.stderr for fragment in expected):
            raise SystemExit(f'{name}: expected the compiler to reject this program\n{result.stdout}{result.stderr}')
        print(f'PASS compile-fail {name}')

    for mode in ('-debug', '-o:speed'):
        for name, operation, expected in DURABILITY:
            pending = '' if name == 'zero_value_is_ready' else (
                '    paxos.effects_add_write(&e, paxos.Write_Promise{paxos.ballot_make(1, 0, 1)})\n')
            source.write_text(PREFIX + 'main :: proc() {\n    e: paxos.Effects(u64, 1, 4, 1)\n' + pending +
                              operation + '\n}\n')
            subprocess.run(
                [ODIN, 'build', str(source), '-file', f'-collection:review={ROOT}', f'-out:{binary}', mode], check=True,
            )
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            if expected:
                if result.returncode == 0 or expected not in result.stderr or 'Hint:' not in result.stderr:
                    raise SystemExit(f'{name} {mode}: expected durability rejection\n{result.stderr}')
            elif result.returncode:
                raise SystemExit(f'{name} {mode}: correct ordering failed\n{result.stderr}')
            print(f'PASS durability {name} {mode}')
