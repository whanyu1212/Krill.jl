# Configuration

Krill configuration is layered: `krill.toml` for durable project defaults, `.env` for secrets, and environment variables for ad hoc overrides.

| File | Purpose |
| --- | --- |
| `krill.toml` | Provider, profiles, tool toggles, MCP servers |
| `.env` | Secrets and machine-local values |
| `context/` | Agent file sandbox — bootstrap docs and skills (committed to git) |
| `~/.krill/` | Runtime state — sessions, memory, cron, dead letters (machine-local) |


## `krill.toml`

Which channels start is controlled entirely by `krill.toml` — no code change needed. Set `enabled = true` on any channel and it is picked up automatically when you run `bin/krill.jl`.

```toml
# LLM provider
[provider]
name    = "openai"              # "openai" or "gemini"
model   = "gpt-5.4"
api_key = "$OPENAI_API_KEY"     # or set in .env

# Channels — enable as many as you need
[telegram]
enabled    = true
bot_token  = "$TELEGRAM_BOT_TOKEN"
allow_from = ["*"]              # Telegram user IDs, or "*" for everyone

[discord]
enabled    = false
bot_token  = "$DISCORD_BOT_TOKEN"
allow_from = ["*"]

# Runtime paths
[llm]
workspace                     = "context"
data_dir                      = "$KRILL_DATA_DIR"   # defaults to ~/.krill
builtin_restrict_to_workspace = false

# Agent identity and tool toggles
[profile]
system_prompt = """You are Krill — a personal AI assistant. \
Your personality is in SOUL.md, tool rules in AGENTS.md, \
per-tool docs in TOOLS.md. Follow those documents."""

[profile.tools]
provider_builtins    = true     # provider web search + code interpreter
local_builtins       = true
builtin_skills       = true
memory               = true
memory_consolidation = true
cron                 = true
subagents            = true
exec                 = false
claude_code          = false
claude_code_model    = "sonnet"
codex                = false
codex_model          = ""
google_workspace     = false
clawhub              = false    # ClawHub skill registry
history_summarization = false

# MCP servers (add as many blocks as needed)
[[profile.mcp]]
name      = "filesystem"
transport = "stdio"
command   = "npx"
args      = ["-y", "@modelcontextprotocol/server-filesystem", "context"]
```

Token values beginning with `$` are expanded from the environment at startup, so secrets stay in `.env` and `krill.toml` can be safely version-controlled (without the tokens).


## Environment Variables

The recommended approach is to keep tokens in `.env` and reference them from `krill.toml` as `"$VAR_NAME"`. Environment variables are expanded at startup.

| Variable | Meaning |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `OPENAI_API_KEY` | OpenAI provider key |
| `GEMINI_API_KEY` | Gemini provider key |


## Tools

Krill exposes two tool classes simultaneously.

### Provider-native tools

Run on the provider's infrastructure. Pass them through via `provider_builtins = true`.

| Provider | Tools |
| --- | --- |
| OpenAI | `web_search`, `code_interpreter` |
| Gemini | `googleSearch`, `urlContext`, `codeExecution` |

OpenAI `web_search` and Gemini `googleSearch` return clean, cited results. Set `provider_builtins = true` for most bots. If native search returns poor results, the agent can delegate deeper research to `claude_code` or `codex`.

### Krill local tools

Implemented by Krill and registered in a local `ToolRegistry`.

| Tool | Description |
| --- | --- |
| `read_file`, `write_file`, `edit_file`, `list_dir` | File operations within the context directory |
| `web_fetch` | Fetch a specific URL as markdown |
| `github` | Wraps the `gh` CLI |
| `google_workspace` _(optional)_ | Wraps the `gws` CLI for Gmail, Calendar, Drive |
| `exec` _(optional)_ | Shell commands — disabled by default |
| `claude_code` _(optional)_ | Delegate to Claude Code CLI |
| `codex` _(optional)_ | Delegate to OpenAI Codex CLI |
| `cron_add/list/remove` | Schedule management when cron is enabled |
| `spawn/spawn_list/spawn_cancel` | Subagent management when subagents are enabled |
| `clawhub_search/install/remove/list` _(optional)_ | ClawHub skill registry — search, install with validation, manage |

`claude_code` and `codex` run their own internal search and file pipelines. Enable them when the task involves multi-step research or code changes across multiple files.

**Recommended tool combinations**

| Use case | Setup |
| --- | --- |
| General assistant with web search | `provider_builtins = true`, `local_builtins = true` |
| File-focused agent, no web search | `provider_builtins = false`, `local_builtins = true` |
| Research or coding tasks | `claude_code` or `codex` + provider tools |
| Minimal / echo bot | Both off; pass tools explicitly via `llm_tools` |


## MCP Servers

Connect external tool servers via stdio or HTTP. MCP tools are namespaced as `mcp_<name>_<tool>`.

MCP is the right choice for tools not in Krill's built-ins: database queries, calendar APIs, custom business systems. For plain file access, the built-in file tools are simpler.

### Transports

| Transport | When to use |
| --- | --- |
| `stdio` | Local process (`npx`, `uvx`, etc.) — most common |
| `streamable_http` | Remote HTTP MCP server — prefer over `sse` for new servers |
| `sse` | Legacy HTTP+SSE — use only if the server doesn't support streamable HTTP |
| `auto` | Infer from config: stdio if `command` set, HTTP if `url` set |

### Fields

| Field | Meaning |
| --- | --- |
| `name` | Server name — used in tool IDs (`mcp_<name>_<tool>`) |
| `command` / `args` | Stdio server command |
| `url` | HTTP server URL |
| `headers` | Extra HTTP headers (e.g. `Authorization`) |
| `enabled_tools` | Tool allowlist — `["*"]` for all, `[]` for none |
| `request_timeout_s` | Timeout for initialization |
| `tool_timeout_s` | Per-call execution timeout |
| `cache_tools` | Cache tool schemas on startup |

**Note:** Krill has no official Julia MCP SDK — the client is built from scratch. It handles common cases well but may have edge-case issues with non-standard servers. See [Known Limitations](/guide/features#Known-Limitations).


## ClawHub Skill Registry

Enable with `clawhub = true` under `[profile.tools]`. This registers four tools (`clawhub_search`, `clawhub_install`, `clawhub_remove`, `clawhub_list`) that let the agent discover and install community skills from [ClawHub](https://clawhub.ai) through a security validation pipeline.

```toml
[profile.tools]
clawhub = true

[clawhub]
api_url         = "https://clawhub.ai/api/v1"
auth_token      = "$CLAWHUB_TOKEN"       # optional, only needed for private skills
min_downloads   = 10                      # minimum download count to pass validation
min_stars       = 0
blocked_slugs   = []
blocked_authors = []
```

| Field | Default | Meaning |
| --- | --- | --- |
| `api_url` | `https://clawhub.ai/api/v1` | ClawHub API base URL |
| `auth_token` | _(none)_ | Bearer token for authenticated requests |
| `min_downloads` | `0` | Reject skills with fewer downloads than this |
| `min_stars` | `0` | Reject skills with fewer stars than this |
| `blocked_slugs` | `[]` | Skill slugs to always reject |
| `blocked_authors` | `[]` | Authors to always reject |

Installed skills are stored in `~/.krill/skill_store/` with separate `quarantine/` and `verified/` directories. A `manifest.json` tracks all entries with status, version, SHA-256 hash, and timestamps.

See [Security](/guide/security) for details on the validation gate and what it catches.


## Filesystem Layout

### `context/` — agent sandbox (committed to git)

Bootstrap docs and skills live here. The agent can read and write inside this directory; it cannot escape it.

| File | Commit? | Purpose |
| --- | --- | --- |
| `SOUL.md` | Yes | Persona and tone |
| `AGENTS.md` | No — gitignore, copy from `.example` | Environment, paths, tool preferences |
| `USER.md` | No — gitignore, copy from `.example` | Your name, timezone, technical level |
| `TOOLS.md` | Yes | Non-obvious tool constraints |
| `skills/` | Yes | Local skill definitions |

**Tips for writing bootstrap docs**

- **Keep them short.** Every character costs context budget on every turn. 20 tight lines beats 200 sprawling ones.
- **`SOUL.md`** — personality and communication style only. Don't list capabilities here.
- **`AGENTS.md`** — tool selection rules and agent constraints. Machine-specific paths go here.
- **`USER.md`** — who you are: name, timezone, technical level, preferences.
- **`TOOLS.md`** — timeouts, auth requirements, non-obvious quirks. Generic enough to commit.
- **Don't duplicate `system_prompt`.** The base prompt in `krill.toml` and bootstrap docs are both injected — avoid repeating the same content.

### `~/.krill/` — runtime state (machine-local, never committed)

| Path | Purpose |
| --- | --- |
| `sessions/<session>/history.jsonl` | Turn-by-turn session history |
| `memory/<session>/MEMORY.md` | Consolidated durable memory |
| `memory/<session>/HISTORY.md` | Archived consolidation dumps |
| `memory/<session>/state.json` | Memory bookkeeping |
| `cron/jobs.json` | Persisted cron jobs |
| `skill_store/manifest.json` | ClawHub skill registry manifest |
| `skill_store/quarantine/<slug>/` | Skills awaiting validation |
| `skill_store/verified/<slug>/` | Validated and promoted skills |
| `dead_letters.jsonl` | Failed outbound delivery records |
