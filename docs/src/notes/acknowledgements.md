# Acknowledgements

Krill.jl wouldn't exist without the work of people who built things worth learning from.

## nanobot

The most direct inspiration for this project is [nanobot](https://github.com/HKUDS/nanobot) by [HKUDS](https://github.com/HKUDS). It showed that an AI agent runtime could be lightweight, readable, and composable without reaching for a heavy framework. Krill started as an attempt to carry that same philosophy into Julia.

## OpenClaw / ClawHub

[OpenClaw](https://github.com/openclaw/openclaw) is the open-source personal AI assistant that nanobot is a variant of. A lot of Krill's design thinking traces back to OpenClaw — the skill system, the bootstrap-docs-as-prompt pattern, and the idea that agent capabilities should be modular and user-composable. [ClawHub](https://clawhub.ai) is OpenClaw's community skill registry. Krill integrates with it — see [Security](/guide/security) for how that works.

## Open-source LLM tooling

Krill also learned from:

- [openai-agents-python](https://github.com/openai/openai-agents-python) — agent loop and tool-calling patterns
- [Google ADK](https://github.com/google/adk-python) — multi-tool orchestration design
- [Model Context Protocol](https://modelcontextprotocol.io/) — the MCP standard for external tool integration
- The Julia ecosystem — HTTP.jl, JSON3.jl, and the stdlib that make this possible with minimal dependencies