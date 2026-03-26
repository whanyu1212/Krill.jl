# Tool context for cron: auto-injected session routing info
const _CRON_CONTEXT = Ref{@NamedTuple{channel::Symbol,session_key::String,chat_id::String}}(
    (channel = :system, session_key = "", chat_id = "")
)

"""
    set_cron_context!(channel, session_key, chat_id)

Set the global cron routing context (channel, session key, chat ID) for tool invocations.
"""
function set_cron_context!(channel::Symbol, session_key::AbstractString, chat_id::AbstractString)
    _CRON_CONTEXT[] = (channel = channel, session_key = String(session_key), chat_id = String(chat_id))
end

const _DEFAULT_READ_LIMIT = 2_000
const _DEFAULT_LIST_LIMIT = 200
const _DEFAULT_WEB_FETCH_LIMIT = 8_000
const _MAX_EXEC_OUTPUT_CHARS = 10_000
const _WEB_TOOL_TIMEOUT_SECONDS = 15
const _WEB_FETCH_ALLOW_INSECURE_ENV = "KRILL_WEB_FETCH_ALLOW_INSECURE"

const _SSRF_BLOCKED_HOSTS = (
    "localhost",
    "localhost.localdomain",
)

function _is_insecure_web_fetch_allowed()
    value = lowercase(strip(get(ENV, _WEB_FETCH_ALLOW_INSECURE_ENV, "")))
    return value in ("1", "true", "yes", "on")
end

function _is_certificate_error(err::Any)
    msg = lowercase(sprint(showerror, err))
    return (
        occursin("unable to get local issuer", msg) ||
        occursin("certificate verify failed", msg) ||
        occursin("certificate verification failed", msg) ||
        occursin("x509: certificate", msg)
    )
end

function _safe_http_get(
    url::AbstractString,
    ;
    request_fn::Function = HTTP.request,
    headers::AbstractVector = Pair{String,String}[],
)
    return request_fn(
        "GET",
        url;
        headers = headers,
        readtimeout = _WEB_TOOL_TIMEOUT_SECONDS,
        require_ssl_verification = true,
    )
end

function _safe_web_fetch_request(
    url::AbstractString;
    request_fn::Function = HTTP.request,
    headers::AbstractVector = Pair{String,String}[],
)
    try
        return _safe_http_get(
            url;
            request_fn = request_fn,
            headers = headers,
        )
    catch e
        normalized_url = lowercase(String(url))
        if _is_insecure_web_fetch_allowed() &&
           startswith(normalized_url, "https://") &&
           _is_certificate_error(e)
            return request_fn(
                "GET",
                url;
                headers = Pair{String,String}[
                    String(p.first) => String(p.second) for p in headers
                ],
                readtimeout = _WEB_TOOL_TIMEOUT_SECONDS,
                require_ssl_verification = false,
            )
        end
        rethrow()
    end
end

function _header_value(headers, key::AbstractString)
    target = lowercase(String(key))
    for pair in headers
        if lowercase(String(pair[1])) == target
            return String(pair[2])
        end
    end
    return nothing
end

function _strip_protocol_relative(url::AbstractString)
    out = String(url)
    startswith(out, "//") && return "https:" * out
    return out
end

# Check a resolved IP address (IPv4 or IPv6) against all private/link-local ranges.
# This is the authoritative check — used after DNS resolution and after each redirect.
function _is_forbidden_ip(ip::IPAddr)
    if ip isa IPv4
        o = ip.host  # UInt32, network byte order
        a = (o >> 24) & 0xff
        b = (o >> 16) & 0xff
        a == 127 && return true          # 127.0.0.0/8  loopback
        a == 10 && return true           # 10.0.0.0/8   private
        a == 0 && return true            # 0.0.0.0/8    reserved
        a == 169 && b == 254 && return true  # 169.254.0.0/16 link-local / cloud metadata
        a == 192 && b == 168 && return true  # 192.168.0.0/16 private
        a == 172 && 16 <= b <= 31 && return true  # 172.16.0.0/12 private
        a == 100 && 64 <= b <= 127 && return true  # 100.64.0.0/10 shared address space
        a == 198 && b == 18 && return true   # 198.18.0.0/15 benchmarking
        a == 198 && b == 19 && return true
        a == 203 && b == 0 && return true    # 203.0.113.0/24 documentation
        a == 255 && return true              # 255.x.x.x broadcast
        return false
    elseif ip isa IPv6
        s = string(ip)
        s == "::1" && return true                    # loopback
        s == "::" && return true                     # unspecified
        startswith(s, "fc") && return true           # fc00::/7 ULA
        startswith(s, "fd") && return true
        startswith(s, "fe80") && return true         # fe80::/10 link-local
        startswith(s, "::ffff:") && return true      # IPv4-mapped
        startswith(s, "2001:db8") && return true     # documentation
        return false
    end
    return false
end

# Resolve hostname via DNS and check every returned IP against blocked ranges.
# Returns an error string if blocked, nothing if safe.
function _validate_host_dns(host::AbstractString)
    ips = try
        Sockets.getaddrinfo(String(host))
    catch _
        # DNS failure is not a security block — let the HTTP layer handle it
        return nothing
    end
    # getaddrinfo returns a single IPAddr; check it
    ip_list = ips isa AbstractVector ? ips : [ips]
    for ip in ip_list
        if _is_forbidden_ip(ip)
            return "Error: URL host resolves to a blocked IP address ($(ip))"
        end
    end
    return nothing
end

function _is_forbidden_host(host::AbstractString)
    normalized = lowercase(strip(host))
    isempty(normalized) && return true
    normalized in _SSRF_BLOCKED_HOSTS && return true
    endswith(normalized, ".localhost") && return true

    if occursin('@', normalized)
        return true
    end

    m = match(r"^\d{1,3}(?:\.\d{1,3}){3}$", normalized)
    if m !== nothing
        parts = try
            [parse(Int, p) for p in split(normalized, ".")]
        catch _
            Int[]
        end
        if length(parts) == 4
            if parts[1] == 127 || parts[1] == 10
                return true
            end
            if parts[1] == 192 && parts[2] == 168
                return true
            end
            if parts[1] == 172 && 16 <= parts[2] <= 31
                return true
            end
            if parts[1] == 169 && parts[2] == 254
                return true
            end
            if parts[1] == 0
                return true
            end
        end
    end

    if occursin(":", normalized) && (
        startswith(normalized, "::1") ||
        startswith(normalized, "0:0:0:0:0:0:0:") ||
        normalized == "::" ||
        startswith(normalized, "fc") ||
        startswith(normalized, "fd") ||
        startswith(normalized, "fe80") ||
        startswith(normalized, "fe9") ||
        startswith(normalized, "fea") ||
        startswith(normalized, "feb") ||
        startswith(normalized, "::ffff:")
    )
        return true
    end

    return false
end

function _validate_http_url(raw_url::AbstractString)
    url = _strip_protocol_relative(strip(raw_url))
    isempty(url) && return nothing, "Error: `url` must not be empty"

    uri = try
        HTTP.URI(url)
    catch _
        return nothing, "Error: invalid URL"
    end

    if lowercase(String(uri.scheme)) ∉ ("http", "https")
        return nothing, "Error: URL must use http:// or https://"
    end

    raw_host = uri.host
    raw_host === nothing && return nothing, "Error: URL is missing host"

    if _is_forbidden_host(String(raw_host))
        return nothing, "Error: URL host is blocked for safety"
    end

    # DNS resolution check — catches domains that resolve to private IPs
    dns_err = _validate_host_dns(String(raw_host))
    dns_err !== nothing && return nothing, dns_err

    return url, nothing
end

function _html_to_markdown(html::AbstractString)
    out = replace(String(html), r"(?is)<script[^>]*>.*?</script>" => "")
    out = replace(out, r"(?is)<style[^>]*>.*?</style>" => "")
    out = replace(out, r"(?is)<noscript[^>]*>.*?</noscript>" => "")
    out = replace(out, r"(?is)<br\s*/?>" => "\n")
    out = replace(out, r"(?is)<hr\s*/?>" => "\n---\n")
    out = replace(out, r"(?is)</(p|div|section|article)>" => "\n\n")
    out = replace(out, r"(?is)<li[^>]*>(.*?)</li>" => s"- \1")
    out = replace(out, r"(?is)<h1[^>]*>(.*?)</h1>" => s"# \1")
    out = replace(out, r"(?is)<h2[^>]*>(.*?)</h2>" => s"## \1")
    out = replace(out, r"(?is)<h3[^>]*>(.*?)</h3>" => s"### \1")
    out = replace(out, r"(?is)<h4[^>]*>(.*?)</h4>" => s"#### \1")
    out = replace(out, r"(?is)<h5[^>]*>(.*?)</h5>" => s"##### \1")
    out = replace(out, r"(?is)<h6[^>]*>(.*?)</h6>" => s"###### \1")
    out = replace(out, r"(?is)<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>" => s"[\2](\1)")
    out = replace(out, r"<[^>]+>" => "")
    return strip(_decode_html_entities(out))
end

function _is_within(path::AbstractString, root::AbstractString)
    npath = normpath(abspath(path))
    nroot = normpath(abspath(root))
    npath == nroot && return true
    sep = Base.Filesystem.path_separator
    return startswith(npath, nroot * string(sep))
end

function _resolve_path(path::AbstractString, workspace::AbstractString; restrict_to_workspace::Bool = true)
    raw = expanduser(String(path))
    resolved = isabspath(raw) ? normpath(abspath(raw)) : normpath(abspath(joinpath(workspace, raw)))
    if restrict_to_workspace
        # Resolve the workspace root via realpath (follows symlinks, e.g. /tmp → /private/tmp on macOS).
        real_workspace = try
            realpath(workspace)
        catch _
            normpath(abspath(workspace))
        end
        # For the target path: resolve symlinks if the path exists; if it doesn't exist yet
        # (e.g. a new file being written), resolve as far as possible by resolving the parent.
        real = if ispath(resolved)
            realpath(resolved)
        else
            parent_real = try
                realpath(dirname(resolved))
            catch _
                normpath(abspath(dirname(resolved)))
            end
            joinpath(parent_real, basename(resolved))
        end
        _is_within(real, real_workspace) || throw(ArgumentError("Path is outside workspace: $(path)"))
    end
    return resolved
end

function _parse_bool(value; default::Bool = false)
    value === nothing && return default
    value isa Bool && return value
    if value isa AbstractString
        v = lowercase(strip(String(value)))
        if v in ("1", "true", "yes", "on")
            return true
        elseif v in ("0", "false", "no", "off")
            return false
        end
    end
    return default
end

function _truncate_text(s::AbstractString, max_chars::Int)
    max_chars <= 0 && return String(s)
    length(s) <= max_chars && return String(s)
    half = max(1, max_chars ÷ 2)
    omitted = length(s) - (2 * half)
    return String(first(String(s), half)) *
           "\n\n... ($(omitted) chars truncated) ...\n\n" *
           String(last(String(s), half))
end

function _decode_html_entities(text::AbstractString)
    out = String(text)
    out = replace(out, "&amp;" => "&")
    out = replace(out, "&lt;" => "<")
    out = replace(out, "&gt;" => ">")
    out = replace(out, "&quot;" => "\"")
    out = replace(out, "&#39;" => "'")
    out = replace(out, "&nbsp;" => " ")
    return out
end

function _strip_html(text::AbstractString)
    out = replace(String(text), r"<[^>]+>" => "")
    return strip(_decode_html_entities(out))
end
