module Sessions

using Dates
using UUIDs
using JSON3

export SessionStore,
    TurnRecord,
    clear_session!,
    get_session_lock!,
    load_history,
    append_turn!,
    save_history,
    session_dir,
    sanitize_session_key

"""
    TurnRecord

A single turn in session history. Stored as one JSONL line on disk.
"""
struct TurnRecord
    role::Symbol
    text::String
    message_id::UUID
    correlation_id::Union{Nothing,UUID}
    timestamp::DateTime
    metadata::Dict{String,Any}
end

function TurnRecord(
    role::Symbol,
    text::String,
    message_id::UUID,
    correlation_id::Union{Nothing,UUID},
    timestamp::DateTime,
)
    return TurnRecord(role, text, message_id, correlation_id, timestamp, Dict{String,Any}())
end

"""
    SessionStore(; workspace="workspace")

Manages per-session locks and JSONL history persistence.
Sessions are identified by `session_key` strings.
History files live at `workspace/sessions/<sanitized_key>/history.jsonl`.

Thread-safe: the lock map is protected by its own `ReentrantLock`.
"""
mutable struct SessionStore
    workspace::String
    locks::Dict{String,ReentrantLock}
    lock_map_lock::ReentrantLock
end

function SessionStore(; workspace::AbstractString="workspace")
    return SessionStore(String(workspace), Dict{String,ReentrantLock}(), ReentrantLock())
end

"""
    sanitize_session_key(key) -> String

Replace characters invalid in file paths (`:`  `/`  `\\`) with `_`.
"""
sanitize_session_key(key::AbstractString) = replace(String(key), r"[:/\\]" => "_")

"""
    session_dir(store, session_key) -> String

Return the directory path for a session's data files. Creates it if missing.
"""
function session_dir(store::SessionStore, session_key::AbstractString)
    dir = joinpath(store.workspace, "sessions", sanitize_session_key(session_key))
    mkpath(dir)
    return dir
end

"""
    get_session_lock!(store, session_key) -> ReentrantLock

Get or create the per-session lock. Thread-safe.
"""
function get_session_lock!(store::SessionStore, session_key::AbstractString)
    lock(store.lock_map_lock) do
        return get!(store.locks, String(session_key)) do
            ReentrantLock()
        end
    end
end

function _turn_to_dict(turn::TurnRecord)
    d = Dict{String,Any}(
        "role" => String(turn.role),
        "text" => turn.text,
        "message_id" => string(turn.message_id),
        "timestamp" => string(turn.timestamp),
    )
    if turn.correlation_id !== nothing
        d["correlation_id"] = string(turn.correlation_id)
    end
    if !isempty(turn.metadata)
        d["metadata"] = turn.metadata
    end
    return d
end

function _dict_to_turn(obj)
    metadata = Dict{String,Any}()
    if haskey(obj, :metadata) && obj[:metadata] !== nothing
        metadata = Dict{String,Any}(String(k) => v for (k, v) in pairs(obj[:metadata]))
    end
    return TurnRecord(
        Symbol(obj[:role]),
        String(obj[:text]),
        UUID(String(obj[:message_id])),
        haskey(obj, :correlation_id) && obj[:correlation_id] !== nothing ? UUID(String(obj[:correlation_id])) : nothing,
        DateTime(String(obj[:timestamp])),
        metadata,
    )
end

"""
    load_history(store, session_key) -> Vector{TurnRecord}

Load session history from the JSONL file. Returns empty vector if no file exists.
Caller must hold the session lock.
"""
function load_history(store::SessionStore, session_key::AbstractString)
    dir = session_dir(store, session_key)
    path = joinpath(dir, "history.jsonl")
    history = TurnRecord[]
    isfile(path) || return history
    for line in eachline(path)
        stripped = strip(line)
        isempty(stripped) && continue
        push!(history, _dict_to_turn(JSON3.read(stripped)))
    end
    return history
end

"""
    append_turn!(store, session_key, turn)

Append a single turn to the session's JSONL history file.
Caller must hold the session lock.
"""
function append_turn!(store::SessionStore, session_key::AbstractString, turn::TurnRecord)
    dir = session_dir(store, session_key)
    path = joinpath(dir, "history.jsonl")
    open(path, "a") do io
        println(io, JSON3.write(_turn_to_dict(turn)))
    end
    return nothing
end

"""
    save_history(store, session_key, history)

Overwrite the session's JSONL history file. Useful for truncation/compaction.
Caller must hold the session lock.
"""
function save_history(store::SessionStore, session_key::AbstractString, history::Vector{TurnRecord})
    dir = session_dir(store, session_key)
    path = joinpath(dir, "history.jsonl")
    open(path, "w") do io
        for turn in history
            println(io, JSON3.write(_turn_to_dict(turn)))
        end
    end
    return nothing
end

"""
    clear_session!(store, session_key)

Delete persisted history for a session.
"""
function clear_session!(store::SessionStore, session_key::AbstractString)
    dir = session_dir(store, String(session_key))
    isdir(dir) || return nothing
    try
        rm(dir; recursive=true, force=true)
    catch _
        # Ignore cleanup failures; callers can retry.
    end
    return nothing
end

end
