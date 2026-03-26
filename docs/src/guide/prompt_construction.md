# Prompt Construction

Krill assembles the final system prompt from multiple sources at runtime. This page explains how each piece is loaded and composed into the instructions the LLM sees.

## Sources

The system prompt is built from these sources, in order:

| Source | Location | Purpose |
| --- | --- | --- |
| Base system prompt | `[profile] system_prompt` in `krill.toml` | Core personality, tool selection rules, response style |
| Bootstrap docs | `context/AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md` | Domain knowledge injected as context |
| Skills summary | Generated from `context/skills/*/SKILL.md` | One-line list of available skills |
| Always-on skills | Skills with `always: true` in frontmatter | Full skill content auto-injected |
| Session memory | `~/.krill/memory/{session_key}.json` | Per-session facts from previous conversations |
| Tool safety notice | Hardcoded in `prompt_context.jl` | Instructions for safe tool output handling |
| Runtime metadata | Generated per-turn | Timestamp, channel, session key, chat/user ID |

## Composition Order

The `compose_instructions()` function in `prompt_context.jl` joins all non-empty sections with `---` separators:

```
[Base system prompt from krill.toml]

---

## Workspace Bootstrap Docs

### AGENTS.md
[content]

### SOUL.md
[content]

### USER.md
[content]

### TOOLS.md
[content]

---

## Available Skills
- **cron**: Schedule reminders and recurring tasks [always-on]
- **memory**: Two-layer memory system [always-on]
- **weather**: Get current weather and forecasts
- ...

---

## Active Skills

### Skill: memory
[full memory skill content — loaded because always: true]

### Skill: cron
[full cron skill content — loaded because always: true]

---

## Session Memory
[consolidated facts from previous turns]

---

## Safety
[tool output safety notice]

---

[Runtime Context — metadata only, not instructions]

## Runtime Metadata
- Timestamp (UTC): 2026-03-26T16:30:00Z
- Channel: telegram
- Session Key: telegram:5376052137
- Chat ID: 5376052137
- User ID: 5376052137
```

::: tip Debugging the prompt
At `@info` level, each turn logs `instructions_chars` and `context_messages` — enough to spot if something is missing or unexpectedly large. To see the full composed prompt, run with `JULIA_DEBUG=Krill`. This dumps the entire instructions string every turn, which can be thousands of characters — not pleasant to read in a terminal, but useful for diagnosing silent errors like a missing bootstrap doc, a skill not being injected, or memory content being dropped.
:::

## Bootstrap Docs

Bootstrap docs are loaded from the `workspace` directory (default `context/`). The default set is:

| Doc | Purpose |
| --- | --- |
| `AGENTS.md` | Agent behavior rules — when to use which tool category |
| `SOUL.md` | Personality, values, communication style |
| `USER.md` | User profile for personalization |
| `TOOLS.md` | Detailed tool documentation beyond JSON schemas |

Docs are loaded in order. Missing files are silently skipped. Each doc is truncated at `max_chars_per_doc` (default 12,000 characters).

To add custom bootstrap docs, create a markdown file in `context/` and add the filename to the `doc_names` config (or use the default set).

## Skills

Skills are discovered from `context/skills/*/SKILL.md`. Each skill file has YAML frontmatter:

```yaml
---
name: cron
description: Schedule reminders and recurring tasks.
always: true
---
```

**All skills** appear in the skills summary (one-line description each). Skills with `always: true` have their **full content** injected into the system prompt automatically. Other skills can be loaded on demand when the LLM calls the `read_skill` tool.

Use `always: true` sparingly — each always-on skill consumes context in every conversation.

## Tool Schemas

Tool definitions are separate from the system prompt. They're passed to the LLM via the provider's function calling interface (OpenAI `tools` parameter / Gemini `functionDeclarations`). The tool description in the JSON schema is the primary guidance the LLM sees for each tool — it should be accurate and self-contained.

The `TOOLS.md` bootstrap doc provides supplementary guidance (best practices, non-obvious constraints) that doesn't fit in the JSON schema description.

## Provider-Native Tools

Provider-native tools (OpenAI `web_search`, Gemini `googleSearch`, `urlContext`, `codeExecution`) are passed alongside function-calling tools. They're configured in `config/provider.jl` via `provider_tools()` and merged into the tools list at runtime.

For Gemini, function-calling tools are converted from OpenAI format to Gemini format via `_tools_openai_to_gemini()` in `parsing.jl`.

## Memory Injection

Session memory is loaded from disk before each turn and injected as a `## Session Memory` section. Memory is accumulated across conversations and periodically consolidated by the LLM (summarized when context exceeds a threshold). See the memory skill for details on the two-layer memory system.

## Subagent Prompts

Subagents get a simplified system prompt (no bootstrap docs, no skills summary, no memory). Their prompt is a short set of rules defined in `_subagent_system_prompt()` in `runtime.jl`. They receive the same tool schemas as the parent agent (minus spawn, cron, and message tools).

## Customization

To customize the prompt:

- **Change personality** — edit `[profile] system_prompt` in `krill.toml`
- **Add domain knowledge** — create/edit files in `context/` (AGENTS.md, SOUL.md, USER.md, TOOLS.md)
- **Add a skill** — create `context/skills/{name}/SKILL.md` with frontmatter
- **Always-on skill** — set `always: true` in the skill's frontmatter
- **Change bootstrap doc set** — configure `doc_names` in `PromptContextConfig`
