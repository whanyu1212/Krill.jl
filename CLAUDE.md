# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Krill.jl

A Julia-native, channel-agnostic AI agent runtime. It connects LLM providers (OpenAI, Gemini) to messaging channels (Telegram, Discord) with tool calling, persistent memory, cron scheduling, MCP integration, and subagent delegation.

## Commands

```bash
# Install dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run the agent
julia --project=. --threads=auto bin/krill.jl

# Run full test suite
julia --project=. -e 'using Pkg; Pkg.test()'

# Fast offline tests (no API calls)
KRILL_FAST_TESTS=1 julia --project=. -e 'using Pkg; Pkg.test()'

# Run a single test file (tests require these imports from runtests.jl)
julia --project=. -e 'using Krill; using Test; using UUIDs; using Dates; include("test/test_types.jl")'

# Some tests also need: using Krill.Telegram: HTTP, JSON3
```

## Architecture

### Message Flow

```
Channel (Telegram/Discord)
  → normalize_update() → InboundMessage
  → BoundedDedup → MessageHub.inbound_queue
  → SessionConsumer (per-session FIFO, concurrent across sessions)
  → Processor (echo or LLM)
  → LLM tool loop (call → dispatch → repeat, max 10 iterations)
  → SessionStore (persist turn history)
  → MessageHub.outbound_queue
  → ChannelManager → send_message()
```

### Key Modules

- **`src/runtime.jl`** — `RuntimeState` wires hub, channels, consumer, store, cron, MCP, subagents. `start!()` boots everything, `shutdown!()` tears down.
- **`src/core/agent.jl`** — `Agent` struct groups all config. `AgentHooks` provides callbacks (`on_tool_call`, `on_tool_result`, `should_interrupt`). Nested config structs: `MemoryConfig`, `BuiltinToolsConfig`, `SkillsConfig`, etc.
- **`src/core/llm/`** — LLM abstraction layer:
  - `providers.jl` — `OpenAIProvider` (Responses API), `GeminiProvider` (native), `GeminiOpenAICompatProvider`
  - `tool_loop.jl` — Agentic loop with tool dispatch, caching, truncation, retry
  - `parsing.jl` — Converts between OpenAI and Gemini formats (tool schemas, responses)
  - `processor.jl` — `make_llm_processor()` factory creates the session processor function
- **`src/core/types.jl`** — `InboundMessage`, `OutboundMessage`, `ContentPart` variants, `ToolCallEvent`/`ToolResultEvent`, `ErrorEnvelope`
- **`src/core/tools.jl`** — `ToolDef` (JSON schema + execute fn), `ToolRegistry`, `dispatch_tool()`
- **`src/core/builtin_tools/`** — All built-in tool implementations. `registration.jl` registers them into the registry.
- **`src/core/cron.jl`** — `CronService` runs a background tick loop, fires due jobs by injecting synthetic `InboundMessage` into the hub. Three schedule types: `AtSchedule`, `IntervalSchedule`, `CronSchedule`.
- **`src/core/mcp.jl`** — MCP client (stdio/HTTP transports). Tools registered as `{server}_{tool}` to avoid collisions.
- **`src/core/skills.jl`** — Discovers `SKILL.md` files from `context/skills/`. Skills with `always: true` in frontmatter are auto-injected into every system prompt.
- **`src/config/config.jl`** — `load_config()` parses `krill.toml`, expands `$ENV_VAR` references from environment or `.env`.

### Configuration

All config in `krill.toml`. Key sections:
- `[provider]` — LLM provider (`openai` or `gemini`), model, API key
- `[telegram]`/`[discord]` — Channel config with `allow_from` ACL
- `[profile]` — System prompt and `[profile.tools]` toggles (exec, cron, memory, claude_code, codex, etc.)
- `[[profile.mcp]]` — MCP server connections (stdio or HTTP)
- Secrets use `$VAR` syntax, expanded from env or `.env` at startup

### Context Workspace (`context/`)

- `SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md` — Bootstrap docs injected into system prompt
- `skills/*/SKILL.md` — Domain-specific instructions with frontmatter metadata

### Provider-Native vs Local Tools

When `provider_builtins = true` in config, native search (OpenAI `web_search` / Gemini `googleSearch`) is used. The local DuckDuckGo `web_search` tool is automatically disabled when provider builtins are available. `web_fetch` (URL fetching) is always registered regardless.

### Persistence

- Session history, memory, cron jobs stored under `data_dir` (default `~/.krill`)
- Cron jobs persisted to `{data_dir}/cron/jobs.json`
- Memory stored as `{data_dir}/memory/{session_key}.json`

## Code Conventions

- Julia 1.12+, minimal external dependencies (HTTP.jl, JSON3.jl, TOML)
- Structs use keyword constructors with defaults
- Thread safety via `ReentrantLock` on shared state (hub queues, session store, cron jobs)
- Tool results truncated to `max_tool_output_chars` (default 8000)
- `ToolCallEvent`/`ToolResultEvent` with `correlation_id` link call→result pairs
- `ErrorEnvelope` classifies errors: `E_PERMISSION_DENIED`, `E_TIMEOUT`, `E_NOT_FOUND`, `E_EXECUTION`
- Cooperative cancellation via `SessionCancelScope` (atomic flag checked between tool iterations)
