using Krill
using Krill: build_context, TurnRecord, InboundMessage, message_text
using Test
using UUIDs
using Dates

# ============================================================================
# Helpers
# ============================================================================

function make_turn(; role = :user, text = "hello", timestamp = now(UTC))
    return TurnRecord(role, text, uuid4(), nothing, timestamp)
end

function make_msg(; text = "current message")
    return InboundMessage(
        channel = :test,
        session_key = "test:1",
        user_id = "1",
        chat_id = "1",
        text = text,
    )
end

# ============================================================================
# Context window management tests
# ============================================================================

@testset "Context Window Management" begin
    @testset "build_context basic — no summarization" begin
        history = [
            make_turn(text = "hi"),
            make_turn(role = :assistant, text = "hello!"),
        ]
        msg = make_msg(text = "how are you?")
        ctx = build_context("You are helpful.", history, msg; max_context_tokens = 8000)
        @test ctx.instructions !== nothing
        @test length(ctx.messages) == 3  # 2 history + 1 current
    end

    @testset "build_context drops old turns when over budget" begin
        # Create history that exceeds budget
        long_text = repeat("word ", 500)  # ~500 tokens
        history = [
            make_turn(text = long_text),
            make_turn(role = :assistant, text = long_text),
            make_turn(text = "recent"),
            make_turn(role = :assistant, text = "recent reply"),
        ]
        msg = make_msg(text = "now")
        # Set tight budget so only recent turns fit
        ctx = build_context("System.", history, msg; max_context_tokens = 200)
        @test length(ctx.messages) < 5  # Not all turns fit
        @test length(ctx.messages) >= 1  # At least current message
    end

    @testset "build_context with history_summarizer — summarizes dropped turns" begin
        long_text = repeat("word ", 500)
        history = [
            make_turn(text = long_text),
            make_turn(role = :assistant, text = long_text),
            make_turn(text = "recent"),
        ]
        msg = make_msg(text = "now")

        summarizer_called = Ref(false)
        dropped_turns_received = Ref(TurnRecord[])

        mock_summarizer = (dropped::Vector{TurnRecord}) -> begin
            summarizer_called[] = true
            dropped_turns_received[] = dropped
            return "Summary: discussed words extensively."
        end

        ctx = build_context("System.", history, msg;
            max_context_tokens = 200,
            history_summarizer = mock_summarizer,
        )

        @test summarizer_called[]
        @test !isempty(dropped_turns_received[])
        @test contains(ctx.instructions, "Earlier Conversation Summary")
        @test contains(ctx.instructions, "discussed words extensively")
    end

    @testset "build_context — summarizer not called when nothing dropped" begin
        history = [make_turn(text = "short")]
        msg = make_msg(text = "hi")
        called = Ref(false)
        summarizer = (_) -> (called[] = true; "summary")

        ctx = build_context("System.", history, msg;
            max_context_tokens = 8000,
            history_summarizer = summarizer,
        )
        @test !called[]
    end

    @testset "build_context — summarizer returning nothing is handled" begin
        long_text = repeat("word ", 500)
        history = [make_turn(text = long_text)]
        msg = make_msg(text = "now")

        ctx = build_context("System.", history, msg;
            max_context_tokens = 50,
            history_summarizer = _ -> nothing,
        )
        # No crash, no summary block
        @test !contains(something(ctx.instructions, ""), "Earlier Conversation Summary")
    end

    @testset "build_context — summarizer returning empty string is handled" begin
        long_text = repeat("word ", 500)
        history = [make_turn(text = long_text)]
        msg = make_msg(text = "now")

        ctx = build_context("System.", history, msg;
            max_context_tokens = 50,
            history_summarizer = _ -> "   ",
        )
        @test !contains(something(ctx.instructions, ""), "Earlier Conversation Summary")
    end

    @testset "build_context — summarizer error is caught" begin
        long_text = repeat("word ", 500)
        history = [make_turn(text = long_text)]
        msg = make_msg(text = "now")

        # Summarizer throws — should not propagate
        ctx = build_context("System.", history, msg;
            max_context_tokens = 50,
            history_summarizer = _ -> error("boom"),
        )
        @test !contains(something(ctx.instructions, ""), "Earlier Conversation Summary")
    end

    @testset "build_context — summary appended to existing instructions" begin
        long_text = repeat("word ", 500)
        history = [make_turn(text = long_text)]
        msg = make_msg(text = "now")

        ctx = build_context("You are a bot.", history, msg;
            max_context_tokens = 50,
            history_summarizer = _ -> "The user asked about words.",
        )
        @test startswith(ctx.instructions, "You are a bot.")
        @test contains(ctx.instructions, "Earlier Conversation Summary")
        @test contains(ctx.instructions, "The user asked about words.")
    end

    @testset "build_context — summary works with nil system prompt" begin
        long_text = repeat("word ", 500)
        history = [make_turn(text = long_text)]
        msg = make_msg(text = "now")

        ctx = build_context(nothing, history, msg;
            max_context_tokens = 50,
            history_summarizer = _ -> "Previous discussion.",
        )
        @test ctx.instructions !== nothing
        @test contains(ctx.instructions, "Previous discussion.")
    end

    @testset "dropped turns are in original order" begin
        history = [
            make_turn(text = repeat("a ", 300)),  # will be dropped
            make_turn(role = :assistant, text = repeat("b ", 300)),  # will be dropped
            make_turn(text = "recent"),  # fits
        ]
        msg = make_msg(text = "now")

        dropped_order = Ref(String[])
        summarizer = (dropped) -> begin
            dropped_order[] = [t.text[1:1] for t in dropped]
            return "summary"
        end

        build_context("S.", history, msg;
            max_context_tokens = 100,
            history_summarizer = summarizer,
        )

        @test dropped_order[] == ["a", "b"]
    end

    @testset "build_context — no summarizer, backward compat" begin
        history = [make_turn(text = "old"), make_turn(text = "new")]
        msg = make_msg()
        # Should work exactly as before when no summarizer provided
        ctx = build_context("System.", history, msg; max_context_tokens = 8000)
        @test ctx.instructions == "System."
        @test length(ctx.messages) == 3
    end
end
