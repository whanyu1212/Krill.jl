using Krill
using Test
using Krill.Telegram: HTTP, JSON3
using UUIDs
using Dates

const KRILL_FAST_TESTS = get(ENV, "KRILL_FAST_TESTS", "0") == "1"

# ─── Telegram ─────────────────────────────────────────────────────
include("test_telegram_connector.jl")
include("test_normalize.jl")

# ─── MCP ──────────────────────────────────────────────────────────
include("test_mcp_runtime.jl")

# ─── Core types & message hub ────────────────────────────────────
include("test_types.jl")
include("test_message_hub.jl")

# ─── Integration & runtime ───────────────────────────────────────
include("test_integration.jl")
include("test_runtime.jl")

# ─── Sessions & memory ──────────────────────────────────────────
include("test_sessions.jl")
include("test_memory.jl")
include("test_session_consumer.jl")

# ─── Tools & skills ─────────────────────────────────────────────
include("test_builtin_tools.jl")
include("test_prompt_context.jl")

# ─── Runtime with LLM ───────────────────────────────────────────
include("test_runtime_memory.jl")
include("test_openai.jl")
include("test_gemini.jl")
include("test_runtime_sessions.jl")
include("test_runtime_openai.jl")
include("test_runtime_gemini.jl")

# ─── Dedicated test files ───────────────────────────────────────
include("test_agent.jl")
include("test_tools_mcp.jl")
include("test_cron.jl")
include("test_channels.jl")
include("test_dispatch.jl")
include("test_claude_code.jl")
include("test_webhook.jl")
include("test_durable_queue.jl")
include("test_context_window.jl")
include("test_gap_fixes.jl")
include("test_security.jl")
include("test_skills.jl")
include("test_subagent.jl")
