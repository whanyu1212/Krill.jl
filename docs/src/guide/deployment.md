# Deployment

Krill runs anywhere Julia runs — a local machine, a VPS, or a container platform. A `Dockerfile` is included for containerized deployments, and a GitHub Actions workflow (`.github/workflows/deploy.yml`) handles automated deploy to Google Cloud Run.

## Recommended Platforms

For a long-running polling bot with background tasks (cron, subagents), an always-on server is the most natural fit:

| Platform | Cost | Notes |
| --- | --- | --- |
| VPS (Hetzner, DigitalOcean) | $4-6/month | Full control, always-on, no workarounds needed |
| Fly.io | $2-5/month | Docker-native, persistent volumes, designed for always-on |
| Railway | ~$5/month | Git-push deploy, persistent containers |
| GCE (Compute Engine) | $5-7/month | Same GCP ecosystem, no serverless constraints |

## Persistent Storage

Session data, memory, and cron state are written to `data_dir` (configurable in `krill.toml`, defaults to `~/.krill`). For containerized deployments, mount a persistent volume at that path.

## Cloud Run

Cloud Run is designed for stateless HTTP request handlers — not long-running polling bots. Krill can run on Cloud Run, but it requires several workarounds. The platforms listed above are a more natural fit.

### Why Cloud Run is a poor fit

Cloud Run's model is: receive HTTP request, process, respond, go idle. Krill does the opposite: it runs a persistent Telegram polling loop, background cron ticks, and in-memory session state. Cloud Run fights this at every level:

- **Scale-to-zero kills background loops** — polling and cron die when the container shuts down
- **CPU throttling freezes the bot** — between HTTP requests, CPU is throttled to near-zero, stalling the poll loop
- **No local filesystem** — sessions, memory, and cron state need external storage
- **Health checks expect HTTP** — Krill's polling mode doesn't serve HTTP, so a fake health server is needed

### Workarounds applied

The following settings in `cloudrun.yaml` make Krill work on Cloud Run despite these constraints:

| Setting | Why |
| --- | --- |
| `min-instances: 1` | Prevent scale-to-zero — keep the polling loop alive |
| `max-instances: 1` | Only one instance can poll the same Telegram bot token |
| `cpu-throttling: "false"` | Keep CPU allocated between requests so polling isn't frozen |
| `startup-cpu-boost: "true"` | Extra CPU during startup to speed up Julia's JIT compilation |
| Startup probe (600s window) | Julia's JIT can take 60-100s on first boot — default timeout kills it |
| Liveness probe on `/` | Tells Cloud Run the container is still alive between requests |
| `memory: 2Gi`, `cpu: 2` | Julia's compiler is memory- and CPU-hungry during JIT |
| GCS FUSE volume mount | Provides persistent storage at `/data` for sessions, memory, and cron |
| Health check server in `bin/krill.jl` | A minimal HTTP server on `PORT` that responds `200 ok` — only started when `PORT` is set (Cloud Run sets it automatically; locally it's skipped) |

### Julia Startup Time (JIT / TTFX)

Julia's just-in-time compiler causes slow container startup. On a fresh Cloud Run instance, the first call to `load_config` and `start_agent!` triggers compilation of many code paths. If this takes too long, Cloud Run terminates the container before the agent starts.

Mitigations:

- **Precompile workload in Dockerfile** — the build step calls `load_config(...)` during `docker build`, forcing compilation of hot paths into the precompile cache
- **Startup CPU boost + 2 CPUs** — speeds up the JIT pass at startup
- **Extended startup probe** — allows up to 600 seconds before marking the container unhealthy
- **Disable MCP servers** — MCP connection code pulls in large JIT dependency chains; disable in `krill.toml` for cloud deployments unless needed

If startup time remains a problem, consider [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) to build a sysimage with ahead-of-time compiled code. This reduces cold start to 1-2 seconds at the cost of longer Docker builds (~10 min) and a larger image (~500MB).

### GCS Storage

The Cloud Run config mounts a GCS bucket via GCS FUSE at `/data` and sets `KRILL_DATA_DIR=/data` as an environment variable. Create the bucket and grant access:

```bash
gcloud storage buckets create gs://krill-data --location=us-central1
gcloud storage buckets add-iam-policy-binding gs://krill-data \
  --member="serviceAccount:YOUR_SA@PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
```

### GitHub Actions Deploy

The workflow in `.github/workflows/deploy.yml` builds the Docker image, pushes it to Artifact Registry, and deploys to Cloud Run. It substitutes secrets from GitHub Actions secrets into `cloudrun.yaml` placeholders at deploy time.

Required GitHub secrets:

| Secret | Value |
| --- | --- |
| `GCP_SA_KEY` | Service account key JSON |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `OPENAI_API_KEY` | OpenAI API key |
| `GEMINI_API_KEY` | Gemini API key |
| `GH_PAT` | GitHub personal access token |
