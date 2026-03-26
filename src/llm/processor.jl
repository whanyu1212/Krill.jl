const _HISTORY_SUMMARY_INSTRUCTIONS = """Summarize the following conversation turns into a concise summary.
Focus on: key topics discussed, decisions made, important facts mentioned, and any unresolved questions.
Keep the summary factual and concise. Output only the summary text, no preamble."""

function _make_history_summarizer(provider::AbstractLLMProvider; max_chars::Int = 2_000)
    return function (dropped_turns::Vector{TurnRecord})
        isempty(dropped_turns) && return nothing

        # Build a compact representation of dropped turns
        lines = String[]
        total_chars = 0
        for turn in dropped_turns
            prefix = turn.role === :assistant ? "Assistant" : "User"
            text = turn.text
            if length(text) > max_chars ÷ length(dropped_turns)
                limit = max(100, max_chars ÷ length(dropped_turns))
                text = text[1:min(limit, length(text))] * "…"
            end
            line = "$(prefix): $(text)"
            total_chars += length(line)
            total_chars > max_chars * 2 && break
            push!(lines, line)
        end

        conversation_text = join(lines, "\n")
        messages = Any[Dict{String,Any}(
            "role" => "user",
            "content" => Any[Dict{String,Any}(
                "type" => "input_text",
                "text" => conversation_text,
            )],
        )]

        response = chat_completion(provider, messages;
            instructions = _HISTORY_SUMMARY_INSTRUCTIONS,
            max_output_tokens = 500,
        )
        return response.text
    end
end

function _invoke_instructions_builder(
    builder::Function,
    msg::InboundMessage,
    base_instructions::Union{Nothing,AbstractString},
    memory_text::Union{Nothing,AbstractString},
)
    if applicable(builder, msg, base_instructions, memory_text)
        return builder(msg, base_instructions, memory_text)
    end
    if applicable(builder, msg, base_instructions)
        return builder(msg, base_instructions)
    end
    return builder(msg, base_instructions, memory_text)
end

"""
    make_llm_processor(provider; kwargs...) -> Function

Create a session processor compatible with `run_session_loop!`.
Supports text/image/file inputs (from `content_parts`) and Responses API tools options.
When `memory_store` is provided, session memory is loaded and appended to
context instructions for each turn.
When `instructions_builder` is provided, it receives
`(msg, base_instructions, memory_text)` and can compose per-turn instructions
(for runtime metadata/bootstrap docs/memory policy).
When `enable_history_summarization` is true, turns that are dropped due to
context window limits are summarized by the LLM and prepended to instructions.
"""
function make_llm_processor(
    provider::AbstractLLMProvider;
    system_prompt::Union{Nothing,AbstractString,Function} = "You are a helpful assistant.",
    instructions_builder::Union{Nothing,Function} = nothing,
    memory_store::Union{Nothing,MemoryStore} = nothing,
    max_context_tokens::Int = 8_000,
    reasoning = nothing,
    tools = nothing,
    tool_registry::Union{Nothing,ToolRegistry} = nothing,
    tool_choice = nothing,
    include = nothing,
    max_output_tokens::Union{Nothing,Integer} = nothing,
    temperature::Union{Nothing,Real} = nothing,
    top_p::Union{Nothing,Real} = nothing,
    stream::Bool = false,
    parallel_tool_calls::Union{Nothing,Bool} = nothing,
    metadata::Union{Nothing,Dict{String,Any}} = nothing,
    max_tool_iterations::Int = 10,
    max_tool_output_chars::Int = 8_000,
    tool_progress::Union{Nothing,Function} = nothing,
    stop_check::Union{Nothing,Function} = nothing,
    allowed_tools::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    enable_history_summarization::Bool = false,
    history_summarization_max_chars::Int = 2_000,
    hooks = nothing,   # expected: AgentHooks or nothing
    retry = nothing,   # expected: RetryConfig or nothing
)
    resolved_tools, resolved_registry = _resolve_tools_and_registry(tools, tool_registry)
    resolved_allowed = allowed_tools === nothing ? nothing : Set{String}(String.(allowed_tools))

    history_summarizer = if enable_history_summarization
        _make_history_summarizer(provider; max_chars = history_summarization_max_chars)
    else
        nothing
    end

    return function (msg::InboundMessage, history::Vector{TurnRecord})
        memory_text = if memory_store === nothing
            nothing
        else
            try
                load_memory(memory_store, msg.session_key)
            catch e
                @warn "failed to load session memory for context build" session_key=msg.session_key exception=(
                    e,
                    catch_backtrace(),
                )
                nothing
            end
        end

        system_prompt_for_turn = system_prompt
        memory_for_context = memory_text
        if instructions_builder !== nothing
            try
                base_instructions = _resolve_instructions(system_prompt, msg.session_key)
                # Prefer the new 3-arg callback shape, but fall back to legacy
                # 2-arg builders for backward compatibility.
                built = _invoke_instructions_builder(instructions_builder, msg, base_instructions, memory_text)
                system_prompt_for_turn = built
                # Memory is already incorporated by the builder path.
                memory_for_context = nothing
            catch e
                @warn "failed to build prompt instructions; falling back to system_prompt" session_key=msg.session_key exception=(
                    e,
                    catch_backtrace(),
                )
                system_prompt_for_turn = system_prompt
                memory_for_context = memory_text
            end
        end

        ctx = build_context(system_prompt_for_turn, history, msg;
            max_context_tokens = max_context_tokens,
            memory_text = memory_for_context,
            history_summarizer = history_summarizer,
        )
        _instructions_chars = ctx.instructions === nothing ? 0 : length(ctx.instructions)
        _n_messages = length(ctx.messages)
        @info "turn prompt" session_key=msg.session_key instructions_chars=_instructions_chars context_messages=_n_messages
        @debug "turn prompt instructions" session_key=msg.session_key instructions=ctx.instructions

        resolved_tool_progress = if tool_progress === nothing
            nothing
        else
            (tool_name, arguments) -> tool_progress(msg, tool_name, arguments)
        end

        response, tool_events = _chat_with_tool_loop(
            provider,
            ctx.messages;
            instructions = ctx.instructions,
            reasoning = reasoning,
            tools = resolved_tools,
            tool_choice = tool_choice,
            include = include,
            max_output_tokens = max_output_tokens,
            temperature = temperature,
            top_p = top_p,
            stream = stream,
            parallel_tool_calls = parallel_tool_calls,
            metadata = metadata,
            tool_registry = resolved_registry,
            tool_progress = resolved_tool_progress,
            stop_check = if stop_check === nothing
                nothing
            else
                () -> stop_check(msg)
            end,
            max_tool_iterations = max_tool_iterations,
            max_tool_output_chars = max_tool_output_chars,
            allowed_tools = resolved_allowed,
            session_key = msg.session_key,
            hooks = hooks,
            retry_config = retry,
        )

        usage = response.usage === nothing ? nothing : _usage_dict(response.usage)
        out_metadata = Dict{String,Any}()
        isempty(tool_events) || (out_metadata["tool_events"] = tool_events)
        return (
            text = response.text,
            format = :markdown,
            usage = usage,
            raw = response.raw,
            metadata = isempty(out_metadata) ? nothing : out_metadata,
        )
    end
end
