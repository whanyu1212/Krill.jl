@testset "Krill.jl Gemini OpenAI compatibility provider" begin
    @testset "chat_completion maps responses-style input to chat completions payload" begin
        captured = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            captured["method"] = method
            captured["url"] = url
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "id" => "chatcmpl_1",
                        "choices" => Any[
                            Dict(
                            "index" => 0,
                            "message" => Dict("role" => "assistant", "content" => "hi from gemini"),
                        ),
                        ],
                        "usage" => Dict(
                            "prompt_tokens" => 15,
                            "completion_tokens" => 6,
                            "total_tokens" => 21,
                            "completion_tokens_details" => Dict("reasoning_tokens" => 2),
                        ),
                    ),
                ),
            )
        end

        provider = GeminiOpenAICompatProvider(
            api_key = "gemini-key",
            base_url = "https://example.gemini.test/v1beta/openai",
            model = "gemini-3-flash-preview",
            request = mock_request,
            max_retries = 0,
        )

        input = Any[
            Dict(
            "role" => "user",
            "content" => Any[
                Dict("type" => "input_text", "text" => "hello"),
                Dict("type" => "input_image", "image_url" => "https://example.test/cat.jpg"),
                Dict("type" => "input_file", "file_id" => "file-abc"),
            ],
        ),
        ]

        response = chat_completion(
            provider,
            input;
            instructions = "You are concise",
            reasoning = Dict("effort" => "low"),
            tools = Any[Dict("type" => "function", "name" => "foo", "parameters" => Dict("type" => "object"))],
            stream = true,
        )

        @test captured["method"] == "POST"
        @test captured["url"] == "https://example.gemini.test/v1beta/openai/chat/completions"
        @test captured["payload"][:model] == "gemini-3-flash-preview"
        @test captured["payload"][:reasoning_effort] == "low"
        @test captured["payload"][:tools][1][:type] == "function"
        @test captured["payload"][:messages][1][:role] == "system"
        @test captured["payload"][:messages][2][:role] == "user"

        parts = captured["payload"][:messages][2][:content]
        @test parts[1][:type] == "text"
        @test parts[2][:type] == "image_url"
        @test parts[2][:image_url][:url] == "https://example.test/cat.jpg"
        @test parts[3][:type] == "text"
        @test occursin("[file_id]", String(parts[3][:text]))

        @test response.text == "hi from gemini"
        @test response.usage !== nothing
        @test response.usage.input_tokens == 15
        @test response.usage.reasoning_tokens == 2
    end
end

@testset "Krill.jl Gemini native provider" begin
    @testset "chat_completion maps responses-style input to generateContent payload" begin
        captured = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            captured["method"] = method
            captured["url"] = url
            captured["headers"] = headers
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "candidates" => Any[
                            Dict(
                            "content" => Dict(
                                "role" => "model",
                                "parts" => Any[
                                    Dict("text" => "hi"),
                                    Dict("text" => "from native gemini"),
                                ],
                            ),
                        ),
                        ],
                        "usageMetadata" => Dict(
                            "promptTokenCount" => 18,
                            "candidatesTokenCount" => 7,
                            "totalTokenCount" => 25,
                            "thoughtsTokenCount" => 2,
                            "cachedContentTokenCount" => 1,
                        ),
                    ),
                ),
            )
        end

        provider = GeminiProvider(
            api_key = "gemini-key",
            base_url = "https://example.gemini.test/v1beta",
            model = "gemini-3-flash-preview",
            request = mock_request,
            max_retries = 0,
        )

        input = Any[
            Dict(
            "role" => "user",
            "content" => Any[
                Dict("type" => "input_text", "text" => "hello"),
                Dict("type" => "input_image", "mime_type" => "image/png", "image_url" => "data:image/png;base64,AA=="),
                Dict(
                    "type" => "input_file",
                    "mime_type" => "application/pdf",
                    "file_data" => "UEs=",
                    "filename" => "doc.pdf",
                ),
                Dict(
                    "type" => "input_file",
                    "mime_type" => "application/pdf",
                    "file_url" => "https://example.test/doc.pdf",
                ),
            ],
        ),
        ]

        response = chat_completion(
            provider,
            input;
            instructions = "You are concise",
            reasoning = Dict("effort" => "low", "includeThoughts" => true),
            tools = Any[
                Dict("type" => "web_search"),
                Dict("type" => "code_interpreter"),
                Dict("type" => "url_context"),
                Dict("type" => "google_maps"),
                Dict("type" => "file_search", "file_search_store_names" => Any["fileSearchStores/store-1"]),
                Dict(
                    "type" => "function",
                    "name" => "lookup_weather",
                    "description" => "Lookup weather",
                    "parameters" => Dict("type" => "object"),
                ),
            ],
            tool_choice = Dict("function" => Dict("name" => "lookup_weather")),
            max_output_tokens = 200,
            temperature = 0.2,
            top_p = 0.9,
            include = Any["unused.include"],
            stream = true,
            parallel_tool_calls = true,
            metadata = Dict{String,Any}("trace_id" => "abc"),
        )

        @test captured["method"] == "POST"
        @test captured["url"] == "https://example.gemini.test/v1beta/models/gemini-3-flash-preview:generateContent"
        @test any(h -> h.first == "x-goog-api-key" && h.second == "gemini-key", captured["headers"])

        payload = captured["payload"]
        @test payload[:systemInstruction][:parts][1][:text] == "You are concise"
        @test payload[:contents][1][:role] == "user"

        parts = payload[:contents][1][:parts]
        @test parts[1][:text] == "hello"
        @test parts[2][:inlineData][:mimeType] == "image/png"
        @test parts[2][:inlineData][:data] == "AA=="
        @test parts[3][:inlineData][:mimeType] == "application/pdf"
        @test parts[4][:fileData][:fileUri] == "https://example.test/doc.pdf"

        @test payload[:tools][1][:googleSearch] isa AbstractDict
        @test payload[:tools][2][:codeExecution] isa AbstractDict
        @test payload[:tools][3][:urlContext] isa AbstractDict
        @test !any(tool -> (tool isa AbstractDict && haskey(tool, :googleMaps)), payload[:tools])
        @test payload[:tools][4][:fileSearch][:fileSearchStoreNames][1] == "fileSearchStores/store-1"
        @test payload[:tools][5][:functionDeclarations][1][:name] == "lookup_weather"
        @test payload[:toolConfig][:functionCallingConfig][:mode] == "ANY"
        @test payload[:toolConfig][:functionCallingConfig][:allowedFunctionNames][1] == "lookup_weather"

        @test payload[:generationConfig][:maxOutputTokens] == 200
        @test payload[:generationConfig][:temperature] == 0.2
        @test payload[:generationConfig][:topP] == 0.9
        @test payload[:generationConfig][:thinkingConfig][:thinkingBudget] == 256
        @test payload[:generationConfig][:thinkingConfig][:includeThoughts] == true

        @test response.text == "hi\nfrom native gemini"
        @test response.usage !== nothing
        @test response.usage.input_tokens == 18
        @test response.usage.output_tokens == 7
        @test response.usage.reasoning_tokens == 2
        @test response.usage.cached_tokens == 1
    end

    @testset "chat_completion drops googleMaps when combined with googleSearch" begin
        captured = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "candidates" => Any[
                            Dict("content" => Dict(
                            "role" => "model",
                            "parts" => Any[Dict("text" => "ok")],
                        )),
                        ],
                        "usageMetadata" => Dict(
                            "promptTokenCount" => 1,
                            "candidatesTokenCount" => 1,
                            "totalTokenCount" => 2,
                        ),
                    ),
                ),
            )
        end

        provider = GeminiProvider(
            api_key = "gemini-key",
            base_url = "https://example.gemini.test/v1beta",
            model = "gemini-3-flash-preview",
            request = mock_request,
            max_retries = 0,
        )

        response = chat_completion(
            provider,
            Any[Dict("role" => "user", "content" => Any[Dict("type" => "input_text", "text" => "hello")])];
            tools = Any[
                Dict("type" => "web_search"),
                Dict("type" => "google_maps"),
            ],
        )

        @test response.text == "ok"
        @test captured["payload"][:tools][1][:googleSearch] isa AbstractDict
        @test !any(tool -> (tool isa AbstractDict && haskey(tool, :googleMaps)), captured["payload"][:tools])
    end

    @testset "chat_completion enables includeThoughts when Gemini tools are present" begin
        captured = Dict{String,Any}()

        mock_request = function (method, url, headers, body)
            captured["payload"] = JSON3.read(String(body))
            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "candidates" => Any[
                            Dict("content" => Dict(
                            "role" => "model",
                            "parts" => Any[Dict("text" => "ok")],
                        )),
                        ],
                        "usageMetadata" => Dict(
                            "promptTokenCount" => 1,
                            "candidatesTokenCount" => 1,
                            "totalTokenCount" => 2,
                        ),
                    ),
                ),
            )
        end

        provider = GeminiProvider(
            api_key = "gemini-key",
            base_url = "https://example.gemini.test/v1beta",
            model = "gemini-3-flash-preview",
            request = mock_request,
            max_retries = 0,
        )

        response = chat_completion(
            provider,
            Any[Dict("role" => "user", "content" => Any[Dict("type" => "input_text", "text" => "hello")])];
            tools = Any[
                Dict(
                "type" => "function",
                "name" => "sum_numbers",
                "parameters" => Dict("type" => "object"),
            ),
            ],
        )

        @test response.text == "ok"
        payload = captured["payload"]
        @test payload[:generationConfig][:thinkingConfig][:includeThoughts] == true
    end

    @testset "make_llm_processor uses native Gemini functionResponse continuation" begin
        payloads = Any[]
        call_no = Ref(0)

        mock_request = function (method, url, headers, body)
            call_no[] += 1
            payload = JSON3.read(String(body))
            push!(payloads, payload)

            if call_no[] == 1
                return HTTP.Response(
                    200,
                    JSON3.write(
                        Dict(
                            "candidates" => Any[
                                Dict(
                                "content" => Dict(
                                    "role" => "model",
                                    "parts" => Any[
                                        Dict(
                                            "text" => "internal thought",
                                            "thought" => true,
                                            "thoughtSignature" => "sig_abc123",
                                        ),
                                        Dict(
                                            "functionCall" => Dict(
                                                "id" => "call_1",
                                                "name" => "sum_numbers",
                                                "args" => Dict("a" => 2, "b" => 3),
                                                "thoughtSignature" => "sig_abc123",
                                            ),
                                        ),
                                    ],
                                ),
                            ),
                            ],
                            "usageMetadata" => Dict(
                                "promptTokenCount" => 9,
                                "candidatesTokenCount" => 3,
                                "totalTokenCount" => 12,
                            ),
                        ),
                    ),
                )
            end

            return HTTP.Response(
                200,
                JSON3.write(
                    Dict(
                        "candidates" => Any[
                            Dict(
                            "content" => Dict(
                                "role" => "model",
                                "parts" => Any[
                                    Dict("text" => "gemini says 5"),
                                ],
                            ),
                        ),
                        ],
                        "usageMetadata" => Dict(
                            "promptTokenCount" => 11,
                            "candidatesTokenCount" => 4,
                            "totalTokenCount" => 15,
                        ),
                    ),
                ),
            )
        end

        provider = GeminiProvider(
            api_key = "gemini-key",
            base_url = "https://example.gemini.test/v1beta",
            model = "gemini-3-flash-preview",
            request = mock_request,
            max_retries = 0,
        )

        sum_tool = ToolDef(
            name = "sum_numbers",
            parameters = Dict{String,Any}(
                "type" => "object",
                "properties" => Dict{String,Any}(
                    "a" => Dict{String,Any}("type" => "integer"),
                    "b" => Dict{String,Any}("type" => "integer"),
                ),
                "required" => Any["a", "b"],
            ),
            execute = args -> Int(args["a"]) + Int(args["b"]),
        )

        processor = make_llm_processor(provider;
            tools = [sum_tool],
            max_tool_iterations = 4,
        )

        msg = InboundMessage(
            channel = :telegram,
            session_key = "telegram:42",
            user_id = "42",
            chat_id = "42",
            text = "2+3?",
        )

        result = processor(msg, TurnRecord[])
        @test result.text == "gemini says 5"
        @test haskey(result.metadata, "tool_events")
        @test length(result.metadata["tool_events"]) == 1
        @test result.metadata["tool_events"][1].call.tool_name == "sum_numbers"
        @test result.metadata["tool_events"][1].result.error === nothing

        @test length(payloads) == 2
        second_payload = payloads[2]
        @test length(second_payload[:contents]) == 3
        @test second_payload[:contents][2][:role] == "model"
        @test second_payload[:contents][2][:parts][1][:thought] == true
        @test second_payload[:contents][2][:parts][1][:thoughtSignature] == "sig_abc123"
        @test second_payload[:contents][2][:parts][2][:functionCall][:name] == "sum_numbers"
        @test second_payload[:contents][2][:parts][2][:functionCall][:thoughtSignature] == "sig_abc123"
        @test second_payload[:contents][3][:role] == "user"
        @test second_payload[:contents][3][:parts][1][:functionResponse][:name] == "sum_numbers"
        @test second_payload[:contents][3][:parts][1][:functionResponse][:id] == "call_1"
        @test second_payload[:contents][3][:parts][1][:functionResponse][:response][:output] == "5"
    end
end
