# Contributing to paxos-odin

## Build and run

```sh
./build.sh          # bootstrap bin/paxodin
make build          # bin/paxos.o, bin/paxos-sim, bin/paxos-bench, bin/paxodin
make test           # odin test tests
make example        # odin run examples/counter.odin -file
make sim            # one seeded simulation
make docs           # the book and the POD records, into docs/build/

make check-python   # ruff, mypy, pytest against both native libraries
make python-wheel   # wheel from an sdist built outside the repo, on 3.12-3.14
make python-docs    # the API reference, generated from docstrings
make check-all      # everything CI runs
```

Requirements: Odin `dev-2026-09` or newer; Typst 0.15 for the documents;
Python 3 for `make check`; [uv](https://docs.astral.sh/uv/) for the Python
package in `python/paxodin/` (it fetches the interpreters it needs).

## Before you push

Run the full verification and make sure it ends with `All checks passed.`:

```sh
make check          # the Odin library
make check-python   # the Python package, when you touched python/paxodin/
```

It checks style, runs the tests in `-debug` and `-o:speed`, runs the compiler
and durability contract fixtures, runs 240 fault simulations (120 with default capacities and 120 with a small
window and flexible quorums), the counter example, the benchmark JSON
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

### Python (`python/paxodin/`)

The same structural creed applies, expressed the way Python expresses it. **Ruff
is both the linter and the formatter**; nothing is hand-rolled for formatting,
import order, naming or docstrings. `tools/check_style.py` adds exactly two rules
that ruff cannot express, sharing the Odin constants:

| Odin rule | Python enforcement |
| --- | --- |
| 99 columns soft, 108 hard | ruff `line-length = 99` |
| Files at most 1,408 lines | `tools/check_style.py` |
| Procedure bodies at most 70 logic lines | `tools/check_style.py`, via `ast` |
| `Ada_Case` / `snake_case` / `UPPER_CASE` | ruff `N` (pep8-naming) |
| Every `Error` carries a `Hint:` | the native explanation table; never a copy |

- Public API carries **Google-style docstrings** with `Args:`, `Returns:` and
  `Raises:`, saying what the rule protects rather than restating the signature.
  `make python-docs` renders them; docstring examples run under pytest.
- `mypy --strict` must pass, and `py.typed` ships.
- Exception names mirror the core's error values one for one (`.Not_Leader` ->
  `NotLeader`), which is why `N818` is disabled for `errors.py`.
- The test suite runs twice: against the shipped `.Host_Managed` library and
  against the `.Enforced` twin, which compiles the core's own durability gate in.
  A change that breaks the batch ordering must fail the second run.

## Documentation

Documentation is written in Typst. The Markdown files in the repository are
`README.md`, `README.ko.md`, this file, and `python/paxodin/README.md` with
`python/paxodin/docs/` - the last two exist because PyPI needs a
`long_description` and because the Python API reference is *generated* from
docstrings by mkdocstrings, so it cannot drift from the code. Prose about the
SDK still belongs in POD 0011 and Part IX of the book.

- The book is `docs/book.typ` with one chapter per file in `docs/book/`. The
  API reference is Part VII.
- Release notes live in `docs/releases/<version>.typ` and compile with
  `./bin/paxodin docs releases` (or `typst compile --root .
  docs/releases/<version>.typ docs/build/release-<version>.pdf`).
- Matched benchmark numbers come from the archived JSON under `bench/results/`,
  recorded by `make bench-matched`; historical CPU/durability rows retain
  `bench/results/latest.json` from `make bench-compare`. Do not mix their harnesses
  or revisions. The book loads timing tables from those files directly.
- Reproduction, profiling, and static memory instructions live in
  `docs/book/06_measurement_methods.typ`; measured recovery evidence is in POD 0009.
- Editorial guidance and documentation organization are recorded in
  `docs/pod/records/0001-pod-process.typ`. Temporary agent notes and scratch plans
  stay outside the repository. Benchmark data files are evidence, not prose documents.
- Design records are PODs (Paxos Odin Discussions) under `docs/pod/records/`.

Keep `README.md` and `README.ko.md` in step: same sections, same order, same
numbers.

## Adding a POD

```sh
./bin/paxodin pod new <slug>        # docs/pod/records/XXXXX-<slug>.typ from the template
# edit the draft: title, summary, design, alternatives, evidence
./bin/paxodin pod promote <slug>    # assigns the next 4-digit number, registers it
./bin/paxodin docs pod-NNNN         # compile just that record
./bin/paxodin pod list              # registry and drafts
```

`docs/pod/registry.typ` is the source of truth for the list; `promote` appends
to it and to `docs/pod/bundle.typ`. Slugs are lowercase letters, digits, and
hyphens. A POD that changes the protocol should point at the test or
simulation that demonstrates the change.

## Commits

One change per commit, with a message that states what the change protects or
enables. Reference the POD number when a design record exists.

## Tagged releases and website

The release version must agree in `src/paxos.odin`, `cli/main.odin`, the Python
project metadata, and `paxodin.__version__`. Update `uv.lock`, the book and Typst
release notes, then run `python3 tools/release.py version`. Push a `vX.Y.Z` tag
only on the revision intended for publication. The release workflow runs the full
verification gate and builds the CLI and standalone Python wheel on Linux x86-64,
Windows x86-64 and macOS Apple Silicon. Every wheel is installed and exercised on
Python 3.12-3.14 before the publication job uses `PYPI_API_KEY`.

Routine CI uses a short fault matrix; tags, weekly runs and manual dispatch run
the full matrix. Tests run in parallel with artifact builds on tags, but publishing
waits for all checks. Documentation-only changes skip library CI. New commits
cancel obsolete branch checks; release jobs are never cancelled by a newer tag.

`make docs && make python-docs && python3 tools/build_site.py` assembles `_site/`.
The landing page and shared reading styles live in `docs/site/`; Typst remains the
source for book and POD content. Pages deploys from `main` through GitHub Actions.
The organization must allow this repository to access its `PYPI_API_KEY` secret.
Never print, copy into source, or pass that secret to a build job.
