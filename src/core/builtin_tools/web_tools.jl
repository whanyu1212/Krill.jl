function _extract_ddg_results(html::AbstractString, max_results::Int)
    matches = collect(eachmatch(
        r"""<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"""is,
        String(html),
    ))
    results = Dict{String,String}[]
    for m in matches
        url = strip(_decode_html_entities(String(m.captures[1])))
        title = strip(_strip_html(String(m.captures[2])))
        isempty(url) && continue
        isempty(title) && continue
        push!(results, Dict("title" => title, "url" => url))
        length(results) >= max_results && break
    end
    return results
end

function _web_search_impl(args::Dict{String,Any}; max_results::Int)
    query = get(args, "query", nothing)
    query isa AbstractString || return "Error: `query` must be a string"
    query_s = strip(String(query))
    isempty(query_s) && return "Error: `query` must not be empty"

    count = try
        clamp(Int(get(args, "count", max_results)), 1, 10)
    catch _
        clamp(max_results, 1, 10)
    end

    url = "https://duckduckgo.com/html/?q=$(HTTP.escapeuri(query_s))"
    headers = Pair{String,String}[
        "User-Agent" => "Krill/1.0",
        "Accept" => "text/html",
    ]

    response = try
        _safe_http_get(url; headers=headers, request_fn=HTTP.request)
    catch e
        return "Error: web_search request failed: $(sprint(showerror, e))"
    end

    response.status == 200 || return "Error: web_search HTTP status $(response.status)"
    html = try
        String(response.body)
    catch e
        return "Error: could not decode search response: $(sprint(showerror, e))"
    end

    results = _extract_ddg_results(html, count)
    isempty(results) && return "No results for: $(query_s)"

    lines = String["Results for: $(query_s)", ""]
    for (i, item) in enumerate(results)
        push!(lines, "$(i). $(item["title"])")
        push!(lines, "   $(item["url"])")
    end
    return join(lines, "\n")
end

const _MAX_REDIRECTS = 5

function _web_fetch_impl(
    args::Dict{String,Any};
    max_chars::Int=_DEFAULT_WEB_FETCH_LIMIT,
    request_fn::Function=HTTP.request,
)
    url = get(args, "url", nothing)
    url isa AbstractString || return "Error: `url` must be a string"

    resolved_url, err = _validate_http_url(url)
    resolved_url === nothing && return err

    max_chars = try
        max(1, Int(get(args, "max_chars", max_chars)))
    catch _
        max_chars
    end

    # Manually follow redirects so we can re-validate each hop against SSRF rules.
    # HTTP.jl would follow redirects transparently, bypassing our checks.
    current_url = resolved_url
    response = nothing
    for _ in 1:_MAX_REDIRECTS
        response = try
            request_fn(
                "GET",
                current_url;
                headers=Pair{String,String}["User-Agent" => "Krill/1.0"],
                readtimeout=_WEB_TOOL_TIMEOUT_SECONDS,
                require_ssl_verification=true,
                redirect=false,
            )
        catch e
            if _is_insecure_web_fetch_allowed() &&
                startswith(lowercase(current_url), "https://") &&
                _is_certificate_error(e)
                try
                    request_fn(
                        "GET",
                        current_url;
                        headers=Pair{String,String}["User-Agent" => "Krill/1.0"],
                        readtimeout=_WEB_TOOL_TIMEOUT_SECONDS,
                        require_ssl_verification=false,
                        redirect=false,
                    )
                catch e2
                    return "Error: web_fetch request failed: $(sprint(showerror, e2))"
                end
            elseif _is_certificate_error(e)
                return "Error: web_fetch request failed: unable to verify certificate chain. Set $(_WEB_FETCH_ALLOW_INSECURE_ENV)=1 to retry without certificate verification."
            else
                return "Error: web_fetch request failed: $(sprint(showerror, e))"
            end
        end

        if response.status in (301, 302, 303, 307, 308)
            location = _header_value(response.headers, "location")
            location === nothing && return "Error: redirect with no Location header"
            # Resolve relative redirects against current URL
            next_url = _strip_protocol_relative(String(location))
            if !startswith(next_url, "http://") && !startswith(next_url, "https://")
                base_uri = HTTP.URI(current_url)
                next_url = string(base_uri.scheme) * "://" * string(base_uri.host) * next_url
            end
            # Re-validate the redirect destination — this is the critical SSRF check
            validated, rerr = _validate_http_url(next_url)
            if validated === nothing
                return "Error: redirect blocked — $(rerr)"
            end
            current_url = validated
            continue
        end
        break
    end

    response === nothing && return "Error: web_fetch failed (no response)"
    response.status == 200 || return "Error: web_fetch HTTP status $(response.status)"

    raw_body = try
        String(response.body)
    catch e
        return "Error: could not decode response: $(sprint(showerror, e))"
    end

    content_type = _header_value(response.headers, "content-type")
    lower_ct = lowercase(content_type === nothing ? "" : String(content_type))
    content = if startswith(lower_ct, "text/html") || occursin("html", lower_ct)
        _html_to_markdown(raw_body)
    else
        raw_body
    end

    return _truncate_text(content, max_chars)
end
