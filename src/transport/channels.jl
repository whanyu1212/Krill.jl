module ChannelInterface

using Dates
using UUIDs
using ..Types: InboundMessage, OutboundMessage, message_text
using ..MessageHub: MessageHubState, try_publish_inbound!
using ..ChannelManager: ChannelManagerState, register_sender!
using ..Dedup: BoundedDedup, seen!

export AbstractChannel,
    channel_name,
    make_sender,
    normalize,
    start_channel!,
    stop_channel!,
    send_typing,
    send_direct,
    ChannelState,
    is_allowed

"""
    AbstractChannel

Abstract supertype for all channel implementations.

Every concrete channel must implement:
- `channel_name(ch) -> Symbol` — unique channel identifier (e.g. `:telegram`, `:discord`)
- `make_sender(ch) -> Function` — returns `(OutboundMessage) -> Any` sender function
- `normalize(ch, raw_event) -> Union{InboundMessage, Nothing}` — converts raw platform event to InboundMessage
- `start_channel!(ch, hub, running; dedup, on_message) -> Task` — starts the inbound event loop, returns the polling/gateway task
- `stop_channel!(ch) -> Nothing` — stops the channel (cleanup connections, etc.)

Optional:
- `send_typing(ch, chat_id) -> Nothing` — sends typing indicator (default: no-op)
- `send_direct(ch, chat_id, text; kwargs...) -> Any` — sends a message directly bypassing the outbound queue (for tools, progress hints)
"""
abstract type AbstractChannel end

"""
    channel_name(ch::AbstractChannel) -> Symbol

Return the unique channel identifier symbol (e.g. `:telegram`, `:discord`).
"""
function channel_name end

"""
    make_sender(ch::AbstractChannel) -> Function

Return a sender function `(OutboundMessage) -> Any` suitable for `register_sender!`.
"""
function make_sender end

"""
    normalize(ch::AbstractChannel, raw_event) -> Union{InboundMessage, Nothing}

Convert a raw platform event into an `InboundMessage`. Returns `nothing` if
the event is not a recognizable message.
"""
function normalize end

"""
    start_channel!(ch::AbstractChannel, hub::MessageHubState, running::Ref{Bool};
                   dedup::Union{Nothing,BoundedDedup}=nothing,
                   on_message::Union{Nothing,Function}=nothing) -> Task

Start the channel's inbound event loop (polling, WebSocket gateway, etc.).
Returns the spawned `Task`.

The default implementation provides a standard inbound handler that:
1. Normalizes raw events via `normalize(ch, event)`
2. Deduplicates via `dedup` (if provided)
3. Publishes to the hub's inbound queue

Channels that need custom event loop behavior should override this method.
"""
function start_channel! end

"""
    stop_channel!(ch::AbstractChannel) -> Nothing

Stop the channel and clean up resources. Called during runtime shutdown.
Default implementation is a no-op.
"""
stop_channel!(::AbstractChannel) = nothing

"""
    send_typing(ch::AbstractChannel, chat_id) -> Nothing

Send a typing indicator to the given chat. Default is a no-op.
"""
send_typing(::AbstractChannel, chat_id) = nothing

"""
    send_direct(ch::AbstractChannel, chat_id, text::AbstractString; kwargs...) -> Any

Send a message directly to a chat, bypassing the outbound queue. Used by tools
and progress hints. Default throws an error.
"""
function send_direct(::AbstractChannel, chat_id, text::AbstractString; kwargs...)
    error("send_direct not implemented for this channel")
end

"""
    ChannelState

Tracks a registered channel within the runtime — holds the channel instance,
its sender, and the inbound task.
"""
mutable struct ChannelState
    channel::AbstractChannel
    sender::Function
    inbound_task::Union{Nothing,Task}
end

ChannelState(ch::AbstractChannel) = ChannelState(ch, make_sender(ch), nothing)

"""
    register_channel!(manager::ChannelManagerState, ch::AbstractChannel;
                      on_send::Union{Nothing,Function}=nothing) -> ChannelState

Register a channel's sender with the ChannelManager. If `on_send` is provided,
it wraps the sender to call `on_send()` after each successful send (e.g. to
update last_successful_send_at).

Returns a `ChannelState` ready for `start_channel!`.
"""
function register_channel!(
    manager::ChannelManagerState,
    ch::AbstractChannel;
    on_send::Union{Nothing,Function} = nothing,
)
    sender = make_sender(ch)
    wrapped_sender = if on_send !== nothing
        msg -> begin
            sender(msg)
            on_send()
            return nothing
        end
    else
        sender
    end
    register_sender!(manager, channel_name(ch), wrapped_sender)
    return ChannelState(ch, sender, nothing)
end

"""
    is_allowed(ch::AbstractChannel, user_id::AbstractString) -> Bool

Check whether `user_id` is permitted to interact with this channel.

The default implementation returns `true` (no restriction). Channel types that
carry an `allow_from` field override this: an empty list denies everyone;
`["*"]` allows everyone; otherwise the user_id must appear in the list.
"""
is_allowed(::AbstractChannel, ::AbstractString) = true

"""
    make_inbound_handler(ch::AbstractChannel, hub::MessageHubState;
                         dedup::Union{Nothing,BoundedDedup}=nothing,
                         on_poll::Union{Nothing,Function}=nothing) -> Function

Create a standard inbound handler function that normalizes, deduplicates,
and publishes events to the hub. Channels can use this in their
`start_channel!` implementation.

`on_poll` is called on every raw event before normalization (e.g. to update
last_successful_poll_at).
"""
function make_inbound_handler(
    ch::AbstractChannel,
    hub::MessageHubState;
    dedup::Union{Nothing,BoundedDedup} = nothing,
    on_poll::Union{Nothing,Function} = nothing,
)
    return function (raw_event)
        on_poll !== nothing && on_poll()

        # Dedup by platform-specific ID if available
        if dedup !== nothing
            event_id = _extract_event_id(raw_event)
            if event_id !== nothing && !seen!(dedup, event_id)
                @debug "skipping duplicate event" channel=channel_name(ch) event_id=event_id
                return
            end
        end

        msg = normalize(ch, raw_event)
        msg === nothing && return

        if !is_allowed(ch, string(msg.user_id))
            @warn "rejecting message from unlisted user" channel=channel_name(ch) user_id=msg.user_id
            return
        end

        if !try_publish_inbound!(hub, msg)
            @warn "inbound queue full, dropping event" channel=channel_name(ch) session_key=msg.session_key
        end
    end
end

"""
    _extract_event_id(raw_event) -> Union{Int, Nothing}

Try to extract an integer event ID from a raw event for deduplication.
Supports Telegram's `update_id` and Discord's message `id`.
"""
function _extract_event_id(raw_event)
    # Telegram: update_id at top level
    if raw_event isa AbstractDict || applicable(haskey, raw_event, :update_id)
        id = get(raw_event, :update_id, nothing)
        id !== nothing && return Int(id)
    end
    # Discord: message id (snowflake as Int)
    if raw_event isa AbstractDict || applicable(haskey, raw_event, :id)
        id = get(raw_event, :id, nothing)
        if id !== nothing
            return try
                parse(Int, string(id))
            catch _
                nothing
            end
        end
    end
    return nothing
end

end
