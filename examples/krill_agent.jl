# examples/krill_agent.jl
#
# DEPRECATED — use bin/krill.jl instead:
#   julia --project=. --threads=auto bin/krill.jl
#   julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml
#
# This wrapper exists for backward compatibility and simply delegates to
# the new entry point.

@warn "examples/krill_agent.jl is deprecated — use bin/krill.jl instead"
include(joinpath(@__DIR__, "..", "bin", "krill.jl"))
