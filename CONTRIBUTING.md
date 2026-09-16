# Contributing to paxos-odin

## Build and run

```sh
./build.sh          # bootstrap bin/paxos-cli
make build          # bin/paxos.o, bin/paxos-sim, bin/paxos-bench, bin/paxos-cli
make test           # odin test tests
make example        # odin run examples/counter.odin -file
make sim            # one seeded simulation
make docs           # the book and the POD records, into docs/build/
```

Requirements: Odin `dev-2026-09` or newer; Typst 0.15 for the documents;
Python 3 for `make check`.

## Before you push

Run the full verification and make sure it ends with `All checks passed.`:

```sh
make check
```

It checks style, runs the tests in `-debug` and `-o:speed`, runs the compiler
and durability contract fixtures, runs 120 fault simulations (60 with one
leader, 60 with rotating ownership), the counter example, the benchmark JSON
schema, and the CLI failure check, all in a temporary directory. `python3 tools/check.py --seeds=100 --steps=10000` widens
the simulation matrix.

A change to the protocol needs a test that fails without it. A change that
fixes a bug found by the simulator should name the seed in the commit message
so the run can be replayed: `paxos-sim --seed=N --steps=N --nodes=N
[--ownership] --verbose`. A change to a proof obligation needs the matching
lemma in the safety-argument chapter and POD 0008 updated in the same commit.

## Style

- The Zen of Odin for InsanAI (POD 0001): 99 columns soft, 108 hard; files at most 1,408 lines;
  procedure bodies at most 70 lines of logic. `tools/check_style.py` rejects violations.
- Every package passes `odin check <package> -vet -strict-style`. The library
  is fully parametric, so its bodies are checked through `tests`, `sim`,
  `bench`, `cli`, and `examples/counter.odin`.
- Types are `Ada_Case` (`Node_Options`, `Trim_Anchor`, `Durability_Gate`);
  procs and fields are `snake_case`; constants are `UPPER_CASE`.
- Procs are prefixed with their receiver: `node_propose`, `replicated_log_step`,
  `learner_learn_chosen`, `effects_reset`, `membership_init`. Add the short
  spelling to the proc group in `src/paxos.odin` when the verb already exists
  there.
- No allocation and no value copies in a transition. Use `small_array`, fixed
  arrays, and native `bit_set`; the host owns anything that grows. Records and
  messages point at values inside the ledger; only hosts copy.
- Keep the ledger a struct of arrays. A new per-slot fact is a new column and,
  if it is scanned, a bitmap; not a field inside a cell struct.
- Every `Error` value has an entry in `explain_error` with a title line, a
  one-sentence cause, and a `Hint:` line naming the corrective action.
  `test_every_error_explains_problem_and_recovery` enumerates the enum, so a
  missing entry fails `make test`.
- Diagnostics that stop the process (`#assert`, the durability gate) carry a
  `Hint:` too; the contract fixtures check for it.
- Comments say what a rule protects, not what the next line does.

## Documentation

Documentation is written in Typst. The only Markdown files in the repository
are `README.md`, `README.ko.md`, and this file.

- The book is `docs/book.typ` with one chapter per file in `docs/book/`. The
  API reference is Part VII.
- Release notes live in `docs/releases/<version>.typ` and compile with
  `./bin/paxos-cli docs releases` (or `typst compile --root .
  docs/releases/<version>.typ docs/build/release-<version>.pdf`).
- Benchmark numbers in the book and the READMEs come from
  `bench/results/latest.json`, written by `make bench-compare` on a quiet
  machine (`ZIG=/path/to/zig make bench-compare` when zig is not on PATH).
  Never type a number by hand.
- Design records are PODs (Paxos Odin Discussions) under `docs/pod/records/`.

Keep `README.md` and `README.ko.md` in step: same sections, same order, same
numbers.

## Adding a POD

```sh
./bin/paxos-cli pod new <slug>        # docs/pod/records/XXXXX-<slug>.typ from the template
# edit the draft: title, summary, design, alternatives, evidence
./bin/paxos-cli pod promote <slug>    # assigns the next 4-digit number, registers it
./bin/paxos-cli docs pod-NNNN         # compile just that record
./bin/paxos-cli pod list              # registry and drafts
```

`docs/pod/registry.typ` is the source of truth for the list; `promote` appends
to it and to `docs/pod/bundle.typ`. Slugs are lowercase letters, digits, and
hyphens. A POD that changes the protocol should point at the test or
simulation that demonstrates the change.

## Commits

One change per commit, with a message that states what the change protects or
enables. Reference the POD number when a design record exists.
