if !KRILL_FAST_TESTS
    # --- In-process mock MCP client (no subprocess) ---
    const _MCPMod = Krill.Core.MCP

    mutable struct MockMCPClient <: _MCPMod.AbstractMCPClient
        server::_MCPMod.MCPServer
        tools_cache::Union{Nothing,Vector{Dict{String,Any}}}
        lock::ReentrantLock
        tools::Vector{Dict{String,Any}}
        handler::Function  # (name, args) -> content_text
        closed::Ref{Bool}
    end

    function _make_mock_server(;
        name::String = "stub",
        enabled_tools::Vector{String} = String["*"],
        tool_timeout_s::Float64 = 1.0,
    )
        _MCPMod.MCPServer(
            name = name,
            command = "mock",
            args = String[],
            enabled_tools = enabled_tools,
            tool_timeout_s = tool_timeout_s,
            request_timeout_s = 5.0,
        )
    end

    const _MOCK_TOOLS = Dict{String,Any}[
        Dict{String,Any}(
            "name" => "echo_tool",
            "description" => "Echo text",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}("message" => Dict{String,Any}("type" => "string")),
                "required" => Any["message"],
            ),
        ),
        Dict{String,Any}(
            "name" => "add_tool",
            "description" => "Add two integers",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "a" => Dict{String,Any}("type" => "integer"),
                    "b" => Dict{String,Any}("type" => "integer"),
                ),
                "required" => Any["a", "b"],
            ),
        ),
        Dict{String,Any}(
            "name" => "slow_tool",
            "description" => "Sleep before replying",
            "inputSchema" => Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}("seconds" => Dict{String,Any}("type" => "number")),
            ),
        ),
    ]

    function _mock_handler(name::AbstractString, args::Dict{String,Any})
        if name == "echo_tool"
            msg = get(args, "message", "(missing)")
            return "echo: $msg"
        elseif name == "add_tool"
            a = Int(get(args, "a", 0))
            b = Int(get(args, "b", 0))
            return string(a + b)
        elseif name == "slow_tool"
            seconds = Float64(get(args, "seconds", 1.0))
            sleep(seconds)
            return "slow done"
        end
        return "unknown tool"
    end

    function _make_mock_client(;
        name::String = "stub",
        enabled_tools::Vector{String} = String["*"],
        tool_timeout_s::Float64 = 1.0,
        tools::Vector{Dict{String,Any}} = copy(_MOCK_TOOLS),
        handler::Function = _mock_handler,
    )
        server = _make_mock_server(; name, enabled_tools, tool_timeout_s)
        return MockMCPClient(server, nothing, ReentrantLock(), tools, handler, Ref(false))
    end

    # _rpc dispatch for MockMCPClient — runs in-process
    function _MCPMod._rpc(client::MockMCPClient, method::String, params = nothing; timeout_s::Real = 5.0)
        if method == "initialize"
            return Dict{String,Any}(
                "id" => 1,
                "result" => Dict{String,Any}(
                    "protocolVersion" => "2024-11-05",
                    "capabilities" => Dict{String,Any}(),
                    "serverInfo" => Dict{String,Any}("name" => client.server.name, "version" => "0.1"),
                ),
            )
        elseif method == "tools/list"
            return Dict{String,Any}(
                "id" => 2,
                "result" => Dict{String,Any}("tools" => client.tools),
            )
        elseif method == "tools/call"
            tool_name = params isa AbstractDict ? String(get(params, "name", "")) : ""
            tool_args =
                params isa AbstractDict ?
                Dict{String,Any}(String(k) => v for (k, v) in get(params, "arguments", Dict{String,Any}())) :
                Dict{String,Any}()

            result_ch = Channel{String}(1)
            @async begin
                text = client.handler(tool_name, tool_args)
                put!(result_ch, text)
            end
            deadline = time() + Float64(timeout_s)
            while !isready(result_ch) && time() < deadline
                sleep(0.01)
            end
            if !isready(result_ch)
                throw(ErrorException("MCP timeout ($(timeout_s)s) waiting for response to tools/call"))
            end
            text = take!(result_ch)
            return Dict{String,Any}(
                "id" => 3,
                "result" => Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "text", "text" => text)]),
            )
        end
        return Dict{String,Any}("id" => 0, "result" => Dict{String,Any}())
    end

    function _MCPMod.connect!(client::MockMCPClient)
        return client
    end

    function _MCPMod.close!(client::MockMCPClient)
        client.closed[] = true
        client.tools_cache = nothing
        return nothing
    end

    # connect_fn for use with connect_mcp_servers! / RuntimeState
    function _mock_mcp_connect(server::_MCPMod.MCPServer)
        client = MockMCPClient(server, nothing, ReentrantLock(), copy(_MOCK_TOOLS), _mock_handler, Ref(false))
        _MCPMod.connect!(client)
        return client
    end

    # connect_fn that fails for a specific server name
    function _make_partial_mock_connect(fail_name::String)
        return function (server::_MCPMod.MCPServer)
            if server.name == fail_name
                throw(ErrorException("connection failed for $(server.name)"))
            end
            return _mock_mcp_connect(server)
        end
    end

    @testset "Krill.jl MCP module" begin
        MCPMod = _MCPMod

        @testset "HTTP readtimeout normalization" begin
            @test MCPMod._http_readtimeout(0.1) == 1
            @test MCPMod._http_readtimeout(1.0) == 1
            @test MCPMod._http_readtimeout(1.2) == 2
            @test MCPMod._http_readtimeout(30.0) == 30
        end

        @testset "MCPServer constructor validation" begin
            # empty name is rejected
            @test_throws ArgumentError MCPMod.MCPServer(name = "", command = "cmd")
            # whitespace-only name is rejected
            @test_throws ArgumentError MCPMod.MCPServer(name = "   ", command = "cmd")
            # invalid transport
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", transport = :bogus, command = "cmd")
            # stdio without command
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", transport = :stdio)
            # stdio with url
            @test_throws ArgumentError MCPMod.MCPServer(
                name = "s",
                transport = :stdio,
                command = "cmd",
                url = "http://x",
            )
            # HTTP without url
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", transport = :sse)
            # HTTP with command
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", transport = :sse, url = "http://x", command = "cmd")
            # auto with both command and url
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", command = "cmd", url = "http://x")
            # auto with neither
            @test_throws ArgumentError MCPMod.MCPServer(name = "s")
            # non-positive timeout
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", command = "cmd", request_timeout_s = 0.0)
            @test_throws ArgumentError MCPMod.MCPServer(name = "s", command = "cmd", tool_timeout_s = -1.0)
            # valid stdio construction (transport=:auto stored; resolved to :stdio at connect time)
            s = MCPMod.MCPServer(name = "myserver", command = "echo", args = ["hi"])
            @test s.name == "myserver"
            @test s.transport == :auto
            @test s.command == "echo"
            @test s.args == ["hi"]
            # explicit transport=:stdio is stored as-is
            s2 = MCPMod.MCPServer(name = "myserver2", transport = :stdio, command = "echo")
            @test s2.transport == :stdio
            # valid HTTP construction (SSE)
            h = MCPMod.MCPServer(name = "h", url = "http://host/sse")
            @test h.transport == :auto
            @test h.url == "http://host/sse"
        end

        @testset "mcp_wrapped_tool_name" begin
            @test MCPMod.mcp_wrapped_tool_name("myserver", "mytool") == "mcp_myserver_mytool"
            # special chars are replaced with underscores
            @test MCPMod.mcp_wrapped_tool_name("my-server", "my.tool") == "mcp_my_server_my_tool"
            # empty segments fall back to defaults
            @test MCPMod.mcp_wrapped_tool_name("", "") == "mcp_server_tool"
            # spaces are trimmed before sanitization
            @test MCPMod.mcp_wrapped_tool_name("  s  ", "t") == "mcp_s_t"
        end

        @testset "_normalize_transport" begin
            @test MCPMod._normalize_transport(:auto) == :auto
            @test MCPMod._normalize_transport("auto") == :auto
            @test MCPMod._normalize_transport(:stdio) == :stdio
            @test MCPMod._normalize_transport("stdio") == :stdio
            @test MCPMod._normalize_transport(:sse) == :sse
            @test MCPMod._normalize_transport("SSE") == :sse
            @test MCPMod._normalize_transport("streamable_http") == :streamable_http
            @test MCPMod._normalize_transport("http") == :streamable_http
            @test MCPMod._normalize_transport("post") == :streamable_http
            @test_throws ArgumentError MCPMod._normalize_transport(:unknown)
        end

        @testset "_resolved_transport" begin
            # explicit transports pass through
            s_stdio = MCPMod.MCPServer(name = "s", transport = :stdio, command = "cmd")
            @test MCPMod._resolved_transport(s_stdio) == :stdio

            # auto + command → stdio
            s_auto_cmd = MCPMod.MCPServer(name = "s", command = "cmd")
            @test MCPMod._resolved_transport(s_auto_cmd) == :stdio

            # auto + url ending in /sse → :sse
            s_sse = MCPMod.MCPServer(name = "s", url = "http://host/sse")
            @test MCPMod._resolved_transport(s_sse) == :sse

            # auto + url not ending in /sse → :streamable_http
            s_http = MCPMod.MCPServer(name = "s", url = "http://host/mcp")
            @test MCPMod._resolved_transport(s_http) == :streamable_http
        end

        @testset "list_tools caches results" begin
            client = _make_mock_client()
            tools1 = MCPMod.list_tools(client)
            @test length(tools1) == 3
            # mutate the underlying list to verify the cache is returned, not re-fetched
            empty!(client.tools)
            tools2 = MCPMod.list_tools(client)
            @test tools2 === tools1  # same object from cache
        end

        @testset "list_tools skips cache when cache_tools=false" begin
            server = MCPMod.MCPServer(name = "s", command = "mock", cache_tools = false)
            local_tools = copy(_MOCK_TOOLS)
            client = MockMCPClient(server, nothing, ReentrantLock(), local_tools, _mock_handler, Ref(false))
            tools1 = MCPMod.list_tools(client)
            @test length(tools1) == 3
            # remove a tool from the backing list — cache disabled so next call re-fetches
            pop!(local_tools)
            tools2 = MCPMod.list_tools(client)
            @test length(tools2) == 2
        end

        @testset "call_tool returns rendered text" begin
            client = _make_mock_client()
            MCPMod.connect!(client)
            result = MCPMod.call_tool(client, "echo_tool", Dict{String,Any}("message" => "world"))
            @test result == "echo: world"

            sum_result = MCPMod.call_tool(client, "add_tool", Dict{String,Any}("a" => 4, "b" => 6))
            @test sum_result == "10"
        end

        @testset "_render_tool_result" begin
            # text content
            r_text = Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "text", "text" => "hello")])
            @test MCPMod._render_tool_result(r_text) == "hello"

            # multiple text blocks joined with newline
            r_multi = Dict{String,Any}(
                "content" => Any[
                    Dict{String,Any}("type" => "text", "text" => "a"),
                    Dict{String,Any}("type" => "text", "text" => "b"),
                ],
            )
            @test MCPMod._render_tool_result(r_multi) == "a\nb"

            # image block → placeholder
            r_img = Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "image", "mimeType" => "image/png")])
            @test MCPMod._render_tool_result(r_img) == "[image: image/png]"

            # unknown block type → JSON
            r_unk = Dict{String,Any}("content" => Any[Dict{String,Any}("type" => "audio", "data" => "x")])
            rendered_unk = MCPMod._render_tool_result(r_unk)
            @test occursin("audio", rendered_unk)

            # empty content list → "(no output)"
            r_empty = Dict{String,Any}("content" => Any[])
            @test MCPMod._render_tool_result(r_empty) == "(no output)"

            # non-dict result → "(no output)"
            @test MCPMod._render_tool_result("raw string") == "(no output)"
            @test MCPMod._render_tool_result(42) == "(no output)"
        end

        @testset "namespacing + enabled_tools (raw name)" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "stub", enabled_tools = String["echo_tool"])
            set = MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[server]; connect_fn = _mock_mcp_connect)
            try
                @test isempty(set.failed_servers)
                @test haskey(set.registered_tools, "stub")
                @test "mcp_stub_echo_tool" in set.registered_tools["stub"]
                @test has_tool(registry, "mcp_stub_echo_tool")
                @test !has_tool(registry, "mcp_stub_add_tool")

                result = dispatch_tool(registry, "mcp_stub_echo_tool", Dict("message" => "hello"))
                @test result == "echo: hello"
            finally
                MCPMod.close!(set)
            end
        end

        @testset "enabled_tools supports wrapped names" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "stub", enabled_tools = String["mcp_stub_add_tool"])
            set = MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[server]; connect_fn = _mock_mcp_connect)
            try
                @test isempty(set.failed_servers)
                @test has_tool(registry, "mcp_stub_add_tool")
                @test !has_tool(registry, "mcp_stub_echo_tool")

                sum_result = dispatch_tool(registry, "mcp_stub_add_tool", Dict("a" => 2, "b" => 3))
                @test sum_result == "5"
            finally
                MCPMod.close!(set)
            end
        end

        @testset "enabled_tools=[] registers no tools" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "stub", enabled_tools = String[])
            set = MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[server]; connect_fn = _mock_mcp_connect)
            try
                @test isempty(set.failed_servers)
                @test isempty(get(set.registered_tools, "stub", String[]))
                @test !has_tool(registry, "mcp_stub_echo_tool")
                @test !has_tool(registry, "mcp_stub_add_tool")
            finally
                MCPMod.close!(set)
            end
        end

        @testset "enabled_tools wildcard registers all tools" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "stub", enabled_tools = String["*"])
            set = MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[server]; connect_fn = _mock_mcp_connect)
            try
                @test isempty(set.failed_servers)
                @test has_tool(registry, "mcp_stub_echo_tool")
                @test has_tool(registry, "mcp_stub_add_tool")
                @test has_tool(registry, "mcp_stub_slow_tool")
            finally
                MCPMod.close!(set)
            end
        end

        @testset "unmatched enabled_tools entry emits warning" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "stub", enabled_tools = String["nonexistent_tool"])
            set = @test_logs (:warn, r"MCP enabled_tools entries not found"i) match_mode=:any begin
                MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[server]; connect_fn = _mock_mcp_connect)
            end
            try
                @test isempty(get(set.registered_tools, "stub", String[]))
            finally
                MCPMod.close!(set)
            end
        end

        @testset "per-tool timeout returns timeout message" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "stub", enabled_tools = String["slow_tool"], tool_timeout_s = 0.1)
            set = MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[server]; connect_fn = _mock_mcp_connect)
            try
                @test isempty(set.failed_servers)
                @test has_tool(registry, "mcp_stub_slow_tool")

                result = dispatch_tool(registry, "mcp_stub_slow_tool", Dict("seconds" => 0.5))
                @test occursin("timed out", lowercase(result))
            finally
                MCPMod.close!(set)
            end
        end

        @testset "partial connect failure does not block healthy servers" begin
            registry = ToolRegistry()
            bad = _make_mock_server(name = "bad", enabled_tools = String["*"])
            good = _make_mock_server(name = "good", enabled_tools = String["echo_tool"])

            connect_fn = _make_partial_mock_connect("bad")
            set = MCPMod.connect_mcp_servers!(registry, MCPMod.MCPServer[bad, good]; connect_fn = connect_fn)
            try
                @test haskey(set.failed_servers, "bad")
                @test !isempty(set.failed_servers["bad"])  # failure message is non-empty
                @test haskey(set.registered_tools, "good")
                @test has_tool(registry, "mcp_good_echo_tool")
                @test !has_tool(registry, "mcp_bad_echo_tool")
            finally
                MCPMod.close!(set)
            end
        end

        @testset "close!(MCPConnectionSet) closes all clients" begin
            client1 = _make_mock_client(name = "s1")
            client2 = _make_mock_client(name = "s2")
            set = MCPMod.MCPConnectionSet(
                MCPMod.AbstractMCPClient[client1, client2],
                Dict{String,Vector{String}}(),
                Dict{String,String}(),
            )
            @test !client1.closed[]
            @test !client2.closed[]
            MCPMod.close!(set)
            @test client1.closed[]
            @test client2.closed[]
        end

        @testset "RuntimeState wires MCP tools and closes when shutdown before start" begin
            registry = ToolRegistry()
            server = _make_mock_server(name = "runtime", enabled_tools = String["echo_tool"])

            mock_request = function (method, url, headers, body)
                if occursin("getUpdates", url)
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
                elseif occursin("sendMessage", url)
                    return HTTP.Response(200, JSON3.write(Dict(
                        "ok" => true,
                        "result" => Dict("message_id" => 1),
                    )))
                end
                return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
            end

            client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)
            provider = OpenAIProvider(api_key = "test_key")
            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                llm_provider = provider,
                llm_tool_registry = registry,
                llm_mcp_servers = MCPMod.MCPServer[server],
                llm_mcp_connect_fn = _mock_mcp_connect,
                workspace = mktempdir(),
            )

            @test runtime.mcp_connections !== nothing
            @test has_tool(registry, "mcp_runtime_echo_tool")
            @test status(runtime)["mcp_connected_servers"] == 1

            shutdown!(runtime)
            @test runtime.mcp_connections === nothing
        end

        @testset "RuntimeState exposes MCP tool schemas to LLM payload" begin
            captured_payload = Ref{Any}(nothing)
            server = _make_mock_server(name = "runtime", enabled_tools = String["echo_tool"])

            mock_telegram_request = function (method, url, headers, body)
                if occursin("getUpdates", url)
                    return HTTP.Response(
                        200,
                        JSON3.write(
                            Dict(
                                "ok" => true,
                                "result" => Any[
                                    Dict(
                                    "update_id" => 7100,
                                    "message" => Dict(
                                        "message_id" => 1,
                                        "text" => "hello",
                                        "chat" => Dict("id" => 9),
                                        "from" => Dict("id" => 9),
                                    ),
                                ),
                                ],
                            ),
                        ),
                    )
                elseif occursin("sendChatAction", url)
                    return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => true)))
                elseif occursin("sendMessage", url)
                    return HTTP.Response(200, JSON3.write(Dict(
                            "ok" => true,
                            "result" => Dict("message_id" => 1001),
                        )))
                end
                return HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
            end

            mock_openai_request = function (method, url, headers, body)
                payload = JSON3.read(String(body))
                captured_payload[] = payload
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "id" => "resp_mcp_schema",
                            "output_text" => "ok",
                            "usage" => Dict("input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12),
                        ),
                    ),
                )
            end

            client = TelegramClient("token";
                base_url = "https://example.test/botTOKEN",
                request = mock_telegram_request,
            )
            provider = OpenAIProvider(
                api_key = "test-key",
                base_url = "https://example.openai.test/v1",
                request = mock_openai_request,
                max_retries = 0,
            )

            runtime = RuntimeState(TelegramChannel(client; poll_timeout = 0, poll_interval = 0.01);
                workspace = mktempdir(),
                llm_provider = provider,
                llm_enable_builtin_tools = false,
                llm_enable_builtin_skills = false,
                llm_mcp_servers = MCPMod.MCPServer[server],
                llm_mcp_connect_fn = _mock_mcp_connect,
            )

            start!(runtime)
            for _ in 1:60
                captured_payload[] !== nothing && break
                sleep(0.05)
            end
            shutdown!(runtime)

            payload = captured_payload[]
            @test payload !== nothing
            if payload !== nothing
                @test haskey(payload, :tools)
                if haskey(payload, :tools)
                    tool_names = String[]
                    for item in payload[:tools]
                        haskey(item, :name) && push!(tool_names, String(item[:name]))
                    end
                    @test "mcp_runtime_echo_tool" in tool_names
                end
            end
        end

        @testset "RuntimeState rejects MCP config without llm_provider" begin
            client = TelegramClient(
                "token";
                base_url = "https://example.test/botTOKEN",
                request = (args...)->HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[]))),
            )
            server = _make_mock_server(name = "runtime2", enabled_tools = String["*"])
            @test_throws ArgumentError RuntimeState(TelegramChannel(client);
                llm_mcp_servers = MCPMod.MCPServer[server],
                llm_mcp_connect_fn = _mock_mcp_connect,
                workspace = mktempdir(),
            )
        end
    end
end  # !KRILL_FAST_TESTS (MCP)
