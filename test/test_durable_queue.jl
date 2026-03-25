using Krill
using Krill: DurableQueueState, enqueue!, ack!, replay, compact!, queue_stats
using Test
using UUIDs
using Dates
using JSON3

# ============================================================================
# Helpers
# ============================================================================

function make_test_inbound(; text="hello", chat_id="42", channel=:telegram)
    return InboundMessage(
        channel=channel,
        session_key="$(channel):$(chat_id)",
        user_id="100",
        chat_id=chat_id,
        text=text,
    )
end

function make_test_outbound(; text="reply", chat_id="42", channel=:telegram)
    return OutboundMessage(
        channel=channel,
        session_key="$(channel):$(chat_id)",
        chat_id=chat_id,
        text=text,
    )
end

# ============================================================================
# DurableQueue tests
# ============================================================================

@testset "DurableQueue" begin

    @testset "constructor creates WAL directory" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "subdir", "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)
            @test isdir(dirname(wal_path))
            @test dq.enqueued_count == 0
            @test dq.acked_count == 0
            @test dq.wal_lines == 0
        end
    end

    @testset "enqueue! persists inbound message" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)
            msg = make_test_inbound(text="test message")
            mid = enqueue!(dq, msg)
            @test mid == msg.message_id
            @test dq.enqueued_count == 1
            @test dq.wal_lines == 1
            @test isfile(wal_path)

            # Verify WAL content
            line = readline(wal_path)
            entry = JSON3.read(line, Dict{String,Any})
            @test entry["op"] == "enqueue"
            @test entry["message_id"] == string(msg.message_id)
            @test entry["payload"]["type"] == "inbound"
            @test entry["payload"]["text"] == "test message"
        end
    end

    @testset "enqueue! persists outbound message" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)
            msg = make_test_outbound(text="response")
            enqueue!(dq, msg)
            @test dq.enqueued_count == 1

            line = readline(wal_path)
            entry = JSON3.read(line, Dict{String,Any})
            @test entry["payload"]["type"] == "outbound"
            @test entry["payload"]["text"] == "response"
        end
    end

    @testset "ack! records acknowledgement" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)
            msg = make_test_inbound()
            enqueue!(dq, msg)
            ack!(dq, msg.message_id)
            @test dq.acked_count == 1
            @test dq.wal_lines == 2

            lines = readlines(wal_path)
            @test length(lines) == 2
            ack_entry = JSON3.read(lines[2], Dict{String,Any})
            @test ack_entry["op"] == "ack"
            @test ack_entry["message_id"] == string(msg.message_id)
        end
    end

    @testset "replay returns unacked messages" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msg1 = make_test_inbound(text="first")
            msg2 = make_test_inbound(text="second")
            msg3 = make_test_outbound(text="third")

            enqueue!(dq, msg1)
            enqueue!(dq, msg2)
            enqueue!(dq, msg3)
            ack!(dq, msg1.message_id)

            result = replay(dq)
            @test length(result.inbound) == 1
            @test length(result.outbound) == 1
            @test Krill.message_text(result.inbound[1]) == "second"
            @test Krill.message_text(result.outbound[1]) == "third"
        end
    end

    @testset "replay on empty WAL returns empty" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)
            result = replay(dq)
            @test isempty(result.inbound)
            @test isempty(result.outbound)
        end
    end

    @testset "replay on nonexistent WAL returns empty" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "nonexistent.wal")
            dq = DurableQueueState(wal_path=wal_path)
            result = replay(dq)
            @test isempty(result.inbound)
            @test isempty(result.outbound)
        end
    end

    @testset "replay preserves message fields" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msg = make_test_inbound(text="preserve me", chat_id="99", channel=:telegram)
            enqueue!(dq, msg)

            result = replay(dq)
            @test length(result.inbound) == 1
            recovered = result.inbound[1]
            @test recovered.message_id == msg.message_id
            @test recovered.chat_id == "99"
            @test recovered.channel == :telegram
            @test Krill.message_text(recovered) == "preserve me"
        end
    end

    @testset "replay preserves outbound delivery policy" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            policy = DeliveryPolicy(max_retries=5, timeout_ms=10_000, priority=2, drop_if_late=true)
            msg = OutboundMessage(
                channel=:telegram,
                session_key="telegram:42",
                chat_id="42",
                text="with policy",
                delivery_policy=policy,
            )
            enqueue!(dq, msg)

            result = replay(dq)
            recovered = result.outbound[1]
            @test recovered.delivery_policy.max_retries == 5
            @test recovered.delivery_policy.timeout_ms == 10_000
            @test recovered.delivery_policy.priority == 2
            @test recovered.delivery_policy.drop_if_late == true
        end
    end

    @testset "replay deduplicates re-enqueued messages" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msg = make_test_inbound(text="dedup me")
            enqueue!(dq, msg)
            enqueue!(dq, msg)  # same message_id

            result = replay(dq)
            @test length(result.inbound) == 1
        end
    end

    @testset "replay preserves insertion order" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msgs = [make_test_inbound(text="msg$i") for i in 1:5]
            for m in msgs
                enqueue!(dq, m)
            end
            ack!(dq, msgs[2].message_id)
            ack!(dq, msgs[4].message_id)

            result = replay(dq)
            @test length(result.inbound) == 3
            texts = [Krill.message_text(m) for m in result.inbound]
            @test texts == ["msg1", "msg3", "msg5"]
        end
    end

    @testset "compact! removes acked entries" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msg1 = make_test_inbound(text="keep")
            msg2 = make_test_inbound(text="remove")
            enqueue!(dq, msg1)
            enqueue!(dq, msg2)
            ack!(dq, msg2.message_id)

            @test dq.wal_lines == 3  # 2 enqueue + 1 ack
            compact!(dq)
            @test dq.wal_lines == 1  # only unacked enqueue remains

            # Verify replay still works after compaction
            result = replay(dq)
            @test length(result.inbound) == 1
            @test Krill.message_text(result.inbound[1]) == "keep"
        end
    end

    @testset "compact! handles all-acked WAL" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msg = make_test_inbound()
            enqueue!(dq, msg)
            ack!(dq, msg.message_id)
            compact!(dq)

            @test dq.wal_lines == 0
            result = replay(dq)
            @test isempty(result.inbound)
        end
    end

    @testset "auto-compaction on threshold" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path, auto_compact_threshold=6)

            # Enqueue 3, ack 3 = 6 lines -> triggers auto-compact
            msgs = [make_test_inbound(text="msg$i") for i in 1:3]
            for m in msgs
                enqueue!(dq, m)
            end
            for m in msgs[1:2]
                ack!(dq, m.message_id)
            end
            @test dq.wal_lines == 5  # 3 enqueue + 2 ack, below threshold

            # The next ack pushes to 6 lines -> compact triggers
            ack!(dq, msgs[3].message_id)
            # After compaction, all acked -> 0 lines
            @test dq.wal_lines == 0
        end
    end

    @testset "queue_stats returns correct values" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            msg1 = make_test_inbound()
            msg2 = make_test_inbound()
            enqueue!(dq, msg1)
            enqueue!(dq, msg2)
            ack!(dq, msg1.message_id)

            stats = queue_stats(dq)
            @test stats["enqueued"] == 2
            @test stats["acked"] == 1
            @test stats["wal_lines"] == 3
            @test stats["wal_path"] == wal_path
        end
    end

    @testset "fresh DurableQueueState counts existing lines" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq1 = DurableQueueState(wal_path=wal_path)
            msg = make_test_inbound()
            enqueue!(dq1, msg)
            @test dq1.wal_lines == 1

            # Create fresh state pointing to same WAL
            dq2 = DurableQueueState(wal_path=wal_path)
            @test dq2.wal_lines == 1
        end
    end

    @testset "replay survives simulated crash" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")

            # "Process 1" enqueues but crashes before acking
            dq1 = DurableQueueState(wal_path=wal_path)
            msg = make_test_inbound(text="important")
            enqueue!(dq1, msg)
            # dq1 is "crashed" — no ack

            # "Process 2" restarts and replays
            dq2 = DurableQueueState(wal_path=wal_path)
            result = replay(dq2)
            @test length(result.inbound) == 1
            @test Krill.message_text(result.inbound[1]) == "important"

            # Process 2 processes and acks
            ack!(dq2, msg.message_id)
            result2 = replay(dq2)
            @test isempty(result2.inbound)
        end
    end

    @testset "replay skips malformed lines" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)
            msg = make_test_inbound(text="valid")
            enqueue!(dq, msg)

            # Append a malformed line
            open(wal_path, "a") do io
                println(io, "not json {{{")
            end
            dq.wal_lines += 1

            result = replay(dq)
            @test length(result.inbound) == 1
            @test Krill.message_text(result.inbound[1]) == "valid"
        end
    end

    @testset "concurrent enqueue is safe" begin
        mktempdir() do dir
            wal_path = joinpath(dir, "queue.wal")
            dq = DurableQueueState(wal_path=wal_path)

            tasks = [Threads.@spawn begin
                msg = make_test_inbound(text="concurrent $i")
                enqueue!(dq, msg)
            end for i in 1:20]

            for t in tasks
                wait(t)
            end

            @test dq.enqueued_count == 20
            @test dq.wal_lines == 20
            result = replay(dq)
            @test length(result.inbound) == 20
        end
    end

end
