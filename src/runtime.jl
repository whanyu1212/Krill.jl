module RuntimeModule

using Dates

using ..Core: InboundMessage, OutboundMessage, message_text,
    MessageHubState, try_publish_inbound!,
    ChannelManagerState, register_sender!, start_dispatch!, stop_dispatch!, dispatch_stats,
    BoundedDedup, seen!,
    AbstractChannel, ChannelState, channel_name, make_sender,
    register_channel!, start_channel!, stop_channel!, send_typing, send_direct,
    make_inbound_handler,
    run_echo_loop!,
    SessionStore, run_session_loop!, echo_processor, SessionCancelScope, is_cancelled, clear_cancel!,
    MemoryStore,
    ToolRegistry,
    ToolDef,
    register_tool!,
    SkillDef, discover_skills, skills_summary, load_always_skills, register_read_skill_tool!,
    DEFAULT_BOOTSTRAP_DOCS, load_bootstrap_docs, make_prompt_builder,
    AbstractLLMProvider, OpenAIProvider, GeminiProvider, GeminiOpenAICompatProvider, make_llm_processor,
    RetryConfig, AgentHooks, Agent,
    MemoryConfig, BuiltinToolsConfig, SkillsConfig, ClaudeCodeConfig, CodexConfig,
    PromptContextConfig, SubagentConfig,
    make_memory_consolidator,
    register_builtin_tools!, register_cron_tools!, set_cron_context!,
    CronService, CronJob, add_job!, Cron,
    SubagentManager, register_spawn_tools!, set_spawn_context!, cancel_subagents!, subagent_count,
    MCPServer, MCPConnectionSet, connect, connect_mcp_servers!, close!

using ..Channels.Telegram: TelegramClient, TelegramChannel, TelegramWebhookChannel,
    run_polling, normalize_update, make_telegram_sender, send_chat_action, send_message

export RuntimeState, start!, shutdown!, status

function _merge_tool_items(existing, additions::Vector{<:Any})
    isempty(additions) && return existing
    if existing === nothing
        return Any[additions...]
    elseif existing isa AbstractVector
        merged = Any[existing...]
        append!(merged, additions)
        return merged
    end
    return Any[existing, additions...]
end

function _mcp_registered_tool_defs(
    registry::Union{Nothing,ToolRegistry},
    mcp_connections::Union{Nothing,MCPConnectionSet},
)
    (registry === nothing || mcp_connections === nothing) && return ToolDef[]
    defs = ToolDef[]
    for names in values(mcp_connections.registered_tools)
        for name in names
            tool = get(registry.tools, name, nothing)
            tool === nothing || push!(defs, tool)
        end
    end
    return defs
end

"""
    RuntimeState(channels; hub, consumer, store, processor, workspace, llm_mcp_servers, ...)

Top-level runtime that owns the full message pipeline: channel inbound polling,
normalization with dedup, session-aware consumer processing (echo by default),
and outbound dispatch.

Accepts a single `AbstractChannel` or a `Vector{<:AbstractChannel}`.

Use [`start!`](@ref) and [`shutdown!`](@ref) to manage the lifecycle.
"""
mutable struct RuntimeState
    hub::MessageHubState
    manager::ChannelManagerState
    channel_states::Vector{ChannelState}
    consumer::Function
    store::Union{Nothing,SessionStore}
    consumer_task::Union{Nothing,Task}
    running::Ref{Bool}
    dedup::BoundedDedup
    mcp_connections::Union{Nothing,MCPConnectionSet}
    cron_service::Union{Nothing,CronService}
    subagent_manager::Union{Nothing,SubagentManager}
    last_successful_poll_at::Ref{Union{Nothing,DateTime}}
    last_successful_send_at::Ref{Union{Nothing,DateTime}}
end

# Single channel convenience
function RuntimeState(channel::AbstractChannel; kwargs...)
    return RuntimeState([channel]; kwargs...)
end

"""
    RuntimeState(channels; llm_provider=nothing, workspace="context", ...)

Flat-kwargs constructor for convenience and testing. When `llm_provider` is given,
builds an `Agent` internally and delegates to `RuntimeState(channels, agent; ...)`.
When no provider is given, creates an echo-only runtime.
"""
function RuntimeState(
    channels::Vector{<:AbstractChannel};
    hub::MessageHubState=MessageHubState(),
    consumer::Union{Nothing,Function}=nothing,
    store::Union{Nothing,SessionStore}=nothing,
    processor::Function=echo_processor,
    dedup_capacity::Int=1000,
    workspace::AbstractString="context",
    data_dir::AbstractString=joinpath(homedir(), ".krill"),
    llm_provider::Union{Nothing,AbstractLLMProvider}=nothing,
    llm_memory_store::Union{Nothing,MemoryStore}=nothing,
    llm_enable_memory::Bool=true,
    llm_enable_memory_consolidation::Bool=true,
    llm_memory_consolidation_threshold_tokens::Int=2_000,
    llm_memory_consolidation_max_output_tokens::Union{Nothing,Integer}=800,
    llm_memory_consolidation_max_turn_chars::Int=2_000,
    llm_memory_consolidation_max_turns::Int=50,
    llm_memory_consolidation_max_failures::Int=3,
    system_prompt::Union{Nothing,AbstractString,Function}="You are a helpful assistant.",
    max_context_tokens::Int=8_000,
    llm_reasoning=nothing,
    llm_tools=nothing,
    llm_tool_registry=nothing,
    llm_tool_choice=nothing,
    llm_include=nothing,
    llm_stream::Bool=false,
    llm_parallel_tool_calls::Union{Nothing,Bool}=nothing,
    llm_max_output_tokens::Union{Nothing,Integer}=nothing,
    llm_max_tool_iterations::Int=10,
    llm_max_tool_output_chars::Int=8_000,
    llm_enable_builtin_tools::Bool=true,
    llm_builtin_enable_exec::Bool=false,
    llm_builtin_exec_timeout_s::Real=60.0,
    llm_builtin_exec_path_append::AbstractString="",
    llm_builtin_web_search_max_results::Int=5,
    llm_builtin_restrict_to_workspace::Bool=true,
    llm_enable_claude_code::Bool=false,
    llm_claude_code_model::String="sonnet",
    llm_claude_code_timeout_s::Real=1800.0,
    llm_claude_code_max_budget::Union{Nothing,Real}=nothing,
    llm_claude_code_permission_mode::String="bypassPermissions",
    llm_claude_code_progress_interval_s::Real=15.0,
    llm_enable_codex::Bool=false,
    llm_codex_model::Union{Nothing,String}=nothing,
    llm_codex_timeout_s::Real=1800.0,
    llm_codex_sandbox_mode::String="workspace-write",
    llm_codex_progress_interval_s::Real=15.0,
    llm_enable_google_workspace::Bool=false,
    llm_enable_builtin_skills::Bool=true,
    llm_builtin_skills_dir::Union{Nothing,AbstractString}=nothing,
    llm_enable_prompt_context::Bool=true,
    llm_prompt_doc_names::Union{Tuple,Vector}=DEFAULT_BOOTSTRAP_DOCS,
    llm_prompt_max_chars_per_doc::Int=12_000,
    llm_prompt_include_runtime_metadata::Bool=true,
    llm_allowed_tools::Union{Nothing,AbstractVector{<:AbstractString}}=nothing,
    llm_enable_history_summarization::Bool=false,
    llm_history_summarization_max_chars::Int=2_000,
    llm_enable_cron::Bool=true,
    llm_cron_tick_interval_s::Float64=15.0,
    llm_enable_subagents::Bool=true,
    llm_subagent_max_concurrent::Int=5,
    llm_subagent_max_iterations::Int=15,
    llm_mcp_servers::Vector{MCPServer}=MCPServer[],
    llm_mcp_connect_fn::Function=connect,
    llm_hooks=nothing,   # expected: AgentHooks or nothing
    llm_retry=nothing,   # expected: RetryConfig or nothing
    dead_letter_path::Union{Nothing,AbstractString}=nothing,
    on_dispatch::Union{Nothing,Function}=nothing,
)
    # When an LLM provider is given, pack all config into an Agent and delegate
    if llm_provider !== nothing
        agent = Agent(llm_provider;
            system_prompt=system_prompt,
            workspace=workspace,
            data_dir=data_dir,
            tool_registry=llm_tool_registry,
            memory_store=llm_memory_store,
            hooks=llm_hooks === nothing ? AgentHooks() : llm_hooks,
            retry=llm_retry === nothing ? RetryConfig() : llm_retry,
            llm_tools=llm_tools,
            llm_include=llm_include,
            llm_reasoning=llm_reasoning,
            llm_stream=llm_stream,
            llm_parallel_tool_calls=llm_parallel_tool_calls,
            llm_max_output_tokens=llm_max_output_tokens,
            llm_tool_choice=llm_tool_choice,
            max_context_tokens=max_context_tokens,
            max_tool_iterations=llm_max_tool_iterations,
            max_tool_output_chars=llm_max_tool_output_chars,
            allowed_tools=llm_allowed_tools,
            memory=MemoryConfig(
                enable=llm_enable_memory,
                enable_consolidation=llm_enable_memory_consolidation,
                consolidation_threshold_tokens=llm_memory_consolidation_threshold_tokens,
                consolidation_max_output_tokens=llm_memory_consolidation_max_output_tokens,
                consolidation_max_turn_chars=llm_memory_consolidation_max_turn_chars,
                consolidation_max_turns=llm_memory_consolidation_max_turns,
                consolidation_max_failures=llm_memory_consolidation_max_failures,
            ),
            builtin_tools=BuiltinToolsConfig(
                enable=llm_enable_builtin_tools,
                restrict_to_workspace=llm_builtin_restrict_to_workspace,
                enable_exec=llm_builtin_enable_exec,
                exec_timeout_s=llm_builtin_exec_timeout_s,
                exec_path_append=llm_builtin_exec_path_append,
                web_search_max_results=llm_builtin_web_search_max_results,
            ),
            skills=SkillsConfig(
                enable=llm_enable_builtin_skills,
                dir=llm_builtin_skills_dir,
            ),
            claude_code=ClaudeCodeConfig(
                enable=llm_enable_claude_code,
                model=llm_claude_code_model,
                timeout_s=llm_claude_code_timeout_s,
                max_budget=llm_claude_code_max_budget,
                permission_mode=llm_claude_code_permission_mode,
                progress_interval_s=llm_claude_code_progress_interval_s,
            ),
            codex=CodexConfig(
                enable=llm_enable_codex,
                model=llm_codex_model,
                timeout_s=llm_codex_timeout_s,
                sandbox_mode=llm_codex_sandbox_mode,
                progress_interval_s=llm_codex_progress_interval_s,
            ),
            subagents=SubagentConfig(
                enable=llm_enable_subagents,
                max_concurrent=llm_subagent_max_concurrent,
                max_iterations=llm_subagent_max_iterations,
            ),
            prompt_context=PromptContextConfig(
                enable=llm_enable_prompt_context,
                doc_names=llm_prompt_doc_names,
                max_chars_per_doc=llm_prompt_max_chars_per_doc,
                include_runtime_metadata=llm_prompt_include_runtime_metadata,
            ),
            enable_history_summarization=llm_enable_history_summarization,
            history_summarization_max_chars=llm_history_summarization_max_chars,
            enable_google_workspace=llm_enable_google_workspace,
            enable_cron=llm_enable_cron,
            cron_tick_interval_s=llm_cron_tick_interval_s,
            mcp_servers=llm_mcp_servers,
            mcp_connect_fn=llm_mcp_connect_fn,
        )
        return RuntimeState(channels, agent;
            hub=hub,
            consumer=consumer,
            store=store,
            dedup_capacity=dedup_capacity,
            dead_letter_path=dead_letter_path,
            on_dispatch=on_dispatch,
        )
    end

    # Echo-only runtime (no LLM provider)
    !isempty(llm_mcp_servers) && throw(ArgumentError("llm_mcp_servers requires llm_provider"))

    return _build_runtime(channels;
        hub=hub, consumer=consumer, store=store, processor=processor,
        dedup_capacity=dedup_capacity, workspace=workspace, data_dir=data_dir,
        dead_letter_path=dead_letter_path, on_dispatch=on_dispatch,
    )
end

"""
    RuntimeState(channels, agent::Agent; hub, consumer, store, dedup_capacity, dead_letter_path, on_dispatch)

Primary constructor: build a full runtime from an `Agent` config and a set of channels.
All LLM, tool, memory, and hook settings come from the `Agent`.
Infrastructure kwargs (`hub`, `consumer`, `store`, etc.) are optional overrides.
"""
function RuntimeState(
    channels::Vector{<:AbstractChannel},
    agent::Agent;
    hub::MessageHubState=MessageHubState(),
    consumer::Union{Nothing,Function}=nothing,
    store::Union{Nothing,SessionStore}=nothing,
    dedup_capacity::Int=1000,
    dead_letter_path::Union{Nothing,AbstractString}=nothing,
    on_dispatch::Union{Nothing,Function}=nothing,
)
    workspace = agent.workspace
    data_dir = agent.data_dir
    provider = agent.provider

    isempty(channels) && throw(ArgumentError("at least one channel is required"))

    resolved_dead_letter_path = dead_letter_path
    if resolved_dead_letter_path === nothing
        resolved_dead_letter_path = joinpath(data_dir, "dead_letters.jsonl")
    end

    manager = ChannelManagerState(hub;
        on_dispatch=on_dispatch,
        dead_letter_path=resolved_dead_letter_path,
    )
    last_successful_send_at = Ref{Union{Nothing,DateTime}}(nothing)

    channel_states = ChannelState[]
    channel_map = Dict{Symbol,AbstractChannel}()
    for ch in channels
        name = channel_name(ch)
        haskey(channel_map, name) && throw(ArgumentError("duplicate channel name: $name"))
        channel_map[name] = ch
        cs = register_channel!(manager, ch;
            on_send=() -> (last_successful_send_at[] = now(UTC)),
        )
        push!(channel_states, cs)
    end

    (agent.tool_registry === nothing || agent.tool_registry isa ToolRegistry) ||
        throw(ArgumentError("tool_registry must be ToolRegistry or nothing"))

    resolved_tool_registry = agent.tool_registry
    builtin_tool_defs = ToolDef[]
    builtin_skill_defs = ToolDef[]
    cron_tool_defs = ToolDef[]
    spawn_tool_defs = ToolDef[]
    mcp_tool_defs = ToolDef[]
    discovered_skills = SkillDef[]
    mcp_connections = nothing
    cron_service = nothing
    subagent_manager = nothing

    if agent.builtin_tools.enable
        resolved_tool_registry === nothing && (resolved_tool_registry = ToolRegistry())
        send_tool_message = (chat_id, text; disable_web_page_preview=false) -> begin
            for cs in channel_states
                try
                    send_direct(cs.channel, chat_id, String(text);
                        parse_mode=nothing,
                        disable_web_page_preview=Bool(disable_web_page_preview),
                    )
                    return nothing
                catch e
                    e isa ErrorException && contains(e.msg, "not implemented") && continue
                    rethrow()
                end
            end
            @warn "no channel could deliver tool message" chat_id=chat_id
            return nothing
        end

        _cc_progress_fn = if agent.claude_code.enable && send_tool_message !== nothing
            (progress_text::String) -> begin
                @debug "claude_code progress" text=progress_text
            end
        else
            nothing
        end

        # Disable local DDG web_search when provider-native search is available
        _has_provider_search = agent.llm_tools !== nothing

        builtin_tool_defs = register_builtin_tools!(
            resolved_tool_registry;
            workspace=workspace,
            enable_exec=agent.builtin_tools.enable_exec,
            exec_timeout_s=Float64(agent.builtin_tools.exec_timeout_s),
            exec_path_append=agent.builtin_tools.exec_path_append,
            enable_web_search=!_has_provider_search,
            web_search_max_results=agent.builtin_tools.web_search_max_results,
            restrict_to_workspace=agent.builtin_tools.restrict_to_workspace,
            send_message_fn=send_tool_message,
            enable_claude_code=agent.claude_code.enable,
            claude_code_model=agent.claude_code.model,
            claude_code_timeout_s=Float64(agent.claude_code.timeout_s),
            claude_code_max_budget=agent.claude_code.max_budget,
            claude_code_permission_mode=agent.claude_code.permission_mode,
            claude_code_progress_fn=_cc_progress_fn,
            claude_code_progress_interval_s=Float64(agent.claude_code.progress_interval_s),
            enable_codex=agent.codex.enable,
            codex_model=agent.codex.model,
            codex_timeout_s=Float64(agent.codex.timeout_s),
            codex_sandbox_mode=agent.codex.sandbox_mode,
            codex_progress_fn=nothing,
            codex_progress_interval_s=Float64(agent.codex.progress_interval_s),
            enable_google_workspace=agent.enable_google_workspace,
            replace=false,
        )
    end

    if agent.skills.enable
        discovered_skills = discover_skills(
            workspace;
            builtin_skills_dir=agent.skills.dir,
        )
        if !isempty(discovered_skills)
            resolved_tool_registry === nothing && (resolved_tool_registry = ToolRegistry())
            read_skill_tool = register_read_skill_tool!(
                resolved_tool_registry;
                workspace=workspace,
                builtin_skills_dir=agent.skills.dir,
                skills=discovered_skills,
                replace=false,
            )
            push!(builtin_skill_defs, read_skill_tool)
        end
    end

    if agent.enable_cron
        resolved_tool_registry === nothing && (resolved_tool_registry = ToolRegistry())
        cron_service = CronService(
            workspace=data_dir,
            tick_interval_s=agent.cron_tick_interval_s,
            publish_fn=msg -> try_publish_inbound!(hub, msg),
        )
        cron_tool_defs = register_cron_tools!(resolved_tool_registry, cron_service; replace=false)
    end

    if agent.subagents.enable
        resolved_tool_registry === nothing && (resolved_tool_registry = ToolRegistry())

        # Capture references needed by the closure. Skills, MCP tools, and
        # builtin_skill_defs are populated by earlier blocks and may still be
        # empty vectors — that's fine; the closure reads them at spawn time.
        _sub_discovered_skills = discovered_skills
        _sub_builtin_skill_defs = builtin_skill_defs
        _sub_mcp_tool_defs = mcp_tool_defs

        subagent_processor_factory = () -> begin
            sub_registry = ToolRegistry()
            sub_tool_defs = register_builtin_tools!(
                sub_registry;
                workspace=workspace,
                enable_exec=agent.builtin_tools.enable_exec,
                exec_timeout_s=Float64(agent.builtin_tools.exec_timeout_s),
                exec_path_append=agent.builtin_tools.exec_path_append,
                enable_web_search=!_has_provider_search,
                web_search_max_results=agent.builtin_tools.web_search_max_results,
                restrict_to_workspace=agent.builtin_tools.restrict_to_workspace,
                send_message_fn=nothing,  # subagents don't send messages directly
                enable_claude_code=agent.claude_code.enable,
                claude_code_model=agent.claude_code.model,
                claude_code_timeout_s=Float64(agent.claude_code.timeout_s),
                claude_code_max_budget=agent.claude_code.max_budget,
                claude_code_permission_mode=agent.claude_code.permission_mode,
                claude_code_progress_fn=nothing,
                claude_code_progress_interval_s=Float64(agent.claude_code.progress_interval_s),
                enable_codex=agent.codex.enable,
                codex_model=agent.codex.model,
                codex_timeout_s=Float64(agent.codex.timeout_s),
                codex_sandbox_mode=agent.codex.sandbox_mode,
                codex_progress_fn=nothing,
                codex_progress_interval_s=Float64(agent.codex.progress_interval_s),
                enable_google_workspace=agent.enable_google_workspace,
                replace=false,
            )

            # Merge tools: provider-native → builtins → skills → MCP (no spawn, no cron)
            sub_tools = agent.llm_tools
            sub_tools = _merge_tool_items(sub_tools, Any[sub_tool_defs...])
            sub_tools = _merge_tool_items(sub_tools, Any[_sub_builtin_skill_defs...])
            sub_tools = _merge_tool_items(sub_tools, Any[_sub_mcp_tool_defs...])

            # Register MCP tools into subagent registry so dispatch works
            for td in _sub_mcp_tool_defs
                register_tool!(sub_registry, td; replace=true)
            end
            # Register skill tools into subagent registry
            for td in _sub_builtin_skill_defs
                register_tool!(sub_registry, td; replace=true)
            end

            make_llm_processor(provider;
                system_prompt=_subagent_system_prompt(workspace),
                max_context_tokens=agent.max_context_tokens,
                tools=sub_tools,
                tool_registry=sub_registry,
                max_tool_iterations=agent.subagents.max_iterations,
                max_tool_output_chars=agent.max_tool_output_chars,
            )
        end

        subagent_manager = SubagentManager(
            publish_fn=msg -> try_publish_inbound!(hub, msg),
            processor_factory=subagent_processor_factory,
            max_concurrent=agent.subagents.max_concurrent,
            max_iterations=agent.subagents.max_iterations,
        )
        spawn_tool_defs = register_spawn_tools!(resolved_tool_registry, subagent_manager; replace=false)
    end

    if !isempty(agent.mcp_servers)
        resolved_tool_registry === nothing && (resolved_tool_registry = ToolRegistry())
        mcp_connections = connect_mcp_servers!(resolved_tool_registry, agent.mcp_servers; connect_fn=agent.mcp_connect_fn)
        mcp_tool_defs = _mcp_registered_tool_defs(resolved_tool_registry, mcp_connections)
        if !isempty(mcp_connections.failed_servers)
            @warn "MCP server connect failures" failures=mcp_connections.failed_servers
        end
    end

    processor = echo_processor
    before_process = nothing
    after_process = nothing
    cancel_scope = SessionCancelScope()

    if !(provider isa OpenAIProvider || provider isa GeminiProvider || provider isa GeminiOpenAICompatProvider)
        mcp_connections === nothing || (try
            close!(mcp_connections)
        catch e
            @debug "MCP cleanup failed" exception=e
        end)
        throw(ArgumentError("Unsupported llm_provider type: $(typeof(provider))"))
    end

    tools_for_processor = agent.llm_tools
    tools_for_processor = _merge_tool_items(tools_for_processor, Any[builtin_tool_defs...])
    tools_for_processor = _merge_tool_items(tools_for_processor, Any[builtin_skill_defs...])
    tools_for_processor = _merge_tool_items(tools_for_processor, Any[cron_tool_defs...])
    tools_for_processor = _merge_tool_items(tools_for_processor, Any[spawn_tool_defs...])
    tools_for_processor = _merge_tool_items(tools_for_processor, Any[mcp_tool_defs...])
    memory_store_for_processor = if agent.memory.enable
        agent.memory_store === nothing ? MemoryStore(; workspace=data_dir) : agent.memory_store
    else
        nothing
    end

    skills_summary_text = skills_summary(discovered_skills)
    always_skills_text = load_always_skills(discovered_skills)
    system_prompt_for_processor = agent.system_prompt
    instructions_builder = nothing
    if agent.prompt_context.enable
        bootstrap_docs = load_bootstrap_docs(
            workspace;
            doc_names=agent.prompt_context.doc_names,
            max_chars_per_doc=agent.prompt_context.max_chars_per_doc,
        )
        instructions_builder = make_prompt_builder(
            bootstrap_docs=bootstrap_docs,
            skills_summary_text=skills_summary_text,
            always_skills_text=always_skills_text,
            include_runtime_metadata=agent.prompt_context.include_runtime_metadata,
        )
    else
        system_prompt_for_processor = _append_prompt_suffix(
            agent.system_prompt,
            skills_summary_text,
        )
    end

    try
        processor = make_llm_processor(provider;
            system_prompt=system_prompt_for_processor,
            instructions_builder=instructions_builder,
            memory_store=memory_store_for_processor,
            max_context_tokens=agent.max_context_tokens,
            reasoning=agent.llm_reasoning,
            tools=tools_for_processor,
            tool_registry=resolved_tool_registry,
            tool_choice=agent.llm_tool_choice,
            include=agent.llm_include,
            stream=agent.llm_stream,
            parallel_tool_calls=agent.llm_parallel_tool_calls,
            max_output_tokens=agent.llm_max_output_tokens,
            tool_progress=(msg, tool_name, arguments) -> begin
                ch = get(channel_map, msg.channel, nothing)
                ch === nothing && return nothing
                arguments_text = if haskey(arguments, "task")
                    String(arguments["task"])
                elseif haskey(arguments, "command")
                    String(arguments["command"])
                elseif haskey(arguments, "query")
                    String(arguments["query"])
                elseif haskey(arguments, "url")
                    String(arguments["url"])
                elseif haskey(arguments, "chat_id")
                    "chat $(String(arguments["chat_id"]))"
                elseif haskey(arguments, "path")
                    String(arguments["path"])
                else
                    "task arguments"
                end
                if length(arguments_text) > 100
                    arguments_text = arguments_text[1:100] * "…"
                end
                try
                    send_direct(ch, msg.chat_id,
                        "Working on \"$(tool_name)\" for: $(arguments_text)";
                        parse_mode=nothing,
                    )
                catch e
                    @debug "Tool progress notification failed" exception=e
                end
                return nothing
            end,
            max_tool_iterations=agent.max_tool_iterations,
            max_tool_output_chars=agent.max_tool_output_chars,
            allowed_tools=agent.allowed_tools,
            enable_history_summarization=agent.enable_history_summarization,
            history_summarization_max_chars=agent.history_summarization_max_chars,
            stop_check=(msg) -> is_cancelled(cancel_scope, msg.session_key),
            hooks=agent.hooks,
            retry=agent.retry,
        )

        if memory_store_for_processor !== nothing && agent.memory.enable_consolidation
            after_process = make_memory_consolidator(
                provider,
                memory_store_for_processor;
                unconsolidated_token_threshold=agent.memory.consolidation_threshold_tokens,
                max_output_tokens=agent.memory.consolidation_max_output_tokens,
                max_input_turn_chars=agent.memory.consolidation_max_turn_chars,
                max_consolidation_turns=agent.memory.consolidation_max_turns,
                max_failures=agent.memory.consolidation_max_failures,
            )
        end
    catch _
        mcp_connections === nothing || (try
            close!(mcp_connections)
        catch e
            @debug "MCP cleanup failed during error recovery" exception=e
        end)
        rethrow()
    end

    _subagent_mgr = subagent_manager
    _agent_hooks = agent.hooks
    before_process = (msg, history) -> begin
        ch = get(channel_map, msg.channel, nothing)
        if ch !== nothing
            try
                send_typing(ch, msg.chat_id)
            catch e
                @debug "Typing indicator failed" exception=e
            end
        end
        if _subagent_mgr !== nothing
            set_spawn_context!(msg.channel, msg.session_key, msg.chat_id)
        end
        set_cron_context!(msg.channel, msg.session_key, msg.chat_id)
        if _agent_hooks.on_turn_start !== nothing
            try
                _agent_hooks.on_turn_start(msg, history)
            catch e
                @warn "on_turn_start hook failed" exception=(e, catch_backtrace())
            end
        end
        return nothing
    end

    if _agent_hooks.on_turn_end !== nothing
        _raw_after = after_process
        after_process = (msg, history) -> begin
            _raw_after !== nothing && _raw_after(msg, history)
            try
                _agent_hooks.on_turn_end(msg, history)
            catch e
                @warn "on_turn_end hook failed" exception=(e, catch_backtrace())
            end
        end
    end

    if consumer === nothing
        if store === nothing
            store = SessionStore(; workspace=data_dir)
        end
        consumer = (hub, running) -> run_session_loop!(hub, running;
            store=store,
            processor=processor,
            before_process=before_process,
            after_process=after_process,
            cancel_scope=cancel_scope,
        )
    end

    return RuntimeState(
        hub, manager, channel_states,
        consumer,
        store,
        nothing,
        Ref(false),
        BoundedDedup(dedup_capacity),
        mcp_connections,
        cron_service,
        subagent_manager,
        Ref{Union{Nothing,DateTime}}(nothing),
        last_successful_send_at,
    )
end

# Single-channel convenience: RuntimeState(channel, agent; ...)
function RuntimeState(channel::AbstractChannel, agent::Agent; kwargs...)
    return RuntimeState([channel], agent; kwargs...)
end

# Echo-only runtime (no LLM provider) — shared by flat-kwargs path
function _build_runtime(
    channels::Vector{<:AbstractChannel};
    hub::MessageHubState=MessageHubState(),
    consumer::Union{Nothing,Function}=nothing,
    store::Union{Nothing,SessionStore}=nothing,
    processor::Function=echo_processor,
    dedup_capacity::Int=1000,
    workspace::AbstractString="context",
    data_dir::AbstractString=joinpath(homedir(), ".krill"),
    dead_letter_path::Union{Nothing,AbstractString}=nothing,
    on_dispatch::Union{Nothing,Function}=nothing,
)
    isempty(channels) && throw(ArgumentError("at least one channel is required"))

    resolved_dead_letter_path = dead_letter_path
    if resolved_dead_letter_path === nothing
        resolved_dead_letter_path = joinpath(data_dir, "dead_letters.jsonl")
    end

    manager = ChannelManagerState(hub;
        on_dispatch=on_dispatch,
        dead_letter_path=resolved_dead_letter_path,
    )
    last_successful_send_at = Ref{Union{Nothing,DateTime}}(nothing)

    channel_states = ChannelState[]
    for ch in channels
        name = channel_name(ch)
        cs = register_channel!(manager, ch;
            on_send=() -> (last_successful_send_at[] = now(UTC)),
        )
        push!(channel_states, cs)
    end

    if consumer === nothing
        if store === nothing
            store = SessionStore(; workspace=data_dir)
        end
        consumer = (hub, running) -> run_session_loop!(hub, running;
            store=store,
            processor=processor,
        )
    end

    return RuntimeState(
        hub, manager, channel_states,
        consumer,
        store,
        nothing,
        Ref(false),
        BoundedDedup(dedup_capacity),
        nothing,
        nothing,
        nothing,
        Ref{Union{Nothing,DateTime}}(nothing),
        last_successful_send_at,
    )
end

"""
    start!(rt::RuntimeState) -> rt

Start all channel inbound loops, consumer, and dispatch tasks. No-op if already running.
"""
function start!(rt::RuntimeState)
    rt.running[] && return rt
    rt.running[] = true

    start_dispatch!(rt.manager)

    rt.consumer_task = Threads.@spawn begin
        try
            rt.consumer(rt.hub, rt.running)
        catch e
            e isa InterruptException && return
            @error "consumer task failed" exception=(e, catch_backtrace())
        end
    end

    # Start all channels
    for cs in rt.channel_states
        cs.inbound_task = start_channel!(cs.channel, rt.hub, rt.running;
            dedup=rt.dedup,
            on_message=() -> (rt.last_successful_poll_at[] = now(UTC)),
        )
    end

    if rt.cron_service !== nothing
        Cron.start!(rt.cron_service)
    end

    channel_names = [channel_name(cs.channel) for cs in rt.channel_states]
    @info "Runtime started" channels=channel_names consumer=true dispatch=true
    return rt
end

"""
    shutdown!(rt::RuntimeState) -> rt

Gracefully shut down the runtime. Stops all channel inbound loops first (no new
messages), then waits for the consumer to drain inbound, then stops outbound dispatch.
"""
function shutdown!(rt::RuntimeState)
    if !rt.running[]
        _shutdown_subagents!(rt)
        _shutdown_cron!(rt)
        _shutdown_mcp!(rt)
        return rt
    end
    @info "Runtime shutting down..."
    rt.running[] = false

    # Stop all channel inbound tasks
    for cs in rt.channel_states
        task = cs.inbound_task
        if task !== nothing && !istaskdone(task)
            wait(task)
        end
        cs.inbound_task = nothing
        try
            stop_channel!(cs.channel)
        catch e
            @warn "Failed to stop channel" channel=channel_name(cs.channel) exception=(e, catch_backtrace())
        end
    end

    task = rt.consumer_task
    if task !== nothing && !istaskdone(task)
        wait(task)
    end
    rt.consumer_task = nothing

    _shutdown_subagents!(rt)
    _shutdown_cron!(rt)
    stop_dispatch!(rt.manager)
    _shutdown_mcp!(rt)

    @info "Runtime shutdown complete"
    return rt
end

function _task_alive(task::Union{Nothing,Task})
    task === nothing && return false
    return !istaskdone(task)
end

function _append_prompt_suffix(base_prompt, suffix::AbstractString)
    clean_suffix = strip(String(suffix))
    isempty(clean_suffix) && return base_prompt

    if base_prompt === nothing
        return clean_suffix
    elseif base_prompt isa Function
        return function(session_key)
            base = try
                base_prompt(session_key)
            catch e
                @warn "Dynamic system_prompt function failed, using empty" exception=e
                ""
            end
            text = strip(string(base))
            isempty(text) && return clean_suffix
            return text * "\n\n---\n\n" * clean_suffix
        end
    else
        text = strip(String(base_prompt))
        isempty(text) && return clean_suffix
        return text * "\n\n---\n\n" * clean_suffix
    end
end

function _subagent_system_prompt(workspace::AbstractString)
    return """You are a focused subagent executing a specific task. You have access to file operations, web search, shell exec, GitHub, Google Workspace, MCP tools, and coding agents (claude_code, codex).

Rules:
- Complete the assigned task thoroughly and report your findings clearly.
- Be concise but complete in your final response.
- Use the provider's built-in web search for research. If results are insufficient, delegate deeper research to claude_code or codex.
- You cannot spawn further subagents, send messages, or schedule cron jobs.
- Working directory: $(workspace)"""
end

function _shutdown_subagents!(rt::RuntimeState)
    mgr = rt.subagent_manager
    mgr === nothing && return nothing
    running = subagent_count(mgr; running_only=true)
    running == 0 && return nothing
    try
        # Cancel all running subagent tasks across all sessions
        for (session_key, _) in mgr.session_tasks
            cancel_subagents!(mgr, session_key)
        end
        @info "Cancelled running subagents during shutdown" count=running
    catch e
        @warn "Failed to cancel subagents during shutdown" exception=(e, catch_backtrace())
    end
    return nothing
end

function _shutdown_cron!(rt::RuntimeState)
    svc = rt.cron_service
    svc === nothing && return nothing
    try
        Cron.stop!(svc)
    catch e
        @warn "Failed to stop cron service during shutdown" exception=(e, catch_backtrace())
    end
    return nothing
end

function _shutdown_mcp!(rt::RuntimeState)
    set = rt.mcp_connections
    set === nothing && return nothing
    try
        close!(set)
    catch e
        @warn "Failed to close MCP connections during shutdown" exception=(e, catch_backtrace())
    end
    rt.mcp_connections = nothing
    return nothing
end

"""
    channels(rt::RuntimeState) -> Vector{AbstractChannel}

Return all registered channels.
"""
channels(rt::RuntimeState) = [cs.channel for cs in rt.channel_states]

"""
    get_channel(rt::RuntimeState, name::Symbol) -> Union{AbstractChannel, Nothing}

Look up a registered channel by name.
"""
function get_channel(rt::RuntimeState, name::Symbol)
    for cs in rt.channel_states
        channel_name(cs.channel) == name && return cs.channel
    end
    return nothing
end

function status(rt::RuntimeState)
    last_send_at = rt.last_successful_send_at[] === nothing ?
        rt.manager.last_successful_send_at :
        rt.last_successful_send_at[]
    mcp_set = rt.mcp_connections
    mcp_connected = mcp_set === nothing ? 0 : length(mcp_set.clients)
    mcp_failed = mcp_set === nothing ? 0 : length(mcp_set.failed_servers)

    channel_status = Dict{String,Any}()
    for cs in rt.channel_states
        name = string(channel_name(cs.channel))
        channel_status[name] = Dict{String,Any}(
            "inbound_alive" => _task_alive(cs.inbound_task),
        )
    end

    ds = dispatch_stats(rt.manager)

    return Dict{String,Any}(
        "running" => rt.running[],
        "channels" => channel_status,
        "polling_alive" => any(cs -> _task_alive(cs.inbound_task), rt.channel_states),
        "consumer_alive" => _task_alive(rt.consumer_task),
        "dispatch_alive" => _task_alive(rt.manager.dispatch_task),
        "inbound_queue_depth" => Base.n_avail(rt.hub.inbound),
        "outbound_queue_depth" => Base.n_avail(rt.hub.outbound),
        "last_successful_poll_at" => rt.last_successful_poll_at[],
        "last_successful_send_at" => last_send_at,
        "dispatch_delivered" => ds["delivered"],
        "dispatch_failed" => ds["failed"],
        "dispatch_dropped" => ds["dropped"],
        "dispatch_dead_letters" => ds["dead_letters"],
        "dispatch_pending" => ds["pending"],
        "mcp_connected_servers" => mcp_connected,
        "mcp_failed_servers" => mcp_failed,
        "cron_enabled" => rt.cron_service !== nothing,
        "cron_job_count" => rt.cron_service === nothing ? 0 : length(rt.cron_service.jobs),
        "subagents_enabled" => rt.subagent_manager !== nothing,
        "subagents_total" => rt.subagent_manager === nothing ? 0 : subagent_count(rt.subagent_manager),
        "subagents_running" => rt.subagent_manager === nothing ? 0 : subagent_count(rt.subagent_manager; running_only=true),
    )
end

end
