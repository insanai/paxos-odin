#import "theme.typ": *
#import "figures.typ": python_sdk_layers, python_sdk_batch

#part_page("IX", [Python integration], [
  A Python SDK: a small interface over a precise durability contract.
  Follow one command across the language boundary, then examine what a timeout,
  a crash and a released buffer mean.
])

= Paxodin: A Python Host for the Odin Core

#objectives([
  After completing this chapter, you will be able to:
  - Integrate Python applications with the Odin consensus core across a stable, versioned C ABI boundary.
  - Implement durable file-backed journals and histories adhering to the strict persist-before-send contract.
  - Track command lifecycles across the agreement, release, and application boundaries.
  - Build asynchronous consensus workflows using `AsyncSession` and standard Python `asyncio`.
  - Manage buffer memory lifetimes and wire codecs safely without introducing memory safety hazards.
])

*Status.* The package exists at `python/paxodin/` and is described by POD 0011.
Its C ABI, typed `Node`, durable `Session`, asyncio `AsyncSession`, typed
message classes, reference journal and history, wire codec and in-process
clusters are implemented and covered by `make check-python`.
A wheel builds from a source distribution outside the checkout and passes a
three-node smoke test on CPython 3.12, 3.13 and 3.14 with no Odin compiler
present. Reconfiguration, rotating ownership, learners and leases are refused by
capability bit rather than half-supported. Tagged releases publish the tested wheels and source distribution to PyPI as `paxodin`.

== Start with one command

Imagine three processes maintaining the same sequence of commands. A Python
application asks one participant to append `b"set counter 41"`. The bytes become
a value in the Odin log. The Python layer drives journal writes and message
exchange until it can report the command's position in a durable, contiguous
prefix. The application later interprets those bytes and updates its counter.

There are three distinct events here: agreement, release and application. An
`append` receipt reports the first two at this participant. It does not say that
every participant has received the command, or that the counter has changed.
Keeping that distinction visible makes the API easier to reason about after a
crash.

```python
from paxodin import FileHistory, FileJournal, Session

# Supply an authenticated transport connecting this member to its peers.
with Session(
    node_id=1,
    members=[1, 2, 3],
    configuration_id=1,
    journal=FileJournal("state/node-1"),
    history=FileHistory("state/node-1"),
    transport=transport,
) as session:
    receipt = session.append(b"set counter 41", timeout=5.0)
    print(receipt.slot)
```

A Session represents one participant. The other two must also run and serve
traffic. `poll(timeout=...)` keeps a participant progressing between appends.
The initial design has no background worker. A follower reports `NotLeader`
with a hint when available, leaving request routing explicit.

== A small Python surface

The SDK uses Python 3.12+ features directly. Results are frozen dataclasses
with slots; options are keyword-only; alternatives use union annotations; storage
and transport adapters satisfy typed protocols. Public objects own their data.
A Python `bytes` returned today remains valid after tomorrow's transitions.

The rule that shapes the surface is that Odin is the engine and Python is the
product. Messages are nine typed classes an adapter matches on, never a tag and
a field to consult. Timers are seconds; the engine's ticks are converted away.
Errors render exactly as the core's do -- a titled banner, the cause with its
values, a `Hint:` -- and a test enumerates every exception class as the Odin
suite enumerates its `Error` enum. Reading the log is iteration.

`Session` is inspired by Requests in its context management, discoverable verbs,
explicit timeouts and useful exceptions. `AsyncSession` is the same participant
driven by asyncio: no polling loop, one lock owning every transition, journal
syncs off the event loop, and a cancellation that stops waiting without
pretending to un-propose. The subject is a replicated log, so completion rules
come from the log. A third API, `Node`, exposes individual transitions and
pending batches for hosts that need control over scheduling or
storage. Both APIs invoke the same Odin core.

#book_figure([The SDK layers. Python owns returned data; the bridge hides native representation.], python_sdk_layers())

The initial wheel contains a fixed capacity profile. Python cannot instantiate
an arbitrary Odin generic at runtime. The stock profile supports seven
members, a 256-slot window, a 64-slot recovery chunk and commands up to 1,024 bytes.
These limits are queryable and checked before mutation. Larger profiles need
compatible artifacts on every participant.

== Why the bridge retains a batch

Suppose Odin emits a vote and an outgoing acknowledgement. The wrapper starts
constructing a Python list, but Python raises `MemoryError`. If that list were the
only record of the pending writes, the next call could accidentally acknowledge
a vote that never reached disk.

The bridge therefore retains the native effects batch behind a generation
token. Python can ask for buffer sizes and retry copies without rerunning the
transition. No new transition is permitted until that batch has been dealt with.

#book_figure([Write before send across two languages. A failed allocation leaves the batch pending.], python_sdk_batch())

The sequence has four steps. First, perform one transition and retain its effects.
Second, copy the journal records, append them in order and sync. Third, confirm
that exact batch token and copy outputs into owned Python storage. Finally, finish
the batch and send or release the copied outputs. A protocol error may accompany
writes, so checking the error never substitutes for processing the batch.

This design pays for copies at the language boundary. Those copies give ordinary
Python lifetimes to values whose native storage is mutable. A later optimization
must preserve that ownership contract. An exported pointer into the ledger would
make a short API much harder to use correctly.

== A timeout leaves a question open

A caller waits five seconds. The peers may have chosen the command while the
reply was delayed. Raising `CommitTimeout` cannot undo that choice. The exception
therefore reports whether admission occurred and, when known, the configuration
and slot.

```text
CommitTimeout: slot 28 was admitted, but its decision was not observed within 5s.
Hint: keep polling and inspect local history. This timeout did not cancel Paxos.
Use a command id and application deduplication before retrying into another slot.
```

The first sentence says what is known. The hint says how to make progress without
inventing a guarantee. The SDK does not silently submit another copy after an
admitted timeout. A receipt also does not create exactly-once application: a host
still needs a durable command-id policy when its clients retry.

== A memory floor transfers responsibility

A finite native window eventually fills. Freeing a cell is safe only after the
host has durably taken responsibility for the released entry. In the implementation,
Session writes released entries to retained history before moving the native
memory floor. The application's durable cursor is separate: it records what the
application has applied, not what Session has merely stored.

#table(
  columns: (1fr, 2fr), inset: 6pt, stroke: 0.5pt + rule,
  [*Position*], [*What it establishes*],
  [Released prefix], [This participant knows the decisions in order.],
  [Native memory floor], [The host durably retains the entries needed outside the window.],
  [Application cursor], [The application has durably consumed this prefix.],
)

On restart, journal replay reconstructs the core. Retained history supplies
unapplied commands and catch-up replies. V1 does not delete this history; bounded
RAM is not bounded disk usage. Disk quotas stop admission with a useful error.
Snapshot installation and history trimming require a later, explicit contract.
A complete record with a bad checksum is corruption, not permission to skip it.

== Packaging without a second algorithm

The project lives in `python/paxodin/`. uv manages its environment and locked
development dependencies. hatchling is the build backend, and a build hook runs
`odin build -build-mode:shared` directly; ctypes loads the result. There is no C
or C++ in the project, so there is no C build system in it either. Wheels include
the library, so ordinary wheel users need no Odin compiler. Source distributions
include the exact core source revision and must build independently of the
surrounding checkout.

Two libraries are built from one source. The shipped one compiles the core with
`Host_Managed`, because a host inside a Python interpreter cannot accept a gate
that calls `os.exit`; the bridge enforces the same order itself and returns a
status. A second library compiles `Enforced`, and the whole test suite runs again
against it, so an ordering mistake in the bridge stops a test run instead of
reaching a release.

The development tools are Ruff, strict mypy, pytest and Hypothesis. The first
release matrix covers CPython 3.12–3.14 on Linux x86-64, Windows x86-64 and
macOS Apple Silicon. Each tagged release checks the installed artifacts before publishing.
The release has to verify resource loading, native dependencies, portable CPU
instructions, ABI versions and the absence of source-tree path assumptions.
POD 0011 links the upstream tooling documentation and specifies the build gates.

== Measure the wrapper's actual cost

The native benchmark measures neither Python object creation nor a Python
journal, so the same workload was run through every path with the membership,
payload, capacities and completion rule held equal. One member, one value per
transition, the batch fully discharged and the memory floor advanced each time.

#table(
  columns: (auto, auto, auto, auto), inset: 6pt, stroke: 0.5pt + rule,
  [*Path*], [*ns per value*], [*vs native*], [*What it adds*],
  [native Odin],        [826],    [1.00],  [the transition alone],
  [C ABI],              [7,008],  [8.52],  [`ctypes` crossings and copies],
  [Python `Node`],      [23,787], [28.78], [owned Python objects],
  [`Session`, memory],  [29,739], [35.98], [framing, journal, ordering],
  [`Session`, `fsync`], [48,091], [58.29], [a durable barrier per batch],
)

Measured on an AMD Ryzen 7 5800H with CPython 3.13.5, nine samples per row, 64-byte
payloads; raw data in `bench/results/paxodin-paths-20260917.json`.

Read the table as a distribution, not a ranking. The rows are not
interchangeable, and comparing a Python `fsync` against a native in-memory
transition would say nothing at all. What it shows is where the cost goes. The
boundary itself is 883 nanoseconds per crossing at seven crossings per value, so
the C ABI accounts for 6.2 of its 7.0 microseconds. Building owned Python objects
costs a further 17 microseconds, and that is the ownership contract being paid
for: a `bytes` handed to an application today stays correct after any number of
later transitions.

Payload size moves the native and ABI rows by under five percent from eight bytes
to 1,024, because values are stored inline at a fixed size and a larger one costs
the engine no allocation -- the same property that makes the node's footprint
knowable in advance. The Python rows move by up to twelve percent at 1,024 bytes,
which is the copy into an owned `bytes`, paid once per released entry.

This is what a measurement is for. Batched FFI would address 6.2 microseconds; a
compiled extension would address the 17 spent on object creation. Neither was
built, because the first question was where the time actually went.

== Exercises

+ Python fails to allocate an output buffer after a transition. Which object must
  still own the effects, and why is repeating the transition unsafe?
+ An append times out, then its value appears in local history. Which statement
  would have been false: “the wait ended” or “the command was cancelled”?
+ The memory floor is 100 and the application cursor is 90. Where must commands
  91–100 survive, and who is responsible for returning them after restart?

The pending native batch answers the first question: retry the copy, not the
transition. The wait ended in the second; cancellation was never established.
For the third, the host's durable history must retain the commands independently
of the native window and serve them until application and retention obligations
have both been met.

== Install and release

Install the Python SDK with `uv add paxodin` or `python -m pip install paxodin`.
The wheel contains the native engine; a wheel user needs no Odin compiler.
Source builds use the Odin compiler and the core bundled in the source distribution.
The separate `paxodin` CLI comes from GitHub releases and works inside a repository
checkout. Its build and test commands need Odin; documentation also needs Typst.
The Odin import name remains `paxos`.

Tag names are `vMAJOR.MINOR.PATCH`. The release gate checks agreement among the
tag, core, CLI and Python versions. Three native jobs build CLI archives and
wheels, rebuild wheels from standalone source distributions, and test wheel installs
on CPython 3.12, 3.13 and 3.14 without Odin on PATH. macOS releases target only
Apple Silicon, with macOS 12 as the minimum. Linux wheel tags encode their glibc
requirement. Windows releases target x86-64. Checksums accompany GitHub assets.

Routine CI runs both Odin test profiles, contracts and a short seeded fault matrix,
plus Python lint, types and both durability gates. Full fault simulations run on
tags, weekly and on manual dispatch. New pushes cancel obsolete branch checks.
Build jobs have no publication credentials; only the final publish job receives
the organization's `PYPI_API_KEY`. GitHub Pages deploys the built static site with
its own narrowly scoped permissions. Performance benchmarks remain reproducible
manual experiments rather than noisy shared-runner timing gates.
