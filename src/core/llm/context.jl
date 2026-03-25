_estimate_tokens(text::AbstractString) = max(1, cld(length(codeunits(text)), 4))

function _estimate_content_tokens(content_items::Vector{Any})
    tokens = 0
    for item in content_items
        if haskey(item, "type") && (item["type"] == "input_text" || item["type"] == "output_text")
            tokens += _estimate_tokens(String(get(item, "text", "")))
        elseif haskey(item, "type") && item["type"] == "input_image"
            tokens += 512
        elseif haskey(item, "type") && item["type"] == "input_file"
            tokens += 1024
        else
            tokens += 32
        end
    end
    return tokens
end

function _turn_to_input_message(turn::TurnRecord)
    role = turn.role === :assistant ? "assistant" : "user"
    # OpenAI Responses requires assistant history text as `output_text`.
    text_part_type = turn.role === :assistant ? "output_text" : "input_text"
    return Dict{String,Any}(
        "role" => role,
        "content" => Any[Dict{String,Any}(
            "type" => text_part_type,
            "text" => turn.text,
        )],
    )
end

function _binary_to_input_item(part::BinaryPart)
    media = lowercase(strip(part.media_type))
    if startswith(media, "image/")
        item = Dict{String,Any}("type" => "input_image", "mime_type" => part.media_type)
        if part.bytes !== nothing
            item["image_url"] = "data:$(part.media_type);base64,$(base64encode(part.bytes))"
            return item
        elseif part.url !== nothing
            item["image_url"] = part.url
            return item
        end
        return nothing
    end

    item = Dict{String,Any}("type" => "input_file", "mime_type" => part.media_type)
    if part.bytes !== nothing
        item["file_data"] = base64encode(part.bytes)
        if part.filename !== nothing
            item["filename"] = part.filename
        end
        return item
    elseif part.url !== nothing
        if startswith(part.url, "file-") || startswith(part.url, "file_")
            item["file_id"] = part.url
        elseif startswith(part.url, "http://") || startswith(part.url, "https://")
            item["file_url"] = part.url
        else
            item["file_id"] = part.url
        end
        return item
    end
    return nothing
end

function _input_content_from_parts(parts::Vector{ContentPart})
    content = Any[]
    for part in parts
        if part isa TextPart
            push!(content, Dict{String,Any}(
                "type" => "input_text",
                "text" => part.text,
            ))
        elseif part isa BinaryPart
            item = _binary_to_input_item(part)
            item === nothing || push!(content, item)
        end
    end
    return content
end

function _resolve_instructions(system_prompt, session_key::AbstractString)
    if system_prompt === nothing
        return nothing
    elseif system_prompt isa Function
        return String(system_prompt(session_key))
    end
    return String(system_prompt)
end

function _append_memory_instructions(
    instructions::Union{Nothing,AbstractString},
    memory_text::Union{Nothing,AbstractString},
)
    memory_text === nothing && return instructions
    clean_memory = strip(String(memory_text))
    isempty(clean_memory) && return instructions

    memory_section = "## Session Memory\n" * clean_memory
    if instructions === nothing
        return memory_section
    end

    base = strip(String(instructions))
    isempty(base) && return memory_section
    return base * "\n\n---\n\n" * memory_section
end

"""
    build_context(system_prompt, history, current_msg; max_context_tokens=8_000, memory_text=nothing, history_summarizer=nothing)

Build a Responses API `input` message array from session history and the current message.
Oldest turns are dropped when the estimated token budget is exceeded; if a
`history_summarizer` is provided, dropped turns are summarized and prepended to instructions.
Returns a named tuple `(instructions, messages)`.
"""
function build_context(
    system_prompt,
    history::Vector{TurnRecord},
    current_msg::InboundMessage;
    max_context_tokens::Int=8_000,
    memory_text::Union{Nothing,AbstractString}=nothing,
    history_summarizer::Union{Nothing,Function}=nothing,
)
    max_context_tokens <= 0 && throw(ArgumentError("max_context_tokens must be > 0"))

    instructions = _resolve_instructions(system_prompt, current_msg.session_key)
    instructions = _append_memory_instructions(instructions, memory_text)

    current_content = _input_content_from_parts(current_msg.content_parts)
    if isempty(current_content)
        current_content = Any[Dict{String,Any}(
            "type" => "input_text",
            "text" => message_text(current_msg),
        )]
    end

    current_message = Dict{String,Any}(
        "role" => "user",
        "content" => current_content,
    )

    used = _estimate_content_tokens(current_content)
    selected = Dict{String,Any}[]
    dropped = TurnRecord[]

    for turn in Iterators.reverse(history)
        msg = _turn_to_input_message(turn)
        turn_tokens = _estimate_content_tokens(msg["content"])
        if used + turn_tokens > max_context_tokens
            push!(dropped, turn)
            continue
        end
        push!(selected, msg)
        used += turn_tokens
    end

    reverse!(selected)
    reverse!(dropped)

    # If turns were dropped and a summarizer is available, summarize them
    # and prepend as a context note in the instructions
    if !isempty(dropped) && history_summarizer !== nothing
        summary = try
            history_summarizer(dropped)
        catch e
            @warn "history summarizer failed; dropped turns lost" count=length(dropped) exception=(e, catch_backtrace())
            nothing
        end
        if summary !== nothing && !isempty(strip(summary))
            summary_block = "\n\n## Earlier Conversation Summary\nThe following is a summary of earlier conversation that no longer fits in the context window:\n\n$(strip(summary))"
            instructions = instructions === nothing ? strip(summary_block) : instructions * summary_block
        end
    end

    push!(selected, current_message)
    return (instructions=instructions, messages=Any[selected...])
end
