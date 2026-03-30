module Telegram

using HTTP
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

export TelegramClient,
    TelegramAPIError,
    TelegramChannel,
    TelegramWebhookChannel,
    get_updates,
    send_message,
    send_chat_action,
    set_webhook,
    delete_webhook,
    run_polling,
    normalize_update,
    make_telegram_sender

"""
    TelegramClient(token; base_url=nothing, request=HTTP.request)

HTTP client for the Telegram Bot API.
`request` is injectable for testing (any function with the same signature as `HTTP.request`).
"""
struct TelegramClient
    token::String
    base_url::String
    request::Function
end

function TelegramClient(
    token::AbstractString;
    base_url::Union{Nothing,AbstractString} = nothing,
    request::Function = HTTP.request,
)
    resolved_base_url = isnothing(base_url) ? "https://api.telegram.org/bot$(token)" : String(base_url)
    return TelegramClient(String(token), resolved_base_url, request)
end

"""
    TelegramAPIError <: Exception

Raised when a Telegram Bot API call fails at either the HTTP or API level.
"""
struct TelegramAPIError <: Exception
    method::String
    description::String
    code::Int
end

function Base.showerror(io::IO, err::TelegramAPIError)
    print(io, "Telegram API error in ", err.method, " (", err.code, "): ", err.description)
end

function _api_call(client::TelegramClient, method::AbstractString; payload::Dict{String,Any} = Dict{String,Any}())
    url = "$(client.base_url)/$(method)"
    headers = ["Content-Type" => "application/json"]
    response = client.request("POST", url, headers, JSON3.write(payload))

    if response.status < 200 || response.status >= 300
        throw(TelegramAPIError(String(method), "HTTP status $(response.status)", Int(response.status)))
    end

    parsed = JSON3.read(String(response.body))
    ok = haskey(parsed, :ok) ? Bool(parsed[:ok]) : false
    if !ok
        description = haskey(parsed, :description) ? String(parsed[:description]) : "Unknown Telegram API failure"
        code = haskey(parsed, :error_code) ? Int(parsed[:error_code]) : Int(response.status)
        throw(TelegramAPIError(String(method), description, code))
    end

    return parsed[:result]
end

"""
    get_updates(client; offset=0, timeout=30, limit=nothing, allowed_updates=nothing)

Long-poll for new updates from the Telegram Bot API.
Returns the raw array of update objects.
"""
function get_updates(
    client::TelegramClient;
    offset::Integer = 0,
    timeout::Integer = 30,
    limit::Union{Nothing,Integer} = nothing,
    allowed_updates::Union{Nothing,Vector{String}} = nothing,
)
    payload = Dict{String,Any}(
        "offset" => Int(offset),
        "timeout" => Int(timeout),
    )
    if !isnothing(limit)
        payload["limit"] = Int(limit)
    end
    if !isnothing(allowed_updates)
        payload["allowed_updates"] = allowed_updates
    end

    return _api_call(client, "getUpdates"; payload = payload)
end

"""
    send_message(client, chat_id, text; parse_mode="HTML", disable_web_page_preview=false)

Send a text message to `chat_id`. Returns the sent message object from Telegram.
"""
function send_message(
    client::TelegramClient,
    chat_id,
    text::AbstractString;
    parse_mode::Union{Nothing,AbstractString} = "HTML",
    disable_web_page_preview::Bool = false,
)
    payload = Dict{String,Any}(
        "chat_id" => chat_id,
        "text" => String(text),
        "disable_web_page_preview" => disable_web_page_preview,
    )

    if !isnothing(parse_mode)
        payload["parse_mode"] = String(parse_mode)
    end

    return _api_call(client, "sendMessage"; payload = payload)
end

"""
    send_chat_action(client, chat_id, action="typing")

Send a chat action (for example `"typing"`) to indicate bot activity.
Returns the API result.
"""
function send_chat_action(
    client::TelegramClient,
    chat_id,
    action::AbstractString = "typing",
)
    payload = Dict{String,Any}(
        "chat_id" => chat_id,
        "action" => String(action),
    )
    return _api_call(client, "sendChatAction"; payload = payload)
end

"""
    set_webhook(client, url; secret_token=nothing, max_connections=nothing, allowed_updates=nothing, drop_pending_updates=false)

Register a webhook URL with Telegram. The bot will receive updates via HTTPS POST
to this URL instead of via `getUpdates` long-polling.

`secret_token` (optional) is sent in the `X-Telegram-Bot-Api-Secret-Token` header
of each webhook request so you can verify authenticity.
"""
function set_webhook(
    client::TelegramClient,
    url::AbstractString;
    secret_token::Union{Nothing,AbstractString} = nothing,
    max_connections::Union{Nothing,Integer} = nothing,
    allowed_updates::Union{Nothing,Vector{String}} = nothing,
    drop_pending_updates::Bool = false,
)
    payload = Dict{String,Any}("url" => String(url))
    secret_token === nothing || (payload["secret_token"] = String(secret_token))
    max_connections === nothing || (payload["max_connections"] = Int(max_connections))
    allowed_updates === nothing || (payload["allowed_updates"] = allowed_updates)
    drop_pending_updates && (payload["drop_pending_updates"] = true)
    return _api_call(client, "setWebhook"; payload = payload)
end

"""
    delete_webhook(client; drop_pending_updates=false)

Remove the current webhook. After this, you can switch back to `getUpdates` polling.
"""
function delete_webhook(client::TelegramClient; drop_pending_updates::Bool = false)
    payload = Dict{String,Any}()
    drop_pending_updates && (payload["drop_pending_updates"] = true)
    return _api_call(client, "deleteWebhook"; payload = payload)
end

function _escape_html(text::AbstractString)
    out = replace(String(text), "&" => "&amp;")
    out = replace(out, "<" => "&lt;")
    out = replace(out, ">" => "&gt;")
    return out
end

function _escape_html_attr(text::AbstractString)
    out = _escape_html(text)
    out = replace(out, "\"" => "&quot;")
    return out
end

function _replace_markdown_code_blocks(text::AbstractString)
    blocks = String[]
    replaced = replace(
        String(text),
        r"(?ms)```([^\n`]*)\n?(.*?)```" =>
            raw_match -> begin
                match_obj = match(r"(?ms)^```([^\n`]*)\n?(.*?)```$", String(raw_match))
                match_obj === nothing && return String(raw_match)

                lang = strip(String(match_obj.captures[1]))
                code = _escape_html(String(match_obj.captures[2]))
                rendered = if isempty(lang)
                    "<pre><code>$(code)</code></pre>"
                else
                    "<pre><code class=\"language-$(_escape_html_attr(lang))\">$(code)</code></pre>"
                end
                push!(blocks, rendered)
                return "\0KRILLCODEBLOCK$(length(blocks))\0"
            end,
    )
    return replaced, blocks
end

function _replace_markdown_inline_code(text::AbstractString)
    snippets = String[]
    replaced = replace(
        String(text),
        r"`([^`\n]+)`" => raw_match -> begin
            match_obj = match(r"^`([^`\n]+)`$", String(raw_match))
            match_obj === nothing && return String(raw_match)

            rendered = "<code>$(_escape_html(String(match_obj.captures[1])))</code>"
            push!(snippets, rendered)
            return "\0KRILLINLINECODE$(length(snippets))\0"
        end,
    )
    return replaced, snippets
end

function _restore_placeholders(text::AbstractString, prefix::String, values::Vector{String})
    out = String(text)
    for (idx, value) in enumerate(values)
        out = replace(out, "\0$(prefix)$(idx)\0" => value)
    end
    return out
end

"""Convert a markdown table (header + separator + rows) into a monospace <pre> block."""
function _replace_markdown_tables(text::AbstractString)
    table_blocks = String[]
    # Match contiguous runs of pipe-delimited lines (header, separator, data rows)
    replaced = replace(
        String(text),
        r"(?m)((?:^[ \t]*\|.+\|[ \t]*$\n?){3,})" =>
            block -> begin
                lines = split(strip(String(block)), '\n')
                # Parse cells from each line
                parsed = Vector{Vector{String}}()
                for line in lines
                    stripped = strip(line)
                    # Skip separator rows (|---|---|)
                    occursin(r"^\|[\s:|\-]+\|$", stripped) && continue
                    cells = [strip(c) for c in split(stripped, '|')]
                    # Remove empty first/last from leading/trailing |
                    !isempty(cells) && isempty(cells[1]) && popfirst!(cells)
                    !isempty(cells) && isempty(cells[end]) && pop!(cells)
                    push!(parsed, cells)
                end
                isempty(parsed) && return String(block)

                # Strip inline markdown markers — <pre> renders as plain text anyway
                _strip_md = s -> replace(s, r"\*\*|__|\*|_|`" => "")
                parsed = [[_strip_md(cell) for cell in row] for row in parsed]

                # Calculate column widths
                ncols = maximum(length.(parsed))
                widths = zeros(Int, ncols)
                for row in parsed
                    for (i, cell) in enumerate(row)
                        i <= ncols && (widths[i] = max(widths[i], length(cell)))
                    end
                end

                # Render aligned text
                out = IOBuffer()
                for (ri, row) in enumerate(parsed)
                    for ci in 1:ncols
                        cell = ci <= length(row) ? row[ci] : ""
                        padded = rpad(cell, widths[ci])
                        ci > 1 && print(out, "  ")
                        print(out, padded)
                    end
                    ri < length(parsed) && println(out)
                end

                rendered = "<pre>$(_escape_html(String(take!(out))))</pre>"
                push!(table_blocks, rendered)
                return "\0KRILLTABLE$(length(table_blocks))\0"
            end,
    )
    return replaced, table_blocks
end

function _markdown_to_telegram_html(text::AbstractString)
    normalized = replace(String(text), "\r\n" => "\n")
    normalized = replace(normalized, '\r' => '\n')

    with_tables, table_blocks = _replace_markdown_tables(normalized)
    with_blocks, code_blocks = _replace_markdown_code_blocks(with_tables)
    with_inline, inline_codes = _replace_markdown_inline_code(with_blocks)

    escaped = _escape_html(with_inline)
    escaped = replace(escaped, r"(?m)^#{1,6}[ \t]+(.+)$" => s"<b>\1</b>")
    escaped = replace(
        escaped,
        r"\[([^\]\n]+)\]\((https?://[^\s)]+)\)" =>
            raw_match -> begin
                match_obj = match(r"^\[([^\]\n]+)\]\((https?://[^\s)]+)\)$", String(raw_match))
                match_obj === nothing && return String(raw_match)
                return "<a href=\"$(String(match_obj.captures[2]))\">$(String(match_obj.captures[1]))</a>"
            end,
    )
    escaped = replace(escaped, r"(?<!\*)\*\*([^*\n]+)\*\*(?!\*)" => s"<b>\1</b>")
    escaped = replace(escaped, r"(?<![_\w])__([^_\n]+)__(?![_\w])" => s"<b>\1</b>")
    escaped = replace(escaped, r"~~([^~\n]+)~~" => s"<s>\1</s>")
    escaped = replace(escaped, r"(?<![*\w])\*([^*\n]+)\*(?![*\w])" => s"<i>\1</i>")
    escaped = replace(escaped, r"(?<![_\w])_([^_\n]+)_(?![_\w])" => s"<i>\1</i>")

    escaped = _restore_placeholders(escaped, "KRILLINLINECODE", inline_codes)
    escaped = _restore_placeholders(escaped, "KRILLCODEBLOCK", code_blocks)
    escaped = _restore_placeholders(escaped, "KRILLTABLE", table_blocks)
    return escaped
end

function _error_code(err)
    for field in (:status, :code)
        if hasproperty(err, field)
            return try
                Int(getproperty(err, field))
            catch _
                nothing
            end
        end
    end
    return nothing
end

"""
    run_polling(client, handler; offset=0, timeout=30, poll_interval=0.1, max_updates=nothing)

Poll for Telegram updates in a loop, calling `handler(update)` for each one.
If `max_updates` is set, stops after that many updates have been processed.

Handler exceptions are logged and do not terminate the polling loop.
"""
function run_polling(
    client::TelegramClient,
    handler::Function;
    offset::Integer = 0,
    timeout::Integer = 30,
    poll_interval::Real = 0.1,
    max_updates::Union{Nothing,Integer} = nothing,
    running::Ref{Bool} = Ref(true),
)
    next_offset = Int(offset)
    processed = 0

    while running[]
        updates = try
            get_updates(client; offset = next_offset, timeout = timeout)
        catch err
            @warn "telegram polling request failed, retrying" exception=(err, catch_backtrace())
            sleep(min(5.0, Float64(poll_interval) + 1.0))
            continue
        end
        running[] || break

        for update in updates
            running[] || break
            try
                handler(update)
            catch err
                @error "polling handler failed" update_id=get(update, :update_id, nothing) error=err
            end
            processed += 1

            if haskey(update, :update_id)
                next_offset = max(next_offset, Int(update[:update_id]) + 1)
            end

            if !isnothing(max_updates) && processed >= max_updates
                return processed
            end
        end

        sleep(poll_interval)
    end
    return processed
end

# ---------------------------------------------------------------------------
# Normalizer: raw Telegram update -> InboundMessage
# ---------------------------------------------------------------------------

"""
    normalize_update(update) -> Union{InboundMessage, Nothing}

Convert a raw Telegram update (dict-like object from `get_updates`) into an
[`InboundMessage`](@ref). Returns `nothing` if the update contains no
recognizable message (e.g. non-message update types).

Session key format: `telegram:<chat_id>` for private chats,
`telegram:<chat_id>:topic:<thread_id>` for topic-enabled groups.
"""
function _extract_media_parts(msg)
    parts = ContentPart[]

    # Photos: array of PhotoSize, take largest (last)
    if haskey(msg, :photo) && !isempty(msg[:photo])
        photo = last(msg[:photo])
        file_id = String(photo[:file_id])
        push!(parts, BinaryPart("image/jpeg", nothing, nothing, file_id))
    end

    # Document
    if haskey(msg, :document)
        doc = msg[:document]
        mime = haskey(doc, :mime_type) ? String(doc[:mime_type]) : "application/octet-stream"
        file_id = String(doc[:file_id])
        filename = haskey(doc, :file_name) ? String(doc[:file_name]) : nothing
        push!(parts, BinaryPart(mime, nothing, nothing, file_id))
    end

    # Voice
    if haskey(msg, :voice)
        voice = msg[:voice]
        mime = haskey(voice, :mime_type) ? String(voice[:mime_type]) : "audio/ogg"
        file_id = String(voice[:file_id])
        push!(parts, BinaryPart(mime, nothing, nothing, file_id))
    end

    # Audio
    if haskey(msg, :audio)
        audio = msg[:audio]
        mime = haskey(audio, :mime_type) ? String(audio[:mime_type]) : "audio/mpeg"
        file_id = String(audio[:file_id])
        push!(parts, BinaryPart(mime, nothing, nothing, file_id))
    end

    # Video
    if haskey(msg, :video)
        video = msg[:video]
        mime = haskey(video, :mime_type) ? String(video[:mime_type]) : "video/mp4"
        file_id = String(video[:file_id])
        push!(parts, BinaryPart(mime, nothing, nothing, file_id))
    end

    # Sticker
    if haskey(msg, :sticker)
        sticker = msg[:sticker]
        file_id = String(sticker[:file_id])
        is_animated = try
            Bool(get(sticker, :is_animated, false))
        catch _
            ;
            false
        end
        mime = is_animated ? "application/x-tgsticker" : "image/webp"
        push!(parts, BinaryPart(mime, nothing, nothing, file_id))
    end

    return parts
end

function normalize_update(update)
    # Handle callback_query (inline keyboard button press)
    if haskey(update, :callback_query)
        cq = update[:callback_query]
        haskey(cq, :from) || return nothing
        haskey(cq, :id) || return nothing
        data = haskey(cq, :data) ? String(cq[:data]) : ""
        user_id = string(cq[:from][:id])
        # Callback queries come from the message's chat
        chat_msg = haskey(cq, :message) ? cq[:message] : nothing
        chat_id = chat_msg !== nothing ? string(chat_msg[:chat][:id]) : user_id
        session_key = "telegram:$(chat_id)"

        return InboundMessage(
            channel = :telegram,
            session_key = session_key,
            user_id = user_id,
            chat_id = chat_id,
            text = data,
            raw = update,
            metadata = Dict{String,Any}(
                "type" => "callback_query",
                "callback_query_id" => String(cq[:id]),
            ),
        )
    end

    # Telegram wraps the actual message under various keys; :message is the most common
    msg = nothing
    for key in (:message, :edited_message, :channel_post, :edited_channel_post)
        if haskey(update, key)
            msg = update[key]
            break
        end
    end
    msg === nothing && return nothing

    text = haskey(msg, :text) ? String(msg[:text]) :
           haskey(msg, :caption) ? String(msg[:caption]) : ""
    chat_id = string(msg[:chat][:id])
    user_id = if haskey(msg, :from)
        string(msg[:from][:id])
    else
        chat_id  # channel posts may not have :from
    end

    session_key = if haskey(msg, :message_thread_id)
        "telegram:$(chat_id):topic:$(msg[:message_thread_id])"
    else
        "telegram:$(chat_id)"
    end

    # Build content parts: text + any media
    media_parts = _extract_media_parts(msg)
    parts = ContentPart[]
    isempty(text) || push!(parts, TextPart(text))
    append!(parts, media_parts)

    if isempty(parts)
        # No text and no media — skip
        return nothing
    end

    return InboundMessage(
        channel = :telegram,
        session_key = session_key,
        user_id = user_id,
        chat_id = chat_id,
        content_parts = parts,
        text = text,
        raw = update,
    )
end

# ---------------------------------------------------------------------------
# Sender factory: OutboundMessage -> Telegram send_message
# ---------------------------------------------------------------------------

"""
    make_telegram_sender(client::TelegramClient) -> Function

Return a sender function suitable for `register_sender!`.
The returned function takes an [`OutboundMessage`](@ref) and sends its text
content to the appropriate chat via the Telegram Bot API.
"""
function make_telegram_sender(client::TelegramClient)
    return function (msg::OutboundMessage)
        raw_text = message_text(msg)
        text = raw_text
        parse_mode = nothing
        if msg.format === :telegram_html
            parse_mode = "HTML"
        elseif msg.format === :markdown
            parse_mode = "HTML"
            text = _markdown_to_telegram_html(raw_text)
        end

        try
            send_message(client, msg.chat_id, text; parse_mode = parse_mode)
        catch err
            code = _error_code(err)
            if parse_mode == "HTML" && code == 400
                @warn "telegram HTML send failed; retrying as plain text" chat_id=msg.chat_id message_id=msg.message_id
                return send_message(client, msg.chat_id, raw_text; parse_mode = nothing)
            end
            rethrow()
        end
    end
end

# ---------------------------------------------------------------------------
# TelegramChannel <: AbstractChannel
# ---------------------------------------------------------------------------

"""
    TelegramChannel(client::TelegramClient; poll_timeout=30, poll_interval=0.1)

Channel adapter wrapping a `TelegramClient` to implement the `AbstractChannel`
interface. Handles polling, normalization, sending, and typing indicators.
"""
struct TelegramChannel <: AbstractChannel
    client::TelegramClient
    poll_timeout::Int
    poll_interval::Float64
    allow_from::Vector{String}
end

function TelegramChannel(
    client::TelegramClient;
    poll_timeout::Integer = 30,
    poll_interval::Real = 0.1,
    allow_from::Vector{String} = String[],
)
    return TelegramChannel(client, Int(poll_timeout), Float64(poll_interval), allow_from)
end

function TelegramChannel(
    token::AbstractString;
    base_url::Union{Nothing,AbstractString} = nothing,
    request::Function = HTTP.request,
    poll_timeout::Integer = 30,
    poll_interval::Real = 0.1,
    allow_from::Vector{String} = String[],
)
    client = TelegramClient(token; base_url = base_url, request = request)
    return TelegramChannel(client; poll_timeout = poll_timeout, poll_interval = poll_interval, allow_from = allow_from)
end

channel_name(::TelegramChannel) = :telegram

function is_allowed(ch::TelegramChannel, user_id::AbstractString)
    isempty(ch.allow_from) && return false
    "*" in ch.allow_from && return true
    return user_id in ch.allow_from
end

make_sender(ch::TelegramChannel) = make_telegram_sender(ch.client)

normalize(::TelegramChannel, raw_event) = normalize_update(raw_event)

function send_typing(ch::TelegramChannel, chat_id)
    send_chat_action(ch.client, chat_id, "typing")
    return nothing
end

function send_direct(ch::TelegramChannel, chat_id, text::AbstractString; kwargs...)
    parse_mode = get(kwargs, :parse_mode, nothing)
    disable_web_page_preview = get(kwargs, :disable_web_page_preview, false)
    return send_message(
        ch.client, chat_id, String(text);
        parse_mode = parse_mode,
        disable_web_page_preview = Bool(disable_web_page_preview),
    )
end

function start_channel!(
    ch::TelegramChannel,
    hub::MessageHubState,
    running::Ref{Bool};
    dedup::Union{Nothing,BoundedDedup} = nothing,
    on_message::Union{Nothing,Function} = nothing,
)
    handler = make_inbound_handler(ch, hub; dedup = dedup, on_poll = on_message)
    task = Threads.@spawn begin
        try
            run_polling(ch.client, handler;
                timeout = ch.poll_timeout,
                poll_interval = ch.poll_interval,
                running = running,
            )
        catch e
            e isa InterruptException && return
            @error "telegram polling task failed" exception=(e, catch_backtrace())
        end
    end
    return task
end

# ---------------------------------------------------------------------------
# TelegramWebhookChannel <: AbstractChannel
# ---------------------------------------------------------------------------

"""
    TelegramWebhookChannel(client; url, host="0.0.0.0", port=8443, path="/webhook",
                           secret_token=nothing, set_webhook_on_start=true,
                           delete_webhook_on_stop=true, drop_pending_updates=false)

Channel adapter that receives Telegram updates via webhook HTTP POST instead of
long-polling. The channel starts an embedded HTTP server on `host:port` and
optionally registers the webhook URL with Telegram on `start_channel!`.

`secret_token` is used for both the `setWebhook` call and for verifying incoming
requests via the `X-Telegram-Bot-Api-Secret-Token` header.

`url` is the publicly-reachable HTTPS URL that Telegram will POST to. It must
include the path component (e.g. `https://example.com/webhook`).
"""
mutable struct TelegramWebhookChannel <: AbstractChannel
    client::TelegramClient
    url::String
    host::String
    port::Int
    path::String
    secret_token::Union{Nothing,String}
    set_webhook_on_start::Bool
    delete_webhook_on_stop::Bool
    drop_pending_updates::Bool
    server::Any  # HTTP.Server or nothing
end

function TelegramWebhookChannel(
    client::TelegramClient;
    url::AbstractString,
    host::AbstractString = "0.0.0.0",
    port::Integer = 8443,
    path::AbstractString = "/webhook",
    secret_token::Union{Nothing,AbstractString} = nothing,
    set_webhook_on_start::Bool = true,
    delete_webhook_on_stop::Bool = true,
    drop_pending_updates::Bool = false,
)
    return TelegramWebhookChannel(
        client,
        String(url),
        String(host),
        Int(port),
        String(path),
        secret_token === nothing ? nothing : String(secret_token),
        set_webhook_on_start,
        delete_webhook_on_stop,
        drop_pending_updates,
        nothing,
    )
end

function TelegramWebhookChannel(
    token::AbstractString;
    base_url::Union{Nothing,AbstractString} = nothing,
    request::Function = HTTP.request,
    kwargs...,
)
    client = TelegramClient(token; base_url = base_url, request = request)
    return TelegramWebhookChannel(client; kwargs...)
end

channel_name(::TelegramWebhookChannel) = :telegram

make_sender(ch::TelegramWebhookChannel) = make_telegram_sender(ch.client)

normalize(::TelegramWebhookChannel, raw_event) = normalize_update(raw_event)

function send_typing(ch::TelegramWebhookChannel, chat_id)
    send_chat_action(ch.client, chat_id, "typing")
    return nothing
end

function send_direct(ch::TelegramWebhookChannel, chat_id, text::AbstractString; kwargs...)
    parse_mode = get(kwargs, :parse_mode, nothing)
    disable_web_page_preview = get(kwargs, :disable_web_page_preview, false)
    return send_message(
        ch.client, chat_id, String(text);
        parse_mode = parse_mode,
        disable_web_page_preview = Bool(disable_web_page_preview),
    )
end

function _make_webhook_router(ch::TelegramWebhookChannel, handler::Function)
    expected_path = ch.path
    secret = ch.secret_token

    return function (req::HTTP.Request)
        # Only accept POST to the configured path
        if req.method != "POST" || HTTP.URI(req.target).path != expected_path
            return HTTP.Response(404, "Not Found")
        end

        # Verify secret token if configured
        if secret !== nothing
            token_header = HTTP.header(req, "X-Telegram-Bot-Api-Secret-Token", "")
            if token_header != secret
                return HTTP.Response(403, "Forbidden")
            end
        end

        # Parse and handle the update
        local update
        try
            update = JSON3.read(String(req.body))
        catch _
            return HTTP.Response(400, "Bad Request")
        end

        try
            handler(update)
        catch e
            @error "webhook handler failed" exception=(e, catch_backtrace())
        end

        # Always return 200 to Telegram so it doesn't retry
        return HTTP.Response(200, "OK")
    end
end

function start_channel!(
    ch::TelegramWebhookChannel,
    hub::MessageHubState,
    running::Ref{Bool};
    dedup::Union{Nothing,BoundedDedup} = nothing,
    on_message::Union{Nothing,Function} = nothing,
)
    handler = make_inbound_handler(ch, hub; dedup = dedup, on_poll = on_message)
    router = _make_webhook_router(ch, handler)

    if ch.set_webhook_on_start
        set_webhook(ch.client, ch.url;
            secret_token = ch.secret_token,
            drop_pending_updates = ch.drop_pending_updates,
        )
        @info "Telegram webhook registered" url=ch.url
    end

    server = HTTP.serve!(router, ch.host, ch.port)
    ch.server = server
    @info "Telegram webhook server listening" host=ch.host port=ch.port path=ch.path

    # Return a task that waits for the running flag to be cleared, then closes the server
    task = Threads.@spawn begin
        try
            while running[]
                sleep(0.5)
            end
        catch e
            e isa InterruptException || @error "webhook watcher failed" exception=(e, catch_backtrace())
        end
    end
    return task
end

function stop_channel!(ch::TelegramWebhookChannel)
    if ch.server !== nothing
        try
            close(ch.server)
        catch e
            @warn "failed to close webhook server" exception=(e, catch_backtrace())
        end
        ch.server = nothing
    end

    if ch.delete_webhook_on_stop
        try
            delete_webhook(ch.client)
            @info "Telegram webhook deleted"
        catch e
            @warn "failed to delete webhook" exception=(e, catch_backtrace())
        end
    end
    return nothing
end

end
