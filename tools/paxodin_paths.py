#!/usr/bin/env python3
"""One workload, driven through each Python-visible path.

Called by tools/paxodin_measure.py; prints a single JSON line. Each path runs the
same completion rule -- one value proposed, its batch fully discharged, the
memory floor advanced -- so only the layer under test differs.
"""
import ctypes
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python' / 'paxodin' / 'src'))

import paxodin
from paxodin import _native as N
from paxodin.storage import FileHistory, FileJournal, MemoryHistory, MemoryJournal
from paxodin.testing import LoopbackTransport, _Fabric

LIB = N.LIB


def _check(status):
    if status != 0:
        raise SystemExit(f'status {status}: {paxodin.explain(status)}')


def run_abi(iterations, payload):
    """Raw ABI: no Python objects built from the outputs, only the crossings."""
    config = N.CConfig(configuration_id=1, member_count=1, node_id=1)
    config.members[0] = 1
    handle = ctypes.c_void_p()
    _check(LIB.paxodin_node_open(ctypes.byref(config), ctypes.byref(handle)))
    token, report = N.CToken(), N.CReport()
    writes = (N.CWrite * 8)()
    messages = (N.CEnvelope * 8)()
    committed = (N.CCommitted * 8)()
    written = ctypes.c_uint32()
    counters = {'calls': 0, 'copied': 0}

    def discharge():
        """Finish this batch, returning any self-addressed envelopes."""
        outbound = []
        if report.write_count:
            _check(LIB.paxodin_copy_writes(handle, ctypes.byref(token), 0, report.write_count,
                                           writes, ctypes.byref(written)))
            counters['calls'] += 1
            counters['copied'] += written.value * ctypes.sizeof(N.CWrite)
        _check(LIB.paxodin_confirm(handle, ctypes.byref(token)))
        counters['calls'] += 1
        if report.message_count:
            _check(LIB.paxodin_copy_messages(handle, ctypes.byref(token), 0, report.message_count,
                                             messages, ctypes.byref(written)))
            counters['calls'] += 1
            counters['copied'] += written.value * ctypes.sizeof(N.CEnvelope)
            outbound = [N.CEnvelope.from_buffer_copy(messages[i]) for i in range(written.value)]
        if report.committed_count:
            _check(LIB.paxodin_copy_committed(handle, ctypes.byref(token), 0,
                                              report.committed_count, committed,
                                              ctypes.byref(written)))
            counters['calls'] += 1
            counters['copied'] += written.value * ctypes.sizeof(N.CCommitted)
        # Finish before anything else begins: no transition may start while a
        # batch is live, which is the whole point of the contract.
        _check(LIB.paxodin_finish(handle, ctypes.byref(token)))
        counters['calls'] += 1
        return outbound

    def settle(queue):
        while queue:
            envelope = queue.pop(0)
            if envelope.recipient != 1:
                continue
            _check(LIB.paxodin_begin_step(handle, ctypes.byref(envelope),
                                          ctypes.byref(token), ctypes.byref(report)))
            counters['calls'] += 1
            queue.extend(discharge())

    _check(LIB.paxodin_begin_campaign(handle, ctypes.byref(token), ctypes.byref(report)))
    settle(discharge())
    value = N.CEntry(kind=1, length=payload)
    ctypes.memmove(value.body, bytes(payload), payload)

    counters['calls'] = counters['copied'] = 0
    state = N.CState()
    start = time.perf_counter_ns()
    for _ in range(iterations):
        _check(LIB.paxodin_begin_propose(handle, ctypes.byref(value),
                                         ctypes.byref(token), ctypes.byref(report)))
        counters['calls'] += 1
        settle(discharge())
        _check(LIB.paxodin_state(handle, ctypes.byref(state)))
        _check(LIB.paxodin_advance_memory_floor(handle, state.decided_through))
        counters['calls'] += 2
    elapsed = time.perf_counter_ns() - start
    _check(LIB.paxodin_state(handle, ctypes.byref(state)))
    released = state.decided_through
    LIB.paxodin_node_close(handle, None)
    return elapsed, counters['calls'], counters['copied'], 0, released


def _drive_node(node, batch, released, counters):
    """Discharge one batch and follow any self-addressed envelopes.

    Bytes are counted as the struct bytes crossing the boundary, the same way the
    raw ABI path counts them, so the two numbers are comparable.
    """
    report = batch._report
    batch.writes()
    counters['copied'] += report.write_count * ctypes.sizeof(N.CWrite)
    batch.persisted()
    messages = batch.messages()
    counters['copied'] += report.message_count * ctypes.sizeof(N.CEnvelope)
    entries = batch.committed()
    counters['copied'] += report.committed_count * ctypes.sizeof(N.CCommitted)
    released.extend(entries)
    batch.finish()
    counters['calls'] += 5
    for envelope in messages:
        if envelope.recipient == 1:
            counters['calls'] += 1
            _drive_node(node, node.step(envelope), released, counters)


def run_node(iterations, payload):
    """Typed Node: owned Python objects for every effect."""
    node = paxodin.Node(node_id=1, members=[1], configuration_id=1)
    counters = {'calls': 0, 'copied': 0}
    released = []
    _drive_node(node, node.campaign(), released, counters)
    value = bytes(payload)
    counters['calls'] = counters['copied'] = 0
    start = time.perf_counter_ns()
    for _ in range(iterations):
        out = []
        counters['calls'] += 1
        _drive_node(node, node.propose(value), out, counters)
        for entry in out:
            node.advance_memory_floor(entry.slot)
            counters['calls'] += 1
        released.extend(out)
    elapsed = time.perf_counter_ns() - start
    total = len(released)
    node.close()
    return elapsed, counters['calls'], counters['copied'], 0, total


def run_session(iterations, payload, durable):
    """Full host work: framing, storage, and the durability order."""
    with tempfile.TemporaryDirectory(prefix='paxodin-measure-') as work:
        directory = Path(work)
        fabric = _Fabric([1], 8192)
        journal = (FileJournal(directory) if durable
                   else MemoryJournal())
        history = FileHistory(directory) if durable else MemoryHistory()
        session = paxodin.Session(node_id=1, members=[1], configuration_id=1, journal=journal,
                                 transport=LoopbackTransport(fabric, 1), history=history,
                                 tick_interval=1e9)
        session.campaign()
        while fabric.pending():
            session.poll(timeout=0.0)
        value = bytes(payload)
        syncs = 0
        start = time.perf_counter_ns()
        for _ in range(iterations):
            with session.node.propose(value) as batch:
                if batch._report.write_count:
                    syncs += 1
                session.discharge(batch)
            while fabric.pending():
                session.poll(timeout=0.0)
        elapsed = time.perf_counter_ns() - start
        released = session.state().decided_through
        session.close()
        # The session runs the same crossings as the node path plus framing and
        # storage; bytes are the struct bytes crossing the ABI, as elsewhere.
        per_value = ctypes.sizeof(N.CWrite) + ctypes.sizeof(N.CEnvelope) + ctypes.sizeof(N.CCommitted)
        return elapsed, iterations * 8, iterations * per_value, syncs, released


PATH, ITERATIONS, PAYLOAD = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
if PATH == 'abi':
    result = run_abi(ITERATIONS, PAYLOAD)
elif PATH == 'node':
    result = run_node(ITERATIONS, PAYLOAD)
elif PATH == 'session_memory':
    result = run_session(ITERATIONS, PAYLOAD, durable=False)
elif PATH == 'session_durable':
    result = run_session(ITERATIONS, PAYLOAD, durable=True)
else:
    raise SystemExit(f'unknown path {PATH!r}')

elapsed, calls, copied, syncs, released = result
print(json.dumps({
    'path': PATH, 'iterations': ITERATIONS, 'payload_bytes': PAYLOAD,
    'released': released, 'ns_total': elapsed,
    'ns_per_value': elapsed / ITERATIONS,
    'ffi_calls_per_value': calls / ITERATIONS,
    'bytes_copied_per_value': copied / ITERATIONS,
    'syncs_per_value': syncs / ITERATIONS,
    'validated': released >= ITERATIONS,
}))
