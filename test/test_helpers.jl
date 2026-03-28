# Shared test fixtures and mock factories.
# Include this file from test files that need common mocks.

"""Create a mock HTTP request function for Telegram that returns empty updates."""
function make_mock_telegram_request(; on_message = nothing)
    return function (method, url, headers, body)
        if occursin("getUpdates", url)
            updates = on_message === nothing ? Any[] : on_message()
            return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => updates)))
        elseif occursin("sendChatAction", url)
            return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
        elseif occursin("sendMessage", url)
            return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Dict("message_id" => 999))))
        end
        return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
    end
end

"""Create a mock OpenAI request function that captures payloads and returns a canned response."""
function make_mock_openai_request(; captured = nothing, response_text = "ok")
    return function (method, url, headers, body)
        payload = JSON3.read(String(body))
        captured !== nothing && (captured[] = payload)
        return HTTP.Response(
            200,
            JSON3.write(
                Dict(
                    "id" => "resp_mock",
                    "output_text" => response_text,
                    "usage" => Dict("input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12),
                ),
            ),
        )
    end
end

"""Create a mock Telegram update for a text message."""
function make_telegram_update(; text = "hello", update_id = 1000, chat_id = 42, user_id = 42)
    return Dict(
        "update_id" => update_id,
        "message" => Dict(
            "message_id" => 1,
            "text" => text,
            "chat" => Dict("id" => chat_id),
            "from" => Dict("id" => user_id),
        ),
    )
end

"""Create a TelegramClient with a mock request function."""
function make_mock_telegram_client(; kwargs...)
    request_fn = make_mock_telegram_request(; kwargs...)
    return TelegramClient("test-token"; base_url = "https://mock.test/botTOKEN", request = request_fn)
end

"""Create an OpenAIProvider with a mock request function."""
function make_mock_openai_provider(; kwargs...)
    request_fn = make_mock_openai_request(; kwargs...)
    return OpenAIProvider(
        api_key = "test-key",
        base_url = "https://mock.test/v1",
        request = request_fn,
        max_retries = 0,
    )
end
