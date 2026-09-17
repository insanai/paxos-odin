#!/usr/bin/env bash
set -euo pipefail

# Paxos-Odin Bootstrap Build Script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

mkdir -p bin
echo "==> Building Paxos-Odin CLI (bin/paxodin)..."
odin build cli -out:bin/paxodin -o:speed

echo "==> CLI built successfully."
echo "You can now run:"
echo "  ./bin/paxodin build all"
echo "  ./bin/paxodin test"
echo "  ./bin/paxodin sim --seed=42"
echo "  ./bin/paxodin bench"
echo "  ./bin/paxodin docs all"
