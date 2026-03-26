using Krill
using Krill: AbstractChannel
using Test
using UUIDs
using Dates
using HTTP
using JSON3

# ============================================================================
# Helpers
# ============================================================================

function make_mock_request(responses::Vector)
    idx = Ref(0)
    return function (method, url, headers, body)
        idx[] += 1
        i = min(idx[], length(responses))
        resp = responses[i]
        if resp isa Function
            return resp(method, url, headers, body)
        end
        return resp
    end
end

function make_ok_response(result; status = 200)
    body = JSON3.write(Dict(:ok => true, :result => result))
    return HTTP.Response(status, [], body = Vector{UInt8}(body))
end

function make_discord_response(data; status = 200)
    body = data === nothing ? UInt8[] : Vector{UInt8}(JSON3.write(data))
    return HTTP.Response(status, [], body = body)
end

# ============================================================================
# AbstractChannel trait tests
# ============================================================================

@testset "AbstractChannel trait" begin
    @testset "AbstractChannel is abstract" begin
        @test isabstracttype(Krill.AbstractChannel)
        @test TelegramChannel <: Krill.AbstractChannel
        @test DiscordChannel <: Krill.AbstractChannel
    end

    @testset "channel_name returns correct symbols" begin
        tg_client = TelegramClient("tok"; base_url = "http://localhost:1")
        tg = TelegramChannel(tg_client)
        @test channel_name(tg) === :telegram

        dc_client = DiscordClient("tok"; api_base = "http://localhost:1")
        dc = DiscordChannel(dc_client)
        @test channel_name(dc) === :discord
    end

    @testset "make_sender returns callable" begin
        tg_client = TelegramClient("tok"; base_url = "http://localhost:1")
        tg = TelegramChannel(tg_client)
        sender = make_sender(tg)
        @test sender isa Function

        dc_client = DiscordClient("tok"; api_base = "http://localhost:1")
        dc = DiscordChannel(dc_client)
        sender = make_sender(dc)
        @test sender isa Function
    end

    @testset "default stop_channel! is no-op" begin
        # Custom channel with no stop_channel! override
        # AbstractChannel default should work
        tg_client = TelegramClient("tok"; base_url = "http://localhost:1")
        tg = TelegramChannel(tg_client)
        @test stop_channel!(tg) === nothing
    end

    @testset "ChannelState construction" begin
        tg_client = TelegramClient("tok"; base_url = "http://localhost:1")
        tg = TelegramChannel(tg_client)
        cs = ChannelState(tg)
        @test cs.channel === tg
        @test cs.sender isa Function
        @test cs.inbound_task === nothing
    end
end

# ============================================================================
# TelegramChannel tests
# ============================================================================

@testset "TelegramChannel" begin
    @testset "construction from TelegramClient" begin
        client = TelegramClient("tok"; base_url = "http://localhost:1")
        ch = TelegramChannel(client)
        @test ch.client === client
        @test ch.poll_timeout == 30
        @test ch.poll_interval == 0.1
    end

    @testset "construction from token" begin
        ch = TelegramChannel("tok"; base_url = "http://localhost:1", poll_timeout = 60)
        @test ch.client isa TelegramClient
        @test ch.poll_timeout == 60
    end

    @testset "construction with custom params" begin
        client = TelegramClient("tok"; base_url = "http://localhost:1")
        ch = TelegramChannel(client; poll_timeout = 10, poll_interval = 0.5)
        @test ch.poll_timeout == 10
        @test ch.poll_interval == 0.5
    end

    @testset "normalize delegates to normalize_update" begin
        ch = TelegramChannel("tok"; base_url = "http://localhost:1")
        update = Dict(
            :update_id => 100,
            :message => Dict(
                :text => "hello",
                :chat => Dict(:id => 42),
                :from => Dict(:id => 7),
            ),
        )
        msg = normalize(ch, update)
        @test msg isa InboundMessage
        @test msg.channel === :telegram
        @test msg.session_key == "telegram:42"
        @test msg.chat_id == "42"
        @test msg.user_id == "7"
        @test Krill.message_text(msg) == "hello"
    end

    @testset "normalize returns nothing for non-message update" begin
        ch = TelegramChannel("tok"; base_url = "http://localhost:1")
        @test normalize(ch, Dict(:callback_query => Dict())) === nothing
    end

    @testset "send_typing calls send_chat_action" begin
        called = Ref(false)
        req = (method, url, headers, body) -> begin
            if contains(url, "sendChatAction")
                parsed = JSON3.read(String(body))
                @test String(parsed[:action]) == "typing"
                called[] = true
            end
            return make_ok_response(true)
        end
        client = TelegramClient("tok"; base_url = "http://test", request = req)
        ch = TelegramChannel(client)
        send_typing(ch, "123")
        @test called[]
    end

    @testset "send_direct calls send_message" begin
        sent_text = Ref("")
        req = (method, url, headers, body) -> begin
            if contains(url, "sendMessage")
                parsed = JSON3.read(String(body))
                sent_text[] = String(parsed[:text])
            end
            return make_ok_response(Dict(:message_id => 1))
        end
        client = TelegramClient("tok"; base_url = "http://test", request = req)
        ch = TelegramChannel(client)
        send_direct(ch, "123", "hello world")
        @test sent_text[] == "hello world"
    end

    @testset "start_channel! spawns polling task" begin
        poll_count = Ref(0)
        req = (method, url, headers, body) -> begin
            poll_count[] += 1
            return make_ok_response([])
        end
        client = TelegramClient("tok"; base_url = "http://test", request = req)
        ch = TelegramChannel(client; poll_timeout = 1, poll_interval = 0.01)
        hub = MessageHubState()
        running = Ref(true)
        task = start_channel!(ch, hub, running)
        @test task isa Task
        sleep(0.1)
        running[] = false
        wait(task)
        @test poll_count[] > 0
    end
end

# ============================================================================
# DiscordChannel tests
# ============================================================================

@testset "DiscordChannel" begin
    @testset "construction from DiscordClient" begin
        client = DiscordClient("tok"; api_base = "http://localhost:1")
        ch = DiscordChannel(client)
        @test ch.client === client
        @test ch.intents > 0
    end

    @testset "construction from token" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        @test ch.client isa DiscordClient
    end

    @testset "normalize_discord_event - guild message" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        event = Dict(
            :id => "123456789",
            :content => "hello from discord",
            :channel_id => "chan_1",
            :guild_id => "guild_1",
            :author => Dict(:id => "user_1", :username => "testuser", :bot => false),
        )
        msg = normalize(ch, event)
        @test msg isa InboundMessage
        @test msg.channel === :discord
        @test msg.session_key == "discord:guild_1:chan_1"
        @test msg.chat_id == "chan_1"
        @test msg.user_id == "user_1"
        @test Krill.message_text(msg) == "hello from discord"
        @test msg.metadata["guild_id"] == "guild_1"
        @test msg.metadata["username"] == "testuser"
    end

    @testset "normalize_discord_event - DM" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        event = Dict(
            :id => "999",
            :content => "DM message",
            :channel_id => "dm_chan",
            :author => Dict(:id => "user_2", :username => "dmuser"),
        )
        msg = normalize(ch, event)
        @test msg isa InboundMessage
        @test msg.session_key == "discord:dm:dm_chan"
    end

    @testset "normalize_discord_event - skips bot messages" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        event = Dict(
            :id => "100",
            :content => "I am a bot",
            :channel_id => "chan",
            :author => Dict(:id => "bot_1", :username => "bot", :bot => true),
        )
        @test normalize(ch, event) === nothing
    end

    @testset "normalize_discord_event - missing content" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        @test normalize(ch, Dict(:author => Dict(:id => "1"))) === nothing
    end

    @testset "normalize_discord_event - missing author" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        @test normalize(ch, Dict(:content => "test")) === nothing
    end

    @testset "discord_send_message" begin
        sent = Ref{Any}(nothing)
        req = (method, url, headers, body) -> begin
            sent[] = (method = method, url = url, body = JSON3.read(String(body)))
            return make_discord_response(Dict(:id => "msg_1"))
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        discord_send_message(client, "chan_1", "hello")
        @test sent[] !== nothing
        @test sent[].method == "POST"
        @test contains(sent[].url, "/channels/chan_1/messages")
        @test String(sent[].body[:content]) == "hello"
    end

    @testset "discord_trigger_typing" begin
        called = Ref(false)
        req = (method, url, headers, body) -> begin
            if contains(url, "/typing")
                called[] = true
            end
            return make_discord_response(nothing; status = 204)
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        discord_trigger_typing(client, "chan_1")
        @test called[]
    end

    @testset "send_typing delegates" begin
        called = Ref(false)
        req = (method, url, headers, body) -> begin
            if contains(url, "/typing")
                called[] = true
            end
            return make_discord_response(nothing; status = 204)
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        ch = DiscordChannel(client)
        send_typing(ch, "chan_1")
        @test called[]
    end

    @testset "send_direct delegates" begin
        sent_content = Ref("")
        req = (method, url, headers, body) -> begin
            parsed = JSON3.read(String(body))
            sent_content[] = String(parsed[:content])
            return make_discord_response(Dict(:id => "msg_1"))
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        ch = DiscordChannel(client)
        send_direct(ch, "chan_1", "test message")
        @test sent_content[] == "test message"
    end

    @testset "DiscordAPIError on failure" begin
        req = (method, url, headers, body) -> begin
            body_data = JSON3.write(Dict(:message => "Not Found", :code => 0))
            return HTTP.Response(404, [], body = Vector{UInt8}(body_data))
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        @test_throws DiscordAPIError discord_send_message(client, "bad_chan", "test")
    end

    @testset "message splitting for long messages" begin
        req = (method, url, headers, body) -> begin
            return make_discord_response(Dict(:id => "msg_1"))
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        ch = DiscordChannel(client)
        sender = make_sender(ch)

        # Create a message longer than 2000 chars
        long_text = repeat("a", 3000)
        msg = OutboundMessage(
            channel = :discord,
            session_key = "discord:dm:test",
            chat_id = "chan_1",
            text = long_text,
        )
        # Should not throw — splits internally
        sender(msg)
    end

    @testset "HTML to Discord markdown conversion" begin
        req = (method, url, headers, body) -> begin
            return make_discord_response(Dict(:id => "msg_1"))
        end
        client = DiscordClient("tok"; api_base = "http://test", request = req)
        ch = DiscordChannel(client)
        sender = make_sender(ch)

        sent_texts = String[]
        req2 = (method, url, headers, body) -> begin
            parsed = JSON3.read(String(body))
            push!(sent_texts, String(parsed[:content]))
            return make_discord_response(Dict(:id => "msg_1"))
        end
        client2 = DiscordClient("tok"; api_base = "http://test", request = req2)
        sender2 = Krill.Channels.Discord.make_discord_sender(client2)

        msg = OutboundMessage(
            channel = :discord,
            session_key = "discord:dm:test",
            chat_id = "chan_1",
            text = "<b>bold</b> and <i>italic</i>",
            format = :telegram_html,
        )
        sender2(msg)
        @test length(sent_texts) == 1
        @test contains(sent_texts[1], "**bold**")
        @test contains(sent_texts[1], "*italic*")
    end
end

# ============================================================================
# RuntimeState multi-channel integration
# ============================================================================

@testset "RuntimeState channel integration" begin
    @testset "TelegramChannel constructor" begin
        client = TelegramClient("tok"; base_url = "http://localhost:1")
        ch = TelegramChannel(client)
        rt = RuntimeState(ch)
        @test rt.channel_states[1].channel.client isa TelegramClient
        @test rt.channel_states[1].channel.client === client
        @test rt.channel_states[1].channel.poll_timeout == 30
    end

    @testset "single TelegramChannel constructor" begin
        ch = TelegramChannel("tok"; base_url = "http://localhost:1")
        rt = RuntimeState(ch)
        s = status(rt)
        @test haskey(s["channels"], "telegram")
    end

    @testset "single DiscordChannel constructor" begin
        ch = DiscordChannel("tok"; api_base = "http://localhost:1")
        rt = RuntimeState(ch)
        s = status(rt)
        @test haskey(s["channels"], "discord")
    end

    @testset "multi-channel constructor" begin
        tg = TelegramChannel("tok1"; base_url = "http://localhost:1")
        dc = DiscordChannel("tok2"; api_base = "http://localhost:2")
        rt = RuntimeState([tg, dc])
        s = status(rt)
        @test haskey(s["channels"], "telegram")
        @test haskey(s["channels"], "discord")
        @test length(s["channels"]) == 2
    end

    @testset "duplicate channel names rejected" begin
        tg1 = TelegramChannel("tok1"; base_url = "http://localhost:1")
        tg2 = TelegramChannel("tok2"; base_url = "http://localhost:2")
        @test_throws ArgumentError RuntimeState([tg1, tg2])
    end

    @testset "empty channels rejected" begin
        @test_throws ArgumentError RuntimeState(AbstractChannel[])
    end

    @testset "register_channel! wires sender" begin
        hub = MessageHubState()
        manager = ChannelManagerState(hub)
        tg = TelegramChannel("tok"; base_url = "http://localhost:1")
        cs = register_channel!(manager, tg)
        @test cs.channel === tg
        @test haskey(manager.senders, :telegram)
    end

    @testset "register_channel! with on_send callback" begin
        called = Ref(false)
        hub = MessageHubState()
        manager = ChannelManagerState(hub)
        tg = TelegramChannel("tok"; base_url = "http://localhost:1")
        cs = register_channel!(manager, tg; on_send = () -> (called[] = true))
        @test cs isa ChannelState
    end

    @testset "status reports polling_alive correctly" begin
        tg = TelegramChannel("tok"; base_url = "http://localhost:1")
        rt = RuntimeState(tg)
        s = status(rt)
        @test s["polling_alive"] == false  # not started yet
    end

    @testset "make_inbound_handler normalizes and publishes" begin
        tg = TelegramChannel("tok"; base_url = "http://localhost:1", allow_from = ["*"])
        hub = MessageHubState()
        dedup = BoundedDedup(100)
        handler = make_inbound_handler(tg, hub; dedup = dedup)

        update = Dict(
            :update_id => 1,
            :message => Dict(
                :text => "test msg",
                :chat => Dict(:id => 42),
                :from => Dict(:id => 7),
            ),
        )
        handler(update)
        msg = Krill.try_take_inbound!(hub)
        @test msg !== nothing
        @test msg.channel === :telegram
        @test Krill.message_text(msg) == "test msg"
    end

    @testset "make_inbound_handler rejects unlisted user" begin
        tg = TelegramChannel("tok"; base_url = "http://localhost:1", allow_from = ["999"])
        hub = MessageHubState()
        handler = make_inbound_handler(tg, hub)

        update = Dict(
            :update_id => 1,
            :message => Dict(
                :text => "should be blocked",
                :chat => Dict(:id => 42),
                :from => Dict(:id => 7),
            ),
        )
        handler(update)
        @test Krill.try_take_inbound!(hub) === nothing
    end

    @testset "make_inbound_handler allows listed user" begin
        tg = TelegramChannel("tok"; base_url = "http://localhost:1", allow_from = ["7"])
        hub = MessageHubState()
        handler = make_inbound_handler(tg, hub)

        update = Dict(
            :update_id => 1,
            :message => Dict(
                :text => "allowed",
                :chat => Dict(:id => 42),
                :from => Dict(:id => 7),
            ),
        )
        handler(update)
        msg = Krill.try_take_inbound!(hub)
        @test msg !== nothing
        @test Krill.message_text(msg) == "allowed"
    end

    @testset "make_inbound_handler deduplicates" begin
        tg = TelegramChannel("tok"; base_url = "http://localhost:1", allow_from = ["*"])
        hub = MessageHubState()
        dedup = BoundedDedup(100)
        handler = make_inbound_handler(tg, hub; dedup = dedup)

        update = Dict(
            :update_id => 42,
            :message => Dict(
                :text => "dup test",
                :chat => Dict(:id => 1),
                :from => Dict(:id => 1),
            ),
        )
        handler(update)
        handler(update)  # duplicate

        msg1 = Krill.try_take_inbound!(hub)
        msg2 = Krill.try_take_inbound!(hub)
        @test msg1 !== nothing
        @test msg2 === nothing  # deduplicated
    end

    @testset "make_inbound_handler calls on_poll" begin
        tg = TelegramChannel("tok"; base_url = "http://localhost:1", allow_from = ["*"])
        hub = MessageHubState()
        poll_count = Ref(0)
        handler = make_inbound_handler(tg, hub; on_poll = () -> (poll_count[] += 1))

        update = Dict(
            :update_id => 1,
            :message => Dict(
                :text => "test",
                :chat => Dict(:id => 1),
                :from => Dict(:id => 1),
            ),
        )
        handler(update)
        @test poll_count[] == 1
    end

    @testset "start! and shutdown! lifecycle" begin
        poll_calls = Ref(0)
        req = (method, url, headers, body) -> begin
            poll_calls[] += 1
            sleep(0.05)
            return make_ok_response([])
        end
        client = TelegramClient("tok"; base_url = "http://test", request = req)
        ch = TelegramChannel(client; poll_timeout = 1, poll_interval = 0.01)
        rt = RuntimeState(ch)

        start!(rt)
        s = status(rt)
        @test s["running"] == true
        sleep(0.2)
        @test poll_calls[] > 0

        shutdown!(rt)
        s2 = status(rt)
        @test s2["running"] == false
        @test s2["polling_alive"] == false
    end
end

println("\n✅ All A.5 channel abstraction tests passed!")
