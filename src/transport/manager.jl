module ChannelManager

using ..Types: OutboundMessage
using ..MessageHub: MessageHubState, try_take_outbound!
using Dates
using UUIDs
using JSON3

export ChannelManagerState,
    DispatchEvent,
    register_sender!,
    start_dispatch!,
    stop_dispatch!,
    dispatch_stats,
    dead_letters,
    flush_dead_letters!

"""
    DispatchEvent

Emitted after each dispatch attempt. Passed to the optional `on_dispatch` callback.

Fields:
- `message_id`: UUID of the outbound message
- `correlation_id`: UUID of the inbound message that triggered this outbound (or nothing)
- `channel`: target channel symbol
- `session_key`: session that produced this message
- `chat_id`: target chat
- `outcome`: `:delivered`, `:failed`, `:dropped`, or `:no_sender`
- `reason`: human-readable reason (empty on success)
- `attempts`: number of send attempts made
- `elapsed_ms`: wall-clock time spent on delivery
- `error`: the last error (or nothing)
- `timestamp`: when the event was recorded
"""
struct DispatchEvent
    message_id::UUID
    correlation_id::Union{Nothing,UUID}
    channel::Symbol
    session_key::String
    chat_id::String
    outcome::Symbol
    reason::String
    attempts::Int
    elapsed_ms::Int
    error::Union{Nothing,Exception}
    timestamp::DateTime
end

"""
    ChannelManagerState(hub::MessageHubState; on_dispatch=nothing, dead_letter_path=nothing)

Manages channel sender registration and asynchronous outbound message dispatch.
Consumes messages from the hub's outbound queue and routes each to the sender
registered for that message's `channel` symbol.

Optional callbacks:
- `on_dispatch`: called with a `DispatchEvent` after every delivery attempt
- `dead_letter_path`: file path for persistent dead-letter log (JSONL)

Use [`register_sender!`](@ref) to associate a channel name with a send function,
then [`start_dispatch!`](@ref) / [`stop_dispatch!`](@ref) to control the dispatch loop.
"""
mutable struct ChannelManagerState
    hub::MessageHubState
    senders::Dict{Symbol,Function}
    running::Bool
    dispatch_task::Union{Nothing,Task}
    stop_signal::Channel{Nothing}
    pending::Vector{OutboundMessage}
    dead_letters::Vector{Dict{String,Any}}
    delivered_count::Int
    failed_count::Int
    dropped_count::Int
    last_successful_send_at::Union{Nothing,DateTime}
    on_dispatch::Union{Nothing,Function}
    dead_letter_path::Union{Nothing,String}
end

function ChannelManagerState(
    hub::MessageHubState;
    on_dispatch::Union{Nothing,Function} = nothing,
    dead_letter_path::Union{Nothing,AbstractString} = nothing,
)
    return ChannelManagerState(
        hub,
        Dict{Symbol,Function}(),
        false,
        nothing,
        Channel{Nothing}(1),
        OutboundMessage[],
        Dict{String,Any}[],
        0,
        0,
        0,
        nothing,
        on_dispatch,
        dead_letter_path === nothing ? nothing : String(dead_letter_path),
    )
end

"""
    register_sender!(manager, channel::Symbol, sender::Function)

Register `sender` as the delivery function for `channel`.
`sender` will be called with a single [`OutboundMessage`](@ref) argument.
Overwrites any previously registered sender for the same channel.
"""
function register_sender!(manager::ChannelManagerState, channel::Symbol, sender::Function)
    manager.senders[channel] = sender
    return manager
end

"""
    dispatch_stats(manager) -> Dict{String,Any}

Return delivery statistics: counts, last success time, dead letter count.
"""
function dispatch_stats(manager::ChannelManagerState)
    return Dict{String,Any}(
        "delivered" => manager.delivered_count,
        "failed" => manager.failed_count,
        "dropped" => manager.dropped_count,
        "dead_letters" => length(manager.dead_letters),
        "last_successful_send_at" => manager.last_successful_send_at,
        "pending" => length(manager.pending),
    )
end

"""
    dead_letters(manager) -> Vector{Dict{String,Any}}

Return a copy of the dead-letter log.
"""
dead_letters(manager::ChannelManagerState) = copy(manager.dead_letters)

"""
    flush_dead_letters!(manager) -> Vector{Dict{String,Any}}

Return and clear the dead-letter log.
"""
function flush_dead_letters!(manager::ChannelManagerState)
    flushed = copy(manager.dead_letters)
    empty!(manager.dead_letters)
    return flushed
end

_is_retriable_status_code(code::Int) = code == 408 || code == 429 || (500 <= code <= 599)

function _extract_error_code(err)
    if hasproperty(err, :code)
        code = try
            Int(getproperty(err, :code))
        catch _
            nothing
        end
        code === nothing || return code
    end
    return nothing
end

function _is_retriable_send_error(err)
    # Network-level errors are always retriable
    (err isa Base.IOError || err isa EOFError) && return true
    # Check for HTTP-like status codes on other error types
    code = _extract_error_code(err)
    code === nothing && return false
    return _is_retriable_status_code(code)
end

function _attempt_send(sender::Function, msg::OutboundMessage; timeout_ms::Int)
    task = Threads.@spawn begin
        try
            sender(msg)
            return (ok = true, error = nothing)
        catch err
            return (ok = false, error = err)
        end
    end
    if timeout_ms > 0
        timeout_s = timeout_ms / 1000
        poll_s = max(0.001, min(0.01, timeout_s / 5))
        wait_result = timedwait(() -> istaskdone(task), timeout_s; pollint = poll_s)
        if wait_result == :timed_out
            return (ok = false, retriable = true, error = ErrorException("send timeout after $(timeout_ms) ms"))
        end
    end

    result = fetch(task)
    result.ok && return (ok = true, retriable = false, error = nothing)
    return (ok = false, retriable = _is_retriable_send_error(result.error), error = result.error)
end

function _message_age_ms(msg::OutboundMessage)
    return Dates.value(now(UTC) - msg.timestamp)
end

function _record_dead_letter!(manager::ChannelManagerState, msg::OutboundMessage, reason::String; error = nothing)
    entry = Dict{String,Any}(
        "message_id" => string(msg.message_id),
        "correlation_id" => msg.correlation_id === nothing ? nothing : string(msg.correlation_id),
        "channel" => String(msg.channel),
        "session_key" => msg.session_key,
        "chat_id" => msg.chat_id,
        "reason" => reason,
        "timestamp" => string(now(UTC)),
    )
    error === nothing || (entry["error"] = sprint(showerror, error))
    push!(manager.dead_letters, entry)

    # Persist to disk if configured
    if manager.dead_letter_path !== nothing
        try
            dir = dirname(manager.dead_letter_path)
            isempty(dir) || mkpath(dir)
            open(manager.dead_letter_path, "a") do io
                println(io, JSON3.write(entry))
            end
        catch e
            @warn "failed to persist dead letter" path=manager.dead_letter_path exception=(e, catch_backtrace())
        end
    end
    return nothing
end

function _emit_dispatch_event!(
    manager::ChannelManagerState,
    msg::OutboundMessage,
    outcome::Symbol,
    reason::String,
    attempts::Int,
    elapsed_ms::Int;
    error = nothing,
)
    @debug "dispatch" message_id=msg.message_id correlation_id=msg.correlation_id channel=msg.channel session_key=msg.session_key outcome=outcome attempts=attempts elapsed_ms=elapsed_ms

    manager.on_dispatch === nothing && return nothing
    event = DispatchEvent(
        msg.message_id,
        msg.correlation_id,
        msg.channel,
        msg.session_key,
        msg.chat_id,
        outcome,
        reason,
        attempts,
        elapsed_ms,
        error,
        now(UTC),
    )
    try
        manager.on_dispatch(event)
    catch e
        @warn "on_dispatch callback failed" exception=(e, catch_backtrace())
    end
    return nothing
end

function _delivery_sort_key(msg::OutboundMessage)
    return (-msg.delivery_policy.priority, msg.timestamp)
end

function _enqueue_pending!(manager::ChannelManagerState, msg::OutboundMessage)
    push!(manager.pending, msg)
    sort!(manager.pending; by = _delivery_sort_key)
    return nothing
end

function _take_next_outbound!(manager::ChannelManagerState)
    if !isempty(manager.pending)
        return popfirst!(manager.pending)
    end

    msg = try_take_outbound!(manager.hub)
    msg === nothing && return nothing

    _enqueue_pending!(manager, msg)
    while true
        extra = try_take_outbound!(manager.hub)
        extra === nothing && break
        _enqueue_pending!(manager, extra)
    end
    return popfirst!(manager.pending)
end

function _dispatch_with_policy!(manager::ChannelManagerState, sender::Function, msg::OutboundMessage)
    t0 = time()
    policy = msg.delivery_policy
    timeout_ms = policy.timeout_ms
    if policy.drop_if_late && timeout_ms > 0
        age_ms = _message_age_ms(msg)
        if age_ms > timeout_ms
            manager.dropped_count += 1
            elapsed = round(Int, (time() - t0) * 1000)
            @warn "dropping late outbound message" message_id=msg.message_id correlation_id=msg.correlation_id channel=msg.channel session_key=msg.session_key age_ms=age_ms timeout_ms=timeout_ms
            _record_dead_letter!(manager, msg, "drop_if_late")
            _emit_dispatch_event!(
                manager,
                msg,
                :dropped,
                "drop_if_late: age $(age_ms)ms > timeout $(timeout_ms)ms",
                0,
                elapsed,
            )
            return false
        end
    end

    attempts = max(1, policy.max_retries + 1)
    last_error = nothing
    for attempt in 1:attempts
        result = _attempt_send(sender, msg; timeout_ms = timeout_ms)
        if result.ok
            manager.delivered_count += 1
            manager.last_successful_send_at = now(UTC)
            elapsed = round(Int, (time() - t0) * 1000)
            _emit_dispatch_event!(manager, msg, :delivered, "", attempt, elapsed)
            return true
        end

        last_error = result.error
        should_retry = result.retriable && attempt < attempts
        if should_retry
            sleep(0.5 * 2.0^(attempt - 1))
            continue
        end
        break
    end

    elapsed = round(Int, (time() - t0) * 1000)
    manager.failed_count += 1
    _record_dead_letter!(manager, msg, "send_failed"; error = last_error)
    _emit_dispatch_event!(manager, msg, :failed, "send_failed", attempts, elapsed; error = last_error)
    @error "channel sender failed" message_id=msg.message_id correlation_id=msg.correlation_id channel=msg.channel session_key=msg.session_key chat_id=msg.chat_id error=last_error
    return false
end

function _dispatch_once!(manager::ChannelManagerState, msg::OutboundMessage)
    sender = get(manager.senders, msg.channel, nothing)
    if sender === nothing
        manager.failed_count += 1
        _record_dead_letter!(manager, msg, "sender_not_registered")
        _emit_dispatch_event!(manager, msg, :no_sender, "sender_not_registered", 0, 0)
        @warn "no sender registered for channel" message_id=msg.message_id correlation_id=msg.correlation_id channel=msg.channel
        return false
    end

    return _dispatch_with_policy!(manager, sender, msg)
end

function _drain_outbound!(manager::ChannelManagerState)
    while true
        msg = _take_next_outbound!(manager)
        msg === nothing && break
        _dispatch_once!(manager, msg)
    end
end

"""
    start_dispatch!(manager) -> manager

Start the background dispatch loop. Messages on the hub's outbound queue are
consumed and routed to the appropriate registered sender.

No-op if dispatch is already running.
"""
function start_dispatch!(manager::ChannelManagerState)
    manager.running && return manager
    manager.running = true

    manager.dispatch_task = Threads.@spawn begin
        while true
            msg = _take_next_outbound!(manager)
            if msg !== nothing
                _dispatch_once!(manager, msg)
                continue
            end
            if isready(manager.stop_signal)
                take!(manager.stop_signal)
                break
            end
            sleep(0.01)
        end
        _drain_outbound!(manager)
    end

    return manager
end

"""
    stop_dispatch!(manager) -> manager

Signal the dispatch loop to stop. The loop drains any remaining outbound messages
before exiting. The hub's outbound channel remains open and usable.
"""
function stop_dispatch!(manager::ChannelManagerState)
    manager.running = false

    try
        put!(manager.stop_signal, nothing)
    catch _
        # already signaled
    end

    task = manager.dispatch_task
    if task !== nothing && !istaskdone(task)
        wait(task)
    end

    manager.dispatch_task = nothing
    manager.stop_signal = Channel{Nothing}(1)
    empty!(manager.pending)
    return manager
end

end
