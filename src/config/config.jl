module Config

using TOML

using ..Core: AbstractChannel, AbstractLLMProvider, OpenAIProvider, GeminiProvider,
    MCPServer, Agent, AgentHooks,
    MemoryConfig, BuiltinToolsConfig, SkillsConfig,
    ClaudeCodeConfig, CodexConfig, PromptContextConfig, SubagentConfig
using ..Channels.Telegram: TelegramChannel
using ..Channels.Discord: DiscordChannel
using ..RuntimeModule: RuntimeState, start!, shutdown!

include("dotenv.jl")
include("env_expand.jl")
include("provider.jl")
include("mcp_config.jl")
include("channels_config.jl")

export KrillConfig, load_config, start_agent!,
    load_dotenv!, expand_env, expand_env_deep!,
    get_cfg, make_provider, provider_tools, provider_include_fields,
    make_mcp_servers, build_channels

"""
    KrillConfig

Fully-resolved configuration for a Krill agent runtime.
Constructed by [`load_config`](@ref) from a `krill.toml` file.
"""
struct KrillConfig
    provider::AbstractLLMProvider
    channels::Vector{AbstractChannel}
    mcp_servers::Vector{MCPServer}
    system_prompt::String
    workspace::String
    data_dir::String
    tools_cfg::Dict
    llm_tools::Any
    llm_include::Any
    raw::Dict
end

"""
    load_config(; config_path, project_root=dirname(config_path), dotenv_path=nothing) -> KrillConfig

Load a `krill.toml` configuration file, expand environment variables, and
construct all providers and channels. If `dotenv_path` is not specified,
looks for `.env` in `project_root`.
"""
function load_config(;
    config_path::AbstractString,
    project_root::AbstractString = dirname(config_path),
    dotenv_path::Union{AbstractString,Nothing} = nothing,
)
    # Load .env
    envpath = dotenv_path !== nothing ? dotenv_path : joinpath(project_root, ".env")
    load_dotenv!(envpath)

    # Parse and expand config
    isfile(config_path) ||
        error("krill.toml not found at $config_path — copy krill.toml.example and fill in your tokens")
    cfg = expand_env_deep!(TOML.parsefile(config_path))

    # Resolve components
    provider = make_provider(cfg)
    channels = build_channels(cfg)
    mcp_servers = make_mcp_servers(cfg)

    workspace = let w = get_cfg(cfg, "llm", "workspace"; default = "")
        isempty(w) ? joinpath(project_root, "context") : w
    end

    data_dir = let d = get_cfg(cfg, "llm", "data_dir"; default = "")
        isempty(d) ? joinpath(homedir(), ".krill") : d
    end

    system_prompt = get_cfg(cfg, "profile", "system_prompt";
        default = "You are a helpful assistant. Be concise and friendly.")

    tools_cfg = get_cfg(cfg, "profile", "tools"; default = Dict())

    KrillConfig(
        provider,
        channels,
        mcp_servers,
        system_prompt,
        workspace,
        data_dir,
        tools_cfg,
        provider_tools(provider, cfg),
        provider_include_fields(provider),
        cfg,
    )
end

"""
    start_agent!(config::KrillConfig; hooks=nothing)

Construct an `Agent` and `RuntimeState` from the given configuration, start
the runtime, and block until interrupted. Returns the `RuntimeState`.

Pass custom `AgentHooks` via the `hooks` keyword to override the default
observability hooks.
"""
function start_agent!(config::KrillConfig;
    hooks::Union{AgentHooks,Nothing} = nothing,
)
    tc = config.tools_cfg

    if hooks === nothing
        hooks = AgentHooks(
            on_tool_call = (name, args) -> (@info "Tool called" tool=name),
            on_tool_result = (name, res) -> (@info "Tool result" tool=name chars=length(res)),
        )
    end

    agent = Agent(config.provider;
        system_prompt = config.system_prompt,
        workspace = config.workspace,
        data_dir = config.data_dir,
        # Provider-side tools
        llm_tools = config.llm_tools,
        llm_include = config.llm_include,
        # Grouped configs
        memory = MemoryConfig(
            enable = get(tc, "memory", true),
            enable_consolidation = get(tc, "memory_consolidation", true),
        ),
        builtin_tools = BuiltinToolsConfig(
            enable = get(tc, "local_builtins", true),
            restrict_to_workspace = get_cfg(config.raw, "llm", "builtin_restrict_to_workspace"; default = true),
            enable_exec = get(tc, "exec", false),
        ),
        skills = SkillsConfig(
            enable = get(tc, "builtin_skills", true),
        ),
        claude_code = ClaudeCodeConfig(
            enable = get(tc, "claude_code", false),
            model = get(tc, "claude_code_model", "sonnet"),
        ),
        codex = CodexConfig(
            enable = get(tc, "codex", false),
            model = let m = get(tc, "codex_model", "")
                isempty(m) ? nothing : m
            end,
        ),
        subagents = SubagentConfig(
            enable = get(tc, "subagents", true),
        ),
        # Flat flags
        enable_history_summarization = get(tc, "history_summarization", false),
        enable_cron = get(tc, "cron", true),
        enable_google_workspace = get(tc, "google_workspace", false),
        # Hooks
        hooks = hooks,
        # MCP
        mcp_servers = config.mcp_servers,
    )

    rt = RuntimeState(config.channels, agent)
    start!(rt)

    channel_names = join([string(typeof(ch)) for ch in config.channels], ", ")
    @info "Krill agent running" channels=channel_names

    try
        wait()
    catch e
        e isa InterruptException || rethrow()
    finally
        shutdown!(rt)
    end

    return rt
end

end # module Config
