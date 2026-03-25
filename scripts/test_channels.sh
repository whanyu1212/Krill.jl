#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Running channel tests..."
julia --project --threads=auto test/test_channels.jl
