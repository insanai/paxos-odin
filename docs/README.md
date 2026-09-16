# Paxos-Odin Documentation & Specifications

This directory contains the formal design documentation, specifications, and RFC proposals for the `paxos-odin` monorepo.

## Structure

- **`book.typ` & `book/`**: The complete multi-chapter book and formal specification of the library, covering consensus theory, state machine mechanics, durability rules, and simulation verification.
- **`shared/`**: Shared Typst themes, palettes, and helper functions (`theme.typ`, `pod.typ`).
- **`pod/`**: **Paxos Odin Discussions (POD)**: The RFC proposal and engineering discussion records.
  - `records/`: Formally numbered discussion records (`NNNN-<slug>.typ`).
  - `template/`: Starter template for new drafts (`rfc-template.typ`).
  - `registry.typ`: Master document index.
  - `index.typ`: Typst PDF index generator.
  - `bundle.typ`: Consolidated bundle export.
- **`releases/`**: Per-version release notes and upgrade guides.
- **`build/`**: Target directory for compiled PDF specifications.

## Building Documentation

Documentation is managed through the `paxos-cli` tool:

```sh
# Compile all documentation (Book + all POD records + Index)
./bin/paxos-cli docs all

# Compile only the master specification book
./bin/paxos-cli docs book

# Compile the POD index
./bin/paxos-cli docs index

# Compile all registered POD records
./bin/paxos-cli docs pod

# Compile a specific POD record
./bin/paxos-cli docs pod-0001
```
