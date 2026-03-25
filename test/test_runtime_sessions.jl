if !KRILL_FAST_TESTS
    @testset "Krill.jl Runtime with sessions" begin
        @testset "session-aware echo runtime end-to-end" begin
        call_count = Ref(0)
        sent_messages = Dict{String,Any}[]

        mock_request = function(method, url, headers, body)
            payload = JSON3.read(String(body))
            if occursin("getUpdates", url)
                call_count[] += 1
                if call_count[] == 1
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true,
                        "result" => Any[
                            Dict("update_id" => 900, "message" => Dict(
                                "message_id" => 1, "text" => "session hello",
                                "chat" => Dict("id" => 42),
                                "from" => Dict("id" => 42),
                            )),
                        ],
                    )))
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

        workspace = mktempdir()
        client = TelegramClient("token";
            base_url="https://example.test/botTOKEN",
            request=mock_request,
        )

        runtime = RuntimeState(TelegramChannel(client; poll_timeout=0, poll_interval=0.01);
            hub=MessageHubState(inbound_capacity=8, outbound_capacity=8),
            workspace=workspace,
        )

        start!(runtime)
        sleep(0.5)
        shutdown!(runtime)

        @test length(sent_messages) == 1
        @test sent_messages[1]["text"] == "session hello"

        history = load_history(runtime.store, "telegram:42")
        @test length(history) == 2
        @test history[1].role == :user
        @test history[1].text == "session hello"
        @test history[2].role == :assistant
        @test history[2].text == "session hello"
        end
    end
end
