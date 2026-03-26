if !KRILL_FAST_TESTS
    @testset "Krill.jl Runtime with Gemini native provider" begin
        @testset "typing indicator + Gemini generateContent response + usage metadata" begin
            telegram_calls = Dict{String,Int}(
                "getUpdates" => 0,
                "sendChatAction" => 0,
                "sendMessage" => 0,
            )
            sent_texts = String[]

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
                                        "update_id" => 1300,
                                        "message" => Dict(
                                            "message_id" => 1, "text" => "hello gemini",
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
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
                elseif occursin("sendMessage", url)
                    telegram_calls["sendMessage"] += 1
                    push!(sent_texts, String(payload[:text]))
                    return HTTP.Response(200, JSON3.write(Dict(
                            "ok" => true,
                            "result" => Dict("message_id" => 2002),
                        )))
                end
            end

            mock_gemini_request = function (method, url, headers, body)
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "candidates" => Any[
                                Dict(
                                "content" => Dict(
                                    "role" => "model",
                                    "parts" => Any[
                                        Dict("text" => "hello from gemini"),
                                    ],
                                ),
                            ),
                            ],
                            "usageMetadata" => Dict(
                                "promptTokenCount" => 10,
                                "candidatesTokenCount" => 4,
                                "totalTokenCount" => 14,
                                "thoughtsTokenCount" => 1,
                            ),
                        ),
                    ),
                )
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_telegram_request,
            )

            provider = GeminiProvider(
                api_key = "gemini-key",
                base_url = "https://example.gemini.test/v1beta",
                request = mock_gemini_request,
                max_retries = 0,
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8),
                workspace = mktempdir(),
                llm_provider = provider,
                llm_reasoning = Dict("effort" => "low"),
                llm_tools = Any[Dict("type" => "function", "name" => "foo", "parameters" => Dict("type" => "object"))],
            )

            start!(runtime)
            sleep(0.5)
            shutdown!(runtime)

            @test telegram_calls["sendChatAction"] >= 1
            @test telegram_calls["sendMessage"] == 1
            @test sent_texts == ["hello from gemini"]

            history = load_history(runtime.store, "telegram:42")
            @test length(history) == 2
            @test haskey(history[2].metadata, "usage")
        end

        @testset "Gemini runtime injects bootstrap docs, memory, metadata, and safety into systemInstruction" begin
            workspace = mktempdir()
            write(joinpath(workspace, "AGENTS.md"), "Gemini agent instructions.")
            write(joinpath(workspace, "SOUL.md"), "Gemini personality.")
            save_memory!(MemoryStore(; workspace = workspace), "telegram:50", "User prefers Julia examples.")

            captured_payload = Ref{Any}(nothing)

            mock_telegram_request = function (method, url, headers, body)
                if occursin("getUpdates", url)
                    return HTTP.Response(
                        200,
                        JSON3.write(
                            Dict(
                                "ok" => true,
                                "result" => Any[
                                    Dict(
                                    "update_id" => 1400,
                                    "message" => Dict(
                                        "message_id" => 1,
                                        "text" => "test prompt context",
                                        "chat" => Dict("id" => 50),
                                        "from" => Dict("id" => 50),
                                    ),
                                ),
                                ],
                            ),
                        ),
                    )
                elseif occursin("sendChatAction", url)
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
                elseif occursin("sendMessage", url)
                    return HTTP.Response(200, JSON3.write(Dict(
                            "ok" => true,
                            "result" => Dict("message_id" => 2003),
                        )))
                end
                return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
            end

            mock_gemini_request = function (method, url, headers, body)
                payload = JSON3.read(String(body))
                captured_payload[] = payload
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "candidates" => Any[
                                Dict(
                                "content" => Dict(
                                    "role" => "model",
                                    "parts" => Any[Dict("text" => "gemini prompt context ok")],
                                ),
                            ),
                            ],
                            "usageMetadata" => Dict(
                                "promptTokenCount" => 15,
                                "candidatesTokenCount" => 5,
                                "totalTokenCount" => 20,
                            ),
                        ),
                    ),
                )
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_telegram_request,
            )
            provider = GeminiProvider(
                api_key = "gemini-key",
                base_url = "https://example.gemini.test/v1beta",
                request = mock_gemini_request,
                max_retries = 0,
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8),
                workspace = workspace,
                llm_provider = provider,
                llm_enable_builtin_tools = false,
                llm_enable_builtin_skills = false,
            )

            start!(runtime)
            sleep(0.5)
            shutdown!(runtime)

            payload = captured_payload[]
            @test payload !== nothing
            @test haskey(payload, :systemInstruction)
            si = payload[:systemInstruction]
            @test haskey(si, :parts)
            instructions_text = String(si[:parts][1][:text])

            # Bootstrap docs
            @test occursin("## Workspace Bootstrap Docs", instructions_text)
            @test occursin("### AGENTS.md", instructions_text)
            @test occursin("Gemini agent instructions.", instructions_text)
            @test occursin("### SOUL.md", instructions_text)
            @test occursin("Gemini personality.", instructions_text)

            # Session memory
            @test occursin("## Session Memory", instructions_text)
            @test occursin("User prefers Julia examples.", instructions_text)

            # Runtime metadata
            @test occursin(Krill.Core.RUNTIME_CONTEXT_MARKER, instructions_text)
            @test occursin("## Runtime Metadata", instructions_text)
            @test occursin("Channel: telegram", instructions_text)
            @test occursin("Session Key: telegram:50", instructions_text)
            @test occursin("Chat ID: 50", instructions_text)
            @test occursin("User ID: 50", instructions_text)

            # Tool safety notice
            @test occursin(Krill.Core.TOOL_OUTPUT_SAFETY_NOTICE, instructions_text)
        end
    end
end  # !KRILL_FAST_TESTS (Gemini native provider)
