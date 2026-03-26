# Krill.jl 🦐

A Julia-native, channel-agnostic AI agent runtime. Inspired by [openai-agents-python](https://github.com/openai/openai-agents-python) and [nanobot](https://github.com/nano-bot/nano-bot).

## Features

- **Multi-channel** — Telegram and Discord out of the box
- **Multi-provider LLM** — OpenAI, Gemini, or any OpenAI-compatible endpoint
- **Tool calling** — file ops, web search, web fetch, shell exec, GitHub CLI, Google Workspace, messaging
- **MCP support** — connect any MCP server (stdio or HTTP)
- **Persistent memory** — per-session memory with automatic consolidation
- **Cron/reminders** — schedule recurring or one-shot tasks
- **Subagents** — spawn background tasks that run in parallel
- **Skills** — load domain-specific instructions from markdown files
- **Coding agents** — delegate to Claude Code or Codex CLI
- **Durable queue** — dead-letter handling and message deduplication
- **Context window management** — LLM-driven history summarization
- **Webhook support** — Telegram webhook mode for serverless deployments

## Quick Start

**1. Install Julia 1.12+**

**2. Clone and install dependencies**
```bash
git clone https://github.com/your-username/Krill.jl
cd Krill.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

**3. Configure**
```bash
cp krill.toml.example krill.toml
# Edit krill.toml — set your bot token, LLM provider, and API keys
```

**4. Run**
```bash
julia --project=. --threads=auto bin/krill.jl
```

## Configuration

All configuration lives in `krill.toml`. Secrets can be inlined or referenced as `$ENV_VAR` (expanded at startup from environment or `.env`).

```toml
[provider]
name    = "openai"
model   = "gpt-4o"
api_key = "$OPENAI_API_KEY"

[telegram]
enabled   = true
bot_token = "$TELEGRAM_BOT_TOKEN"

[llm]
workspace = "context"   # agent file sandbox
data_dir  = ""          # session/memory/cron storage — defaults to ~/.krill
```

See [`krill.toml.example`](krill.toml.example) for the full reference.

## Project Structure

```
bin/           entry point (krill.jl)
context/       agent workspace — files, skills, persona docs
src/           source code
  channels/    Telegram, Discord channel implementations
  config/      config loading, .env, provider setup
  core/        agent, LLM, tools, memory, sessions, cron, MCP, subagents
  runtime.jl   RuntimeState — wires everything together
test/          test suite
scripts/       helper scripts (deploy, test, GCP setup)
```

## Deployment

The `Dockerfile` and `scripts/deploy.sh` in this repo target **Google Cloud Run**, which is the only platform tested so far. Cold starts are slow due to Julia's compilation overhead, and stateless containers require a persistent volume for `data_dir` (default `~/.krill`) — session data, memory, and cron state are all written there. More testing is needed to compare platforms (e.g., a long-running VM or VPS may be a better fit than serverless containers).

## Testing

```bash
# Full test suite
julia --project=. -e 'using Pkg; Pkg.test()'

# Fast offline tests only
KRILL_FAST_TESTS=1 julia --project=. -e 'using Pkg; Pkg.test()'

# Via script (cleans up workspace artifacts)
bash scripts/test.sh
```
