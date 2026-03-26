if !KRILL_FAST_TESTS
    @testset "Krill.jl Runtime with OpenAI provider" begin
        @testset "typing indicator + llm response + usage metadata" begin
            telegram_calls = Dict{String,Int}(
                "getUpdates" => 0,
                "sendChatAction" => 0,
                "sendMessage" => 0,
            )
            sent_texts = String[]
            action_payloads = Dict{Symbol,Any}[]

            mock_telegram_request = function (method, url, headers, body)
                payload = JSON3.read(String(body))
                if occursin("getUpdates", url)
                    telegram_calls["getUpdates"] += 1
                    if telegram_calls["getUpdates"] == 1
                        return HTTP.Response(
                            200,
                            JSON3.write(
                                Dict(
                                    "ok" => true,
                                    "result" => Any[
                                        Dict(
                                        "update_id" => 1200,
                                        "message" => Dict(
                                            "message_id" => 1, "text" => "hello llm",
                                            "chat" => Dict("id" => 42),
                                            "from" => Dict("id" => 42),
                                        ),
                                    ),
                                    ],
                                ),
                            ),
                        )
                    end
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
                elseif occursin("sendChatAction", url)
                    telegram_calls["sendChatAction"] += 1
                    push!(action_payloads, payload)
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
                elseif occursin("sendMessage", url)
                    telegram_calls["sendMessage"] += 1
                    push!(sent_texts, String(payload[:text]))
                    return HTTP.Response(200, JSON3.write(Dict(
                            "ok" => true,
                            "result" => Dict("message_id" => 2001),
                        )))
                end
            end

            mock_openai_request = function (method, url, headers, body)
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_test",
                            "output_text" => "hello from llm",
                            "usage" => Dict(
                                "input_tokens" => 9,
                                "output_tokens" => 4,
                                "total_tokens" => 13,
                                "input_tokens_details" => Dict("cached_tokens" => 0),
                                "output_tokens_details" => Dict("reasoning_tokens" => 1),
                            ),
                        ),
                    ),
                )
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_telegram_request,
            )

            provider = OpenAIProvider(
                api_key = "test-key",
                base_url = "https://example.openai.test/v1",
                request = mock_openai_request,
                max_retries = 0,
            )

            workspace = mktempdir()
            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8),
                workspace = workspace,
                llm_provider = provider,
                llm_reasoning = Dict("effort" => "low", "summary" => "auto"),
                llm_tools = Any[Dict("type" => "web_search")],
            )

            start!(runtime)
            sleep(0.5)
            shutdown!(runtime)

            @test telegram_calls["sendChatAction"] >= 1
            @test telegram_calls["sendMessage"] == 1
            @test sent_texts == ["hello from llm"]
            @test action_payloads[1][:action] == "typing"

            history = load_history(runtime.store, "telegram:42")
            @test length(history) == 2
            @test haskey(history[2].metadata, "usage")
        end

        @testset "runtime emits progress hint during tool execution" begin
            sent_texts = String[]
            telegram_calls = Dict{String,Int}(
                "getUpdates" => 0,
                "sendChatAction" => 0,
                "sendMessage" => 0,
            )
            call_no = Ref(0)

            mock_telegram_request = function (method, url, headers, body)
                payload = JSON3.read(String(body))
                if occursin("getUpdates", url)
                    telegram_calls["getUpdates"] += 1
                    if telegram_calls["getUpdates"] == 1
                        return HTTP.Response(
                            200,
                            JSON3.write(
                                Dict(
                                    "ok" => true,
                                    "result" => Any[
                                        Dict(
                                        "update_id" => 2200,
                                        "message" => Dict(
                                            "message_id" => 1, "text" => "run tool",
                                            "chat" => Dict("id" => 99),
                                            "from" => Dict("id" => 99),
                                        ),
                                    ),
                                    ],
                                ),
                            ),
                        )
                    end
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
                elseif occursin("sendChatAction", url)
                    telegram_calls["sendChatAction"] += 1
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
                elseif occursin("sendMessage", url)
                    telegram_calls["sendMessage"] += 1
                    push!(sent_texts, String(payload[:text]))
                    return HTTP.Response(200, JSON3.write(Dict(
                            "ok" => true,
                            "result" => Dict("message_id" => 2004),
                        )))
                end
                return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
            end

            mock_openai_request = function (method, url, headers, body)
                call_no[] += 1
                if call_no[] == 1
                    return HTTP.Response(
                        200,
                        JSON3.write(
                            Dict(
                                "id" => "resp_tool_call",
                                "output" => Any[
                                    Dict(
                                    "type" => "function_call",
                                    "id" => "fc_1",
                                    "call_id" => "call_1",
                                    "name" => "note_tool",
                                    "arguments" => "{\"query\":\"status\"}",
                                ),
                                ],
                                "usage" => Dict(
                                    "input_tokens" => 10,
                                    "output_tokens" => 3,
                                    "total_tokens" => 13,
                                    "input_tokens_details" => Dict("cached_tokens" => 0),
                                    "output_tokens_details" => Dict("reasoning_tokens" => 1),
                                ),
                            ),
                        ),
                    )
                end
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_tool_result",
                            "output_text" => "Note fetched",
                            "usage" => Dict(
                                "input_tokens" => 10,
                                "output_tokens" => 4,
                                "total_tokens" => 14,
                                "input_tokens_details" => Dict("cached_tokens" => 0),
                                "output_tokens_details" => Dict("reasoning_tokens" => 1),
                            ),
                        ),
                    ),
                )
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_telegram_request,
            )
            provider = OpenAIProvider(
                api_key = "test-key",
                base_url = "https://example.openai.test/v1",
                request = mock_openai_request,
                max_retries = 0,
            )
            note_tool = ToolDef(
                name = "note_tool",
                description = "Fetch note summary",
                parameters = Dict{String,Any}(
                    "type" => "object",
                    "properties" => Dict{String,Any}(
                        "query" => Dict("type" => "string", "description" => "Query"),
                    ),
                    "required" => Any["query"],
                ),
                execute = args -> "Note: $(get(args, "query", ""))",
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8),
                workspace = mktempdir(),
                llm_provider = provider,
                llm_enable_builtin_tools = false,
                llm_tools = Any[note_tool],
            )

            start!(runtime)
            sleep(0.5)
            shutdown!(runtime)

            @test telegram_calls["sendMessage"] == 2
            @test sent_texts[1] == "Working on \"note_tool\" for: status"
            @test sent_texts[2] == "Note fetched"
            @test telegram_calls["sendChatAction"] >= 1
        end
    end
end
