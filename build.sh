#!/usr/bin/env bash
set -euo pipefail

# Paxos-Odin Bootstrap Build Script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p bin
echo "==> Building Paxos-Odin CLI (bin/paxos-cli)..."
odin build cli -out:bin/paxos-cli -o:speed

echo "==> CLI built successfully."
echo "You can now run:"
echo "  ./bin/paxos-cli build all"
echo "  ./bin/paxos-cli test"
echo "  ./bin/paxos-cli sim --seed=42"
echo "  ./bin/paxos-cli bench"
echo "  ./bin/paxos-cli docs all"
