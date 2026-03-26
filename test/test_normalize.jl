@testset "Krill.jl normalize_update" begin
    @testset "normalizes standard message update" begin
        update = Dict{Symbol,Any}(
            :update_id => 100,
            :message => Dict{Symbol,Any}(
                :message_id => 1,
                :text => "hello",
                :chat => Dict{Symbol,Any}(:id => 5376),
                :from => Dict{Symbol,Any}(:id => 999),
            ),
        )

        inbound = normalize_update(update)

        @test inbound !== nothing
        @test inbound.channel == :telegram
        @test inbound.session_key == "telegram:5376"
        @test inbound.user_id == "999"
        @test inbound.chat_id == "5376"
        @test message_text(inbound) == "hello"
        @test inbound.raw === update
    end

    @testset "normalizes edited_message" begin
        update = Dict{Symbol,Any}(
            :update_id => 101,
            :edited_message => Dict{Symbol,Any}(
                :message_id => 2,
                :text => "edited",
                :chat => Dict{Symbol,Any}(:id => 42),
                :from => Dict{Symbol,Any}(:id => 7),
            ),
        )

        inbound = normalize_update(update)
        @test inbound !== nothing
        @test message_text(inbound) == "edited"
    end

    @testset "normalizes channel_post without :from" begin
        update = Dict{Symbol,Any}(
            :update_id => 102,
            :channel_post => Dict{Symbol,Any}(
                :message_id => 3,
                :text => "announcement",
                :chat => Dict{Symbol,Any}(:id => 88),
            ),
        )

        inbound = normalize_update(update)
        @test inbound !== nothing
        @test inbound.user_id == "88"  # falls back to chat_id
    end

    @testset "returns nothing for non-message updates" begin
        update = Dict{Symbol,Any}(
            :update_id => 103,
            :callback_query => Dict{Symbol,Any}(:id => "abc"),
        )

        @test normalize_update(update) === nothing
    end

    @testset "handles message with no text" begin
        update = Dict{Symbol,Any}(
            :update_id => 104,
            :message => Dict{Symbol,Any}(
                :message_id => 4,
                :chat => Dict{Symbol,Any}(:id => 55),
                :from => Dict{Symbol,Any}(:id => 55),
                :photo => Any[Dict(:file_id => "abc")],
            ),
        )

        inbound = normalize_update(update)
        @test inbound !== nothing
        @test message_text(inbound) == ""
    end
end

@testset "Krill.jl make_telegram_sender" begin
    @testset "sends outbound message text via client" begin
        sent = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            sent["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Dict("message_id" => 99),
            )))
        end

        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)
        sender = make_telegram_sender(client)

        msg = OutboundMessage(
            channel = :telegram,
            session_key = "telegram:1234",
            chat_id = "1234",
            text = "hi there",
            format = :telegram_html,
        )

        sender(msg)

        @test sent["payload"][:chat_id] == "1234"
        @test sent["payload"][:text] == "hi there"
        @test sent["payload"][:parse_mode] == "HTML"
    end

    @testset "plain format sends without parse_mode" begin
        sent = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            sent["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Dict("message_id" => 100),
            )))
        end

        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)
        sender = make_telegram_sender(client)

        msg = OutboundMessage(
            channel = :telegram,
            session_key = "telegram:1234",
            chat_id = "1234",
            text = "plain text",
            format = :plain,
        )

        sender(msg)

        @test sent["payload"][:text] == "plain text"
        @test !haskey(sent["payload"], :parse_mode)
    end

    @testset "markdown format renders to HTML parse_mode" begin
        sent = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            sent["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Dict("message_id" => 101),
            )))
        end

        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)
        sender = make_telegram_sender(client)

        msg = OutboundMessage(
            channel = :telegram,
            session_key = "telegram:1234",
            chat_id = "1234",
            text = "## Title\n**bold** and `x < y`\n\n[OpenAI](https://openai.com/?a=1&b=2)\n\n```julia\nx = 1 < 2\n```",
            format = :markdown,
        )

        sender(msg)

        @test sent["payload"][:parse_mode] == "HTML"
        rendered = String(sent["payload"][:text])
        @test occursin("<b>Title</b>", rendered)
        @test occursin("<b>bold</b>", rendered)
        @test occursin("<code>x &lt; y</code>", rendered)
        @test occursin("<a href=\"https://openai.com/?a=1&amp;b=2\">OpenAI</a>", rendered)
        @test occursin("<pre><code class=\"language-julia\">x = 1 &lt; 2", rendered)
    end

    @testset "HTML formatting falls back to plain text on 400" begin
        payloads = Any[]
        call_no = Ref(0)

        mock_request = function (method, url, headers, body)
            call_no[] += 1
            payload = JSON3.read(String(body))
            push!(payloads, payload)
            if call_no[] == 1
                return HTTP.Response(
                    400,
                    JSON3.write(
                        Dict(
                            "ok" => false,
                            "error_code" => 400,
                            "description" => "Bad Request: can't parse entities",
                        ),
                    ),
                )
            end
            return HTTP.Response(200, JSON3.write(Dict(
                "ok" => true,
                "result" => Dict("message_id" => 102),
            )))
        end

        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)
        sender = make_telegram_sender(client)

        msg = OutboundMessage(
            channel = :telegram,
            session_key = "telegram:1234",
            chat_id = "1234",
            text = "**fallback me**",
            format = :markdown,
        )

        sender(msg)

        @test length(payloads) == 2
        @test payloads[1][:parse_mode] == "HTML"
        @test !haskey(payloads[2], :parse_mode)
        @test payloads[2][:text] == "**fallback me**"
    end
end
