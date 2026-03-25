@testset "Krill.jl OpenAI provider" begin
    @testset "build_context truncates oldest turns under budget" begin
        history = TurnRecord[
            TurnRecord(:user, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", uuid4(), nothing, now(UTC)),
            TurnRecord(:assistant, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", uuid4(), nothing, now(UTC)),
            TurnRecord(:user, "cccccccccccccccccccccccccccccccccccccccc", uuid4(), nothing, now(UTC)),
            TurnRecord(:assistant, "dddddddddddddddddddddddddddddddddddddddd", uuid4(), nothing, now(UTC)),
        ]

        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:42",
            user_id="42",
            chat_id="42",
            text="now",
        )

        ctx = build_context("sys", history, msg; max_context_tokens=30)
        @test ctx.instructions == "sys"
        @test length(ctx.messages) < 5
        @test ctx.messages[end]["role"] == "user"
    end

    @testset "build_context encodes assistant history as output_text" begin
        history = TurnRecord[
            TurnRecord(:user, "hello", uuid4(), nothing, now(UTC)),
            TurnRecord(:assistant, "hi there", uuid4(), nothing, now(UTC)),
        ]

        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:42",
            user_id="42",
            chat_id="42",
            text="follow up",
        )

        ctx = build_context("sys", history, msg; max_context_tokens=1_000)
        @test length(ctx.messages) == 3
        @test ctx.messages[1]["content"][1]["type"] == "input_text"
        @test ctx.messages[2]["role"] == "assistant"
        @test ctx.messages[2]["content"][1]["type"] == "output_text"
        @test ctx.messages[3]["content"][1]["type"] == "input_text"
    end

    @testset "build_context appends memory section to instructions" begin
        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:42",
            user_id="42",
            chat_id="42",
            text="follow up",
        )

        ctx = build_context("sys", TurnRecord[], msg;
            max_context_tokens=1_000,
            memory_text="Preferred language: Julia.",
        )
        @test occursin("sys", String(ctx.instructions))
        @test occursin("## Session Memory", String(ctx.instructions))
        @test occursin("Preferred language: Julia.", String(ctx.instructions))

        memory_only = build_context(nothing, TurnRecord[], msg;
            max_context_tokens=1_000,
            memory_text="Timezone: Asia/Singapore.",
        )
        @test memory_only.instructions == "## Session Memory\nTimezone: Asia/Singapore."
    end

    @testset "chat_completion sends responses payload and parses usage" begin
        captured = Dict{String,Any}()

        mock_request = function(method, url, headers, body)
            captured["method"] = method
            captured["url"] = url
            captured["headers"] = headers
            captured["payload"] = JSON3.read(String(body))

            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_1",
                "output_text" => "hello from openai",
                "usage" => Dict(
                    "input_tokens" => 11,
                    "output_tokens" => 7,
                    "total_tokens" => 18,
                    "input_tokens_details" => Dict("cached_tokens" => 3),
                    "output_tokens_details" => Dict("reasoning_tokens" => 2),
                ),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            model="gpt-5.4-mini",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        response = chat_completion(
            provider,
            Any[Dict("role" => "user", "content" => Any[Dict("type" => "input_text", "text" => "hi")])];
            instructions="You are concise",
            reasoning=Dict("effort" => "low", "summary" => "auto"),
            tools=Any[
                Dict("type" => "web_search"),
                Dict("type" => "code_interpreter"),
                Dict("type" => "file_search", "vector_store_ids" => ["vs_123"]),
            ],
            include=Any["web_search_call.action.sources"],
        )

        @test captured["method"] == "POST"
        @test captured["url"] == "https://example.openai.test/v1/responses"
        @test captured["payload"][:model] == "gpt-5.4-mini"
        @test captured["payload"][:instructions] == "You are concise"
        @test captured["payload"][:reasoning][:effort] == "low"
        @test captured["payload"][:tools][1][:type] == "web_search"
        @test captured["payload"][:tools][2][:type] == "code_interpreter"
        @test captured["payload"][:tools][2][:container][:type] == "auto"
        @test response.text == "hello from openai"
        @test response.usage !== nothing
        @test response.usage.input_tokens == 11
        @test response.usage.reasoning_tokens == 2
    end

    @testset "make_llm_processor supports text image and file content parts" begin
        captured = Dict{String,Any}()

        mock_request = function(method, url, headers, body)
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_2",
                "output_text" => "multimodal ok",
                "usage" => Dict(
                    "input_tokens" => 20,
                    "output_tokens" => 5,
                    "total_tokens" => 25,
                    "input_tokens_details" => Dict("cached_tokens" => 0),
                    "output_tokens_details" => Dict("reasoning_tokens" => 1),
                ),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        processor = make_llm_processor(provider;
            tools=Any[
                Dict("type" => "web_search"),
                Dict("type" => "file_search", "vector_store_ids" => ["vs_abc"]),
                Dict(
                    "type" => "function",
                    "name" => "lookup_weather",
                    "description" => "Lookup weather by city",
                    "parameters" => Dict(
                        "type" => "object",
                        "properties" => Dict("city" => Dict("type" => "string")),
                        "required" => Any["city"],
                    ),
                ),
            ],
            reasoning=Dict("effort" => "low", "summary" => "auto"),
            include=Any["file_search_call.results"],
        )

        msg = InboundMessage(
            1,
            uuid4(),
            string(uuid4()),
            nothing,
            :telegram,
            "telegram:42",
            "42",
            "42",
            now(UTC),
            ContentPart[
                TextPart("summarize these"),
                BinaryPart("image/jpeg", "https://example.test/cat.jpg", nothing, nothing),
                BinaryPart("application/pdf", "file-abc123", nothing, "paper.pdf"),
                BinaryPart("application/octet-stream", nothing, UInt8[0x50, 0x4B], "tiny.bin"),
            ],
            Dict{String,Any}(),
            nothing,
        )

        result = processor(msg, TurnRecord[])
        @test result.text == "multimodal ok"
        @test result.format == :markdown
        @test result.usage !== nothing

        payload = captured["payload"]
        @test payload[:tools][1][:type] == "web_search"
        @test payload[:tools][2][:type] == "file_search"
        @test payload[:tools][3][:type] == "function"

        content = payload[:input][1][:content]
        content_types = [String(x[:type]) for x in content]
        @test "input_text" in content_types
        @test "input_image" in content_types
        @test "input_file" in content_types

        image_item = only(filter(x -> String(x[:type]) == "input_image", content))
        @test image_item[:image_url] == "https://example.test/cat.jpg"

        file_id_item = only(filter(x -> haskey(x, :file_id), content))
        @test file_id_item[:file_id] == "file-abc123"

        file_data_item = only(filter(x -> haskey(x, :file_data), content))
        @test file_data_item[:file_data] == "UEs="
    end

    @testset "make_llm_processor injects session memory from MemoryStore" begin
        captured = Dict{String,Any}()

        mock_request = function(method, url, headers, body)
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_2b",
                "output_text" => "ok",
                "usage" => Dict("input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        workspace = mktempdir()
        memory_store = MemoryStore(; workspace=workspace)
        save_memory!(memory_store, "telegram:42", "Known preference: concise answers.")

        processor = make_llm_processor(provider;
            system_prompt="sys",
            memory_store=memory_store,
        )

        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:42",
            user_id="42",
            chat_id="42",
            text="hey",
        )

        result = processor(msg, TurnRecord[])
        @test result.text == "ok"
        @test haskey(captured["payload"], :instructions)
        @test occursin("## Session Memory", String(captured["payload"][:instructions]))
        @test occursin("concise answers", String(captured["payload"][:instructions]))
    end

    @testset "make_llm_processor calls instructions_builder during LLM turn" begin
        captured = Dict{String,Any}()
        builder_calls = Ref(0)
        last_builder_memory = Ref{Union{Nothing,String}}(nothing)

        mock_request = function(method, url, headers, body)
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_2c",
                "output_text" => "ok",
                "usage" => Dict("input_tokens" => 9, "output_tokens" => 2, "total_tokens" => 11),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        workspace = mktempdir()
        memory_store = MemoryStore(; workspace=workspace)
        save_memory!(memory_store, "telegram:99", "Remember this user likes short replies.")

        processor = make_llm_processor(provider;
            system_prompt=session_key -> "base for $(session_key)",
            memory_store=memory_store,
            instructions_builder=(msg, base, memory) -> begin
                builder_calls[] += 1
                last_builder_memory[] = memory === nothing ? nothing : String(memory)
                return "$(base)\n\nChannel=$(String(msg.channel))\n\nMemory=$(memory)"
            end,
        )

        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:99",
            user_id="99",
            chat_id="99",
            text="hey",
        )

        result = processor(msg, TurnRecord[])
        @test result.text == "ok"
        @test builder_calls[] == 1
        @test last_builder_memory[] !== nothing
        @test occursin("short replies", String(last_builder_memory[]))
        @test haskey(captured["payload"], :instructions)
        instructions = String(captured["payload"][:instructions])
        @test occursin("base for telegram:99", instructions)
        @test occursin("Channel=telegram", instructions)
        @test occursin("Memory=Remember this user likes short replies.", instructions)
        @test !occursin("## Session Memory", instructions)
    end

    @testset "make_llm_processor executes tool calls through registry" begin
        payloads = Any[]
        call_no = Ref(0)

        mock_request = function(method, url, headers, body)
            call_no[] += 1
            payload = JSON3.read(String(body))
            push!(payloads, payload)

            if call_no[] == 1
                return HTTP.Response(200, JSON3.write(Dict(
                    "id" => "resp_1",
                    "output" => Any[
                        Dict(
                            "type" => "function_call",
                            "id" => "fc_1",
                            "call_id" => "call_1",
                            "name" => "sum_numbers",
                            "arguments" => "{\"a\":2,\"b\":3}",
                        ),
                    ],
                    "usage" => Dict(
                        "input_tokens" => 10,
                        "output_tokens" => 3,
                        "total_tokens" => 13,
                    ),
                )))
            end

            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_2",
                "output_text" => "The sum is 5",
                "usage" => Dict(
                    "input_tokens" => 12,
                    "output_tokens" => 5,
                    "total_tokens" => 17,
                ),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        sum_tool = ToolDef(
            name="sum_numbers",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "a" => Dict{String,Any}("type" => "integer"),
                    "b" => Dict{String,Any}("type" => "integer"),
                ),
                "required" => Any["a", "b"],
            ),
            execute=args -> Int(args["a"]) + Int(args["b"]),
        )

        processor = make_llm_processor(provider;
            tools=[sum_tool],
            max_tool_iterations=4,
        )

        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:42",
            user_id="42",
            chat_id="42",
            text="what is 2+3?",
        )

        result = processor(msg, TurnRecord[])
        @test result.text == "The sum is 5"
        @test haskey(result.metadata, "tool_events")
        @test length(result.metadata["tool_events"]) == 1
        @test result.metadata["tool_events"][1].call.tool_name == "sum_numbers"
        @test result.metadata["tool_events"][1].result.error === nothing

        @test length(payloads) == 2
        @test payloads[1][:tools][1][:name] == "sum_numbers"
        @test payloads[2][:previous_response_id] == "resp_1"
        @test payloads[2][:input][1][:type] == "function_call_output"
        @test payloads[2][:input][1][:call_id] == "call_1"
        @test payloads[2][:input][1][:output] == "5"
    end

    @testset "return_direct tool short-circuits tool loop" begin
        call_no = Ref(0)

        mock_request = function(method, url, headers, body)
            call_no[] += 1
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_rd",
                "output" => Any[
                    Dict(
                        "type" => "function_call",
                        "id" => "fc_rd",
                        "call_id" => "call_rd",
                        "name" => "lookup_direct",
                        "arguments" => "{\"q\":\"ok\"}",
                    ),
                ],
                "usage" => Dict(
                    "input_tokens" => 5,
                    "output_tokens" => 2,
                    "total_tokens" => 7,
                ),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        direct_tool = ToolDef(
            name="lookup_direct",
            parameters=Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "q" => Dict{String,Any}("type" => "string"),
                ),
                "required" => Any["q"],
            ),
            execute=args -> "DIRECT_" * String(args["q"]),
            return_direct=true,
        )

        processor = make_llm_processor(provider;
            tools=[direct_tool],
            max_tool_iterations=4,
        )

        msg = InboundMessage(
            channel=:telegram,
            session_key="telegram:42",
            user_id="42",
            chat_id="42",
            text="direct",
        )

        result = processor(msg, TurnRecord[])
        @test result.text == "DIRECT_ok"
        @test call_no[] == 1
    end

    @testset "tool_progress hook fires before each tool call" begin
        progress_log = Tuple{String,Dict{String,Any}}[]
        call_no = Ref(0)

        mock_request = function(method, url, headers, body)
            call_no[] += 1
            if call_no[] == 1
                return HTTP.Response(200, JSON3.write(Dict(
                    "id" => "resp_tp1",
                    "output" => Any[
                        Dict(
                            "type" => "function_call",
                            "id" => "fc_a",
                            "call_id" => "call_a",
                            "name" => "alpha",
                            "arguments" => "{\"x\":1}",
                        ),
                        Dict(
                            "type" => "function_call",
                            "id" => "fc_b",
                            "call_id" => "call_b",
                            "name" => "beta",
                            "arguments" => "{\"y\":2}",
                        ),
                    ],
                    "usage" => Dict("input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7),
                )))
            end
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_tp2",
                "output_text" => "done",
                "usage" => Dict("input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        registry = ToolRegistry()
        register_tool!(registry, ToolDef(
            name="alpha",
            parameters=Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}("x" => Dict{String,Any}("type" => "integer"))),
            execute=args -> "alpha_$(args["x"])",
        ))
        register_tool!(registry, ToolDef(
            name="beta",
            parameters=Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}("y" => Dict{String,Any}("type" => "integer"))),
            execute=args -> "beta_$(args["y"])",
        ))

        processor = make_llm_processor(provider;
            tools=tools_schema(registry),
            tool_registry=registry,
            max_tool_iterations=4,
            tool_progress=(msg, tool_name, arguments) -> push!(progress_log, (tool_name, arguments)),
        )

        msg = InboundMessage(
            channel=:telegram, session_key="telegram:tp", user_id="1", chat_id="1", text="go",
        )
        result = processor(msg, TurnRecord[])
        @test result.text == "done"

        # Progress fired once per tool call, in order
        @test length(progress_log) == 2
        @test progress_log[1][1] == "alpha"
        @test progress_log[1][2]["x"] == 1
        @test progress_log[2][1] == "beta"
        @test progress_log[2][2]["y"] == 2
    end

    @testset "tool_progress exception does not crash tool execution" begin
        call_no = Ref(0)

        mock_request = function(method, url, headers, body)
            call_no[] += 1
            if call_no[] == 1
                return HTTP.Response(200, JSON3.write(Dict(
                    "id" => "resp_tpe1",
                    "output" => Any[
                        Dict(
                            "type" => "function_call",
                            "id" => "fc_err",
                            "call_id" => "call_err",
                            "name" => "greet",
                            "arguments" => "{\"name\":\"Alice\"}",
                        ),
                    ],
                    "usage" => Dict("input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7),
                )))
            end
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_tpe2",
                "output_text" => "greeted",
                "usage" => Dict("input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        registry = ToolRegistry()
        register_tool!(registry, ToolDef(
            name="greet",
            parameters=Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}("name" => Dict{String,Any}("type" => "string"))),
            execute=args -> "Hello $(args["name"])",
        ))

        processor = make_llm_processor(provider;
            tools=tools_schema(registry),
            tool_registry=registry,
            tool_progress=(msg, tool_name, arguments) -> error("progress hook exploded"),
        )

        msg = InboundMessage(
            channel=:telegram, session_key="telegram:tpe", user_id="1", chat_id="1", text="greet Alice",
        )

        # Should not throw — progress error is swallowed
        result = processor(msg, TurnRecord[])
        @test result.text == "greeted"
        @test length(result.metadata["tool_events"]) == 1
        @test result.metadata["tool_events"][1].result.result == "Hello Alice"
    end
end

@testset "Krill.jl HTML-to-markdown conversion" begin
    html_to_md = Krill.Core.BuiltinTools._html_to_markdown
    decode_entities = Krill.Core.BuiltinTools._decode_html_entities

    @testset "strips script, style, noscript tags" begin
        html = """<p>Hello</p><script>alert('xss')</script><style>body{}</style><noscript>Enable JS</noscript><p>world</p>"""
        md = html_to_md(html)
        @test !occursin("alert", md)
        @test !occursin("body{}", md)
        @test !occursin("Enable JS", md)
        @test occursin("Hello", md)
        @test occursin("world", md)
    end

    @testset "converts headings to markdown" begin
        @test occursin("# Title", html_to_md("<h1>Title</h1>"))
        @test occursin("## Sub", html_to_md("<h2>Sub</h2>"))
        @test occursin("### Third", html_to_md("<h3>Third</h3>"))
        @test occursin("#### Fourth", html_to_md("<h4>Fourth</h4>"))
        @test occursin("##### Fifth", html_to_md("<h5>Fifth</h5>"))
        @test occursin("###### Sixth", html_to_md("<h6>Sixth</h6>"))
    end

    @testset "converts links to markdown" begin
        md = html_to_md("""<a href="https://example.com">Click</a>""")
        @test occursin("[Click](https://example.com)", md)
    end

    @testset "converts list items" begin
        md = html_to_md("<ul><li>First</li><li>Second</li></ul>")
        @test occursin("- First", md)
        @test occursin("- Second", md)
    end

    @testset "strips remaining HTML tags" begin
        md = html_to_md("<div><span class=\"x\">Text</span></div>")
        @test !occursin("<", md)
        @test occursin("Text", md)
    end

    @testset "decodes HTML entities" begin
        @test decode_entities("&amp;") == "&"
        @test decode_entities("&lt;") == "<"
        @test decode_entities("&gt;") == ">"
        @test decode_entities("&quot;") == "\""
        @test decode_entities("&#39;") == "'"
        @test decode_entities("&nbsp;") == " "
        md = html_to_md("<p>A &amp; B &lt; C</p>")
        @test occursin("A & B < C", md)
    end

    @testset "handles empty and plain text input" begin
        @test html_to_md("") == ""
        @test html_to_md("plain text") == "plain text"
    end
end

