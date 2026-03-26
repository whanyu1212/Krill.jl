if !KRILL_FAST_TESTS
    @testset "Krill.jl end-to-end integration" begin
        @testset "Telegram update flows through hub to sender" begin
            # 1. Simulate a raw Telegram update
            raw_update = Dict{Symbol,Any}(
                :update_id => 200,
                :message => Dict{Symbol,Any}(
                    :message_id => 50,
                    :text => "ping",
                    :chat => Dict{Symbol,Any}(:id => 7777),
                    :from => Dict{Symbol,Any}(:id => 7777),
                ),
            )

            # 2. Normalize to InboundMessage
            inbound = normalize_update(raw_update)
            @test inbound !== nothing
            @test message_text(inbound) == "ping"

            # 3. Set up hub + manager with a capturing sender
            hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)
            manager = ChannelManagerState(hub)
            sent_texts = String[]
            register_sender!(manager, :telegram, msg -> push!(sent_texts, message_text(msg)))
            start_dispatch!(manager)

            # 4. Publish inbound, consume it, create outbound reply
            publish_inbound!(hub, inbound)
            received = take_inbound!(hub)
            @test message_text(received) == "ping"

            reply = OutboundMessage(
                channel = received.channel,
                session_key = received.session_key,
                chat_id = received.chat_id,
                text = "pong",
                correlation_id = received.message_id,
            )
            publish_outbound!(hub, reply)

            # 5. Wait for dispatch and verify
            sleep(0.05)
            stop_dispatch!(manager)

            @test length(sent_texts) == 1
            @test sent_texts[1] == "pong"
        end
    end
end

# ───────────────────────────────────────────────────────────────────
# Phase A tests
# ───────────────────────────────────────────────────────────────────

@testset "Krill.jl try_publish_inbound!/try_publish_outbound!" begin
    @testset "returns true when queue has room" begin
        hub = MessageHubState(inbound_capacity = 2, outbound_capacity = 2)

        msg = InboundMessage(
            channel = :telegram, session_key = "t:1", user_id = "1", chat_id = "1", text = "a",
        )
        @test try_publish_inbound!(hub, msg) == true
        @test try_publish_inbound!(hub, msg) == true
    end

    @testset "returns false when inbound queue is full" begin
        hub = MessageHubState(inbound_capacity = 1, outbound_capacity = 1)

        msg = InboundMessage(
            channel = :telegram, session_key = "t:1", user_id = "1", chat_id = "1", text = "a",
        )
        @test try_publish_inbound!(hub, msg) == true
        @test try_publish_inbound!(hub, msg) == false
    end

    @testset "returns false when outbound queue is full" begin
        hub = MessageHubState(inbound_capacity = 1, outbound_capacity = 1)

        msg = OutboundMessage(
            channel = :telegram, session_key = "t:1", chat_id = "1", text = "a",
        )
        @test try_publish_outbound!(hub, msg) == true
        @test try_publish_outbound!(hub, msg) == false
    end
end

@testset "Krill.jl ChannelManager non-destructive stop" begin
    @testset "hub remains usable after stop_dispatch!" begin
        hub = MessageHubState(outbound_capacity = 4)
        manager = ChannelManagerState(hub)

        delivered = OutboundMessage[]
        register_sender!(manager, :telegram, msg -> push!(delivered, msg))

        start_dispatch!(manager)
        sleep(0.02)
        stop_dispatch!(manager)

        # Hub outbound channel should still be open — we can publish to it
        msg = OutboundMessage(
            channel = :telegram, session_key = "t:1", chat_id = "1", text = "after stop",
        )
        @test try_publish_outbound!(hub, msg) == true
    end

    @testset "manager can be restarted after stop" begin
        hub = MessageHubState(outbound_capacity = 4)
        manager = ChannelManagerState(hub)

        delivered = OutboundMessage[]
        register_sender!(manager, :telegram, msg -> push!(delivered, msg))

        # First cycle
        start_dispatch!(manager)
        publish_outbound!(
            hub,
            OutboundMessage(
                channel = :telegram, session_key = "t:1", chat_id = "1", text = "round1",
            ),
        )
        sleep(0.05)
        stop_dispatch!(manager)

        # Second cycle
        start_dispatch!(manager)
        publish_outbound!(
            hub,
            OutboundMessage(
                channel = :telegram, session_key = "t:1", chat_id = "1", text = "round2",
            ),
        )
        sleep(0.05)
        stop_dispatch!(manager)

        texts = [message_text(m) for m in delivered]
        @test "round1" in texts
        @test "round2" in texts
    end

    @testset "drains remaining messages on stop" begin
        hub = MessageHubState(outbound_capacity = 4)
        manager = ChannelManagerState(hub)

        delivered = OutboundMessage[]
        register_sender!(manager, :telegram, msg -> push!(delivered, msg))

        # Publish before starting dispatch
        publish_outbound!(
            hub,
            OutboundMessage(
                channel = :telegram, session_key = "t:1", chat_id = "1", text = "pre-queued",
            ),
        )

        start_dispatch!(manager)
        sleep(0.05)
        stop_dispatch!(manager)

        @test length(delivered) == 1
        @test message_text(delivered[1]) == "pre-queued"
    end
end

@testset "Krill.jl run_polling with running flag" begin
    @testset "stops when running is set to false" begin
        call_count = Ref(0)

        mock_request = function (method, url, headers, body)
            call_count[] += 1
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "ok" => true,
                        "result" => Any[
                            Dict("update_id" => 40 + call_count[], "message" => Dict("text" => "x")),
                        ],
                    ),
                ),
            )
        end

        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)

        running = Ref(true)
        handler_calls = Ref(0)
        processed = Ref(0)

        t = Threads.@spawn begin
            processed[] = run_polling(client, function (update)
                    handler_calls[] += 1
                    if handler_calls[] >= 2
                        running[] = false
                    end
                end; timeout = 0, poll_interval = 0.0, running = running)
        end

        wait(t)
        @test handler_calls[] >= 2
        @test running[] == false
    end
end

@testset "Krill.jl BoundedDedup" begin
    @testset "seen! returns true for new, false for duplicate" begin
        d = BoundedDedup(10)
        @test seen!(d, 1) == true
        @test seen!(d, 2) == true
        @test seen!(d, 1) == false  # duplicate
        @test seen!(d, 2) == false  # duplicate
        @test seen!(d, 3) == true   # new
    end

    @testset "has_seen checks without recording" begin
        d = BoundedDedup(10)
        @test has_seen(d, 1) == false
        seen!(d, 1)
        @test has_seen(d, 1) == true
    end

    @testset "evicts oldest when capacity exceeded" begin
        d = BoundedDedup(3)
        seen!(d, 10)
        seen!(d, 20)
        seen!(d, 30)

        @test has_seen(d, 10) == true
        @test has_seen(d, 20) == true
        @test has_seen(d, 30) == true

        # This should evict 10
        seen!(d, 40)
        @test has_seen(d, 10) == false
        @test has_seen(d, 20) == true
        @test has_seen(d, 30) == true
        @test has_seen(d, 40) == true

        # 10 should be insertable again as new
        @test seen!(d, 10) == true
    end

    @testset "capacity validation" begin
        @test_throws ArgumentError BoundedDedup(0)
        @test_throws ArgumentError BoundedDedup(-1)
    end
end

@testset "Krill.jl Echo consumer" begin
    @testset "echoes inbound text with correlation_id" begin
        hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)

        inbound = InboundMessage(
            channel = :telegram, session_key = "t:42", user_id = "42", chat_id = "42", text = "echo me",
        )
        publish_inbound!(hub, inbound)

        # Run echo with running=false so it just drains
        run_echo_loop!(hub, Ref(false))

        reply = try_take_outbound!(hub)
        @test reply !== nothing
        @test message_text(reply) == "echo me"
        @test reply.correlation_id == inbound.message_id
        @test reply.channel == :telegram
        @test reply.session_key == "t:42"
        @test reply.chat_id == "42"
    end

    @testset "drains multiple messages" begin
        hub = MessageHubState(inbound_capacity = 4, outbound_capacity = 4)

        for i in 1:3
            publish_inbound!(
                hub,
                InboundMessage(
                    channel = :telegram, session_key = "t:1", user_id = "1", chat_id = "1", text = "msg$i",
                ),
            )
        end

        run_echo_loop!(hub, Ref(false))

        replies = OutboundMessage[]
        while true
            r = try_take_outbound!(hub)
            r === nothing && break
            push!(replies, r)
        end

        @test length(replies) == 3
        texts = [message_text(r) for r in replies]
        @test texts == ["msg1", "msg2", "msg3"]
    end
end
