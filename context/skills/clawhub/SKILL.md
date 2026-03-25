---
name: clawhub
description: "Search, install, update, and manage community skills from ClawHub, the public skill registry. Use when the user asks to find skills, install new capabilities, browse available skills, update installed skills, or check what skills are installed."
requires_bins: npx
---

# ClawHub

Public skill registry for AI agents. Search by natural language (vector similarity).

All commands use `exec` with the workspace `--workdir` flag pointing at the Krill workspace so skills install into `context/skills/` where Krill discovers them.

**Critical:** Always include `--workdir /Volumes/Expansion/Krill.jl/context` in every command. Without it, skills install to the wrong location.

## Search

Find skills by natural language query:
```bash
npx --yes clawhub@latest search "web scraping" --limit 5
```

Results show: `slug  Name  (relevance score)`. Use the slug for install/inspect.

## Inspect Before Installing

Preview a skill's metadata without installing:
```bash
npx --yes clawhub@latest inspect <slug>
```

View its files:
```bash
npx --yes clawhub@latest inspect <slug> --files
```

Read a specific file:
```bash
npx --yes clawhub@latest inspect <slug> --file SKILL.md
```

Always inspect before installing to verify the skill is relevant and well-structured.

## Install

```bash
npx --yes clawhub@latest install <slug> --workdir /Volumes/Expansion/Krill.jl/context
```

This places the skill into `context/skills/<slug>/`. Use `--force` to overwrite an existing skill.

**Important:** After installing, remind the user that a restart is needed for Krill to discover the new skill.

## Update

Update a specific skill:
```bash
npx --yes clawhub@latest update <slug> --workdir /Volumes/Expansion/Krill.jl/context
```

Update all installed skills:
```bash
npx --yes clawhub@latest update --all --workdir /Volumes/Expansion/Krill.jl/context
```

## Uninstall

```bash
npx --yes clawhub@latest uninstall <slug> --workdir /Volumes/Expansion/Krill.jl/context --yes
```

## List Installed

```bash
npx --yes clawhub@latest list --workdir /Volumes/Expansion/Krill.jl/context
```

## Compatibility Notes

- ClawHub skills use the same SKILL.md format as Krill (YAML frontmatter + Markdown body).
- Community skills may reference tools by different names (e.g., `bash` instead of `exec`). After installing, read the SKILL.md and note any tool name mismatches.
- Skills that depend on nanobot-specific features (like `cron()` function syntax) may need minor edits to work with Krill's tool names (`cron_add`, `github`, `exec`, etc.).
- If an installed skill overwrites a Krill-adapted skill you already have, restore your version or merge the changes.
- No API key needed for search, inspect, and install. Login (`clawhub login`) is only required for publishing.
