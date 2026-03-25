module MCP

using HTTP
using JSON3

using ..Tools: ToolDef, ToolRegistry, register_tool!

export MCPServer,
    AbstractMCPClient,
    MCPStdioClient,
    MCPHTTPClient,
    MCPConnectionSet,
    connect,
    connect!,
    reconnect!,
    close!,
    list_tools,
    call_tool,
    mcp_wrapped_tool_name,
    register_mcp_tools!,
    connect_mcp_servers!

"""
    MCPServer(; name, transport=:auto, command=nothing, args=String[], env=Dict(), url=nothing,
                headers=Dict(), request_timeout_s=30.0, tool_timeout_s=30.0,
                enabled_tools=["*"], cache_tools=true)

MCP server configuration for either stdio or HTTP transport.

- `name`: logical server name used for namespaced tool IDs.
- `transport`: `:auto`, `:stdio`, `:sse`, or `:streamable_http`.
- `enabled_tools`: allowlist of tool names; accepts raw names or wrapped names.
  Use `["*"]` (default) for all tools, or `String[]` for none.
"""
struct MCPServer
    name::String
    transport::Symbol
    command::Union{Nothing,String}
    args::Vector{String}
    env::Dict{String,String}
    url::Union{Nothing,String}
    headers::Dict{String,String}
    request_timeout_s::Float64
    tool_timeout_s::Float64
    enabled_tools::Vector{String}
    cache_tools::Bool
end

function MCPServer(;
    name::AbstractString,
    transport::Union{Symbol,AbstractString}=:auto,
    command::Union{Nothing,AbstractString}=nothing,
    args::Vector{String}=String[],
    env::Dict{String,String}=Dict{String,String}(),
    url::Union{Nothing,AbstractString}=nothing,
    headers::Dict{String,String}=Dict{String,String}(),
    request_timeout_s::Real=30.0,
    tool_timeout_s::Real=30.0,
    enabled_tools::AbstractVector=Any["*"],
    cache_tools::Bool=true,
)
    sname = strip(String(name))
    isempty(sname) && throw(ArgumentError("MCPServer name must not be empty"))
    timeout_req = Float64(request_timeout_s)
    timeout_tool = Float64(tool_timeout_s)
    timeout_req > 0 || throw(ArgumentError("request_timeout_s must be > 0"))
    timeout_tool > 0 || throw(ArgumentError("tool_timeout_s must be > 0"))

    ntransport = _normalize_transport(transport)
    cmd = command === nothing ? nothing : String(command)
    endpoint = url === nothing ? nothing : String(url)

    if ntransport == :stdio
        cmd === nothing && throw(ArgumentError("MCPServer transport=:stdio requires `command`"))
        endpoint === nothing || throw(ArgumentError("MCPServer transport=:stdio does not accept `url`"))
    elseif ntransport in (:sse, :streamable_http)
        endpoint === nothing && throw(ArgumentError("MCPServer HTTP transport requires `url`"))
        cmd === nothing || throw(ArgumentError("MCPServer HTTP transport does not accept `command`"))
    else
        (cmd === nothing) == (endpoint === nothing) &&
            throw(ArgumentError("MCPServer transport=:auto requires exactly one of `command` or `url`"))
    end

    enabled = String[String(v) for v in enabled_tools]
    return MCPServer(
        sname,
        ntransport,
        cmd,
        copy(args),
        copy(env),
        endpoint,
        copy(headers),
        timeout_req,
        timeout_tool,
        enabled,
        cache_tools,
    )
end

"""
    AbstractMCPClient

Abstract supertype for MCP client connections (stdio or HTTP transport).
"""
abstract type AbstractMCPClient end

"""
    MCPStdioClient <: AbstractMCPClient

MCP client that communicates with a server over stdin/stdout JSON-RPC.
"""
mutable struct MCPStdioClient <: AbstractMCPClient
    server::MCPServer
    proc::Union{Nothing,Base.Process}
    proc_stdin::Union{Nothing,IO}
    proc_stdout::Union{Nothing,IO}
    request_id::Int
    tools_cache::Union{Nothing,Vector{Dict{String,Any}}}
    lock::ReentrantLock
end

"""
    MCPHTTPClient <: AbstractMCPClient

MCP client that communicates with a server over HTTP (SSE or streamable HTTP).
"""
mutable struct MCPHTTPClient <: AbstractMCPClient
    server::MCPServer
    transport::Symbol
    request_id::Int
    tools_cache::Union{Nothing,Vector{Dict{String,Any}}}
    lock::ReentrantLock
end

"""
    MCPConnectionSet

Result of [`connect_mcp_servers!`](@ref): holds live clients, registered tool names per server,
and error messages for any servers that failed to connect.
"""
struct MCPConnectionSet
    clients::Vector{AbstractMCPClient}
    registered_tools::Dict{String,Vector{String}}
    failed_servers::Dict{String,String}
end

_sanitize_name(s::AbstractString) = replace(strip(String(s)), r"[^A-Za-z0-9_]" => "_")

"""
    mcp_wrapped_tool_name(server_name, tool_name) -> String

Return the namespaced tool name `"mcp_<server>_<tool>"` used when registering MCP tools.
"""
function mcp_wrapped_tool_name(server_name::AbstractString, tool_name::AbstractString)
    s = _sanitize_name(server_name)
    t = _sanitize_name(tool_name)
    isempty(s) && (s = "server")
    isempty(t) && (t = "tool")
    return "mcp_$(s)_$(t)"
end

function _normalize_transport(transport::Union{Symbol,AbstractString})
    raw = lowercase(strip(String(transport)))
    if raw in ("auto",)
        return :auto
    elseif raw in ("stdio",)
        return :stdio
    elseif raw in ("sse",)
        return :sse
    elseif raw in ("streamable_http", "streamablehttp", "http", "post")
        return :streamable_http
    end
    throw(ArgumentError("Unsupported MCP transport: $(transport)"))
end

function _resolved_transport(server::MCPServer)
    if server.transport != :auto
        return server.transport
    end
    if server.command !== nothing
        return :stdio
    end
    endpoint = lowercase(strip(String(server.url)))
    return endswith(endpoint, "/sse") ? :sse : :streamable_http
end

function _next_id!(client::MCPStdioClient)
    client.request_id += 1
    return client.request_id
end

function _next_id!(client::MCPHTTPClient)
    client.request_id += 1
    return client.request_id
end

function _http_readtimeout(timeout_s::Real)
    # HTTP.jl expects an integer timeout value for `readtimeout`.
    return max(1, ceil(Int, Float64(timeout_s)))
end

function _to_plain(value)
    if value isa AbstractDict
        out = Dict{String,Any}()
        for (k, v) in pairs(value)
            out[String(k)] = _to_plain(v)
        end
        return out
    elseif value isa AbstractVector
        return Any[_to_plain(v) for v in value]
    end
    return value
end

function _parse_rpc_json(raw::AbstractString)
    parsed = JSON3.read(raw)
    plain = _to_plain(parsed)
    plain isa AbstractDict || throw(ArgumentError("MCP response is not a JSON object"))
    return Dict{String,Any}(String(k) => v for (k, v) in pairs(plain))
end

function _stdio_process_alive(client::MCPStdioClient)
    client.proc === nothing && return false
    return process_running(client.proc)
end

function _stdio_reconnect!(client::MCPStdioClient)
    @warn "MCP stdio process died, attempting reconnect" server=client.server.name
    close!(client)
    connect!(client)
    @info "MCP stdio reconnected" server=client.server.name
end

function _rpc(
    client::MCPStdioClient,
    method::String,
    params=nothing;
    timeout_s::Real=client.server.request_timeout_s,
)
    # Auto-reconnect if process has died (but not for the initial `initialize` call)
    if method != "initialize" && !_stdio_process_alive(client)
        _stdio_reconnect!(client)
    end

    client.proc_stdin === nothing && throw(ArgumentError("MCP stdio client is not connected"))
    client.proc_stdout === nothing && throw(ArgumentError("MCP stdio client is not connected"))

    request_id = _next_id!(client)
    req = Dict{String,Any}(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => method,
    )
    params === nothing || (req["params"] = params)

    try
        write(client.proc_stdin, JSON3.write(req) * "\n")
        flush(client.proc_stdin)
    catch e
        # Write failed — process may have died. Try reconnect once.
        if method != "initialize"
            _stdio_reconnect!(client)
            request_id = _next_id!(client)
            req["id"] = request_id
            write(client.proc_stdin, JSON3.write(req) * "\n")
            flush(client.proc_stdin)
        else
            rethrow()
        end
    end

    result_ref = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
    error_ref = Ref{Union{Nothing,String}}(nothing)

    read_task = @async begin
        while true
            raw = try
                readline(client.proc_stdout)
            catch _
                ""
            end
            isempty(raw) && break

            resp = try
                _parse_rpc_json(raw)
            catch _
                continue
            end

            # Skip server-initiated notifications (no "id" field)
            haskey(resp, "id") || continue
            resp["id"] == request_id || continue
            if haskey(resp, "error")
                err = _to_plain(resp["error"])
                if err isa AbstractDict
                    code = get(err, "code", "?")
                    msg = get(err, "message", "unknown")
                    error_ref[] = "MCP error $(code): $(msg)"
                else
                    error_ref[] = "MCP error: $(err)"
                end
            else
                result_ref[] = resp
            end
            break
        end
    end

    wait_status = timedwait(() -> istaskdone(read_task), Float64(timeout_s); pollint=0.01)
    if wait_status == :timed_out
        throw(ErrorException("MCP timeout ($(timeout_s)s) waiting for response to $(method)"))
    end

    error_ref[] === nothing || throw(ErrorException(error_ref[]))
    result_ref[] === nothing && throw(ErrorException("MCP: no response received for $(method)"))
    return result_ref[]
end

function _parse_sse_rpc(body::AbstractString)
    last_data = nothing
    # SSE spec: multiple `data:` lines within a single event are concatenated
    # with newlines. Accumulate data lines between blank-line event boundaries.
    data_buffer = String[]
    for line in split(String(body), r"\r?\n")
        stripped = strip(line)
        # Keep-alive comments (lines starting with `:`) — skip
        if startswith(stripped, ":")
            continue
        end
        # `event:` lines — skip (we only care about data)
        if startswith(stripped, "event:")
            continue
        end
        # `id:` lines — skip (not needed for JSON-RPC)
        if startswith(stripped, "id:") && !startswith(stripped, "id\"")
            continue
        end
        # `retry:` lines — skip
        if startswith(stripped, "retry:")
            continue
        end
        if startswith(stripped, "data:")
            payload = strip(stripped[6:end])
            # data: [DONE] is a common sentinel — skip
            payload == "[DONE]" && continue
            isempty(payload) || push!(data_buffer, payload)
            continue
        end
        # Blank line = event boundary: try to parse accumulated data
        if isempty(stripped) && !isempty(data_buffer)
            combined = join(data_buffer, "\n")
            empty!(data_buffer)
            parsed = try
                _parse_rpc_json(combined)
            catch _
                continue
            end
            # Only accept JSON-RPC responses (must have `id`); ignore notifications
            haskey(parsed, "id") && (last_data = parsed)
            continue
        end
    end
    # Handle trailing data without a final blank line
    if !isempty(data_buffer)
        combined = join(data_buffer, "\n")
        parsed = try
            _parse_rpc_json(combined)
        catch _
            nothing
        end
        if parsed !== nothing && haskey(parsed, "id")
            last_data = parsed
        end
    end

    last_data === nothing &&
        throw(ErrorException("MCP HTTP (SSE): no JSON-RPC response found in stream"))
    return last_data
end

const _MCP_HTTP_RETRIABLE_STATUS = Set([408, 429, 500, 502, 503, 504])
const _MCP_HTTP_MAX_RETRIES = 3
const _MCP_HTTP_RETRY_BASE_DELAY = 0.5

function _is_retriable_http_error(e)
    msg = lowercase(sprint(showerror, e))
    return occursin("timeout", msg) || occursin("connection refused", msg) ||
           occursin("connection reset", msg) || occursin("eof", msg) ||
           occursin("broken pipe", msg)
end

function _rpc(
    client::MCPHTTPClient,
    method::String,
    params=nothing;
    timeout_s::Real=client.server.request_timeout_s,
)
    request_id = _next_id!(client)
    req = Dict{String,Any}(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => method,
    )
    params === nothing || (req["params"] = params)

    headers = Pair{String,String}[
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
    ]
    append!(headers, Pair{String,String}[String(k) => String(v) for (k, v) in client.server.headers])

    last_error = nothing
    for attempt in 1:(_MCP_HTTP_MAX_RETRIES + 1)
        response = try
            HTTP.request(
                "POST",
                String(client.server.url),
                headers,
                JSON3.write(req);
                readtimeout=_http_readtimeout(timeout_s),
                status_exception=false,
            )
        catch e
            if attempt <= _MCP_HTTP_MAX_RETRIES && _is_retriable_http_error(e)
                last_error = e
                delay = _MCP_HTTP_RETRY_BASE_DELAY * (2.0 ^ (attempt - 1))
                @warn "MCP HTTP request failed, retrying" method=method attempt=attempt delay_s=delay error=sprint(showerror, e)
                sleep(delay)
                continue
            end
            throw(ErrorException("MCP HTTP request failed: $(sprint(showerror, e))"))
        end

        # Retry on retriable HTTP status codes
        if response.status in _MCP_HTTP_RETRIABLE_STATUS && attempt <= _MCP_HTTP_MAX_RETRIES
            delay = _MCP_HTTP_RETRY_BASE_DELAY * (2.0 ^ (attempt - 1))
            @warn "MCP HTTP retriable status" method=method status=response.status attempt=attempt delay_s=delay
            sleep(delay)
            continue
        end

        # Non-retriable HTTP error
        if response.status >= 400
            body_preview = String(response.body)
            if length(body_preview) > 200
                body_preview = body_preview[1:200] * "…"
            end
            throw(ErrorException("MCP HTTP error $(response.status): $(body_preview)"))
        end

        body = String(response.body)
        header_map = Dict{String,String}(String(k) => String(v) for (k, v) in response.headers)
        content_type = lowercase(get(header_map, "Content-Type", get(header_map, "content-type", "")))

        parsed = if occursin("text/event-stream", content_type)
            _parse_sse_rpc(body)
        else
            try
                _parse_rpc_json(body)
            catch _
                throw(ErrorException("MCP HTTP: could not parse response JSON"))
            end
        end

        if haskey(parsed, "error")
            err = _to_plain(parsed["error"])
            if err isa AbstractDict
                code = get(err, "code", "?")
                msg = get(err, "message", "unknown")
                throw(ErrorException("MCP error $(code): $(msg)"))
            end
            throw(ErrorException("MCP error: $(err)"))
        end

        return parsed
    end

    # Exhausted retries
    err_msg = last_error !== nothing ? sprint(showerror, last_error) : "unknown"
    throw(ErrorException("MCP HTTP request failed after $(_MCP_HTTP_MAX_RETRIES + 1) attempts: $(err_msg)"))
end

function _send_initialized_notification!(client::MCPStdioClient)
    client.proc_stdin === nothing && return nothing
    notif = Dict{String,Any}(
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => Dict{String,Any}(),
    )
    write(client.proc_stdin, JSON3.write(notif) * "\n")
    flush(client.proc_stdin)
    return nothing
end

function _send_initialized_notification!(client::MCPHTTPClient)
    notif = Dict{String,Any}(
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => Dict{String,Any}(),
    )
    headers = Pair{String,String}[
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
    ]
    append!(headers, Pair{String,String}[String(k) => String(v) for (k, v) in client.server.headers])
    try
        HTTP.request(
            "POST",
            String(client.server.url),
            headers,
            JSON3.write(notif);
            readtimeout=_http_readtimeout(client.server.request_timeout_s),
        )
    catch _
        # Best effort notification.
    end
    return nothing
end

"""
    connect!(client::AbstractMCPClient) -> AbstractMCPClient

Open the transport, perform the MCP `initialize` handshake, and return the connected client.
"""
function connect!(client::MCPStdioClient)
    server = client.server
    server.command === nothing && throw(ArgumentError("MCP stdio server requires `command`"))

    cmd = Cmd([String(server.command), server.args...])
    if !isempty(server.env)
        merged_env = merge(
            Dict{String,String}(String(k) => String(v) for (k, v) in ENV),
            server.env,
        )
        cmd = Cmd(cmd; env=merged_env)
    end

    inp = Pipe()
    out = Pipe()

    try
        proc = run(pipeline(cmd; stdin=inp, stdout=out, stderr=devnull); wait=false)
        close(inp.out)
        close(out.in)
        client.proc = proc
        client.proc_stdin = inp.in
        client.proc_stdout = out.out

        # Give local servers a small startup window before initialize.
        sleep(0.2)
        _rpc(
            client,
            "initialize",
            Dict{String,Any}(
                "protocolVersion" => "2024-11-05",
                "capabilities" => Dict{String,Any}(),
                "clientInfo" => Dict{String,Any}(
                    "name" => "Krill.jl",
                    "version" => "0.1",
                ),
            );
            timeout_s=server.request_timeout_s,
        )
        _send_initialized_notification!(client)
        return client
    catch e
        close!(client)
        rethrow()
    end
end

function connect!(client::MCPHTTPClient)
    _rpc(
        client,
        "initialize",
        Dict{String,Any}(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}(
                "name" => "Krill.jl",
                "version" => "0.1",
            ),
        );
        timeout_s=client.server.request_timeout_s,
    )
    _send_initialized_notification!(client)
    return client
end

"""
    reconnect!(client::AbstractMCPClient)

Re-establish connection after a transient failure. Clears cached tools.
"""
function reconnect!(client::MCPStdioClient)
    _stdio_reconnect!(client)
end

function reconnect!(client::MCPHTTPClient)
    client.tools_cache = nothing
    connect!(client)
end

"""
    connect(server::MCPServer) -> AbstractMCPClient

Create and connect a new MCP client for the given server configuration.
"""
function connect(server::MCPServer)
    transport = _resolved_transport(server)
    if transport == :stdio
        client = MCPStdioClient(server, nothing, nothing, nothing, 0, nothing, ReentrantLock())
        return connect!(client)
    elseif transport in (:sse, :streamable_http)
        client = MCPHTTPClient(server, transport, 0, nothing, ReentrantLock())
        return connect!(client)
    end
    throw(ArgumentError("Unsupported resolved MCP transport: $(transport)"))
end

"""
    close!(client_or_set)

Close an MCP client connection (or all connections in an `MCPConnectionSet`).
"""
function close!(client::MCPHTTPClient)
    client.tools_cache = nothing
    return nothing
end

function close!(client::MCPStdioClient)
    client.proc_stdin === nothing || (try
        close(client.proc_stdin)
    catch _
    end)
    client.proc_stdout === nothing || (try
        close(client.proc_stdout)
    catch _
    end)
    if client.proc !== nothing && process_running(client.proc)
        try
            kill(client.proc)
        catch _
        end
    end
    client.proc = nothing
    client.proc_stdin = nothing
    client.proc_stdout = nothing
    client.tools_cache = nothing
    return nothing
end

function close!(set::MCPConnectionSet)
    for client in set.clients
        try
            close!(client)
        catch _
        end
    end
    return nothing
end

"""
    list_tools(client::AbstractMCPClient) -> Vector{Dict{String,Any}}

Fetch the list of available tools from the MCP server (cached when `cache_tools=true`).
"""
function list_tools(client::AbstractMCPClient)
    if client.server.cache_tools && client.tools_cache !== nothing
        return client.tools_cache
    end

    lock(client.lock) do
        if client.server.cache_tools && client.tools_cache !== nothing
            return client.tools_cache
        end

        resp = _rpc(
            client,
            "tools/list",
            Dict{String,Any}();
            timeout_s=client.server.request_timeout_s,
        )
        result = _to_plain(get(resp, "result", Dict{String,Any}()))
        raw_tools = if result isa AbstractDict
            get(result, "tools", Any[])
        else
            Any[]
        end

        tools = Dict{String,Any}[]
        if raw_tools isa AbstractVector
            for raw in raw_tools
                plain = _to_plain(raw)
                plain isa AbstractDict || continue
                push!(tools, Dict{String,Any}(String(k) => v for (k, v) in pairs(plain)))
            end
        end

        client.tools_cache = tools
        return tools
    end
end

function _render_tool_result(result)
    plain = _to_plain(result)
    if plain isa AbstractDict
        content = get(plain, "content", Any[])
        if content isa AbstractVector
            parts = String[]
            for raw in content
                block = _to_plain(raw)
                if block isa AbstractDict
                    block_type = lowercase(String(get(block, "type", "")))
                    if block_type == "text"
                        push!(parts, String(get(block, "text", "")))
                    elseif block_type == "image"
                        mime = String(get(block, "mimeType", "image"))
                        push!(parts, "[image: $(mime)]")
                    else
                        push!(parts, String(JSON3.write(block)))
                    end
                else
                    push!(parts, string(block))
                end
            end
            isempty(parts) || return join(parts, "\n")
        end
    end
    return "(no output)"
end

"""
    call_tool(client, name, arguments; timeout_s) -> String

Invoke a tool on the MCP server by name and return the rendered text result.
"""
function call_tool(
    client::AbstractMCPClient,
    name::AbstractString,
    arguments::Dict{String,Any};
    timeout_s::Real=client.server.tool_timeout_s,
)
    lock(client.lock) do
        resp = _rpc(
            client,
            "tools/call",
            Dict{String,Any}(
                "name" => String(name),
                "arguments" => _to_plain(arguments),
            );
            timeout_s=Float64(timeout_s),
        )
        result = get(resp, "result", Dict{String,Any}())
        return _render_tool_result(result)
    end
end

function _schema_from_tool_descriptor(tool::AbstractDict)
    fallback = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(),
    )
    schema = get(tool, "inputSchema", fallback)
    plain = _to_plain(schema)
    plain isa AbstractDict || return fallback
    out = Dict{String,Any}(String(k) => v for (k, v) in pairs(plain))
    get(out, "type", "object") == "object" || return fallback
    props = get(out, "properties", Dict{String,Any}())
    props isa AbstractDict || (out["properties"] = Dict{String,Any}())
    return out
end

_is_timeout_error(err) = occursin("timeout", lowercase(sprint(showerror, err)))

"""
    register_mcp_tools!(registry, client; server_name, enabled_tools, tool_timeout_s, replace) -> Vector{String}

Discover tools from an MCP client and register them in the `ToolRegistry` under
namespaced names. Returns the list of registered tool names.
"""
function register_mcp_tools!(
    registry::ToolRegistry,
    client::AbstractMCPClient;
    server_name::Union{Nothing,AbstractString}=nothing,
    enabled_tools::Union{Nothing,AbstractVector}=nothing,
    tool_timeout_s::Union{Nothing,Real}=nothing,
    replace::Bool=true,
)
    sname = server_name === nothing ? client.server.name : String(server_name)
    enabled = enabled_tools === nothing ? client.server.enabled_tools : String[String(v) for v in enabled_tools]
    enabled_set = Set(enabled)
    allow_all = "*" in enabled_set
    matched = Set{String}()

    timeout_val = Float64(tool_timeout_s === nothing ? client.server.tool_timeout_s : tool_timeout_s)
    timeout_val > 0 || throw(ArgumentError("tool_timeout_s must be > 0"))

    registered = String[]
    for descriptor in list_tools(client)
        raw_name = String(get(descriptor, "name", ""))
        isempty(raw_name) && continue
        wrapped_name = mcp_wrapped_tool_name(sname, raw_name)

        if !allow_all
            if !(raw_name in enabled_set || wrapped_name in enabled_set)
                continue
            end
            raw_name in enabled_set && push!(matched, raw_name)
            wrapped_name in enabled_set && push!(matched, wrapped_name)
        end

        description = get(descriptor, "description", nothing)
        desc = description === nothing ? nothing : String(description)
        schema = _schema_from_tool_descriptor(descriptor)

        tool = ToolDef(
            name=wrapped_name,
            description=desc,
            parameters=schema,
            execute=function(args::Dict{String,Any})
                try
                    call_tool(client, raw_name, args; timeout_s=timeout_val)
                catch e
                    if _is_timeout_error(e)
                        return "(MCP tool call timed out after $(timeout_val)s)"
                    end
                    return "(MCP tool call failed: $(sprint(showerror, e)))"
                end
            end,
        )
        register_tool!(registry, tool; replace=replace)
        push!(registered, wrapped_name)
    end

    if !allow_all && !isempty(enabled_set)
        unmatched = sort!(collect(setdiff(enabled_set, matched)))
        isempty(unmatched) || @warn "MCP enabled_tools entries not found" server=sname enabled_tools=unmatched
    end

    return registered
end

"""
    connect_mcp_servers!(registry, servers; replace=true) -> MCPConnectionSet

Connect to each `MCPServer`, register its tools in the `ToolRegistry`, and return
an [`MCPConnectionSet`](@ref) with live clients and any connection failures.
"""
function connect_mcp_servers!(
    registry::ToolRegistry,
    servers::Vector{MCPServer};
    replace::Bool=true,
    connect_fn::Function=connect,
)
    clients = AbstractMCPClient[]
    registered_tools = Dict{String,Vector{String}}()
    failed_servers = Dict{String,String}()

    for server in servers
        client = nothing
        try
            client = connect_fn(server)
            names = register_mcp_tools!(
                registry,
                client;
                server_name=server.name,
                enabled_tools=server.enabled_tools,
                tool_timeout_s=server.tool_timeout_s,
                replace=replace,
            )
            registered_tools[server.name] = names
            push!(clients, client)
        catch e
            failed_servers[server.name] = sprint(showerror, e)
            client === nothing || (try
                close!(client)
            catch _
            end)
        end
    end

    return MCPConnectionSet(clients, registered_tools, failed_servers)
end

end
