function _maybe_add!(payload::Dict{String,Any}, key::String, value)
    value === nothing && return
    payload[key] = value
end

function _reasoning_effort_from(reasoning)
    reasoning === nothing && return nothing
    if reasoning isa Dict
        if haskey(reasoning, "effort")
            return String(reasoning["effort"])
        elseif haskey(reasoning, :effort)
            return String(reasoning[:effort])
        end
    end
    return nothing
end

"""
    chat_completion(provider, input; kwargs...) -> LLMResponse

Call OpenAI's `POST /v1/responses` endpoint.
`input` should be either a string or a Responses API input message array.

Reference: https://platform.openai.com/docs/api-reference/responses
"""
function chat_completion(
    provider::OpenAIProvider,
    input;
    model::Union{Nothing,AbstractString}=nothing,
    instructions::Union{Nothing,AbstractString}=nothing,
    reasoning=nothing,
    tools=nothing,
    tool_choice=nothing,
    include=nothing,
    max_output_tokens::Union{Nothing,Integer}=nothing,
    temperature::Union{Nothing,Real}=nothing,
    top_p::Union{Nothing,Real}=nothing,
    stream::Bool=false,
    parallel_tool_calls::Union{Nothing,Bool}=nothing,
    metadata::Union{Nothing,Dict{String,Any}}=nothing,
    previous_response_id::Union{Nothing,AbstractString}=nothing,
    retry_config=nothing,
)
    payload = Dict{String,Any}(
        "model" => isnothing(model) ? provider.model : String(model),
        "input" => input,
    )

    _maybe_add!(payload, "instructions", instructions === nothing ? nothing : String(instructions))
    _maybe_add!(payload, "reasoning", reasoning)
    _maybe_add!(payload, "tools", _tools_with_openai_defaults(tools))
    _maybe_add!(payload, "tool_choice", tool_choice)
    _maybe_add!(payload, "include", include)
    _maybe_add!(payload, "max_output_tokens", max_output_tokens === nothing ? nothing : Int(max_output_tokens))
    _maybe_add!(payload, "temperature", temperature === nothing ? nothing : Float64(temperature))
    _maybe_add!(payload, "top_p", top_p === nothing ? nothing : Float64(top_p))
    _maybe_add!(payload, "parallel_tool_calls", parallel_tool_calls)
    _maybe_add!(payload, "metadata", metadata)
    _maybe_add!(
        payload,
        "previous_response_id",
        previous_response_id === nothing ? nothing : String(previous_response_id),
    )
    if stream
        payload["stream"] = true
    end

    body = _post_responses(provider, payload; retry_config=retry_config)
    parsed = try
        JSON3.read(body)
    catch e
        throw(OpenAIAPIError("POST /responses", "Invalid JSON response: $(sprint(showerror, e))", 0, false))
    end

    text = _extract_output_text(parsed)
    usage = _extract_usage(parsed)
    tool_calls = _extract_responses_tool_calls(parsed)
    response_id = haskey(parsed, :id) ? String(parsed[:id]) : nothing
    return LLMResponse(text, usage, parsed, tool_calls, response_id)
end

function chat_completion(
    provider::GeminiProvider,
    input;
    model::Union{Nothing,AbstractString}=nothing,
    instructions::Union{Nothing,AbstractString}=nothing,
    reasoning=nothing,
    tools=nothing,
    tool_choice=nothing,
    include=nothing,
    max_output_tokens::Union{Nothing,Integer}=nothing,
    temperature::Union{Nothing,Real}=nothing,
    top_p::Union{Nothing,Real}=nothing,
    stream::Bool=false,
    parallel_tool_calls::Union{Nothing,Bool}=nothing,
    metadata::Union{Nothing,Dict{String,Any}}=nothing,
    previous_response_id::Union{Nothing,AbstractString}=nothing,
    retry_config=nothing,
)
    include === nothing || @debug "Gemini native API ignores `include` field"
    parallel_tool_calls === nothing || @debug "Gemini native API ignores `parallel_tool_calls` field"
    metadata === nothing || @debug "Gemini native API ignores `metadata` field"
    previous_response_id === nothing || @debug "Gemini native API ignores `previous_response_id` field"
    stream && @debug "Gemini native API streaming not yet wired; using non-streaming generateContent"

    effective_model = isnothing(model) ? provider.model : String(model)
    contents = if input isa AbstractString
        Any[
            Dict{String,Any}(
                "role" => "user",
                "parts" => Any[Dict{String,Any}("text" => String(input))],
            ),
        ]
    else
        _responses_messages_to_gemini_contents(Vector{Any}(input))
    end

    payload = Dict{String,Any}(
        "contents" => contents,
    )

    if instructions !== nothing && !isempty(strip(String(instructions)))
        payload["systemInstruction"] = Dict{String,Any}(
            "parts" => Any[Dict{String,Any}("text" => String(instructions))],
        )
    end

    gemini_tools = _tools_openai_to_gemini(tools)
    _maybe_add!(payload, "tools", gemini_tools)
    _maybe_add!(payload, "toolConfig", _tool_config_for_gemini(tool_choice))

    # Gemini requires include_server_side_tool_invocations when mixing built-in
    # tools (googleSearch, codeExecution, urlContext, etc.) with function calling.
    if _has_mixed_gemini_tools(gemini_tools)
        tc = get!(Dict{String,Any}, payload, "toolConfig")
        tc["includeServerSideToolInvocations"] = true
    end

    thinking_config = _ensure_gemini_thought_signatures(
        _thinking_config_for_gemini(reasoning),
        tools,
    )
    _maybe_add!(payload, "generationConfig", _gemini_generation_config(
        max_output_tokens=max_output_tokens,
        temperature=temperature,
        top_p=top_p,
        thinking_config=thinking_config,
    ))

    body = _post_generate_content(provider, effective_model, payload; retry_config=retry_config)
    parsed = try
        JSON3.read(body)
    catch e
        throw(OpenAIAPIError("POST /models/$(effective_model):generateContent", "Invalid JSON response: $(sprint(showerror, e))", 0, false))
    end

    text = _extract_gemini_output_text(parsed)
    usage = _extract_gemini_usage(parsed)
    tool_calls = _extract_gemini_tool_calls(parsed)
    response_id = haskey(parsed, :responseId) ? String(parsed[:responseId]) :
        (haskey(parsed, :id) ? String(parsed[:id]) : nothing)
    return LLMResponse(text, usage, parsed, tool_calls, response_id)
end

function chat_completion(
    provider::GeminiOpenAICompatProvider,
    input;
    model::Union{Nothing,AbstractString}=nothing,
    instructions::Union{Nothing,AbstractString}=nothing,
    reasoning=nothing,
    tools=nothing,
    tool_choice=nothing,
    include=nothing,
    max_output_tokens::Union{Nothing,Integer}=nothing,
    temperature::Union{Nothing,Real}=nothing,
    top_p::Union{Nothing,Real}=nothing,
    stream::Bool=false,
    parallel_tool_calls::Union{Nothing,Bool}=nothing,
    metadata::Union{Nothing,Dict{String,Any}}=nothing,
    previous_response_id::Union{Nothing,AbstractString}=nothing,
    retry_config=nothing,
)
    include === nothing || @debug "Gemini OpenAI compatibility ignores `include` field for chat/completions"
    previous_response_id === nothing || @debug "Gemini OpenAI compatibility ignores `previous_response_id` field"

    messages = if input isa AbstractString
        _responses_messages_to_chat_messages(
            instructions,
            Any[Dict{String,Any}(
                "role" => "user",
                "content" => Any[Dict{String,Any}("type" => "input_text", "text" => String(input))],
            )],
        )
    else
        _responses_messages_to_chat_messages(instructions, Vector{Any}(input))
    end

    payload = Dict{String,Any}(
        "model" => isnothing(model) ? provider.model : String(model),
        "messages" => messages,
    )

    _maybe_add!(payload, "tools", tools)
    _maybe_add!(payload, "tool_choice", tool_choice)
    _maybe_add!(payload, "max_tokens", max_output_tokens === nothing ? nothing : Int(max_output_tokens))
    _maybe_add!(payload, "temperature", temperature === nothing ? nothing : Float64(temperature))
    _maybe_add!(payload, "top_p", top_p === nothing ? nothing : Float64(top_p))
    _maybe_add!(payload, "parallel_tool_calls", parallel_tool_calls)
    _maybe_add!(payload, "metadata", metadata)

    effort = _reasoning_effort_from(reasoning)
    _maybe_add!(payload, "reasoning_effort", effort)
    _maybe_add!(payload, "extra_body", provider.extra_body)
    if stream
        payload["stream"] = true
    end

    body = _post_chat_completions(provider, payload; retry_config=retry_config)
    parsed = try
        JSON3.read(body)
    catch e
        throw(OpenAIAPIError("POST /chat/completions", "Invalid JSON response: $(sprint(showerror, e))", 0, false))
    end

    text = _extract_chat_output_text(parsed)
    usage = _extract_chat_usage(parsed)
    tool_calls = _extract_chat_tool_calls(parsed)
    response_id = haskey(parsed, :id) ? String(parsed[:id]) : nothing
    return LLMResponse(text, usage, parsed, tool_calls, response_id)
end
