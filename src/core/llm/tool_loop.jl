"""
    _safe_call(fn, label, default, args...)

Call a nullable callback safely. Returns `default` if `fn` is nothing or throws.
Logs a warning with `label` on failure.
"""
function _safe_call(fn, label::String, default, args...)
    fn === nothing && return default
    try
        return fn(args...)
    catch e
        @warn "$label failed" exception=(e, catch_backtrace())
        return default
    end
end

function _log_llm_response(provider::AbstractLLMProvider, response::LLMResponse, session_key::String)
    u = response.usage
    if u !== nothing
        @info "LLM call" model=provider.model session_key=session_key input_tokens=u.input_tokens output_tokens=u.output_tokens tool_calls=length(
            response.tool_calls,
        )
    else
        @info "LLM call" model=provider.model session_key=session_key tool_calls=length(response.tool_calls)
    end
end

function _usage_dict(usage::LLMUsage)
    return Dict{String,Any}(
        "input_tokens" => usage.input_tokens,
        "output_tokens" => usage.output_tokens,
        "total_tokens" => usage.total_tokens,
        "reasoning_tokens" => usage.reasoning_tokens,
        "cached_tokens" => usage.cached_tokens,
    )
end

function _stringify_tool_result(value)
    if value isa AbstractString
        return String(value)
    end
    return try
        String(JSON3.write(_to_plain(value)))
    catch _
        string(value)
    end
end

function _truncate_text(text::AbstractString, max_chars::Int)
    max_chars <= 0 && return String(text)
    length(text) <= max_chars && return String(text)
    suffix = "... [truncated]"
    keep = max(0, max_chars - length(suffix))
    return String(first(String(text), keep)) * suffix
end

function _clone_tool_registry(registry::ToolRegistry)
    cloned = ToolRegistry()
    for name in tool_names(registry)
        tool = get_tool(registry, name)
        tool === nothing || register_tool!(cloned, tool; replace = true)
    end
    return cloned
end

function _resolve_tools_and_registry(tools, tool_registry::Union{Nothing,ToolRegistry})
    registry = tool_registry
    if tools === nothing
        return nothing, registry
    elseif tools isa ToolRegistry
        registry = isnothing(registry) ? tools : registry
        return tools_schema(tools), registry
    elseif tools isa AbstractVector
        defs = ToolDef[]
        passthrough = Any[]
        for item in tools
            if item isa ToolDef
                push!(defs, item)
            else
                push!(passthrough, item)
            end
        end

        if !isempty(defs)
            registry = if registry === nothing
                ToolRegistry(defs)
            else
                merged = _clone_tool_registry(registry)
                for def in defs
                    register_tool!(merged, def; replace = true)
                end
                merged
            end
            append!(passthrough, tools_schema(defs))
        end
        return isempty(passthrough) ? nothing : passthrough, registry
    elseif tools isa ToolDef
        registry = if registry === nothing
            ToolRegistry([tools])
        else
            merged = _clone_tool_registry(registry)
            register_tool!(merged, tools; replace = true)
            merged
        end
        return tools_schema([tools]), registry
    end
    return tools, registry
end

function _execute_tool_calls(
    registry::ToolRegistry,
    calls::Vector{LLMToolCall};
    max_tool_output_chars::Int,
    tool_progress::Union{Nothing,Function} = nothing,
    allowed_tools::Union{Nothing,Set{String}} = nothing,
    session_key::String = "",
    tool_cache::Union{Nothing,Dict{UInt64,Tuple{String,Bool}}} = nothing,
    hooks = nothing,  # expected: AgentHooks or nothing
)
    openai_outputs = Any[]
    events = Any[]
    return_direct_text = nothing
    interrupted = false

    for call in calls
        # should_interrupt gate: stop tool loop before dispatching this call
        if hooks !== nothing &&
            _safe_call(hooks.should_interrupt, "should_interrupt hook", false, call.name, call.arguments)
            interrupted = true
            break
        end

        tool = get_tool(registry, call.name)
        per_tool_limit = if tool === nothing
            max_tool_output_chars
        else
            tool.max_output_chars > 0 ? tool.max_output_chars : max_tool_output_chars
        end
        call_id = isempty(call.id) ? ("call_" * call.name) : call.id
        is_error = false
        result_text = ""
        error_envelope = nothing
        duration_ms = nothing  # set by dispatch; nothing for cache hits / permission denied

        # Permission check
        if allowed_tools !== nothing && !(call.name in allowed_tools)
            is_error = true
            error_envelope = ErrorEnvelope(
                "E_PERMISSION_DENIED",
                "Tool \"$(call.name)\" is not allowed in this session",
                false,
                Dict{String,Any}("tool_name" => call.name),
            )
            result_text = "Permission denied: tool \"$(call.name)\" is not allowed"
        else
            # Check tool result cache
            cache_key = tool_cache === nothing ? nothing : hash((call.name, call.arguments))
            cached = cache_key === nothing ? nothing : get(tool_cache, cache_key, nothing)

            if cached !== nothing
                result_text, is_error = cached
                @debug "tool cache hit" tool=call.name
            else
                _safe_call(tool_progress, "tool progress hook", nothing, call.name, call.arguments)

                # on_tool_call hook
                if hooks !== nothing
                    _safe_call(hooks.on_tool_call, "on_tool_call hook", nothing, call.name, call.arguments)
                end

                t0 = time()
                try
                    result = dispatch_tool(registry, call.name, call.arguments)
                    duration_ms = (time() - t0) * 1000.0
                    result_text = _truncate_text(_stringify_tool_result(result), per_tool_limit)
                    if tool !== nothing && tool.return_direct && return_direct_text === nothing
                        return_direct_text = result_text
                    end
                    @info "tool executed" tool=call.name status=:ok duration_ms=round(Int, duration_ms) result_chars=length(
                        result_text,
                    )

                    # on_tool_result hook
                    if hooks !== nothing
                        _safe_call(hooks.on_tool_result, "on_tool_result hook", nothing, call.name, result_text)
                    end
                catch e
                    duration_ms = (time() - t0) * 1000.0
                    is_error = true
                    result_text = _truncate_text(sprint(showerror, e), per_tool_limit)
                    error_code =
                        if occursin("timeout", lowercase(result_text)) || occursin("timed out", lowercase(result_text))
                            "E_TIMEOUT"
                        elseif occursin("not found", lowercase(result_text))
                            "E_NOT_FOUND"
                        else
                            "E_EXECUTION"
                        end
                    error_envelope = ErrorEnvelope(
                        error_code,
                        result_text,
                        error_code == "E_TIMEOUT",
                        Dict{String,Any}("tool_name" => call.name),
                    )
                    @info "tool executed" tool=call.name status=:error error_code=error_code duration_ms=round(
                        Int,
                        duration_ms,
                    )

                    # on_tool_result hook (also fires on errors)
                    if hooks !== nothing
                        _safe_call(hooks.on_tool_result, "on_tool_result hook", nothing, call.name, result_text)
                    end
                end

                # Store in cache
                if cache_key !== nothing
                    tool_cache[cache_key] = (result_text, is_error)
                end
            end
        end

        push!(
            openai_outputs,
            Dict{String,Any}(
                "type" => "function_call_output",
                "call_id" => call_id,
                "output" => result_text,
            ),
        )

        call_event = ToolCallEvent(
            session_key = session_key,
            tool_name = call.name,
            arguments = call.arguments,
        )
        result_event = ToolResultEvent(
            session_key = session_key,
            tool_name = call.name,
            correlation_id = call_event.event_id,
            result = is_error ? nothing : result_text,
            error = error_envelope,
            duration_ms = duration_ms,
        )
        push!(events, (call = call_event, result = result_event))
    end

    return (
        openai_outputs = openai_outputs,
        events = events,
        return_direct_text = return_direct_text,
        interrupted = interrupted,
    )
end

function _tool_event_output(event)::String
    if event isa NamedTuple || (event isa Any && hasproperty(event, :result))
        re = event.result
        if re.error !== nothing
            return re.error.message
        elseif re.result !== nothing
            return string(re.result)
        end
        return ""
    end
    # Legacy dict fallback
    return String(get(event, "output", ""))
end

function _tool_event_is_error(event)::Bool
    if event isa NamedTuple || (event isa Any && hasproperty(event, :result))
        return event.result.error !== nothing
    end
    return Bool(get(event, "is_error", false))
end

function _tool_event_name(event)::String
    if event isa NamedTuple || (event isa Any && hasproperty(event, :call))
        return event.call.tool_name
    end
    return String(get(event, "tool_name", "tool"))
end

function _tool_events_to_text(events::Vector{Any})
    lines = String[]
    for event in events
        tool_name = _tool_event_name(event)
        output = _tool_event_output(event)
        is_error = _tool_event_is_error(event)
        label = is_error ? "Tool error" : "Tool result"
        push!(lines, "$(label) [$(tool_name)]: $(output)")
    end
    return join(lines, "\n")
end

function _tool_calls_to_function_call_parts(calls::Vector{LLMToolCall})
    parts = Any[]
    for call in calls
        part = Dict{String,Any}(
            "type" => "function_call",
            "name" => call.name,
            "arguments" => call.arguments,
        )
        isempty(call.id) || (part["id"] = call.id)
        push!(parts, part)
    end
    return parts
end

function _gemini_raw_function_call_parts(raw_response, fallback_calls::Vector{LLMToolCall})
    plain = _to_plain(raw_response)
    plain isa AbstractDict || return _tool_calls_to_function_call_parts(fallback_calls)

    candidates = get(plain, "candidates", Any[])
    candidates isa AbstractVector || return _tool_calls_to_function_call_parts(fallback_calls)

    parts = Any[]
    for raw_candidate in candidates
        candidate = _to_plain(raw_candidate)
        candidate isa AbstractDict || continue
        content = get(candidate, "content", nothing)
        content isa AbstractDict || continue
        raw_parts = get(content, "parts", Any[])
        raw_parts isa AbstractVector || continue
        has_function_call = any(rp -> begin
                p = _to_plain(rp)
                p isa AbstractDict && haskey(p, "functionCall")
            end, raw_parts)
        has_function_call || continue

        for raw_part in raw_parts
            part = _to_plain(raw_part)
            part isa AbstractDict || continue
            function_call = get(part, "functionCall", nothing)
            if function_call isa AbstractDict
                name = String(get(function_call, "name", ""))
                isempty(name) && continue
                args = _parse_tool_arguments(get(function_call, "args", Dict{String,Any}()))
                call_id = get(function_call, "id", get(function_call, "callId", nothing))

                call_part = Dict{String,Any}(
                    "type" => "function_call",
                    "name" => name,
                    "arguments" => args,
                    # Preserve provider-native metadata (e.g. thoughtSignature) for Gemini continuation.
                    "gemini_function_call" =>
                        Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(function_call)),
                )
                call_id === nothing || (call_part["id"] = String(call_id))
                # Capture part-level siblings (e.g. thoughtSignature) required by Gemini
                # for tool-call continuation. These live next to functionCall, not inside it.
                for pk in keys(part)
                    sk = String(pk)
                    sk == "functionCall" && continue
                    call_part["gemini_part_" * sk] = _to_plain(part[pk])
                end
                push!(parts, call_part)
            else
                # Preserve any additional Gemini model parts (e.g. thought parts/signatures)
                # so continuation payloads keep provider-required metadata.
                push!(
                    parts,
                    Dict{String,Any}(
                        "type" => "gemini_raw_part",
                        "gemini_part" => Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(part)),
                    ),
                )
            end
        end

        # Only use the first candidate that contains function calls.
        break
    end

    return isempty(parts) ? _tool_calls_to_function_call_parts(fallback_calls) : parts
end

function _tool_events_to_function_response_parts(events::Vector{Any})
    parts = Any[]
    for event in events
        tool_name = _tool_event_name(event)
        isempty(tool_name) && continue
        output = _tool_event_output(event)
        is_error = _tool_event_is_error(event)

        response_payload = is_error ?
                           Dict{String,Any}("error" => output) :
                           Dict{String,Any}("output" => output)

        part = Dict{String,Any}(
            "type" => "function_response",
            "name" => tool_name,
            "response" => response_payload,
        )
        # Extract call_id from the ToolCallEvent arguments or event structure
        if event isa NamedTuple || (event isa Any && hasproperty(event, :call))
            # ToolCallEvent doesn't carry call_id; use event_id as fallback
        else
            call_id = get(event, "call_id", nothing)
            call_id === nothing || (part["id"] = String(call_id))
        end
        push!(parts, part)
    end
    return parts
end

function _tool_loop_fallback_text(response::LLMResponse, max_tool_iterations::Int)
    text = strip(response.text)
    if isempty(text)
        return "I reached the maximum number of tool-call iterations ($(max_tool_iterations)) without completing the task."
    end
    return response.text
end

function _chat_with_tool_loop(
    provider::AbstractLLMProvider,
    input_messages::Vector{Any};
    instructions::Union{Nothing,AbstractString} = nothing,
    reasoning = nothing,
    tools = nothing,
    tool_choice = nothing,
    include = nothing,
    max_output_tokens::Union{Nothing,Integer} = nothing,
    temperature::Union{Nothing,Real} = nothing,
    top_p::Union{Nothing,Real} = nothing,
    stream::Bool = false,
    parallel_tool_calls::Union{Nothing,Bool} = nothing,
    metadata::Union{Nothing,Dict{String,Any}} = nothing,
    tool_registry::Union{Nothing,ToolRegistry} = nothing,
    tool_progress::Union{Nothing,Function} = nothing,
    stop_check::Union{Nothing,Function} = nothing,
    max_tool_iterations::Int = 10,
    max_tool_output_chars::Int = 8_000,
    allowed_tools::Union{Nothing,Set{String}} = nothing,
    session_key::String = "",
    hooks = nothing,         # expected: AgentHooks or nothing
    retry_config = nothing,  # expected: RetryConfig or nothing
)
    max_tool_iterations <= 0 && throw(ArgumentError("max_tool_iterations must be > 0"))
    max_tool_output_chars < 0 && throw(ArgumentError("max_tool_output_chars must be >= 0"))

    tool_events = Any[]
    response = chat_completion(
        provider,
        input_messages;
        instructions = instructions,
        reasoning = reasoning,
        tools = tools,
        tool_choice = tool_choice,
        include = include,
        max_output_tokens = max_output_tokens,
        temperature = temperature,
        top_p = top_p,
        stream = stream,
        parallel_tool_calls = parallel_tool_calls,
        metadata = metadata,
        retry_config = retry_config,
    )
    _log_llm_response(provider, response, session_key)

    if _safe_call(stop_check, "stop_check callback", false)
        return LLMResponse(
            "Stopped by user request.", response.usage, response.raw,
            LLMToolCall[], response.response_id,
        ), tool_events
    end

    tool_registry === nothing && return response, tool_events
    isempty(response.tool_calls) && return response, tool_events

    # Per-turn tool result cache: avoids re-executing identical tool calls
    tool_cache = Dict{UInt64,Tuple{String,Bool}}()

    # Shared chat_completion kwargs used in continuation calls
    _cc_kwargs = (;
        reasoning = reasoning,
        tools = tools,
        tool_choice = tool_choice,
        include = include,
        max_output_tokens = max_output_tokens,
        temperature = temperature,
        top_p = top_p,
        stream = false,
        parallel_tool_calls = parallel_tool_calls,
        metadata = metadata,
        retry_config = retry_config,
    )

    # Provider-specific state for continuation
    _continuation_messages = provider isa OpenAIProvider ? nothing : Any[input_messages...]
    current = response

    for iteration in 1:max_tool_iterations
        isempty(current.tool_calls) && return current, tool_events

        exec_result = _execute_tool_calls(
            tool_registry,
            current.tool_calls;
            max_tool_output_chars = max_tool_output_chars,
            tool_progress = tool_progress,
            allowed_tools = allowed_tools,
            session_key = session_key,
            tool_cache = tool_cache,
            hooks = hooks,
        )
        append!(tool_events, exec_result.events)

        if exec_result.interrupted
            return current, tool_events
        end

        if exec_result.return_direct_text !== nothing
            return LLMResponse(
                exec_result.return_direct_text, current.usage, current.raw,
                LLMToolCall[], current.response_id,
            ), tool_events
        end

        if _safe_call(stop_check, "stop_check callback", false)
            return LLMResponse(
                "Stopped by user request.", current.usage, current.raw,
                LLMToolCall[], current.response_id,
            ), tool_events
        end

        if iteration >= max_tool_iterations
            return LLMResponse(
                _tool_loop_fallback_text(current, max_tool_iterations),
                current.usage, current.raw, LLMToolCall[], current.response_id,
            ), tool_events
        end

        # OpenAI requires response_id for continuation; bail if missing
        if provider isa OpenAIProvider && current.response_id === nothing
            @warn "provider returned tool calls without response_id; stopping tool loop"
            return current, tool_events
        end

        # Provider-specific continuation strategy
        current = _continue_after_tool_calls(
            provider, current, exec_result, _continuation_messages,
            instructions, _cc_kwargs,
        )
        _log_llm_response(provider, current, session_key)
    end

    return response, tool_events
end

# ─── Provider-specific continuation strategies ───────────────────────

# OpenAI: send function_call_output with previous_response_id
function _continue_after_tool_calls(
    provider::OpenAIProvider, current::LLMResponse, exec_result, _messages,
    instructions, cc_kwargs,
)
    return chat_completion(
        provider, exec_result.openai_outputs;
        instructions = nothing,
        previous_response_id = current.response_id,
        cc_kwargs...,
    )
end

# Gemini native: append functionCall + functionResponse parts to message history
function _continue_after_tool_calls(
    provider::GeminiProvider, current::LLMResponse, exec_result, messages,
    instructions, cc_kwargs,
)
    fc_parts = _gemini_raw_function_call_parts(current.raw, current.tool_calls)
    isempty(fc_parts) || push!(messages, Dict{String,Any}(
        "role" => "assistant",
        "content" => fc_parts,
    ))

    fr_parts = _tool_events_to_function_response_parts(exec_result.events)
    isempty(fr_parts) || push!(messages, Dict{String,Any}(
        "role" => "user",
        "content" => fr_parts,
    ))

    return chat_completion(provider, messages; instructions = instructions, cc_kwargs...)
end

# Fallback (GeminiOpenAICompat and others): append tool results as text
function _continue_after_tool_calls(
    provider::AbstractLLMProvider, current::LLMResponse, exec_result, messages,
    instructions, cc_kwargs,
)
    push!(messages, Dict{String,Any}(
        "role" => "user",
        "content" => Any[Dict{String,Any}(
            "type" => "input_text",
            "text" => _tool_events_to_text(exec_result.events),
        )],
    ))

    return chat_completion(provider, messages; instructions = instructions, cc_kwargs...)
end
