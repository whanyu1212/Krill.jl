# Getting Started

Krill can be used as a small channel client, a message-pipeline runtime, or a full assistant runtime with tools and memory. This page covers the shortest path to a working local setup.

## Prerequisites

- Julia `1.12`
- Node.js and npm if you want to preview the docs locally
- A bot token for the channel you want to use
- An LLM API key (OpenAI or Gemini)

## 1. Install Dependencies

From the repository root:

```bash
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
model   = "gpt-4o-mini"
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

## 3. Run

A single entry point starts whichever channels are enabled in `krill.toml`:

```bash
julia --project=. --threads=auto bin/krill.jl
```

Pass `--config` to load a config file from a different path:

```bash
julia --project=. --threads=auto bin/krill.jl --config /path/to/krill.toml
```

Set `enabled = true` under `[telegram]` or `[discord]` in `krill.toml` to enable a channel — no code change required.

## 4. Run Tests

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

## 5. Build and Preview the Docs

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

## 6. Understand the Smallest Runtime Loop

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

The full `RuntimeState` constructor packages that wiring for you and adds sessions, prompt context, tools, MCP, memory, cron, and subagents.

## 7. Deployment

Krill runs anywhere Julia runs — a local machine, a VPS, or a container platform. A `Dockerfile` is included for containerized deployments, and a GitHub Actions workflow (`.github/workflows/deploy.yml`) handles automated deploy to Google Cloud Run.

### Cloud Run Notes

Cloud Run expects the container to listen on a port for health checks. Krill starts a minimal HTTP health server on the `PORT` environment variable (set automatically by Cloud Run). Locally, `PORT` is unset and the health server is skipped.

#### Julia Startup Time (JIT / TTFX)

Julia's just-in-time compiler can cause slow container startup. On a fresh Cloud Run instance, the first call to `load_config` and `start_agent!` triggers JIT compilation of many code paths. If this takes too long, Cloud Run terminates the container before the agent starts.

Mitigations applied in this project:

- **Precompile workload in Dockerfile** — the build step calls `load_config(...)` during `docker build`, forcing compilation of hot paths into the precompile cache. This reduces runtime startup from ~60s to ~5-10s.
- **Startup CPU boost** — `run.googleapis.com/startup-cpu-boost: "true"` in `cloudrun.yaml` gives the container extra CPU during startup, speeding up JIT.
- **Custom startup probe** — the startup probe in `cloudrun.yaml` allows up to 310 seconds before marking the container as unhealthy, giving Julia enough time to compile on first deploy.
- **Memory limit** — set to 2Gi. Julia's compiler is memory-hungry; 512Mi is not enough for the initial JIT pass.

If startup time becomes a recurring problem, consider using [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) to build a sysimage with all of Krill's code ahead-of-time compiled. This reduces cold start to 1-2 seconds at the cost of longer Docker builds (~5-10 min) and a larger image (~500MB).

### Persistent Storage

Session data, memory, and cron state are written to `data_dir` (configurable in `krill.toml`, defaults to `~/.krill`). For stateless container deployments, mount a persistent volume at that path. The included Cloud Run config mounts a GCS bucket via GCS FUSE at `/data` and sets `KRILL_DATA_DIR=/data`.

## 8. What to Read Next

- Use [Configuration](configuration.md) to understand environment overrides and workspace behavior
- Use [Features](features.md) for a capability map
- Use [Architecture](architecture.md) for component responsibilities and data flow
