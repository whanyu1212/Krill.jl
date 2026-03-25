# Runnable Example

Krill ships with a single entry-point script — `bin/krill.jl` — that starts a fully-featured assistant runtime. Which channels run is controlled entirely by `krill.toml`; no code change is needed to add or remove a channel.

## Quick Start

```bash
# 1. Copy the example config and fill in your tokens
cp krill.toml.example krill.toml

# 2. Add secrets to .env
echo "TELEGRAM_BOT_TOKEN=your_token" >> .env
echo "OPENAI_API_KEY=your_key" >> .env

# 3. Run
julia --project=. --threads=auto bin/krill.jl
```

Pass `--config` to load a config from a different path:

```bash
julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml
```

## What it enables

By default, with `exec = false` and `claude_code = false`:

- provider-side tools (OpenAI `web_search` + `code_interpreter`, or Gemini `googleSearch` + `urlContext` + `codeExecution`)
- Krill local built-in tools (file ops, web search/fetch, GitHub, message)
- built-in skills and workspace skill overrides
- prompt context (bootstrap docs, runtime metadata)
- session memory and memory consolidation
- cron scheduling
- subagent spawning

Optional tools are toggled in `krill.toml` under `[profile.tools]`:

| Key | Default | What it enables |
| --- | --- | --- |
| `exec` | `false` | Shell `exec` tool |
| `claude_code` | `false` | Claude Code CLI delegation |
| `codex` | `false` | Codex CLI delegation |
| `history_summarization` | `false` | LLM-driven context-window compression |

## `krill.toml` reference

```toml
[provider]
name    = "openai"           # "openai" or "gemini"
model   = "gpt-4o-mini"
api_key = "$OPENAI_API_KEY"  # expanded from .env at startup

[telegram]
enabled    = true
bot_token  = "$TELEGRAM_BOT_TOKEN"
allow_from = ["*"]           # user IDs, or "*" for everyone

[discord]
enabled    = false
bot_token  = "$DISCORD_BOT_TOKEN"
allow_from = ["*"]

[llm]
workspace                     = "context"
builtin_restrict_to_workspace = true

[profile]
system_prompt = "You are a helpful assistant. Be concise and friendly."

[profile.tools]
provider_builtins    = true
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
history_summarization = false
```

Token values beginning with `$` are expanded from the environment at startup, so `krill.toml` can be safely committed to version control (without the secrets).

## Secrets (`.env`)

Keep secrets in `.env` in the project root. Only set the variables for the channel and provider you plan to use.

| Variable | Purpose |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `OPENAI_API_KEY` | OpenAI provider key |
| `GEMINI_API_KEY` | Gemini provider key |

## Discord-specific behaviour

When the Discord channel is enabled:

- markdown tables are converted to aligned text in code blocks (Discord does not render markdown tables)
- headings are converted to bold text
- long messages are automatically split at Discord's 2000-character limit
