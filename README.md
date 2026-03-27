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
cp krill.toml.example krill.toml   # edit with your tokens
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

All configuration lives in `krill.toml`. Secrets referenced as `$ENV_VAR` are expanded at startup from the environment or `.env`.

```toml
[provider]
name    = "openai"
model   = "gpt-5.4"
api_key = "$OPENAI_API_KEY"

[telegram]
enabled   = true
bot_token = "$TELEGRAM_BOT_TOKEN"

[llm]
workspace = "context"   # agent file sandbox
data_dir  = ""          # defaults to ~/.krill
```

See [`krill.toml.example`](krill.toml.example) for the full reference.

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

## Known Limitations

| | Area | What's missing |
|:---:|---|---|
| ⚠️ | **Providers** | OpenAI and Gemini only — no Anthropic, Ollama, or local models yet |
| ⚠️ | **Channels** | Telegram and Discord only — no WhatsApp, Slack, or voice |
| ⚠️ | **Memory** | Per-chat isolation, no explicit "remember this", no size cap |
| ⚠️ | **MCP** | Built from scratch (no Julia SDK) — edge cases with non-standard servers |
| ⚠️ | **Telegram** | Tables may misalign on mobile; no auto-split for long messages |
| ⚠️ | **Images** | Can't display generated images in chat yet |
| ⚠️ | **Deploy** | Only Cloud Run tested; Julia cold starts are slow |
| ⚠️ | **Permissions** | All tools are global — no per-user allowlists yet |

## Testing

```bash
bash scripts/test.sh                    # full suite
KRILL_FAST_TESTS=1 bash scripts/test.sh  # fast offline tests
```

## Deployment

Running locally is the simplest option. The `Dockerfile` targets Google Cloud Run but more platform testing is planned. See the [deployment guide](https://whanyu1212.github.io/Krill.jl/guide/deployment).

## Contributing

Issues and PRs are welcome. If you've tried Krill and hit a bug or have an idea, [open an issue](https://github.com/whanyu1212/Krill.jl/issues).

## AI Disclosure

AI was used as a force multiplier in this project. For onboarding, see [`CLAUDE.md`](CLAUDE.md) or [`AGENTS.md`](AGENTS.md).

## Acknowledgements

See [Acknowledgements](https://whanyu1212.github.io/Krill.jl/notes/acknowledgements) for the projects that inspired Krill.
