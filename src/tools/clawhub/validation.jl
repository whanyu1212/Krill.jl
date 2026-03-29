"""
    ValidationPolicy(; kwargs...)

Configurable policy for the skill validation gate. Controls which checks
are enabled and their thresholds.
"""
struct ValidationPolicy
    content_scan::Bool
    metadata_check::Bool
    min_downloads::Int
    min_stars::Int
    blocked_slugs::Set{String}
    blocked_authors::Set{String}
    allowed_slugs::Union{Nothing,Set{String}}
    allowed_authors::Union{Nothing,Set{String}}
end

function ValidationPolicy(;
    content_scan::Bool = true,
    metadata_check::Bool = true,
    min_downloads::Int = 0,
    min_stars::Int = 0,
    blocked_slugs::Union{AbstractSet,AbstractVector} = String[],
    blocked_authors::Union{AbstractSet,AbstractVector} = String[],
    allowed_slugs::Union{Nothing,AbstractSet,AbstractVector} = nothing,
    allowed_authors::Union{Nothing,AbstractSet,AbstractVector} = nothing,
)
    return ValidationPolicy(
        content_scan, metadata_check, min_downloads, min_stars,
        Set{String}(String.(collect(blocked_slugs))),
        Set{String}(String.(collect(blocked_authors))),
        allowed_slugs === nothing ? nothing : Set{String}(String.(collect(allowed_slugs))),
        allowed_authors === nothing ? nothing : Set{String}(String.(collect(allowed_authors))),
    )
end

"""
    ValidationResult

Outcome of the validation pipeline.
"""
struct ValidationResult
    passed::Bool
    reasons::Vector{String}
end

const _DANGEROUS_PATTERNS = Pair{Regex,String}[
    r"```(?:bash|sh|shell|zsh|cmd|powershell)"i => "embedded shell code block",
    r"\brun\s*\("i => "Julia run() call",
    r"\bENV\s*\["i => "ENV variable access",
    r"\bdownload\s*\("i => "download() call",
    r"\bBase\.eval\b"i => "Base.eval call",
    r"@eval\b"i => "@eval macro",
    r"\bccall\b"i => "ccall (C function call)",
    r"\bunsafe_"i => "unsafe_ function",
    r"\bshell`"i => "shell command literal",
    r"\bMeta\.parse\b"i => "Meta.parse (code parsing)",
    r"\binclude\s*\("i => "include() call",
    r"\bpiracy\b"i => "type piracy reference",
    r"\brm\s*\(\s*[\"']?/"i => "rm() on absolute path",
    r"\bchmod\b"i => "chmod call",
]

"""
    default_policy() -> ValidationPolicy

Returns the default validation policy with content scanning and metadata checks enabled,
no popularity thresholds, and no allow/blocklists.
"""
default_policy() = ValidationPolicy()

"""
    validate_skill(skill_dir, policy; remote_meta=nothing) -> ValidationResult

Run the full validation pipeline on a quarantined skill directory.
`remote_meta` is an optional Dict with fields like "author", "downloads", "stars"
from the ClawHub API.
"""
function validate_skill(
    skill_dir::AbstractString,
    policy::ValidationPolicy;
    remote_meta::Union{Nothing,AbstractDict} = nothing,
)
    reasons = String[]

    # Allow/blocklist check (uses remote_meta for author)
    slug = basename(String(skill_dir))
    author = remote_meta === nothing ? "" : String(get(remote_meta, "author", get(remote_meta, :author, "")))

    _check_allowlist_blocklist!(reasons, slug, author, policy)
    !isempty(reasons) && return ValidationResult(false, reasons)

    # Metadata validation
    if policy.metadata_check
        _validate_metadata!(reasons, String(skill_dir))
    end

    # Content scanning
    if policy.content_scan
        _scan_content!(reasons, String(skill_dir))
    end

    # Popularity gate
    if remote_meta !== nothing
        _check_popularity!(reasons, remote_meta, policy)
    end

    return ValidationResult(isempty(reasons), reasons)
end

function _check_allowlist_blocklist!(
    reasons::Vector{String},
    slug::AbstractString,
    author::AbstractString,
    policy::ValidationPolicy,
)
    if slug in policy.blocked_slugs
        push!(reasons, "Skill '$(slug)' is in the blocklist")
    end
    if !isempty(author) && author in policy.blocked_authors
        push!(reasons, "Author '$(author)' is in the blocklist")
    end
    if policy.allowed_slugs !== nothing && !(slug in policy.allowed_slugs)
        push!(reasons, "Skill '$(slug)' is not in the allowlist")
    end
    if policy.allowed_authors !== nothing && !isempty(author) && !(author in policy.allowed_authors)
        push!(reasons, "Author '$(author)' is not in the allowlist")
    end
    return nothing
end

function _validate_metadata!(reasons::Vector{String}, skill_dir::AbstractString)
    skill_file = joinpath(skill_dir, "SKILL.md")
    if !isfile(skill_file)
        push!(reasons, "SKILL.md not found in skill directory")
        return nothing
    end

    content = try
        read(skill_file, String)
    catch _
        push!(reasons, "Failed to read SKILL.md")
        return nothing
    end

    meta = Skills.parse_skill_frontmatter(content)
    if isempty(meta)
        push!(reasons, "No frontmatter found in SKILL.md")
        return nothing
    end

    desc = get(meta, "description", "")
    if isempty(desc)
        push!(reasons, "Missing 'description' in frontmatter")
    end

    return nothing
end

function _scan_content!(reasons::Vector{String}, skill_dir::AbstractString)
    for (root, _, files) in walkdir(skill_dir)
        for file in files
            # Only scan text-based files
            ext = lowercase(splitext(file)[2])
            ext in (".md", ".txt", ".toml", ".yaml", ".yml", ".json", ".jl", ".py", ".sh", ".js", ".ts") || continue

            filepath = joinpath(root, file)
            content = try
                read(filepath, String)
            catch _
                continue
            end

            relpath_str = relpath(filepath, skill_dir)
            for (pattern, label) in _DANGEROUS_PATTERNS
                if occursin(pattern, content)
                    push!(reasons, "Dangerous pattern detected in $(relpath_str): $(label)")
                end
            end
        end
    end
    return nothing
end

function _check_popularity!(
    reasons::Vector{String},
    remote_meta::AbstractDict,
    policy::ValidationPolicy,
)
    downloads = Int(get(remote_meta, "downloads", get(remote_meta, :downloads, 0)))
    stars = Int(get(remote_meta, "stars", get(remote_meta, :stars, 0)))

    if policy.min_downloads > 0 && downloads < policy.min_downloads
        push!(reasons, "Download count $(downloads) is below minimum threshold $(policy.min_downloads)")
    end
    if policy.min_stars > 0 && stars < policy.min_stars
        push!(reasons, "Star count $(stars) is below minimum threshold $(policy.min_stars)")
    end
    return nothing
end
