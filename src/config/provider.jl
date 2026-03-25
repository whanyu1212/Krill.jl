"""
    get_cfg(cfg::Dict, keys...; default=nothing)

Safely navigate a nested Dict by successive keys, returning `default` if any
key is missing.
"""
function get_cfg(cfg::Dict, keys...; default=nothing)
    v = cfg
    try
        for k in keys
            v = v[k]
        end
        return v
    catch e
        e isa KeyError || rethrow()
        return default
    end
end

"""
    make_provider(cfg::Dict) -> AbstractLLMProvider

Construct an LLM provider from a parsed krill.toml config dict.
Reads `[provider]` section for `name`, `model`, and `api_key`.
"""
function make_provider(cfg::Dict)
    name  = lowercase(get_cfg(cfg, "provider", "name"; default="openai"))
    model = get_cfg(cfg, "provider", "model"; default="")

    if name == "openai"
        key = get_cfg(cfg, "provider", "api_key"; default=get(ENV, "OPENAI_API_KEY", ""))
        isempty(key) && error("No OpenAI API key — set provider.api_key in krill.toml or OPENAI_API_KEY in .env")
        m = isempty(model) ? "gpt-5.4-nano" : model
        @info "Provider: OpenAI" model=m
        return OpenAIProvider(api_key=key, model=m)
    elseif name == "gemini"
        key = get_cfg(cfg, "provider", "api_key"; default=get(ENV, "GEMINI_API_KEY", ""))
        isempty(key) && error("No Gemini API key — set provider.api_key in krill.toml or GEMINI_API_KEY in .env")
        m = isempty(model) ? "gemini-2.5-flash" : model
        @info "Provider: Gemini" model=m
        return GeminiProvider(api_key=key, model=m)
    else
        error("Unknown provider name \"$name\" in krill.toml — expected \"openai\" or \"gemini\"")
    end
end

"""
    provider_tools(provider::AbstractLLMProvider, cfg::Dict)

Return provider-specific built-in tool definitions (web search, code interpreter, etc.)
or `nothing` if provider builtins are disabled.
"""
function provider_tools(provider::AbstractLLMProvider, cfg::Dict)
    get_cfg(cfg, "profile", "tools", "provider_builtins"; default=true) || return nothing
    if provider isa OpenAIProvider
        return Any[
            Dict("type" => "web_search"),
            Dict("type" => "code_interpreter", "container" => Dict("type" => "auto")),
        ]
    elseif provider isa GeminiProvider
        return Any[
            Dict("googleSearch" => Dict{String,Any}()),
            Dict("urlContext"   => Dict{String,Any}()),
            Dict("codeExecution" => Dict{String,Any}()),
        ]
    end
    return nothing
end

"""
    provider_include_fields(provider::AbstractLLMProvider)

Return provider-specific include fields for LLM responses, or `nothing`.
"""
function provider_include_fields(provider::AbstractLLMProvider)
    provider isa OpenAIProvider ? Any["web_search_call.action.sources"] : nothing
end
