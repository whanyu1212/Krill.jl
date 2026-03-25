#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Running skills tests..."
julia --project=. test/test_skills.jl
echo "Done."
