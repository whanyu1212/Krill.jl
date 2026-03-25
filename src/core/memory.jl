module Memory

using Dates
using JSON3

using ..Sessions: sanitize_session_key

export MemoryStore,
    MemoryState,
    memory_dir,
    memory_path,
    history_path,
    memory_state_path,
    load_memory,
    save_memory!,
    append_history!,
    load_memory_state,
    save_memory_state!

"""
    MemoryState

Per-session memory bookkeeping.
`last_consolidated` tracks the last archived turn index/offset.
`consolidation_failures` counts consecutive LLM failures for fallback logic.
"""
struct MemoryState
    last_consolidated::Int
    consolidation_failures::Int
end

MemoryState() = MemoryState(0, 0)
MemoryState(last_consolidated::Int) = MemoryState(last_consolidated, 0)

"""
    MemoryStore(; workspace="workspace")

Persists per-session memory files under:
`workspace/memory/<sanitized_session_key>/`.
"""
mutable struct MemoryStore
    workspace::String
end

function MemoryStore(; workspace::AbstractString="workspace")
    return MemoryStore(String(workspace))
end

"""
    memory_dir(store, session_key) -> String

Return the session memory directory, creating it if needed.
"""
function memory_dir(store::MemoryStore, session_key::AbstractString)
    dir = joinpath(store.workspace, "memory", sanitize_session_key(session_key))
    mkpath(dir)
    return dir
end

memory_path(store::MemoryStore, session_key::AbstractString) = joinpath(memory_dir(store, session_key), "MEMORY.md")
history_path(store::MemoryStore, session_key::AbstractString) = joinpath(memory_dir(store, session_key), "HISTORY.md")
memory_state_path(store::MemoryStore, session_key::AbstractString) = joinpath(memory_dir(store, session_key), "state.json")

"""
    load_memory(store, session_key) -> String

Read `MEMORY.md` for a session. Returns an empty string if missing.
"""
function load_memory(store::MemoryStore, session_key::AbstractString)
    path = memory_path(store, session_key)
    isfile(path) || return ""
    return read(path, String)
end

"""
    save_memory!(store, session_key, content)

Overwrite a session's `MEMORY.md`.
"""
function save_memory!(store::MemoryStore, session_key::AbstractString, content::AbstractString)
    path = memory_path(store, session_key)
    open(path, "w") do io
        write(io, String(content))
    end
    return nothing
end

"""
    append_history!(store, session_key, entry; timestamp=now(UTC))

Append a timestamped block to `HISTORY.md`.
"""
function append_history!(
    store::MemoryStore,
    session_key::AbstractString,
    entry::AbstractString;
    timestamp::DateTime=now(UTC),
)
    text = strip(String(entry))
    isempty(text) && return nothing

    path = history_path(store, session_key)
    has_content = isfile(path) && filesize(path) > 0
    open(path, "a") do io
        has_content && println(io)
        println(io, "## ", string(timestamp))
        println(io)
        println(io, text)
    end
    return nothing
end

"""
    load_memory_state(store, session_key) -> MemoryState

Load memory state for a session. Missing or invalid files return defaults.
"""
function load_memory_state(store::MemoryStore, session_key::AbstractString)
    path = memory_state_path(store, session_key)
    isfile(path) || return MemoryState()
    try
        obj = JSON3.read(read(path, String))
        last = max(0, Int(haskey(obj, :last_consolidated) ? obj[:last_consolidated] : 0))
        failures = max(0, Int(haskey(obj, :consolidation_failures) ? obj[:consolidation_failures] : 0))
        return MemoryState(last, failures)
    catch e
        @debug "Failed to load memory state, using defaults" path exception=e
        return MemoryState()
    end
end

"""
    save_memory_state!(store, session_key, state)

Persist per-session memory state metadata.
"""
function save_memory_state!(store::MemoryStore, session_key::AbstractString, state::MemoryState)
    state.last_consolidated < 0 && throw(ArgumentError("last_consolidated must be >= 0"))
    state.consolidation_failures < 0 && throw(ArgumentError("consolidation_failures must be >= 0"))
    path = memory_state_path(store, session_key)
    payload = Dict{String,Any}(
        "last_consolidated" => state.last_consolidated,
        "consolidation_failures" => state.consolidation_failures,
    )
    open(path, "w") do io
        write(io, JSON3.write(payload))
    end
    return nothing
end

end
