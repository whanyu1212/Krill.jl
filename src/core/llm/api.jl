function _is_retriable_status(status::Integer)
    return Int(status) in (429, 500, 503)
end

function _api_headers(provider::OpenAIProvider)
    return [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(provider.api_key)",
    ]
end

function _api_headers(provider::GeminiProvider)
    return [
        "Content-Type" => "application/json",
        "x-goog-api-key" => provider.api_key,
    ]
end

function _api_headers(provider::GeminiOpenAICompatProvider)
    return [
        "Content-Type" => "application/json",
        "Authorization" => "Bearer $(provider.api_key)",
    ]
end

_provider_retries(provider::OpenAIProvider) = provider.max_retries
_provider_retries(provider::GeminiProvider) = provider.max_retries
_provider_retries(provider::GeminiOpenAICompatProvider) = provider.max_retries

_provider_retry_base(provider::OpenAIProvider) = provider.retry_base_seconds
_provider_retry_base(provider::GeminiProvider) = provider.retry_base_seconds
_provider_retry_base(provider::GeminiOpenAICompatProvider) = provider.retry_base_seconds

function _extract_error_description(body::AbstractString, fallback::AbstractString)
    try
        parsed = JSON3.read(body)
        if haskey(parsed, :error)
            err = parsed[:error]
            if haskey(err, :message)
                return String(err[:message])
            end
        elseif haskey(parsed, :message)
            return String(parsed[:message])
        end
    catch _
    end
    return String(fallback)
end

function _post_responses(provider::OpenAIProvider, payload::Dict{String,Any}; retry_config=nothing)
    return _post_json(provider, "/responses", payload; retry_config=retry_config)
end

function _post_generate_content(provider::GeminiProvider, model::AbstractString, payload::Dict{String,Any}; retry_config=nothing)
    model_name = startswith(String(model), "models/") ? String(model)[8:end] : String(model)
    return _post_json(provider, "/models/$(model_name):generateContent", payload; retry_config=retry_config)
end

function _post_chat_completions(provider::GeminiOpenAICompatProvider, payload::Dict{String,Any}; retry_config=nothing)
    return _post_json(provider, "/chat/completions", payload; retry_config=retry_config)
end

function _post_json(provider::AbstractLLMProvider, path::AbstractString, payload::Dict{String,Any}; retry_config=nothing)
    method = "POST $(path)"
    base_url = getproperty(provider, :base_url)
    url = "$(base_url)$(path)"
    headers = _api_headers(provider)
    body = JSON3.write(payload)

    # Use RetryConfig when provided; fall back to provider-level settings otherwise.
    attempts = if retry_config !== nothing
        retry_config.max_retries + 1
    else
        _provider_retries(provider) + 1
    end
    last_error = nothing

    for attempt in 1:attempts
        response = try
            provider.request("POST", url, headers, body)
        catch e
            if attempt < attempts
                _retry_sleep(attempt, retry_config, provider)
                continue
            end
            throw(e)
        end

        if response.status >= 200 && response.status < 300
            attempt > 1 && @info "LLM call succeeded after retry" path=path attempt=attempt
            return String(response.body)
        end

        retriable = if retry_config !== nothing
            Int(response.status) in retry_config.retriable_status_codes
        else
            _is_retriable_status(response.status)
        end
        err = OpenAIAPIError(
            method,
            _extract_error_description(String(response.body), "HTTP status $(response.status)"),
            Int(response.status),
            retriable,
        )
        last_error = err

        if retriable && attempt < attempts
            @warn "LLM call failed, retrying" path=path attempt=attempt status=err.status message=err.message
            _retry_sleep(attempt, retry_config, provider)
            continue
        end

        @error "LLM call failed" path=path status=err.status message=err.message
        throw(err)
    end

    last_error === nothing || throw(last_error)
    error("unreachable")
end

# Compute and apply sleep duration for a retry attempt.
# Uses RetryConfig when provided (with optional jitter), otherwise falls back to
# the provider's retry_base_seconds with plain exponential backoff.
function _retry_sleep(attempt::Int, retry_config, provider)
    if retry_config !== nothing
        raw = retry_config.base_delay_s * retry_config.multiplier^(attempt - 1)
        factor = retry_config.jitter ? (0.75 + rand() * 0.25) : 1.0
        sleep(clamp(raw * factor, 0.0, retry_config.max_delay_s))
    else
        sleep(_provider_retry_base(provider) * 2.0^(attempt - 1))
    end
end
