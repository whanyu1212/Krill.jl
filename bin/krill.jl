# bin/krill.jl
#
# Thin entry point for a Krill agent. All configuration is driven by
# krill.toml — no code change required to add/remove channels or providers.
#
# Usage:
#   julia --project=. --threads=auto bin/krill.jl
#   julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Krill
using HTTP

# -- Health check server (for Cloud Run) ------------------------------------

const HEALTH_PORT = parse(Int, get(ENV, "PORT", "0"))

if HEALTH_PORT > 0
    Threads.@spawn begin
        HTTP.serve("0.0.0.0", HEALTH_PORT) do req
            HTTP.Response(200, "ok")
        end
    end
    @info "Health check listening" port=HEALTH_PORT
end

# -- CLI args ----------------------------------------------------------------

config_path = let
    i = findfirst(==("--config"), ARGS)
    (i !== nothing && i < length(ARGS)) ? ARGS[i+1] :
        joinpath(@__DIR__, "..", "krill.toml")
end

# -- Load & run --------------------------------------------------------------

config = load_config(config_path=config_path,
                     project_root=joinpath(@__DIR__, ".."))

start_agent!(config)
