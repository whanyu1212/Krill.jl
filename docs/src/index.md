---
layout: home

hero:
  name: "Krill.jl"
  text: Personal AI assistant runtime in Julia
  tagline: 🦐 A tiny Julia framework for building personal AI assistants across chat platforms, inspired by OpenClaw and nanobot.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting_started
    - theme: alt
      text: Read the Architecture
      link: /guide/architecture
    - theme: alt
      text: Browse the API
      link: /api/reference

features:
  - title: Agents
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/></svg>'
    details: Session orchestration, tool-calling loop, and background subagent spawning — the core intelligence that drives every conversation.
  - title: Tools & MCP
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z"/></svg>'
    details: File ops, web search, GitHub, shell exec, cron scheduling, and external MCP servers — all registered into one tool surface.
  - title: Skills
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 12h-5"/><path d="M15 8h-5"/><path d="M19 17V5a2 2 0 0 0-2-2H4"/><path d="M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3"/></svg>'
    details: Markdown instruction documents that shape assistant behavior. Always-on or on-demand, with dependency checks.
  - title: LLM Providers
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 18V5"/><path d="M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4"/><path d="M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5"/><path d="M17.997 5.125a4 4 0 0 1 2.526 5.77"/><path d="M18 18a4 4 0 0 0 2-7.464"/><path d="M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517"/><path d="M6 18a4 4 0 0 1-2-7.464"/><path d="M6.003 5.125a4 4 0 0 0-2.526 5.77"/></svg>'
    details: OpenAI Responses and Gemini native, with provider-side web search, code execution, and context-window management.
  - title: Context & Memory
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5V19A9 3 0 0 0 21 19V5"/><path d="M3 12A9 3 0 0 0 21 12"/></svg>'
    details: Prompt context, bootstrap docs, session history, durable memory files, and LLM-driven consolidation for lasting context.
  - title: Channels
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16.247 7.761a6 6 0 0 1 0 8.478"/><path d="M19.075 4.933a10 10 0 0 1 0 14.134"/><path d="M4.925 19.067a10 10 0 0 1 0-14.134"/><path d="M7.753 16.239a6 6 0 0 1 0-8.478"/><circle cx="12" cy="12" r="2"/></svg>'
    details: Telegram polling, webhooks, and Discord gateway. Thin adapters that normalize platform events into a shared message contract.
  - title: Runtime
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="8" height="8" x="3" y="3" rx="2"/><path d="M7 11v4a2 2 0 0 0 2 2h4"/><rect width="8" height="8" x="13" y="13" rx="2"/></svg>'
    details: Message hub, dispatch queue, retry policies, dead letters, deduplication, and durable queue primitives that keep the pipeline reliable.
  - title: Security
    icon: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/></svg>'
    details: Per-channel allow_from allowlists, exec denylist + URL scan, SSRF protection with DNS resolution and redirect validation, and symlink-safe workspace sandboxing.
---

## Current Scope

<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; margin-top: 16px;">

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">Agent API</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);"><code>Agent</code>, <code>AgentHooks</code>, <code>RetryConfig</code> — composable, testable, flat-kwarg and struct-based entry points</div>
</div>

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">Agent Capabilities</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);">Built-in tools, provider-native tools, MCP, skills, cron, subagents, prompt context, memory consolidation, history summarization</div>
</div>

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">LLM Providers</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);">OpenAI Responses API · Gemini native <code>generateContent</code> · Gemini OpenAI-compat — with web search, code execution, and URL context</div>
</div>

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">Memory</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);">Per-session LLM-consolidated memory + cross-channel global user profile via <code>/remember</code></div>
</div>

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">Persistence</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);">Session history JSONL, memory files, cron job JSON, dead letters, durable queue WAL</div>
</div>

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">Channels</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);">Telegram polling, Telegram webhook server, Discord Gateway + REST</div>
</div>

<div style="border: 1px solid var(--vp-c-divider); border-radius: 8px; padding: 16px 20px;">
<div style="font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--vp-c-brand-1); margin-bottom: 6px;">Entry Point</div>
<div style="font-size: 0.9rem; color: var(--vp-c-text-2);"><code>bin/krill.jl</code> — channel selection driven entirely by <code>krill.toml</code>, no code changes needed</div>
</div>

</div>
