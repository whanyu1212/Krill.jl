function _read_file_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    path = get(args, "path", nothing)
    path isa AbstractString || return "Error: `path` must be a string"

    resolved = try
        _resolve_path(String(path), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    isfile(resolved) || return "Error: File not found: $(path)"

    content = try
        read(resolved, String)
    catch e
        return "Error reading file: $(sprint(showerror, e))"
    end

    lines = split(content, "\n"; keepempty=true)
    total = length(lines)
    total == 0 && return "(Empty file: $(path))"

    offset_raw = get(args, "offset", 1)
    limit_raw = get(args, "limit", _DEFAULT_READ_LIMIT)
    offset = try
        max(1, Int(offset_raw))
    catch _
        1
    end
    limit = try
        max(1, Int(limit_raw))
    catch _
        _DEFAULT_READ_LIMIT
    end

    offset > total && return "Error: offset $(offset) is beyond end of file ($(total) lines)"

    start_idx = offset
    end_idx = min(total, start_idx + limit - 1)
    out_lines = String[]
    for idx in start_idx:end_idx
        push!(out_lines, "$(idx)| $(lines[idx])")
    end

    suffix = if end_idx < total
        "(Showing lines $(start_idx)-$(end_idx) of $(total). Use offset=$(end_idx + 1) to continue.)"
    else
        "(End of file - $(total) lines total)"
    end

    return join(vcat(out_lines, "", suffix), "\n")
end

function _write_file_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    path = get(args, "path", nothing)
    content = get(args, "content", nothing)
    path isa AbstractString || return "Error: `path` must be a string"
    content isa AbstractString || return "Error: `content` must be a string"

    resolved = try
        _resolve_path(String(path), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end

    try
        mkpath(dirname(resolved))
        write(resolved, String(content))
    catch e
        return "Error writing file: $(sprint(showerror, e))"
    end
    return "Successfully wrote $(length(String(content))) bytes to $(resolved)"
end

function _edit_file_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    path = get(args, "path", nothing)
    old_text = get(args, "old_text", nothing)
    new_text = get(args, "new_text", nothing)
    replace_all = _parse_bool(get(args, "replace_all", false); default=false)

    path isa AbstractString || return "Error: `path` must be a string"
    old_text isa AbstractString || return "Error: `old_text` must be a string"
    new_text isa AbstractString || return "Error: `new_text` must be a string"

    resolved = try
        _resolve_path(String(path), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    isfile(resolved) || return "Error: File not found: $(path)"

    content = try
        read(resolved, String)
    catch e
        return "Error reading file: $(sprint(showerror, e))"
    end

    needle = String(old_text)
    replacement = String(new_text)
    occurrences = count(needle, content)
    occurrences == 0 && return "Error: old_text not found in $(path)"

    if !replace_all && occurrences > 1
        return "Warning: old_text appears $(occurrences) times. Provide more context or set replace_all=true."
    end

    updated = replace_all ?
        replace(content, needle => replacement) :
        replace(content, needle => replacement; count=1)

    try
        write(resolved, updated)
    catch e
        return "Error writing file: $(sprint(showerror, e))"
    end
    return "Successfully edited $(resolved)"
end

function _delete_file_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    path = get(args, "path", nothing)
    path isa AbstractString || return "Error: `path` must be a string"

    resolved = try
        _resolve_path(String(path), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    isfile(resolved) || return "Error: File not found: $(path)"

    try
        rm(resolved)
    catch e
        return "Error deleting file: $(sprint(showerror, e))"
    end
    return "Deleted $(resolved)"
end

function _move_file_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    src = get(args, "src", nothing)
    dst = get(args, "dst", nothing)
    src isa AbstractString || return "Error: `src` must be a string"
    dst isa AbstractString || return "Error: `dst` must be a string"

    resolved_src = try
        _resolve_path(String(src), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    resolved_dst = try
        _resolve_path(String(dst), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end

    ispath(resolved_src) || return "Error: Source not found: $(src)"

    try
        mkpath(dirname(resolved_dst))
        mv(resolved_src, resolved_dst; force=true)
    catch e
        return "Error moving file: $(sprint(showerror, e))"
    end
    return "Moved $(resolved_src) → $(resolved_dst)"
end

function _search_files_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    pattern = get(args, "pattern", nothing)
    pattern isa AbstractString || return "Error: `pattern` must be a string"

    path = String(get(args, "path", "."))
    resolved = try
        _resolve_path(path, workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    ispath(resolved) || return "Error: Path not found: $(path)"

    glob_pattern = String(get(args, "glob", "*"))
    case_sensitive = get(args, "case_sensitive", true) !== false
    max_results = try
        max(1, Int(get(args, "max_results", 50)))
    catch _
        50
    end

    regex = try
        case_sensitive ? Regex(String(pattern)) : Regex(String(pattern), "i")
    catch e
        return "Error: invalid regex pattern: $(sprint(showerror, e))"
    end

    matches = String[]
    truncated = false

    for (root, dirs, files) in walkdir(resolved)
        sort!(dirs)
        sort!(files)
        for fname in files
            _glob_match(glob_pattern, fname) || continue
            fpath = joinpath(root, fname)
            try
                for (lineno, line) in enumerate(eachline(fpath))
                    if occursin(regex, line)
                        rel = relpath(fpath, resolved)
                        push!(matches, "$(rel):$(lineno): $(strip(line))")
                        if length(matches) >= max_results
                            truncated = true
                            break
                        end
                    end
                end
            catch _
                # skip unreadable files (binary, permission denied)
            end
            truncated && break
        end
        truncated && break
    end

    isempty(matches) && return "No matches found for pattern '$(pattern)' in $(resolved)"
    result = join(matches, "\n")
    truncated && (result *= "\n\n(Showing first $(max_results) matches. Increase max_results to see more.)")
    return result
end

function _glob_match(pattern::AbstractString, name::AbstractString)::Bool
    # Simple glob: * matches anything, ? matches one char
    regex_str = replace(replace(replace(pattern, "." => "\\."), "*" => ".*"), "?" => ".")
    return occursin(Regex("^" * regex_str * "\$"), name)
end

function _list_dir_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    restrict_to_workspace::Bool,
)
    path = String(get(args, "path", "."))
    recursive = _parse_bool(get(args, "recursive", false); default=false)
    max_entries = try
        max(1, Int(get(args, "max_entries", _DEFAULT_LIST_LIMIT)))
    catch _
        _DEFAULT_LIST_LIMIT
    end

    resolved = try
        _resolve_path(path, workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    isdir(resolved) || return "Error: Not a directory: $(path)"

    entries = String[]
    truncated = false

    if recursive
        for (root, dirs, files) in walkdir(resolved)
            sort!(dirs)
            sort!(files)
            rel_root = relpath(root, resolved)

            for d in dirs
                rel = rel_root == "." ? d : joinpath(rel_root, d)
                push!(entries, rel * "/")
                if length(entries) >= max_entries
                    truncated = true
                    break
                end
            end
            truncated && break

            for f in files
                rel = rel_root == "." ? f : joinpath(rel_root, f)
                push!(entries, rel)
                if length(entries) >= max_entries
                    truncated = true
                    break
                end
            end
            truncated && break
        end
    else
        for name in sort(readdir(resolved))
            full = joinpath(resolved, name)
            push!(entries, isdir(full) ? name * "/" : name)
            if length(entries) >= max_entries
                truncated = true
                break
            end
        end
    end

    isempty(entries) && return "(Empty directory: $(path))"
    header = "Listing for $(resolved)"
    body = join(entries, "\n")
    trailer = truncated ? "\n\n(Showing first $(length(entries)) entries. Increase max_entries to see more.)" : ""
    return header * "\n" * body * trailer
end
