if !KRILL_FAST_TESTS
    @testset "Krill.jl Runtime integration" begin
        @testset "echo runtime end-to-end with mocked polling" begin
            call_count = Ref(0)
            sent_messages = Dict{String,Any}[]

            mock_request = function (method, url, headers, body)
                payload = JSON3.read(String(body))

                if occursin("getUpdates", url)
                    call_count[] += 1
                    if call_count[] == 1
                        return HTTP.Response(
                            200,
                            JSON3.write(
                                Dict(
                                    "ok" => true,
                                    "result" => Any[
                                        Dict(
                                            "update_id" => 500,
                                            "message" => Dict(
                                                "message_id" => 1, "text" => "hello",
                                                "chat" => Dict("id" => 42),
                                                "from" => Dict("id" => 42),
                                            ),
                                        ),
                                        Dict(
                                            "update_id" => 501,
                                            "message" => Dict(
                                                "message_id" => 2, "text" => "world",
                                                "chat" => Dict("id" => 42),
                                                "from" => Dict("id" => 42),
                                            ),
                                        ),
                                    ],
                                ),
                            ),
                        )
                    end
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true, "result" => Any[],
                    )))
                elseif occursin("sendMessage", url)
                    push!(sent_messages, Dict{String,Any}(
                            "chat_id" => payload[:chat_id],
                            "text" => String(payload[:text]),
                        ))
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true,
                        "result" => Dict("message_id" => 99),
                    )))
                end
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_request,
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                hub = MessageHubState(inbound_capacity = 8, outbound_capacity = 8),
                workspace = mktempdir(),
            )

            start!(runtime)
            deadline = time() + 3.0
            while length(sent_messages) < 2 && time() < deadline
                sleep(0.05)
            end
            st = status(runtime)
            shutdown!(runtime)

            @test length(sent_messages) == 2
            texts = [m["text"] for m in sent_messages]
            @test "hello" in texts
            @test "world" in texts
            @test st["running"] == true
            @test st["dispatch_alive"] == true
            @test st["last_successful_poll_at"] !== nothing

            after = status(runtime)
            @test after["running"] == false
            @test after["dispatch_alive"] == false
            @test after["last_successful_send_at"] !== nothing
        end

        @testset "dedup skips duplicate update_ids" begin
            call_count = Ref(0)
            sent_messages = String[]

            mock_request = function (method, url, headers, body)
                if occursin("getUpdates", url)
                    call_count[] += 1
                    if call_count[] <= 2
                        return HTTP.Response(
                            200,
                            JSON3.write(
                                Dict(
                                    "ok" => true,
                                    "result" => Any[
                                        Dict(
                                        "update_id" => 600,
                                        "message" => Dict(
                                            "message_id" => 1, "text" => "dedup me",
                                            "chat" => Dict("id" => 99),
                                            "from" => Dict("id" => 99),
                                        ),
                                    ),
                                    ],
                                ),
                            ),
                        )
                    end
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true, "result" => Any[],
                    )))
                elseif occursin("sendMessage", url)
                    payload = JSON3.read(String(body))
                    push!(sent_messages, String(payload[:text]))
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true,
                        "result" => Dict("message_id" => 99),
                    )))
                end
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_request,
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                workspace = mktempdir(),
            )

            start!(runtime)
            sleep(0.3)
            shutdown!(runtime)

            @test length(sent_messages) == 1
            @test sent_messages[1] == "dedup me"
        end

        @testset "shutdown is clean" begin
            mock_request = function (method, url, headers, body)
                return HTTP.Response(200, JSON3.write(Dict(
                    "ok" => true, "result" => Any[],
                )))
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_request,
            )

            runtime =
                RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01); workspace = mktempdir())

            start!(runtime)
            sleep(0.1)
            shutdown!(runtime)

            @test runtime.running[] == false
            @test runtime.channel_states[1].inbound_task === nothing
            @test runtime.consumer_task === nothing
        end

        @testset "backpressure does not deadlock" begin
            call_count = Ref(0)

            mock_request = function (method, url, headers, body)
                if occursin("getUpdates", url)
                    call_count[] += 1
                    if call_count[] == 1
                        return HTTP.Response(
                            200,
                            JSON3.write(
                                Dict(
                                    "ok" => true,
                                    "result" => Any[
                                        Dict(
                                            "update_id" => 700 + i,
                                            "message" => Dict(
                                                "message_id" => i, "text" => "msg$i",
                                                "chat" => Dict("id" => 1),
                                                "from" => Dict("id" => 1),
                                            ),
                                        ) for i in 1:5
                                    ],
                                ),
                            ),
                        )
                    end
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true, "result" => Any[],
                    )))
                elseif occursin("sendMessage", url)
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true,
                        "result" => Dict("message_id" => 99),
                    )))
                end
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_request,
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                hub = MessageHubState(inbound_capacity = 1, outbound_capacity = 8),
                workspace = mktempdir(),
            )

            start!(runtime)
            sleep(0.3)
            shutdown!(runtime)

            # If we reach here, no deadlock occurred
            @test runtime.running[] == false
        end
    end
end

# ───────────────────────────────────────────────────────────────────
# Phase B tests
# ───────────────────────────────────────────────────────────────────
