# Features

A practical guide to what Krill does and how to use each part.

## Agent Runtime

Everything starts with `RuntimeState`. It wires together the channel, provider, tools, memory, and all other subsystems into a single running process.

Pass everything directly as `llm_*` keyword arguments (flat API):

```julia
rt = RuntimeState(channel;
    llm_provider  = OpenAIProvider(api_key=ENV["OPENAI_API_KEY"], model="gpt-5.4"),
    system_prompt = "You are a helpful assistant.",
    workspace     = "context",
    data_dir      = joinpath(homedir(), ".krill"),
)

start!(rt)
wait()
shutdown!(rt)
```

Or compose an `Agent` struct first and pass it directly (Agent API):

```julia
agent = Agent(OpenAIProvider(api_key=ENV["OPENAI_API_KEY"], model="gpt-5.4");
    system_prompt = "You are a helpful assistant.",
    workspace     = "context",
    hooks = AgentHooks(
        on_tool_call   = (name, args) -> @info "Tool called" tool=name,
        on_tool_result = (name, res)  -> @info "Tool result" tool=name chars=length(res),
    ),
    retry = RetryConfig(max_retries=5, base_delay_s=1.0),
)

rt = RuntimeState(channel, agent)
start!(rt)
wait()
shutdown!(rt)
```

Both paths are equivalent. `Agent` is more convenient when you want to share, inspect, or test the config separately from channel setup.

| Parameter | What it does |
| --- | --- |
| `channel` | Where messages come from and go to (Telegram, Discord) |
| `llm_provider` / `provider` | Which LLM to use — `OpenAIProvider` or `GeminiProvider` |
| `system_prompt` | Base instructions prepended to every conversation |
| `workspace` | Agent file sandbox — bootstrap docs and skills live here |
| `data_dir` | Krill state directory — sessions, memory, cron (`~/.krill` by default) |

See [Architecture](/guide/architecture) for the full component picture.

## Hooks

`AgentHooks` lets you inject callbacks at five points in the agent loop without modifying any core code. All hooks are optional; failures are caught, logged with `@warn`, and never propagate.

```julia
hooks = AgentHooks(
    on_turn_start    = (msg, history) -> nothing,  # before each LLM call
    on_turn_end      = (msg, history) -> nothing,  # after response is stored
    on_tool_call     = (name, args)   -> nothing,  # before each tool dispatch
    on_tool_result   = (name, result) -> nothing,  # after successful dispatch
    should_interrupt = (name, args)   -> false,    # return true to stop the loop
)
```

| Hook | Signature | When it fires |
| --- | --- | --- |
| `on_turn_start` | `(msg, history) -> nothing` | Before the LLM call, after typing indicator |
| `on_turn_end` | `(msg, history) -> nothing` | After response stored, before next turn |
| `on_tool_call` | `(tool_name, arguments) -> nothing` | Before each tool is dispatched |
| `on_tool_result` | `(tool_name, result_text) -> nothing` | After a successful tool dispatch |
| `should_interrupt` | `(tool_name, arguments) -> Bool` | Before each tool; `true` stops the loop |

When `should_interrupt` returns `true`, the current tool and any remaining tools in the same LLM batch are skipped and the loop exits with whatever response text was accumulated so far.

Pass via `Agent(provider; hooks=...)` or `llm_hooks=...` on `RuntimeState`.

## Retry

`RetryConfig` controls how Krill retries failed LLM API calls. By default Krill retries up to 3 times with exponential backoff; `RetryConfig` lets you tune or replace that policy.

```julia
retry = RetryConfig(
    max_retries            = 5,
    base_delay_s           = 1.0,
    max_delay_s            = 60.0,
    multiplier             = 2.0,
    jitter                 = true,   # randomise 0.75–1.0× to avoid thundering herd
    retriable_status_codes = Set([408, 429, 500, 502, 503, 504, 529]),
)
```

Sleep formula: `clamp(base_delay_s × multiplier^(attempt-1) × jitter_factor, 0, max_delay_s)`

Pass via `Agent(provider; retry=...)` or `llm_retry=...` on `RuntimeState`. When omitted, Krill falls back to the per-provider `max_retries` / `retry_base_seconds` fields.

## Tools

Tools are what the LLM can actually *do*. Krill has two classes.

### Local built-ins

Enabled with `llm_enable_builtin_tools=true`. Always available regardless of provider.

| Tool | What it does |
| --- | --- |
| `read_file`, `write_file`, `edit_file`, `list_dir` | File operations inside `workspace` |
| `web_fetch` | Fetch a specific URL as markdown |
| `github` | Wraps the `gh` CLI |
| `message` | Send a message to a chat ID (only registered when a send function is available) |
| `exec` | Shell commands — opt-in via `llm_builtin_enable_exec=true` |
| `google_workspace` | Wraps the `gws` CLI for Gmail, Calendar, Drive — opt-in via `llm_enable_google_workspace=true` |
| `claude_code` | Delegate a task to Claude Code CLI — opt-in via `llm_enable_claude_code=true` |
| `codex` | Delegate a task to Codex CLI — opt-in via `llm_enable_codex=true` |

By default, file tools are restricted to `workspace`. Set `llm_builtin_restrict_to_workspace=false` to allow access outside it.

### Provider built-ins

Pass provider-native tools via `llm_tools`. These run on the provider's infrastructure and are significantly more capable than local equivalents for web search and code execution.

```julia
# OpenAI
llm_tools = [
    Dict("type" => "web_search"),
    Dict("type" => "code_interpreter", "container" => Dict("type" => "auto")),
]

# Gemini
llm_tools = [
    Dict("googleSearch" => Dict{String,Any}()),
    Dict("urlContext"   => Dict{String,Any}()),
    Dict("codeExecution" => Dict{String,Any}()),
]
```

For most bots, enable both: provider tools for web search quality, local tools for file access and GitHub. Use `claude_code` or `codex` for multi-step research or coding tasks.

### Provider tools not yet enabled

Both providers offer additional built-in tools that Krill doesn't enable by default. I may come back to these later, but most are not high-value items for a personal assistant use case right now.

| Tool | Provider | Value | Notes |
| --- | --- | --- | --- |
| `image_generation` | OpenAI | High | "Generate an image of X" is a natural request. Easy to enable on the API side, but Krill's pipeline currently assumes text-only responses — displaying images in Telegram/Discord requires changes to parsing, message types, and channel senders. |
| `googleMaps` | Gemini | Medium | Useful for location queries ("restaurants near me", "directions to X"). Has compatibility constraints — can't combine with `googleSearch`, `codeExecution`, or `urlContext` in the same request. The agent loses other tools when maps is active. `_sanitize_gemini_tools` in `parsing.jl` already handles this. |
| `file_search` | Both | Low | Requires pre-uploading documents to vector stores (OpenAI) or file search stores (Gemini). Not useful unless you set up a knowledge base. Could be valuable later for searching over a document library. |
| `computerUse` | Gemini | None | Krill runs headless — there's no screen to interact with. |
| `mcp` (remote) | OpenAI | None | OpenAI's server-side MCP. Krill already has local MCP support which is more flexible. |

## MCP Servers

MCP lets you connect any external tool server — databases, calendars, custom APIs — and expose its tools to the LLM alongside the built-ins.

Configure servers in `krill.toml`:

```toml
[[profile.mcp]]
name      = "filesystem"
transport = "stdio"
command   = "npx"
args      = ["-y", "@modelcontextprotocol/server-filesystem", "context"]
```

At startup, Krill calls `initialize` and `list_tools` on each server and registers the results into the local `ToolRegistry` under namespaced IDs: `mcp_<name>_<tool>`.

| Transport | When to use |
| --- | --- |
| `stdio` | Local process (`npx`, `uvx`, etc.) — most common |
| `streamable_http` | Remote HTTP MCP server |
| `sse` | Legacy HTTP+SSE — use only if the server requires it |

**Note:** Julia has no official MCP SDK. Krill's client implements JSON-RPC initialize / list / call from scratch. It handles the common cases but may have edge-case issues with non-standard servers. See [Known Limitations](#known-limitations).

## Skills

Skills are markdown documents that inject reusable instructions into the prompt. They live in `context/skills/<name>/SKILL.md` and are discovered automatically at startup.

```
context/
  skills/
    github/
      SKILL.md
    cron/
      SKILL.md
```

Each `SKILL.md` has a YAML frontmatter header:

```markdown
---
name: github
description: "Interact with GitHub using the github tool (gh CLI wrapper)."
requires_bins: gh
---

# GitHub

Use the `github` tool to run `gh` CLI commands...
```

| Field | Meaning |
| --- | --- |
| `name` | Skill identifier — must match the directory name |
| `description` | Shown to the LLM in the skills summary; primary trigger for loading the skill |
| `always` | `true` — full body injected into every turn; `false` — loaded on-demand via `read_skill` tool |
| `requires_bins` | Comma-separated binaries; skill marked unavailable if any are missing from PATH |
| `requires_env` | Comma-separated env vars; skill marked unavailable if any are unset |

Enable with `llm_enable_builtin_skills=true`.

### Built-in Skills

Krill ships with the following skills out of the box:

| Skill | Always-on | Description |
| --- | --- | --- |
| `memory` | Yes | Two-layer memory system guidance — when and how to update MEMORY.md and search HISTORY.md |
| `github` | No | Patterns for the `github` tool: issues, PRs, CI status, repo info, API queries, `--json`/`--jq` output |
| `cron` | No | Scheduling guide for `cron_add`/`cron_list`/`cron_remove` with schedule type reference |
| `weather` | No | Free weather APIs (wttr.in, Open-Meteo) with no API key required |
| `google-workspace` | No | Gmail, Calendar, Drive patterns for the `google_workspace` tool — send, triage, reply, API commands |
| `skill-creator` | No | Guide to creating new skills — anatomy, frontmatter, bundled resources, design principles |
| `clawhub` | No | Search, install, and manage community skills from [ClawHub](https://clawhub.ai) |

Always-on skills (`memory`) are injected into every system prompt. The rest are loaded on-demand when the LLM calls `read_skill("github")` etc.

### Discovering Community Skills

The agent can search and install skills from [ClawHub](https://clawhub.ai), a public skill registry, using the built-in `clawhub` skill. This lets the agent extend its own capabilities on the fly:

```
User: "Find me a skill for PDF processing"
  → LLM loads clawhub skill via read_skill("clawhub")
  → LLM calls exec: npx clawhub@latest search "PDF processing" --limit 5
  → LLM calls exec: npx clawhub@latest inspect pdf-toolkit-pro
  → LLM calls exec: npx clawhub@latest install pdf-toolkit-pro --workdir context/
  → Skill installed to context/skills/pdf-toolkit-pro/
  → Available after restart
```

Community skills use the same `SKILL.md` format. Some may reference tool names from other agent frameworks — minor edits may be needed to map to Krill's tool names (`exec`, `github`, `cron_add`, etc.).

No API key is required for searching and installing. See `context/skills/clawhub/SKILL.md` for full usage.

### Creating Custom Skills

Use the `skill-creator` skill for guidance on writing your own:

```
context/skills/my-skill/
├── SKILL.md              # Required — frontmatter + instructions
└── references/           # Optional — detailed docs loaded on-demand
    └── api.md
```

Key design principles:
- **Concise** — the context window is shared; only include what the LLM doesn't already know
- **Progressive disclosure** — metadata always loaded, body on-demand, resources only when needed
- **Specific triggers** — put "when to use" info in the `description` field, not the body

## Prompt Context

On every turn, Krill assembles the system prompt from multiple sources in order:

1. `system_prompt` from `RuntimeState`
2. Bootstrap docs from `workspace` — `SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`
3. Skill metadata summary (names + descriptions of available skills)
4. Always-on skill bodies (`always: true`)
5. Session memory from `MEMORY.md`
6. Tool-output safety notice
7. Runtime metadata — channel name, session key, chat ID, user ID, UTC timestamp

This is assembled fresh every turn, so changes to bootstrap docs or skills take effect immediately without restarting.

## Memory

Krill has a two-layer memory system: **session memory** (per-chat, automatic) and **global memory** (per-user, explicit).

### Session Memory

Per-session durable memory that persists across restarts. Scoped to a session key (e.g. `telegram:123`), so each chat has its own isolated memory store.

Enable with `llm_enable_memory=true` and `llm_enable_memory_consolidation=true`.

**How it works:**

1. After each turn, a consolidation process scans new history entries
2. It calls the LLM to extract durable facts and merge them into `MEMORY.md`
3. Processed history is archived to `HISTORY.md` so `MEMORY.md` stays compact
4. On the next turn, `MEMORY.md` is injected into the system prompt as `## Session Memory`

Files written under `~/.krill/memory/<session>/`:

| File | Purpose |
| --- | --- |
| `MEMORY.md` | Live consolidated memory — injected each turn |
| `HISTORY.md` | Archived consolidation batches |
| `state.json` | Offsets and failure tracking |

### Global Memory

Cross-channel user profile that persists across sessions and channels. Keyed by `user_id` (not session key), so the same user is recognised whether they message from Telegram, Discord, or any other channel.

Enable by passing `llm_global_memory_store` to `RuntimeState`.

**How it works:**

1. Users write facts explicitly with `/remember <fact>`
2. The LLM merges the new fact into the existing profile — deduplicating, resolving contradictions, and reorganising into coherent sections
3. The updated profile is saved to `MEMORY.md` for that user
4. On every turn, the profile is injected into the system prompt as `## User Profile`, above session memory

Files written under `~/.krill/global_memory/<user_id>/`:

| File | Purpose |
| --- | --- |
| `MEMORY.md` | Live user profile — injected every turn across all sessions |

**Prompt injection order** (when both layers are enabled):

```
[Base system prompt]
[Bootstrap docs]
[Skills]
## User Profile       ← global memory (cross-channel)
## Session Memory     ← session memory (per-chat)
[Tool safety notice]
[Runtime metadata]
```

## Cron

Schedule jobs that fire as synthetic messages back into the runtime — the LLM handles them like any other inbound message.

Enable with `llm_enable_cron=true`. The LLM can then use `cron_add`, `cron_list`, and `cron_remove` tools.

Three schedule types:

| Type | Example | Meaning |
| --- | --- | --- |
| `at` | `at 2026-04-01T09:00:00` | One-shot at a specific time |
| `every` | `every 30m` | Repeating interval |
| cron expression | `0 9 * * 1-5` | Standard 5-field cron |

Jobs persist to `~/.krill/cron/jobs.json` and survive restarts.

## Subagents

A subagent is an isolated background LLM task spawned mid-conversation. The parent session continues; when the subagent finishes, its result is injected back as a message.

Enable with `llm_enable_subagents=true`.

```
User: "Research X and summarise it"
  → LLM calls spawn_subagent(task="Research X")
  → Subagent runs in its own session with its own tool loop
  → Result injected into parent session when done
  → LLM continues with the result
```

Key behaviours:

- Subagents get their own isolated session — history doesn't bleed across
- Spawn tools are omitted inside subagents to prevent recursive spawning
- Concurrent subagent limit is enforced to avoid runaway parallelism

## Channels

### Telegram

```julia
channel = TelegramChannel(TelegramClient(token); allow_from=["123456789"])
```

- Long polling via `TelegramChannel`
- HTTP webhook via `TelegramWebhookChannel`
- Normalises text, media, callback queries, and channel posts into `InboundMessage`
- `allow_from` controls which user IDs can interact (`["*"]` to allow all)

### Discord

```julia
channel = DiscordChannel(DiscordClient(token); allow_from=["*"])
```

- Gateway client for `MESSAGE_CREATE` events
- REST client for sending and typing indicators
- Long messages split automatically on outbound
- Markdown formatter converts tables → code blocks, headings → bold, HRs → Unicode lines

## Known Limitations

### MCP client

Krill's MCP client is built from scratch with no official Julia SDK. Known edge cases:

- **Partial SSE frames** — servers that don't strictly follow the SSE spec may cause parse errors
- **Stdio mid-call exit** — reconnect fires but the in-flight result is lost
- **Non-standard error shapes** — the client may surface a generic error instead of the server's structured one
- **Session continuity** — HTTP re-initialization after reconnect may break servers that tie context to session state

Open an issue with the raw JSON-RPC exchange and server name if you hit one of these.

### Memory

- **No memory retrieval tool** — the full `MEMORY.md` is dumped into context every turn; the LLM can't search or query it selectively
- **No memory size cap** — if `MEMORY.md` grows large, it eats into the context window with no automatic pruning
- **Session memory consolidation quality depends on the LLM** — the summarizer may drop facts the user considers important, or retain noise
- **Global memory is explicit-only** — the user must invoke `/remember <fact>`; the LLM does not write to global memory automatically

### Telegram rendering

Krill converts markdown to Telegram HTML before sending — bold, italic, strikethrough, code blocks, inline code, links, and headings all translate. Tables are converted to aligned monospace `<pre>` blocks. Known rough edges:

- **Complex tables** — Tables with very wide columns or mixed-width content may not align well on mobile screens
- **Nested formatting in tables** — Bold/italic inside table cells is stripped (the table is rendered as plain text inside `<pre>`)
- **Long messages** — Telegram has a 4096-character limit per message; Krill does not currently split long responses automatically (Discord does)
- **HTML fallback** — If Telegram rejects the HTML (malformed tags from unusual LLM output), Krill retries as plain text, losing all formatting

### Current boundaries

- Telegram and Discord only — more channels are roadmap
- Entry points enable all tools by default — no per-tool UI yet
- `context/` is a plain directory, not a versioned or migrated store
