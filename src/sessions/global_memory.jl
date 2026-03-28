module GlobalMemory

using Dates
using JSON3

using ..LLM: AbstractLLMProvider, chat_completion

export GlobalMemoryStore,
    global_memory_path,
    load_global_memory,
    save_global_memory!,
    consolidate_global_memory!

const GLOBAL_MEMORY_CONSOLIDATION_INSTRUCTIONS = """
You maintain a persistent user profile across all conversations.
Merge the new fact into the existing profile using these rules:
- Deduplicate: if the fact is already captured, keep only one version.
- Resolve contradictions: prefer the newer information.
- Organize: group related facts into coherent sections (preferences, background, interests, tools, etc.).
- Be concise: remove stale or redundant entries.
- Do not include secrets or credentials.
Output only the updated profile in Markdown. No preamble or commentary.
"""

"""
    GlobalMemoryStore(; data_dir="~/.krill")

Persists per-user global memory under:
`data_dir/global_memory/<user_id>/MEMORY.md`

Keyed by `user_id` (not session key), so memory is shared across
channels (Telegram, Discord) for the same user.
"""
struct GlobalMemoryStore
    data_dir::String
end

function GlobalMemoryStore(; data_dir::AbstractString = joinpath(homedir(), ".krill"))
    return GlobalMemoryStore(String(data_dir))
end

function _global_memory_dir(store::GlobalMemoryStore, user_id::AbstractString)
    safe = replace(String(user_id), r"[^A-Za-z0-9_\-]" => "_")
    dir = joinpath(store.data_dir, "global_memory", safe)
    mkpath(dir)
    return dir
end

"""
    global_memory_path(store, user_id) -> String

Return the path to the global MEMORY.md for a user.
"""
function global_memory_path(store::GlobalMemoryStore, user_id::AbstractString)
    return joinpath(_global_memory_dir(store, user_id), "MEMORY.md")
end

"""
    load_global_memory(store, user_id) -> String

Read the global MEMORY.md for a user. Returns an empty string if missing.
"""
function load_global_memory(store::GlobalMemoryStore, user_id::AbstractString)
    path = global_memory_path(store, user_id)
    isfile(path) || return ""
    return read(path, String)
end

"""
    save_global_memory!(store, user_id, content)

Overwrite the global MEMORY.md for a user.
"""
function save_global_memory!(
    store::GlobalMemoryStore,
    user_id::AbstractString,
    content::AbstractString,
)
    path = global_memory_path(store, user_id)
    open(path, "w") do io
        write(io, String(content))
    end
    return nothing
end

"""
    consolidate_global_memory!(provider, store, user_id, new_fact; max_output_tokens=800)

Merge `new_fact` into the user's existing global memory using the LLM.
The result is a clean, deduplicated, reorganized profile written back to MEMORY.md.

Returns the updated memory content, or throws on LLM failure.
"""
function consolidate_global_memory!(
    provider::AbstractLLMProvider,
    store::GlobalMemoryStore,
    user_id::AbstractString,
    new_fact::AbstractString;
    max_output_tokens::Union{Nothing,Integer} = 800,
)
    existing = load_global_memory(store, user_id)
    existing_block = isempty(strip(existing)) ? "(empty)" : strip(existing)

    prompt = join(
        String[
            "Current profile:",
            existing_block,
            "",
            "New fact to incorporate:",
            strip(String(new_fact)),
            "",
            "Rewrite the profile now.",
        ], "\n")

    input = Any[Dict{String,Any}(
        "role" => "user",
        "content" => Any[Dict{String,Any}(
            "type" => "input_text",
            "text" => prompt,
        )],
    )]

    response = chat_completion(
        provider,
        input;
        instructions = GLOBAL_MEMORY_CONSOLIDATION_INSTRUCTIONS,
        max_output_tokens = max_output_tokens,
    )

    consolidated = strip(response.text)
    isempty(consolidated) && error("global memory consolidation returned empty content")

    save_global_memory!(store, user_id, consolidated)
    return consolidated
end

end
