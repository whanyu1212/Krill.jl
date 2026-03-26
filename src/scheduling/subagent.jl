module Subagent

using Dates
using UUIDs
using ..Types: InboundMessage, OutboundMessage, message_text
using ..MessageHub: MessageHubState, try_publish_inbound!
using ..Sessions: SessionStore, TurnRecord, load_history
using ..Tools: ToolDef, ToolRegistry, dispatch_tool
using ..LLM: AbstractLLMProvider, make_llm_processor

export SubagentTask,
    SubagentManager,
    spawn_subagent!,
    cancel_subagents!,
    list_subagents,
    subagent_count,
    register_spawn_tools!

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
    SubagentTask

Tracks a single spawned subagent background task.
"""
mutable struct SubagentTask
    id::String
    label::String
    task_description::String
    origin_channel::Symbol
    origin_session_key::String
    origin_chat_id::String
    julia_task::Union{Nothing,Task}
    status::Symbol  # :running, :completed, :failed, :cancelled
    result::Union{Nothing,String}
    started_at::DateTime
    finished_at::Union{Nothing,DateTime}
end

"""
    SubagentManager

Manages spawned subagent background tasks. Provides spawn, cancel, and listing
operations. Each subagent runs its own LLM conversation loop with a restricted
tool set (no spawn, no message, no cron).
"""
mutable struct SubagentManager
    tasks::Dict{String,SubagentTask}
    session_tasks::Dict{String,Set{String}}  # session_key -> {task_id, ...}
    lock::ReentrantLock
    publish_fn::Function                     # msg -> Bool (publishes to hub inbound)
    processor_factory::Union{Nothing,Function}  # () -> processor function for subagents
    max_concurrent::Int
    max_iterations::Int
end

function SubagentManager(;
    publish_fn::Function,
    processor_factory::Union{Nothing,Function} = nothing,
    max_concurrent::Int = 5,
    max_iterations::Int = 15,
)
    return SubagentManager(
        Dict{String,SubagentTask}(),
        Dict{String,Set{String}}(),
        ReentrantLock(),
        publish_fn,
        processor_factory,
        max_concurrent,
        max_iterations,
    )
end

# ---------------------------------------------------------------------------
# Spawn
# ---------------------------------------------------------------------------

"""
    spawn_subagent!(mgr, task_description; label, origin_channel, origin_session_key, origin_chat_id) -> String

Spawn a background subagent to execute the given task. Returns immediately with
a status message. The subagent runs its own LLM conversation loop and announces
results back to the origin session via the shared message hub.
"""
function spawn_subagent!(
    mgr::SubagentManager,
    task_description::AbstractString;
    label::AbstractString = "",
    origin_channel::Symbol = :system,
    origin_session_key::AbstractString = "",
    origin_chat_id::AbstractString = "",
)
    task_id = string(uuid4())[1:8]
    display_label = isempty(label) ? _truncate(task_description, 40) : String(label)

    # Check concurrent limit
    limit_msg = lock(mgr.lock) do
        running = count(t -> t.status === :running, values(mgr.tasks))
        if running >= mgr.max_concurrent
            return "Cannot spawn subagent: maximum concurrent limit ($(mgr.max_concurrent)) reached. Wait for existing tasks to complete."
        end
        return nothing
    end
    limit_msg !== nothing && return limit_msg

    st = SubagentTask(
        task_id,
        display_label,
        String(task_description),
        origin_channel,
        String(origin_session_key),
        String(origin_chat_id),
        nothing,
        :running,
        nothing,
        now(UTC),
        nothing,
    )

    lock(mgr.lock) do
        mgr.tasks[task_id] = st
        session_set = get!(Set{String}, mgr.session_tasks, st.origin_session_key)
        push!(session_set, task_id)
    end

    st.julia_task = Threads.@spawn begin
        try
            _run_subagent!(mgr, st)
        catch e
            if e isa InterruptException
                _finish_task!(mgr, st, :cancelled, "Task was cancelled.")
            else
                @error "subagent failed" task_id=task_id exception=(e, catch_backtrace())
                _finish_task!(mgr, st, :failed, "Error: $(sprint(showerror, e))")
            end
        end
        _announce_result!(mgr, st)
    end

    return "Subagent '$(display_label)' started (id: $(task_id)). I'll notify you when it completes."
end

# ---------------------------------------------------------------------------
# Subagent execution
# ---------------------------------------------------------------------------

function _run_subagent!(mgr::SubagentManager, st::SubagentTask)
    if mgr.processor_factory === nothing
        _finish_task!(mgr, st, :failed, "No LLM provider configured for subagents.")
        return
    end

    processor = try
        mgr.processor_factory()
    catch e
        _finish_task!(mgr, st, :failed, "Failed to create subagent processor: $(sprint(showerror, e))")
        return
    end

    # Build a minimal InboundMessage for the subagent task
    task_msg = InboundMessage(
        channel = :system,
        session_key = "subagent:$(st.id)",
        user_id = "parent",
        chat_id = st.origin_chat_id,
        text = st.task_description,
        metadata = Dict{String,Any}(
            "from_subagent" => true,
            "subagent_id" => st.id,
        ),
    )

    # Call the processor with empty history (fresh context)
    result = try
        processor(task_msg, TurnRecord[])
    catch e
        e isa InterruptException && rethrow()
        _finish_task!(mgr, st, :failed, "Subagent processor error: $(sprint(showerror, e))")
        return
    end

    # Extract text from result
    result_text = if result isa AbstractString
        String(result)
    elseif result isa NamedTuple && hasproperty(result, :text)
        String(getproperty(result, :text))
    else
        string(result)
    end

    _finish_task!(mgr, st, :completed, result_text)
end

function _finish_task!(mgr::SubagentManager, st::SubagentTask, status::Symbol, result::String)
    lock(mgr.lock) do
        st.status = status
        st.result = result
        st.finished_at = now(UTC)
    end
end

function _announce_result!(mgr::SubagentManager, st::SubagentTask)
    st.status === :running && return  # not finished yet

    status_text =
        st.status === :completed ? "completed successfully" :
        st.status === :failed ? "failed" :
        st.status === :cancelled ? "was cancelled" : "finished"

    content = """[Subagent '$(st.label)' $(status_text)]

Task: $(st.task_description)

Result:
$(something(st.result, "(no result)"))

Summarize this naturally for the user. Keep it brief (1-2 sentences). Do not mention technical details like "subagent" or task IDs."""

    # Inject as inbound message to the origin session
    msg = InboundMessage(
        channel = st.origin_channel,
        session_key = st.origin_session_key,
        user_id = "subagent",
        chat_id = st.origin_chat_id,
        text = content,
        metadata = Dict{String,Any}(
            "from_subagent" => true,
            "subagent_id" => st.id,
            "subagent_status" => string(st.status),
        ),
    )

    mgr.publish_fn(msg)
    @info "subagent announced result" task_id=st.id label=st.label status=st.status
end

# ---------------------------------------------------------------------------
# Cancel / List
# ---------------------------------------------------------------------------

"""
    cancel_subagents!(mgr, session_key) -> Int

Cancel all running subagents for the given session. Returns the number cancelled.
"""
function cancel_subagents!(mgr::SubagentManager, session_key::AbstractString)
    task_ids = lock(mgr.lock) do
        collect(get(mgr.session_tasks, String(session_key), Set{String}()))
    end

    cancelled = 0
    for tid in task_ids
        st = get(mgr.tasks, tid, nothing)
        st === nothing && continue
        st.status !== :running && continue
        jt = st.julia_task
        if jt !== nothing && !istaskdone(jt)
            try
                Base.throwto(jt, InterruptException())
                cancelled += 1
            catch _
            end
        end
    end
    return cancelled
end

"""
    list_subagents(mgr; session_key=nothing) -> Vector{SubagentTask}

List subagent tasks, optionally filtered by session.
"""
function list_subagents(mgr::SubagentManager; session_key::Union{Nothing,AbstractString} = nothing)
    lock(mgr.lock) do
        if session_key === nothing
            return collect(values(mgr.tasks))
        end
        task_ids = get(mgr.session_tasks, String(session_key), Set{String}())
        return [mgr.tasks[tid] for tid in task_ids if haskey(mgr.tasks, tid)]
    end
end

"""
    subagent_count(mgr; running_only=false) -> Int
"""
function subagent_count(mgr::SubagentManager; running_only::Bool = false)
    lock(mgr.lock) do
        if running_only
            return count(t -> t.status === :running, values(mgr.tasks))
        end
        return length(mgr.tasks)
    end
end

# ---------------------------------------------------------------------------
# Spawn tool registration
# ---------------------------------------------------------------------------

"""
    register_spawn_tools!(registry, mgr; from_subagent=false, replace=false) -> Vector{ToolDef}

Register `spawn`, `spawn_list`, `spawn_cancel` tools. If `from_subagent=true`,
tools are not registered (prevents recursive spawning).
"""
function register_spawn_tools!(
    registry::ToolRegistry,
    mgr::SubagentManager;
    from_subagent::Bool = false,
    replace::Bool = false,
)
    from_subagent && return ToolDef[]

    defs = ToolDef[]

    push!(
        defs,
        ToolDef(
            name = "spawn",
            description = "Spawn a background subagent to work on a task independently. " *
                          "The subagent has its own LLM conversation with file/web tools but cannot spawn further subagents. " *
                          "Results are reported back when complete. Use for long-running research, file operations, or parallel tasks.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "task" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Detailed description of the task for the subagent to complete",
                    ),
                    "label" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Short label for display (optional, defaults to truncated task)",
                    ),
                ),
                "required" => Any["task"],
            ),
            execute = args -> _spawn_impl(mgr, args),
        ),
    )

    push!(
        defs,
        ToolDef(
            name = "spawn_list",
            description = "List all spawned subagent tasks and their status.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(),
            ),
            execute = args -> _spawn_list_impl(mgr, args),
        ),
    )

    push!(
        defs,
        ToolDef(
            name = "spawn_cancel",
            description = "Cancel a running subagent task by ID.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "task_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "The ID of the subagent task to cancel",
                    ),
                ),
                "required" => Any["task_id"],
            ),
            execute = args -> _spawn_cancel_impl(mgr, args),
        ),
    )

    for def in defs
        register_tool!(registry, def; replace = replace)
    end

    return defs
end

# Tool context: set by session consumer before each turn
const _TOOL_CONTEXT = Ref{@NamedTuple{channel::Symbol,session_key::String,chat_id::String}}(
    (channel = :system, session_key = "", chat_id = "")
)

function set_spawn_context!(channel::Symbol, session_key::AbstractString, chat_id::AbstractString)
    _TOOL_CONTEXT[] = (channel = channel, session_key = String(session_key), chat_id = String(chat_id))
end

function _spawn_impl(mgr::SubagentManager, args::Dict{String,Any})
    task = get(args, "task", "")
    isempty(task) && return "Error: 'task' is required."
    label = get(args, "label", "")

    ctx = _TOOL_CONTEXT[]
    return spawn_subagent!(mgr, task;
        label = label,
        origin_channel = ctx.channel,
        origin_session_key = ctx.session_key,
        origin_chat_id = ctx.chat_id,
    )
end

function _spawn_list_impl(mgr::SubagentManager, ::Dict{String,Any})
    tasks = list_subagents(mgr)
    isempty(tasks) && return "No subagent tasks."

    lines = String[]
    for st in sort(tasks; by = t -> t.started_at)
        elapsed = if st.finished_at !== nothing
            "$(round(Int, Dates.value(st.finished_at - st.started_at) / 1000))s"
        else
            "$(round(Int, Dates.value(now(UTC) - st.started_at) / 1000))s (running)"
        end
        push!(lines, "- [$(st.id)] $(st.label) — $(st.status) ($(elapsed))")
    end
    return join(lines, "\n")
end

function _spawn_cancel_impl(mgr::SubagentManager, args::Dict{String,Any})
    task_id = get(args, "task_id", "")
    isempty(task_id) && return "Error: 'task_id' is required."

    st = lock(mgr.lock) do
        get(mgr.tasks, task_id, nothing)
    end
    st === nothing && return "No subagent with id '$(task_id)' found."
    st.status !== :running && return "Subagent '$(st.label)' is already $(st.status)."

    jt = st.julia_task
    if jt !== nothing && !istaskdone(jt)
        try
            Base.throwto(jt, InterruptException())
        catch _
            return "Failed to cancel subagent '$(st.label)'."
        end
    end
    return "Subagent '$(st.label)' ($(task_id)) cancellation requested."
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function _truncate(s::AbstractString, max::Int)
    str = String(s)
    length(str) <= max && return str
    return str[1:max] * "..."
end

# Import register_tool! from Tools
using ..Tools: register_tool!

end
