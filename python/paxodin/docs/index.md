# paxodin

Idiomatic Python bindings for the [paxos-odin](https://github.com/insanai/paxos-odin)
consensus core.

The Odin core performs no I/O and owns no threads or clocks: it consumes messages and
fills a caller-owned batch of effects. This package keeps that split. It owns the
*order* of the durability contract - persist, confirm, send, release - and the lifetime
of the bytes it returns. Every actual byte moves through an adapter you supply, so there
is no socket, no TLS policy and no retry loop here.

## Three events, kept distinct

Collapsing these is how a consensus API starts lying:

| Event | What it means |
|---|---|
| **Agreement** | A quorum chose the value. |
| **Release** | This participant knows it, in order, durably. |
| **Application** | Your code has acted on it. |

An `append` receipt reports the first two, **at this participant only**.

## Quick start

```python
from paxodin.testing import Cluster

with Cluster(3) as cluster:
    receipt = cluster.append(b"set counter 41")
    print(receipt.slot, receipt.value)
```

Prefer asyncio? The same participant drives itself:

```python
from paxodin.testing import AsyncCluster

async with AsyncCluster(3) as cluster:
    receipt = await cluster.append(b"set counter 41")
```

`Cluster` is memory-backed and not durable - it is for examples and tests. For anything
real, supply a [`FileJournal`][paxodin.storage.FileJournal] and your own transport:

```python
from paxodin import Session
from paxodin.storage import FileHistory, FileJournal

with Session(
    node_id=1,
    members=[1, 2, 3],
    configuration_id=1,
    journal=FileJournal("state/node-1"),
    history=FileHistory("state/node-1"),
    transport=transport,
) as session:
    receipt = session.append(b"set counter 41", timeout=5.0)
```

## What this package does not do

* **No transport.** You supply one, and it owns authentication - a sender id inside a
  frame is a claim, not proof.
* **No leases, no linearizable reads.** The core has neither, so neither does this.
  A local read is *this participant's released prefix* and nothing more.
* **No automatic retry.** A `CommitTimeout` does not cancel anything. Retry only behind
  an application command id and a deduplication policy.
* **No background thread in `Session`.** Call [`poll`][paxodin.session.Session.poll]
  between appends - or use `AsyncSession`, which drives itself.

## Design records

The prose lives in the project's Typst documents, not here: POD 0011
(`docs/pod/records/0011-paxodin-python-sdk.typ`) and Part IX of the specification book
(`docs/book/09_python_sdk.typ`).
