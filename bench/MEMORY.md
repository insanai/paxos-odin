# Measuring the static memory budget

Run from the repository root:

```sh
odin run tools/memory_report.odin -file -out:/tmp/paxos-memory-report
```

The CSV reports actual instantiated type sizes. `node_bytes` already includes
`ledger_bytes`; `total_bytes` adds one caller-owned effects buffer to one node.
It excludes transport queues, serialization buffers, journals, allocator overhead,
application state, and process/runtime memory. A host may share one effects buffer
between nodes if it consumes or copies each batch before reuse.

On the current x86-64 build (Odin dev-2026-09-nightly:a2fb372):

| Payload | Members | Window | Chunk | Node bytes | Effects bytes | Total bytes |
|---|---:|---:|---:|---:|---:|---:|
| 8 B | 3 | 256 | 64 | 23,168 | 22,704 | 45,872 |
| 1 KiB | 3 | 256 | 64 | 610,416 | 22,704 | 633,120 |
| 8 B | 5 | 256 | 64 | 23,384 | 32,272 | 55,656 |
| 1 KiB | 5 | 256 | 64 | 610,632 | 32,272 | 642,904 |
| 8 B | 3 | 4,096 | 256 | 357,344 | 137,904 | 495,248 |
| 1 KiB | 3 | 4,096 | 256 | 8,942,544 | 137,904 | 9,080,448 |

Borrowed payloads keep effects storage independent of payload size. The node still
has a window of ledger values, a window of recovery values, and a chunk-sized
resubmission queue. The recovery values are a useful next optimization candidate:
recovery processes one chunk at a time, but currently reserves a full window.
Changing that layout requires testing chunk boundaries, retries and wrapped window
indexes; it is not justified by a smaller `size_of` alone.

Canonical membership also removes the separate member index. Duplicate validation
now scans adjacent sorted IDs rather than comparing every pair of input IDs.

## Comparing implementations

Match member count, window, recovery chunk, payload, durability policy, and enabled
features. Measure transport queues and peak resident memory separately from these
static sizes. No equivalent current Zig memory measurement is recorded here.

The existing performance results are workload-specific. They show an Odin advantage
for large payloads and a Zig advantage for three-node small-payload workloads;
they do not establish a universal winner. The benchmark's final validation now
uses the highest actual proposed slot, including ownership gaps. Final ownership
settling remains outside the timed interval, so those rows are not measurements of
end-to-end completion latency. Existing results files are historical measurements,
not measurements of subsequent source changes.
