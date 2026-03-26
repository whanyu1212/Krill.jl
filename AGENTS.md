# Repository Guidelines

## Project Structure & Module Organization
- `bin/krill.jl` is the runtime entry point.
- `src/Krill.jl` is the package entry point — includes all submodules directly (no `Core` wrapper).
- `src/transport/` — message plumbing (`types.jl`, `message_hub.jl`, `manager.jl`, `dedup.jl`, `channels.jl`, `durable_queue.jl`)
- `src/sessions/` — persistence (`sessions.jl`, `memory.jl`, `memory_consolidation.jl`, `consumer.jl`, `echo.jl`)
- `src/tools/` — tool system (`registry.jl`, `skills.jl`, `mcp.jl`, `builtin/` with file/web/shell/github/google/claude_code/codex/message/cron tools + registration)
- `src/scheduling/` — cron and subagents (`cron.jl`, `subagent.jl`)
- `src/llm/` — LLM providers (`providers.jl`, `api.jl`, `context.jl`, `parsing.jl`, `chat_completion.jl`, `tool_loop.jl`, `processor.jl`)
- `src/agent.jl` + `src/prompt_context.jl` — agent config and prompt composition (top-level)
- `src/config/` — config loading and runtime wiring
- `src/channels/` includes Telegram (polling + webhook) and Discord integrations.
- `src/runtime.jl` wires channels, tool registries, prompt context, MCP, cron, subagents, memory, and LLM processors into `RuntimeState`.
- `context/` is the prompt workspace (`AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `skills/`).
- `test/` includes `runtests.jl` plus focused subsystem files such as `test_runtime_openai.jl`, `test_runtime_gemini.jl`, `test_tools_mcp.jl`, `test_cron.jl`, `test_subagent.jl`, `test_dispatch.jl`, `test_claude_code.jl`, `test_context_window.jl`, and `test_security.jl`.
- `scripts/` includes full, fast, and focused test wrappers plus deployment/sysimage helpers (`deploy.sh`, `setup_gcp.sh`, `build_sysimage.jl`).
- `docs/` contains Documenter + DocumenterVitepress sources; `notes/` holds design notes and roadmap material.
- Runtime state is written under `data_dir` (default `~/.krill`): sessions, memory, cron state, and dead letters are generated data, not source.

## Build, Test, and Development Commands
- `julia --project=. -e 'using Pkg; Pkg.instantiate()'`  
  Install project dependencies.
- `julia --project=. --threads=auto bin/krill.jl`  
  Run the main agent using repository `krill.toml`.
- `julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml`  
  Run with an explicit config path.
- `bash scripts/test.sh`  
  Preferred full-suite command; runs `Pkg.test()` and removes macOS `._*` artifacts on exit.
- `bash scripts/test_fast.sh`  
  Runs the suite with `KRILL_FAST_TESTS=1` for faster local iteration.
- `bash scripts/test_channels.sh`, `bash scripts/test_tools_mcp.sh`, `bash scripts/test_skills.sh`, `bash scripts/test_cron.sh`, `bash scripts/test_subagent.sh`, `bash scripts/test_dispatch.sh`, `bash scripts/test_claude_code.sh`  
  Focused wrappers for subsystem iteration.
- `julia --project=. test/test_<name>.jl`  
  Run an individual test file directly.
- `julia --project=docs docs/make.jl` and `npm --prefix docs run docs:dev`  
  Build and preview docs.

## Coding Style & Naming Conventions
- Use 4-space indentation; no tabs.
- Julia naming: `UpperCamelCase` for modules/types, `snake_case` for functions/variables/files.
- Mutating functions should use `!` suffix (`register_tool!`, `append_turn!`, `save_jobs!`).
- Keep provider, tool, and channel payload keys as `String` keys (`Dict{String,Any}`) at JSON/API boundaries.
- Prefer small, composable helpers around payload mapping, prompt assembly, persistence, and tool dispatch so HTTP/process boundaries stay easy to mock.
- Validate boundary inputs with `ArgumentError`, and keep fallback behavior explicit when handling provider/channel failures.
- Prefer extending grouped `Agent` configs (`MemoryConfig`, `BuiltinToolsConfig`, `PromptContextConfig`, etc.) over adding loosely scoped runtime flags.

## Testing Guidelines
- Use `@testset` blocks named by subsystem or feature area (e.g., `Krill.jl OpenAI provider`).
- Add regression tests for every behavior change, especially in tool dispatch, provider payload mapping, prompt composition, persistence, channel normalization, and context-window handling.
- Mock HTTP, WebSocket, and subprocess boundaries in tests; do not rely on live network services or installed MCP servers.
- When tests write runtime state, prefer `mktempdir()` or explicit temporary `workspace=` / `data_dir=` paths over repository `context/`.
- Use `KRILL_FAST_TESTS=1` when iterating locally, but run the full suite before merging.
- A change is ready when `bash scripts/test.sh` passes.

## Commit & Pull Request Guidelines
- Commit messages should be short, imperative, and descriptive (e.g., `Add Telegram webhook dead-letter coverage`).
- PRs should include:
  - What changed and why.
  - Key files touched.
  - Test evidence (command + result).
  - Any env/config changes (`.env`, `krill.toml`, MCP/tool flags) and backward-compatibility notes.

## Security & Configuration Tips
- Never commit secrets; keep API keys only in `.env`.
- Common vars: `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GH_PAT`, `KRILL_DATA_DIR`.
- `krill.toml` supports `$VAR` / `${VAR}` interpolation and profile-scoped tool/MCP configuration via `load_config`.
- Provider-native tools are controlled by `[profile.tools].provider_builtins`; when enabled, local DuckDuckGo `web_search` is intentionally disabled.
- If file tools are enabled, prefer `llm.builtin_restrict_to_workspace = true` unless cross-directory access is explicitly required.

## Prompt Context Notes
- Prompt composition is implemented in `src/prompt_context.jl` and wired from `RuntimeState`; extend the composed builder instead of collapsing back to one static prompt string.
- Bootstrap docs are loaded from the workspace in order `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`; missing files are skipped.
- Skills support both discovery-on-demand (`read_skill`) and always-on injection via `always: true` frontmatter plus availability checks (`requires_bins`, `requires_env`).
- Session history persists under `<data_dir>/sessions/<session>/history.jsonl`.
- Session memory persists under `<data_dir>/memory/<session>/` as `MEMORY.md`, `HISTORY.md`, and `state.json`, with LLM-driven consolidation in `src/sessions/memory_consolidation.jl`.
- Cron jobs persist under `<data_dir>/cron/jobs.json`; outbound dead letters persist under `<data_dir>/dead_letters.jsonl`.
- MCP tools are namespaced as `mcp_<server>_<tool>` via `src/tools/mcp.jl`.
