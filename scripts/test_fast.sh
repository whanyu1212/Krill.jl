#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  find "${ROOT_DIR}" -type f -name '._*' -delete || true
}

trap cleanup EXIT

export KRILL_FAST_TESTS="${KRILL_FAST_TESTS:-1}"
julia --project="${ROOT_DIR}" -e 'using Pkg; Pkg.test()'
