module MemoryConsolidation

using Dates

using ..Types: InboundMessage
using ..Sessions: TurnRecord
using ..Memory:
    MemoryStore, MemoryState, load_memory, save_memory!, append_history!, load_memory_state, save_memory_state!
using ..LLM: AbstractLLMProvider, chat_completion

export MemoryConsolidatorConfig,
    estimate_turn_tokens,
    estimate_turns_tokens,
    consolidate_session_memory!,
    make_memory_consolidator

const CONSOLIDATION_INSTRUCTIONS = """
You maintain durable conversation memory for an assistant.
Rewrite MEMORY.md using:
- stable user profile and preferences
- ongoing goals/tasks and constraints
- important project/context facts
- unresolved follow-ups

Rules:
- Keep it concise and factual.
- Prefer durable facts over one-off chatter.
- Do not include secrets unless explicitly requested to remember.
- Output only the updated MEMORY.md content in Markdown.
"""

"""
    MemoryConsolidatorConfig(; unconsolidated_token_threshold=2_000, max_output_tokens=800, max_input_turn_chars=2_000, max_consolidation_turns=50, max_failures=3)

Configuration for memory consolidation.

- `max_consolidation_turns`: cap how many turns are sent to the LLM in a single
  consolidation call. Remaining turns are left for the next round.
- `max_failures`: after this many consecutive LLM failures, raw-dump turns to
  HISTORY.md and advance `last_consolidated` without an LLM summary.
"""
struct MemoryConsolidatorConfig
    unconsolidated_token_threshold::Int
    max_output_tokens::Union{Nothing,Int}
    max_input_turn_chars::Int
    max_consolidation_turns::Int
    max_failures::Int
end

function MemoryConsolidatorConfig(;
    unconsolidated_token_threshold::Int = 2_000,
    max_output_tokens::Union{Nothing,Integer} = 800,
    max_input_turn_chars::Int = 2_000,
    max_consolidation_turns::Int = 50,
    max_failures::Int = 3,
)
    unconsolidated_token_threshold > 0 || throw(ArgumentError("unconsolidated_token_threshold must be > 0"))
    max_output_tokens === nothing || Int(max_output_tokens) > 0 ||
        throw(ArgumentError("max_output_tokens must be > 0 when provided"))
    max_input_turn_chars > 0 || throw(ArgumentError("max_input_turn_chars must be > 0"))
    max_consolidation_turns > 0 || throw(ArgumentError("max_consolidation_turns must be > 0"))
    max_failures > 0 || throw(ArgumentError("max_failures must be > 0"))
    return MemoryConsolidatorConfig(
        unconsolidated_token_threshold,
        max_output_tokens === nothing ? nothing : Int(max_output_tokens),
        max_input_turn_chars,
        max_consolidation_turns,
        max_failures,
    )
end

# Rough bytes/4 heuristic for BPE token count — no tokenizer dependency.
# The +8 per turn accounts for role tags, message framing, and separators.
_estimate_tokens(text::AbstractString) = max(1, cld(length(codeunits(text)), 4))

estimate_turn_tokens(turn::TurnRecord) = _estimate_tokens(turn.text) + 8
estimate_turns_tokens(turns::Vector{TurnRecord}) = sum(estimate_turn_tokens(t) for t in turns)

function _truncate_for_prompt(text::AbstractString, max_chars::Int)
    s = strip(String(text))
    n = length(s)
    n <= max_chars && return s
    keep = max(0, max_chars - length(" ... [truncated]"))
    return String(first(s, keep)) * " ... [truncated]"
end

function _render_turns_for_prompt(turns::Vector{TurnRecord}, start_index::Int, max_turn_chars::Int)
    lines = String[]
    for (offset, turn) in enumerate(turns)
        idx = start_index + offset - 1
        body = _truncate_for_prompt(turn.text, max_turn_chars)
        push!(lines, "[$idx] $(turn.timestamp) $(turn.role): $body")
    end
    return join(lines, "\n")
end

function _render_archive_block(turns::Vector{TurnRecord}, start_index::Int)
    end_index = start_index + length(turns) - 1
    lines = String[
        "Consolidated turn range: $start_index-$end_index",
        "",
    ]
    for (offset, turn) in enumerate(turns)
        idx = start_index + offset - 1
        push!(lines, "[$idx] $(turn.timestamp) $(turn.role)")
        push!(lines, turn.text)
        push!(lines, "")
    end
    return join(lines, "\n")
end

function _build_consolidation_prompt(
    existing_memory::AbstractString,
    turns::Vector{TurnRecord},
    start_index::Int,
    max_turn_chars::Int,
)
    turns_block = _render_turns_for_prompt(turns, start_index, max_turn_chars)
    memory_block = strip(String(existing_memory))
    if isempty(memory_block)
        memory_block = "(empty)"
    end

    return join(
        String[
            "Current MEMORY.md:",
            memory_block,
            "",
            "New unconsolidated turns:",
            turns_block,
            "",
            "Rewrite MEMORY.md now.",
        ], "\n")
end

function _unconsolidated_turns(history::Vector{TurnRecord}, last_consolidated::Int)
    if isempty(history)
        return TurnRecord[], 1
    end
    start_idx = clamp(last_consolidated + 1, 1, length(history) + 1)
    if start_idx > length(history)
        return TurnRecord[], start_idx
    end
    return history[start_idx:end], start_idx
end

"""
    _raw_dump_fallback!(memory_store, session_key, turns, start_index) -> Int

Raw-dump turns to HISTORY.md without LLM summarization.
Returns the new `last_consolidated` value.
"""
function _raw_dump_fallback!(
    memory_store::MemoryStore,
    session_key::AbstractString,
    turns::Vector{TurnRecord},
    start_index::Int,
)
    append_history!(memory_store, session_key, _render_archive_block(turns, start_index))
    return start_index + length(turns) - 1
end

"""
    consolidate_session_memory!(provider, memory_store, session_key, history; config=MemoryConsolidatorConfig())

Consolidate unconsolidated session turns into `MEMORY.md` when their estimated
token count exceeds the configured threshold. Appends raw archived turns into
`HISTORY.md` and advances `last_consolidated` state.

At most `config.max_consolidation_turns` turns are processed per call; remaining
turns are left for the next invocation.

After `config.max_failures` consecutive LLM failures, falls back to a raw dump
of turns into `HISTORY.md` (no LLM summary) so that `last_consolidated` advances
and the consolidation prompt doesn't grow unboundedly.
"""
function consolidate_session_memory!(
    provider::AbstractLLMProvider,
    memory_store::MemoryStore,
    session_key::AbstractString,
    history::Vector{TurnRecord};
    config::MemoryConsolidatorConfig = MemoryConsolidatorConfig(),
)
    state = load_memory_state(memory_store, session_key)
    last = clamp(state.last_consolidated, 0, length(history))
    failures = state.consolidation_failures

    turns, start_index = _unconsolidated_turns(history, last)
    isempty(turns) &&
        return (consolidated = false, reason = :no_unconsolidated_turns, token_estimate = 0, last_consolidated = last)

    # Cap batch size
    if length(turns) > config.max_consolidation_turns
        turns = turns[1:config.max_consolidation_turns]
    end

    token_estimate = estimate_turns_tokens(turns)
    if token_estimate < config.unconsolidated_token_threshold
        return (
            consolidated = false,
            reason = :below_threshold,
            token_estimate = token_estimate,
            last_consolidated = last,
        )
    end

    # Fallback: too many consecutive LLM failures — raw dump without summary
    if failures >= config.max_failures
        @warn "memory consolidation: $(failures) consecutive LLM failures, falling back to raw archive" session_key=session_key turns=length(
            turns,
        )
        new_last = _raw_dump_fallback!(memory_store, session_key, turns, start_index)
        save_memory_state!(memory_store, session_key, MemoryState(new_last, 0))
        return (
            consolidated = true,
            reason = :fallback_raw_dump,
            token_estimate = token_estimate,
            consolidated_turns = length(turns),
            last_consolidated = new_last,
        )
    end

    existing_memory = load_memory(memory_store, session_key)
    prompt = _build_consolidation_prompt(existing_memory, turns, start_index, config.max_input_turn_chars)
    input = Any[Dict{String,Any}(
        "role" => "user",
        "content" => Any[Dict{String,Any}(
            "type" => "input_text",
            "text" => prompt,
        )],
    )]

    local consolidated_memory::String
    try
        response = chat_completion(
            provider,
            input;
            instructions = CONSOLIDATION_INSTRUCTIONS,
            max_output_tokens = config.max_output_tokens,
        )
        consolidated_memory = strip(response.text)
        if isempty(consolidated_memory)
            error("memory consolidation returned empty content")
        end
    catch err
        new_failures = failures + 1
        save_memory_state!(memory_store, session_key, MemoryState(last, new_failures))
        @warn "memory consolidation LLM call failed" session_key=session_key failures=new_failures max_failures=config.max_failures error=err
        return (
            consolidated = false,
            reason = :llm_error,
            token_estimate = token_estimate,
            last_consolidated = last,
            error = err,
        )
    end

    save_memory!(memory_store, session_key, consolidated_memory)
    append_history!(memory_store, session_key, _render_archive_block(turns, start_index))

    new_last = start_index + length(turns) - 1
    save_memory_state!(memory_store, session_key, MemoryState(new_last, 0))

    return (
        consolidated = true,
        reason = :ok,
        token_estimate = token_estimate,
        consolidated_turns = length(turns),
        last_consolidated = new_last,
    )
end

"""
    make_memory_consolidator(provider, memory_store; kwargs...) -> Function

Create an `after_process(msg, history)` hook for `run_session_loop!`.
"""
function make_memory_consolidator(
    provider::AbstractLLMProvider,
    memory_store::MemoryStore;
    unconsolidated_token_threshold::Int = 2_000,
    max_output_tokens::Union{Nothing,Integer} = 800,
    max_input_turn_chars::Int = 2_000,
    max_consolidation_turns::Int = 50,
    max_failures::Int = 3,
)
    config = MemoryConsolidatorConfig(;
        unconsolidated_token_threshold = unconsolidated_token_threshold,
        max_output_tokens = max_output_tokens,
        max_input_turn_chars = max_input_turn_chars,
        max_consolidation_turns = max_consolidation_turns,
        max_failures = max_failures,
    )

    return function (msg::InboundMessage, history::Vector{TurnRecord})
        result = consolidate_session_memory!(
            provider,
            memory_store,
            msg.session_key,
            history;
            config = config,
        )
        if result.consolidated
            @info "session memory consolidated" session_key=msg.session_key reason=result.reason token_estimate=result.token_estimate consolidated_turns=result.consolidated_turns last_consolidated=result.last_consolidated
        end
        return nothing
    end
end

end
