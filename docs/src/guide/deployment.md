# Deployment

Krill is a long-running polling bot with background tasks (cron, subagents, in-memory session state). The `Dockerfile`, `cloudrun.yaml`, and GitHub Actions workflow in this repo all target **Google Cloud Run**, which is the only platform tested so far. It works, but requires significant workarounds — more testing is needed to compare against other platforms.

## Persistent Storage

Session data, memory, and cron state are written to `data_dir` (configurable in `krill.toml`, defaults to `~/.krill`). For containerized deployments, mount a persistent volume at that path.

## Local

Running locally is the simplest and most tested option:

```bash
julia --project=. --threads=auto bin/krill.jl
```

All features work out of the box — no workarounds needed. If you want to use `claude_code` or `codex`, authenticate both CLIs beforehand:

```bash
claude auth login    # Claude Code — opens browser for OAuth
codex auth           # Codex — opens browser for OAuth
```

These store session tokens locally (`~/.claude/` for Claude Code). Once authenticated, the agent can delegate coding tasks to either CLI. If you use API keys instead of personal subscriptions, set `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` in your environment or `.env` file and the CLIs will pick them up automatically.

## Cloud Run

Cloud Run is designed for stateless HTTP request handlers — not long-running polling bots. Krill can run on it, but it fights the model at every level.

### Known Problems

- **Scale-to-zero kills background loops** — polling and cron die when the container shuts down
- **CPU throttling freezes the bot** — between HTTP requests, CPU is throttled to near-zero, stalling the poll loop
- **No local filesystem** — sessions, memory, and cron state need external storage (GCS FUSE)
- **Health checks expect HTTP** — Krill's polling mode doesn't serve HTTP, so a fake health server is needed (`bin/krill.jl` starts one when `PORT` is set)
- **Julia cold starts** — JIT compilation takes 60-100s on first boot; default Cloud Run timeouts kill the container before the agent starts
- **No interactive auth for claude_code / codex** — Both CLIs authenticate via browser-based OAuth when used with personal subscriptions (Claude Pro/Max, ChatGPT Plus/Pro). Cloud Run containers can't do interactive login. Options: (1) use API keys instead of subscription auth, set as Cloud Run secrets; (2) disable claude_code/codex in the cloud config and use them locally only; (3) copy auth tokens (`~/.claude/`, etc.) into the container as secrets, but tokens expire and need periodic refresh

### Workarounds Applied

The following settings in `cloudrun.yaml` make Krill work despite these constraints:

| Setting | Why |
| --- | --- |
| `min-instances: 1` | Prevent scale-to-zero — keep the polling loop alive |
| `max-instances: 1` | Only one instance can poll the same Telegram bot token |
| `cpu-throttling: "false"` | Keep CPU allocated between requests so polling isn't frozen |
| `startup-cpu-boost: "true"` | Extra CPU during startup to speed up Julia's JIT compilation |
| Startup probe (600s window) | Julia's JIT can take 60-100s — default timeout kills it |
| Liveness probe on `/` | Tells Cloud Run the container is still alive between requests |
| `memory: 2Gi`, `cpu: 2` | Julia's compiler is memory- and CPU-hungry during JIT |
| GCS FUSE volume mount | Provides persistent storage at `/data` for sessions, memory, and cron |

### Julia Startup Time (JIT / TTFX)

Julia's just-in-time compiler causes slow container startup. Mitigations used:

- **Precompile workload in Dockerfile** — the build step calls `load_config(...)` during `docker build`, caching compilation of hot paths
- **Startup CPU boost + 2 CPUs** — speeds up the JIT pass
- **Extended startup probe (600s)** — allows time before marking unhealthy
- **Disable MCP servers in cloud** — MCP connection code pulls in large JIT dependency chains

If startup time remains a problem, consider [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) to build a sysimage. This reduces cold start to 1-2 seconds at the cost of longer Docker builds (~10 min) and a larger image (~500MB).

### GCS Storage

The Cloud Run config mounts a GCS bucket via GCS FUSE at `/data` and sets `KRILL_DATA_DIR=/data`. Create the bucket and grant access:

```bash
gcloud storage buckets create gs://krill-data --location=us-central1
gcloud storage buckets add-iam-policy-binding gs://krill-data \
  --member="serviceAccount:YOUR_SA@PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

### GitHub Actions Deploy

The workflow in `.github/workflows/deploy.yml` builds the Docker image, pushes to Artifact Registry, and deploys to Cloud Run. It substitutes secrets from GitHub Actions into `cloudrun.yaml` placeholders at deploy time.

Required GitHub secrets:

| Secret | Value |
| --- | --- |
| `GCP_SA_KEY` | Service account key JSON |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `OPENAI_API_KEY` | OpenAI API key |
| `GEMINI_API_KEY` | Gemini API key |
| `GH_PAT` | GitHub personal access token |

## Other Platforms

No other platforms have been tested yet. A long-running VM or VPS would avoid most of the Cloud Run workarounds (no scale-to-zero, no CPU throttling, local filesystem).

::: warning Work in Progress
Testing on more platforms (Fly.io, Railway, bare VPS, etc.) is planned. If you've deployed Krill somewhere other than Cloud Run or locally, I'd love to hear about your experience — open an issue on GitHub.
:::
