"""
    load_dotenv!(path::AbstractString)

Read a `.env` file and set environment variables that are not already present.
Supports `KEY=VALUE`, `KEY="VALUE"`, and `KEY='VALUE'` formats.
Lines starting with `#` are treated as comments.
"""
function load_dotenv!(path::AbstractString)
    isfile(path) || return
    for line in eachline(path)
        line = strip(line)
        isempty(line) && continue
        startswith(line, "#") && continue
        occursin("=", line) || continue
        k, v = strip.(split(line, "="; limit = 2))
        if (startswith(v, "\"") && endswith(v, "\"")) ||
           (startswith(v, "'") && endswith(v, "'"))
            v = v[2:(end - 1)]
        end
        isempty(k) && continue
        haskey(ENV, k) || (ENV[k] = v)
    end
end
