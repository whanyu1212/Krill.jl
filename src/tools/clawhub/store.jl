"""
    SkillManifestEntry

Metadata for a single skill in the local store (quarantined, verified, or rejected).
"""
struct SkillManifestEntry
    slug::String
    version::String
    status::String          # "quarantined", "verified", "rejected"
    sha256::String
    source_url::String
    author::String
    downloads::Int
    stars::Int
    installed_at::String    # ISO 8601
    verified_at::Union{Nothing,String}
    type::String            # "skill" (future: "mcp_server")
end

function SkillManifestEntry(;
    slug::AbstractString,
    version::AbstractString = "latest",
    status::AbstractString = "quarantined",
    sha256::AbstractString = "",
    source_url::AbstractString = "",
    author::AbstractString = "",
    downloads::Int = 0,
    stars::Int = 0,
    installed_at::AbstractString = string(Dates.now(Dates.UTC)),
    verified_at::Union{Nothing,AbstractString} = nothing,
    type::AbstractString = "skill",
)
    return SkillManifestEntry(
        String(slug), String(version), String(status), String(sha256),
        String(source_url), String(author), downloads, stars,
        String(installed_at),
        verified_at === nothing ? nothing : String(verified_at),
        String(type),
    )
end

"""
    SkillStore(; data_dir)

Thread-safe manager for the local skill store. Persists a manifest and manages
quarantine/verified directories under `{data_dir}/skill_store/`.
"""
mutable struct SkillStore
    root_dir::String
    manifest::Dict{String,SkillManifestEntry}
    lock::ReentrantLock
end

function SkillStore(; data_dir::AbstractString)
    root = joinpath(String(data_dir), "skill_store")
    mkpath(joinpath(root, "quarantine"))
    mkpath(joinpath(root, "verified"))
    store = SkillStore(root, Dict{String,SkillManifestEntry}(), ReentrantLock())
    load_manifest!(store)
    return store
end

manifest_path(store::SkillStore) = joinpath(store.root_dir, "manifest.json")
quarantine_dir(store::SkillStore, slug::AbstractString) = joinpath(store.root_dir, "quarantine", String(slug))
verified_dir(store::SkillStore, slug::AbstractString) = joinpath(store.root_dir, "verified", String(slug))
verified_root(store::SkillStore) = joinpath(store.root_dir, "verified")

"""
    load_manifest!(store)

Load the manifest from disk. Creates an empty manifest if the file doesn't exist.
"""
function load_manifest!(store::SkillStore)
    lock(store.lock) do
        path = manifest_path(store)
        if !isfile(path)
            store.manifest = Dict{String,SkillManifestEntry}()
            return nothing
        end
        raw = try
            JSON3.read(read(path, String))
        catch _
            @warn "Failed to parse skill manifest, starting fresh" path = path
            Dict{String,Any}()
        end
        manifest = Dict{String,SkillManifestEntry}()
        entries = if raw isa AbstractDict
            get(raw, :entries, get(raw, :skills, raw))
        elseif raw isa AbstractVector
            raw
        else
            Any[]
        end
        if entries isa AbstractDict
            for (k, v) in pairs(entries)
                v isa AbstractDict || continue
                entry = _parse_manifest_entry(v)
                entry === nothing && continue
                manifest[String(k)] = entry
            end
        elseif entries isa AbstractVector
            for v in entries
                v isa AbstractDict || continue
                entry = _parse_manifest_entry(v)
                entry === nothing && continue
                manifest[entry.slug] = entry
            end
        end
        store.manifest = manifest
        return nothing
    end
end

function _parse_manifest_entry(d::AbstractDict)
    slug = String(get(d, :slug, get(d, "slug", "")))
    isempty(slug) && return nothing
    return SkillManifestEntry(
        slug = slug,
        version = String(get(d, :version, get(d, "version", "latest"))),
        status = String(get(d, :status, get(d, "status", "quarantined"))),
        sha256 = String(get(d, :sha256, get(d, "sha256", ""))),
        source_url = String(get(d, :source_url, get(d, "source_url", ""))),
        author = String(get(d, :author, get(d, "author", ""))),
        downloads = Int(get(d, :downloads, get(d, "downloads", 0))),
        stars = Int(get(d, :stars, get(d, "stars", 0))),
        installed_at = String(get(d, :installed_at, get(d, "installed_at", ""))),
        verified_at = let v = get(d, :verified_at, get(d, "verified_at", nothing))
            v === nothing || v === JSON3.null ? nothing : String(v)
        end,
        type = String(get(d, :type, get(d, "type", "skill"))),
    )
end

"""
    save_manifest!(store)

Atomically write the manifest to disk (write to temp, then rename).
"""
function save_manifest!(store::SkillStore)
    lock(store.lock) do
        path = manifest_path(store)
        entries = Dict{String,Any}[]
        for (_, entry) in sort!(collect(store.manifest); by = p -> p.first)
            push!(
                entries,
                Dict{String,Any}(
                    "slug" => entry.slug,
                    "version" => entry.version,
                    "status" => entry.status,
                    "sha256" => entry.sha256,
                    "source_url" => entry.source_url,
                    "author" => entry.author,
                    "downloads" => entry.downloads,
                    "stars" => entry.stars,
                    "installed_at" => entry.installed_at,
                    "verified_at" => entry.verified_at,
                    "type" => entry.type,
                ),
            )
        end
        data = Dict{String,Any}("entries" => entries)
        tmp_path = path * ".tmp"
        write(tmp_path, JSON3.write(data))
        mv(tmp_path, path; force = true)
        return nothing
    end
end

"""
    add_quarantined!(store, entry)

Add a skill entry to quarantine and persist the manifest.
"""
function add_quarantined!(store::SkillStore, entry::SkillManifestEntry)
    lock(store.lock) do
        store.manifest[entry.slug] = SkillManifestEntry(
            slug = entry.slug,
            version = entry.version,
            status = "quarantined",
            sha256 = entry.sha256,
            source_url = entry.source_url,
            author = entry.author,
            downloads = entry.downloads,
            stars = entry.stars,
            installed_at = entry.installed_at,
            verified_at = nothing,
            type = entry.type,
        )
    end
    save_manifest!(store)
    return nothing
end

"""
    promote!(store, slug)

Move a skill from quarantine to verified and update the manifest.
"""
function promote!(store::SkillStore, slug::AbstractString)
    s = String(slug)
    lock(store.lock) do
        haskey(store.manifest, s) || throw(ErrorException("Skill '$(s)' not found in manifest"))
        entry = store.manifest[s]
        entry.status == "quarantined" ||
            throw(ErrorException("Skill '$(s)' is not quarantined (status: $(entry.status))"))

        src = quarantine_dir(store, s)
        dst = verified_dir(store, s)
        isdir(src) || throw(ErrorException("Quarantine directory missing for '$(s)'"))

        # Move from quarantine to verified
        rm(dst; force = true, recursive = true)
        mkpath(dirname(dst))
        mv(src, dst; force = true)

        store.manifest[s] = SkillManifestEntry(
            slug = entry.slug,
            version = entry.version,
            status = "verified",
            sha256 = entry.sha256,
            source_url = entry.source_url,
            author = entry.author,
            downloads = entry.downloads,
            stars = entry.stars,
            installed_at = entry.installed_at,
            verified_at = string(Dates.now(Dates.UTC)),
            type = entry.type,
        )
    end
    save_manifest!(store)
    return nothing
end

"""
    reject!(store, slug)

Reject a quarantined skill: remove its directory and mark as rejected.
"""
function reject!(store::SkillStore, slug::AbstractString)
    s = String(slug)
    lock(store.lock) do
        haskey(store.manifest, s) || return nothing
        src = quarantine_dir(store, s)
        rm(src; force = true, recursive = true)
        entry = store.manifest[s]
        store.manifest[s] = SkillManifestEntry(
            slug = entry.slug,
            version = entry.version,
            status = "rejected",
            sha256 = entry.sha256,
            source_url = entry.source_url,
            author = entry.author,
            downloads = entry.downloads,
            stars = entry.stars,
            installed_at = entry.installed_at,
            verified_at = nothing,
            type = entry.type,
        )
    end
    save_manifest!(store)
    return nothing
end

"""
    remove!(store, slug)

Remove a skill from the verified store entirely.
"""
function remove!(store::SkillStore, slug::AbstractString)
    s = String(slug)
    lock(store.lock) do
        haskey(store.manifest, s) || return nothing
        rm(quarantine_dir(store, s); force = true, recursive = true)
        rm(verified_dir(store, s); force = true, recursive = true)
        delete!(store.manifest, s)
    end
    save_manifest!(store)
    return nothing
end

get_entry(store::SkillStore, slug::AbstractString) = lock(() -> get(store.manifest, String(slug), nothing), store.lock)

function list_entries(store::SkillStore; status::Union{Nothing,AbstractString} = nothing)
    lock(store.lock) do
        entries = collect(values(store.manifest))
        if status !== nothing
            filter!(e -> e.status == String(status), entries)
        end
        sort!(entries; by = e -> e.slug)
        return entries
    end
end

has_skill(store::SkillStore, slug::AbstractString) = lock(() -> haskey(store.manifest, String(slug)), store.lock)
