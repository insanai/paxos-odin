.PHONY: all build test check vet sim bench bench-durable bench-compare docs example clean help

ODIN ?= odin
CLI = bin/paxos-cli

all: build

$(CLI): $(wildcard cli/*.odin) Makefile
	@mkdir -p bin
	$(ODIN) build cli -out:$(CLI) -o:speed

build: $(CLI)
	@./$(CLI) build all

test: $(CLI)
	@./$(CLI) test

vet:
	@python3 tools/check_style.py
	@$(ODIN) check tests -vet -strict-style -no-entry-point
	@for p in sim bench cli; do $(ODIN) check $$p -vet -strict-style || exit 1; done
	@$(ODIN) check examples/counter.odin -file -vet -strict-style

check:
	@ODIN="$(ODIN)" python3 tools/check.py

sim: $(CLI)
	@./$(CLI) sim --seed=42 --steps=1024

bench: $(CLI)
	@./$(CLI) bench

bench-durable: $(CLI)
	@./$(CLI) bench --durable

# Set ZIG=/path/to/zig when zig is not on PATH; PAXOS_ZIG_DIR points at the paxos-zig checkout.
bench-compare:
	@python3 tools/bench_compare.py

docs: $(CLI)
	@./$(CLI) docs all

example:
	@$(ODIN) run examples/counter.odin -file

clean:
	rm -rf bin/ docs/build/

help:
	@echo "Paxos-Odin targets:"
	@echo "  make build         Build the library object, simulator, benchmark, and CLI into bin/"
	@echo "  make test          Run the unit tests (odin test tests)"
	@echo "  make vet           Zen structural constraints plus -vet -strict-style on every package"
	@echo "  make check         Full verification: style, tests in both builds, contracts, fault matrix, smoke runs"
	@echo "  make sim           Run one seeded chaos simulation"
	@echo "  make bench         Run the in-memory benchmark"
	@echo "  make bench-durable Run the benchmark with a journal and fsync per commit round"
	@echo "  make bench-compare Run this library, paxos-zig, OmniPaxos, and LibPaxos3; record bench/results/"
	@echo "  make check-python  Ruff, mypy, and pytest against both native libraries"
	@echo "  make check-all     The Odin gate and the Python gate"
	@echo "  make python-wheel  Build a wheel from the sdist outside the repo and smoke-test it"
	@echo "  make python-docs   Generate the Python API reference from docstrings"
	@echo "  make docs          Compile the book and the POD records to PDF"
	@echo "  make example       Run the three-node replicated counter"
	@echo "  make clean         Remove built binaries and PDFs"

.PHONY: check-python
# Ruff is the linter and the formatter; tools/check_style.py adds only the two
# structural limits ruff cannot express. The suite runs twice: once against the
# shipped .Host_Managed library and once against the .Enforced twin, so a bridge
# ordering bug fails loudly instead of shipping.
check-python:
	@python3 tools/check_style.py
	@cd python/paxodin && uv sync --quiet
	@cd python/paxodin && uv run ruff check .
	@cd python/paxodin && uv run ruff format --check .
	@cd python/paxodin && uv run mypy
	@cd python/paxodin && uv run pytest -q --doctest-modules src/paxodin
	@cd python/paxodin && uv run pytest -q
	@cd python/paxodin && PAXODIN_LIB=enforced uv run pytest -q
	@cd python/paxodin && uv run python examples/counter.py >/dev/null
	@echo "All Python checks passed."

.PHONY: check-all
# Everything CI runs: the Odin gate, then the Python gate.
check-all: check check-python

.PHONY: python-docs python-wheel
python-docs:
	@cd python/paxodin && uv run --group docs mkdocs build --strict

# Builds the sdist, then the wheel from that sdist in a directory outside the
# repository, so a path such as ../../src can never be a hidden requirement.
python-wheel:
	@cd python/paxodin && uv build --sdist
	@python3 tools/check_wheel.py

.PHONY: bench-matched bench-profile
bench-matched:
	python3 tools/matched_compare.py

bench-profile:
	python3 tools/matched_compare.py --profile-build --build-only --output=bin/profile-build.json
	python3 tools/matched_profile.py bin/profile-build.json
