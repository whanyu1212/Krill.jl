@testset "Krill.jl Telegram connector" begin
    @testset "TelegramClient constructor" begin
        client = TelegramClient("abc123")
        @test client.token == "abc123"
        @test client.base_url == "https://api.telegram.org/botabc123"
    end

    @testset "send_message builds request and parses success" begin
        captured = Dict{String,Any}()

        mock_request = function(method, url, headers, body)
            captured["method"] = method
            captured["url"] = url
            captured["headers"] = headers
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Dict("message_id" => 42),
            )))
        end

        client = TelegramClient("token"; base_url="https://example.test/botTOKEN", request=mock_request)
        result = send_message(client, 12345, "hello from krill"; parse_mode="HTML")

        @test captured["method"] == "POST"
        @test captured["url"] == "https://example.test/botTOKEN/sendMessage"
        @test captured["payload"][:chat_id] == 12345
        @test captured["payload"][:text] == "hello from krill"
        @test captured["payload"][:parse_mode] == "HTML"
        @test result[:message_id] == 42
    end

    @testset "send_chat_action builds request and parses success" begin
        captured = Dict{String,Any}()

        mock_request = function(method, url, headers, body)
            captured["method"] = method
            captured["url"] = url
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => true,
            )))
        end

        client = TelegramClient("token"; base_url="https://example.test/botTOKEN", request=mock_request)
        result = send_chat_action(client, 12345, "typing")

        @test captured["method"] == "POST"
        @test captured["url"] == "https://example.test/botTOKEN/sendChatAction"
        @test captured["payload"][:chat_id] == 12345
        @test captured["payload"][:action] == "typing"
        @test result == true
    end

    @testset "get_updates sends polling payload" begin
        captured = Dict{String,Any}()

        mock_request = function(method, url, headers, body)
            captured["method"] = method
            captured["url"] = url
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Any[
                    Dict("update_id" => 10),
                    Dict("update_id" => 11),
                ],
            )))
        end

        client = TelegramClient("token"; base_url="https://example.test/botTOKEN", request=mock_request)
        updates = get_updates(client; offset=5, timeout=20, limit=2, allowed_updates=["message"])

        @test captured["method"] == "POST"
        @test captured["url"] == "https://example.test/botTOKEN/getUpdates"
        @test captured["payload"][:offset] == 5
        @test captured["payload"][:timeout] == 20
        @test captured["payload"][:limit] == 2
        @test captured["payload"][:allowed_updates][1] == "message"
        @test length(updates) == 2
        @test updates[1][:update_id] == 10
    end

    @testset "TelegramAPIError on API-level failure" begin
        mock_request = function(method, url, headers, body)
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => false,
                "error_code" => 401,
                "description" => "Unauthorized",
            )))
        end

        client = TelegramClient("badtoken"; base_url="https://example.test/botBAD", request=mock_request)

        err = try
            get_updates(client)
            nothing
        catch e
            e
        end

        @test err isa TelegramAPIError
        @test err.code == 401
        @test err.description == "Unauthorized"
        @test err.method == "getUpdates"
    end

    @testset "TelegramAPIError on non-2xx HTTP status" begin
        mock_request = function(method, url, headers, body)
            return HTTP.Response(500, "internal error")
        end

        client = TelegramClient("token"; base_url="https://example.test/botTOKEN", request=mock_request)

        err = try
            send_message(client, 1, "hi")
            nothing
        catch e
            e
        end

        @test err isa TelegramAPIError
        @test err.code == 500
        @test err.method == "sendMessage"
    end

    @testset "run_polling processes updates and stops at max_updates" begin
        calls = Ref(0)

        mock_request = function(method, url, headers, body)
            calls[] += 1
            if calls[] == 1
                return HTTP.Response(200, JSON3.write(Dict(
                    "ok" => true,
                    "result" => Any[
                        Dict("update_id" => 21, "message" => Dict("text" => "a")),
                        Dict("update_id" => 22, "message" => Dict("text" => "b")),
                    ],
                )))
            end

            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Any[],
            )))
        end

        client = TelegramClient("token"; base_url="https://example.test/botTOKEN", request=mock_request)

        seen = Int[]
        processed = run_polling(client, update -> push!(seen, Int(update[:update_id])); timeout=0, poll_interval=0.0, max_updates=2)

        @test processed == 2
        @test seen == [21, 22]
        @test calls[] == 1
    end

    @testset "run_polling survives handler exceptions" begin
        calls = Ref(0)

        mock_request = function(method, url, headers, body)
            calls[] += 1
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Any[
                    Dict("update_id" => 30 + calls[], "message" => Dict("text" => "x")),
                ],
            )))
        end

        client = TelegramClient("token"; base_url="https://example.test/botTOKEN", request=mock_request)

        handler_calls = Ref(0)
        processed = run_polling(client, function(update)
            handler_calls[] += 1
            if handler_calls[] == 1
                error("boom")  # should not kill polling
            end
        end; timeout=0, poll_interval=0.0, max_updates=2)

        @test processed == 2
        @test handler_calls[] == 2  # both invoked despite first throwing
    end
end
