module Krill

# ─── Transport ────────────────────────────────────────────────────
include("transport/types.jl")
include("transport/message_hub.jl")
include("transport/manager.jl")
include("transport/dedup.jl")
include("transport/channels.jl")
include("transport/durable_queue.jl")

# ─── Sessions & memory ───────────────────────────────────────────
include("sessions/sessions.jl")
include("sessions/memory.jl")
include("sessions/echo.jl")

# ─── Tools, skills, MCP ─────────────────────────────────────────
include("tools/registry.jl")
include("tools/skills.jl")

# ─── Prompt context ──────────────────────────────────────────────
include("prompt_context.jl")

# ─── Scheduling (cron before builtin_tools — builtin_tools uses Cron) ─
include("scheduling/cron.jl")

# ─── Builtin tools & MCP (depend on Tools + Cron) ───────────────
include("tools/builtin/builtin_tools.jl")
include("tools/mcp.jl")

# ─── LLM providers ──────────────────────────────────────────────
include("llm/llm.jl")

# ─── Memory consolidation + global memory (depend on LLM + Sessions) ───
include("sessions/memory_consolidation.jl")
include("sessions/global_memory.jl")
include("sessions/consumer.jl")

# ─── Subagents (depends on LLM + Tools) ─────────────────────────
include("scheduling/subagent.jl")

# ─── Agent config (depends on everything above) ─────────────────
include("agent.jl")

# ─── Channels ────────────────────────────────────────────────────
include("channels/channels.jl")

# ─── Runtime ─────────────────────────────────────────────────────
include("runtime.jl")

# ─── Config ──────────────────────────────────────────────────────
include("config/config.jl")

# ─── Re-exports from submodules ──────────────────────────────────

using .Types: ContentPart, TextPart, BinaryPart, ToolCallPart, ToolResultPart,
    DeliveryPolicy, ErrorEnvelope, MCPConnectionError, MemoryConsolidationError,
    InboundMessage, OutboundMessage,
    ToolCallEvent, ToolResultEvent,
    message_text

using .MessageHub: MessageHubState,
    publish_inbound!, publish_outbound!,
    try_publish_inbound!, try_publish_outbound!,
    take_inbound!, take_outbound!,
    try_take_inbound!, try_take_outbound!

using .ChannelManager: ChannelManagerState, DispatchEvent,
    register_sender!, start_dispatch!, stop_dispatch!,
    dispatch_stats, dead_letters, flush_dead_letters!

using .Dedup: BoundedDedup, seen!, has_seen

using .ChannelInterface: AbstractChannel, ChannelState,
    channel_name, make_sender, normalize,
    start_channel!, stop_channel!, send_typing, send_direct,
    register_channel!, make_inbound_handler

using .Sessions: SessionStore, TurnRecord,
    get_session_lock!, load_history, append_turn!, save_history,
    session_dir, sanitize_session_key

using .Memory: MemoryStore, MemoryState,
    memory_dir, memory_path, history_path, memory_state_path,
    load_memory, save_memory!, append_history!,
    load_memory_state, save_memory_state!

using .GlobalMemory:
    GlobalMemoryStore,
    global_memory_path, load_global_memory, save_global_memory!,
    consolidate_global_memory!

using .Echo: run_echo_loop!

using .SessionConsumer:
    run_session_loop!, echo_processor,
    SessionCancelScope, request_cancel!, is_cancelled, clear_cancel!

using .Tools: AbstractToolDef, ToolDef, ToolRegistry,
    ToolNotFoundError, ToolValidationError, ToolExecutionError,
    register_tool!, unregister_tool!, get_tool, has_tool,
    tool_names, tools_schema, dispatch_tool, @tool

using .Skills: SkillDef,
    discover_skills, read_skill, skills_summary,
    load_always_skills, register_read_skill_tool!

using .PromptContext: BootstrapDoc, DEFAULT_BOOTSTRAP_DOCS,
    RUNTIME_CONTEXT_MARKER, TOOL_OUTPUT_SAFETY_NOTICE,
    load_bootstrap_docs, render_runtime_metadata,
    compose_instructions, make_prompt_builder

using .BuiltinTools: register_builtin_tools!, register_cron_tools!, set_cron_context!

using .MCP: MCPServer

using .LLM: AbstractLLMProvider,
    OpenAIProvider, GeminiProvider, GeminiOpenAICompatProvider,
    OpenAIAPIError, LLMToolCall, LLMUsage, LLMResponse,
    build_context, chat_completion, make_llm_processor

using .MemoryConsolidation: MemoryConsolidatorConfig,
    estimate_turn_tokens, estimate_turns_tokens,
    consolidate_session_memory!, make_memory_consolidator

using .Cron: CronJob, CronService,
    add_job!, remove_job!, list_jobs, get_job,
    is_due, parse_schedule, parse_cron,
    save_jobs!, load_jobs!

using .Subagent: SubagentTask, SubagentManager,
    spawn_subagent!, cancel_subagents!, list_subagents, subagent_count,
    register_spawn_tools!, set_spawn_context!

using .DurableQueue: DurableQueueState,
    enqueue!, ack!, replay, compact!, queue_stats

using .AgentModule: RetryConfig, AgentHooks, Agent,
    MemoryConfig, BuiltinToolsConfig, SkillsConfig,
    ClaudeCodeConfig, CodexConfig, PromptContextConfig, SubagentConfig

using .Channels: Telegram, TelegramClient, TelegramAPIError,
    TelegramChannel, TelegramWebhookChannel,
    get_updates, send_message, run_polling,
    send_chat_action, set_webhook, delete_webhook,
    normalize_update, make_telegram_sender,
    Discord, DiscordClient, DiscordAPIError, DiscordChannel,
    discord_send_message, discord_trigger_typing

using .RuntimeModule: RuntimeState, start!, shutdown!, status

using .Config: KrillConfig, load_config, start_agent!,
    load_dotenv!, expand_env, expand_env_deep!,
    get_cfg, make_provider, provider_tools, provider_include_fields,
    make_mcp_servers, build_channels

# ═══════════════════════════════════════════════════════════════════
# Exports
# ═══════════════════════════════════════════════════════════════════

export # ─── Submodules ───
    Types, MessageHub, ChannelManager, Dedup, ChannelInterface,
    Sessions, Memory, GlobalMemory, Echo, SessionConsumer, Tools, Skills,
    PromptContext, BuiltinTools, MCP, LLM, MemoryConsolidation,
    Cron, Subagent, AgentModule, DurableQueue,
    Channels, Telegram, Discord,
    RuntimeModule, Config,

    # ─── Message types ───
    ContentPart, TextPart, BinaryPart, ToolCallPart, ToolResultPart,
    DeliveryPolicy, ErrorEnvelope, MCPConnectionError, MemoryConsolidationError,
    InboundMessage, OutboundMessage,
    ToolCallEvent, ToolResultEvent,
    message_text,

    # ─── Message hub ───
    MessageHubState,
    publish_inbound!, publish_outbound!,
    try_publish_inbound!, try_publish_outbound!,
    take_inbound!, take_outbound!,
    try_take_inbound!, try_take_outbound!,

    # ─── Channel manager & dispatch ───
    AbstractChannel, ChannelState,
    channel_name, make_sender, normalize,
    start_channel!, stop_channel!, send_typing, send_direct,
    register_channel!, make_inbound_handler,
    ChannelManagerState, DispatchEvent,
    register_sender!, start_dispatch!, stop_dispatch!,
    dispatch_stats, dead_letters, flush_dead_letters!,

    # ─── Dedup ───
    BoundedDedup, seen!, has_seen,

    # ─── Sessions & memory ───
    SessionStore, TurnRecord,
    get_session_lock!, load_history, append_turn!, save_history,
    session_dir, sanitize_session_key,
    MemoryStore, MemoryState,
    memory_dir, memory_path, history_path, memory_state_path,
    load_memory, save_memory!, append_history!,
    load_memory_state, save_memory_state!,
    GlobalMemoryStore,
    global_memory_path, load_global_memory, save_global_memory!,
    consolidate_global_memory!,

    # ─── Echo & session consumer ───
    run_echo_loop!, run_session_loop!, echo_processor,
    SessionCancelScope, request_cancel!, is_cancelled, clear_cancel!,

    # ─── Tools ───
    AbstractToolDef, ToolDef, ToolRegistry,
    ToolNotFoundError, ToolValidationError, ToolExecutionError,
    register_tool!, unregister_tool!, get_tool, has_tool,
    tool_names, tools_schema, dispatch_tool, @tool,
    register_builtin_tools!,

    # ─── Skills ───
    SkillDef,
    discover_skills, read_skill, skills_summary,
    load_always_skills, register_read_skill_tool!,

    # ─── Prompt context ───
    BootstrapDoc, DEFAULT_BOOTSTRAP_DOCS,
    RUNTIME_CONTEXT_MARKER, TOOL_OUTPUT_SAFETY_NOTICE,
    load_bootstrap_docs, render_runtime_metadata,
    compose_instructions, make_prompt_builder,

    # ─── MCP ───
    MCPServer,

    # ─── LLM ───
    AbstractLLMProvider,
    OpenAIProvider, GeminiProvider, GeminiOpenAICompatProvider,
    OpenAIAPIError, LLMToolCall, LLMUsage, LLMResponse,
    build_context, chat_completion, make_llm_processor,

    # ─── Memory consolidation ───
    MemoryConsolidatorConfig,
    estimate_turn_tokens, estimate_turns_tokens,
    consolidate_session_memory!, make_memory_consolidator,

    # ─── Cron ───
    CronJob, CronService,
    add_job!, remove_job!, list_jobs, get_job,
    is_due, parse_schedule, parse_cron,
    save_jobs!, load_jobs!,
    register_cron_tools!, set_cron_context!,

    # ─── Subagents ───
    SubagentTask, SubagentManager,
    spawn_subagent!, cancel_subagents!, list_subagents, subagent_count,
    register_spawn_tools!, set_spawn_context!,

    # ─── Durable queue ───
    DurableQueueState,
    enqueue!, ack!, replay, compact!, queue_stats,

    # ─── Agent & config ───
    RetryConfig, AgentHooks, Agent,
    MemoryConfig, BuiltinToolsConfig, SkillsConfig,
    ClaudeCodeConfig, CodexConfig, PromptContextConfig, SubagentConfig,

    # ─── Channels (Telegram) ───
    TelegramClient, TelegramAPIError,
    TelegramChannel, TelegramWebhookChannel,
    get_updates, send_message, send_chat_action,
    set_webhook, delete_webhook, run_polling,
    normalize_update, make_telegram_sender,

    # ─── Channels (Discord) ───
    DiscordClient, DiscordAPIError, DiscordChannel,
    discord_send_message, discord_trigger_typing,

    # ─── Runtime ───
    RuntimeState, start!, shutdown!, status,

    # ─── Config ───
    KrillConfig, load_config, start_agent!,
    load_dotenv!, expand_env, expand_env_deep!,
    get_cfg, make_provider, provider_tools, provider_include_fields,
    make_mcp_servers, build_channels

end
