# scripts/precompile_workload.jl
#
# Exercises Krill's hot code paths so PackageCompiler captures them
# in the sysimage. Runs during `create_sysimage` — errors are expected
# (no real API keys) and silently caught.

using Krill
using HTTP
using JSON3

# Exercise config loading (will fail on missing env vars — that's fine)
try
    load_config(config_path="krill.toml", project_root=".")
catch _
end

# Exercise HTTP client paths (used by LLM providers and Telegram)
try
    HTTP.get("https://httpbin.org/status/200"; readtimeout=5)
catch _
end

# Exercise JSON3 parsing (used everywhere)
try
    JSON3.read("""{"key": "value", "list": [1,2,3]}""")
    JSON3.write(Dict("key" => "value"))
catch _
end

# Exercise tool registry (public API)
try
    reg = ToolRegistry()
    register_builtin_tools!(reg; workspace=".")
catch _
end
