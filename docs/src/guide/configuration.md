# Configuration

Krill configuration is layered: `krill.toml` for durable project defaults, `.env` for secrets, and environment variables for ad hoc overrides.

| File | Purpose |
| --- | --- |
| `krill.toml` | Provider, profiles, tool toggles, MCP servers |
| `.env` | Secrets and machine-local values |
| `context/` | Agent file sandbox — bootstrap docs and skills (committed to git) |
| `~/.krill/` | Runtime state — sessions, memory, cron, dead letters (machine-local) |

---

## `krill.toml`

Which channels start is controlled entirely by `krill.toml` — no code change needed. Set `enabled = true` on any channel and it is picked up automatically when you run `bin/krill.jl`.

```toml
# LLM provider
[provider]
name    = "openai"           # "openai" or "gemini"
model   = "gpt-4o-mini"
api_key = "$OPENAI_API_KEY"  # or set in .env

# Channels — enable as many as you need
[telegram]
enabled    = true
bot_token  = "$TELEGRAM_BOT_TOKEN"
allow_from = ["*"]           # Telegram user IDs, or "*" for everyone

[discord]
enabled    = false
bot_token  = "$DISCORD_BOT_TOKEN"
allow_from = ["*"]

# Runtime paths
[llm]
workspace                     = "context"
builtin_restrict_to_workspace = true

# Agent identity and tool toggles
[profile]
system_prompt = "You are a helpful assistant. Be concise and friendly."

[profile.tools]
provider_builtins    = true   # provider web search + code interpreter
local_builtins       = true
builtin_skills       = true
memory               = true
cron                 = true
subagents            = true
exec                 = false
claude_code          = false
codex                = false

# MCP servers (add as many blocks as needed)
[[profile.mcp]]
name      = "filesystem"
transport = "stdio"
command   = "npx"
args      = ["-y", "@modelcontextprotocol/server-filesystem", "context"]
```

Token values beginning with `$` are expanded from the environment at startup, so secrets stay in `.env` and `krill.toml` can be safely version-controlled (without the tokens).

---

## Environment Variables

The recommended approach is to keep tokens in `.env` and reference them from `krill.toml` as `"$VAR_NAME"`. Environment variables are expanded at startup.

| Variable | Meaning |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `OPENAI_API_KEY` | OpenAI provider key |
| `GEMINI_API_KEY` | Gemini provider key |

---

## Tools

Krill exposes two tool classes simultaneously.

### Provider-native tools

Run on the provider's infrastructure. Pass them through via `provider_builtins = true`.

| Provider | Tools |
| --- | --- |
| OpenAI | `web_search`, `code_interpreter`, `image_generation` |
| Gemini | `googleSearch`, `urlContext`, `codeExecution` |

OpenAI `web_search` and Gemini `googleSearch` return clean, cited results. Krill's local `web_search` uses DuckDuckGo with basic HTML scraping — useful for simple lookups, but noticeably weaker. Set `provider_builtins = true` for most bots.

### Krill local tools

Implemented by Krill and registered in a local `ToolRegistry`.

| Tool | Description |
| --- | --- |
| `read_file`, `write_file`, `edit_file`, `list_dir` | File operations within the context directory |
| `web_search` | DuckDuckGo search (basic quality) |
| `web_fetch` | Fetch a URL as markdown (no JS rendering) |
| `github` | Wraps the `gh` CLI |
| `message` | Send a message to a chat ID from a tool call |
| `exec` _(optional)_ | Shell commands — disabled by default |
| `claude_code` _(optional)_ | Delegate to Claude Code CLI |
| `codex` _(optional)_ | Delegate to OpenAI Codex CLI |
| `cron_add/list/remove` | Schedule management when cron is enabled |

`claude_code` and `codex` run their own internal search and file pipelines. Enable them when the task involves multi-step research or code changes across multiple files.

:::details Recommended tool combinations
| Use case | Setup |
| --- | --- |
| General assistant with web search | `provider_builtins = true`, `local_builtins = true` |
| File-focused agent, no web search | `provider_builtins = false`, `local_builtins = true` |
| Research or coding tasks | `claude_code` or `codex` + provider tools |
| Minimal / echo bot | Both off; pass tools explicitly via `llm_tools` |
:::

---

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

---

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

:::details Tips for writing bootstrap docs
- **Keep them short.** Every character costs context budget on every turn. 20 tight lines beats 200 sprawling ones.
- **`SOUL.md`** — personality and communication style only. Don't list capabilities here.
- **`AGENTS.md`** — your actual project paths, directory layout, tool selection rules. Machine-specific, so gitignore it.
- **`USER.md`** — who you are: name, timezone, technical level, preferences. Also machine-specific.
- **`TOOLS.md`** — timeouts, auth requirements, non-obvious quirks. Generic enough to commit.
- **Don't duplicate `system_prompt`.** If you set one in `RuntimeState`, don't repeat the same content in `SOUL.md` — both get injected.
:::

### `~/.krill/` — runtime state (machine-local, never committed)

| Path | Purpose |
| --- | --- |
| `sessions/<session>/history.jsonl` | Turn-by-turn session history |
| `memory/<session>/MEMORY.md` | Consolidated durable memory |
| `memory/<session>/HISTORY.md` | Archived consolidation dumps |
| `memory/<session>/state.json` | Memory bookkeeping |
| `cron/jobs.json` | Persisted cron jobs |
| `dead_letters.jsonl` | Failed outbound delivery records |
