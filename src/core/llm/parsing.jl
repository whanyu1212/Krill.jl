function _extract_output_text(parsed)
    if haskey(parsed, :output_text) && parsed[:output_text] !== nothing
        return String(parsed[:output_text])
    end

    chunks = String[]
    if haskey(parsed, :output)
        for item in parsed[:output]
            item_type = haskey(item, :type) ? String(item[:type]) : ""
            item_type == "message" || continue
            haskey(item, :content) || continue
            for part in item[:content]
                part_type = haskey(part, :type) ? String(part[:type]) : ""
                part_type == "output_text" || continue
                if haskey(part, :text)
                    push!(chunks, String(part[:text]))
                end
            end
        end
    end
    return join(chunks, "\n")
end

function _extract_usage(parsed)
    haskey(parsed, :usage) || return nothing
    usage = parsed[:usage]

    input_tokens = haskey(usage, :input_tokens) ? Int(usage[:input_tokens]) : 0
    output_tokens = haskey(usage, :output_tokens) ? Int(usage[:output_tokens]) : 0
    total_tokens = haskey(usage, :total_tokens) ? Int(usage[:total_tokens]) : (input_tokens + output_tokens)

    cached_tokens = 0
    if haskey(usage, :input_tokens_details)
        itd = usage[:input_tokens_details]
        cached_tokens = haskey(itd, :cached_tokens) ? Int(itd[:cached_tokens]) : 0
    end

    reasoning_tokens = 0
    if haskey(usage, :output_tokens_details)
        otd = usage[:output_tokens_details]
        reasoning_tokens = haskey(otd, :reasoning_tokens) ? Int(otd[:reasoning_tokens]) : 0
    end

    return LLMUsage(input_tokens, output_tokens, total_tokens, reasoning_tokens, cached_tokens)
end

function _to_plain(value)
    if value isa AbstractDict
        out = Dict{String,Any}()
        for (k, v) in pairs(value)
            out[String(k)] = _to_plain(v)
        end
        return out
    elseif value isa AbstractVector
        return Any[_to_plain(v) for v in value]
    else
        return value
    end
end

function _parse_tool_arguments(value)::Dict{String,Any}
    if value isa AbstractDict
        return Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(value))
    elseif value isa AbstractString
        raw = String(value)
        if isempty(strip(raw))
            return Dict{String,Any}()
        end
        parsed = try
            JSON3.read(raw)
        catch _
            return Dict{String,Any}("raw" => raw)
        end
        if parsed isa AbstractDict
            return Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(parsed))
        end
        return Dict{String,Any}("value" => _to_plain(parsed))
    elseif value === nothing
        return Dict{String,Any}()
    else
        return Dict{String,Any}("value" => _to_plain(value))
    end
end

function _extract_responses_tool_calls(parsed)
    calls = LLMToolCall[]
    haskey(parsed, :output) || return calls
    for item in parsed[:output]
        item_type = haskey(item, :type) ? String(item[:type]) : ""
        item_type == "function_call" || continue
        name = haskey(item, :name) ? String(item[:name]) : ""
        isempty(name) && continue
        call_id = if haskey(item, :call_id)
            String(item[:call_id])
        elseif haskey(item, :id)
            String(item[:id])
        else
            "call_" * string(length(calls) + 1)
        end
        raw_args = haskey(item, :arguments) ? item[:arguments] : Dict{String,Any}()
        push!(calls, LLMToolCall(call_id, name, _parse_tool_arguments(raw_args)))
    end
    return calls
end

function _extract_chat_output_text(parsed)
    haskey(parsed, :choices) || return ""
    choices = parsed[:choices]
    isempty(choices) && return ""
    choice = choices[1]
    haskey(choice, :message) || return ""
    msg = choice[:message]
    haskey(msg, :content) || return ""
    content = msg[:content]

    if content isa AbstractString
        return String(content)
    end

    chunks = String[]
    for part in content
        if part isa AbstractString
            push!(chunks, String(part))
        elseif haskey(part, :text)
            push!(chunks, String(part[:text]))
        elseif haskey(part, :content)
            push!(chunks, String(part[:content]))
        end
    end
    return join(chunks, "\n")
end

function _extract_chat_usage(parsed)
    haskey(parsed, :usage) || return nothing
    usage = parsed[:usage]

    input_tokens =
        haskey(usage, :prompt_tokens) ? Int(usage[:prompt_tokens]) :
        (haskey(usage, :input_tokens) ? Int(usage[:input_tokens]) : 0)
    output_tokens =
        haskey(usage, :completion_tokens) ? Int(usage[:completion_tokens]) :
        (haskey(usage, :output_tokens) ? Int(usage[:output_tokens]) : 0)
    total_tokens = haskey(usage, :total_tokens) ? Int(usage[:total_tokens]) : (input_tokens + output_tokens)

    cached_tokens = 0
    if haskey(usage, :prompt_tokens_details)
        ptd = usage[:prompt_tokens_details]
        cached_tokens = haskey(ptd, :cached_tokens) ? Int(ptd[:cached_tokens]) : 0
    elseif haskey(usage, :input_tokens_details)
        itd = usage[:input_tokens_details]
        cached_tokens = haskey(itd, :cached_tokens) ? Int(itd[:cached_tokens]) : 0
    end

    reasoning_tokens = 0
    if haskey(usage, :completion_tokens_details)
        ctd = usage[:completion_tokens_details]
        reasoning_tokens = haskey(ctd, :reasoning_tokens) ? Int(ctd[:reasoning_tokens]) : 0
    elseif haskey(usage, :output_tokens_details)
        otd = usage[:output_tokens_details]
        reasoning_tokens = haskey(otd, :reasoning_tokens) ? Int(otd[:reasoning_tokens]) : 0
    end

    return LLMUsage(input_tokens, output_tokens, total_tokens, reasoning_tokens, cached_tokens)
end

function _extract_chat_tool_calls(parsed)
    calls = LLMToolCall[]
    haskey(parsed, :choices) || return calls
    choices = parsed[:choices]
    isempty(choices) && return calls
    choice = choices[1]
    haskey(choice, :message) || return calls
    msg = choice[:message]
    haskey(msg, :tool_calls) || return calls
    for tc in msg[:tool_calls]
        name = ""
        args = Dict{String,Any}()
        call_id = haskey(tc, :id) ? String(tc[:id]) : "call_" * string(length(calls) + 1)
        if haskey(tc, :function)
            fn = tc[:function]
            name = haskey(fn, :name) ? String(fn[:name]) : ""
            args = haskey(fn, :arguments) ? _parse_tool_arguments(fn[:arguments]) : Dict{String,Any}()
        elseif haskey(tc, :name)
            name = String(tc[:name])
            args = haskey(tc, :arguments) ? _parse_tool_arguments(tc[:arguments]) : Dict{String,Any}()
        end
        isempty(name) && continue
        push!(calls, LLMToolCall(call_id, name, args))
    end
    return calls
end

function _responses_messages_to_chat_messages(
    instructions::Union{Nothing,AbstractString},
    input_messages::Vector{Any},
)
    out = Any[]
    if instructions !== nothing && !isempty(strip(String(instructions)))
        push!(out, Dict{String,Any}("role" => "system", "content" => String(instructions)))
    end

    for msg in input_messages
        role = haskey(msg, "role") ? String(msg["role"]) : "user"
        raw_content = haskey(msg, "content") ? msg["content"] : Any[]
        mapped_content = Any[]

        for part in raw_content
            ptype = haskey(part, "type") ? String(part["type"]) : ""
            if ptype == "input_text" || ptype == "output_text"
                push!(mapped_content, Dict{String,Any}(
                    "type" => "text",
                    "text" => String(get(part, "text", "")),
                ))
            elseif ptype == "input_image"
                image_url = String(get(part, "image_url", ""))
                push!(
                    mapped_content,
                    Dict{String,Any}(
                        "type" => "image_url",
                        "image_url" => Dict{String,Any}("url" => image_url),
                    ),
                )
            elseif ptype == "input_file"
                # Gemini OpenAI-compat chat endpoint has a reduced schema;
                # keep file references as plain text context here.
                if haskey(part, "file_url")
                    push!(
                        mapped_content,
                        Dict{String,Any}(
                            "type" => "text",
                            "text" => "[file_url] " * String(part["file_url"]),
                        ),
                    )
                elseif haskey(part, "file_id")
                    push!(
                        mapped_content,
                        Dict{String,Any}(
                            "type" => "text",
                            "text" => "[file_id] " * String(part["file_id"]),
                        ),
                    )
                elseif haskey(part, "file_data")
                    fname = haskey(part, "filename") ? String(part["filename"]) : "uploaded_file"
                    push!(mapped_content, Dict{String,Any}(
                        "type" => "text",
                        "text" => "[file_data] " * fname,
                    ))
                end
            end
        end

        if isempty(mapped_content)
            push!(mapped_content, Dict{String,Any}("type" => "text", "text" => ""))
        end
        push!(out, Dict{String,Any}("role" => role, "content" => mapped_content))
    end
    return out
end

function _dict_get(obj, key::AbstractString, default = nothing)
    obj isa AbstractDict || return default
    if haskey(obj, key)
        return obj[key]
    end
    skey = Symbol(key)
    if haskey(obj, skey)
        return obj[skey]
    end
    return default
end

function _parse_base64_data_url(url::AbstractString)
    m = match(r"^data:([^;,]+);base64,(.+)$"s, String(url))
    m === nothing && return nothing
    return (mime_type = String(m.captures[1]), data = String(m.captures[2]))
end

function _responses_part_to_gemini_parts(part)
    ptype = String(_dict_get(part, "type", ""))
    out = Any[]

    if ptype == "input_text" || ptype == "output_text"
        push!(out, Dict{String,Any}(
            "text" => String(_dict_get(part, "text", "")),
        ))
        return out
    end

    if ptype == "input_image"
        image_url = String(_dict_get(part, "image_url", ""))
        isempty(image_url) && return out
        parsed = _parse_base64_data_url(image_url)
        if parsed === nothing
            push!(
                out,
                Dict{String,Any}(
                    "fileData" => Dict{String,Any}(
                        "mimeType" => String(_dict_get(part, "mime_type", "image/*")),
                        "fileUri" => image_url,
                    ),
                ),
            )
        else
            push!(
                out,
                Dict{String,Any}(
                    "inlineData" => Dict{String,Any}(
                        "mimeType" => parsed.mime_type,
                        "data" => parsed.data,
                    ),
                ),
            )
        end
        return out
    end

    if ptype == "input_file"
        mime_type = String(_dict_get(part, "mime_type", "application/octet-stream"))
        file_data = _dict_get(part, "file_data", nothing)
        if file_data !== nothing
            push!(
                out,
                Dict{String,Any}(
                    "inlineData" => Dict{String,Any}(
                        "mimeType" => mime_type,
                        "data" => String(file_data),
                    ),
                ),
            )
            return out
        end

        file_url = _dict_get(part, "file_url", nothing)
        if file_url !== nothing
            push!(
                out,
                Dict{String,Any}(
                    "fileData" => Dict{String,Any}(
                        "mimeType" => mime_type,
                        "fileUri" => String(file_url),
                    ),
                ),
            )
            return out
        end

        file_id = _dict_get(part, "file_id", nothing)
        if file_id !== nothing
            push!(
                out,
                Dict{String,Any}(
                    "fileData" => Dict{String,Any}(
                        "mimeType" => mime_type,
                        "fileUri" => String(file_id),
                    ),
                ),
            )
            return out
        end
    end

    if ptype == "gemini_raw_part"
        raw = _dict_get(part, "gemini_part", nothing)
        if raw isa AbstractDict
            push!(out, Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(raw)))
        end
        return out
    end

    if ptype == "function_call"
        raw_payload = _dict_get(part, "gemini_function_call", nothing)
        if raw_payload isa AbstractDict
            payload = Dict{String,Any}(String(k) => _to_plain(v) for (k, v) in pairs(raw_payload))
            name = String(get(payload, "name", _dict_get(part, "name", "")))
            isempty(name) && return out
            payload["name"] = name

            if haskey(payload, "args")
                payload["args"] = _to_plain(_parse_tool_arguments(payload["args"]))
            else
                payload["args"] = _to_plain(_parse_tool_arguments(_dict_get(part, "arguments", Dict{String,Any}())))
            end

            call_id = _dict_get(part, "id", _dict_get(part, "call_id", nothing))
            if call_id !== nothing && !haskey(payload, "id") && !haskey(payload, "callId")
                payload["id"] = String(call_id)
            end

            gemini_part = Dict{String,Any}("functionCall" => payload)
            # Re-attach part-level siblings (e.g. thoughtSignature) captured during extraction.
            for (k, v) in pairs(part)
                sk = String(k)
                if startswith(sk, "gemini_part_")
                    gemini_part[sk[(length("gemini_part_") + 1):end]] = v
                end
            end
            push!(out, gemini_part)
            return out
        end

        name = String(_dict_get(part, "name", ""))
        isempty(name) && return out
        args = _dict_get(part, "arguments", Dict{String,Any}())
        call_id = _dict_get(part, "id", _dict_get(part, "call_id", nothing))
        payload = Dict{String,Any}(
            "name" => name,
            "args" => _to_plain(_parse_tool_arguments(args)),
        )
        call_id === nothing || (payload["id"] = String(call_id))
        push!(out, Dict{String,Any}("functionCall" => payload))
        return out
    end

    if ptype == "function_response"
        name = String(_dict_get(part, "name", ""))
        isempty(name) && return out
        response = _dict_get(part, "response", Dict{String,Any}("output" => String(_dict_get(part, "output", ""))))
        call_id = _dict_get(part, "id", _dict_get(part, "call_id", nothing))
        payload = Dict{String,Any}(
            "name" => name,
            "response" => _to_plain(response),
        )
        call_id === nothing || (payload["id"] = String(call_id))
        push!(out, Dict{String,Any}("functionResponse" => payload))
        return out
    end

    return out
end

function _responses_messages_to_gemini_contents(input_messages::Vector{Any})
    contents = Any[]
    for msg in input_messages
        role = haskey(msg, "role") ? String(msg["role"]) : "user"
        gemini_role = role == "assistant" ? "model" : "user"
        raw_content = haskey(msg, "content") ? msg["content"] : Any[]
        parts = Any[]
        for part in raw_content
            append!(parts, _responses_part_to_gemini_parts(part))
        end
        if isempty(parts)
            push!(parts, Dict{String,Any}("text" => ""))
        end
        push!(contents, Dict{String,Any}(
            "role" => gemini_role,
            "parts" => parts,
        ))
    end
    return contents
end

function _function_declaration_from_tool(tool)
    name = _dict_get(tool, "name", nothing)
    name === nothing && return nothing

    decl = Dict{String,Any}("name" => String(name))
    description = _dict_get(tool, "description", nothing)
    description === nothing || (decl["description"] = String(description))

    schema = _dict_get(tool, "parameters_json_schema", _dict_get(tool, "parameters", nothing))
    schema === nothing || (decl["parametersJsonSchema"] = schema)
    return decl
end

function _string_list(value)
    value === nothing && return nothing
    if value isa AbstractString
        item = strip(String(value))
        return isempty(item) ? nothing : Any[item]
    elseif value isa AbstractVector
        out = Any[]
        for v in value
            s = strip(String(v))
            isempty(s) || push!(out, s)
        end
        return isempty(out) ? nothing : out
    end
    return nothing
end

function _openai_tool_with_required_defaults(tool)
    tool isa AbstractDict || return tool
    ttype = lowercase(String(_dict_get(tool, "type", "")))
    ttype == "code_interpreter" || return tool
    _dict_get(tool, "container", nothing) !== nothing && return tool

    normalized = Dict{String,Any}()
    for (k, v) in pairs(tool)
        normalized[String(k)] = v
    end
    normalized["container"] = Dict{String,Any}("type" => "auto")
    return normalized
end

function _tools_with_openai_defaults(tools)
    tools === nothing && return nothing
    tools isa AbstractVector || return _openai_tool_with_required_defaults(tools)
    return Any[_openai_tool_with_required_defaults(tool) for tool in tools]
end

function _tools_openai_to_gemini(tools)
    tools === nothing && return nothing

    # OpenAI Responses tools reference:
    # https://developers.openai.com/api/docs/guides/tools
    # https://developers.openai.com/api/docs/guides/tools-web-search
    # https://developers.openai.com/api/docs/guides/tools-file-search
    # https://developers.openai.com/api/docs/guides/tools-code-interpreter
    # https://developers.openai.com/api/docs/guides/image-generation
    #
    # Gemini tools reference:
    # https://ai.google.dev/gemini-api/docs/tools
    # https://ai.google.dev/gemini-api/docs/google-search
    # https://ai.google.dev/gemini-api/docs/code-execution
    # https://ai.google.dev/gemini-api/docs/url-context
    # https://ai.google.dev/gemini-api/docs/file-search
    # https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta
    mapped = Any[]
    function_declarations = Any[]
    for tool in tools
        tool isa AbstractDict || continue
        ttype = lowercase(String(_dict_get(tool, "type", "")))

        if ttype == "function"
            declaration = _function_declaration_from_tool(tool)
            declaration === nothing || push!(function_declarations, declaration)
            continue
        elseif ttype == "web_search" || ttype == "web_search_preview" || ttype == "google_search"
            push!(mapped, Dict{String,Any}("googleSearch" => Dict{String,Any}()))
            continue
        elseif ttype == "file_search"
            file_search = Dict{String,Any}()
            # Gemini expects File Search store names; if callers pass OpenAI-style
            # `vector_store_ids`, we forward values verbatim for cross-provider config.
            store_names = _string_list(
                _dict_get(
                    tool,
                    "file_search_store_names",
                    _dict_get(
                        tool,
                        "fileSearchStoreNames",
                        _dict_get(tool, "vector_store_ids", nothing),
                    ),
                ),
            )
            store_names === nothing || (file_search["fileSearchStoreNames"] = store_names)

            top_k = _dict_get(tool, "top_k", _dict_get(tool, "topK", nothing))
            top_k === nothing || (file_search["topK"] = Int(top_k))

            metadata_filter = _dict_get(tool, "metadata_filter", _dict_get(tool, "metadataFilter", nothing))
            metadata_filter === nothing || (file_search["metadataFilter"] = String(metadata_filter))

            push!(mapped, Dict{String,Any}("fileSearch" => file_search))
            continue
        elseif ttype == "code_interpreter" || ttype == "code_execution"
            push!(mapped, Dict{String,Any}("codeExecution" => Dict{String,Any}()))
            continue
        elseif ttype == "url_context"
            push!(mapped, Dict{String,Any}("urlContext" => Dict{String,Any}()))
            continue
        elseif ttype == "google_maps"
            push!(mapped, Dict{String,Any}("googleMaps" => Dict{String,Any}()))
            continue
        end

        if _dict_get(tool, "functionDeclarations", nothing) !== nothing ||
           _dict_get(tool, "googleSearch", nothing) !== nothing ||
           _dict_get(tool, "fileSearch", nothing) !== nothing ||
           _dict_get(tool, "urlContext", nothing) !== nothing ||
           _dict_get(tool, "codeExecution", nothing) !== nothing ||
           _dict_get(tool, "googleMaps", nothing) !== nothing ||
           _dict_get(tool, "computerUse", nothing) !== nothing ||
           _dict_get(tool, "mcpServers", nothing) !== nothing
            push!(mapped, tool)
        end
    end

    isempty(function_declarations) || push!(mapped, Dict{String,Any}(
        "functionDeclarations" => function_declarations,
    ))

    return isempty(mapped) ? nothing : _sanitize_gemini_tools(mapped)
end

function _sanitize_gemini_tools(tools)
    tools === nothing && return nothing
    tools isa AbstractVector || return tools

    has_google_maps = false
    has_incompatible_with_maps = false
    for tool in tools
        tool isa AbstractDict || continue
        if _dict_get(tool, "googleMaps", nothing) !== nothing
            has_google_maps = true
            continue
        end
        if _dict_get(tool, "googleSearch", nothing) !== nothing ||
           _dict_get(tool, "codeExecution", nothing) !== nothing ||
           _dict_get(tool, "urlContext", nothing) !== nothing ||
           _dict_get(tool, "fileSearch", nothing) !== nothing
            has_incompatible_with_maps = true
        end
    end

    if has_google_maps && has_incompatible_with_maps
        filtered = Any[]
        dropped = 0
        for tool in tools
            if tool isa AbstractDict && _dict_get(tool, "googleMaps", nothing) !== nothing
                dropped += 1
                continue
            end
            push!(filtered, tool)
        end
        @warn "Gemini API tool combinations are limited; dropping `googleMaps` when other Gemini built-ins are present" dropped=dropped
        return isempty(filtered) ? nothing : filtered
    end

    return tools
end

"""Check if a converted Gemini tools array contains both server-side built-ins and function declarations."""
function _has_mixed_gemini_tools(tools)
    tools === nothing && return false
    tools isa AbstractVector || return false
    has_builtin = false
    has_functions = false
    for tool in tools
        tool isa AbstractDict || continue
        if _dict_get(tool, "functionDeclarations", nothing) !== nothing
            has_functions = true
        end
        if _dict_get(tool, "googleSearch", nothing) !== nothing ||
           _dict_get(tool, "codeExecution", nothing) !== nothing ||
           _dict_get(tool, "urlContext", nothing) !== nothing ||
           _dict_get(tool, "fileSearch", nothing) !== nothing ||
           _dict_get(tool, "googleMaps", nothing) !== nothing
            has_builtin = true
        end
        has_builtin && has_functions && return true
    end
    return false
end

function _tool_config_for_gemini(tool_choice)
    tool_choice === nothing && return nothing

    if tool_choice isa AbstractString
        choice = lowercase(strip(String(tool_choice)))
        mode = if choice == "none"
            "NONE"
        elseif choice == "required"
            "ANY"
        elseif choice == "auto"
            "AUTO"
        else
            nothing
        end
        mode === nothing && return nothing
        return Dict{String,Any}(
            "functionCallingConfig" => Dict{String,Any}("mode" => mode),
        )
    end

    tool_choice isa AbstractDict || return nothing
    name = nothing
    fn = _dict_get(tool_choice, "function", nothing)
    if fn isa AbstractDict
        name = _dict_get(fn, "name", nothing)
    end
    name === nothing && (name = _dict_get(tool_choice, "name", nothing))
    name === nothing && return nothing

    return Dict{String,Any}(
        "functionCallingConfig" => Dict{String,Any}(
            "mode" => "ANY",
            "allowedFunctionNames" => Any[String(name)],
        ),
    )
end

function _coerce_bool(value)
    if value isa Bool
        return value
    elseif value isa Integer
        return value != 0
    elseif value isa AbstractString
        norm = lowercase(strip(String(value)))
        if norm in ("1", "true", "yes", "on")
            return true
        elseif norm in ("0", "false", "no", "off")
            return false
        end
    end
    throw(ArgumentError("Cannot coerce value to Bool: $(value)"))
end

function _thinking_config_for_gemini(reasoning)
    reasoning === nothing && return nothing
    config = Dict{String,Any}()

    effort = _reasoning_effort_from(reasoning)
    if effort !== nothing
        budget = if lowercase(effort) in ("minimal", "none")
            0
        elseif lowercase(effort) == "low"
            256
        elseif lowercase(effort) == "medium"
            1024
        elseif lowercase(effort) == "high"
            2048
        elseif lowercase(effort) == "max"
            4096
        else
            nothing
        end
        budget === nothing || (config["thinkingBudget"] = budget)
    end

    if reasoning isa AbstractDict
        include_thoughts = _dict_get(reasoning, "includeThoughts", _dict_get(reasoning, "include_thoughts", nothing))
        include_thoughts !== nothing && (config["includeThoughts"] = _coerce_bool(include_thoughts))

        explicit_budget = _dict_get(reasoning, "thinkingBudget", _dict_get(reasoning, "thinking_budget", nothing))
        explicit_budget === nothing || (config["thinkingBudget"] = Int(explicit_budget))
    end

    return isempty(config) ? nothing : config
end

function _ensure_gemini_thought_signatures(thinking_config, tools)
    tools === nothing && return thinking_config

    has_tools = false
    if tools isa AbstractVector
        has_tools = !isempty(tools)
    else
        has_tools = true
    end
    has_tools || return thinking_config

    if thinking_config === nothing
        return Dict{String,Any}("includeThoughts" => true)
    end

    config = Dict{String,Any}(String(k) => v for (k, v) in pairs(thinking_config))
    haskey(config, "includeThoughts") || (config["includeThoughts"] = true)
    return config
end

function _gemini_generation_config(;
    max_output_tokens::Union{Nothing,Integer} = nothing,
    temperature::Union{Nothing,Real} = nothing,
    top_p::Union{Nothing,Real} = nothing,
    thinking_config = nothing,
)
    generation = Dict{String,Any}()
    max_output_tokens === nothing || (generation["maxOutputTokens"] = Int(max_output_tokens))
    temperature === nothing || (generation["temperature"] = Float64(temperature))
    top_p === nothing || (generation["topP"] = Float64(top_p))
    thinking_config === nothing || (generation["thinkingConfig"] = thinking_config)
    return isempty(generation) ? nothing : generation
end

function _extract_gemini_output_text(parsed)
    haskey(parsed, :candidates) || return ""
    chunks = String[]
    for candidate in parsed[:candidates]
        haskey(candidate, :content) || continue
        content = candidate[:content]
        haskey(content, :parts) || continue
        for part in content[:parts]
            haskey(part, :text) || continue
            # Skip thinking/reasoning parts (marked with thought: true)
            if haskey(part, :thought) && part[:thought] == true
                continue
            end
            push!(chunks, String(part[:text]))
        end
    end
    return join(chunks, "\n")
end

function _extract_gemini_usage(parsed)
    haskey(parsed, :usageMetadata) || return nothing
    usage = parsed[:usageMetadata]

    input_tokens = haskey(usage, :promptTokenCount) ? Int(usage[:promptTokenCount]) : 0
    output_tokens = haskey(usage, :candidatesTokenCount) ? Int(usage[:candidatesTokenCount]) : 0
    total_tokens = haskey(usage, :totalTokenCount) ? Int(usage[:totalTokenCount]) : (input_tokens + output_tokens)
    reasoning_tokens = haskey(usage, :thoughtsTokenCount) ? Int(usage[:thoughtsTokenCount]) : 0
    cached_tokens = haskey(usage, :cachedContentTokenCount) ? Int(usage[:cachedContentTokenCount]) : 0

    return LLMUsage(input_tokens, output_tokens, total_tokens, reasoning_tokens, cached_tokens)
end

function _extract_gemini_tool_calls(parsed)
    calls = LLMToolCall[]
    haskey(parsed, :candidates) || return calls
    for candidate in parsed[:candidates]
        haskey(candidate, :content) || continue
        content = candidate[:content]
        haskey(content, :parts) || continue
        for part in content[:parts]
            haskey(part, :functionCall) || continue
            fc = part[:functionCall]
            name = haskey(fc, :name) ? String(fc[:name]) : ""
            isempty(name) && continue
            call_id =
                haskey(fc, :id) ? String(fc[:id]) :
                (haskey(fc, :callId) ? String(fc[:callId]) : "call_" * string(length(calls) + 1))
            args = haskey(fc, :args) ? _parse_tool_arguments(fc[:args]) : Dict{String,Any}()
            push!(calls, LLMToolCall(call_id, name, args))
        end
    end
    return calls
end

# ─── Provider-dispatched extraction ──────────────────────────────────
# Unified interface: dispatch on provider type to call the correct format-specific extractor.

_extract_text(::OpenAIProvider, parsed) = _extract_output_text(parsed)
_extract_text(::GeminiOpenAICompatProvider, parsed) = _extract_chat_output_text(parsed)
_extract_text(::GeminiProvider, parsed) = _extract_gemini_output_text(parsed)

_extract_response_usage(::OpenAIProvider, parsed) = _extract_usage(parsed)
_extract_response_usage(::GeminiOpenAICompatProvider, parsed) = _extract_chat_usage(parsed)
_extract_response_usage(::GeminiProvider, parsed) = _extract_gemini_usage(parsed)

_extract_tool_calls(::OpenAIProvider, parsed) = _extract_responses_tool_calls(parsed)
_extract_tool_calls(::GeminiOpenAICompatProvider, parsed) = _extract_chat_tool_calls(parsed)
_extract_tool_calls(::GeminiProvider, parsed) = _extract_gemini_tool_calls(parsed)

function _extract_response_id(::OpenAIProvider, parsed)
    haskey(parsed, :id) ? String(parsed[:id]) : nothing
end
function _extract_response_id(::GeminiProvider, parsed)
    haskey(parsed, :responseId) ? String(parsed[:responseId]) :
    (haskey(parsed, :id) ? String(parsed[:id]) : nothing)
end
function _extract_response_id(::GeminiOpenAICompatProvider, parsed)
    haskey(parsed, :id) ? String(parsed[:id]) : nothing
end

"""Parse JSON response body and build an LLMResponse using provider-dispatched extractors."""
function _parse_and_build_response(provider::AbstractLLMProvider, body::AbstractString, endpoint_label::String)
    parsed = try
        JSON3.read(body)
    catch e
        throw(OpenAIAPIError(endpoint_label, "Invalid JSON response: $(sprint(showerror, e))", 0, false))
    end
    return LLMResponse(
        _extract_text(provider, parsed),
        _extract_response_usage(provider, parsed),
        parsed,
        _extract_tool_calls(provider, parsed),
        _extract_response_id(provider, parsed),
    )
end
