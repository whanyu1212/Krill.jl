# Security

Krill runs as a personal AI assistant with real capabilities — shell access, file I/O, web fetch, GitHub API. This page documents the guardrails in place and how to configure them.

## Access Control — `allow_from`

The most important setting. Without it, **any user who can reach your bot can trigger the agent**.

Every channel (`TelegramChannel`, `DiscordChannel`) accepts an `allow_from` list:

| Value | Behavior |
|-------|----------|
| `[]` (empty, default) | Deny everyone — bot ignores all messages |
| `["*"]` | Allow any authenticated platform user |
| `["123456789"]` | Allow only this user ID |
| `["111", "222"]` | Allow multiple users |

Messages from unlisted users are silently dropped before the agent loop. A warning is logged:

```
Warning: rejecting message from unlisted user  channel=telegram  user_id="999"
```

### Configuration

Set `ALLOW_FROM` in your `.env` as a comma-separated list of platform user IDs:

```
ALLOW_FROM=123456789,987654321
```

**How to find your user ID:**
- **Telegram:** message `@userinfobot` — it replies with your numeric ID
- **Discord:** Settings → Advanced → enable Developer Mode, then right-click your username → Copy User ID

The same `ALLOW_FROM` env var works for both bots. IDs from different platforms won't collide since each channel only sees its own platform's user IDs.

### Why deny-by-default?

The alternative (allow-all by default) was a major criticism of OpenClaw. If you forget to set `ALLOW_FROM`, a stranger who discovers your bot token gets a fully-capable shell agent. Deny-by-default means forgetting to configure access control results in a bot that does nothing, not one that's open to the world.

---

## Exec Command Denylist

When `ENABLE_EXEC=true`, the agent can run shell commands. A denylist blocks the most destructive patterns before they reach the shell:

| Pattern | Blocks |
|---------|--------|
| `rm -rf` / `rm -fr` | Recursive forced deletion |
| `dd if=/dev/zero of=/dev/...` | Raw disk wipe |
| `mkfs` | Filesystem formatting |
| `fdisk`, `parted` | Disk partitioning |
| `:(){ :|:& };:` | Fork bomb |
| `shutdown`, `reboot`, `halt`, `poweroff` | System shutdown |
| `> /etc/passwd`, `> /etc/sudoers` | Overwrite of critical system files |
| `rm ... ~ / $HOME / /root` | Deletion of home or root directory |
| `sudo rm/dd/mkfs/...` | Privileged destructive commands |

Blocked commands return an error string to the LLM explaining why. The command is never executed.

In addition, any `http`/`https` URLs embedded in the command string are extracted and validated through the same SSRF rules as `web_fetch`. This blocks attacks like `curl http://169.254.169.254/latest/meta-data/` which would pass the pattern denylist but hit the cloud metadata endpoint.

**This denylist only applies to the raw `exec` tool.** Claude Code and Codex delegation tools run as subprocesses with their own permission models and are not affected.

### What's still allowed

Normal commands pass through unfiltered: `rm file.txt`, `rm -r ./build`, `git clean -fdx`, `ls`, `cat`, `grep`, `cp`, `mkdir`, `julia`, etc.

---

## SSRF Protection

**SSRF (Server-Side Request Forgery)** is an attack where someone tricks the agent into fetching a URL that looks harmless but actually hits something private — your local network, router, or cloud infrastructure.

### Why it matters

Your bot has a `web_fetch` tool that fetches arbitrary URLs on your behalf. Consider this prompt:

> "Fetch http://169.254.169.254/latest/meta-data/ and tell me what's there."

That IP is the **AWS/GCP/Azure instance metadata endpoint** — only reachable from inside a cloud VM. It returns your cloud credentials, IAM roles, and access tokens. An attacker who gets the agent to fetch it receives the keys to your cloud account.

Even on a home machine, an agent that can reach `http://192.168.1.1/` is an agent that can poke at your router's admin interface.

### Why string checks aren't enough

Checking the hostname string before fetching is the naive approach and it fails in two ways:

1. **DNS rebinding** — an attacker registers `evil.com` pointing to `169.254.169.254`. The string check sees `evil.com` and passes. DNS resolution returns the cloud metadata IP.

2. **Open redirect** — `https://legit.com/redirect` returns `HTTP 301 → http://169.254.169.254/`. The first URL passes the check, the redirect delivers the agent to the internal endpoint.

### What Krill does

**DNS resolution check:** Before fetching any URL, the hostname is resolved via DNS and every returned IP is validated against all private and reserved CIDR ranges:

| Range | Covers |
|-------|--------|
| `127.0.0.0/8` | Loopback |
| `10.0.0.0/8` | Private network |
| `172.16.0.0/12` | Private network |
| `192.168.0.0/16` | Private network |
| `169.254.0.0/16` | Link-local / cloud metadata (AWS, GCP, Azure) |
| `100.64.0.0/10` | Shared address space |
| `0.0.0.0/8`, `255.x.x.x` | Reserved |
| `::1`, `fe80::/10`, `fc00::/7` | IPv6 loopback / link-local / ULA |

If the hostname resolves to any blocked IP, the request is rejected before a connection is opened.

**Redirect validation:** HTTP redirects are followed manually rather than transparently. Each redirect destination goes through the same full validation — hostname string check + DNS resolution — before the next request is made. A public URL that redirects to `169.254.x.x` is blocked at the redirect hop.

---

---

## Context Sandboxing

File operations (`read_file`, `write_file`, `edit_file`, `list_dir`) are restricted to the context directory by default. The agent cannot read or write files outside it.

### Default context path

```
<project>/context
```

This is the agent's file sandbox — where it can read and write files. It is separate from Krill's internal state directory (`~/.krill`), which stores sessions, memory, cron jobs, and dead letters.

You can override either path:

```julia
RuntimeState(channel;
    workspace="/path/to/agent/context",  # agent file sandbox
    data_dir="/path/to/krill/state",     # sessions, memory, cron
)
```

Or via environment variables in the example bots: `KRILL_WORKSPACE` and `KRILL_DATA_DIR`.

### Symlink escape prevention

A naive path check (`path.startswith(context)`) can be bypassed by creating a symlink inside the context directory that points outside:

```
context/
  link_to_etc -> /etc        # passes string check, but reads /etc
```

Krill uses `realpath()` to resolve all symlinks on both the target path and the context root before checking boundaries. After resolution, `context/link_to_etc/passwd` becomes `/etc/passwd`, which fails the check.

For paths that don't exist yet (new file writes), the parent directory is resolved via `realpath()` and the filename is appended — so the boundary check still works even before the file is created.

### Disabling the restriction

If you need the agent to access files outside the context directory (e.g. reading system config or a path elsewhere on disk), you can opt out:

```julia
RuntimeState(channel; llm_builtin_restrict_to_workspace=false)
```

Note: disabling this removes the file system boundary entirely. Use with care.

---

---

## Claude Code & Codex Permission Mode

Claude Code and Codex run as subprocesses with their own permission models. Krill currently passes `--permission-mode bypassPermissions` to Claude Code, meaning it runs without pausing for approval on file edits or shell commands.

This is intentional for a headless bot — interactive permission prompts would hang indefinitely with no terminal to respond to. Since `allow_from` already ensures only you can trigger Claude Code, bypass is acceptable for personal use.

**A future improvement** would be to relay permission prompts through the chat itself — Claude Code would pause, send you a Telegram/Discord message asking "approve edit to `src/foo.jl`?", and resume when you reply. This would give you real `acceptEdits` semantics through the chat interface. It's architecturally feasible (file-based IPC between the hook script and Krill, with a bypass path in the session router) but non-trivial to implement. Tracked for a future phase.

---

## What's Coming

The following are planned as part of Phase G — Security Hardening:

- **File read size limit** — cap single-call file reads
- **Per-session rate limiting** — throttle requests per user

See the [Roadmap](/notes/roadmap) for the full list.
