# Acknowledgements

Krill.jl exists because of the ideas and work of others.

## nanobot

This project was directly inspired by [nanobot](https://github.com/HKUDS/nanobot) by [HKUDS](https://github.com/HKUDS). nanobot demonstrated that an AI agent runtime could be lightweight, readable, and composable without the overhead of large frameworks. Krill started as an attempt to bring that same philosophy to Julia.

## OpenClaw / ClawHub

Krill's skills system is inspired by [OpenClaw](https://github.com/openclaw/openclaw) and its community registry [ClawHub](https://clawhub.ai). OpenClaw is a broader concept: an open protocol for defining agent capabilities in a portable, runtime-agnostic way. The core idea is that what an agent *can do* should be separable from the runtime it runs on — skills are first-class artifacts that can be discovered, shared, and reused across different agent implementations. OpenClaw has been implemented in multiple languages (including Python, Go, and Rust), which validates the protocol's language-agnostic design. Krill participates in this ecosystem by supporting the same skill format and the ClawHub registry.

## Open-source LLM tooling

Krill also builds on patterns from:

- [openai-agents-python](https://github.com/openai/openai-agents-python) — agent loop and tool-calling patterns
- [Google ADK](https://github.com/google/adk-python) — agent development kit design and multi-tool orchestration patterns
- [Model Context Protocol](https://modelcontextprotocol.io/) — the MCP standard for external tool integration
- The Julia ecosystem — HTTP.jl, JSON3.jl, and the stdlib that make this possible with minimal dependencies
