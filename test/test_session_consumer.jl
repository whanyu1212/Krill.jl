@testset "Krill.jl SessionConsumer" begin
    @testset "echo_processor returns message text" begin
        msg = InboundMessage(
            channel = :telegram, session_key = "t:1", user_id = "1", chat_id = "1", text = "hello",
        )
        result = echo_processor(msg, TurnRecord[])
        @test result == "hello"
    end

    @testset "run_session_loop! echoes with session history" begin
        hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)
        store = SessionStore(; workspace = mktempdir())

        msg = InboundMessage(
            channel = :telegram, session_key = "telegram:42", user_id = "42",
            chat_id = "42", text = "session test",
        )
        publish_inbound!(hub, msg)

        run_session_loop!(hub, Ref(false); store = store, processor = echo_processor)

        reply = try_take_outbound!(hub)
        @test reply !== nothing
        @test message_text(reply) == "session test"
        @test reply.correlation_id == msg.message_id

        history = load_history(store, "telegram:42")
        @test length(history) == 2
        @test history[1].role == :user
        @test history[1].text == "session test"
        @test history[2].role == :assistant
        @test history[2].text == "session test"
    end

    @testset "custom processor receives history" begin
        hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)
        store = SessionStore(; workspace = mktempdir())

        count_processor = (msg, history) -> "turns: $(length(history))"

        for i in 1:3
            publish_inbound!(
                hub,
                InboundMessage(
                    channel = :telegram, session_key = "telegram:1", user_id = "1",
                    chat_id = "1", text = "msg$i",
                ),
            )
        end

        run_session_loop!(hub, Ref(false); store = store, processor = count_processor)

        replies = OutboundMessage[]
        while true
            r = try_take_outbound!(hub)
            r === nothing && break
            push!(replies, r)
        end

        @test length(replies) == 3
        texts = [message_text(r) for r in replies]
        @test texts == ["turns: 0", "turns: 2", "turns: 4"]
    end

    @testset "processor can set outbound format" begin
        hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)
        store = SessionStore(; workspace = mktempdir())

        markdown_processor = (msg, history) -> (text = "**formatted**", format = :markdown)

        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:fmt", user_id = "1",
                chat_id = "1", text = "use format",
            ),
        )

        run_session_loop!(hub, Ref(false); store = store, processor = markdown_processor)

        reply = try_take_outbound!(hub)
        @test reply !== nothing
        @test message_text(reply) == "**formatted**"
        @test reply.format == :markdown
    end

    @testset "processor exception produces fallback reply" begin
        hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)
        store = SessionStore(; workspace = mktempdir())

        boom_processor = (msg, history) -> error("kaboom")

        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "t:1", user_id = "1",
                chat_id = "1", text = "trigger error",
            ),
        )

        run_session_loop!(hub, Ref(false); store = store, processor = boom_processor)

        reply = try_take_outbound!(hub)
        @test reply !== nothing
        @test message_text(reply) == "Sorry, something went wrong."
    end

    @testset "slash command /help returns command summary" begin
        hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8)
        store = SessionStore(; workspace = mktempdir())
        running = Ref(true)

        task = Threads.@spawn run_session_loop!(hub, running;
            store = store,
            processor = echo_processor,
        )

        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:help", user_id = "help", chat_id = "42", text = "/help",
            ),
        )

        got_reply = false
        reply = nothing
        deadline = time() + 2
        while true
            reply = try_take_outbound!(hub)
            if reply !== nothing
                got_reply = true
                break
            end
            sleep(0.05)
            if time() > deadline
                break
            end
        end

        @test got_reply
        running[] = false
        wait(task)

        @test reply !== nothing
        @test occursin("/help", message_text(reply))
    end

    @testset "slash command /new clears session history" begin
        hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8)
        workspace = mktempdir()
        store = SessionStore(; workspace = workspace)
        running = Ref(true)

        task = Threads.@spawn run_session_loop!(hub, running;
            store = store,
            processor = echo_processor,
        )

        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:clear", user_id = "clear", chat_id = "100", text = "first",
            ),
        )
        sleep(0.1)
        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:clear", user_id = "clear", chat_id = "100", text = "/new",
            ),
        )
        sleep(0.1)
        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:clear", user_id = "clear", chat_id = "100", text = "second",
            ),
        )
        sleep(0.3)

        running[] = false
        wait(task)

        replies = OutboundMessage[]
        while true
            msg = try_take_outbound!(hub)
            msg === nothing && break
            push!(replies, msg)
        end

        @test length(replies) >= 3
        @test message_text(replies[1]) == "first"
        @test message_text(replies[2]) == "Cleared 2 turns. Fresh session."
        @test message_text(replies[3]) == "second"

        history = load_history(store, "telegram:clear")
        @test length(history) == 2
        @test history[1].text == "second"
        @test history[2].text == "second"
    end

    @testset "slash command /stop interrupts active task" begin
        hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8)
        store = SessionStore(; workspace = mktempdir())
        running = Ref(true)

        started = Channel{Bool}(1)
        release = Channel{Nothing}(1)
        blocking_processor = (msg, history) -> begin
            if message_text(msg) == "slow"
                put!(started, true)
                take!(release)
            end
            return message_text(msg)
        end

        task = Threads.@spawn run_session_loop!(hub, running;
            store = store,
            processor = blocking_processor,
        )

        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:stop", user_id = "stop", chat_id = "300", text = "slow",
            ),
        )
        took = false
        deadline = time() + 2
        while time() < deadline && !took
            if isready(started)
                took = true
                break
            end
            sleep(0.05)
        end
        @test took
        take!(started)

        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:stop", user_id = "stop", chat_id = "300", text = "/stop",
            ),
        )
        sleep(0.1)
        publish_inbound!(
            hub,
            InboundMessage(
                channel = :telegram, session_key = "telegram:stop", user_id = "stop", chat_id = "300",
                text = "after stop",
            ),
        )
        sleep(0.3)

        running[] = false
        try
            put!(release, nothing)
        catch
            # no-op
        end
        wait(task)

        replies = String[]
        while true
            msg = try_take_outbound!(hub)
            msg === nothing && break
            push!(replies, message_text(msg))
        end

        @test any(r == "Stopped active assistant task." for r in replies)
        @test any(r == "after stop" for r in replies)
        @test !any(r == "slow" for r in replies if r != "after stop")
    end
end

@testset "Krill.jl concurrent session safety" begin
    @testset "serial within same session, history order correct" begin
        hub = MessageHubState(inbound_capacity = 32, outbound_capacity = 32)
        store = SessionStore(; workspace = mktempdir())

        for i in 1:5
            publish_inbound!(
                hub,
                InboundMessage(
                    channel = :telegram, session_key = "serial_test",
                    user_id = "1", chat_id = "1", text = "msg-$i",
                ),
            )
        end

        run_session_loop!(hub, Ref(false); store = store, processor = echo_processor)

        history = load_history(store, "serial_test")
        @test length(history) == 10

        for i in 1:5
            @test history[2i - 1].role == :user
            @test history[2i - 1].text == "msg-$i"
            @test history[2i].role == :assistant
            @test history[2i].text == "msg-$i"
        end
    end

    @testset "concurrent lock creation for same session is safe" begin
        store = SessionStore(; workspace = mktempdir())
        results = Channel{ReentrantLock}(100)

        tasks = [Threads.@spawn begin
            lk = get_session_lock!(store, "race_key")
            put!(results, lk)
        end for _ in 1:20]

        for t in tasks
            wait(t)
        end
        close(results)

        locks = collect(results)
        @test length(locks) == 20
        @test all(l -> l === locks[1], locks)
    end

    @testset "different sessions process in parallel" begin
        hub = MessageHubState(inbound_capacity = 32, outbound_capacity = 32)
        store = SessionStore(; workspace = mktempdir())

        start_times = Dict{String,Float64}()
        end_times = Dict{String,Float64}()
        time_lock = ReentrantLock()

        timing_processor = function (msg, history)
            key = msg.session_key
            t0 = time()
            lock(time_lock) do
                if !haskey(start_times, key) || t0 < start_times[key]
                    start_times[key] = t0
                end
            end
            sleep(0.1)
            t1 = time()
            lock(time_lock) do
                if !haskey(end_times, key) || t1 > end_times[key]
                    end_times[key] = t1
                end
            end
            return "ok"
        end

        for s in ["par_a", "par_b", "par_c"]
            publish_inbound!(
                hub,
                InboundMessage(
                    channel = :telegram, session_key = s,
                    user_id = "1", chat_id = "1", text = "test",
                ),
            )
        end

        run_session_loop!(hub, Ref(false); store = store, processor = timing_processor)

        all_start = minimum(values(start_times))
        all_end = maximum(values(end_times))
        elapsed = all_end - all_start

        # Parallel: ~0.1s + overhead. Sequential would be ~0.3s+.
        @test elapsed < 0.5
    end
end

@testset "Krill.jl normalize_update session key derivation" begin
    @testset "group with topic produces topic-scoped session key" begin
        update = Dict{Symbol,Any}(
            :update_id => 300,
            :message => Dict{Symbol,Any}(
                :message_id => 1,
                :text => "in topic",
                :message_thread_id => 42,
                :chat => Dict{Symbol,Any}(:id => 1000),
                :from => Dict{Symbol,Any}(:id => 999),
            ),
        )
        inbound = normalize_update(update)
        @test inbound.session_key == "telegram:1000:topic:42"
    end

    @testset "private chat without topic uses simple session key" begin
        update = Dict{Symbol,Any}(
            :update_id => 301,
            :message => Dict{Symbol,Any}(
                :message_id => 2,
                :text => "private",
                :chat => Dict{Symbol,Any}(:id => 5376),
                :from => Dict{Symbol,Any}(:id => 5376),
            ),
        )
        inbound = normalize_update(update)
        @test inbound.session_key == "telegram:5376"
    end
end
