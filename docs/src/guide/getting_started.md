# Getting Started

Krill can be used as a small channel client, a message-pipeline runtime, or a full assistant runtime with tools and memory. This page covers the shortest path to a working local setup.

## Prerequisites

- **Julia 1.12+** — Install via [juliaup](https://github.com/JuliaLang/juliaup), the recommended Julia version manager. It handles installing and switching between Julia versions:
  ```bash
  # Install juliaup (macOS / Linux)
  curl -fsSL https://install.julialang.org | sh

  # Install Julia 1.12
  juliaup add 1.12
  juliaup default 1.12
  ```
- **Node.js and npm** — only needed if you want to preview the docs locally or use MCP stdio servers (e.g. `npx` commands)
- **A bot token** for the channel you want to use:
  - Telegram: create a bot via [@BotFather](https://t.me/BotFather) and copy the token
  - Discord: create an application at the [Discord Developer Portal](https://discord.com/developers/applications), add a bot, and copy the token
- **An LLM API key** — OpenAI (`OPENAI_API_KEY`) or Gemini (`GEMINI_API_KEY`). Only these two providers are supported right now; more are planned (see [Roadmap](/notes/roadmap))
- **(Optional) Claude Code / Codex CLIs** — if you want the agent to delegate coding tasks. Authenticate before running Krill:
  ```bash
  claude auth login    # Claude Code
  codex auth           # Codex
  ```

## 1. Clone and Install Dependencies

```bash
git clone https://github.com/whanyu1212/Krill.jl
cd Krill.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

To prepare the docs toolchain:

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
npm --prefix docs install
```

## 2. Configure `krill.toml`

`krill.toml` controls which LLM provider to use, which channels are enabled, and which tools are on. Values beginning with `$` are expanded from the environment at startup, so secrets stay in `.env`.

```toml
[provider]
name    = "openai"
model   = "gpt-5.4"
api_key = "$OPENAI_API_KEY"

[telegram]
enabled    = true
bot_token  = "$TELEGRAM_BOT_TOKEN"
allow_from = ["*"]   # user IDs, or "*" for everyone

[discord]
enabled    = false
bot_token  = "$DISCORD_BOT_TOKEN"
allow_from = ["*"]
```

Then create `.env` in the project root with your secrets:

```bash
TELEGRAM_BOT_TOKEN=your_telegram_bot_token
OPENAI_API_KEY=your_openai_key
```

## 3. Customize the Agent (optional)

Krill loads bootstrap docs from the `context/` folder in your project and injects them into the system prompt. These files are committed to your repo — they define who the agent is. Edit them directly:

| File | Purpose |
| --- | --- |
| `SOUL.md` | Persona and tone — who the assistant is |
| `AGENTS.md` | Capabilities and constraints — what it can and cannot do |
| `USER.md` | Information about you — your name, preferences, context |
| `TOOLS.md` | Non-obvious tool usage notes — how to use specific tools well |

All files are optional and missing ones are silently skipped. The repo includes starter versions of each — edit them to match your needs.

## 4. Run

A single entry point starts whichever channels are enabled in `krill.toml`:

```bash
julia --project=. --threads=auto bin/krill.jl
```

Pass `--config` to load a config file from a different path:

```bash
julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml
```

Set `enabled = true` under `[telegram]` or `[discord]` in `krill.toml` to enable a channel — no code change required.

## 5. Run Tests

Preferred full suite:

```bash
bash scripts/test.sh
```

Fast mode while iterating:

```bash
bash scripts/test_fast.sh
```

Focused suites are also available for major subsystems:

```bash
bash scripts/test_channels.sh
bash scripts/test_tools_mcp.sh
bash scripts/test_cron.sh
bash scripts/test_subagent.sh
```

## 6. Build and Preview the Docs

Generate the Documenter output:

```bash
julia --project=docs docs/make.jl
```

Preview the VitePress site:

```bash
npm --prefix docs run docs:dev
```

Build the static site:

```bash
npm --prefix docs run docs:build
```

## 7. Understand the Smallest Runtime Loop

A minimal message lifecycle looks like this:

```julia
using Krill

hub = MessageHubState()
manager = ChannelManagerState(hub)
client = TelegramClient(ENV["TELEGRAM_BOT_TOKEN"])
register_sender!(manager, :telegram, make_telegram_sender(client))
start_dispatch!(manager)

# Somewhere upstream: normalize a raw platform event.
inbound = normalize_update(raw_update)
publish_inbound!(hub, inbound)

# Somewhere downstream: consume and reply.
msg = take_inbound!(hub)
reply = OutboundMessage(
    channel=msg.channel,
    session_key=msg.session_key,
    chat_id=msg.chat_id,
    text="Echo: $(message_text(msg))",
)
publish_outbound!(hub, reply)
```

Here's what's happening step by step:

1. **A message hub is created** — think of it as a mailroom with two trays: one for incoming messages, one for outgoing replies. Everything flows through here.
2. **A channel manager is set up** — this is the delivery service. It knows how to send messages back to Telegram (or Discord, or whatever channel you wire up).
3. **A Telegram client connects** — using your bot token, it can talk to the Telegram API.
4. **When a user sends a message**, the raw Telegram event is normalized into a standard `InboundMessage` — stripping away platform-specific details so the rest of Krill doesn't need to know whether it came from Telegram, Discord, or anywhere else.
5. **The message is placed in the incoming tray** and picked up for processing.
6. **A reply is constructed and placed in the outgoing tray** — the channel manager picks it up and delivers it back to the user via Telegram.

This is the bare minimum loop — receive, process, reply. The full `RuntimeState` constructor packages all this wiring for you and layers on sessions, prompt context, LLM calls, tools, MCP, memory, cron, and subagents.

## 8. What to Read Next

- Use [Configuration](configuration.md) to understand environment overrides and workspace behavior
- Use [Features](features.md) for a capability map
- Use [Architecture](architecture.md) for component responsibilities and data flow
