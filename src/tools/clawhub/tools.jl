"""
    register_clawhub_tools!(registry, store, client; policy, replace) -> Vector{ToolDef}

Register ClawHub skill management tools into the `ToolRegistry`.
Returns the list of registered `ToolDef`s.
"""
function register_clawhub_tools!(
    registry::ToolRegistry,
    store::SkillStore,
    client::ClawHubClient;
    policy::ValidationPolicy = default_policy(),
    replace::Bool = false,
)
    defs = ToolDef[]

    # ─── clawhub_search ───────────────────────────────────────────────
    push!(
        defs,
        ToolDef(
            name = "clawhub_search",
            description = "Search the ClawHub skill registry by natural language query. Returns matching skills with name, description, author, downloads, and stars.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "query" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Natural language search query (vector similarity search)",
                    ),
                ),
                "required" => Any["query"],
            ),
            execute = args -> _clawhub_search_impl(args; client = client),
        ),
    )

    # ─── clawhub_install ──────────────────────────────────────────────
    push!(
        defs,
        ToolDef(
            name = "clawhub_install",
            description = "Install a skill from ClawHub. Downloads the skill, runs it through the validation gate (content scan, metadata check, popularity thresholds, allow/blocklists), and promotes it to the verified store if it passes. Rejected skills are removed.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "slug" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Skill slug (identifier) from ClawHub",
                    ),
                    "version" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Skill version to install (default: latest)",
                    ),
                ),
                "required" => Any["slug"],
            ),
            execute = args -> _clawhub_install_impl(args; store = store, client = client, policy = policy),
        ),
    )

    # ─── clawhub_remove ───────────────────────────────────────────────
    push!(
        defs,
        ToolDef(
            name = "clawhub_remove",
            description = "Remove an installed skill from the local verified store.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "slug" => Dict{String,Any}(
                        "type" => "string",
                        "description" => "Skill slug to remove",
                    ),
                ),
                "required" => Any["slug"],
            ),
            execute = args -> _clawhub_remove_impl(args; store = store),
        ),
    )

    # ─── clawhub_list ─────────────────────────────────────────────────
    push!(
        defs,
        ToolDef(
            name = "clawhub_list",
            description = "List all skills in the local store with their status (quarantined, verified, rejected), version, and install date.",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(),
                "required" => Any[],
            ),
            execute = args -> _clawhub_list_impl(args; store = store),
        ),
    )

    for def in defs
        register_tool!(registry, def; replace = replace)
    end
    return defs
end

# ─── Tool implementations ─────────────────────────────────────────────

function _clawhub_search_impl(args::Dict{String,Any}; client::ClawHubClient)
    query = get(args, "query", nothing)
    query isa AbstractString || return "Error: `query` must be a string"
    query_str = strip(String(query))
    isempty(query_str) && return "Error: `query` must not be empty"

    results = try
        clawhub_search(client, query_str)
    catch e
        return "Error searching ClawHub: $(sprint(showerror, e))"
    end

    isempty(results) && return "No skills found for query: $(query_str)"

    lines = String["Found $(length(results)) skill(s):", ""]
    for (i, skill) in enumerate(results)
        slug = get(skill, "slug", get(skill, "name", "unknown"))
        name = get(skill, "name", slug)
        desc = get(skill, "description", "")
        author = get(skill, "author", "")
        downloads = get(skill, "downloads", 0)
        stars = get(skill, "stars", 0)

        push!(lines, "$(i). **$(name)** (`$(slug)`)")
        !isempty(desc) && push!(lines, "   $(desc)")
        meta_parts = String[]
        !isempty(author) && push!(meta_parts, "by $(author)")
        push!(meta_parts, "$(downloads) downloads")
        push!(meta_parts, "$(stars) stars")
        push!(lines, "   $(join(meta_parts, " · "))")
        push!(lines, "")
    end
    return join(lines, "\n")
end

function _clawhub_install_impl(
    args::Dict{String,Any};
    store::SkillStore,
    client::ClawHubClient,
    policy::ValidationPolicy,
)
    slug = get(args, "slug", nothing)
    slug isa AbstractString || return "Error: `slug` must be a string"
    slug_str = strip(String(slug))
    isempty(slug_str) && return "Error: `slug` must not be empty"
    version = strip(String(get(args, "version", "latest")))

    # Check if already installed with same version
    existing = get_entry(store, slug_str)
    if existing !== nothing && existing.status == "verified" && existing.version == version
        return "Skill '$(slug_str)' v$(version) is already installed and verified."
    end

    # Fetch remote metadata
    remote_meta = try
        clawhub_skill_info(client, slug_str)
    catch e
        return "Error fetching skill info: $(sprint(showerror, e))"
    end

    # Quick allowlist/blocklist check before downloading
    author = String(get(remote_meta, "author", get(remote_meta, :author, "")))
    pre_reasons = String[]
    _check_allowlist_blocklist!(pre_reasons, slug_str, author, policy)
    if !isempty(pre_reasons)
        return "Skill '$(slug_str)' rejected (pre-download): $(join(pre_reasons, "; "))"
    end

    # Download to quarantine
    q_dir = quarantine_dir(store, slug_str)
    rm(q_dir; force = true, recursive = true)
    mkpath(q_dir)

    sha256_hash = try
        clawhub_download(client, slug_str, version, q_dir)
    catch e
        rm(q_dir; force = true, recursive = true)
        return "Error downloading skill: $(sprint(showerror, e))"
    end

    # Resolve version from remote metadata if "latest"
    resolved_version = version
    if version == "latest"
        rv = get(remote_meta, "version", get(remote_meta, :version, nothing))
        if rv !== nothing
            resolved_version = String(rv)
        end
    end

    # Create manifest entry
    source_url = "$(client.base_url)/download/$(HTTP.escapeuri(slug_str))/$(HTTP.escapeuri(version))"
    entry = SkillManifestEntry(
        slug = slug_str,
        version = resolved_version,
        status = "quarantined",
        sha256 = sha256_hash,
        source_url = source_url,
        author = author,
        downloads = Int(get(remote_meta, "downloads", get(remote_meta, :downloads, 0))),
        stars = Int(get(remote_meta, "stars", get(remote_meta, :stars, 0))),
        installed_at = string(Dates.now(Dates.UTC)),
        type = "skill",
    )
    add_quarantined!(store, entry)

    # Validate
    result = validate_skill(q_dir, policy; remote_meta = remote_meta)

    if result.passed
        try
            promote!(store, slug_str)
        catch e
            return "Validation passed but promotion failed: $(sprint(showerror, e))"
        end
        return "Skill '$(slug_str)' v$(resolved_version) installed and verified successfully.\n" *
               "SHA256: $(sha256_hash)\n" *
               "Author: $(author)\n" *
               "The skill is now available via `read_skill`."
    else
        reject!(store, slug_str)
        return "Skill '$(slug_str)' REJECTED — failed validation:\n" *
               join(["- $(r)" for r in result.reasons], "\n")
    end
end

function _clawhub_remove_impl(args::Dict{String,Any}; store::SkillStore)
    slug = get(args, "slug", nothing)
    slug isa AbstractString || return "Error: `slug` must be a string"
    slug_str = strip(String(slug))
    isempty(slug_str) && return "Error: `slug` must not be empty"

    if !has_skill(store, slug_str)
        return "Skill '$(slug_str)' is not installed."
    end

    remove!(store, slug_str)
    return "Skill '$(slug_str)' has been removed from the local store."
end

function _clawhub_list_impl(args::Dict{String,Any}; store::SkillStore)
    entries = list_entries(store)
    isempty(entries) && return "No skills installed in the local store."

    lines = String["Installed skills ($(length(entries))):", ""]
    for entry in entries
        status_marker = if entry.status == "verified"
            "✓"
        elseif entry.status == "quarantined"
            "⏳"
        elseif entry.status == "rejected"
            "✗"
        else
            "?"
        end
        push!(lines, "$(status_marker) **$(entry.slug)** v$(entry.version) [$(entry.status)]")
        meta_parts = String[]
        !isempty(entry.author) && push!(meta_parts, "by $(entry.author)")
        !isempty(entry.installed_at) && push!(meta_parts, "installed $(entry.installed_at)")
        !isempty(meta_parts) && push!(lines, "  $(join(meta_parts, " · "))")
    end
    return join(lines, "\n")
end
