# Repository Guidelines

## Purpose
- This file is the root onboarding guide for Codex and other coding agents working in this repository.
- Prefer reading the current code over inferring architecture from stale comments. `src/Krill.jl` is the authoritative include order for the package.
- Treat this repo as a Julia-native agent runtime, not a thin bot wrapper: most changes touch prompt assembly, tool dispatch, persistence, or channel/runtime wiring.

## Start Here
- `README.md` explains the product surface and top-level config shape.
- `src/Krill.jl` shows module load order and public exports.
- `src/runtime.jl` shows how channels, session processing, tools, MCP, cron, memory, and subagents are wired into `RuntimeState`.
- `src/agent.jl` defines the configuration surface that feature work usually extends: `MemoryConfig`, `BuiltinToolsConfig`, `SkillsConfig`, `ClaudeCodeConfig`, `CodexConfig`, `PromptContextConfig`, `SubagentConfig`, and `RetryConfig`.
- `src/prompt_context.jl` shows how system instructions are composed from bootstrap docs, skill metadata, always-on skills, session memory, global memory, tool-safety guidance, and runtime metadata.
- `test/runtests.jl` is the map of what the suite actually covers.

## Architecture Map
- `bin/krill.jl` is the runtime entry point.
- `src/Krill.jl` is the package entry point and include-order source of truth. Include order matters in this codebase.
- `src/transport/` owns normalized message types and queueing:
  - `types.jl`
  - `message_hub.jl`
  - `manager.jl`
  - `dedup.jl`
  - `channels.jl`
  - `durable_queue.jl`
- `src/sessions/` owns persistence and long-lived conversation state:
  - `sessions.jl` for history persistence
  - `memory.jl` for session memory files
  - `memory_consolidation.jl` for LLM-driven session-memory summarization
  - `global_memory.jl` for user-wide cross-session memory
  - `consumer.jl` for per-session FIFO processing and cancellation
  - `echo.jl` for the non-LLM processor path
- `src/tools/` owns the tool system:
  - `registry.jl` for `ToolDef`, `ToolRegistry`, and dispatch
  - `skills.jl` for workspace and builtin `SKILL.md` discovery
  - `mcp.jl` for MCP client registration and namespacing
  - `builtin/` for local tools: file, web, shell, GitHub, Google Workspace, cron, message, Claude Code, and Codex
- `src/llm/` owns provider integration and the tool loop:
  - `providers.jl`, `api.jl`, `chat_completion.jl`
  - `parsing.jl` for provider payload conversion
  - `tool_loop.jl` for iterative tool execution
  - `processor.jl` for session processor construction
  - `context.jl` and `llm.jl` for provider-facing assembly
- `src/scheduling/` owns background execution:
  - `cron.jl`
  - `subagent.jl`
- `src/channels/` owns Telegram and Discord adapters.
- `src/config/` owns config parsing, environment expansion, provider creation, MCP config, and channel construction.
- `src/runtime.jl` wires everything together into `RuntimeState`.

## Runtime Flow
- Inbound channel payloads are normalized into `InboundMessage`.
- `BoundedDedup` suppresses repeat deliveries before they hit the hub.
- `MessageHubState` feeds the session consumer.
- `run_session_loop!` enforces per-session FIFO while allowing concurrent sessions.
- The processor is either echo or an LLM-backed processor from `make_llm_processor`.
- LLM turns may call local builtins, MCP tools, cron tools, Claude Code, or Codex through the tool loop.
- Turn history is persisted to the session store, and outbound messages are dispatched through `ChannelManagerState`.
- Cron jobs inject synthetic inbound messages; subagents run background tasks with their own bounded iteration limits.

## Prompt And Memory Model
- Prompt composition lives in `src/prompt_context.jl`; do not collapse it back into one static prompt string.
- Bootstrap docs are loaded from the workspace in this order: `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`.
- Missing bootstrap docs are skipped, not treated as errors.
- Skills come from `context/skills/` plus optional builtin skill directories. Workspace skills override builtin skills with the same name.
- Skills with `always: true` frontmatter are injected into every turn if their requirements are met.
- The composed instruction stack can include:
  - base system prompt
  - workspace bootstrap docs
  - available-skills summary
  - always-on skill content
  - global user memory
  - per-session memory
  - tool-output safety guidance
  - runtime metadata such as UTC timestamp, channel, session key, chat id, and user id
- Session history persists under `<data_dir>/sessions/<session>/history.jsonl`.
- Session memory persists under `<data_dir>/memory/<session>/` as `MEMORY.md`, `HISTORY.md`, and `state.json`.
- Global memory persists under `<data_dir>/global_memory/<user_id>/MEMORY.md`.
- Cron jobs persist under `<data_dir>/cron/jobs.json`.
- Dead letters persist under `<data_dir>/dead_letters.jsonl`.

## Project Structure And Files To Touch
- Add or change tool behavior in `src/tools/builtin/*.jl` and check registration in `src/tools/builtin/registration.jl`.
- Add MCP behavior in `src/tools/mcp.jl`. MCP tools are namespaced as `mcp_<server>_<tool>`.
- Add provider behavior in `src/llm/providers.jl`, `src/llm/parsing.jl`, `src/llm/chat_completion.jl`, and corresponding runtime tests.
- Add prompt or instruction behavior in `src/prompt_context.jl` and `test/test_prompt_context.jl`.
- Add memory behavior in `src/sessions/memory.jl`, `src/sessions/memory_consolidation.jl`, `src/sessions/global_memory.jl`, and runtime-memory tests.
- Add cron or subagent behavior in `src/scheduling/cron.jl` or `src/scheduling/subagent.jl` plus their focused tests.
- Add channel behavior in `src/channels/telegram.jl` or `src/channels/discord.jl` plus normalization, webhook, and connector tests.
- Add config surface area in `src/config/config.jl`, `src/config/provider.jl`, `src/config/mcp_config.jl`, or `src/config/channels_config.jl`.

## Build, Test, And Development Commands
- `julia --project=. -e 'using Pkg; Pkg.instantiate()'`
  Install project dependencies.
- `julia --project=. --threads=auto bin/krill.jl`
  Run the main agent using repository `krill.toml`.
- `julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml`
  Run with an explicit config path.
- `bash scripts/test.sh`
  Preferred full-suite command. Runs `Pkg.test()` and removes macOS `._*` artifacts on exit.
- `bash scripts/test_fast.sh`
  Fast local iteration path with `KRILL_FAST_TESTS=1`.
- `bash scripts/test_channels.sh`
- `bash scripts/test_tools_mcp.sh`
- `bash scripts/test_skills.sh`
- `bash scripts/test_cron.sh`
- `bash scripts/test_subagent.sh`
- `bash scripts/test_dispatch.sh`
- `bash scripts/test_claude_code.sh`
  Focused wrappers for subsystem work.
- `julia --project=. test/test_<name>.jl`
  Works for many focused files, but some tests assume imports from `test/runtests.jl`.
- `julia --project=. -e 'using Krill; using Test; using UUIDs; using Dates; include("test/test_types.jl")'`
  Safer pattern for single-file execution when a test relies on shared imports.
- `julia --project=docs docs/make.jl`
  Build docs.
- `npm --prefix docs run docs:dev`
  Run local docs preview.

## Test Map
- `test/runtests.jl` includes the full suite and shared imports.
- Core transport coverage:
  - `test/test_types.jl`
  - `test/test_message_hub.jl`
  - `test/test_durable_queue.jl`
- Channel coverage:
  - `test/test_telegram_connector.jl`
  - `test/test_normalize.jl`
  - `test/test_channels.jl`
  - `test/test_webhook.jl`
- Runtime and provider coverage:
  - `test/test_runtime.jl`
  - `test/test_openai.jl`
  - `test/test_gemini.jl`
  - `test/test_runtime_openai.jl`
  - `test/test_runtime_gemini.jl`
  - `test/test_runtime_sessions.jl`
  - `test/test_runtime_memory.jl`
- Session and memory coverage:
  - `test/test_sessions.jl`
  - `test/test_memory.jl`
  - `test/test_session_consumer.jl`
  - `test/test_global_memory.jl`
- Tool and prompt coverage:
  - `test/test_builtin_tools.jl`
  - `test/test_tools_mcp.jl`
  - `test/test_prompt_context.jl`
  - `test/test_skills.jl`
  - `test/test_claude_code.jl`
  - `test/test_subagent.jl`
  - `test/test_cron.jl`
  - `test/test_dispatch.jl`
- Safety and regression coverage:
  - `test/test_context_window.jl`
  - `test/test_security.jl`
  - `test/test_gap_fixes.jl`
- Code quality:
  - Aqua runs from `test/runtests.jl`.

## Coding Style And Naming Conventions
- Use 4-space indentation and no tabs.
- Julia naming:
  - `UpperCamelCase` for modules and types
  - `snake_case` for functions, variables, and files
- Mutating functions should use a `!` suffix.
- Keep JSON and provider payload boundaries as `Dict{String,Any}` unless there is a strong reason not to.
- Prefer small helpers around prompt assembly, provider mapping, persistence, and tool dispatch rather than large monolithic functions.
- Validate boundary inputs with `ArgumentError` and keep fallback behavior explicit.
- Extend grouped agent config structs before adding new flat runtime flags.
- Preserve include ordering when moving code across files; this package is assembled by `include`, not by isolated modules with automatic load resolution.

## Working Safely In This Repo
- Check `git status --short` before editing. The worktree may be dirty.
- Never revert unrelated local changes unless the user explicitly asks.
- macOS metadata files like `._*` may appear; `scripts/test.sh` cleans them up.
- Mock HTTP, WebSocket, subprocess, and MCP boundaries in tests. Do not rely on live external services.
- Prefer `mktempdir()` or explicit temporary `workspace=` and `data_dir=` values in tests instead of writing into repository `context/`.
- When changing prompt construction or memory behavior, verify both direct unit tests and runtime tests. Those regressions often only show up once components are wired together.

## Security And Configuration Tips
- Never commit secrets; keep API keys only in `.env`.
- Common env vars:
  - `TELEGRAM_BOT_TOKEN`
  - `DISCORD_BOT_TOKEN`
  - `OPENAI_API_KEY`
  - `GEMINI_API_KEY`
  - `GH_PAT`
  - `KRILL_DATA_DIR`
- `krill.toml` supports `$VAR` and `${VAR}` interpolation through `load_config`.
- At least one channel must be enabled in config.
- Provider-native tools are controlled by `[profile.tools].provider_builtins`.
- When provider-native search is enabled, the local DuckDuckGo-style `web_search` is intentionally not registered; `web_fetch` still is.
- If file tools are enabled, prefer `llm.builtin_restrict_to_workspace = true` unless cross-directory access is a conscious requirement.
- Codex delegation is controlled through `[profile.tools].codex` and related Codex config in `Agent`.

## Change Readiness
- Add regression tests for every behavior change.
- A change touching tools, prompt context, channels, runtime wiring, persistence, or provider payload mapping is not complete without tests.
- The default merge bar is `bash scripts/test.sh` passing.
