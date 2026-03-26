@testset "Krill.jl runtime memory injection" begin
    @testset "RuntimeState injects bootstrap docs and runtime metadata" begin
        workspace = mktempdir()
        write(joinpath(workspace, "AGENTS.md"), "Workspace agent profile.")
        write(joinpath(workspace, "SOUL.md"), "Workspace personality details.")

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
                                "update_id" => 6299,
                                "message" => Dict(
                                    "message_id" => 1,
                                    "text" => "hello",
                                    "chat" => Dict("id" => 8),
                                    "from" => Dict("id" => 8),
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
                    "result" => Dict("message_id" => 1001),
                )))
            end
            return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
        end

        mock_openai_request = function (method, url, headers, body)
            payload = JSON3.read(String(body))
            captured_payload[] = payload
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "id" => "resp_prompt_context",
                        "output_text" => "ok",
                        "usage" => Dict("input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12),
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

        runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
            workspace = workspace,
            llm_provider = provider,
            llm_enable_builtin_tools = false,
            llm_enable_builtin_skills = false,
        )

        start!(runtime)
        sleep(0.35)
        shutdown!(runtime)

        payload = captured_payload[]
        @test payload !== nothing
        @test haskey(payload, :instructions)
        instructions = String(payload[:instructions])
        @test occursin(Krill.Core.RUNTIME_CONTEXT_MARKER, instructions)
        @test occursin("## Workspace Bootstrap Docs", instructions)
        @test occursin("### AGENTS.md", instructions)
        @test occursin("Workspace agent profile.", instructions)
        @test occursin("### SOUL.md", instructions)
        @test occursin("Workspace personality details.", instructions)
        @test occursin("## Runtime Metadata", instructions)
        @test occursin("Channel: telegram", instructions)
        @test occursin("Session Key: telegram:8", instructions)
        @test occursin("Chat ID: 8", instructions)
        @test occursin("User ID: 8", instructions)
        @test occursin(Krill.Core.TOOL_OUTPUT_SAFETY_NOTICE, instructions)
    end

    @testset "RuntimeState appends MEMORY.md content to instructions" begin
        workspace = mktempdir()
        save_memory!(MemoryStore(; workspace = workspace), "telegram:8", "User prefers compact Julia examples.")

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
                                "update_id" => 6300,
                                "message" => Dict(
                                    "message_id" => 1,
                                    "text" => "hello",
                                    "chat" => Dict("id" => 8),
                                    "from" => Dict("id" => 8),
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
                    "result" => Dict("message_id" => 1002),
                )))
            end
            return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
        end

        mock_openai_request = function (method, url, headers, body)
            payload = JSON3.read(String(body))
            captured_payload[] = payload
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "id" => "resp_memory_prompt",
                        "output_text" => "ok",
                        "usage" => Dict("input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12),
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

        runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
            workspace = workspace,
            llm_provider = provider,
            llm_enable_builtin_tools = false,
            llm_enable_builtin_skills = false,
        )

        start!(runtime)
        sleep(0.35)
        shutdown!(runtime)

        payload = captured_payload[]
        @test payload !== nothing
        @test haskey(payload, :instructions)
        @test occursin("## Session Memory", String(payload[:instructions]))
        @test occursin("compact Julia examples", String(payload[:instructions]))
    end
end
