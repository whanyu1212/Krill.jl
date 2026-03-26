using Krill
using Test
using Krill.Telegram: HTTP, JSON3
using UUIDs

@testset "Krill.jl C.2 tool permission model" begin
    @testset "allowed_tools blocks unauthorized tool calls" begin
        call_no = Ref(0)

        mock_request = function (method, url, headers, body)
            call_no[] += 1
            if call_no[] == 1
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_1",
                            "output" => Any[Dict(
                                "type" => "function_call",
                                "id" => "call_blocked",
                                "name" => "blocked_tool",
                                "arguments" => JSON3.write(Dict("x" => 1)),
                            )],
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            else
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_2",
                            "output_text" => "Permission was denied",
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            end
        end

        provider = OpenAIProvider(
            api_key = "test",
            model = "gpt-4.1-mini",
            base_url = "https://example.test/v1",
            request = mock_request,
            max_retries = 0,
        )

        blocked_tool = ToolDef(
            name = "blocked_tool",
            description = "should be blocked",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}("x" => Dict{String,Any}("type" => "integer")),
            ),
            execute = args -> "should never run",
        )

        processor = make_llm_processor(provider;
            tools = [blocked_tool],
            allowed_tools = ["safe_tool"],
            max_tool_iterations = 2,
        )

        msg = InboundMessage(
            channel = :telegram,
            session_key = "telegram:99",
            user_id = "99",
            chat_id = "99",
            text = "use the tool",
        )

        result = processor(msg, TurnRecord[])
        @test haskey(result.metadata, "tool_events")
        events = result.metadata["tool_events"]
        @test length(events) >= 1
        @test events[1].call.tool_name == "blocked_tool"
        @test events[1].result.error !== nothing
        @test events[1].result.error.code == "E_PERMISSION_DENIED"
        @test events[1].result.error.retriable == false
    end

    @testset "allowed_tools=nothing permits all tools" begin
        call_no = Ref(0)

        mock_request = function (method, url, headers, body)
            call_no[] += 1
            if call_no[] == 1
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_1",
                            "output" => Any[Dict(
                                "type" => "function_call",
                                "id" => "call_ok",
                                "name" => "any_tool",
                                "arguments" => JSON3.write(Dict("x" => 5)),
                            )],
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            else
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_2",
                            "output_text" => "done",
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            end
        end

        provider = OpenAIProvider(
            api_key = "test", model = "gpt-4.1-mini",
            base_url = "https://example.test/v1",
            request = mock_request, max_retries = 0,
        )

        tool = ToolDef(
            name = "any_tool",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}("x" => Dict{String,Any}("type" => "integer")),
            ),
            execute = args -> "result: $(args["x"])",
        )

        processor = make_llm_processor(provider;
            tools = [tool],
            max_tool_iterations = 2,
        )

        msg = InboundMessage(
            channel = :telegram,
            session_key = "telegram:99",
            user_id = "99",
            chat_id = "99",
            text = "go",
        )
        result = processor(msg, TurnRecord[])
        events = result.metadata["tool_events"]
        @test events[1].result.error === nothing
        @test events[1].result.result == "result: 5"
    end
end

@testset "Krill.jl C.2 ErrorEnvelope propagation" begin
    @testset "tool execution error produces ErrorEnvelope" begin
        call_no = Ref(0)

        mock_request = function (method, url, headers, body)
            call_no[] += 1
            if call_no[] == 1
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_1",
                            "output" => Any[Dict(
                                "type" => "function_call",
                                "id" => "call_err",
                                "name" => "failing_tool",
                                "arguments" => JSON3.write(Dict()),
                            )],
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            else
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_2",
                            "output_text" => "handled error",
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            end
        end

        provider = OpenAIProvider(
            api_key = "test", model = "gpt-4.1-mini",
            base_url = "https://example.test/v1",
            request = mock_request, max_retries = 0,
        )

        tool = ToolDef(
            name = "failing_tool",
            parameters = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}()),
            execute = args -> error("something broke"),
        )

        processor = make_llm_processor(provider;
            tools = [tool],
            max_tool_iterations = 2,
        )

        msg = InboundMessage(
            channel = :telegram,
            session_key = "telegram:99",
            user_id = "99",
            chat_id = "99",
            text = "run it",
        )
        result = processor(msg, TurnRecord[])
        events = result.metadata["tool_events"]
        @test length(events) >= 1
        @test events[1].call.tool_name == "failing_tool"
        @test events[1].result.error !== nothing
        @test events[1].result.error.code == "E_EXECUTION"
        @test occursin("something broke", events[1].result.error.message)
        @test events[1].result.result === nothing
    end
end

@testset "Krill.jl C.2 ToolCallEvent/ToolResultEvent persistence" begin
    @testset "tool events are ToolCallEvent/ToolResultEvent structs" begin
        call_no = Ref(0)

        mock_request = function (method, url, headers, body)
            call_no[] += 1
            if call_no[] == 1
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_1",
                            "output" => Any[Dict(
                                "type" => "function_call",
                                "id" => "call_typed",
                                "name" => "echo_tool",
                                "arguments" => JSON3.write(Dict("text" => "hello")),
                            )],
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            else
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_2",
                            "output_text" => "echoed",
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 5),
                        ),
                    ),
                )
            end
        end

        provider = OpenAIProvider(
            api_key = "test", model = "gpt-4.1-mini",
            base_url = "https://example.test/v1",
            request = mock_request, max_retries = 0,
        )

        tool = ToolDef(
            name = "echo_tool",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}("text" => Dict{String,Any}("type" => "string")),
            ),
            execute = args -> args["text"],
        )

        processor = make_llm_processor(provider;
            tools = [tool],
            max_tool_iterations = 2,
        )

        msg = InboundMessage(
            channel = :telegram,
            session_key = "telegram:77",
            user_id = "77",
            chat_id = "77",
            text = "echo this",
        )
        result = processor(msg, TurnRecord[])

        events = result.metadata["tool_events"]
        @test length(events) == 1

        evt = events[1]
        # Verify struct types
        @test evt.call isa ToolCallEvent
        @test evt.result isa ToolResultEvent

        # ToolCallEvent fields
        @test evt.call.session_key == "telegram:77"
        @test evt.call.tool_name == "echo_tool"
        @test evt.call.arguments["text"] == "hello"
        @test evt.call.version == 1
        @test evt.call.event_id isa UUID

        # ToolResultEvent fields
        @test evt.result.session_key == "telegram:77"
        @test evt.result.tool_name == "echo_tool"
        @test evt.result.correlation_id == evt.call.event_id
        @test evt.result.result == "hello"
        @test evt.result.error === nothing
    end
end

@testset "Krill.jl C.3 SSE protocol hardening" begin
    @testset "parse_sse_rpc handles keep-alive comments and multi-data events" begin
        body = """
        : keep-alive

        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

        """
        parsed = Krill.Core.MCP._parse_sse_rpc(body)
        @test parsed["id"] == 1
        @test haskey(parsed, "result")
    end

    @testset "parse_sse_rpc handles [DONE] sentinel" begin
        body = """
        data: {"jsonrpc":"2.0","id":42,"result":{"ok":true}}

        data: [DONE]

        """
        parsed = Krill.Core.MCP._parse_sse_rpc(body)
        @test parsed["id"] == 42
    end

    @testset "parse_sse_rpc handles trailing data without blank line" begin
        body = "data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}"
        parsed = Krill.Core.MCP._parse_sse_rpc(body)
        @test parsed["id"] == 99
    end

    @testset "parse_sse_rpc skips notifications (no id)" begin
        body = """
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        data: {"jsonrpc":"2.0","id":5,"result":{"value":"real"}}

        """
        parsed = Krill.Core.MCP._parse_sse_rpc(body)
        @test parsed["id"] == 5
        @test parsed["result"]["value"] == "real"
    end

    @testset "parse_sse_rpc raises on empty stream" begin
        @test_throws ErrorException Krill.Core.MCP._parse_sse_rpc("")
    end
end

@testset "Krill.jl C.3 MCP HTTP retry constants" begin
    @test Krill.Core.MCP._MCP_HTTP_MAX_RETRIES == 3
    @test Krill.Core.MCP._MCP_HTTP_RETRY_BASE_DELAY == 0.5
    @test 429 in Krill.Core.MCP._MCP_HTTP_RETRIABLE_STATUS
    @test 503 in Krill.Core.MCP._MCP_HTTP_RETRIABLE_STATUS
    @test 200 ∉ Krill.Core.MCP._MCP_HTTP_RETRIABLE_STATUS
end
