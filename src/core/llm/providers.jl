"""
    AbstractLLMProvider

Abstract supertype for LLM API providers (OpenAI, Gemini, etc.).
"""
abstract type AbstractLLMProvider end

"""
    OpenAIAPIError <: Exception

Error raised for OpenAI API failures.
`retriable=true` indicates the error is suitable for retry with backoff.
"""
struct OpenAIAPIError <: Exception
    method::String
    description::String
    code::Int
    retriable::Bool
end

function Base.showerror(io::IO, err::OpenAIAPIError)
    retry = err.retriable ? "retriable" : "non-retriable"
    print(io, "OpenAI API error in ", err.method, " (", err.code, ", ", retry, "): ", err.description)
end

"""
    OpenAIProvider(; api_key, base_url, model, request, max_retries, retry_base_seconds)

Minimal OpenAI Responses API provider backed by `HTTP.request`.
"""
struct OpenAIProvider <: AbstractLLMProvider
    api_key::String
    base_url::String
    model::String
    request::Function
    max_retries::Int
    retry_base_seconds::Float64
end

"""
    GeminiProvider(; api_key, base_url, model, request, max_retries, retry_base_seconds)

Native Gemini API provider backed by `HTTP.request` and
`POST /v1beta/models/{model}:generateContent`.

Reference: https://ai.google.dev/api/rest/v1beta/models/generateContent
"""
struct GeminiProvider <: AbstractLLMProvider
    api_key::String
    base_url::String
    model::String
    request::Function
    max_retries::Int
    retry_base_seconds::Float64
end

"""
    GeminiOpenAICompatProvider(; api_key, base_url, model, request, max_retries, retry_base_seconds, extra_body)

Gemini provider using Google's OpenAI-compatible `chat/completions` endpoint.

Reference: https://ai.google.dev/gemini-api/docs/openai
"""
struct GeminiOpenAICompatProvider <: AbstractLLMProvider
    api_key::String
    base_url::String
    model::String
    request::Function
    max_retries::Int
    retry_base_seconds::Float64
    extra_body::Union{Nothing,Dict{String,Any}}
end

function GeminiProvider(;
    api_key::AbstractString=get(ENV, "GEMINI_API_KEY", ""),
    base_url::AbstractString="https://generativelanguage.googleapis.com/v1beta",
    model::AbstractString="gemini-3-flash-preview",
    request::Function=HTTP.request,
    max_retries::Int=3,
    retry_base_seconds::Real=0.5,
)
    isempty(api_key) && throw(ArgumentError("Missing GEMINI_API_KEY (or pass api_key explicitly)"))
    max_retries < 0 && throw(ArgumentError("max_retries must be >= 0"))
    retry_base_seconds < 0 && throw(ArgumentError("retry_base_seconds must be >= 0"))
    return GeminiProvider(
        String(api_key),
        rstrip(String(base_url), '/'),
        String(model),
        request,
        max_retries,
        Float64(retry_base_seconds),
    )
end

function GeminiOpenAICompatProvider(;
    api_key::AbstractString=get(ENV, "GEMINI_API_KEY", ""),
    base_url::AbstractString="https://generativelanguage.googleapis.com/v1beta/openai",
    model::AbstractString="gemini-3-flash-preview",
    request::Function=HTTP.request,
    max_retries::Int=3,
    retry_base_seconds::Real=0.5,
    extra_body::Union{Nothing,Dict{String,Any}}=nothing,
)
    isempty(api_key) && throw(ArgumentError("Missing GEMINI_API_KEY (or pass api_key explicitly)"))
    max_retries < 0 && throw(ArgumentError("max_retries must be >= 0"))
    retry_base_seconds < 0 && throw(ArgumentError("retry_base_seconds must be >= 0"))
    return GeminiOpenAICompatProvider(
        String(api_key),
        rstrip(String(base_url), '/'),
        String(model),
        request,
        max_retries,
        Float64(retry_base_seconds),
        extra_body,
    )
end

function OpenAIProvider(;
    api_key::AbstractString=get(ENV, "OPENAI_API_KEY", ""),
    base_url::AbstractString="https://api.openai.com/v1",
    model::AbstractString="gpt-5.4-mini",
    request::Function=HTTP.request,
    max_retries::Int=3,
    retry_base_seconds::Real=0.5,
)
    isempty(api_key) && throw(ArgumentError("Missing OPENAI_API_KEY (or pass api_key explicitly)"))
    max_retries < 0 && throw(ArgumentError("max_retries must be >= 0"))
    retry_base_seconds < 0 && throw(ArgumentError("retry_base_seconds must be >= 0"))
    return OpenAIProvider(
        String(api_key),
        rstrip(String(base_url), '/'),
        String(model),
        request,
        max_retries,
        Float64(retry_base_seconds),
    )
end

"""
    LLMUsage

Token accounting summary for a response.
"""
struct LLMUsage
    input_tokens::Int
    output_tokens::Int
    total_tokens::Int
    reasoning_tokens::Int
    cached_tokens::Int
end

"""
    LLMToolCall

Normalized function/tool call request returned by providers.
"""
struct LLMToolCall
    id::String
    name::String
    arguments::Dict{String,Any}
end

"""
    LLMResponse

LLM response payload with extracted text plus raw OpenAI response object.
"""
struct LLMResponse
    text::String
    usage::Union{Nothing,LLMUsage}
    raw::Any
    tool_calls::Vector{LLMToolCall}
    response_id::Union{Nothing,String}
end
