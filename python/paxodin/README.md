# paxodin

A typed Python interface to the [Paxos-Odin](https://github.com/insanai/paxos-odin)
consensus engine. Synchronous sessions, asyncio, explicit durability, and errors
that explain how to recover. Python 3.12+; no runtime Python dependencies.

[Website](https://insanai.github.io/paxos-odin/) |
[Book](https://insanai.github.io/paxos-odin/book/) |
[API reference](https://insanai.github.io/paxos-odin/api/) |
[Design records](https://insanai.github.io/paxos-odin/pods/)

## Install

```sh
uv add paxodin
# Or: python -m pip install paxodin
```

Release wheels contain the native Odin library. Supported release targets are
Linux x86-64, macOS 12+ on Apple Silicon, and Windows x86-64, tested on CPython
3.12, 3.13 and 3.14. Source builds require Odin dev-2026-09 or newer. Free-threaded
Python and PyPy are not qualified. Check the wheel's manylinux tag for its Linux
glibc floor.

## Try three participants

```python
from paxodin.testing import Cluster

with Cluster(3) as cluster:
    receipt = cluster.append(b"set counter 41")
    print(receipt.slot, receipt.value)
```

`Cluster` is an in-process, memory-backed test helper. It is not durable. For a
production participant, provide `FileJournal`, `FileHistory`, and an authenticated
transport to `Session` or `AsyncSession`; see the [API guide](https://insanai.github.io/paxos-odin/api/).

## What success means

An append receipt means this participant knows the command in its durable,
contiguous released prefix. It does not mean your application has applied it or
that every peer has received it. A timeout ends the wait; it cannot cancel a
proposal that peers might choose. Use command ids and application deduplication
when retrying.

The initial profile supports seven members, a 256-slot window, a 64-slot recovery
chunk and 1,024-byte commands. The Python SDK supports fixed membership and
single-leader replication. Reconfiguration, rotating ownership and learners are
available in the Odin core but not exposed by this SDK release. Neither layer
provides lease-based local reads.

## Develop

From `python/paxodin/` in the monorepo:

```sh
uv sync --locked
uv run pytest
uv run ruff check .
uv run mypy
```

Detailed documentation is maintained in Typst in the book and POD 0011. The API
reference is generated from Python docstrings. The separate `paxodin` CLI in
GitHub releases drives repository builds, tests, simulations and documentation;
installing the Python package does not install that executable.

## Authors and license

Authored by **Vikrant Rathore**, with assistance from **Ronak Rathore**.
Copyright (c) 2026 Vikrant Rathore and Ronak Rathore. Released under the
[MIT License](https://github.com/insanai/paxos-odin/blob/main/LICENSE).
