using Krill
using Krill: AbstractChannel, TelegramWebhookChannel
using Test
using UUIDs
using Dates
using HTTP
using JSON3

# ============================================================================
# Helpers
# ============================================================================

function make_mock_request_wh(responses::Vector)
    idx = Ref(0)
    return function(method, url, headers, body)
        idx[] += 1
        i = min(idx[], length(responses))
        resp = responses[i]
        if resp isa Function
            return resp(method, url, headers, body)
        end
        return resp
    end
end

function make_ok_response_wh(result; status=200)
    body = JSON3.write(Dict(:ok => true, :result => result))
    return HTTP.Response(status, [], body=Vector{UInt8}(body))
end

# ============================================================================
# Telegram Webhook API tests
# ============================================================================

@testset "Telegram Webhook" begin

    @testset "set_webhook API call" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, (method=method, url=url, body=JSON3.read(body)))
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        result = Krill.set_webhook(client, "https://example.com/webhook")
        @test length(api_calls) == 1
        @test contains(api_calls[1].url, "setWebhook")
        @test api_calls[1].body[:url] == "https://example.com/webhook"
    end

    @testset "set_webhook with secret_token" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, (method=method, url=url, body=JSON3.read(body)))
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        Krill.set_webhook(client, "https://example.com/wh"; secret_token="s3cret")
        @test api_calls[1].body[:secret_token] == "s3cret"
    end

    @testset "set_webhook with drop_pending_updates" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, (method=method, url=url, body=JSON3.read(body)))
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        Krill.set_webhook(client, "https://example.com/wh"; drop_pending_updates=true)
        @test api_calls[1].body[:drop_pending_updates] == true
    end

    @testset "delete_webhook API call" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, (method=method, url=url, body=JSON3.read(body)))
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        Krill.delete_webhook(client)
        @test length(api_calls) == 1
        @test contains(api_calls[1].url, "deleteWebhook")
    end

    @testset "delete_webhook with drop_pending_updates" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, (method=method, url=url, body=JSON3.read(body)))
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        Krill.delete_webhook(client; drop_pending_updates=true)
        @test api_calls[1].body[:drop_pending_updates] == true
    end

    # ========================================================================
    # TelegramWebhookChannel struct
    # ========================================================================

    @testset "TelegramWebhookChannel constructor" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client;
            url="https://example.com/webhook",
            host="127.0.0.1",
            port=9090,
            path="/hook",
            secret_token="s3cret",
        )
        @test ch.url == "https://example.com/webhook"
        @test ch.host == "127.0.0.1"
        @test ch.port == 9090
        @test ch.path == "/hook"
        @test ch.secret_token == "s3cret"
        @test ch.set_webhook_on_start == true
        @test ch.delete_webhook_on_stop == true
        @test ch.server === nothing
    end

    @testset "TelegramWebhookChannel token constructor" begin
        ch = TelegramWebhookChannel("tok";
            base_url="http://localhost:1",
            url="https://example.com/webhook",
        )
        @test ch isa TelegramWebhookChannel
        @test ch.client isa TelegramClient
    end

    @testset "TelegramWebhookChannel defaults" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/wh")
        @test ch.host == "0.0.0.0"
        @test ch.port == 8443
        @test ch.path == "/webhook"
        @test ch.secret_token === nothing
        @test ch.drop_pending_updates == false
    end

    @testset "channel_name returns :telegram" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/wh")
        @test Krill.channel_name(ch) === :telegram
    end

    @testset "TelegramWebhookChannel <: AbstractChannel" begin
        @test TelegramWebhookChannel <: Krill.AbstractChannel
    end

    @testset "make_sender returns a function" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/wh")
        sender = Krill.make_sender(ch)
        @test sender isa Function
    end

    @testset "normalize delegates to normalize_update" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/wh")
        update = Dict(
            :update_id => 1,
            :message => Dict(
                :message_id => 10,
                :chat => Dict(:id => 42, :type => "private"),
                :from => Dict(:id => 100, :is_bot => false, :first_name => "Test"),
                :text => "hello",
                :date => 1000,
            ),
        )
        msg = Krill.normalize(ch, update)
        @test msg isa InboundMessage
        @test msg.chat_id == "42"
        @test Krill.message_text(msg) == "hello"
    end

    # ========================================================================
    # Webhook HTTP handler
    # ========================================================================

    @testset "webhook router accepts POST to correct path" begin
        received = []
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/webhook", path="/webhook")
        handler = raw_event -> push!(received, raw_event)
        router = Krill.Channels.Telegram._make_webhook_router(ch, handler)

        update = Dict("update_id" => 1, "message" => Dict("message_id" => 10, "chat" => Dict("id" => 42), "text" => "hi", "from" => Dict("id" => 1)))
        body = Vector{UInt8}(JSON3.write(update))
        req = HTTP.Request("POST", "/webhook", [], body)
        resp = router(req)
        @test resp.status == 200
        @test length(received) == 1
    end

    @testset "webhook router rejects wrong path" begin
        received = []
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/webhook", path="/webhook")
        handler = raw_event -> push!(received, raw_event)
        router = Krill.Channels.Telegram._make_webhook_router(ch, handler)

        body = Vector{UInt8}(JSON3.write(Dict("update_id" => 1)))
        req = HTTP.Request("POST", "/other", [], body)
        resp = router(req)
        @test resp.status == 404
        @test isempty(received)
    end

    @testset "webhook router rejects GET" begin
        received = []
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/webhook", path="/webhook")
        handler = raw_event -> push!(received, raw_event)
        router = Krill.Channels.Telegram._make_webhook_router(ch, handler)

        req = HTTP.Request("GET", "/webhook", [], UInt8[])
        resp = router(req)
        @test resp.status == 404
        @test isempty(received)
    end

    @testset "webhook router enforces secret token" begin
        received = []
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client;
            url="https://example.com/webhook",
            path="/webhook",
            secret_token="my_secret",
        )
        handler = raw_event -> push!(received, raw_event)
        router = Krill.Channels.Telegram._make_webhook_router(ch, handler)

        update = Dict("update_id" => 1, "message" => Dict("message_id" => 10, "chat" => Dict("id" => 42), "text" => "hi", "from" => Dict("id" => 1)))
        body = Vector{UInt8}(JSON3.write(update))

        # No token header -> 403
        req = HTTP.Request("POST", "/webhook", [], body)
        resp = router(req)
        @test resp.status == 403
        @test isempty(received)

        # Wrong token -> 403
        req = HTTP.Request("POST", "/webhook", ["X-Telegram-Bot-Api-Secret-Token" => "wrong"], body)
        resp = router(req)
        @test resp.status == 403
        @test isempty(received)

        # Correct token -> 200
        req = HTTP.Request("POST", "/webhook", ["X-Telegram-Bot-Api-Secret-Token" => "my_secret"], body)
        resp = router(req)
        @test resp.status == 200
        @test length(received) == 1
    end

    @testset "webhook router handles malformed JSON" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/webhook", path="/webhook")
        handler = _ -> nothing
        router = Krill.Channels.Telegram._make_webhook_router(ch, handler)

        req = HTTP.Request("POST", "/webhook", [], Vector{UInt8}("not json"))
        resp = router(req)
        @test resp.status == 400
    end

    @testset "webhook router handles handler error gracefully" begin
        client = TelegramClient("tok"; base_url="http://localhost:1")
        ch = TelegramWebhookChannel(client; url="https://example.com/webhook", path="/webhook")
        handler = _ -> error("boom")
        router = Krill.Channels.Telegram._make_webhook_router(ch, handler)

        body = Vector{UInt8}(JSON3.write(Dict("update_id" => 1)))
        req = HTTP.Request("POST", "/webhook", [], body)
        resp = router(req)
        # Should still return 200 to Telegram
        @test resp.status == 200
    end

    # ========================================================================
    # stop_channel! cleanup
    # ========================================================================

    @testset "stop_channel! with no server is no-op" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, url)
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        ch = TelegramWebhookChannel(client;
            url="https://example.com/wh",
            delete_webhook_on_stop=true,
        )
        Krill.stop_channel!(ch)
        # Should still call deleteWebhook
        @test any(contains("deleteWebhook"), api_calls)
    end

    @testset "stop_channel! with delete_webhook_on_stop=false skips API call" begin
        api_calls = []
        mock_req = (method, url, headers, body) -> begin
            push!(api_calls, url)
            make_ok_response_wh(true)
        end
        client = TelegramClient("tok"; base_url="http://localhost:1", request=mock_req)
        ch = TelegramWebhookChannel(client;
            url="https://example.com/wh",
            delete_webhook_on_stop=false,
        )
        Krill.stop_channel!(ch)
        @test isempty(api_calls)
    end

end
