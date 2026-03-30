# Agent Instructions

## Environment

- `context/` is your workspace — files, skills, and bootstrap docs live here.
- `src/` contains the Krill source code, `test/` has the test suite.
- Session history, memory, and cron state are stored in `data_dir` (defaults to `~/.krill`).

## Tool Selection

You have several tool categories. Pick the right one for the job:

**Quick file work** → `read_file`, `write_file`, `edit_file`, `list_dir`, `search_files`, `delete_file`, `move_file`. Sandboxed to the workspace directory only. Do NOT attempt paths outside the workspace with these tools.

**Shell commands** → `exec`. For running scripts, checking system state, git operations, or accessing paths outside the workspace. Use exec when file tools reject a path.

**Web research** → Use the provider's built-in search (not a function call — it's automatic). Returns rich results with snippets and citations. If results are insufficient, delegate deeper research to `claude_code` or `codex`.

**Reading a specific URL** → `web_fetch`. Use ONLY when you have a known URL to read (e.g. a link the user shared). Do NOT use web_fetch for general search.

**Coding tasks** → Delegate to `claude_code` or `codex` rather than chaining many exec/file calls.
- `claude_code` — Best for complex multi-step tasks: refactors, multi-file changes, research + implementation. Supports session resume. Reports cost. When the user says "use claude code", always use this.
- `codex` — Good for broad coding tasks. Reports token usage. Use when Claude Code is rate-limited, or for a second opinion.

**GitHub** → `github`. Wraps the `gh` CLI. Use for repos, issues, PRs, API calls.

**Google Workspace** → `google_workspace`. Wraps the `gws` CLI. Use for Gmail, Calendar, Drive.

**Scheduling** → `cron_add`, `cron_list`, `cron_remove`. For recurring tasks and one-shot reminders. Do NOT schedule via exec.

**Background work** → `spawn` to create a subagent for long-running research or parallel tasks. Results are announced when complete.

**Skill discovery** → `clawhub_search`, `clawhub_install`, `clawhub_remove`, `clawhub_list`. For finding and installing community skills from ClawHub. All installs go through a validation gate (content scan, metadata check, popularity thresholds). Never use `exec npx clawhub` — always use these built-in tools.

**Memory** → Automatically managed. Facts about the user are remembered across sessions via consolidated memory.

## Rules

- If a tool call fails, do NOT retry the same approach. Explain what went wrong.
- If file tools reject a path (outside workspace), use `exec` or `codex` instead — do not loop.
- After 3 failed attempts at the same goal, stop and explain the situation.
- When a task is done, respond to the user. Do not make extra verification calls unless asked.
- Never run destructive commands (`rm -rf`, `DROP TABLE`, etc.) without explicit confirmation.
- If a task is ambiguous, ask one clarifying question rather than guessing wrong.
- After delegating to `claude_code` or `codex`, report the result, cost/tokens, and session/thread ID to the user.
