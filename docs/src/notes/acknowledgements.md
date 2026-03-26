# Acknowledgements

Krill.jl exists because of the ideas and work of others.

## nanobot

This project was directly inspired by [nanobot](https://github.com/HKUDS/nanobot) by [HKUDS](https://github.com/HKUDS). nanobot demonstrated that an AI agent runtime could be lightweight, readable, and composable without the overhead of large frameworks. Krill started as an attempt to bring that same philosophy to Julia — a single-file-readable agent that does the important things well and stays out of the way.

## OpenClaw / ClawHub

The skills system draws from the [OpenClaw](https://github.com/openclaw/openclaw) ecosystem and its community skill registry [ClawHub](https://clawhub.ai). The idea that agent capabilities should be portable markdown documents — discoverable, installable, and shareable — comes from this lineage. OpenClaw's various language implementations (Ruby, Python, Go) showed that the skill format could be universal across runtimes.

## Open-source LLM tooling

Krill also builds on patterns from:

- [openai-agents-python](https://github.com/openai/openai-agents-python) — agent loop and tool-calling patterns
- [Google ADK](https://github.com/google/adk-python) — agent development kit design and multi-tool orchestration patterns
- [Model Context Protocol](https://modelcontextprotocol.io/) — the MCP standard for external tool integration
- The Julia ecosystem — HTTP.jl, JSON3.jl, and the stdlib that make this possible with minimal dependencies
