---
name: memory
description: Two-layer memory system with consolidated long-term memory and append-only history. Always active — provides guidance on when and how to update memory.
always: true
---

# Memory

## Structure

- **MEMORY.md** — Long-term facts: user preferences, project context, relationships, ongoing goals. Always loaded into your context at the start of each session.
- **HISTORY.md** — Append-only event log. NOT loaded into context. Each entry starts with `[YYYY-MM-DD HH:MM]`. Search it when you need to recall past events.

Both files live in the workspace memory directory.

## When to Update MEMORY.md

Write important facts immediately using `edit_file` or `write_file`:
- User preferences ("I prefer metric units", "call me by first name")
- Project context ("The API uses OAuth2", "deploy target is fly.io")
- Relationships ("Alice is the project lead", "Bob handles infra")
- Ongoing goals or constraints ("freeze on non-critical merges until March 28")

Remove or update facts that become stale or incorrect.

## Searching History

Choose the method based on file size:

**Small HISTORY.md** — read the file, then search in-memory:
```
read_file(path="memory/HISTORY.md")
```

**Large HISTORY.md** — use `exec` for targeted search:
```
exec(command="grep -i 'keyword' memory/HISTORY.md | tail -20")
```

## Auto-consolidation

When sessions grow large, old conversations are automatically summarized:
- Durable facts are extracted to MEMORY.md.
- Events are appended to HISTORY.md with timestamps.
- You do not need to manage this process.

## Rules

- Prefer updating MEMORY.md immediately over waiting for auto-consolidation.
- Do not store secrets in memory unless the user explicitly asks.
- Keep MEMORY.md concise and factual — it's loaded every session.
