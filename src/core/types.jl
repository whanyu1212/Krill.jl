module Types

using Dates
using UUIDs

export ContentPart,
    TextPart,
    BinaryPart,
    ToolCallPart,
    ToolResultPart,
    DeliveryPolicy,
    ErrorEnvelope,
    InboundMessage,
    OutboundMessage,
    ToolCallEvent,
    ToolResultEvent,
    message_text

"""
    ContentPart

Abstract supertype for message content parts.
Concrete subtypes: [`TextPart`](@ref), [`BinaryPart`](@ref), [`ToolCallPart`](@ref), [`ToolResultPart`](@ref).
"""
abstract type ContentPart end

"""
    TextPart(text::String)

Plain text content within a message.
"""
struct TextPart <: ContentPart
    text::String
end

"""
    BinaryPart(media_type, url, bytes, filename)

Binary media content (image, audio, document, etc.) within a message.
"""
struct BinaryPart <: ContentPart
    media_type::String
    url::Union{Nothing,String}
    bytes::Union{Nothing,Vector{UInt8}}
    filename::Union{Nothing,String}
end

"""
    ToolCallPart(tool_name, arguments)

Records a tool invocation request within a message.
"""
struct ToolCallPart <: ContentPart
    tool_name::String
    arguments::Dict{String,Any}
end

"""
    ToolResultPart(tool_name, result, is_error)

Records a tool execution result within a message.
"""
struct ToolResultPart <: ContentPart
    tool_name::String
    result::Any
    is_error::Bool
end

"""
    DeliveryPolicy(; max_retries=3, timeout_ms=30_000, priority=0, drop_if_late=false)

Controls outbound message delivery behaviour — retry budget, timeout, priority, and
whether the message may be silently dropped if delivery is late.

Throws `ArgumentError` if `max_retries` or `timeout_ms` is negative.
"""
struct DeliveryPolicy
    max_retries::Int
    timeout_ms::Int
    priority::Int
    drop_if_late::Bool

    function DeliveryPolicy(; max_retries::Int=3, timeout_ms::Int=30_000, priority::Int=0, drop_if_late::Bool=false)
        max_retries < 0 && throw(ArgumentError("max_retries must be >= 0"))
        timeout_ms < 0 && throw(ArgumentError("timeout_ms must be >= 0"))
        return new(max_retries, timeout_ms, priority, drop_if_late)
    end
end

"""
    ErrorEnvelope(code, message, retriable, details)

Structured error representation propagated through the runtime.
`retriable` indicates whether the caller should attempt a retry.
"""
struct ErrorEnvelope
    code::String
    message::String
    retriable::Bool
    details::Dict{String,Any}
end

"""
    InboundMessage(; channel, session_key, user_id, chat_id, text, ...)

A message arriving from an external channel (user → runtime).

Required keyword arguments: `channel`, `session_key`, `user_id`, `chat_id`, `text`.
All other fields have sensible defaults (auto-generated UUIDs, current UTC timestamp, etc.).
"""
struct InboundMessage
    version::Int
    message_id::UUID
    idempotency_key::String
    correlation_id::Union{Nothing,UUID}
    channel::Symbol
    session_key::String
    user_id::String
    chat_id::String
    timestamp::DateTime
    content_parts::Vector{ContentPart}
    metadata::Dict{String,Any}
    raw::Any
end

function InboundMessage(;
    channel::Symbol,
    session_key::AbstractString,
    user_id::AbstractString,
    chat_id::AbstractString,
    text::AbstractString="",
    version::Int=1,
    message_id::UUID=uuid4(),
    idempotency_key::AbstractString=string(message_id),
    correlation_id::Union{Nothing,UUID}=nothing,
    timestamp::DateTime=now(UTC),
    content_parts::Union{Nothing,Vector{ContentPart}}=nothing,
    metadata::Dict{String,Any}=Dict{String,Any}(),
    raw::Any=nothing,
)
    parts = if content_parts !== nothing
        content_parts
    else
        ContentPart[TextPart(String(text))]
    end
    return InboundMessage(
        version,
        message_id,
        String(idempotency_key),
        correlation_id,
        channel,
        String(session_key),
        String(user_id),
        String(chat_id),
        timestamp,
        parts,
        metadata,
        raw,
    )
end

"""
    OutboundMessage(; channel, session_key, chat_id, text, ...)

A message leaving the runtime toward an external channel (runtime → user).

Required keyword arguments: `channel`, `session_key`, `chat_id`, `text`.
"""
struct OutboundMessage
    version::Int
    message_id::UUID
    correlation_id::Union{Nothing,UUID}
    channel::Symbol
    session_key::String
    chat_id::String
    timestamp::DateTime
    content_parts::Vector{ContentPart}
    format::Symbol
    delivery_policy::DeliveryPolicy
    metadata::Dict{String,Any}
end

function OutboundMessage(;
    channel::Symbol,
    session_key::AbstractString,
    chat_id::AbstractString,
    text::AbstractString,
    version::Int=1,
    message_id::UUID=uuid4(),
    correlation_id::Union{Nothing,UUID}=nothing,
    timestamp::DateTime=now(UTC),
    format::Symbol=:plain,
    delivery_policy::DeliveryPolicy=DeliveryPolicy(),
    metadata::Dict{String,Any}=Dict{String,Any}(),
)
    return OutboundMessage(
        version,
        message_id,
        correlation_id,
        channel,
        String(session_key),
        String(chat_id),
        timestamp,
        ContentPart[TextPart(String(text))],
        format,
        delivery_policy,
        metadata,
    )
end

"""
    ToolCallEvent(; session_key, tool_name, arguments=Dict(), ...)

Event recording a tool invocation request within a session.
"""
struct ToolCallEvent
    version::Int
    event_id::UUID
    correlation_id::Union{Nothing,UUID}
    session_key::String
    tool_name::String
    arguments::Dict{String,Any}
    timestamp::DateTime
end

function ToolCallEvent(;
    session_key::AbstractString,
    tool_name::AbstractString,
    arguments::Dict{String,Any}=Dict{String,Any}(),
    version::Int=1,
    event_id::UUID=uuid4(),
    correlation_id::Union{Nothing,UUID}=nothing,
    timestamp::DateTime=now(UTC),
)
    return ToolCallEvent(
        version,
        event_id,
        correlation_id,
        String(session_key),
        String(tool_name),
        arguments,
        timestamp,
    )
end

"""
    ToolResultEvent(; session_key, tool_name, result=nothing, error=nothing, ...)

Event recording the outcome of a tool execution.
Carries either `result` (on success) or `error` ([`ErrorEnvelope`](@ref)).
"""
struct ToolResultEvent
    version::Int
    event_id::UUID
    correlation_id::Union{Nothing,UUID}
    session_key::String
    tool_name::String
    result::Any
    error::Union{Nothing,ErrorEnvelope}
    timestamp::DateTime
end

function ToolResultEvent(;
    session_key::AbstractString,
    tool_name::AbstractString,
    result::Any=nothing,
    error::Union{Nothing,ErrorEnvelope}=nothing,
    version::Int=1,
    event_id::UUID=uuid4(),
    correlation_id::Union{Nothing,UUID}=nothing,
    timestamp::DateTime=now(UTC),
)
    return ToolResultEvent(
        version,
        event_id,
        correlation_id,
        String(session_key),
        String(tool_name),
        result,
        error,
        timestamp,
    )
end

"""
    message_text(msg::Union{InboundMessage, OutboundMessage}) -> String

Extract and concatenate all [`TextPart`](@ref) content from a message,
joining multiple parts with newlines.
"""
function message_text(msg::Union{InboundMessage,OutboundMessage})
    chunks = String[]
    for part in msg.content_parts
        if part isa TextPart
            push!(chunks, part.text)
        end
    end
    return join(chunks, "\n")
end

end
