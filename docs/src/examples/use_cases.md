# Use Case Testing

A quick reference for exercising each capability. Send these messages to your running agent to confirm a feature is working end-to-end.

## Web Search

**Requires:** `provider_builtins = true` (OpenAI `web_search` or Gemini `googleSearch`)

```
What is the latest version of Julia?

Search the web for recent news about OpenAI.
```

The response should include cited sources. If it answers from training data only (no citations), `provider_builtins` may be off or the provider doesn't support it.

## File Operations

**Requires:** `local_builtins = true`, a `context/` workspace directory

```
Create a file called notes.md in the workspace with today's date and a short greeting.

List the files in the workspace.

Read the file notes.md you just created.
```

File tools are sandboxed to `context/` by default. A path-escape attempt should be denied.

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

```
Set a reminder every 1 minute to say "tick".

List my scheduled jobs.

Remove all cron jobs.
```

After adding the job, wait a minute — the agent should send "tick" unprompted. Check `~/.krill/cron/jobs.json` to confirm persistence.

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

**Requires:** `claude_code = true` or `codex = true`

```
Use Claude Code to find all Julia files in the workspace and summarise what each one does.

Delegate to Codex: refactor the function in context/example.jl to use a more idiomatic style.
```

These spawn a subprocess and stream progress back. Useful for multi-step research or code changes across many files.

## Hooks (Agent API)

**Requires:** running via `main_agent()` or a custom `Agent` with `AgentHooks`

Watch the Julia process stdout while sending any tool-triggering message:

```
Search the web for the Julia programming language.
```

You should see `@info "Tool called"` and `@info "Tool result"` log lines printed by the `on_tool_call` / `on_tool_result` hooks defined in `main_agent()`.

## History Summarization

**Requires:** `history_summarization = true`

Have a long conversation (20+ exchanges), then:

```
Summarise what we've discussed so far.
```

When the context window fills, Krill compresses old turns into a summary and continues. Check the session JSONL at `~/.krill/sessions/<session>/history.jsonl` — older turns will be replaced by a summary entry.
