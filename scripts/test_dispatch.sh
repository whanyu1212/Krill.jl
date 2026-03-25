#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Running dispatch observability tests..."
julia --project=. --threads=4 test/test_dispatch.jl
echo "Done."
