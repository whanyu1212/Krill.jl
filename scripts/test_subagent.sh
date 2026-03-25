#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Running subagent tests..."
julia --project=. --threads=4 test/test_subagent.jl
echo "Done."
