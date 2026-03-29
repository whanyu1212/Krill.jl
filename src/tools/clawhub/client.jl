const _CLAWHUB_DEFAULT_URL = "https://clawhub.ai/api/v1"
const _CLAWHUB_TIMEOUT_SECONDS = 15
const _CLAWHUB_USER_AGENT = "Krill/1.0"

"""
    ClawHubClient(; base_url, auth_token)

HTTP client for the ClawHub skill registry API.
"""
struct ClawHubClient
    base_url::String
    auth_token::Union{Nothing,String}
end

function ClawHubClient(;
    base_url::AbstractString = _CLAWHUB_DEFAULT_URL,
    auth_token::Union{Nothing,AbstractString} = nothing,
)
    url = rstrip(String(base_url), '/')
    token = auth_token === nothing ? nothing : String(auth_token)
    return ClawHubClient(url, token)
end

function _clawhub_headers(client::ClawHubClient)
    headers = Pair{String,String}[
        "User-Agent" => _CLAWHUB_USER_AGENT,
        "Accept" => "application/json",
    ]
    if client.auth_token !== nothing && !isempty(client.auth_token)
        push!(headers, "Authorization" => "Bearer $(client.auth_token)")
    end
    return headers
end

function _clawhub_get(client::ClawHubClient, path::AbstractString)
    url = "$(client.base_url)/$(lstrip(String(path), '/'))"
    resp = HTTP.request(
        "GET", url;
        headers = _clawhub_headers(client),
        readtimeout = _CLAWHUB_TIMEOUT_SECONDS,
        status_exception = false,
    )
    if resp.status >= 400
        body_preview = String(resp.body)
        if length(body_preview) > 200
            body_preview = body_preview[1:200] * "…"
        end
        throw(ErrorException("ClawHub API error $(resp.status): $(body_preview)"))
    end
    return JSON3.read(String(resp.body))
end

"""
    clawhub_search(client, query; limit=10) -> Vector{Dict{String,Any}}

Search the ClawHub registry by natural language query. Returns skill metadata dicts.
"""
function clawhub_search(client::ClawHubClient, query::AbstractString; limit::Int = 10)
    encoded_query = HTTP.escapeuri(strip(String(query)))
    path = "skills?q=$(encoded_query)&limit=$(limit)"
    result = _clawhub_get(client, path)

    skills = Dict{String,Any}[]
    items = if result isa AbstractVector
        result
    elseif result isa AbstractDict
        get(result, :skills, get(result, :results, get(result, :items, Any[])))
    else
        Any[]
    end

    for item in items
        item isa AbstractDict || continue
        d = Dict{String,Any}()
        for (k, v) in pairs(item)
            d[String(k)] = v
        end
        push!(skills, d)
    end
    return skills
end

"""
    clawhub_skill_info(client, slug) -> Dict{String,Any}

Get detailed metadata for a single skill by slug.
"""
function clawhub_skill_info(client::ClawHubClient, slug::AbstractString)
    result = _clawhub_get(client, "skills/$(HTTP.escapeuri(String(slug)))")
    d = Dict{String,Any}()
    if result isa AbstractDict
        for (k, v) in pairs(result)
            d[String(k)] = v
        end
    end
    return d
end

"""
    clawhub_download(client, slug, version, dest_dir) -> String

Download a skill ZIP from ClawHub and extract it into `dest_dir`.
Returns the path to the extracted skill directory.
"""
function clawhub_download(
    client::ClawHubClient,
    slug::AbstractString,
    version::AbstractString,
    dest_dir::AbstractString,
)
    s = strip(String(slug))
    v = strip(String(version))
    isempty(s) && throw(ArgumentError("slug must not be empty"))
    isempty(v) && (v = "latest")

    url = "$(client.base_url)/download/$(HTTP.escapeuri(s))/$(HTTP.escapeuri(v))"
    resp = HTTP.request(
        "GET", url;
        headers = _clawhub_headers(client),
        readtimeout = _CLAWHUB_TIMEOUT_SECONDS,
        status_exception = false,
    )
    if resp.status >= 400
        body_preview = String(resp.body)
        if length(body_preview) > 200
            body_preview = body_preview[1:200] * "…"
        end
        throw(ErrorException("ClawHub download error $(resp.status): $(body_preview)"))
    end

    mkpath(String(dest_dir))
    zip_path = joinpath(String(dest_dir), "$(s).zip")
    write(zip_path, resp.body)

    # Compute SHA256 of the downloaded ZIP
    hash = bytes2hex(sha256(resp.body))

    # Extract ZIP
    try
        run(pipeline(`unzip -o $zip_path -d $(String(dest_dir))`; stderr = devnull))
    catch e
        throw(ErrorException("Failed to extract skill ZIP: $(sprint(showerror, e))"))
    end

    # Clean up ZIP file
    try
        rm(zip_path; force = true)
    catch _
    end

    return hash
end
