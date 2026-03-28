# Deployment

Krill is a long-running polling bot with background tasks (cron, subagents, in-memory session state). The recommended production setup is **GCP Compute Engine** with Docker — a standard VM avoids all the constraints of serverless platforms like Cloud Run (no scale-to-zero, no CPU throttling, persistent local filesystem).

## Platform Comparison

| Platform | Est. Monthly Cost | Always-on | Local Filesystem | Notes |
|---|---|---|---|---|
| **GCP Compute Engine e2-medium** | ~$20–25/month | ✅ | ✅ | Recommended. Sustained use discount applies at 100% uptime. |
| **GCP Cloud Run (min-instances=1)** | ~$42–52/month | ✅ | ❌ | ~2× the cost of e2-medium. Scale-to-zero + CPU throttling make it a poor fit for polling bots. |
| **Mac Mini (M4, base)** | ~$0/month (after ~$600 one-time) | ✅ | ✅ | Home power draw ~7W idle (~$5/year electricity). Great for personal use; no ongoing cloud costs. |
| **Fly.io** | TBD | TBD | TBD | Persistent volumes available. Worth evaluating for simpler deploys. |
| **Railway** | TBD | TBD | TBD | Simple git-push deploys. Free tier limited; persistent disk available on paid plans. |
| **Hetzner VPS (CX22)** | TBD | TBD | ✅ | ~€4/month in EU. Strong value for always-on workloads if EU latency is acceptable. |

## Persistent Storage

Session data, memory, and cron state are written to `data_dir` (configurable in `krill.toml`, defaults to `~/.krill`). For containerized deployments, mount a volume at that path so data survives container restarts and redeployments.

## Local

Running locally is the simplest and most tested option:

```bash
julia --project=. --threads=auto bin/krill.jl
```

All features work out of the box. If you want to use `claude_code` or `codex`, authenticate both CLIs beforehand:

```bash
claude auth login    # Claude Code — opens browser for OAuth
codex auth           # Codex — opens browser for OAuth
```

## GCP Compute Engine (Recommended)

### One-time VM Setup

**1.** Create a VM (e2-medium recommended — Julia's JIT needs headroom):

```bash
gcloud compute instances create krill \
  --zone=asia-southeast1-c \
  --machine-type=e2-medium \
  --image-family=debian-12 \
  --image-project=debian-cloud
```

**2.** SSH in:

```bash
gcloud compute ssh krill --zone asia-southeast1-c
```

**3.** Install Docker:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

**4.** Install and configure gcloud (needed for Artifact Registry auth):

```bash
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud init
```

Select the Compute Engine service account when prompted, and set your project ID (`your-gcp-project-id`).

That's it — you never need to clone the repo or manage the process manually. All deployments are handled by CI.

### GitHub Actions CD

Push to `main` triggers the deploy workflow (`.github/workflows/deploy.yml`):

1. Builds the Docker image
2. Pushes to Artifact Registry (`asia-southeast1-docker.pkg.dev/your-gcp-project-id/krill`)
3. SSHs into the VM, pulls the new image, replaces the running container

You can also trigger a manual deploy from any branch via **Actions → Deploy to Compute Engine → Run workflow**.

### Required GitHub Secrets

| Secret | Value |
|---|---|
| `GCP_SA_KEY` | Service account key JSON |
| `GCP_SSH_KEY` | Contents of `~/.ssh/google_compute_engine` (private key) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `OPENAI_API_KEY` | OpenAI API key |
| `GEMINI_API_KEY` | Gemini API key |
| `GH_PAT` | GitHub personal access token |

### Useful Commands on the VM

```bash
# Check if the container is running
docker ps

# Follow live logs
docker logs krill -f

# Restart the container
docker restart krill

# Stop the container
docker stop krill

# Pull and run a specific image manually
docker pull asia-southeast1-docker.pkg.dev/your-gcp-project-id/krill/krill:latest
```

### SSH Access

```bash
# From local machine
gcloud compute ssh krill --zone asia-southeast1-c

# Or directly with the generated key
ssh -i ~/.ssh/google_compute_engine YOUR_USER@YOUR_VM_IP
```

For VS Code Remote-SSH, add to `~/.ssh/config`:

```
Host krill-vm
  HostName YOUR_VM_IP
  User YOUR_USER
  IdentityFile ~/.ssh/google_compute_engine
```

Then **Cmd+Shift+P** → `Remote-SSH: Connect to Host` → `krill-vm`.

## Cloud Run (Not Recommended)

Cloud Run is designed for stateless HTTP request handlers — not long-running polling bots. Krill can run on it but fights the model at every level:

- **Scale-to-zero** kills the polling loop and background tasks
- **CPU throttling** between requests stalls the poll loop
- **No local filesystem** — sessions and memory need external storage (GCS FUSE)
- **Julia cold starts** take 60-100s, hitting Cloud Run's default startup timeouts
- **No interactive auth** for `claude_code` / `codex` — browser-based OAuth not possible in containers

If you still want to use Cloud Run, the old `cloudrun.yaml` config with all the required workarounds is preserved in the repo.
