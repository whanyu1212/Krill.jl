using Krill
using Krill: SubagentTask, SubagentManager, spawn_subagent!, cancel_subagents!,
    list_subagents, subagent_count, register_spawn_tools!, set_spawn_context!,
    ToolRegistry, ToolDef, register_tool!, dispatch_tool, tool_names,
    InboundMessage, TurnRecord, MessageHubState, try_publish_inbound!
using Test
using Dates

# ============================================================================
# Helpers
# ============================================================================

"""Create a SubagentManager with a simple echo processor factory."""
function make_test_manager(;
    published::Union{Nothing,Vector} = nothing,
    processor_factory = nothing,
    max_concurrent::Int = 5,
    max_iterations::Int = 3,
)
    msgs = published === nothing ? InboundMessage[] : published
    publish_fn = msg -> begin
        push!(msgs, msg)
        return true
    end
    if processor_factory === nothing
        # Default: echo processor that returns the task text uppercased
        processor_factory =
            () -> begin
                (msg::InboundMessage, history::Vector{TurnRecord}) -> begin
                    return (text = "DONE: $(uppercase(Krill.message_text(msg)))", usage = nothing)
                end
            end
    end
    return SubagentManager(;
        publish_fn = publish_fn,
        processor_factory = processor_factory,
        max_concurrent = max_concurrent,
        max_iterations = max_iterations,
    ),
    msgs
end

"""Wait for a SubagentTask to finish (up to timeout_s seconds)."""
function wait_for_task(mgr::SubagentManager, task_id::String; timeout_s::Float64 = 10.0)
    deadline = time() + timeout_s
    while time() < deadline
        st = get(mgr.tasks, task_id, nothing)
        st === nothing && return nothing
        st.status !== :running && return st
        sleep(0.05)
    end
    return get(mgr.tasks, task_id, nothing)
end

# ============================================================================
# SubagentManager construction
# ============================================================================

@testset "SubagentManager construction" begin
    @testset "default construction" begin
        mgr, _ = make_test_manager()
        @test mgr isa SubagentManager
        @test isempty(mgr.tasks)
        @test isempty(mgr.session_tasks)
        @test mgr.max_concurrent == 5
        @test mgr.max_iterations == 3
    end

    @testset "custom limits" begin
        mgr, _ = make_test_manager(max_concurrent = 2, max_iterations = 10)
        @test mgr.max_concurrent == 2
        @test mgr.max_iterations == 10
    end

    @testset "subagent_count empty" begin
        mgr, _ = make_test_manager()
        @test subagent_count(mgr) == 0
        @test subagent_count(mgr; running_only = true) == 0
    end

    @testset "list_subagents empty" begin
        mgr, _ = make_test_manager()
        @test isempty(list_subagents(mgr))
        @test isempty(list_subagents(mgr; session_key = "test"))
    end
end

# ============================================================================
# Spawn and execution
# ============================================================================

@testset "Spawn and execution" begin
    @testset "spawn returns status message" begin
        mgr, _ = make_test_manager()
        result = spawn_subagent!(mgr, "do something";
            origin_channel = :test,
            origin_session_key = "sess1",
            origin_chat_id = "chat1",
        )
        @test result isa String
        @test contains(result, "started")
        @test contains(result, "id:")
        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)
    end

    @testset "spawn creates task record" begin
        mgr, _ = make_test_manager()
        spawn_subagent!(mgr, "task one";
            label = "Test Task",
            origin_channel = :test,
            origin_session_key = "sess1",
            origin_chat_id = "chat1",
        )
        @test subagent_count(mgr) == 1
        tasks = list_subagents(mgr)
        @test length(tasks) == 1
        st = tasks[1]
        @test st.label == "Test Task"
        @test st.task_description == "task one"
        @test st.origin_channel === :test
        @test st.origin_session_key == "sess1"
        @test st.origin_chat_id == "chat1"
        wait_for_task(mgr, st.id)
    end

    @testset "spawn completes and announces result" begin
        published = InboundMessage[]
        mgr, _ = make_test_manager(published = published)
        spawn_subagent!(mgr, "analyze data";
            origin_channel = :test,
            origin_session_key = "sess1",
            origin_chat_id = "chat1",
        )

        task_id = first(keys(mgr.tasks))
        st = wait_for_task(mgr, task_id)
        @test st !== nothing
        @test st.status === :completed
        @test st.result !== nothing
        @test contains(st.result, "DONE: ANALYZE DATA")
        @test st.finished_at !== nothing

        # Wait for announcement
        sleep(0.3)
        @test !isempty(published)
        announced = published[end]
        @test announced.channel === :test
        @test announced.session_key == "sess1"
        @test announced.chat_id == "chat1"
        @test announced.user_id == "subagent"
        @test announced.metadata["from_subagent"] == true
        @test announced.metadata["subagent_status"] == "completed"
        announced_text = Krill.message_text(announced)
        @test contains(announced_text, "completed successfully")
        @test contains(announced_text, "DONE: ANALYZE DATA")
    end

    @testset "spawn with label truncation" begin
        mgr, _ = make_test_manager()
        spawn_subagent!(mgr, "a" ^ 100;
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        st = first(values(mgr.tasks))
        @test length(st.label) <= 43  # 40 + "..."
        wait_for_task(mgr, st.id)
    end

    @testset "spawn tracks session tasks" begin
        mgr, _ = make_test_manager()
        spawn_subagent!(mgr, "task A"; origin_session_key = "sess1", origin_chat_id = "c1")
        spawn_subagent!(mgr, "task B"; origin_session_key = "sess1", origin_chat_id = "c1")
        spawn_subagent!(mgr, "task C"; origin_session_key = "sess2", origin_chat_id = "c2")

        sess1_tasks = list_subagents(mgr; session_key = "sess1")
        sess2_tasks = list_subagents(mgr; session_key = "sess2")
        @test length(sess1_tasks) == 2
        @test length(sess2_tasks) == 1

        for (tid, _) in mgr.tasks
            wait_for_task(mgr, tid)
        end
    end

    @testset "spawn with failed processor" begin
        published = InboundMessage[]
        mgr, _ = make_test_manager(
            published = published,
            processor_factory = () -> (msg, history) -> error("processor exploded"),
        )
        spawn_subagent!(mgr, "will fail";
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        task_id = first(keys(mgr.tasks))
        st = wait_for_task(mgr, task_id)
        @test st.status === :failed
        @test contains(st.result, "processor exploded")
    end

    @testset "spawn with no processor factory" begin
        published = InboundMessage[]
        mgr = SubagentManager(
            publish_fn = msg -> (push!(published, msg); true),
            processor_factory = nothing,
            max_concurrent = 5,
            max_iterations = 3,
        )
        spawn_subagent!(mgr, "no processor";
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        task_id = first(keys(mgr.tasks))
        st = wait_for_task(mgr, task_id)
        @test st.status === :failed
        @test contains(st.result, "No LLM provider configured")
    end

    @testset "spawn with processor factory that throws" begin
        mgr, _ = make_test_manager(
            processor_factory = () -> error("factory broken"),
        )
        spawn_subagent!(mgr, "factory fail";
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        task_id = first(keys(mgr.tasks))
        st = wait_for_task(mgr, task_id)
        @test st.status === :failed
        @test contains(st.result, "factory broken")
    end

    @testset "spawn with NamedTuple result" begin
        mgr, _ = make_test_manager(
            processor_factory = () -> (msg, hist) -> (text = "result text", usage = nothing),
        )
        spawn_subagent!(mgr, "named tuple";
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        task_id = first(keys(mgr.tasks))
        st = wait_for_task(mgr, task_id)
        @test st.status === :completed
        @test st.result == "result text"
    end

    @testset "spawn with string result" begin
        mgr, _ = make_test_manager(
            processor_factory = () -> (msg, hist) -> "plain string result",
        )
        spawn_subagent!(mgr, "string result";
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        task_id = first(keys(mgr.tasks))
        st = wait_for_task(mgr, task_id)
        @test st.status === :completed
        @test st.result == "plain string result"
    end
end

# ============================================================================
# Concurrent limit (no cancel — avoids Base.throwto deadlock)
# ============================================================================

@testset "Concurrent limit" begin
    @testset "respects max_concurrent with fast tasks" begin
        # Use an atomic counter to track peak concurrency
        active = Threads.Atomic{Int}(0)
        peak = Threads.Atomic{Int}(0)

        mgr, _ = make_test_manager(
            max_concurrent = 2,
            processor_factory = () -> (msg, hist) -> begin
                Threads.atomic_add!(active, 1)
                current = active[]
                # Update peak if current is higher
                while true
                    old_peak = peak[]
                    current <= old_peak && break
                    Threads.atomic_cas!(peak, old_peak, current)
                end
                sleep(2.0)  # Long enough to still be running when 3rd spawn is attempted
                Threads.atomic_sub!(active, 1)
                return (text = "done", usage = nothing)
            end,
        )

        spawn_subagent!(mgr, "task 1"; origin_session_key = "s", origin_chat_id = "c")
        spawn_subagent!(mgr, "task 2"; origin_session_key = "s", origin_chat_id = "c")
        sleep(0.2)

        # Third should be rejected while 2 are running
        result = spawn_subagent!(mgr, "task 3"; origin_session_key = "s", origin_chat_id = "c")
        @test contains(result, "maximum concurrent limit")

        # Wait for existing tasks to finish
        for (tid, _) in mgr.tasks
            wait_for_task(mgr, tid)
        end
    end
end

# ============================================================================
# Cancel (unit-level, without actual thread interruption)
# ============================================================================

@testset "Cancel subagents" begin
    @testset "cancel returns 0 for no running tasks" begin
        mgr, _ = make_test_manager()
        @test cancel_subagents!(mgr, "nonexistent") == 0
    end

    @testset "cancel returns 0 for completed tasks" begin
        mgr, _ = make_test_manager()
        spawn_subagent!(mgr, "quick task"; origin_session_key = "sess1", origin_chat_id = "c")
        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)

        # Task is already done, cancel should find nothing to cancel
        cancelled = cancel_subagents!(mgr, "sess1")
        @test cancelled == 0
    end
end

# ============================================================================
# Tool registration
# ============================================================================

@testset "Spawn tool registration" begin
    @testset "registers spawn tools" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        defs = register_spawn_tools!(registry, mgr)
        @test length(defs) == 3
        names = [d.name for d in defs]
        @test "spawn" in names
        @test "spawn_list" in names
        @test "spawn_cancel" in names
        @test all(n -> n in tool_names(registry), names)
    end

    @testset "from_subagent skips registration" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        defs = register_spawn_tools!(registry, mgr; from_subagent = true)
        @test isempty(defs)
        @test !("spawn" in tool_names(registry))
    end

    @testset "spawn tool dispatches" begin
        registry = ToolRegistry()
        published = InboundMessage[]
        mgr, _ = make_test_manager(published = published)
        register_spawn_tools!(registry, mgr)
        set_spawn_context!(:test, "sess1", "chat1")

        result = dispatch_tool(registry, "spawn", Dict{String,Any}("task" => "test task", "label" => "My Label"))
        @test result isa String
        @test contains(result, "My Label")
        @test contains(result, "started")

        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)
        sleep(0.2)
    end

    @testset "spawn tool requires task" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        register_spawn_tools!(registry, mgr)

        result = dispatch_tool(registry, "spawn", Dict{String,Any}("task" => ""))
        @test contains(result, "Error")
    end

    @testset "spawn_list tool empty" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        register_spawn_tools!(registry, mgr)

        result = dispatch_tool(registry, "spawn_list", Dict{String,Any}())
        @test contains(result, "No subagent tasks")
    end

    @testset "spawn_list tool with tasks" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        register_spawn_tools!(registry, mgr)
        set_spawn_context!(:test, "s", "c")

        dispatch_tool(registry, "spawn", Dict{String,Any}("task" => "hello"))
        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)
        sleep(0.2)

        result = dispatch_tool(registry, "spawn_list", Dict{String,Any}())
        @test !contains(result, "No subagent tasks")
        @test contains(result, "[")
    end

    @testset "spawn_cancel nonexistent" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        register_spawn_tools!(registry, mgr)

        result = dispatch_tool(registry, "spawn_cancel", Dict{String,Any}("task_id" => "nope"))
        @test contains(result, "No subagent")
    end

    @testset "spawn_cancel requires task_id" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        register_spawn_tools!(registry, mgr)

        result = dispatch_tool(registry, "spawn_cancel", Dict{String,Any}("task_id" => ""))
        @test contains(result, "Error")
    end

    @testset "spawn_cancel already completed" begin
        registry = ToolRegistry()
        mgr, _ = make_test_manager()
        register_spawn_tools!(registry, mgr)
        set_spawn_context!(:test, "s", "c")

        dispatch_tool(registry, "spawn", Dict{String,Any}("task" => "quick"))
        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)

        result = dispatch_tool(registry, "spawn_cancel", Dict{String,Any}("task_id" => task_id))
        @test contains(result, "already")
    end
end

# ============================================================================
# set_spawn_context!
# ============================================================================

@testset "set_spawn_context!" begin
    @testset "sets and uses context" begin
        set_spawn_context!(:telegram, "session_abc", "chat_123")
        mgr, _ = make_test_manager()
        registry = ToolRegistry()
        register_spawn_tools!(registry, mgr)

        dispatch_tool(registry, "spawn", Dict{String,Any}("task" => "context test"))
        task_id = first(keys(mgr.tasks))
        st = mgr.tasks[task_id]
        @test st.origin_channel === :telegram
        @test st.origin_session_key == "session_abc"
        @test st.origin_chat_id == "chat_123"

        wait_for_task(mgr, task_id)
    end
end

# ============================================================================
# Result announcement
# ============================================================================

@testset "Result announcement" begin
    @testset "completed task announces to origin session" begin
        published = InboundMessage[]
        mgr, _ = make_test_manager(published = published)
        spawn_subagent!(mgr, "compute pi";
            origin_channel = :telegram,
            origin_session_key = "sess_pi",
            origin_chat_id = "chat_pi",
        )
        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)
        sleep(0.3)

        @test length(published) >= 1
        msg = published[end]
        @test msg.channel === :telegram
        @test msg.session_key == "sess_pi"
        @test msg.chat_id == "chat_pi"
        @test msg.user_id == "subagent"
        @test msg.metadata["from_subagent"] == true
        @test msg.metadata["subagent_status"] == "completed"
        msg_text = Krill.message_text(msg)
        @test contains(msg_text, "completed successfully")
        @test contains(msg_text, "DONE: COMPUTE PI")
    end

    @testset "failed task announces failure" begin
        published = InboundMessage[]
        mgr, _ = make_test_manager(
            published = published,
            processor_factory = () -> (msg, hist) -> error("boom"),
        )
        spawn_subagent!(mgr, "will fail";
            origin_channel = :test,
            origin_session_key = "s",
            origin_chat_id = "c",
        )
        task_id = first(keys(mgr.tasks))
        wait_for_task(mgr, task_id)
        sleep(0.3)

        @test length(published) >= 1
        msg = published[end]
        @test msg.metadata["subagent_status"] == "failed"
        @test contains(Krill.message_text(msg), "failed")
    end
end

# ============================================================================
# Runtime integration (no LLM needed)
# ============================================================================

@testset "Runtime integration" begin
    @testset "RuntimeState with subagents disabled" begin
        tg = TelegramClient("tok"; base_url = "http://localhost:1")
        rt = RuntimeState(tg; llm_enable_subagents = false)
        @test rt.subagent_manager === nothing
        s = status(rt)
        @test s["subagents_enabled"] == false
        @test s["subagents_total"] == 0
        @test s["subagents_running"] == 0
    end

    @testset "RuntimeState without LLM has no subagent_manager" begin
        tg = TelegramClient("tok"; base_url = "http://localhost:1")
        rt = RuntimeState(tg)
        @test rt.subagent_manager === nothing
        s = status(rt)
        @test s["subagents_enabled"] == false
    end
end

# ============================================================================
# Concurrent stress test
# ============================================================================

@testset "Concurrent subagent stress" begin
    @testset "many rapid spawns complete without corruption" begin
        published = InboundMessage[]
        completed = Threads.Atomic{Int}(0)

        mgr, _ = make_test_manager(
            published = published,
            max_concurrent = 10,
            processor_factory = () ->
                (msg, hist) -> begin
                    Threads.atomic_add!(completed, 1)
                    return (text = "done: $(Krill.message_text(msg))", usage = nothing)
                end,
        )

        # Spawn 10 subagents as fast as possible
        task_ids = String[]
        for i in 1:10
            result = spawn_subagent!(mgr, "stress task $i";
                origin_channel = :test,
                origin_session_key = "stress_sess",
                origin_chat_id = "stress_chat",
            )
            @test contains(result, "started")
            push!(task_ids, first(keys(filter(kv -> !(kv.first in task_ids[1:end]), mgr.tasks))))
        end

        # Wait for all to complete
        for tid in task_ids
            wait_for_task(mgr, tid; timeout_s = 15.0)
        end

        @test completed[] == 10
        @test subagent_count(mgr) == 10
        all_tasks = list_subagents(mgr)
        @test all(t -> t.status === :completed, all_tasks)
        @test all(t -> startswith(t.result, "done:"), all_tasks)
    end

    @testset "concurrent limit enforced under rapid spawning" begin
        barrier = Threads.Event()
        mgr, _ = make_test_manager(
            max_concurrent = 3,
            processor_factory = () -> (msg, hist) -> begin
                wait(barrier)  # block until released
                return (text = "ok", usage = nothing)
            end,
        )

        # Fill up the limit
        for i in 1:3
            spawn_subagent!(mgr, "blocking $i"; origin_session_key = "s", origin_chat_id = "c")
        end
        sleep(0.1)  # let them start

        # 4th should be rejected
        result = spawn_subagent!(mgr, "rejected"; origin_session_key = "s", origin_chat_id = "c")
        @test contains(result, "maximum concurrent limit")

        # Release blocked tasks
        notify(barrier)
        for (tid, _) in mgr.tasks
            wait_for_task(mgr, tid; timeout_s = 10.0)
        end

        @test subagent_count(mgr) == 3
    end
end
