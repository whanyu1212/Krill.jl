module AgentModule

using ..LLM: AbstractLLMProvider
using ..Tools: ToolRegistry
using ..Memory: MemoryStore
using ..MCP: MCPServer, connect
using ..PromptContext: DEFAULT_BOOTSTRAP_DOCS

export RetryConfig, AgentHooks, Agent,
    MemoryConfig, BuiltinToolsConfig, SkillsConfig,
    ClaudeCodeConfig, CodexConfig, PromptContextConfig, SubagentConfig

# ---------------------------------------------------------------------------
# RetryConfig
# ---------------------------------------------------------------------------

"""
Default set of HTTP status codes that are considered transient and safe to retry.
"""
const DEFAULT_RETRIABLE_CODES = Set{Int}([408, 429, 500, 502, 503, 504, 529])

"""
    RetryConfig(; max_retries, base_delay_s, max_delay_s, multiplier, jitter, retriable_status_codes)

Retry policy for LLM API calls. Applies exponential backoff with optional jitter.

| Field | Default | Meaning |
|-------|---------|---------|
| `max_retries` | 3 | Maximum number of retry attempts after the first failure |
| `base_delay_s` | 0.5 | Initial delay in seconds before the first retry |
| `max_delay_s` | 60.0 | Cap on per-attempt sleep duration |
| `multiplier` | 2.0 | Exponential growth factor per attempt |
| `jitter` | true | Randomise sleep by 0.75–1.0× to avoid thundering herd |
| `retriable_status_codes` | `{408,429,500,502,503,504,529}` | HTTP status codes that trigger a retry |

Sleep formula: `clamp(base_delay_s × multiplier^(attempt-1) × jitter_factor, 0, max_delay_s)`
"""
struct RetryConfig
    max_retries::Int
    base_delay_s::Float64
    max_delay_s::Float64
    multiplier::Float64
    jitter::Bool
    retriable_status_codes::Set{Int}
end

function RetryConfig(;
    max_retries::Int=3,
    base_delay_s::Float64=0.5,
    max_delay_s::Float64=60.0,
    multiplier::Float64=2.0,
    jitter::Bool=true,
    retriable_status_codes::Set{Int}=DEFAULT_RETRIABLE_CODES,
)
    max_retries >= 0 || throw(ArgumentError("max_retries must be >= 0"))
    base_delay_s >= 0 || throw(ArgumentError("base_delay_s must be >= 0"))
    max_delay_s >= 0 || throw(ArgumentError("max_delay_s must be >= 0"))
    multiplier >= 1 || throw(ArgumentError("multiplier must be >= 1"))
    return RetryConfig(max_retries, base_delay_s, max_delay_s, multiplier, jitter, retriable_status_codes)
end

# ---------------------------------------------------------------------------
# AgentHooks
# ---------------------------------------------------------------------------

"""
    AgentHooks(; on_turn_start, on_turn_end, on_tool_call, on_tool_result, should_interrupt)

Lifecycle callbacks injected into the agent loop. All fields are optional.

| Hook | Signature | Called when |
|------|-----------|-------------|
| `on_turn_start` | `(msg, history) -> nothing` | Before each LLM call, after typing indicator |
| `on_turn_end` | `(msg, history) -> nothing` | After response is persisted and outbound queued |
| `on_tool_call` | `(tool_name, arguments) -> nothing` | Before each tool is dispatched |
| `on_tool_result` | `(tool_name, result_text) -> nothing` | After a successful tool dispatch |
| `should_interrupt` | `(tool_name, arguments) -> Bool` | Before each tool; return `true` to stop the loop |

Hook failures are logged with `@warn` and never propagate. Hooks are not thread-safe
by default — close over shared mutable state with care in concurrent sessions.

When `should_interrupt` returns `true`, remaining tool calls in the current LLM batch
are silently skipped and the loop exits with the current response text.
"""
struct AgentHooks
    on_turn_start::Union{Nothing,Function}    # (msg, history) -> nothing
    on_turn_end::Union{Nothing,Function}      # (msg, history) -> nothing
    on_tool_call::Union{Nothing,Function}     # (tool_name, arguments) -> nothing
    on_tool_result::Union{Nothing,Function}   # (tool_name, result_text) -> nothing  (fires on both success and error)
    should_interrupt::Union{Nothing,Function} # (tool_name, arguments) -> Bool
end

function AgentHooks(;
    on_turn_start=nothing,
    on_turn_end=nothing,
    on_tool_call=nothing,
    on_tool_result=nothing,
    should_interrupt=nothing,
)
    return AgentHooks(on_turn_start, on_turn_end, on_tool_call, on_tool_result, should_interrupt)
end

# ---------------------------------------------------------------------------
# Config structs — group related Agent configuration
# ---------------------------------------------------------------------------

"""
    MemoryConfig(; enable, enable_consolidation, ...)

Configuration for memory persistence and LLM-driven consolidation.
"""
struct MemoryConfig
    enable::Bool
    enable_consolidation::Bool
    consolidation_threshold_tokens::Int
    consolidation_max_output_tokens::Union{Nothing,Integer}
    consolidation_max_turn_chars::Int
    consolidation_max_turns::Int
    consolidation_max_failures::Int
end

function MemoryConfig(;
    enable::Bool=true,
    enable_consolidation::Bool=true,
    consolidation_threshold_tokens::Int=2_000,
    consolidation_max_output_tokens::Union{Nothing,Integer}=800,
    consolidation_max_turn_chars::Int=2_000,
    consolidation_max_turns::Int=50,
    consolidation_max_failures::Int=3,
)
    MemoryConfig(enable, enable_consolidation,
        consolidation_threshold_tokens, consolidation_max_output_tokens,
        consolidation_max_turn_chars, consolidation_max_turns,
        consolidation_max_failures)
end

"""
    BuiltinToolsConfig(; enable, restrict_to_workspace, enable_exec, ...)

Configuration for local built-in tools (file ops, web search, shell exec).
"""
struct BuiltinToolsConfig
    enable::Bool
    restrict_to_workspace::Bool
    enable_exec::Bool
    exec_timeout_s::Float64
    exec_path_append::String
    web_search_max_results::Int
end

function BuiltinToolsConfig(;
    enable::Bool=true,
    restrict_to_workspace::Bool=true,
    enable_exec::Bool=false,
    exec_timeout_s::Real=60.0,
    exec_path_append::AbstractString="",
    web_search_max_results::Int=5,
)
    BuiltinToolsConfig(enable, restrict_to_workspace, enable_exec,
        Float64(exec_timeout_s), String(exec_path_append), web_search_max_results)
end

"""
    SkillsConfig(; enable, dir)

Configuration for markdown instruction skills.
"""
struct SkillsConfig
    enable::Bool
    dir::Union{Nothing,String}
end

function SkillsConfig(;
    enable::Bool=true,
    dir::Union{Nothing,AbstractString}=nothing,
)
    SkillsConfig(enable, dir === nothing ? nothing : String(dir))
end

"""
    ClaudeCodeConfig(; enable, model, timeout_s, max_budget, permission_mode, progress_interval_s)

Configuration for Claude Code tool delegation.
"""
struct ClaudeCodeConfig
    enable::Bool
    model::String
    timeout_s::Float64
    max_budget::Union{Nothing,Real}
    permission_mode::String
    progress_interval_s::Float64
end

function ClaudeCodeConfig(;
    enable::Bool=false,
    model::AbstractString="sonnet",
    timeout_s::Real=1800.0,
    max_budget::Union{Nothing,Real}=nothing,
    permission_mode::AbstractString="bypassPermissions",
    progress_interval_s::Real=15.0,
)
    ClaudeCodeConfig(enable, String(model), Float64(timeout_s),
        max_budget, String(permission_mode), Float64(progress_interval_s))
end

"""
    CodexConfig(; enable, model, timeout_s, sandbox_mode, progress_interval_s)

Configuration for Codex tool delegation.
"""
struct CodexConfig
    enable::Bool
    model::Union{Nothing,String}
    timeout_s::Float64
    sandbox_mode::String
    progress_interval_s::Float64
end

function CodexConfig(;
    enable::Bool=false,
    model::Union{Nothing,AbstractString}=nothing,
    timeout_s::Real=1800.0,
    sandbox_mode::AbstractString="workspace-write",
    progress_interval_s::Real=15.0,
)
    CodexConfig(enable, model === nothing ? nothing : String(model),
        Float64(timeout_s), String(sandbox_mode), Float64(progress_interval_s))
end

"""
    PromptContextConfig(; enable, doc_names, max_chars_per_doc, include_runtime_metadata)

Configuration for prompt context injection (bootstrap docs, runtime metadata).
"""
struct PromptContextConfig
    enable::Bool
    doc_names::Vector
    max_chars_per_doc::Int
    include_runtime_metadata::Bool
end

function PromptContextConfig(;
    enable::Bool=true,
    doc_names::Union{Tuple,Vector}=DEFAULT_BOOTSTRAP_DOCS,
    max_chars_per_doc::Int=12_000,
    include_runtime_metadata::Bool=true,
)
    PromptContextConfig(enable, collect(doc_names), max_chars_per_doc,
        include_runtime_metadata)
end

"""
    SubagentConfig(; enable, max_concurrent, max_iterations)

Configuration for background subagent spawning.
"""
struct SubagentConfig
    enable::Bool
    max_concurrent::Int
    max_iterations::Int
end

function SubagentConfig(;
    enable::Bool=true,
    max_concurrent::Int=5,
    max_iterations::Int=15,
)
    SubagentConfig(enable, max_concurrent, max_iterations)
end

# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

"""
    Agent(provider; kwargs...)

Encapsulates all LLM-related configuration for a Krill agent. Use with
`RuntimeState(channels, agent)` for a cleaner alternative to passing 50+
`llm_*` keyword arguments directly to `RuntimeState`.

# Basic usage

```julia
agent = Agent(OpenAIProvider(api_key=ENV["OPENAI_API_KEY"], model="gpt-4o-mini");
    system_prompt = "You are a helpful assistant.",
    workspace    = "context",
)
rt = RuntimeState(channels, agent)
```

# With hooks and custom retry

```julia
agent = Agent(provider;
    hooks = AgentHooks(
        on_tool_call   = (name, args) -> @info "Tool" name,
        on_tool_result = (name, res)  -> @info "Result" name chars=length(res),
        should_interrupt = (name, _)  -> name == "forbidden_tool",
    ),
    retry = RetryConfig(max_retries=5, base_delay_s=1.0),
)
```

# With config structs

```julia
agent = Agent(provider;
    memory       = MemoryConfig(enable=true, enable_consolidation=false),
    builtin_tools = BuiltinToolsConfig(enable_exec=true, exec_timeout_s=30.0),
    claude_code  = ClaudeCodeConfig(enable=true, model="opus"),
)
```
"""
struct Agent
    provider::AbstractLLMProvider
    system_prompt::Union{Nothing,String,Function}
    workspace::String
    data_dir::String
    tool_registry::Union{Nothing,ToolRegistry}
    memory_store::Union{Nothing,MemoryStore}
    hooks::AgentHooks
    retry::RetryConfig
    # Provider-native tools (web search, code interpreter, etc.)
    llm_tools::Union{Nothing,Vector}
    llm_include::Union{Nothing,Vector}
    llm_reasoning::Union{Nothing,AbstractDict,AbstractString}
    llm_stream::Bool
    llm_parallel_tool_calls::Union{Nothing,Bool}
    llm_max_output_tokens::Union{Nothing,Integer}
    llm_tool_choice::Union{Nothing,AbstractDict,AbstractString}
    max_context_tokens::Int
    max_tool_iterations::Int
    max_tool_output_chars::Int
    allowed_tools::Union{Nothing,Vector{String}}
    # Grouped configs
    memory::MemoryConfig
    builtin_tools::BuiltinToolsConfig
    skills::SkillsConfig
    prompt_context::PromptContextConfig
    claude_code::ClaudeCodeConfig
    codex::CodexConfig
    subagents::SubagentConfig
    # History summarization
    enable_history_summarization::Bool
    history_summarization_max_chars::Int
    # Google Workspace
    enable_google_workspace::Bool
    # Cron
    enable_cron::Bool
    cron_tick_interval_s::Float64
    # MCP
    mcp_servers::Vector{MCPServer}
    mcp_connect_fn::Function
end

"""
    Agent(provider; kwargs...) — backward-compatible flat-kwarg constructor

Accepts individual keyword arguments and packs them into nested config structs.
Also accepts config structs directly (e.g., `memory=MemoryConfig(...)`) — struct
values take precedence over flat kwargs.
"""
function Agent(
    provider::AbstractLLMProvider;
    system_prompt::Union{Nothing,AbstractString,Function}="You are a helpful assistant.",
    workspace::AbstractString="context",
    data_dir::AbstractString=joinpath(homedir(), ".krill"),
    tool_registry::Union{Nothing,ToolRegistry}=nothing,
    memory_store::Union{Nothing,MemoryStore}=nothing,
    hooks::AgentHooks=AgentHooks(),
    retry::RetryConfig=RetryConfig(),
    # Provider-native tools
    llm_tools=nothing,
    llm_include=nothing,
    llm_reasoning=nothing,
    llm_stream::Bool=false,
    llm_parallel_tool_calls::Union{Nothing,Bool}=nothing,
    llm_max_output_tokens::Union{Nothing,Integer}=nothing,
    llm_tool_choice=nothing,
    max_context_tokens::Int=8_000,
    max_tool_iterations::Int=10,
    max_tool_output_chars::Int=8_000,
    allowed_tools::Union{Nothing,AbstractVector{<:AbstractString}}=nothing,
    # Memory — flat kwargs (backward compat) or struct
    memory::Union{MemoryConfig,Nothing}=nothing,
    enable_memory::Bool=true,
    enable_memory_consolidation::Bool=true,
    memory_consolidation_threshold_tokens::Int=2_000,
    memory_consolidation_max_output_tokens::Union{Nothing,Integer}=800,
    memory_consolidation_max_turn_chars::Int=2_000,
    memory_consolidation_max_turns::Int=50,
    memory_consolidation_max_failures::Int=3,
    # Builtin tools — flat kwargs or struct
    builtin_tools::Union{BuiltinToolsConfig,Nothing}=nothing,
    enable_builtin_tools::Bool=true,
    builtin_restrict_to_workspace::Bool=true,
    builtin_enable_exec::Bool=false,
    builtin_exec_timeout_s::Real=60.0,
    builtin_exec_path_append::AbstractString="",
    builtin_web_search_max_results::Int=5,
    # Skills — flat kwargs or struct
    skills::Union{SkillsConfig,Nothing}=nothing,
    enable_builtin_skills::Bool=true,
    builtin_skills_dir::Union{Nothing,AbstractString}=nothing,
    # Prompt context — flat kwargs or struct
    prompt_context::Union{PromptContextConfig,Nothing}=nothing,
    enable_prompt_context::Bool=true,
    prompt_doc_names::Union{Tuple,Vector}=DEFAULT_BOOTSTRAP_DOCS,
    prompt_max_chars_per_doc::Int=12_000,
    prompt_include_runtime_metadata::Bool=true,
    # Claude Code — flat kwargs or struct
    claude_code::Union{ClaudeCodeConfig,Nothing}=nothing,
    enable_claude_code::Bool=false,
    claude_code_model::AbstractString="sonnet",
    claude_code_timeout_s::Real=1800.0,
    claude_code_max_budget::Union{Nothing,Real}=nothing,
    claude_code_permission_mode::AbstractString="bypassPermissions",
    claude_code_progress_interval_s::Real=15.0,
    # Codex — flat kwargs or struct
    codex::Union{CodexConfig,Nothing}=nothing,
    enable_codex::Bool=false,
    codex_model::Union{Nothing,AbstractString}=nothing,
    codex_timeout_s::Real=1800.0,
    codex_sandbox_mode::AbstractString="workspace-write",
    codex_progress_interval_s::Real=15.0,
    # Subagents — flat kwargs or struct
    subagents::Union{SubagentConfig,Nothing}=nothing,
    enable_subagents::Bool=true,
    subagent_max_concurrent::Int=5,
    subagent_max_iterations::Int=15,
    # History summarization
    enable_history_summarization::Bool=false,
    history_summarization_max_chars::Int=2_000,
    # Google Workspace
    enable_google_workspace::Bool=false,
    # Cron
    enable_cron::Bool=true,
    cron_tick_interval_s::Real=15.0,
    # MCP
    mcp_servers::Vector{MCPServer}=MCPServer[],
    mcp_connect_fn::Function=connect,
)
    resolved_system_prompt = system_prompt isa AbstractString ? String(system_prompt) : system_prompt
    resolved_allowed = allowed_tools === nothing ? nothing : String.(collect(allowed_tools))

    # Pack flat kwargs into config structs (struct value takes precedence)
    mem = memory !== nothing ? memory : MemoryConfig(
        enable=enable_memory,
        enable_consolidation=enable_memory_consolidation,
        consolidation_threshold_tokens=memory_consolidation_threshold_tokens,
        consolidation_max_output_tokens=memory_consolidation_max_output_tokens,
        consolidation_max_turn_chars=memory_consolidation_max_turn_chars,
        consolidation_max_turns=memory_consolidation_max_turns,
        consolidation_max_failures=memory_consolidation_max_failures,
    )

    bt = builtin_tools !== nothing ? builtin_tools : BuiltinToolsConfig(
        enable=enable_builtin_tools,
        restrict_to_workspace=builtin_restrict_to_workspace,
        enable_exec=builtin_enable_exec,
        exec_timeout_s=builtin_exec_timeout_s,
        exec_path_append=builtin_exec_path_append,
        web_search_max_results=builtin_web_search_max_results,
    )

    sk = skills !== nothing ? skills : SkillsConfig(
        enable=enable_builtin_skills,
        dir=builtin_skills_dir,
    )

    pc = prompt_context !== nothing ? prompt_context : PromptContextConfig(
        enable=enable_prompt_context,
        doc_names=prompt_doc_names,
        max_chars_per_doc=prompt_max_chars_per_doc,
        include_runtime_metadata=prompt_include_runtime_metadata,
    )

    cc = claude_code !== nothing ? claude_code : ClaudeCodeConfig(
        enable=enable_claude_code,
        model=claude_code_model,
        timeout_s=claude_code_timeout_s,
        max_budget=claude_code_max_budget,
        permission_mode=claude_code_permission_mode,
        progress_interval_s=claude_code_progress_interval_s,
    )

    cx = codex !== nothing ? codex : CodexConfig(
        enable=enable_codex,
        model=codex_model,
        timeout_s=codex_timeout_s,
        sandbox_mode=codex_sandbox_mode,
        progress_interval_s=codex_progress_interval_s,
    )

    sa = subagents !== nothing ? subagents : SubagentConfig(
        enable=enable_subagents,
        max_concurrent=subagent_max_concurrent,
        max_iterations=subagent_max_iterations,
    )

    return Agent(
        provider,
        resolved_system_prompt,
        String(workspace),
        String(data_dir),
        tool_registry,
        memory_store,
        hooks,
        retry,
        llm_tools,
        llm_include,
        llm_reasoning,
        llm_stream,
        llm_parallel_tool_calls,
        llm_max_output_tokens,
        llm_tool_choice,
        max_context_tokens,
        max_tool_iterations,
        max_tool_output_chars,
        resolved_allowed,
        mem,
        bt,
        sk,
        pc,
        cc,
        cx,
        sa,
        enable_history_summarization,
        history_summarization_max_chars,
        enable_google_workspace,
        enable_cron,
        Float64(cron_tick_interval_s),
        mcp_servers,
        mcp_connect_fn,
    )
end

end # module AgentModule
