# Architecture

A message comes in from Telegram or Discord, gets processed by an LLM with tools, and a reply goes back out. Everything in between is Krill.

## System Layers

```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "primaryColor": "#1a2e4a",
    "primaryTextColor": "#c8d8f0",
    "primaryBorderColor": "#4063d8",
    "lineColor": "#4a6490",
    "secondaryColor": "#0f1e33",
    "tertiaryColor": "#0b1524",
    "clusterBkg": "#0d1e35",
    "clusterBorder": "#2a3f66",
    "titleColor": "#82a0ff",
    "edgeLabelBackground": "#0f1e33",
    "fontFamily": "JuliaMono, IBM Plex Mono, Menlo, monospace",
    "fontSize": "15px"
  }
}}%%
graph TD
  subgraph T["Transport"]
    TG["Telegram\npolling · webhook"]
    DC["Discord\ngateway · REST"]
  end

  subgraph O["Orchestration"]
    MH["MessageHub\ninbound / outbound queues"]
    CM["ChannelManager\nretry · priority · dead letters"]
    SS["Sessions\nper-session locks · JSONL history"]
    DD["Deduplication\nbounded event-ID set"]
  end

  subgraph I["Intelligence"]
    SC["Session consumer\nprompt build → LLM → tool loop → persist"]
    TR["ToolRegistry\nlocal · MCP · skills"]
    LM["LLM providers\nOpenAI · Gemini"]
    MEM["Memory\nconsolidate · summarize"]
    CR["Cron · Subagents\nscheduled · background tasks"]
  end

  TG -->|InboundMessage| MH
  DC -->|InboundMessage| MH
  MH --> DD --> SS --> SC
  SC --> TR
  SC --> LM
  SC --> MEM
  SC --> CR
  SC -->|OutboundMessage| MH
  MH --> CM
  CM -->|send| TG
  CM -->|send| DC

  style T fill:#112240,stroke:#4063d8,stroke-width:1.5px,color:#c8d8f0
  style O fill:#0d1e35,stroke:#2a5298,stroke-width:1.5px,color:#c8d8f0
  style I fill:#0b1c30,stroke:#1e4080,stroke-width:1.5px,color:#c8d8f0
```

## Message Flow

```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "primaryColor": "#1a2e4a",
    "primaryTextColor": "#c8d8f0",
    "primaryBorderColor": "#4063d8",
    "lineColor": "#4a6490",
    "secondaryColor": "#0f1e33",
    "tertiaryColor": "#122033",
    "activationBorderColor": "#4063d8",
    "activationBkgColor": "#162840",
    "actorBkg": "#0f1e33",
    "actorBorder": "#4063d8",
    "actorTextColor": "#c8d8f0",
    "actorLineColor": "#2a3f66",
    "signalColor": "#82a0ff",
    "signalTextColor": "#c8d8f0",
    "labelBoxBkgColor": "#0d1e35",
    "labelBoxBorderColor": "#2a3f66",
    "labelTextColor": "#c8d8f0",
    "loopTextColor": "#c8d8f0",
    "noteBkgColor": "#162840",
    "noteBorderColor": "#4063d8",
    "noteTextColor": "#c8d8f0",
    "fontFamily": "JuliaMono, IBM Plex Mono, Menlo, monospace",
    "fontSize": "15px"
  }
}}%%
sequenceDiagram
  participant P as Platform
  participant CH as Channel
  participant HUB as MessageHub
  participant SES as Session
  participant LLM as LLM
  participant TOOLS as Tools
  participant MGR as ChannelManager

  P->>CH: raw event
  CH->>HUB: normalized message
  HUB->>SES: dequeue
  SES->>SES: load history
  SES->>LLM: prompt
  LLM-->>SES: response

  loop tool calls
    SES->>TOOLS: execute
    TOOLS-->>SES: result
    SES->>LLM: continue
    LLM-->>SES: response
  end

  SES->>SES: persist
  SES->>HUB: reply
  HUB->>MGR: dispatch
  MGR->>CH: send
  CH->>P: delivered
```

## Tool Assembly

```mermaid
%%{init: {
  "theme": "base",
  "themeVariables": {
    "primaryColor": "#1a2e4a",
    "primaryTextColor": "#c8d8f0",
    "primaryBorderColor": "#4063d8",
    "lineColor": "#4a6490",
    "secondaryColor": "#0f1e33",
    "tertiaryColor": "#0b1524",
    "clusterBkg": "#0d1e35",
    "clusterBorder": "#2a3f66",
    "titleColor": "#82a0ff",
    "edgeLabelBackground": "#0f1e33",
    "fontFamily": "JuliaMono, IBM Plex Mono, Menlo, monospace",
    "fontSize": "15px"
  }
}}%%
graph LR
  subgraph LOCAL["Local built-ins"]
    FT["file tools\nread · write · edit · list"]
    WB["web tools\nsearch · fetch"]
    GH["github\ngh CLI wrapper"]
    EX["exec\n(optional)"]
    CC["claude_code / codex\n(optional)"]
  end

  subgraph SKILLS["Skills"]
    SK["context/skills/*/SKILL.md\nalways-on or on-demand"]
    BSK["built-in skills\nbundled with Krill"]
  end

  subgraph MCP["MCP servers"]
    MS1["stdio server\nnpx / uvx process"]
    MS2["HTTP server\nstreamable_http · sse"]
  end

  TR["ToolRegistry"]
  PC["PromptContext\nskill summaries +\nalways-on bodies"]
  SC["Session consumer"]

  FT --> TR
  WB --> TR
  GH --> TR
  EX --> TR
  CC --> TR
  MS1 -->|mcp_name_tool| TR
  MS2 -->|mcp_name_tool| TR
  SK --> PC
  BSK --> PC
  TR --> SC
  PC --> SC

  style LOCAL fill:#112240,stroke:#4063d8,stroke-width:1.5px,color:#c8d8f0
  style SKILLS fill:#0d1e35,stroke:#389826,stroke-width:1.5px,color:#c8d8f0
  style MCP fill:#0b1c30,stroke:#c58d16,stroke-width:1.5px,color:#c8d8f0
```

## Core Components

### `Types`

The runtime boundary types shared by all subsystems:

- `InboundMessage`, `OutboundMessage`
- content parts: `TextPart`, `BinaryPart`, `ToolCallPart`, `ToolResultPart`
- `DeliveryPolicy`, `ErrorEnvelope`
- tool lifecycle events


### `MessageHub`

`MessageHubState` decouples producers from consumers.

- inbound channel for normalized user/platform events
- outbound channel for generated replies or tool-originated messages
- blocking and non-blocking APIs for backpressure-aware wiring


### `ChannelManager`

`ChannelManagerState` owns outbound dispatch.

- sender registration by channel symbol
- retry / timeout / priority / `drop_if_late`
- dead-letter capture
- dispatch events and counters


### `ChannelInterface`

`AbstractChannel` keeps integrations minimal: identify, normalize, send, start/stop.


### `Sessions` and `Memory`

Session history and durable assistant memory are separated on purpose.

- `SessionStore` writes ordered turn history to JSONL
- `MemoryStore` writes `MEMORY.md`, `HISTORY.md`, and `state.json`
- the memory consolidator periodically compresses durable facts out of long histories


### `Tools`, `Skills`, and `MCP`

The intelligence surface is layered rather than monolithic.

- `ToolRegistry` holds local tool definitions and validation
- skills provide markdown instructions — always-on or on-demand via `read_skill`
- MCP connections discover external tools and register them into the same registry

**Note:** Julia has no official MCP SDK. Krill's MCP client (`src/core/mcp.jl`) implements JSON-RPC initialize / list / call over stdio and HTTP from scratch. It covers common cases well but may have edge-case issues with unusual servers. See [Known Limitations](/guide/features#Known-Limitations).


### `PromptContext`

Krill composes the instruction stack explicitly on every turn:

1. base system prompt
2. workspace bootstrap docs (`SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`)
3. skill metadata summary
4. always-on skill bodies
5. session memory
6. tool-output safety notice
7. runtime metadata (channel, session key, chat ID, UTC timestamp)


### `LLM`

- OpenAI Responses API payloads
- Gemini native `generateContent`
- Gemini OpenAI-compatible chat completions
- context-window trimming and dropped-history summarization
- tool call extraction and continuation loops


### `Cron` and `Subagent`

Both inject work back into the same runtime rather than creating a separate orchestration layer.

- cron jobs publish synthetic inbound messages back into `MessageHub`
- subagents run in isolated sessions and inject a summarized result into the origin conversation

## `RuntimeState` — Composition Root

`RuntimeState(...)` is where the whole stack is assembled: channels, tool registry, MCP connections, prompt builder, LLM processor, memory hooks, cron, and subagents. Startup and shutdown are owned here.

## Filesystem Layout

### Agent file sandbox (`<project>/context`)

| Path | Owned by | Purpose |
| --- | --- | --- |
| `SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md` | Prompt context | bootstrap docs injected into system prompt |
| `skills/` | Skills loader | context-local skill definitions |

The agent can read and write inside this directory. File tools are restricted to it by default.

### Krill internal state (`~/.krill`)

| Path | Owned by | Purpose |
| --- | --- | --- |
| `sessions/.../history.jsonl` | `SessionStore` | ordered user/assistant turns |
| `memory/.../MEMORY.md` | `MemoryStore` | consolidated durable memory |
| `memory/.../HISTORY.md` | `MemoryStore` | archived consolidation batches |
| `memory/.../state.json` | `MemoryStore` | consolidation offsets and failures |
| `cron/jobs.json` | `CronService` | persisted schedules |
| `dead_letters.jsonl` | `ChannelManager` | failed dispatch records |

Krill manages this directory itself — it is never exposed to the agent's file tools.

