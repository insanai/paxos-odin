# Paxos Odin Discussions (POD)

Paxos Odin Discussions (POD) are the RFC-style design and architectural records for the `paxos-odin` project. Modeled directly after the Zen Discussion Series (ZDS) from `zenfmt`, each POD is a standalone Typst document stored under `docs/pod/records/`, with metadata centrally indexed in `docs/pod/registry.typ`.

## Workflow Layout

- `records/`: One Typst document per discussion (`NNNN-<slug>.typ`).
- `template/rfc-template.typ`: Starting template for placeholder drafts (`XXXXX-<slug>.typ`).
- `registry.typ`: Central metadata registry driving the index and bundle output.
- `index.typ`: Typst discussion index document.
- `bundle.typ`: Consolidated document combining all POD records.
- `../shared/pod.typ` & `../shared/theme.typ`: Shared document framing, styling, badges, and layout macros.

## Management via CLI

The `paxos-cli` tool automates the POD lifecycle:

```sh
# 1. List registered POD records and active drafts
./bin/paxos-cli pod list

# 2. Create a new placeholder draft from the template
./bin/paxos-cli pod new <slug>

# 3. Promote a draft to the next sequential 4-digit number and register it
./bin/paxos-cli pod promote <slug>

# 4. Compile documents to PDF via Typst
./bin/paxos-cli docs pod            # Compiles all POD records to docs/build/
./bin/paxos-cli docs pod-0001       # Compiles POD 0001
./bin/paxos-cli docs index          # Compiles the POD index PDF
./bin/paxos-cli docs book           # Compiles the Paxos Odin book / specification
```
