@testset "Krill.jl Core types" begin
    @testset "InboundMessage defaults and text extraction" begin
        inbound = InboundMessage(
            channel = :telegram,
            session_key = "telegram:5376052137",
            user_id = "5376052137",
            chat_id = "5376052137",
            text = "hello from inbound",
        )

        @test inbound.version == 1
        @test inbound.channel == :telegram
        @test inbound.session_key == "telegram:5376052137"
        @test inbound.idempotency_key == string(inbound.message_id)
        @test length(inbound.content_parts) == 1
        @test inbound.content_parts[1] isa TextPart
        @test message_text(inbound) == "hello from inbound"
    end

    @testset "OutboundMessage with delivery policy" begin
        policy = DeliveryPolicy(max_retries = 5, timeout_ms = 5_000, priority = 2, drop_if_late = true)
        outbound = OutboundMessage(
            channel = :telegram,
            session_key = "telegram:5376052137",
            chat_id = "5376052137",
            text = "hello from outbound",
            format = :telegram_html,
            delivery_policy = policy,
        )

        @test outbound.version == 1
        @test outbound.channel == :telegram
        @test outbound.format == :telegram_html
        @test outbound.delivery_policy.max_retries == 5
        @test outbound.delivery_policy.timeout_ms == 5_000
        @test outbound.delivery_policy.drop_if_late == true
        @test message_text(outbound) == "hello from outbound"
    end

    @testset "Tool call/result events and error envelope" begin
        call_event = ToolCallEvent(
            session_key = "telegram:5376052137",
            tool_name = "shell",
            arguments = Dict{String,Any}("command" => "ls -la"),
        )

        @test call_event.version == 1
        @test call_event.tool_name == "shell"
        @test call_event.arguments["command"] == "ls -la"

        success_result = ToolResultEvent(
            session_key = "telegram:5376052137",
            tool_name = "shell",
            result = Dict{String,Any}("status" => "ok"),
            duration_ms = 42.5,
        )
        @test success_result.error === nothing
        @test success_result.result["status"] == "ok"
        @test success_result.duration_ms == 42.5

        no_duration_result = ToolResultEvent(
            session_key = "telegram:5376052137",
            tool_name = "shell",
            result = "ok",
        )
        @test no_duration_result.duration_ms === nothing

        err = ErrorEnvelope("E_TIMEOUT", "tool timed out", true, Dict{String,Any}("attempt" => 1))
        failed_result = ToolResultEvent(
            session_key = "telegram:5376052137",
            tool_name = "shell",
            result = nothing,
            error = err,
            duration_ms = 1500.0,
        )

        @test failed_result.error !== nothing
        @test failed_result.error.code == "E_TIMEOUT"
        @test failed_result.error.retriable == true
        @test failed_result.duration_ms == 1500.0
    end

    @testset "DeliveryPolicy validation" begin
        @test_throws ArgumentError DeliveryPolicy(max_retries = -1)
        @test_throws ArgumentError DeliveryPolicy(timeout_ms = -1)
    end
end
