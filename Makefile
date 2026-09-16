.PHONY: all build test sim bench docs clean help

ODIN ?= odin
CLI = bin/paxos-cli

all: build

$(CLI):
	@mkdir -p bin
	$(ODIN) build cli -out:$(CLI) -o:speed

build: $(CLI)
	@./$(CLI) build all

test: $(CLI)
	@./$(CLI) test

sim: $(CLI)
	@./$(CLI) sim --seed=42 --steps=1024

bench: $(CLI)
	@./$(CLI) bench

docs: $(CLI)
	@./$(CLI) docs all

clean:
	rm -rf bin/ docs/build/

help:
	@echo "Paxos-Odin Build & Management Targets:"
	@echo "  make build  - Build library and all binaries into bin/"
	@echo "  make test   - Run unit tests"
	@echo "  make sim    - Run chaos simulation (1024 steps)"
	@echo "  make bench  - Run in-memory performance benchmark"
	@echo "  make docs   - Compile Typst specification book and POD records"
	@echo "  make clean  - Remove built binaries and documentation PDFs"
