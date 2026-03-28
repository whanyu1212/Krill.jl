<p align="center">
  <h1 align="center">Krill.jl 🦐</h1>
  <p align="center">
    <strong>A Julia-native, channel-agnostic AI agent runtime</strong><br>
    Inspired by <a href="https://github.com/HKUDS/nanobot">nanobot</a> and <a href="https://github.com/openclaw/openclaw">OpenClaw</a>
  </p>
  <p align="center">
    <a href="https://whanyu1212.github.io/Krill.jl/"><img src="https://img.shields.io/badge/docs-latest-blue.svg" alt="Documentation"></a>
    <a href="https://github.com/whanyu1212/Krill.jl/actions/workflows/ci.yml"><img src="https://github.com/whanyu1212/Krill.jl/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="https://codecov.io/gh/whanyu1212/Krill.jl"><img src="https://codecov.io/gh/whanyu1212/Krill.jl/branch/main/graph/badge.svg" alt="Coverage"></a>
    <a href="https://github.com/whanyu1212/Krill.jl/actions"><img src="https://img.shields.io/github/actions/workflow/status/whanyu1212/Krill.jl/docs.yml?label=docs%20build" alt="Docs Build"></a>
    <img src="https://img.shields.io/badge/Julia-1.12%2B-purple.svg" alt="Julia 1.12+">
    <img src="https://img.shields.io/badge/status-work%20in%20progress-orange.svg" alt="WIP">
    <a href="https://github.com/whanyu1212/Krill.jl/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT License"></a>
  </p>
</p>

---

> **Work in progress** — solo project under active development. APIs may change. Only OpenAI and Gemini providers supported for now.

## What It Does

Connect an LLM to Telegram or Discord with tools, memory, scheduling, and coding agents — all from a single `krill.toml` config file.

```
User (Telegram/Discord)
  → Krill agent
    → LLM (OpenAI / Gemini)
    → Tools (file ops, web, GitHub, shell, MCP)
    → Coding agents (Claude Code, Codex)
    → Memory (persisted across sessions)
    → Cron (scheduled tasks)
    → Subagents (background work)
  → Reply
```

## Features

| | Feature | Description |
|:---:|---|---|
| 💬 | **Channels** | Telegram (polling + webhook), Discord (gateway + REST) |
| 🧠 | **LLM Providers** | OpenAI Responses API, Gemini native + OpenAI-compat |
| 🔍 | **Provider Search** | OpenAI web search, Gemini Google Search — with citations |
| 🛠️ | **Local Tools** | File ops, web fetch, shell exec, GitHub CLI, Google Workspace |
| 👨‍💻 | **Coding Agents** | Delegate to Claude Code or Codex CLI |
| 🔌 | **MCP** | Connect external tool servers via stdio or HTTP |
| 💾 | **Memory** | Per-session persistent memory with LLM-driven consolidation |
| ⏰ | **Cron** | Recurring and one-shot scheduled tasks |
| 🤖 | **Subagents** | Background tasks with full tool access |
| 📝 | **Skills** | Markdown instruction docs — always-on or on-demand |
| 📊 | **Context Management** | History summarization when context window fills |
| 🏗️ | **Prompt Construction** | System prompt + bootstrap docs + skills + memory, composed per-turn |

## Quick Start

**1.** Install [Julia 1.12+](https://github.com/JuliaLang/juliaup) and clone:
```bash
git clone https://github.com/whanyu1212/Krill.jl && cd Krill.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

**2.** Configure:
```bash
edit krill.toml            # fill in your tokens
```
```bash
# .env
TELEGRAM_BOT_TOKEN=your_token
OPENAI_API_KEY=your_key
```

**3.** (Optional) Authenticate coding agents:
```bash
claude auth login    # Claude Code
codex auth           # Codex
```

**4.** Run:
```bash
julia --project=. --threads=auto bin/krill.jl
```

## Configuration

All configuration lives in `krill.toml`. Secrets use `$VAR` syntax and are expanded at startup from the environment or a `.env` file — no secrets are stored directly in the config.

### `.env`

```bash
# LLM providers (set whichever you use)
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=AIza...

# Channels
TELEGRAM_BOT_TOKEN=...
DISCORD_BOT_TOKEN=...

# MCP / integrations
GH_PAT=github_pat_...

# Optional overrides
KRILL_DATA_DIR=~/.krill        # where session data, memory, cron jobs are stored
```

### `krill.toml`

```toml
# LLM provider — "openai" or "gemini"
[provider]
name    = "openai"
model   = "gpt-4o"
api_key = "$OPENAI_API_KEY"

# Channels — enable the ones you want
[telegram]
enabled    = true
bot_token  = "$TELEGRAM_BOT_TOKEN"
allow_from = ["*"]          # Telegram user IDs, or "*" for everyone

[discord]
enabled    = false
bot_token  = "$DISCORD_BOT_TOKEN"
allow_from = ["*"]          # Discord user snowflakes, or "*" for everyone

# Runtime paths
[llm]
workspace = "context"       # agent file sandbox (skills, bootstrap docs)
data_dir  = "$KRILL_DATA_DIR"

# Agent identity and tool toggles
[profile]
system_prompt = "You are a helpful assistant."

[profile.tools]
provider_builtins     = true   # provider-native web search / code interpreter
local_builtins        = true   # file ops, web fetch, shell exec, GitHub CLI
builtin_skills        = true   # on-demand skill docs
memory                = true   # per-session persistent memory
memory_consolidation  = true   # LLM-driven memory summarization
cron                  = true   # scheduled tasks
subagents             = true   # background task delegation
exec                  = true   # shell execution (use with caution)
claude_code           = false  # delegate to Claude Code CLI
claude_code_model     = "sonnet"
codex                 = false  # delegate to Codex CLI
google_workspace      = false  # Google Workspace tools

# MCP servers — add as many blocks as needed
[[profile.mcp]]
name      = "github"
transport = "streamable_http"
url       = "https://api.githubcopilot.com/mcp/"
[profile.mcp.headers]
Authorization  = "Bearer $GH_PAT"
X-MCP-Readonly = "true"
```

See [`krill.toml`](krill.toml) for the complete reference with all options and comments.

> **Note:** For detailed configuration guides, provider setup, and deployment options, refer to the [documentation](https://whanyu1212.github.io/Krill.jl/).

## Project Structure

```
bin/           entry point (krill.jl)
context/       agent workspace — files, skills, persona docs
src/
  transport/   message types, hub, dispatch, dedup
  sessions/    session history, memory, consolidation
  tools/       tool registry, skills, MCP, builtin tools
  scheduling/  cron jobs, subagents
  llm/         LLM providers, parsing, tool loop
  channels/    Telegram, Discord implementations
  config/      config loading, .env, provider setup
  runtime.jl   RuntimeState — wires everything together
test/          test suite
docs/          Documenter + VitePress documentation
```

## Current Scope

Krill is a focused tool — some things are intentionally out of scope for now, others are on the roadmap.

| Area | Status | Notes |
|---|:---:|---|
| **Providers** | 🔜 | OpenAI and Gemini supported; Anthropic, Ollama, and local models planned |
| **Channels** | 🔜 | Telegram and Discord; WhatsApp, Slack, voice not yet supported |
| **Memory** | 🔜 | Per-session persistent memory; explicit "remember this" and size caps coming |
| **MCP** | 🔧 | Custom Julia implementation — may have edge cases with non-standard servers |
| **Telegram formatting** | 🔧 | Tables may misalign on mobile; long messages not auto-split |
| **Images** | 🔜 | Generated image display in chat not yet supported |
| **Deployment** | 🔜 | Cloud Run and Compute Engine tested; Julia cold starts are slow on first run |
| **Permissions** | 🔜 | Tool access is global per-session; per-user allowlists planned |

> 🔜 planned &nbsp;|&nbsp; 🔧 known quirk

## Testing

```bash
bash scripts/test.sh                    # full suite
KRILL_FAST_TESTS=1 bash scripts/test.sh  # fast offline tests
```

## Deployment

Running locally is the simplest option. For production, the included CI/CD pipeline deploys via Docker — push to `main` triggers a GitHub Actions workflow that builds the image, pushes to Artifact Registry, and deploys to the VM via SSH. The author currently runs this on **GCP Compute Engine** (e2-medium).

An e2-medium VM (~$20–25/month with sustained use discounts) is the recommended setup — always-on, no cold starts, and full local filesystem for session/memory persistence. See the [deployment guide](https://whanyu1212.github.io/Krill.jl/guide/deployment) for full setup instructions and platform comparisons.

## Contributing

Issues and PRs are welcome. If you've tried Krill and hit a bug or have an idea, [open an issue](https://github.com/whanyu1212/Krill.jl/issues).

## Disclaimer

AI was used as a force multiplier in this project — but that doesn't mean the code is untested slop. The test suite covers the core runtime, session handling, tool loop, prompt construction, memory, channels, and concurrency. AI-generated code went through the same review and testing bar as anything written by hand.

Julia is not my first language, so things may be unpolished in places. I'm open to feedback and constructive criticism — if you see something that could be done more idiomatically or efficiently, [open an issue](https://github.com/whanyu1212/Krill.jl/issues) or a PR.

For AI onboarding context, see [`CLAUDE.md`](CLAUDE.md) or [`AGENTS.md`](AGENTS.md).

## Acknowledgements

Krill.jl was inspired by [nanobot](https://github.com/HKUDS/nanobot) and [OpenClaw](https://github.com/openclaw/openclaw), as well as the broader ecosystem of OpenClaw ports and reimplementations in other languages. Thanks to everyone who built and shared those projects — they laid the groundwork for what Krill tries to do in Julia.
