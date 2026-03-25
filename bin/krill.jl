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
