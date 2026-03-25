module DurableQueue

using Dates
using UUIDs
using JSON3

using ..Types: InboundMessage, OutboundMessage, TextPart, ContentPart, DeliveryPolicy

export DurableQueueState,
    enqueue!,
    ack!,
    replay,
    compact!,
    queue_stats

"""
    DurableQueueState(; wal_path, auto_compact_threshold=1000)

Append-only WAL (write-ahead log) for crash-recoverable message queuing.

Each entry is a JSONL line with `op` = `"enqueue"` or `"ack"`.
On startup, call `replay(dq)` to recover unacked messages.

`auto_compact_threshold`: when the WAL exceeds this many lines, `compact!` is
called automatically on the next `ack!`.
"""
mutable struct DurableQueueState
    wal_path::String
    auto_compact_threshold::Int
    enqueued_count::Int
    acked_count::Int
    wal_lines::Int
    lock::ReentrantLock
end

function DurableQueueState(;
    wal_path::AbstractString,
    auto_compact_threshold::Int=1000,
)
    path = String(wal_path)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    return DurableQueueState(path, auto_compact_threshold, 0, 0, _count_lines(path), ReentrantLock())
end

function _count_lines(path::AbstractString)
    isfile(path) || return 0
    count = 0
    open(path, "r") do io
        while !eof(io)
            readline(io)
            count += 1
        end
    end
    return count
end

function _serialize_inbound(msg::InboundMessage)
    text_parts = String[]
    for part in msg.content_parts
        part isa TextPart && push!(text_parts, part.text)
    end
    return Dict{String,Any}(
        "type" => "inbound",
        "message_id" => string(msg.message_id),
        "idempotency_key" => msg.idempotency_key,
        "correlation_id" => msg.correlation_id === nothing ? nothing : string(msg.correlation_id),
        "channel" => String(msg.channel),
        "session_key" => msg.session_key,
        "user_id" => msg.user_id,
        "chat_id" => msg.chat_id,
        "timestamp" => string(msg.timestamp),
        "text" => join(text_parts, "\n"),
    )
end

function _serialize_outbound(msg::OutboundMessage)
    text_parts = String[]
    for part in msg.content_parts
        part isa TextPart && push!(text_parts, part.text)
    end
    policy = msg.delivery_policy
    return Dict{String,Any}(
        "type" => "outbound",
        "message_id" => string(msg.message_id),
        "correlation_id" => msg.correlation_id === nothing ? nothing : string(msg.correlation_id),
        "channel" => String(msg.channel),
        "session_key" => msg.session_key,
        "chat_id" => msg.chat_id,
        "timestamp" => string(msg.timestamp),
        "text" => join(text_parts, "\n"),
        "format" => String(msg.format),
        "max_retries" => policy.max_retries,
        "timeout_ms" => policy.timeout_ms,
        "priority" => policy.priority,
        "drop_if_late" => policy.drop_if_late,
    )
end

function _deserialize_inbound(d::Dict{String,Any})
    return InboundMessage(
        channel=Symbol(d["channel"]),
        session_key=d["session_key"],
        user_id=d["user_id"],
        chat_id=d["chat_id"],
        text=d["text"],
        message_id=UUID(d["message_id"]),
        idempotency_key=d["idempotency_key"],
        correlation_id=d["correlation_id"] === nothing ? nothing : UUID(d["correlation_id"]),
        timestamp=DateTime(d["timestamp"]),
    )
end

function _deserialize_outbound(d::Dict{String,Any})
    return OutboundMessage(
        channel=Symbol(d["channel"]),
        session_key=d["session_key"],
        chat_id=d["chat_id"],
        text=d["text"],
        message_id=UUID(d["message_id"]),
        correlation_id=d["correlation_id"] === nothing ? nothing : UUID(d["correlation_id"]),
        timestamp=DateTime(d["timestamp"]),
        format=Symbol(d["format"]),
        delivery_policy=DeliveryPolicy(
            max_retries=d["max_retries"],
            timeout_ms=d["timeout_ms"],
            priority=d["priority"],
            drop_if_late=d["drop_if_late"],
        ),
    )
end

"""
    enqueue!(dq, msg::Union{InboundMessage, OutboundMessage})

Persist a message to the WAL before processing. Returns the message_id.
"""
function enqueue!(dq::DurableQueueState, msg::Union{InboundMessage,OutboundMessage})
    serialized = msg isa InboundMessage ? _serialize_inbound(msg) : _serialize_outbound(msg)
    entry = Dict{String,Any}(
        "op" => "enqueue",
        "message_id" => string(msg.message_id),
        "ts" => string(now(UTC)),
        "payload" => serialized,
    )
    lock(dq.lock) do
        open(dq.wal_path, "a") do io
            println(io, JSON3.write(entry))
        end
        dq.enqueued_count += 1
        dq.wal_lines += 1
    end
    return msg.message_id
end

"""
    ack!(dq, message_id::UUID)

Mark a message as successfully processed. Triggers auto-compaction if threshold exceeded.
"""
function ack!(dq::DurableQueueState, message_id::UUID)
    entry = Dict{String,Any}(
        "op" => "ack",
        "message_id" => string(message_id),
        "ts" => string(now(UTC)),
    )
    should_compact = false
    lock(dq.lock) do
        open(dq.wal_path, "a") do io
            println(io, JSON3.write(entry))
        end
        dq.acked_count += 1
        dq.wal_lines += 1
        should_compact = dq.wal_lines >= dq.auto_compact_threshold
    end
    should_compact && compact!(dq)
    return nothing
end

"""
    replay(dq) -> (inbound=Vector{InboundMessage}, outbound=Vector{OutboundMessage})

Read the WAL and return all unacked messages, preserving original order.
Call this on startup to recover messages that were enqueued but not acked.
"""
function replay(dq::DurableQueueState)
    inbound = InboundMessage[]
    outbound = OutboundMessage[]
    isfile(dq.wal_path) || return (inbound=inbound, outbound=outbound)

    enqueued = Dict{String,Dict{String,Any}}()  # message_id -> payload
    acked = Set{String}()
    order = String[]  # preserve insertion order

    lock(dq.lock) do
        open(dq.wal_path, "r") do io
            while !eof(io)
                line = strip(readline(io))
                isempty(line) && continue
                local entry
                try
                    entry = JSON3.read(line, Dict{String,Any})
                catch e
                    @debug "Skipping corrupted WAL line during replay" exception=e
                    continue
                end
                op = get(entry, "op", "")
                mid = get(entry, "message_id", "")
                if op == "enqueue" && haskey(entry, "payload")
                    enqueued[mid] = entry["payload"] isa Dict{String,Any} ? entry["payload"] : Dict{String,Any}(entry["payload"]...)
                    push!(order, mid)
                elseif op == "ack"
                    push!(acked, mid)
                end
            end
        end
    end

    seen = Set{String}()
    for mid in order
        mid in acked && continue
        mid in seen && continue
        push!(seen, mid)
        payload = get(enqueued, mid, nothing)
        payload === nothing && continue
        msg_type = get(payload, "type", "")
        if msg_type == "inbound"
            push!(inbound, _deserialize_inbound(payload))
        elseif msg_type == "outbound"
            push!(outbound, _deserialize_outbound(payload))
        end
    end

    return (inbound=inbound, outbound=outbound)
end

"""
    compact!(dq)

Rewrite the WAL, removing all acked entries. This reduces file size.
"""
function compact!(dq::DurableQueueState)
    lock(dq.lock) do
        isfile(dq.wal_path) || return nothing

        # Read current WAL
        enqueued = Dict{String,String}()  # message_id -> original line
        acked = Set{String}()
        order = String[]

        open(dq.wal_path, "r") do io
            while !eof(io)
                line = strip(readline(io))
                isempty(line) && continue
                local entry
                try
                    entry = JSON3.read(line, Dict{String,Any})
                catch e
                    @debug "Skipping corrupted WAL line during compaction" exception=e
                    continue
                end
                op = get(entry, "op", "")
                mid = get(entry, "message_id", "")
                if op == "enqueue"
                    enqueued[mid] = line
                    push!(order, mid)
                elseif op == "ack"
                    push!(acked, mid)
                end
            end
        end

        # Rewrite with only unacked entries
        tmp_path = dq.wal_path * ".tmp"
        lines_written = 0
        open(tmp_path, "w") do io
            seen = Set{String}()
            for mid in order
                mid in acked && continue
                mid in seen && continue
                push!(seen, mid)
                line = get(enqueued, mid, nothing)
                line === nothing && continue
                println(io, line)
                lines_written += 1
            end
        end

        mv(tmp_path, dq.wal_path; force=true)
        dq.wal_lines = lines_written
    end
    return nothing
end

"""
    queue_stats(dq) -> Dict{String,Any}
"""
function queue_stats(dq::DurableQueueState)
    return Dict{String,Any}(
        "enqueued" => dq.enqueued_count,
        "acked" => dq.acked_count,
        "wal_lines" => dq.wal_lines,
        "wal_path" => dq.wal_path,
    )
end

end
