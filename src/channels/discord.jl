module Discord

using HTTP
using HTTP.WebSockets
using JSON3
using Dates
using UUIDs
using ...Types: InboundMessage, OutboundMessage, TextPart, BinaryPart, ContentPart, message_text
using ...MessageHub: MessageHubState
using ...Dedup: BoundedDedup
using ...ChannelInterface: AbstractChannel, make_inbound_handler
import ...ChannelInterface:
    channel_name, make_sender, normalize,
    start_channel!, stop_channel!, send_typing, send_direct, is_allowed

export DiscordClient,
    DiscordAPIError,
    DiscordChannel,
    discord_send_message,
    discord_trigger_typing

# ---------------------------------------------------------------------------
# Discord REST client
# ---------------------------------------------------------------------------

const DISCORD_API_BASE = "https://discord.com/api/v10"

struct DiscordClient
    token::String
    api_base::String
    request::Function
end

function DiscordClient(
    token::AbstractString;
    api_base::Union{Nothing,AbstractString} = nothing,
    request::Function = HTTP.request,
)
    resolved = api_base === nothing ? DISCORD_API_BASE : String(api_base)
    return DiscordClient(String(token), resolved, request)
end

struct DiscordAPIError <: Exception
    method::String
    description::String
    code::Int
end

function Base.showerror(io::IO, err::DiscordAPIError)
    print(io, "Discord API error in ", err.method, " (", err.code, "): ", err.description)
end

function _api_headers(client::DiscordClient)
    return [
        "Authorization" => "Bot $(client.token)",
        "Content-Type" => "application/json",
        "User-Agent" => "Krill.jl (https://github.com/krill-jl, 0.1)",
    ]
end

function _api_call(
    client::DiscordClient,
    method::AbstractString,
    path::AbstractString;
    payload::Union{Nothing,Dict{String,Any}} = nothing,
)
    url = "$(client.api_base)$(path)"
    headers = _api_headers(client)
    body = payload === nothing ? UInt8[] : Vector{UInt8}(JSON3.write(payload))

    response = client.request(method, url, headers, body)

    if response.status < 200 || response.status >= 300
        description = try
            parsed = JSON3.read(String(response.body))
            msg = get(parsed, :message, "HTTP $(response.status)")
            String(msg)
        catch e
            @debug "Failed to parse Discord error response" exception=e
            "HTTP status $(response.status)"
        end
        throw(DiscordAPIError(path, description, Int(response.status)))
    end

    if response.status == 204 || isempty(response.body)
        return nothing
    end

    return JSON3.read(String(response.body))
end

"""
    discord_send_message(client, channel_id, content; kwargs...) -> Any

Send a text message to a Discord channel.
"""
function discord_send_message(
    client::DiscordClient,
    channel_id::AbstractString,
    content::AbstractString;
)
    payload = Dict{String,Any}("content" => String(content))
    return _api_call(client, "POST", "/channels/$(channel_id)/messages"; payload = payload)
end

"""
    discord_trigger_typing(client, channel_id) -> Nothing

Trigger the typing indicator in a Discord channel.
"""
function discord_trigger_typing(client::DiscordClient, channel_id::AbstractString)
    _api_call(client, "POST", "/channels/$(channel_id)/typing")
    return nothing
end

# ---------------------------------------------------------------------------
# Discord Gateway (WebSocket)
# ---------------------------------------------------------------------------

const GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"

# Gateway opcodes
const OP_DISPATCH = 0
const OP_HEARTBEAT = 1
const OP_IDENTIFY = 2
const OP_RESUME = 6
const OP_RECONNECT = 7
const OP_INVALID_SESSION = 9
const OP_HELLO = 10
const OP_HEARTBEAT_ACK = 11

# Default intents: GUILDS | GUILD_MESSAGES | DIRECT_MESSAGES | MESSAGE_CONTENT
const DEFAULT_INTENTS = (1 << 0) | (1 << 9) | (1 << 12) | (1 << 15)

mutable struct GatewayState
    sequence::Union{Nothing,Int}
    session_id::Union{Nothing,String}
    resume_url::Union{Nothing,String}
    heartbeat_interval_ms::Int
    last_heartbeat_ack::Bool
    bot_user_id::Union{Nothing,String}
end

GatewayState() = GatewayState(nothing, nothing, nothing, 41250, true, nothing)

"""
    run_gateway(client, handler; running, intents, gateway_url)

Connect to the Discord Gateway via WebSocket and dispatch MESSAGE_CREATE events
to `handler(event_data)`. Handles heartbeating, identify, and reconnection.
"""
function run_gateway(
    client::DiscordClient,
    handler::Function;
    running::Ref{Bool} = Ref(true),
    intents::Int = DEFAULT_INTENTS,
    gateway_url::AbstractString = GATEWAY_URL,
    max_reconnects::Int = 10,
)
    state = GatewayState()
    reconnects = 0

    while running[] && reconnects <= max_reconnects
        try
            _gateway_session(client, handler, state; running = running, intents = intents,
                gateway_url = state.resume_url !== nothing ? state.resume_url : gateway_url)
        catch e
            e isa InterruptException && return
            running[] || return
            reconnects += 1
            if reconnects > max_reconnects
                @error "discord gateway exceeded max reconnects" max=max_reconnects
                return
            end
            backoff = min(30.0, 1.0 * 2^(reconnects - 1))
            @warn "discord gateway disconnected, reconnecting" attempt=reconnects backoff_s=backoff exception=(
                e,
                catch_backtrace(),
            )
            _interruptible_sleep(backoff, running)
        end
    end
end

function _interruptible_sleep(seconds::Real, running::Ref{Bool})
    deadline = time() + seconds
    while running[] && time() < deadline
        sleep(min(0.5, deadline - time()))
    end
end

function _gateway_session(
    client::DiscordClient,
    handler::Function,
    state::GatewayState;
    running::Ref{Bool},
    intents::Int,
    gateway_url::AbstractString,
)
    HTTP.WebSockets.open(gateway_url) do ws
        # Read HELLO
        hello_raw = String(HTTP.WebSockets.receive(ws))
        hello = JSON3.read(hello_raw)
        if Int(hello[:op]) != OP_HELLO
            error("expected HELLO (op 10), got op $(hello[:op])")
        end
        state.heartbeat_interval_ms = Int(hello[:d][:heartbeat_interval])

        # Identify or Resume
        if state.session_id !== nothing && state.sequence !== nothing
            resume_payload = Dict{String,Any}(
                "op" => OP_RESUME,
                "d" => Dict{String,Any}(
                    "token" => client.token,
                    "session_id" => state.session_id,
                    "seq" => state.sequence,
                ),
            )
            HTTP.WebSockets.send(ws, JSON3.write(resume_payload))
        else
            identify_payload = Dict{String,Any}(
                "op" => OP_IDENTIFY,
                "d" => Dict{String,Any}(
                    "token" => client.token,
                    "intents" => intents,
                    "properties" => Dict{String,Any}(
                        "os" => "julia",
                        "browser" => "Krill.jl",
                        "device" => "Krill.jl",
                    ),
                ),
            )
            HTTP.WebSockets.send(ws, JSON3.write(identify_payload))
        end

        state.last_heartbeat_ack = true

        # Start heartbeat task
        heartbeat_task = Threads.@spawn _heartbeat_loop(ws, state, running)

        try
            while running[] && !HTTP.WebSockets.isclosed(ws)
                raw = try
                    String(HTTP.WebSockets.receive(ws))
                catch e
                    if e isa HTTP.WebSockets.WebSocketError || e isa EOFError
                        break
                    end
                    rethrow()
                end

                event = JSON3.read(raw)
                op = Int(event[:op])

                # Update sequence
                if haskey(event, :s) && event[:s] !== nothing
                    state.sequence = Int(event[:s])
                end

                if op == OP_DISPATCH
                    t = haskey(event, :t) ? String(event[:t]) : ""

                    if t == "READY"
                        state.session_id = String(event[:d][:session_id])
                        if haskey(event[:d], :resume_gateway_url)
                            state.resume_url = String(event[:d][:resume_gateway_url])
                        end
                        if haskey(event[:d], :user) && haskey(event[:d][:user], :id)
                            state.bot_user_id = string(event[:d][:user][:id])
                        end
                        @info "discord gateway READY" session_id=state.session_id bot_user_id=state.bot_user_id
                    elseif t == "MESSAGE_CREATE"
                        # Skip messages from the bot itself
                        author_id = try
                            string(event[:d][:author][:id])
                        catch e
                            @debug "Failed to extract Discord author ID" exception=e
                            nothing
                        end
                        if author_id !== nothing && author_id == state.bot_user_id
                            continue
                        end
                        try
                            handler(event[:d])
                        catch err
                            msg_id = try
                                string(event[:d][:id])
                            catch _
                                ;
                                "unknown"
                            end
                            @error "discord handler failed" message_id=msg_id error=err
                        end
                    end

                elseif op == OP_HEARTBEAT
                    _send_heartbeat(ws, state)

                elseif op == OP_HEARTBEAT_ACK
                    state.last_heartbeat_ack = true

                elseif op == OP_RECONNECT
                    @info "discord gateway requested reconnect"
                    break

                elseif op == OP_INVALID_SESSION
                    resumable = try
                        Bool(event[:d])
                    catch _
                        ;
                        false
                    end
                    if !resumable
                        state.session_id = nothing
                        state.sequence = nothing
                    end
                    @info "discord gateway invalid session" resumable=resumable
                    sleep(rand(1.0:0.5:5.0))
                    break
                end
            end
        finally
            running[] || return
            # Stop heartbeat
            # (heartbeat_task will exit when ws closes or running[] becomes false)
        end
    end
end

function _send_heartbeat(ws, state::GatewayState)
    payload = Dict{String,Any}("op" => OP_HEARTBEAT, "d" => state.sequence)
    try
        HTTP.WebSockets.send(ws, JSON3.write(payload))
    catch e
        @debug "Discord heartbeat send failed" exception=e
    end
end

function _heartbeat_loop(ws, state::GatewayState, running::Ref{Bool})
    interval_s = state.heartbeat_interval_ms / 1000.0
    # Jitter the first heartbeat
    _interruptible_sleep(interval_s * rand(), running)

    while running[] && !HTTP.WebSockets.isclosed(ws)
        if !state.last_heartbeat_ack
            @warn "discord gateway missed heartbeat ACK, reconnecting"
            try
                HTTP.WebSockets.close(ws)
            catch e
                @debug "Discord WS close failed" exception=e
            end
            return
        end
        state.last_heartbeat_ack = false
        _send_heartbeat(ws, state)
        _interruptible_sleep(interval_s, running)
    end
end

# ---------------------------------------------------------------------------
# Normalizer: Discord MESSAGE_CREATE -> InboundMessage
# ---------------------------------------------------------------------------

"""
    normalize_discord_event(event_data) -> Union{InboundMessage, Nothing}

Convert a Discord MESSAGE_CREATE event payload to an `InboundMessage`.
Returns `nothing` if the event is not a recognizable user message.

Session key format:
- DM: `discord:dm:<channel_id>`
- Guild: `discord:<guild_id>:<channel_id>`
- Thread: `discord:<guild_id>:<parent_channel_id>:thread:<channel_id>`
"""
function normalize_discord_event(event_data)
    # Must have content and author
    haskey(event_data, :content) || return nothing
    haskey(event_data, :author) || return nothing

    # Skip bot messages
    author = event_data[:author]
    is_bot = try
        Bool(get(author, :bot, false))
    catch _
        ;
        false
    end
    is_bot && return nothing

    content = String(event_data[:content])
    channel_id = string(event_data[:channel_id])
    user_id = string(author[:id])
    guild_id =
        haskey(event_data, :guild_id) && event_data[:guild_id] !== nothing ?
        string(event_data[:guild_id]) : nothing

    # Determine session key
    session_key = if guild_id === nothing
        "discord:dm:$(channel_id)"
    else
        # Check if it's a thread
        is_thread = try
            msg_type = Int(get(event_data, :type, 0))
            # Type 0 = default, threads have channel type in channel object
            # For simplicity, check thread metadata
            haskey(event_data, :thread) || (haskey(event_data, :message_reference) && haskey(event_data, :position))
        catch e
            @debug "Failed to detect Discord thread" exception=e
            false
        end
        if is_thread
            "discord:$(guild_id):$(channel_id):thread"
        else
            "discord:$(guild_id):$(channel_id)"
        end
    end

    # Extract attachments as BinaryPart
    media_parts = ContentPart[]
    if haskey(event_data, :attachments) && !isempty(event_data[:attachments])
        for att in event_data[:attachments]
            url = try
                String(att[:url])
            catch _
                ;
                continue
            end
            mime = try
                String(att[:content_type])
            catch _
                ;
                "application/octet-stream"
            end
            filename = try
                String(att[:filename])
            catch _
                ;
                nothing
            end
            push!(media_parts, BinaryPart(mime, url, nothing, filename))
        end
    end

    parts = ContentPart[]
    isempty(content) || push!(parts, TextPart(content))
    append!(parts, media_parts)
    isempty(parts) && return nothing

    return InboundMessage(
        channel = :discord,
        session_key = session_key,
        user_id = user_id,
        chat_id = channel_id,
        content_parts = parts,
        text = content,
        raw = event_data,
        metadata = Dict{String,Any}(
            "guild_id" => something(guild_id, ""),
            "username" => try
                String(author[:username])
            catch _
                ;
                ""
            end,
        ),
    )
end

# ---------------------------------------------------------------------------
# Sender: OutboundMessage -> Discord REST API
# ---------------------------------------------------------------------------

"""
    _markdown_to_discord(text) -> String

Convert standard markdown to Discord-compatible markdown.
Discord supports: **bold**, *italic*, __underline__, ~~strikethrough~~,
`inline code`, ```code blocks```, > blockquotes, - lists, [links](url).
Discord does NOT support: tables, headings (#), horizontal rules (---),
images (![]()), footnotes.
"""
function _markdown_to_discord(text::AbstractString)
    s = String(text)
    s = _convert_md_tables(s)
    s = _convert_md_headings(s)
    s = _convert_md_hrs(s)
    return s
end

"""Convert markdown tables to aligned plain-text inside code blocks."""
function _convert_md_tables(text::AbstractString)
    lines = split(text, '\n')
    result = String[]
    i = 1
    while i <= length(lines)
        line = lines[i]
        # Detect table: current line has |, next line is separator (|---|---|)
        if _is_table_row(line) && i + 1 <= length(lines) && _is_table_separator(lines[i + 1])
            # Collect all table rows
            header = line
            i += 2  # skip separator
            body_rows = String[]
            while i <= length(lines) && _is_table_row(lines[i])
                push!(body_rows, lines[i])
                i += 1
            end
            # Parse and format
            formatted = _format_table_as_text(header, body_rows)
            push!(result, "```")
            push!(result, formatted)
            push!(result, "```")
        else
            push!(result, line)
            i += 1
        end
    end
    return join(result, '\n')
end

function _is_table_row(line::AbstractString)
    s = strip(line)
    return startswith(s, '|') && endswith(s, '|') && count('|', s) >= 2
end

function _is_table_separator(line::AbstractString)
    s = strip(line)
    _is_table_row(s) || return false
    # Must contain mostly dashes between pipes: |---|---|
    inner = replace(s, r"^\||\|$" => "")
    cells = split(inner, '|')
    return all(c -> occursin(r"^\s*:?-+:?\s*$", c), cells)
end

function _format_table_as_text(header::AbstractString, body_rows::Vector{String})
    all_rows = vcat([header], body_rows)
    # Parse cells
    parsed = Vector{Vector{String}}()
    for row in all_rows
        inner = strip(row)
        inner = replace(inner, r"^\||\|$" => "")
        cells = [strip(c) for c in split(inner, '|')]
        push!(parsed, cells)
    end

    # Determine column widths
    ncols = maximum(length(r) for r in parsed)
    widths = zeros(Int, ncols)
    for row in parsed
        for (j, cell) in enumerate(row)
            j <= ncols && (widths[j] = max(widths[j], length(cell)))
        end
    end

    # Format rows
    lines = String[]
    for (i, row) in enumerate(parsed)
        parts = String[]
        for j in 1:ncols
            cell = j <= length(row) ? row[j] : ""
            push!(parts, rpad(cell, widths[j]))
        end
        push!(lines, join(parts, "  "))
        # Add separator after header
        if i == 1
            push!(lines, join([repeat("─", w) for w in widths], "  "))
        end
    end
    return join(lines, '\n')
end

"""Convert markdown headings to Discord bold text (Discord doesn't render #)."""
function _convert_md_headings(text::AbstractString)
    out = replace(text, r"^(#{1,6})\s+(.+)$"m => function (m)
        match_result = match(r"^#{1,6}\s+(.+)$", m)
        match_result === nothing ? m : "**$(match_result.captures[1])**"
    end)
    return out
end

"""Convert horizontal rules to a line of dashes."""
function _convert_md_hrs(text::AbstractString)
    return replace(text, r"^(-{3,}|\*{3,}|_{3,})$"m => "─────────────────────────")
end

function make_discord_sender(client::DiscordClient)
    return function (msg::OutboundMessage)
        text = message_text(msg)
        if msg.format === :telegram_html
            # Strip basic HTML tags for Discord (best-effort)
            text = replace(text, r"<b>(.*?)</b>" => s"**\1**")
            text = replace(text, r"<i>(.*?)</i>" => s"*\1*")
            text = replace(text, r"<code>(.*?)</code>" => s"`\1`")
            text = replace(text, r"<pre><code[^>]*>(.*?)</code></pre>"s => s"```\n\1\n```")
            text = replace(text, r"<a href=\"(.*?)\">(.*?)</a>" => s"[\2](\1)")
            text = replace(text, r"<s>(.*?)</s>" => s"~~\1~~")
            text = replace(text, "&amp;" => "&")
            text = replace(text, "&lt;" => "<")
            text = replace(text, "&gt;" => ">")
        end

        # Convert unsupported markdown (tables, headings, HRs) to Discord-friendly format
        text = _markdown_to_discord(text)

        # Discord has a 2000 char limit per message
        if length(text) > 2000
            # Split into chunks
            chunks = _split_message(text, 2000)
            for chunk in chunks
                discord_send_message(client, msg.chat_id, chunk)
            end
        else
            discord_send_message(client, msg.chat_id, text)
        end
    end
end

function _split_message(text::AbstractString, max_len::Int)
    chunks = String[]
    remaining = String(text)
    while length(remaining) > max_len
        # Try to split at a newline
        split_idx = findlast('\n', @view remaining[1:max_len])
        if split_idx === nothing || split_idx < max_len ÷ 2
            split_idx = max_len
        end
        push!(chunks, remaining[1:split_idx])
        remaining = remaining[(split_idx + 1):end]
    end
    isempty(remaining) || push!(chunks, remaining)
    return chunks
end

# ---------------------------------------------------------------------------
# DiscordChannel <: AbstractChannel
# ---------------------------------------------------------------------------

"""
    DiscordChannel(client::DiscordClient; intents=DEFAULT_INTENTS)
    DiscordChannel(token; kwargs...)

Channel adapter wrapping a `DiscordClient` to implement the `AbstractChannel`
interface. Connects to the Discord Gateway via WebSocket for receiving events
and uses the REST API for sending messages.
"""
struct DiscordChannel <: AbstractChannel
    client::DiscordClient
    intents::Int
    gateway_url::String
    allow_from::Vector{String}
end

function DiscordChannel(
    client::DiscordClient;
    intents::Integer = DEFAULT_INTENTS,
    gateway_url::AbstractString = GATEWAY_URL,
    allow_from::Vector{String} = String[],
)
    return DiscordChannel(client, Int(intents), String(gateway_url), allow_from)
end

function DiscordChannel(
    token::AbstractString;
    api_base::Union{Nothing,AbstractString} = nothing,
    request::Function = HTTP.request,
    intents::Integer = DEFAULT_INTENTS,
    gateway_url::AbstractString = GATEWAY_URL,
    allow_from::Vector{String} = String[],
)
    client = DiscordClient(token; api_base = api_base, request = request)
    return DiscordChannel(client; intents = intents, gateway_url = gateway_url, allow_from = allow_from)
end

channel_name(::DiscordChannel) = :discord

function is_allowed(ch::DiscordChannel, user_id::AbstractString)
    isempty(ch.allow_from) && return false
    "*" in ch.allow_from && return true
    return user_id in ch.allow_from
end

make_sender(ch::DiscordChannel) = make_discord_sender(ch.client)

normalize(::DiscordChannel, raw_event) = normalize_discord_event(raw_event)

function send_typing(ch::DiscordChannel, chat_id)
    discord_trigger_typing(ch.client, string(chat_id))
    return nothing
end

function send_direct(ch::DiscordChannel, chat_id, text::AbstractString; kwargs...)
    return discord_send_message(ch.client, string(chat_id), String(text))
end

function start_channel!(
    ch::DiscordChannel,
    hub::MessageHubState,
    running::Ref{Bool};
    dedup::Union{Nothing,BoundedDedup} = nothing,
    on_message::Union{Nothing,Function} = nothing,
)
    handler = make_inbound_handler(ch, hub; dedup = dedup, on_poll = on_message)
    task = Threads.@spawn begin
        try
            run_gateway(ch.client, handler;
                running = running,
                intents = ch.intents,
                gateway_url = ch.gateway_url,
            )
        catch e
            e isa InterruptException && return
            @error "discord gateway task failed" exception=(e, catch_backtrace())
        end
    end
    return task
end

end
