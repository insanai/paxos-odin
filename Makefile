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
	@echo "  make docs          Compile the book and the POD records to PDF"
	@echo "  make example       Run the three-node replicated counter"
	@echo "  make clean         Remove built binaries and PDFs"
