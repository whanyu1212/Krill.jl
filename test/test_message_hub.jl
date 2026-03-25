@testset "Krill.jl MessageHub" begin
    @testset "inbound/outbound FIFO and take APIs" begin
        hub = MessageHubState(inbound_capacity=4, outbound_capacity=4)

        in1 = InboundMessage(
            channel=:telegram,
            session_key="telegram:1",
            user_id="u1",
            chat_id="1",
            text="first inbound",
        )
        in2 = InboundMessage(
            channel=:telegram,
            session_key="telegram:1",
            user_id="u1",
            chat_id="1",
            text="second inbound",
        )

        out1 = OutboundMessage(
            channel=:telegram,
            session_key="telegram:1",
            chat_id="1",
            text="first outbound",
        )
        out2 = OutboundMessage(
            channel=:telegram,
            session_key="telegram:1",
            chat_id="1",
            text="second outbound",
        )

        publish_inbound!(hub, in1)
        publish_inbound!(hub, in2)
        publish_outbound!(hub, out1)
        publish_outbound!(hub, out2)

        got_in1 = take_inbound!(hub)
        got_in2 = take_inbound!(hub)
        got_out1 = take_outbound!(hub)
        got_out2 = take_outbound!(hub)

        @test got_in1.message_id == in1.message_id
        @test got_in2.message_id == in2.message_id
        @test got_out1.message_id == out1.message_id
        @test got_out2.message_id == out2.message_id
    end

    @testset "try_take returns nothing when empty" begin
        hub = MessageHubState()
        @test try_take_inbound!(hub) === nothing
        @test try_take_outbound!(hub) === nothing
    end

    @testset "capacity validation" begin
        @test_throws ArgumentError MessageHubState(inbound_capacity=0)
        @test_throws ArgumentError MessageHubState(outbound_capacity=0)
    end
end

@testset "Krill.jl ChannelManager" begin
    @testset "register sender and dispatch outbound" begin
        hub = MessageHubState(outbound_capacity=4)
        manager = ChannelManagerState(hub)

        delivered = OutboundMessage[]
        register_sender!(manager, :telegram, msg -> push!(delivered, msg))

        msg = OutboundMessage(
            channel=:telegram,
            session_key="telegram:2",
            chat_id="2",
            text="dispatch me",
        )

        start_dispatch!(manager)
        publish_outbound!(hub, msg)

        # Give the async task time to consume
        sleep(0.05)
        stop_dispatch!(manager)

        @test length(delivered) == 1
        @test delivered[1].message_id == msg.message_id
    end

    @testset "unknown channel logs warning but does not crash" begin
        hub = MessageHubState(outbound_capacity=2)
        manager = ChannelManagerState(hub)

        msg = OutboundMessage(
            channel=:unknown,
            session_key="unknown:1",
            chat_id="1",
            text="no sender",
        )

        start_dispatch!(manager)
        publish_outbound!(hub, msg)

        sleep(0.05)
        stop_dispatch!(manager)

        @test manager.running == false
        @test manager.dispatch_task === nothing
    end

    @testset "sender exception does not crash dispatch" begin
        hub = MessageHubState(outbound_capacity=4)
        manager = ChannelManagerState(hub)

        delivered = OutboundMessage[]
        register_sender!(manager, :telegram, function(msg)
            if message_text(msg) == "boom"
                error("sender kaboom")
            end
            push!(delivered, msg)
        end)

        start_dispatch!(manager)

        publish_outbound!(hub, OutboundMessage(
            channel=:telegram, session_key="t:1", chat_id="1", text="boom",
        ))
        publish_outbound!(hub, OutboundMessage(
            channel=:telegram, session_key="t:1", chat_id="1", text="ok",
        ))

        sleep(0.1)
        stop_dispatch!(manager)

        @test length(delivered) == 1
        @test message_text(delivered[1]) == "ok"
    end

    @testset "delivery policy retries retriable sender failures" begin
        hub = MessageHubState(outbound_capacity=4)
        manager = ChannelManagerState(hub)

        attempts = Ref(0)
        delivered = OutboundMessage[]
        register_sender!(manager, :telegram, function(msg)
            attempts[] += 1
            if attempts[] == 1
                throw(TelegramAPIError("sendMessage", "rate limited", 429))
            end
            push!(delivered, msg)
        end)

        msg = OutboundMessage(
            channel=:telegram,
            session_key="telegram:2",
            chat_id="2",
            text="retry me",
            delivery_policy=DeliveryPolicy(max_retries=1, timeout_ms=1_000),
        )

        start_dispatch!(manager)
        publish_outbound!(hub, msg)
        sleep(0.65)
        stop_dispatch!(manager)

        @test attempts[] == 2
        @test length(delivered) == 1
        @test manager.delivered_count >= 1
    end

    @testset "delivery policy timeout marks failure and records dead letter" begin
        hub = MessageHubState(outbound_capacity=4)
        manager = ChannelManagerState(hub)

        register_sender!(manager, :telegram, msg -> sleep(0.05))

        msg = OutboundMessage(
            channel=:telegram,
            session_key="telegram:2",
            chat_id="2",
            text="timeout me",
            delivery_policy=DeliveryPolicy(max_retries=0, timeout_ms=10),
        )

        start_dispatch!(manager)
        publish_outbound!(hub, msg)
        sleep(0.1)
        stop_dispatch!(manager)

        @test manager.failed_count >= 1
        @test !isempty(manager.dead_letters)
        @test manager.dead_letters[end]["reason"] == "send_failed"
    end

    @testset "drop_if_late skips stale outbound message" begin
        hub = MessageHubState(outbound_capacity=4)
        manager = ChannelManagerState(hub)

        calls = Ref(0)
        register_sender!(manager, :telegram, msg -> (calls[] += 1))

        msg = OutboundMessage(
            channel=:telegram,
            session_key="telegram:2",
            chat_id="2",
            text="late",
            timestamp=now(UTC) - Millisecond(250),
            delivery_policy=DeliveryPolicy(max_retries=0, timeout_ms=25, drop_if_late=true),
        )

        start_dispatch!(manager)
        publish_outbound!(hub, msg)
        sleep(0.05)
        stop_dispatch!(manager)

        @test calls[] == 0
        @test manager.dropped_count >= 1
    end

    @testset "higher priority messages dispatch first" begin
        hub = MessageHubState(outbound_capacity=8)
        manager = ChannelManagerState(hub)

        delivered_texts = String[]
        register_sender!(manager, :telegram, msg -> push!(delivered_texts, message_text(msg)))

        low = OutboundMessage(
            channel=:telegram,
            session_key="telegram:2",
            chat_id="2",
            text="low",
            delivery_policy=DeliveryPolicy(priority=0),
        )
        high = OutboundMessage(
            channel=:telegram,
            session_key="telegram:2",
            chat_id="2",
            text="high",
            delivery_policy=DeliveryPolicy(priority=10),
        )

        publish_outbound!(hub, low)
        publish_outbound!(hub, high)
        start_dispatch!(manager)
        sleep(0.08)
        stop_dispatch!(manager)

        @test delivered_texts[1] == "high"
        @test delivered_texts[2] == "low"
    end
end
