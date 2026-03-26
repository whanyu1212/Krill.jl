# Krill.jl 🦐

A Julia-native, channel-agnostic AI agent runtime. Inspired by [nanobot](https://github.com/HKUDS/nanobot) and [OpenClaw](https://github.com/openclaw/openclaw).

> **Work in progress** — this is a solo project under active development. Things may break, APIs may change, and only OpenAI and Gemini are supported as LLM providers for now. More platform and provider support is planned.

## Features

| Category | What's included | Status |
| --- | --- | --- |
| **Channels** | Telegram (polling + webhook), Discord (gateway + REST) | Stable |
| **LLM Providers** | OpenAI Responses API, Gemini native + OpenAI-compat | Stable |
| **Provider Search** | OpenAI web search, Gemini Google Search — with citations | Stable |
| **Local Tools** | File ops, web fetch, shell exec, GitHub CLI, Google Workspace | Stable |
| **Coding Agents** | Delegate to Claude Code or Codex CLI | Stable |
| **MCP** | Connect external tool servers via stdio or HTTP | Works, edge cases |
| **Memory** | Per-session persistent memory with LLM-driven consolidation | Works, no size cap |
| **Cron** | Recurring and one-shot scheduled tasks | Stable |
| **Subagents** | Background tasks with full tool access, results announced when done | Stable |
| **Skills** | Markdown instruction docs — always-on or on-demand via `read_skill` | Stable |
| **Context Management** | History summarization when context window fills | Stable |
| **Prompt Construction** | System prompt + bootstrap docs + skills + memory, composed per-turn | Stable |

## Known Limitations

| Area | Limitation |
| --- | --- |
| **Providers** | OpenAI and Gemini only — no Anthropic Claude, Ollama, or local models yet |
| **Channels** | Telegram and Discord only — no WhatsApp, Slack, or voice |
| **Memory** | Per-chat isolation (no cross-channel), no explicit "remember this", no size cap, full dump each turn |
| **MCP client** | Built from scratch (no Julia SDK) — partial SSE frames, stdio mid-call exits, non-standard errors may cause issues |
| **Telegram rendering** | Tables may not align well on mobile; nested formatting stripped in tables; no auto-split for messages over 4096 chars |
| **Image generation** | OpenAI `image_generation` tool exists but Krill can't display images in Telegram/Discord yet |
| **Deployment** | Only Cloud Run tested; cold starts slow due to Julia JIT; coding agents need interactive auth (can't use subscriptions in containers) |
| **Tool permissions** | All enabled tools are global — no per-user or per-session allowlists yet |

## Quick Start

**1. Install Julia 1.12+** via [juliaup](https://github.com/JuliaLang/juliaup)

**2. Clone and install dependencies**
```bash
git clone https://github.com/whanyu1212/Krill.jl
cd Krill.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

**3. Configure**
```bash
cp krill.toml.example krill.toml
# Edit krill.toml — set your bot token, LLM provider, and API keys
```

Create a `.env` file with your secrets:
```bash
TELEGRAM_BOT_TOKEN=your_token
OPENAI_API_KEY=your_key
```

**4. (Optional) Authenticate coding agents**
```bash
claude auth login    # Claude Code
codex auth           # Codex
```

**5. Run**
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
docs/          documentation (Documenter + VitePress)
```

## Deployment

Running locally is the simplest option — all features work out of the box.

The `Dockerfile` and `scripts/deploy.sh` target **Google Cloud Run**, which is the only cloud platform tested so far. Cold starts are slow due to Julia's compilation overhead, and Cloud Run's serverless model requires workarounds for a long-running polling bot. More platform testing is planned — a long-running VM or VPS may be a better fit.

See the [deployment guide](https://whanyu1212.github.io/Krill.jl/guide/deployment) for details.

## Testing

```bash
# Full test suite
julia --project=. -e 'using Pkg; Pkg.test()'

# Fast offline tests only
KRILL_FAST_TESTS=1 julia --project=. -e 'using Pkg; Pkg.test()'

# Via script (cleans up workspace artifacts)
bash scripts/test.sh
```

## Acknowledgements

See [Acknowledgements](https://whanyu1212.github.io/Krill.jl/notes/acknowledgements) for the projects that inspired Krill.
