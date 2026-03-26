# Roadmap

Planned work, loosely prioritized. Nothing here is committed — priorities shift. Open an issue if something matters to you.

## Near-term

- **More channels** — WhatsApp (Twilio / Meta Cloud API) and Slack
- **Voice support** — Real-time API streaming for voice conversations through Telegram and Discord
- **Profile-based tool loadouts** — Named tool profiles (`coding`, `research`, `minimal`) to reduce schema payload size and inference latency
- **Per-tool permission UI** — Per-session allowlist/denylist without config reload
- **Chat-mediated Claude Code approvals** — Pause for user approval when Claude Code needs permission, via file-based IPC
- **File read size cap** — Configurable limit to prevent context blowout on large files
- **Per-session rate limiting** — Throttle LLM calls per user/session to protect against runaway loops

## Medium-term

- **Webhook hardening** — HMAC signature verification for Telegram webhook mode
- **MCP stress testing** — Dedicated test harness for adversarial transport conditions; replace custom client when an official Julia MCP SDK exists
- **Agent harness expansion** — `before_llm`/`after_llm` hooks, `on_error` hook, headless `run_once()` entry point, session replay for regression testing
- **RAG-backed memory** — Vector-indexed memory with semantic retrieval instead of full `MEMORY.md` dump each turn
- **Streaming responses** — Token-by-token streaming to chat platforms via edit-in-place
- **Structured output** — JSON Schema validation on LLM responses before tool dispatch
- **Multi-modal input** — Forward images, voice, and documents from channels to the LLM
- **Image generation output** — Display OpenAI `image_generation` results in Telegram/Discord

## Longer-term

- **Additional LLM providers** — Anthropic Claude (Messages API), local models via Ollama/llama.cpp
- **Versioned context directory** — Migration layer for evolving skill and bootstrap doc schemas
- **Web dashboard** — Local read-only UI for browsing session history, memory, and cron jobs
- **Platform comparison** — Test deployment on Fly.io, Railway, bare VPS and document trade-offs
