# paxodin

Idiomatic Python bindings for [paxos-odin](https://github.com/insanai/paxos-odin), a
deterministic, bounded, data-oriented implementation of Classic and Multi-Paxos.

> **Status: pre-alpha.** The native bridge and the Python surface are under construction.
> Nothing here is published, and no release artifact has been qualified yet.

The Odin core performs no I/O and owns no threads or clocks: it consumes messages and emits
a caller-owned batch of effects. `paxodin` keeps that split. It owns the *order* of the
durability contract — persist, confirm, send, release — and owns the lifetime of the bytes it
hands you. Every actual byte moves through an adapter you supply, so the package contains no
sockets, no TLS policy and no reconnection logic.

Design records: POD 0011 (`docs/pod/records/0011-paxodin-python-sdk.typ`) and Part IX of the
specification book (`docs/book/09_python_sdk.typ`). Detailed prose lives there, not here.

## Licence

MIT. See `LICENSE`.
