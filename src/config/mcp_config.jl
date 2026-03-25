"""
    make_mcp_servers(cfg::Dict) -> Vector{MCPServer}

Parse the `[[profile.mcp]]` array from a krill.toml config dict and construct
`MCPServer` instances for each valid entry.
"""
function make_mcp_servers(cfg::Dict)
    entries = get_cfg(cfg, "profile", "mcp"; default=nothing)
    entries isa Vector || return MCPServer[]
    servers = MCPServer[]
    for e in entries
        e isa Dict || continue
        name      = get(e, "name", "")
        transport = get(e, "transport", "stdio")
        command   = get(e, "command", "")
        args      = get(e, "args", String[])
        url       = get(e, "url", "")
        isempty(name) && continue
        if transport == "stdio"
            isempty(command) && (@warn "MCP server $name missing command"; continue)
            push!(servers, MCPServer(name=name, transport=:stdio,
                command=command, args=String.(args)))
        elseif transport in ("streamable_http", "sse")
            isempty(url) && (@warn "MCP server $name missing url"; continue)
            raw_headers = get(e, "headers", Dict())
            headers = Dict{String,String}(String(k) => String(v) for (k, v) in raw_headers)
            push!(servers, MCPServer(name=name,
                transport=transport == "sse" ? :sse : :streamable_http,
                url=url, headers=headers))
        else
            @warn "MCP server $name has unknown transport" transport
        end
    end
    return servers
end
