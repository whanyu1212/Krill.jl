# Agents & Subagents

Krill's agent system has two levels: the **main agent** that handles user conversations, and **subagents** that run background tasks in parallel.

## Main Agent

The main agent is configured via the `Agent` struct (built from `krill.toml` at startup). It owns:

- An LLM provider (OpenAI or Gemini)
- A tool registry (all registered tools)
- Session state (history, memory, cancel scope)
- Hooks (`on_tool_call`, `on_tool_result`, `should_interrupt`, `on_turn_start`, `on_turn_end`)

Each inbound message is processed as a **turn**: load history, call LLM, run tool loop (up to `max_tool_iterations`), save history, send response. Turns are FIFO within a session but concurrent across sessions.

### Tool Loop

The core agentic loop in `tool_loop.jl`:

1. Call the LLM with the current message + history + tools
2. If the LLM returns tool calls, dispatch them via the tool registry
3. Append tool results to the conversation
4. Repeat from step 1 until the LLM responds with text only, or `max_tool_iterations` is reached

Tool calls within a single LLM response are executed sequentially. Results are cached by `hash(name, arguments)` within a turn to avoid duplicate dispatches.

### Cooperative Cancellation

Users can send `/stop` to cancel a running turn. This sets a flag in `SessionCancelScope` which is checked between tool iterations. If set, the loop exits with whatever text the LLM has produced so far.

## Subagents

Subagents are background tasks spawned by the main agent via the `spawn` tool. Each subagent:

- Gets its own LLM conversation (fresh history, no shared state)
- Runs in a Julia `@spawn` thread
- Has access to the same tools as the parent (except `spawn`, `cron`, and `message`)
- Reports results back to the originating chat when complete

### Spawning Flow

```
User: "research X in the background"
  → Main agent calls spawn(task="research X")
  → SubagentManager checks concurrent limit (default 5)
  → Creates SubagentTask with unique ID
  → Spawns Julia thread running _run_subagent!()
  → Returns immediately: "Subagent started (id: abc123)"
```

### Subagent Execution

```
_run_subagent!(mgr, task)
  → processor_factory() creates a fresh LLM processor
  → Builds minimal InboundMessage with task description
  → Calls processor(msg, empty_history)
  → LLM runs its own tool loop (up to max_iterations)
  → Result text extracted
  → _finish_task!() records status + result
  → _announce_result!() injects result as InboundMessage
    back to the origin session via the message hub
  → Main agent processes the announcement and relays to user
```

### Subagent Tool Access

Subagents get the same tool set as the parent agent:

- File operations (`read_file`, `write_file`, `edit_file`, etc.)
- Web fetch (`web_fetch`)
- Shell execution (`exec`, if enabled)
- GitHub CLI (`github`)
- Google Workspace (`google_workspace`, if enabled)
- Coding agents (`claude_code`, `codex`, if enabled)
- Provider-native search (OpenAI `web_search` / Gemini `googleSearch`)
- MCP tools (from connected MCP servers)
- Skills (`read_skill`)

Subagents do **not** get:

- `spawn` / `spawn_list` / `spawn_cancel` (no recursive spawning)
- `cron_add` / `cron_list` / `cron_remove` (no scheduling)
- `message` (no direct messaging — results are announced via the hub)

### Managing Subagents

The LLM can use these tools to manage running subagents:

- `spawn_list` — shows all tasks with status and elapsed time
- `spawn_cancel` — cancels a running task by ID (sends `InterruptException` to the thread)

On shutdown, all running subagents are cancelled automatically.

### Configuration

Subagent behavior is controlled via `SubagentConfig`:

| Parameter | Default | Description |
| --- | --- | --- |
| `enable` | `true` | Enable/disable subagent spawning |
| `max_concurrent` | `5` | Maximum running subagents at once |
| `max_iterations` | `15` | Tool loop iterations per subagent |
