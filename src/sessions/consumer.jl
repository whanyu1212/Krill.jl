module SessionConsumer

using ..Types: InboundMessage, OutboundMessage, message_text
using ..MessageHub: MessageHubState, try_take_inbound!, publish_outbound!
using ..Sessions: SessionStore, TurnRecord, get_session_lock!, load_history, append_turn!, clear_session!
using ..GlobalMemory: GlobalMemoryStore, consolidate_global_memory!

using Dates
using UUIDs

export run_session_loop!, echo_processor, SessionCancelScope, request_cancel!, is_cancelled, clear_cancel!

"""
    SessionCancelScope()

Cooperative cancellation registry for mid-turn `/stop` support.
Each session key maps to an `Atomic{Bool}` flag. The LLM processor's
`stop_check` reads this flag between tool iterations.
"""
struct SessionCancelScope
    flags::Dict{String,Threads.Atomic{Bool}}
    lock::ReentrantLock
end

SessionCancelScope() = SessionCancelScope(Dict{String,Threads.Atomic{Bool}}(), ReentrantLock())

"""
    request_cancel!(scope, session_key) -> Bool

Set the cancellation flag for a session. Returns `true` if a flag existed
(meaning a turn was in progress), `false` otherwise.
"""
function request_cancel!(scope::SessionCancelScope, session_key::AbstractString)
    key = String(session_key)
    lock(scope.lock) do
        flag = get(scope.flags, key, nothing)
        if flag !== nothing
            Threads.atomic_xchg!(flag, true)
            return true
        end
        # No active turn — pre-set the flag so next turn picks it up immediately
        scope.flags[key] = Threads.Atomic{Bool}(true)
        return false
    end
end

"""
    is_cancelled(scope, session_key) -> Bool

Check the cancellation flag for a session without clearing it.
"""
function is_cancelled(scope::SessionCancelScope, session_key::AbstractString)
    lock(scope.lock) do
        flag = get(scope.flags, String(session_key), nothing)
        flag === nothing && return false
        return flag[]
    end
end

"""
    clear_cancel!(scope, session_key) -> Threads.Atomic{Bool}

Clear the cancellation flag and return a fresh atomic for the new turn.
Call this at the start of each turn.
"""
function clear_cancel!(scope::SessionCancelScope, session_key::AbstractString)
    key = String(session_key)
    flag = Threads.Atomic{Bool}(false)
    lock(scope.lock) do
        scope.flags[key] = flag
    end
    return flag
end

const _SLASH_NEW = "new"
const _SLASH_HELP = "help"
const _SLASH_STOP = "stop"
const _SLASH_REMEMBER = "remember"

function _format_help_text(store::SessionStore, session_key::AbstractString)
    history = load_history(store, session_key)
    n_turns = length(history)
    session_age = if n_turns > 0
        first_ts = history[1].timestamp
        delta = now(UTC) - first_ts
        mins = round(Int, Dates.value(delta) / 60_000)
        if mins < 60
            "$(mins)m"
        elseif mins < 1440
            "$(mins ÷ 60)h $(mins % 60)m"
        else
            "$(mins ÷ 1440)d $(mins % 1440 ÷ 60)h"
        end
    else
        "new"
    end

    return """*Commands*
/help — this message
/new — clear session and start fresh
/stop — interrupt the running task
/remember <fact> — save a fact to your global memory

*Session*: $(n_turns) turns, age $(session_age)"""
end

function _strip_message_prefixes(text::AbstractString)
    return strip(String(text))
end

function _slash_command(text::AbstractString)
    raw = _strip_message_prefixes(text)
    !startswith(raw, "/") && return nothing
    m = match(r"^/([A-Za-z]+)\b", raw)
    m === nothing && return nothing
    return lowercase(String(m.captures[1]))
end

function _is_command_message(text::AbstractString)
    cmd = _slash_command(text)
    cmd === nothing && return nothing
    if cmd in (_SLASH_HELP, _SLASH_NEW, _SLASH_STOP, _SLASH_REMEMBER)
        return cmd
    end
    return nothing
end

function _remember_fact(text::AbstractString)
    m = match(r"^/remember\s+(.*)"is, strip(String(text)))
    m === nothing && return nothing
    fact = strip(String(m.captures[1]))
    isempty(fact) && return nothing
    return fact
end

function _publish_command_reply!(hub::MessageHubState, msg::InboundMessage, reply::AbstractString)
    reply_msg = OutboundMessage(
        channel = msg.channel,
        session_key = msg.session_key,
        chat_id = msg.chat_id,
        text = String(reply),
        correlation_id = msg.message_id,
    )
    publish_outbound!(hub, reply_msg)
    return nothing
end

function _interrupt_active_session_task!(session_tasks::Dict{String,Task}, session_key::AbstractString)
    running = get(session_tasks, String(session_key), nothing)
    if running === nothing || istaskdone(running)
        return false
    end
    try
        Base.throwto(running, InterruptException())
    catch _
        return false
    end
    return true
end

function _handle_slash_command!(
    hub::MessageHubState,
    store::SessionStore,
    msg::InboundMessage,
    command::AbstractString,
    session_tasks::Dict{String,Task};
    cancel_scope::Union{Nothing,SessionCancelScope} = nothing,
    global_memory_store::Union{Nothing,GlobalMemoryStore} = nothing,
    global_memory_provider = nothing,
)
    if command == _SLASH_HELP
        help_text = _format_help_text(store, msg.session_key)
        _publish_command_reply!(hub, msg, help_text)
        return
    end

    if command == _SLASH_NEW
        n_cleared = lock(get_session_lock!(store, msg.session_key)) do
            history = load_history(store, msg.session_key)
            n = length(history)
            clear_session!(store, msg.session_key)
            n
        end
        reply = if n_cleared > 0
            "Cleared $(n_cleared) turns. Fresh session."
        else
            "Session was already empty. Fresh start."
        end
        _publish_command_reply!(hub, msg, reply)
        return
    end

    if command == _SLASH_STOP
        # Cooperative cancellation via flag (checked between tool iterations)
        had_flag = false
        if cancel_scope !== nothing
            had_flag = request_cancel!(cancel_scope, msg.session_key)
        end
        # Also try the blunt interrupt as fallback (catches non-tool-loop blocking)
        was_interrupted = _interrupt_active_session_task!(session_tasks, msg.session_key)
        if was_interrupted || had_flag
            _publish_command_reply!(hub, msg, "Stopped. The running task has been cancelled.")
        else
            _publish_command_reply!(hub, msg, "Nothing running to stop.")
        end
        return
    end

    if command == _SLASH_REMEMBER
        fact = _remember_fact(message_text(msg))
        if fact === nothing
            _publish_command_reply!(hub, msg, "Usage: /remember <fact>")
            return
        end
        if global_memory_store === nothing || global_memory_provider === nothing
            _publish_command_reply!(hub, msg, "Global memory is not enabled.")
            return
        end
        user_id = msg.user_id
        try
            consolidate_global_memory!(global_memory_provider, global_memory_store, user_id, fact)
            _publish_command_reply!(hub, msg, "Remembered.")
        catch e
            @error "global memory consolidation failed" user_id=user_id exception=(e, catch_backtrace())
            _publish_command_reply!(hub, msg, "Failed to save to memory. Please try again.")
        end
        return
    end
end

"""
    echo_processor(msg, history) -> String

Trivial processor that echoes the inbound message text.
Placeholder for the Phase C LLM integration.
"""
echo_processor(msg::InboundMessage, history::Vector{TurnRecord}) = message_text(msg)

"""
    run_session_loop!(hub, running; store, processor, before_process, after_process)

Session-aware consumer loop. For each inbound message, spawns a task that
processes it under the session lock. Different sessions run in parallel;
same-session messages are processed in FIFO order by chaining tasks.

Drains remaining inbound messages sequentially on shutdown.
`before_process` runs before the processor call.
`after_process` runs after user+assistant turns are persisted and outbound is queued.
"""
function run_session_loop!(
    hub::MessageHubState,
    running::Ref{Bool};
    store::SessionStore = SessionStore(),
    processor::Function = echo_processor,
    before_process::Union{Nothing,Function} = nothing,
    after_process::Union{Nothing,Function} = nothing,
    cancel_scope::Union{Nothing,SessionCancelScope} = nothing,
    global_memory_store::Union{Nothing,GlobalMemoryStore} = nothing,
    global_memory_provider = nothing,
)
    # Track the last spawned task per session to enforce FIFO ordering
    session_tasks = Dict{String,Task}()
    session_tasks_lock = ReentrantLock()
    resolved_cancel_scope = cancel_scope === nothing ? SessionCancelScope() : cancel_scope

    while running[]
        msg = try_take_inbound!(hub)
        if msg === nothing
            sleep(0.01)
            continue
        end
        command = _is_command_message(message_text(msg))
        if command !== nothing
            lock(session_tasks_lock) do
                _handle_slash_command!(hub, store, msg, command, session_tasks;
                    cancel_scope = resolved_cancel_scope,
                    global_memory_store = global_memory_store,
                    global_memory_provider = global_memory_provider)
            end
            continue
        end
        _spawn_ordered!(session_tasks, session_tasks_lock, hub, store, processor, msg,
            before_process, after_process, resolved_cancel_scope)
    end

    # Wait for all in-flight tasks
    _wait_all!(session_tasks)

    # Drain remaining inbound sequentially (preserves ordering)
    while true
        msg = try_take_inbound!(hub)
        msg === nothing && break
        _process_message!(hub, store, processor, msg, before_process, after_process)
    end
end

function _spawn_ordered!(
    session_tasks::Dict{String,Task},
    session_tasks_lock::ReentrantLock,
    hub::MessageHubState,
    store::SessionStore,
    processor::Function,
    msg::InboundMessage,
    before_process::Union{Nothing,Function},
    after_process::Union{Nothing,Function},
    cancel_scope::SessionCancelScope,
)
    key = msg.session_key
    prev = get(session_tasks, key, nothing)

    task = Threads.@spawn begin
        # Wait for previous task in same session to finish (FIFO guarantee).
        if prev !== nothing && !istaskdone(prev)
            try
                wait(prev)
            catch _
                # previous task failed — continue processing
            end
        end
        # Clear (or create) the cancel flag at the start of each turn
        clear_cancel!(cancel_scope, key)
        try
            _process_message!(hub, store, processor, msg, before_process, after_process)
        catch e
            e isa InterruptException && return nothing
            @error "session task failed" session_key=key message_id=msg.message_id exception=(e, catch_backtrace())
        end
    end
    lock(session_tasks_lock) do
        session_tasks[key] = task
    end
end

function _wait_all!(session_tasks::Dict{String,Task})
    for (_, t) in session_tasks
        if !istaskdone(t)
            try
                wait(t)
            catch e
                @error "session task failed during shutdown" exception=(e, catch_backtrace())
            end
        end
    end
    empty!(session_tasks)
end

function _process_message!(
    hub::MessageHubState,
    store::SessionStore,
    processor::Function,
    msg::InboundMessage,
    before_process::Union{Nothing,Function},
    after_process::Union{Nothing,Function},
)
    session_key = msg.session_key
    session_lock = get_session_lock!(store, session_key)

    lock(session_lock) do
        history = load_history(store, session_key)

        user_text = message_text(msg)
        @info "message received" session_key=session_key chat_id=msg.chat_id chars=length(user_text) source=get(
            msg.metadata,
            "source",
            "user",
        )

        user_turn = TurnRecord(
            :user,
            user_text,
            msg.message_id,
            nothing,
            msg.timestamp,
        )

        if before_process !== nothing
            try
                before_process(msg, history)
            catch e
                @warn "before_process hook failed" session_key=session_key message_id=msg.message_id exception=(
                    e,
                    catch_backtrace(),
                )
            end
        end

        processor_result = try
            processor(msg, history)
        catch e
            e isa InterruptException && rethrow()
            @error "processor failed" session_key=session_key message_id=msg.message_id exception=(e, catch_backtrace())
            "Sorry, something went wrong."
        end

        reply_text = ""
        reply_format = :plain
        assistant_metadata = Dict{String,Any}()
        if processor_result isa AbstractString
            reply_text = String(processor_result)
        elseif processor_result isa NamedTuple
            if hasproperty(processor_result, :text)
                reply_text = String(getproperty(processor_result, :text))
            else
                reply_text = string(processor_result)
            end
            if hasproperty(processor_result, :usage)
                usage = getproperty(processor_result, :usage)
                if usage !== nothing
                    assistant_metadata["usage"] = usage
                end
            end
            if hasproperty(processor_result, :metadata)
                extra = getproperty(processor_result, :metadata)
                if extra isa Dict
                    merge!(assistant_metadata, extra)
                end
            end
            if hasproperty(processor_result, :format)
                value = getproperty(processor_result, :format)
                if value isa Symbol
                    reply_format = value
                elseif value isa AbstractString
                    reply_format = Symbol(strip(String(value)))
                end
            end
        else
            reply_text = string(processor_result)
        end

        reply = OutboundMessage(
            channel = msg.channel,
            session_key = session_key,
            chat_id = msg.chat_id,
            text = reply_text,
            format = reply_format,
            correlation_id = msg.message_id,
            metadata = assistant_metadata,
        )

        assistant_turn = TurnRecord(
            :assistant,
            reply_text,
            reply.message_id,
            msg.message_id,
            reply.timestamp,
            assistant_metadata,
        )

        append_turn!(store, session_key, user_turn)
        append_turn!(store, session_key, assistant_turn)
        push!(history, user_turn)
        push!(history, assistant_turn)

        usage = get(assistant_metadata, "usage", nothing)
        if usage !== nothing
            @info "response sent" session_key=session_key chars=length(reply_text) input_tokens=get(
                usage,
                "input_tokens",
                0,
            ) output_tokens=get(usage, "output_tokens", 0)
        else
            @info "response sent" session_key=session_key chars=length(reply_text)
        end

        publish_outbound!(hub, reply)

        if after_process !== nothing
            try
                after_process(msg, history)
            catch e
                @warn "after_process hook failed" session_key=session_key message_id=msg.message_id exception=(
                    e,
                    catch_backtrace(),
                )
            end
        end
    end
end

end
