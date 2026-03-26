module Krill

include("core/core.jl")
include("channels/channels.jl")
include("runtime.jl")
include("config/config.jl")

# ─── Core submodules ────────────────────────────────────────────────
using .Core: Types,
    MessageHub,
    ChannelManager,
    Dedup,
    ChannelInterface,
    DurableQueue,
    Sessions,
    Memory,
    Echo,
    SessionConsumer,
    Tools,
    Skills,
    PromptContext,
    BuiltinTools,
    MCP,
    LLM,
    MemoryConsolidation,
    Cron,
    Subagent,
    AgentModule

# ─── Types ──────────────────────────────────────────────────────────
using .Core: ContentPart, TextPart, BinaryPart, ToolCallPart, ToolResultPart,
    DeliveryPolicy, ErrorEnvelope, MCPConnectionError, MemoryConsolidationError,
    InboundMessage, OutboundMessage,
    ToolCallEvent, ToolResultEvent,
    message_text

# ─── Message hub ────────────────────────────────────────────────────
using .Core: MessageHubState,
    publish_inbound!, publish_outbound!,
    try_publish_inbound!, try_publish_outbound!,
    take_inbound!, take_outbound!,
    try_take_inbound!, try_take_outbound!

# ─── Channel manager & dispatch ─────────────────────────────────────
using .Core: AbstractChannel, ChannelState,
    channel_name, make_sender, normalize,
    start_channel!, stop_channel!, send_typing, send_direct,
    register_channel!, make_inbound_handler,
    ChannelManagerState, DispatchEvent,
    register_sender!, start_dispatch!, stop_dispatch!,
    dispatch_stats, dead_letters, flush_dead_letters!

# ─── Dedup ──────────────────────────────────────────────────────────
using .Core: BoundedDedup, seen!, has_seen

# ─── Sessions & memory ──────────────────────────────────────────────
using .Core: SessionStore, TurnRecord,
    get_session_lock!, load_history, append_turn!, save_history,
    session_dir, sanitize_session_key,
    MemoryStore, MemoryState,
    memory_dir, memory_path, history_path, memory_state_path,
    load_memory, save_memory!, append_history!,
    load_memory_state, save_memory_state!

# ─── Echo & session consumer ────────────────────────────────────────
using .Core:
    run_echo_loop!, run_session_loop!, echo_processor,
    SessionCancelScope, request_cancel!, is_cancelled, clear_cancel!

# ─── Tools ──────────────────────────────────────────────────────────
using .Core: AbstractToolDef, ToolDef, ToolRegistry,
    ToolNotFoundError, ToolValidationError, ToolExecutionError,
    register_tool!, unregister_tool!, get_tool, has_tool,
    tool_names, tools_schema, dispatch_tool, @tool,
    register_builtin_tools!

# ─── Skills ─────────────────────────────────────────────────────────
using .Core: SkillDef,
    discover_skills, read_skill, skills_summary,
    load_always_skills, register_read_skill_tool!

# ─── Prompt context ─────────────────────────────────────────────────
using .Core: BootstrapDoc, DEFAULT_BOOTSTRAP_DOCS,
    RUNTIME_CONTEXT_MARKER, TOOL_OUTPUT_SAFETY_NOTICE,
    load_bootstrap_docs, render_runtime_metadata,
    compose_instructions, make_prompt_builder

# ─── MCP ────────────────────────────────────────────────────────────
using .Core: MCPServer

# ─── LLM ────────────────────────────────────────────────────────────
using .Core: AbstractLLMProvider,
    OpenAIProvider, GeminiProvider, GeminiOpenAICompatProvider,
    OpenAIAPIError, LLMToolCall, LLMUsage, LLMResponse,
    build_context, chat_completion, make_llm_processor

# ─── Memory consolidation ──────────────────────────────────────────
using .Core: MemoryConsolidatorConfig,
    estimate_turn_tokens, estimate_turns_tokens,
    consolidate_session_memory!, make_memory_consolidator

# ─── Cron ───────────────────────────────────────────────────────────
using .Core: CronJob, CronService,
    add_job!, remove_job!, list_jobs, get_job,
    is_due, parse_schedule, parse_cron,
    save_jobs!, load_jobs!,
    register_cron_tools!, set_cron_context!

# ─── Subagents ──────────────────────────────────────────────────────
using .Core: SubagentTask, SubagentManager,
    spawn_subagent!, cancel_subagents!, list_subagents, subagent_count,
    register_spawn_tools!, set_spawn_context!

# ─── Durable queue ──────────────────────────────────────────────────
using .Core: DurableQueueState,
    enqueue!, ack!, replay, compact!, queue_stats

# ─── Agent & config structs ─────────────────────────────────────────
using .Core: RetryConfig, AgentHooks, Agent,
    MemoryConfig, BuiltinToolsConfig, SkillsConfig,
    ClaudeCodeConfig, CodexConfig, PromptContextConfig, SubagentConfig

# ─── Channels ───────────────────────────────────────────────────────
using .Channels: Telegram, TelegramClient, TelegramAPIError,
    TelegramChannel, TelegramWebhookChannel,
    get_updates, send_message, run_polling,
    send_chat_action, set_webhook, delete_webhook,
    normalize_update, make_telegram_sender,
    Discord, DiscordClient, DiscordAPIError, DiscordChannel,
    discord_send_message, discord_trigger_typing

# ─── Runtime ────────────────────────────────────────────────────────
using .RuntimeModule: RuntimeState, start!, shutdown!, status

# ─── Config ─────────────────────────────────────────────────────────
using .Config: KrillConfig, load_config, start_agent!,
    load_dotenv!, expand_env, expand_env_deep!,
    get_cfg, make_provider, provider_tools, provider_include_fields,
    make_mcp_servers, build_channels

# ═══════════════════════════════════════════════════════════════════
# Exports — grouped by category
# ═══════════════════════════════════════════════════════════════════

export # ─── Submodules ───
    Core, Types, MessageHub, ChannelManager, Dedup, ChannelInterface,
    Sessions, Memory, Echo, SessionConsumer, Tools, Skills,
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
