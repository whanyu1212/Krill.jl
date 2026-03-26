"""
    register_builtin_tools!(registry; workspace="workspace", enable_exec=false, ...) -> Vector{ToolDef}

Register the standard set of built-in tools (file ops, web search, web fetch, exec, github,
message, claude_code, codex, google_workspace) into the given `ToolRegistry`.
"""
function register_builtin_tools!(
    registry::ToolRegistry;
    workspace::AbstractString="workspace",
    enable_exec::Bool=false,
    exec_timeout_s::Real=60.0,
    exec_path_append::AbstractString="",
    enable_web_search::Bool=true,
    web_search_max_results::Int=5,
    send_message_fn::Union{Nothing,Function}=nothing,
    restrict_to_workspace::Bool=false,
    enable_claude_code::Bool=false,
    claude_code_model::String="sonnet",
    claude_code_timeout_s::Real=600.0,
    claude_code_max_budget::Union{Nothing,Real}=nothing,
    claude_code_permission_mode::String="bypassPermissions",
    claude_code_progress_fn::Union{Nothing,Function}=nothing,
    claude_code_progress_interval_s::Real=15.0,
    enable_codex::Bool=false,
    codex_model::Union{Nothing,String}=nothing,
    codex_timeout_s::Real=600.0,
    codex_sandbox_mode::String="workspace-write",
    codex_progress_fn::Union{Nothing,Function}=nothing,
    codex_progress_interval_s::Real=15.0,
    enable_google_workspace::Bool=false,
    replace::Bool=false,
)
    exec_timeout_s > 0 || throw(ArgumentError("exec_timeout_s must be > 0"))
    web_search_max_results > 0 || throw(ArgumentError("web_search_max_results must be > 0"))

    defs = ToolDef[]

    push!(defs, ToolDef(
        name="read_file",
        description="Read file contents with numbered lines. Use offset/limit for pagination.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "path" => Dict{String,Any}("type" => "string", "description" => "File path to read"),
                "offset" => Dict{String,Any}("type" => "integer", "description" => "Starting line (1-indexed)"),
                "limit" => Dict{String,Any}("type" => "integer", "description" => "Maximum lines to read"),
            ),
            "required" => Any["path"],
        ),
        execute=args -> _read_file_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    push!(defs, ToolDef(
        name="write_file",
        description="Write text content to a file, creating parent directories if needed.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "path" => Dict{String,Any}("type" => "string", "description" => "File path to write"),
                "content" => Dict{String,Any}("type" => "string", "description" => "Content to write"),
            ),
            "required" => Any["path", "content"],
        ),
        execute=args -> _write_file_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    push!(defs, ToolDef(
        name="edit_file",
        description="Replace old_text with new_text in a file.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "path" => Dict{String,Any}("type" => "string", "description" => "File path to edit"),
                "old_text" => Dict{String,Any}("type" => "string", "description" => "Text to find"),
                "new_text" => Dict{String,Any}("type" => "string", "description" => "Replacement text"),
                "replace_all" => Dict{String,Any}("type" => "boolean", "description" => "Replace all matches"),
            ),
            "required" => Any["path", "old_text", "new_text"],
        ),
        execute=args -> _edit_file_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    push!(defs, ToolDef(
        name="delete_file",
        description="Delete a file from the workspace.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "path" => Dict{String,Any}("type" => "string", "description" => "File path to delete"),
            ),
            "required" => Any["path"],
        ),
        execute=args -> _delete_file_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    push!(defs, ToolDef(
        name="move_file",
        description="Move or rename a file or directory.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "src" => Dict{String,Any}("type" => "string", "description" => "Source path"),
                "dst" => Dict{String,Any}("type" => "string", "description" => "Destination path"),
            ),
            "required" => Any["src", "dst"],
        ),
        execute=args -> _move_file_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    push!(defs, ToolDef(
        name="search_files",
        description="Search for a regex pattern across files in a directory. Returns matching lines with file path and line number.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "pattern" => Dict{String,Any}("type" => "string", "description" => "Regex pattern to search for"),
                "path" => Dict{String,Any}("type" => "string", "description" => "Directory to search in (default '.')"),
                "glob" => Dict{String,Any}("type" => "string", "description" => "Filename glob filter, e.g. '*.jl', '*.py' (default '*')"),
                "case_sensitive" => Dict{String,Any}("type" => "boolean", "description" => "Case sensitive match (default true)"),
                "max_results" => Dict{String,Any}("type" => "integer", "description" => "Maximum number of matching lines to return (default 50)"),
            ),
            "required" => Any["pattern"],
        ),
        execute=args -> _search_files_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    push!(defs, ToolDef(
        name="list_dir",
        description="List directory contents with optional recursive traversal.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "path" => Dict{String,Any}("type" => "string", "description" => "Directory path (default '.')"),
                "recursive" => Dict{String,Any}("type" => "boolean", "description" => "Whether to recurse into subdirectories"),
                "max_entries" => Dict{String,Any}("type" => "integer", "description" => "Maximum entries to return"),
            ),
            "required" => Any[],
        ),
        execute=args -> _list_dir_impl(args, workspace; restrict_to_workspace=restrict_to_workspace),
    ))

    # Local DDG web_search is disabled — provider-native search (OpenAI/Gemini) is
    # used instead. If native search returns poor results, the LLM should delegate
    # deeper research to claude_code or codex.
    # if enable_web_search
    #     push!(defs, ToolDef(
    #         name="web_search",
    #         description="Search the web and return result titles and URLs.",
    #         parameters=Dict{String,Any}(
    #             "type" => "object",
    #             "properties" => Dict{String,Any}(
    #                 "query" => Dict{String,Any}("type" => "string", "description" => "Search query"),
    #                 "count" => Dict{String,Any}("type" => "integer", "description" => "Number of results (1-10)"),
    #             ),
    #             "required" => Any["query"],
    #         ),
    #         execute=args -> _web_search_impl(args; max_results=web_search_max_results),
    #     ))
    # end

    push!(defs, ToolDef(
        name="web_fetch",
        description="Fetch a web URL and return markdown-ish content with SSRF-safe checks.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "url" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "URL to fetch (http/https only)",
                ),
                "max_chars" => Dict{String,Any}(
                    "type" => "integer",
                    "description" => "Maximum number of returned characters",
                ),
            ),
            "required" => Any["url"],
        ),
        execute=args -> _web_fetch_impl(args),
    ))

    push!(defs, ToolDef(
        name="github",
        description="Run a GitHub CLI (gh) command. Examples: 'gh repo view owner/repo', 'gh issue list', 'gh pr list', 'gh api users/USERNAME', 'gh search repos QUERY'. The 'gh' prefix is optional.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "command" => Dict{String,Any}("type" => "string", "description" => "gh CLI command to run (e.g. 'repo view owner/repo' or 'gh issue list')"),
            ),
            "required" => Any["command"],
        ),
        execute=args -> _github_impl(args),
    ))

    if send_message_fn !== nothing
        push!(defs, ToolDef(
            name="message",
            description="Send a message to a chat.",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "chat_id" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Target chat identifier",
                    ),
                    "text" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Message text",
                    ),
                    "disable_web_page_preview" => Dict{String,Any}(
                        "type" => "boolean",
                        "description" => "Disable URL preview in the sent message",
                    ),
                ),
                "required" => Any["chat_id", "text"],
            ),
            execute=args -> _message_tool_impl(args; send_message_fn=send_message_fn),
        ))
    end

    if enable_exec
        push!(defs, ToolDef(
            name="exec",
            description="Execute a shell command and return stdout/stderr plus exit code.",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "command" => Dict{String,Any}("type" => "string", "description" => "Shell command to execute"),
                    "working_dir" => Dict{String,Any}("type" => "string", "description" => "Working directory"),
                    "timeout" => Dict{String,Any}("type" => "number", "description" => "Timeout in seconds"),
                ),
                "required" => Any["command"],
            ),
            execute=args -> _exec_impl(
                args,
                workspace;
                timeout_s=Float64(exec_timeout_s),
                path_append=exec_path_append,
                restrict_to_workspace=restrict_to_workspace,
            ),
        ))
    end

    if enable_claude_code
        push!(defs, ToolDef(
            name="claude_code",
            description="""Delegate a coding task to Claude Code — an autonomous coding agent that can read, write, and edit files, run shell commands, search code, and manage git. Use this for implementation work: writing code, fixing bugs, refactoring, running tests. The task should be a clear, specific description of what to do. Returns the result along with cost and session ID. Optionally pass session_id to resume a previous conversation, or set resume=true to continue the most recent session.""",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "task" => Dict{String,Any}("type" => "string", "description" => "Clear description of the coding task to perform"),
                    "session_id" => Dict{String,Any}("type" => "string", "description" => "Session ID to resume a previous Claude Code conversation (from a previous result's [Session: ...] field)"),
                    "resume" => Dict{String,Any}("type" => "boolean", "description" => "Resume the most recent Claude Code session in this working directory (ignored if session_id is set)"),
                ),
                "required" => Any["task"],
            ),
            execute=args -> _claude_code_impl(
                args;
                workspace=workspace,
                timeout_s=Float64(claude_code_timeout_s),
                model=claude_code_model,
                permission_mode=claude_code_permission_mode,
                max_budget=claude_code_max_budget === nothing ? nothing : Float64(claude_code_max_budget),
                progress_fn=claude_code_progress_fn,
                progress_interval_s=Float64(claude_code_progress_interval_s),
            ),
        ))
    end

    if enable_codex
        push!(defs, ToolDef(
            name="codex",
            description="""Delegate a coding task to Codex (OpenAI) — an autonomous coding agent that can read, write, and edit files, run shell commands, and manage code. Use this for implementation work: writing code, fixing bugs, refactoring, running tests. The task should be a clear, specific description of what to do. Returns the result along with token usage and thread ID. Set resume=true to continue the most recent Codex session.""",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "task" => Dict{String,Any}("type" => "string", "description" => "Clear description of the coding task to perform"),
                    "resume" => Dict{String,Any}("type" => "boolean", "description" => "Resume the most recent Codex session in this working directory"),
                ),
                "required" => Any["task"],
            ),
            execute=args -> _codex_impl(
                args;
                workspace=workspace,
                timeout_s=Float64(codex_timeout_s),
                model=codex_model,
                sandbox_mode=codex_sandbox_mode,
                progress_fn=codex_progress_fn,
                progress_interval_s=Float64(codex_progress_interval_s),
            ),
        ))
    end

    if enable_google_workspace
        push!(defs, ToolDef(
            name="google_workspace",
            description="Run a Google Workspace CLI (gws) command. Supports Gmail, Calendar, Drive, and all Google Workspace APIs. Examples: 'gws gmail +send --to user@example.com --subject \"Hello\" --body \"Hi\"', 'gws gmail +triage', 'gws gmail +reply --id MSG_ID --body \"Thanks\"', 'gws calendar events list'. The 'gws' prefix is optional.",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "command" => Dict{String,Any}("type" => "string", "description" => "gws CLI command to run (e.g. 'gmail +send --to user@example.com --subject \"Hello\" --body \"Hi\"')"),
                ),
                "required" => Any["command"],
            ),
            execute=args -> _google_workspace_impl(args),
        ))
    end

    for def in defs
        register_tool!(registry, def; replace=replace)
    end
    return defs
end
