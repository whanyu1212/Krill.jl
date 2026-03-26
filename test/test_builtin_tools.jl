@testset "Krill.jl Tool registry and macro" begin
    @testset "ToolRegistry dispatch validates and coerces args" begin
        tool = ToolDef(
            name = "add",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "a" => Dict{String,Any}("type" => "integer"),
                    "b" => Dict{String,Any}("type" => "integer"),
                ),
                "required" => Any["a", "b"],
                "additionalProperties" => false,
            ),
            execute = args -> Int(args["a"]) + Int(args["b"]),
        )
        registry = ToolRegistry([tool])

        @test dispatch_tool(registry, "add", Dict("a" => "2", "b" => 3)) == 5

        err = try
            dispatch_tool(registry, "add", Dict("a" => 1, "x" => 2))
            nothing
        catch e
            e
        end
        @test err isa ToolValidationError

        err = try
            dispatch_tool(registry, "missing", Dict{String,Any}())
            nothing
        catch e
            e
        end
        @test err isa ToolNotFoundError
    end

    @testset "@tool creates ToolDef companion variable" begin
        @tool return_direct=true max_output_chars=123 function add_one(x::Int)
            "Add one to x"
            x + 1
        end

        @test add_one_tool isa ToolDef
        @test add_one_tool.name == "add_one"
        @test add_one_tool.return_direct == true
        @test add_one_tool.max_output_chars == 123
        @test add_one_tool.description == "Add one to x"
        @test dispatch_tool(ToolRegistry([add_one_tool]), "add_one", Dict("x" => "41")) == 42
    end
end

@testset "Krill.jl built-in tools" begin
    @testset "registers V1 tools with exec disabled by default" begin
        workspace = mktempdir()
        registry = ToolRegistry()
        defs = register_builtin_tools!(registry; workspace = workspace)
        names = sort([d.name for d in defs])

        @test "read_file" in names
        @test "write_file" in names
        @test "edit_file" in names
        @test "list_dir" in names
        @test "web_search" in names
        @test "web_fetch" in names
        @test "message" in names
        @test !("exec" in names)
        @test !has_tool(registry, "exec")
    end

    @testset "filesystem built-ins roundtrip through dispatch_tool" begin
        workspace = mktempdir()
        registry = ToolRegistry()
        register_builtin_tools!(registry; workspace = workspace)

        write_result = dispatch_tool(registry, "write_file", Dict(
            "path" => "notes.txt",
            "content" => "alpha\nbeta",
        ))
        @test occursin("Successfully wrote", write_result)

        read_result = dispatch_tool(registry, "read_file", Dict("path" => "notes.txt"))
        @test occursin("1| alpha", read_result)
        @test occursin("2| beta", read_result)

        edit_result = dispatch_tool(
            registry,
            "edit_file",
            Dict(
                "path" => "notes.txt",
                "old_text" => "alpha",
                "new_text" => "gamma",
            ),
        )
        @test occursin("Successfully edited", edit_result)

        read_after = dispatch_tool(registry, "read_file", Dict("path" => "notes.txt"))
        @test occursin("gamma", read_after)

        list_result = dispatch_tool(registry, "list_dir", Dict("path" => "."))
        @test occursin("notes.txt", list_result)
    end

    @testset "message tool sends via callback" begin
        workspace = mktempdir()
        registry = ToolRegistry()

        captured_chat_id = Ref{String}()
        captured_text = Ref{String}()
        captured_preview = Ref{Bool}(false)
        send_tool = function (chat_id, text; disable_web_page_preview = false)
            captured_chat_id[] = String(chat_id)
            captured_text[] = String(text)
            captured_preview[] = Bool(disable_web_page_preview)
            return "ok"
        end

        register_builtin_tools!(registry; workspace = workspace, send_message_fn = send_tool)

        result = dispatch_tool(
            registry,
            "message",
            Dict(
                "chat_id" => 1234,
                "text" => "hello from tool",
                "disable_web_page_preview" => true,
            ),
        )

        @test occursin("Sent message", result)
        @test captured_chat_id[] == "1234"
        @test captured_text[] == "hello from tool"
        @test captured_preview[] == true
    end

    @testset "web_fetch blocks SSRF hosts" begin
        workspace = mktempdir()
        registry = ToolRegistry()
        register_builtin_tools!(registry; workspace = workspace)

        local_result = dispatch_tool(registry, "web_fetch", Dict(
            "url" => "http://localhost:8080/foo",
        ))
        blocked_result = dispatch_tool(registry, "web_fetch", Dict(
            "url" => "ftp://example.com",
        ))
        @test startswith(local_result, "Error:")
        @test occursin("URL host is blocked for safety", local_result)
        @test startswith(blocked_result, "Error:")
        @test occursin("must use http:// or https://", blocked_result)
    end

    @testset "web_fetch can retry without certificate verification when enabled" begin
        cert_err = ErrorException("unable to get local issuer certificate")
        @test Krill.Core.BuiltinTools._is_certificate_error(cert_err)

        withenv("KRILL_WEB_FETCH_ALLOW_INSECURE" => "1") do
            calls = Ref(0)
            mock_request = function (method, url; kwargs...)
                calls[] += 1
                if get(kwargs, :require_ssl_verification, true)
                    throw(cert_err)
                end
                return HTTP.Response(200, "Fetched via insecure path")
            end

            result = Krill.Core.BuiltinTools._web_fetch_impl(
                Dict{String,Any}("url" => "https://example.com");
                request_fn = mock_request,
            )
            @test result == "Fetched via insecure path"
            @test calls[] == 2
        end

        withenv("KRILL_WEB_FETCH_ALLOW_INSECURE" => "0") do
            calls = Ref(0)
            mock_request = function (method, url; kwargs...)
                calls[] += 1
                if get(kwargs, :require_ssl_verification, true)
                    throw(cert_err)
                end
                return HTTP.Response(200, "unexpected")
            end

            result = Krill.Core.BuiltinTools._web_fetch_impl(
                Dict{String,Any}("url" => "https://example.com");
                request_fn = mock_request,
            )
            @test startswith(result, "Error: web_fetch request failed:")
            @test occursin("unable to verify certificate chain", result)
            @test calls[] == 1
        end
    end

    @testset "RuntimeState injects built-in function schemas for LLM" begin
        captured_payload = Ref{Any}(nothing)

        mock_telegram_request = function (method, url, headers, body)
            payload = JSON3.read(String(body))
            if occursin("getUpdates", url)
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "ok" => true,
                            "result" => Any[
                                Dict(
                                "update_id" => 6100,
                                "message" => Dict(
                                    "message_id" => 1,
                                    "text" => "hello",
                                    "chat" => Dict("id" => 7),
                                    "from" => Dict("id" => 7),
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
                    "result" => Dict("message_id" => 999),
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
                        "id" => "resp_builtin_tools",
                        "output_text" => "ok",
                        "usage" => Dict(
                            "input_tokens" => 10,
                            "output_tokens" => 2,
                            "total_tokens" => 12,
                        ),
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
        )

        start!(runtime)
        sleep(0.35)
        shutdown!(runtime)

        payload = captured_payload[]
        @test payload !== nothing
        @test haskey(payload, :tools)

        tool_names = String[]
        for item in payload[:tools]
            haskey(item, :name) && push!(tool_names, String(item[:name]))
        end

        @test "read_file" in tool_names
        @test "write_file" in tool_names
        @test "edit_file" in tool_names
        @test "list_dir" in tool_names
        @test "web_search" in tool_names
        @test "web_fetch" in tool_names
        @test "message" in tool_names
        @test !("exec" in tool_names)
    end
end
