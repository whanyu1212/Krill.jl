# Use Case Testing

A quick reference for exercising each capability. Send these messages to your running agent to confirm a feature is working end-to-end.

## Slash Commands

No configuration needed — these work out of the box.

```
/help
```

Should display available commands, session turn count, and session age.

```
/new
```

Should clear the session and report how many turns were cleared.

To test `/stop`, send a message that triggers a long tool chain (e.g., a web search + follow-up), then quickly send:

```
/stop
```

Should respond with "Stopped. The running task has been cancelled."

## Web Search

**Requires:** `provider_builtins = true` (OpenAI `web_search` or Gemini `googleSearch`)

```
What is the latest version of Julia?

Search the web for recent news about OpenAI.
```

The response should include cited sources. If it answers from training data only (no citations), `provider_builtins` may be off or the provider doesn't support it.

## Web Fetch

**Requires:** `local_builtins = true`

```
Read this page and summarise it: https://julialang.org
```

The agent should call `web_fetch` to retrieve the URL content. If it uses provider-native search instead of fetching the specific URL, the tool selection guidance in AGENTS.md may need tuning.

## File Operations

**Requires:** `local_builtins = true`, a `context/` workspace directory

```
Create a file called notes.md in the workspace with today's date and a short greeting.

List the files in the workspace.

Read the file notes.md you just created.
```

File tools are sandboxed to `context/` by default. A path-escape attempt should be denied.

## GitHub

**Requires:** `local_builtins = true`, `gh` CLI installed and authenticated

```
Show me the open issues on whanyu1212/Krill.jl

How many stars does whanyu1212/Krill.jl have?
```

The agent should use the `github` tool wrapping `gh`. Verify it uses `--json` output for structured results.

## Memory

**Requires:** `memory = true`, `memory_consolidation = true`

```
Remember that my preferred language is Julia and I work on data pipelines.
```

Restart the agent, then:

```
What do you remember about me?
```

The agent should recall the preference from `~/.krill/memory/<session>/MEMORY.md` without it being in the current conversation history.

## Cron Scheduling

**Requires:** `cron = true`

Test a one-shot reminder (uses `at` schedule with computed UTC datetime):

```
Remind me in 2 minutes to check the oven.
```

The agent should create a one-shot job. After 2 minutes, it should send the reminder unprompted.

Test a recurring job (uses `interval` schedule):

```
Set a reminder every 1 minute to say "tick".
```

After adding the job, wait a minute — the agent should send "tick" unprompted.

Then manage jobs:

```
List my scheduled jobs.

Remove all cron jobs.
```

Check `~/.krill/cron/jobs.json` to confirm persistence across restarts.

## Subagents

**Requires:** `subagents = true`

```
Spawn a subagent to research the history of the Julia programming language and summarise it in three bullet points.
```

The parent session should continue normally. When the subagent finishes, its summary is injected back into the conversation.

## Skills

**Requires:** `builtin_skills = true` or a custom skill in `context/skills/`

```
What skills do you have available?
```

For an always-on skill, its instructions are injected every turn — verify the agent's behaviour matches the skill document. For an on-demand skill:

```
Use the <skill-name> skill to help me with X.
```

## MCP Tools

**Requires:** a configured `[[profile.mcp]]` block in `krill.toml`

```
List the tools available from the filesystem MCP server.

Use the filesystem MCP server to list files in the context directory.
```

MCP tool names are namespaced as `mcp_<name>_<tool>` — confirm the tool IDs in the response match the server's declared tools.

## Google Workspace (Gmail)

**Requires:** `google_workspace = true`, `gws` CLI installed and authenticated (`gws auth login`)

```
Check my inbox for unread emails.

Send an email to test@example.com with subject "Hello from Krill" and body "This is a test email sent by my AI agent."

Reply to the latest email from LinkedIn saying "Thanks, I'll take a look."
```

The agent should use the `google_workspace` tool with `gws gmail +triage`, `+send`, and `+reply` commands respectively. Verify the email appears in your Gmail Sent folder.

::: warning
**Other Google Workspace services** (Calendar, Drive, Sheets, Docs) are supported by the `gws` CLI but have not been thoroughly tested with Krill. Gmail send/triage/reply is the primary tested workflow. If you use other services, verify the commands work via `gws` directly first.
:::

## Shell Exec

**Requires:** `exec = true` (disabled by default — enable only in trusted environments)

```
Run the shell command: echo "hello from exec"

What is the current working directory?
```

## Claude Code / Codex Delegation

**Requires:** `claude_code = true` or `codex = true`, CLI authenticated beforehand

```
Use Claude Code to find all Julia files in the workspace and summarise what each one does.

Delegate to Codex: write a Julia function that computes the nth Fibonacci number and save it to the workspace.
```

These spawn a subprocess. The agent should report the result, cost/token usage, and session/thread ID when complete.

## Telegram Formatting

**Requires:** Telegram channel enabled

Send a message that triggers a table in the response:

```
Show me a comparison table of Julia, Python, and Rust — columns for typing, speed, and ecosystem size.
```

Tables should render as aligned monospace text in Telegram (inside a `<pre>` block), not raw pipe characters. Bold, italic, code blocks, and links should also render correctly.

## History Summarization

**Requires:** `history_summarization = true`

Have a long conversation (20+ exchanges), then:

```
Summarise what we've discussed so far.
```

When the context window fills, Krill compresses old turns into a summary and continues. Check the session JSONL at `~/.krill/sessions/<session>/history.jsonl` — older turns will be replaced by a summary entry.
