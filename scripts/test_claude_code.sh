#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Running Claude Code tool tests..."
julia --project=. --threads=4 test/test_claude_code.jl
echo "Done."
