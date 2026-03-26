# API Reference

This page is a curated entry point into the public API. For higher-level behavior and composition, start with the guide pages first.

```@meta
CurrentModule = Krill
```

## Agent

```@docs
Krill.Agent
Krill.AgentHooks
Krill.RetryConfig
```

## Runtime

```@docs
Krill.RuntimeState
Krill.start!
Krill.shutdown!
```

## Message Contracts

```@docs
Krill.ContentPart
Krill.TextPart
Krill.BinaryPart
Krill.ToolCallPart
Krill.ToolResultPart
Krill.DeliveryPolicy
Krill.ErrorEnvelope
Krill.InboundMessage
Krill.OutboundMessage
Krill.ToolCallEvent
Krill.ToolResultEvent
Krill.message_text
```

## Queues and Dispatch

```@docs
Krill.MessageHubState
Krill.publish_inbound!
Krill.publish_outbound!
Krill.try_publish_inbound!
Krill.try_publish_outbound!
Krill.take_inbound!
Krill.take_outbound!
Krill.try_take_inbound!
Krill.try_take_outbound!
Krill.ChannelManagerState
Krill.DispatchEvent
Krill.register_sender!
Krill.start_dispatch!
Krill.stop_dispatch!
Krill.dispatch_stats
Krill.dead_letters
Krill.flush_dead_letters!
Krill.BoundedDedup
Krill.seen!
Krill.has_seen
```

## Channels

```@docs
Krill.AbstractChannel
Krill.ChannelState
Krill.channel_name
Krill.make_sender
Krill.normalize
Krill.register_channel!
Krill.make_inbound_handler
Krill.start_channel!
Krill.stop_channel!
Krill.send_typing
Krill.send_direct
Krill.TelegramClient
Krill.TelegramAPIError
Krill.TelegramChannel
Krill.TelegramWebhookChannel
Krill.get_updates
Krill.send_message
Krill.send_chat_action
Krill.set_webhook
Krill.delete_webhook
Krill.run_polling
Krill.make_telegram_sender
Krill.DiscordChannel
Krill.discord_send_message
Krill.discord_trigger_typing
```

## Sessions and Memory

```@docs
Krill.TurnRecord
Krill.SessionStore
Krill.get_session_lock!
Krill.load_history
Krill.append_turn!
Krill.save_history
Krill.session_dir
Krill.sanitize_session_key
Krill.MemoryState
Krill.MemoryStore
Krill.memory_dir
Krill.load_memory
Krill.save_memory!
Krill.append_history!
Krill.load_memory_state
Krill.save_memory_state!
Krill.SessionCancelScope
Krill.request_cancel!
Krill.is_cancelled
Krill.clear_cancel!
Krill.run_session_loop!
Krill.echo_processor
Krill.MemoryConsolidatorConfig
Krill.consolidate_session_memory!
Krill.make_memory_consolidator
```

## Tools and Skills

```@docs
Krill.ToolDef
Krill.SkillDef
Krill.load_always_skills
Krill.register_builtin_tools!
```

## Prompt Context

```@docs
Krill.BootstrapDoc
Krill.load_bootstrap_docs
Krill.render_runtime_metadata
Krill.compose_instructions
Krill.make_prompt_builder
```

## LLM Providers

```@docs
Krill.AbstractLLMProvider
Krill.OpenAIProvider
Krill.OpenAIAPIError
Krill.GeminiProvider
Krill.GeminiOpenAICompatProvider
Krill.LLMUsage
Krill.LLMToolCall
Krill.LLMResponse
Krill.chat_completion
Krill.make_llm_processor
```

## MCP

```@docs
Krill.MCPServer
```

## Cron

```@docs
Krill.CronJob
Krill.CronService
Krill.add_job!
Krill.remove_job!
Krill.list_jobs
Krill.get_job
Krill.is_due
Krill.parse_schedule
Krill.parse_cron
Krill.save_jobs!
Krill.load_jobs!
```

## Subagents

```@docs
Krill.SubagentTask
Krill.SubagentManager
Krill.spawn_subagent!
Krill.cancel_subagents!
Krill.list_subagents
Krill.subagent_count
Krill.register_spawn_tools!
```

## Durable Queue

```@docs
Krill.DurableQueueState
Krill.enqueue!
Krill.ack!
Krill.replay
Krill.compact!
Krill.queue_stats
```
