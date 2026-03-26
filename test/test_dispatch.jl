using Krill
using Krill: ChannelManagerState, DispatchEvent, OutboundMessage, DeliveryPolicy,
    MessageHubState, publish_outbound!, dispatch_stats, dead_letters, flush_dead_letters!,
    register_sender!, start_dispatch!, stop_dispatch!
using Test
using UUIDs
using Dates
using JSON3

# ============================================================================
# Helpers
# ============================================================================

function make_hub()
    MessageHubState()
end

function make_msg(;
    channel::Symbol = :test,
    text::String = "hello",
    session_key::String = "s1",
    chat_id::String = "c1",
    delivery_policy::DeliveryPolicy = DeliveryPolicy(max_retries = 0, timeout_ms = 0),
    correlation_id::Union{Nothing,UUID} = nothing,
)
    OutboundMessage(;
        channel = channel,
        text = text,
        session_key = session_key,
        chat_id = chat_id,
        delivery_policy = delivery_policy,
        correlation_id = correlation_id,
    )
end

function make_manager(hub = make_hub(); kwargs...)
    ChannelManagerState(hub; kwargs...)
end

function wait_for_dispatch(mgr; timeout_s = 5.0)
    t0 = time()
    while time() - t0 < timeout_s
        stats = dispatch_stats(mgr)
        total = stats["delivered"] + stats["failed"] + stats["dropped"]
        total > 0 && return stats
        sleep(0.01)
    end
    return dispatch_stats(mgr)
end

# ============================================================================
# DispatchEvent struct
# ============================================================================

@testset "Phase D: Dispatch Observability" begin
    @testset "DispatchEvent struct" begin
        mid = uuid4()
        cid = uuid4()
        evt = DispatchEvent(mid, cid, :telegram, "s1", "c1", :delivered, "", 1, 42, nothing, now(UTC))
        @test evt.message_id == mid
        @test evt.correlation_id == cid
        @test evt.channel == :telegram
        @test evt.session_key == "s1"
        @test evt.chat_id == "c1"
        @test evt.outcome == :delivered
        @test evt.reason == ""
        @test evt.attempts == 1
        @test evt.elapsed_ms == 42
        @test evt.error === nothing
        @test evt.timestamp isa DateTime
    end

    @testset "DispatchEvent with error" begin
        err = ErrorException("boom")
        evt = DispatchEvent(uuid4(), nothing, :test, "s", "c", :failed, "send_failed", 3, 100, err, now(UTC))
        @test evt.correlation_id === nothing
        @test evt.outcome == :failed
        @test evt.error === err
        @test evt.attempts == 3
    end

    # ============================================================================
    # ChannelManagerState constructor kwargs
    # ============================================================================

    @testset "ChannelManagerState constructor kwargs" begin
        hub = make_hub()

        @testset "defaults" begin
            mgr = ChannelManagerState(hub)
            @test mgr.on_dispatch === nothing
            @test mgr.dead_letter_path === nothing
        end

        @testset "with on_dispatch" begin
            cb = (_) -> nothing
            mgr = ChannelManagerState(hub; on_dispatch = cb)
            @test mgr.on_dispatch === cb
        end

        @testset "with dead_letter_path" begin
            mgr = ChannelManagerState(hub; dead_letter_path = "/tmp/test_dl.jsonl")
            @test mgr.dead_letter_path == "/tmp/test_dl.jsonl"
        end

        @testset "backward compat positional" begin
            mgr = ChannelManagerState(hub)
            @test mgr.hub === hub
            @test isempty(mgr.senders)
            @test mgr.running == false
        end
    end

    # ============================================================================
    # dispatch_stats
    # ============================================================================

    @testset "dispatch_stats" begin
        mgr = make_manager()
        stats = dispatch_stats(mgr)
        @test stats["delivered"] == 0
        @test stats["failed"] == 0
        @test stats["dropped"] == 0
        @test stats["dead_letters"] == 0
        @test stats["last_successful_send_at"] === nothing
        @test stats["pending"] == 0
    end

    # ============================================================================
    # dead_letters / flush_dead_letters!
    # ============================================================================

    @testset "dead_letters and flush" begin
        mgr = make_manager()
        @test isempty(dead_letters(mgr))

        # Simulate adding a dead letter entry
        push!(mgr.dead_letters, Dict{String,Any}("reason" => "test"))
        @test length(dead_letters(mgr)) == 1
        # dead_letters returns a copy
        dl = dead_letters(mgr)
        push!(dl, Dict{String,Any}("reason" => "extra"))
        @test length(dead_letters(mgr)) == 1  # original unchanged

        flushed = flush_dead_letters!(mgr)
        @test length(flushed) == 1
        @test flushed[1]["reason"] == "test"
        @test isempty(dead_letters(mgr))
    end

    # ============================================================================
    # on_dispatch callback — delivered
    # ============================================================================

    @testset "on_dispatch callback fires on delivery" begin
        events = DispatchEvent[]
        hub = make_hub()
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        register_sender!(mgr, :test, msg -> nothing)  # always-success sender
        start_dispatch!(mgr)

        msg = make_msg()
        publish_outbound!(hub, msg)
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        evt = events[1]
        @test evt.outcome == :delivered
        @test evt.channel == :test
        @test evt.session_key == "s1"
        @test evt.chat_id == "c1"
        @test evt.attempts == 1
        @test evt.elapsed_ms >= 0
        @test evt.error === nothing
        @test evt.message_id == msg.message_id
    end

    # ============================================================================
    # on_dispatch callback — failed (no sender)
    # ============================================================================

    @testset "on_dispatch fires on no_sender" begin
        events = DispatchEvent[]
        hub = make_hub()
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        # No sender registered for :test
        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg())
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        evt = events[1]
        @test evt.outcome == :no_sender
        @test evt.reason == "sender_not_registered"
        @test evt.attempts == 0
    end

    # ============================================================================
    # on_dispatch callback — failed (sender throws)
    # ============================================================================

    @testset "on_dispatch fires on send failure" begin
        events = DispatchEvent[]
        hub = make_hub()
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        register_sender!(mgr, :test, msg -> error("boom"))
        start_dispatch!(mgr)

        publish_outbound!(hub, make_msg(delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0)))
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        evt = events[1]
        @test evt.outcome == :failed
        @test evt.reason == "send_failed"
        @test evt.error isa Exception
    end

    # ============================================================================
    # on_dispatch callback — dropped (drop_if_late)
    # ============================================================================

    @testset "on_dispatch fires on drop_if_late" begin
        events = DispatchEvent[]
        hub = make_hub()
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        register_sender!(mgr, :test, msg -> nothing)
        start_dispatch!(mgr)

        # Create a message with a very old timestamp and short timeout so it gets dropped
        old_msg = OutboundMessage(;
            channel = :test,
            text = "old message",
            session_key = "s1",
            chat_id = "c1",
            timestamp = now(UTC) - Millisecond(5000),
            delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 100, drop_if_late = true),
        )
        publish_outbound!(hub, old_msg)
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        evt = events[1]
        @test evt.outcome == :dropped
        @test contains(evt.reason, "drop_if_late")
    end

    # ============================================================================
    # Dead letter recording
    # ============================================================================

    @testset "dead letters recorded on failure" begin
        hub = make_hub()
        mgr = make_manager(hub)

        # No sender registered → dead letter
        start_dispatch!(mgr)
        msg = make_msg(correlation_id = uuid4())
        publish_outbound!(hub, msg)
        sleep(0.3)
        stop_dispatch!(mgr)

        dl = dead_letters(mgr)
        @test length(dl) >= 1
        entry = dl[1]
        @test entry["reason"] == "sender_not_registered"
        @test entry["channel"] == "test"
        @test entry["session_key"] == "s1"
        @test entry["chat_id"] == "c1"
        @test entry["message_id"] == string(msg.message_id)
        @test entry["correlation_id"] == string(msg.correlation_id)
        @test haskey(entry, "timestamp")
    end

    @testset "dead letter on send_failed includes error" begin
        hub = make_hub()
        mgr = make_manager(hub)

        register_sender!(mgr, :test, msg -> error("kaboom"))
        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0)))
        sleep(0.3)
        stop_dispatch!(mgr)

        dl = dead_letters(mgr)
        @test length(dl) >= 1
        @test dl[1]["reason"] == "send_failed"
        @test haskey(dl[1], "error")
        @test contains(dl[1]["error"], "kaboom")
    end

    # ============================================================================
    # Dead letter JSONL persistence
    # ============================================================================

    @testset "dead letter JSONL persistence" begin
        dl_path = joinpath(mktempdir(), "dead_letters.jsonl")
        hub = make_hub()
        mgr = make_manager(hub; dead_letter_path = dl_path)

        # No sender registered → generates dead letter → should write to file
        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg())
        sleep(0.3)
        stop_dispatch!(mgr)

        @test isfile(dl_path)
        lines = readlines(dl_path)
        @test length(lines) >= 1

        parsed = JSON3.read(lines[1], Dict{String,Any})
        @test parsed["reason"] == "sender_not_registered"
        @test parsed["channel"] == "test"
        @test haskey(parsed, "timestamp")
    end

    @testset "dead letter JSONL appends" begin
        dl_path = joinpath(mktempdir(), "sub", "dead_letters.jsonl")
        hub = make_hub()
        mgr = make_manager(hub; dead_letter_path = dl_path)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(text = "first"))
        publish_outbound!(hub, make_msg(text = "second"))
        sleep(0.5)
        stop_dispatch!(mgr)

        @test isfile(dl_path)
        lines = readlines(dl_path)
        @test length(lines) >= 2
    end

    # ============================================================================
    # dispatch_stats counters
    # ============================================================================

    @testset "dispatch_stats counts delivered" begin
        hub = make_hub()
        mgr = make_manager(hub)
        register_sender!(mgr, :test, msg -> nothing)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg())
        publish_outbound!(hub, make_msg())
        sleep(0.3)
        stop_dispatch!(mgr)

        stats = dispatch_stats(mgr)
        @test stats["delivered"] == 2
        @test stats["failed"] == 0
        @test stats["dropped"] == 0
        @test stats["last_successful_send_at"] !== nothing
        @test stats["last_successful_send_at"] isa DateTime
    end

    @testset "dispatch_stats counts failed" begin
        hub = make_hub()
        mgr = make_manager(hub)
        register_sender!(mgr, :test, msg -> error("nope"))

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0)))
        sleep(0.3)
        stop_dispatch!(mgr)

        stats = dispatch_stats(mgr)
        @test stats["failed"] >= 1
        @test stats["dead_letters"] >= 1
    end

    @testset "dispatch_stats counts no_sender as failed" begin
        hub = make_hub()
        mgr = make_manager(hub)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg())
        sleep(0.3)
        stop_dispatch!(mgr)

        stats = dispatch_stats(mgr)
        @test stats["failed"] >= 1
    end

    # ============================================================================
    # Retry behavior with retriable errors
    # ============================================================================

    @testset "retry on retriable error then succeed" begin
        attempt_count = Ref(0)
        hub = make_hub()
        events = DispatchEvent[]
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        register_sender!(mgr, :test, msg -> begin
            attempt_count[] += 1
            if attempt_count[] == 1
                throw(Base.IOError("connection reset", 0))
            end
            # succeed on second attempt
        end)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(delivery_policy = DeliveryPolicy(max_retries = 2, timeout_ms = 0)))
        sleep(2.0)  # allow time for retry backoff
        stop_dispatch!(mgr)

        @test attempt_count[] >= 2
        stats = dispatch_stats(mgr)
        @test stats["delivered"] == 1
        @test stats["failed"] == 0

        @test length(events) >= 1
        @test events[end].outcome == :delivered
        @test events[end].attempts >= 2
    end

    @testset "non-retriable error fails immediately" begin
        attempt_count = Ref(0)
        hub = make_hub()
        mgr = make_manager(hub)

        register_sender!(mgr, :test, msg -> begin
            attempt_count[] += 1
            error("non-retriable error")
        end)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(delivery_policy = DeliveryPolicy(max_retries = 3, timeout_ms = 0)))
        sleep(0.5)
        stop_dispatch!(mgr)

        # Should only attempt once since ErrorException is not retriable
        @test attempt_count[] == 1
        stats = dispatch_stats(mgr)
        @test stats["failed"] == 1
    end

    # ============================================================================
    # Priority ordering
    # ============================================================================

    @testset "priority ordering in pending queue" begin
        hub = make_hub()
        delivered = String[]
        mgr = make_manager(hub)
        register_sender!(mgr, :test, msg -> begin
            text = Krill.message_text(msg)
            push!(delivered, text)
        end)

        # Publish multiple messages with different priorities before starting dispatch
        low = make_msg(text = "low", delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0, priority = 0))
        high = make_msg(text = "high", delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0, priority = 10))
        mid = make_msg(text = "mid", delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0, priority = 5))

        publish_outbound!(hub, low)
        publish_outbound!(hub, high)
        publish_outbound!(hub, mid)

        start_dispatch!(mgr)
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(delivered) == 3
        @test delivered[1] == "high"
        @test delivered[2] == "mid"
        @test delivered[3] == "low"
    end

    # ============================================================================
    # Correlation ID tracking
    # ============================================================================

    @testset "correlation_id preserved in events and dead letters" begin
        cid = uuid4()
        hub = make_hub()
        events = DispatchEvent[]
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        # No sender → will produce dead letter with correlation_id
        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(correlation_id = cid))
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        @test events[1].correlation_id == cid

        dl = dead_letters(mgr)
        @test length(dl) >= 1
        @test dl[1]["correlation_id"] == string(cid)
    end

    @testset "nil correlation_id handled" begin
        hub = make_hub()
        events = DispatchEvent[]
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(correlation_id = nothing))
        sleep(0.3)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        @test events[1].correlation_id === nothing

        dl = dead_letters(mgr)
        @test dl[1]["correlation_id"] === nothing
    end

    # ============================================================================
    # on_dispatch callback error handling
    # ============================================================================

    @testset "on_dispatch callback errors don't crash dispatch" begin
        call_count = Ref(0)
        hub = make_hub()
        mgr = make_manager(hub; on_dispatch = evt -> begin
            call_count[] += 1
            error("callback crash")
        end)

        register_sender!(mgr, :test, msg -> nothing)
        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg())
        publish_outbound!(hub, make_msg())
        sleep(0.5)
        stop_dispatch!(mgr)

        # Callback was called for both messages despite crashing
        @test call_count[] >= 2
        stats = dispatch_stats(mgr)
        @test stats["delivered"] == 2
    end

    # ============================================================================
    # Multiple messages, mixed outcomes
    # ============================================================================

    @testset "mixed outcomes" begin
        hub = make_hub()
        events = DispatchEvent[]
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        attempt = Ref(0)
        register_sender!(mgr, :test, msg -> begin
            attempt[] += 1
            if attempt[] == 2
                error("fail this one")
            end
        end)

        start_dispatch!(mgr)
        publish_outbound!(
            hub,
            make_msg(text = "ok1", delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0)),
        )
        publish_outbound!(
            hub,
            make_msg(text = "fail", delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0)),
        )
        publish_outbound!(
            hub,
            make_msg(text = "ok2", delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 0)),
        )
        sleep(0.5)
        stop_dispatch!(mgr)

        stats = dispatch_stats(mgr)
        @test stats["delivered"] == 2
        @test stats["failed"] == 1
        @test stats["dead_letters"] == 1

        outcomes = [e.outcome for e in events]
        @test count(==(Symbol(:delivered)), outcomes) == 2
        @test count(==(Symbol(:failed)), outcomes) == 1
    end

    # ============================================================================
    # Send timeout
    # ============================================================================

    @testset "send timeout generates failure" begin
        hub = make_hub()
        events = DispatchEvent[]
        mgr = make_manager(hub; on_dispatch = evt -> push!(events, evt))

        register_sender!(mgr, :test, msg -> begin
            sleep(5.0)  # hang
        end)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg(delivery_policy = DeliveryPolicy(max_retries = 0, timeout_ms = 200)))
        sleep(1.0)
        stop_dispatch!(mgr)

        @test length(events) >= 1
        evt = events[1]
        @test evt.outcome == :failed
        @test evt.error isa Exception
    end

    # ============================================================================
    # flush_dead_letters! resets counters
    # ============================================================================

    @testset "flush_dead_letters! clears and returns" begin
        hub = make_hub()
        mgr = make_manager(hub)

        start_dispatch!(mgr)
        publish_outbound!(hub, make_msg())
        publish_outbound!(hub, make_msg())
        sleep(0.3)
        stop_dispatch!(mgr)

        dl_before = dead_letters(mgr)
        @test length(dl_before) >= 2

        flushed = flush_dead_letters!(mgr)
        @test length(flushed) >= 2
        @test isempty(dead_letters(mgr))

        stats = dispatch_stats(mgr)
        @test stats["dead_letters"] == 0
        # Counters (failed) are NOT reset by flush
        @test stats["failed"] >= 2
    end
end  # top-level testset
