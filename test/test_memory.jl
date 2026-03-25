@testset "Krill.jl Memory consolidation" begin
    @testset "consolidate_session_memory! updates MEMORY/HISTORY/state" begin
        workspace = mktempdir()
        memory_store = MemoryStore(; workspace=workspace)
        captured_payload = Ref{Any}(nothing)
        call_count = Ref(0)

        mock_request = function(method, url, headers, body)
            call_count[] += 1
            payload = JSON3.read(String(body))
            captured_payload[] = payload
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_mem_1",
                "output_text" => "## Memory\n- User prefers concise technical replies.",
                "usage" => Dict("input_tokens" => 20, "output_tokens" => 8, "total_tokens" => 28),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        history = TurnRecord[
            TurnRecord(:user, "My preferred style is concise and technical.", uuid4(), nothing, now(UTC)),
            TurnRecord(:assistant, "Understood, I will keep replies concise.", uuid4(), nothing, now(UTC)),
        ]

        result = consolidate_session_memory!(
            provider,
            memory_store,
            "telegram:55",
            history;
            config=MemoryConsolidatorConfig(
                unconsolidated_token_threshold=1,
                max_output_tokens=256,
                max_input_turn_chars=2_000,
            ),
        )

        @test result.consolidated == true
        @test result.last_consolidated == 2
        @test call_count[] == 1
        @test occursin("concise technical replies", load_memory(memory_store, "telegram:55"))
        @test load_memory_state(memory_store, "telegram:55").last_consolidated == 2

        archived = read(history_path(memory_store, "telegram:55"), String)
        @test occursin("Consolidated turn range: 1-2", archived)
        @test occursin("concise and technical", archived)

        payload = captured_payload[]
        @test payload !== nothing
        @test occursin("durable conversation memory", String(payload[:instructions]))
    end

    @testset "consolidate_session_memory! skips below threshold" begin
        memory_store = MemoryStore(; workspace=mktempdir())
        call_count = Ref(0)

        mock_request = function(method, url, headers, body)
            call_count[] += 1
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_mem_2",
                "output_text" => "unused",
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        history = TurnRecord[
            TurnRecord(:user, "short", uuid4(), nothing, now(UTC)),
        ]

        result = consolidate_session_memory!(
            provider,
            memory_store,
            "telegram:77",
            history;
            config=MemoryConsolidatorConfig(unconsolidated_token_threshold=10_000),
        )

        @test result.consolidated == false
        @test result.reason == :below_threshold
        @test call_count[] == 0
        @test load_memory(memory_store, "telegram:77") == ""
        @test load_memory_state(memory_store, "telegram:77").last_consolidated == 0
    end

    @testset "consolidate_session_memory! falls back to raw dump after max_failures" begin
        memory_store = MemoryStore(; workspace=mktempdir())
        call_count = Ref(0)

        # LLM always fails
        mock_request = function(method, url, headers, body)
            call_count[] += 1
            error("LLM unavailable")
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        history = TurnRecord[
            TurnRecord(:user, "Remember my name is Alice.", uuid4(), nothing, now(UTC)),
            TurnRecord(:assistant, "Got it, Alice.", uuid4(), nothing, now(UTC)),
        ]

        config = MemoryConsolidatorConfig(
            unconsolidated_token_threshold=1,
            max_output_tokens=256,
            max_input_turn_chars=2_000,
            max_failures=2,
        )

        # First failure: increments counter, does not consolidate
        r1 = consolidate_session_memory!(provider, memory_store, "telegram:fail", history; config=config)
        @test r1.consolidated == false
        @test r1.reason == :llm_error
        @test load_memory_state(memory_store, "telegram:fail").consolidation_failures == 1
        @test load_memory_state(memory_store, "telegram:fail").last_consolidated == 0

        # Second failure: increments counter again
        r2 = consolidate_session_memory!(provider, memory_store, "telegram:fail", history; config=config)
        @test r2.consolidated == false
        @test r2.reason == :llm_error
        @test load_memory_state(memory_store, "telegram:fail").consolidation_failures == 2

        # Third attempt: failures >= max_failures, triggers raw dump fallback
        r3 = consolidate_session_memory!(provider, memory_store, "telegram:fail", history; config=config)
        @test r3.consolidated == true
        @test r3.reason == :fallback_raw_dump
        @test r3.last_consolidated == 2
        @test load_memory_state(memory_store, "telegram:fail").last_consolidated == 2
        @test load_memory_state(memory_store, "telegram:fail").consolidation_failures == 0

        archived = read(history_path(memory_store, "telegram:fail"), String)
        @test occursin("Consolidated turn range: 1-2", archived)
        @test occursin("Remember my name is Alice", archived)

        # MEMORY.md should NOT have been updated (no LLM summary)
        @test load_memory(memory_store, "telegram:fail") == ""
    end

    @testset "consolidate_session_memory! resets failure counter on success" begin
        memory_store = MemoryStore(; workspace=mktempdir())

        # Pre-seed with 1 failure
        save_memory_state!(memory_store, "telegram:reset", MemoryState(0, 1))

        mock_request = function(method, url, headers, body)
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_ok",
                "output_text" => "## Memory\n- User is Bob.",
                "usage" => Dict("input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        history = TurnRecord[
            TurnRecord(:user, "My name is Bob.", uuid4(), nothing, now(UTC)),
            TurnRecord(:assistant, "Nice to meet you, Bob.", uuid4(), nothing, now(UTC)),
        ]

        result = consolidate_session_memory!(
            provider, memory_store, "telegram:reset", history;
            config=MemoryConsolidatorConfig(unconsolidated_token_threshold=1),
        )

        @test result.consolidated == true
        @test result.reason == :ok
        @test load_memory_state(memory_store, "telegram:reset").consolidation_failures == 0
    end

    @testset "consolidate_session_memory! caps batch with max_consolidation_turns" begin
        memory_store = MemoryStore(; workspace=mktempdir())
        captured_prompt = Ref("")

        mock_request = function(method, url, headers, body)
            payload = JSON3.read(String(body))
            # Extract the prompt text to verify which turns were included
            input_items = payload[:input]
            if !isempty(input_items)
                content = input_items[1][:content]
                if !isempty(content)
                    captured_prompt[] = String(content[1][:text])
                end
            end
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_cap",
                "output_text" => "## Memory\n- Batch capped.",
                "usage" => Dict("input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        # Create 10 turns
        history = TurnRecord[]
        for i in 1:10
            push!(history, TurnRecord(:user, "Message $i from user", uuid4(), nothing, now(UTC)))
        end

        config = MemoryConsolidatorConfig(
            unconsolidated_token_threshold=1,
            max_output_tokens=256,
            max_input_turn_chars=2_000,
            max_consolidation_turns=3,
        )

        # First call: should only process turns 1-3
        r1 = consolidate_session_memory!(provider, memory_store, "telegram:cap", history; config=config)
        @test r1.consolidated == true
        @test r1.consolidated_turns == 3
        @test r1.last_consolidated == 3
        @test occursin("[1]", captured_prompt[])
        @test occursin("[3]", captured_prompt[])
        @test !occursin("[4]", captured_prompt[])

        # Second call: should process turns 4-6
        r2 = consolidate_session_memory!(provider, memory_store, "telegram:cap", history; config=config)
        @test r2.consolidated == true
        @test r2.consolidated_turns == 3
        @test r2.last_consolidated == 6

        # Third call: turns 7-9
        r3 = consolidate_session_memory!(provider, memory_store, "telegram:cap", history; config=config)
        @test r3.consolidated == true
        @test r3.last_consolidated == 9

        # Fourth call: turn 10 only
        r4 = consolidate_session_memory!(provider, memory_store, "telegram:cap", history; config=config)
        @test r4.consolidated == true
        @test r4.consolidated_turns == 1
        @test r4.last_consolidated == 10

        # Fifth call: nothing left
        r5 = consolidate_session_memory!(provider, memory_store, "telegram:cap", history; config=config)
        @test r5.consolidated == false
        @test r5.reason == :no_unconsolidated_turns
    end

    @testset "run_session_loop! executes memory consolidator after each turn" begin
        hub = MessageHubState(inbound_capacity=4, outbound_capacity=4)
        session_store = SessionStore(; workspace=mktempdir())
        memory_store = MemoryStore(; workspace=mktempdir())
        call_count = Ref(0)

        mock_request = function(method, url, headers, body)
            call_count[] += 1
            return HTTP.Response(200, JSON3.write(Dict(
                "id" => "resp_mem_3",
                "output_text" => "## Memory\n- Persisted fact from loop.",
                "usage" => Dict("input_tokens" => 12, "output_tokens" => 4, "total_tokens" => 16),
            )))
        end

        provider = OpenAIProvider(
            api_key="test-key",
            base_url="https://example.openai.test/v1",
            request=mock_request,
            max_retries=0,
        )

        consolidator = make_memory_consolidator(
            provider,
            memory_store;
            unconsolidated_token_threshold=1,
            max_output_tokens=256,
            max_input_turn_chars=2_000,
        )

        publish_inbound!(hub, InboundMessage(
            channel=:telegram,
            session_key="telegram:loop",
            user_id="1",
            chat_id="1",
            text="remember this for later",
        ))

        run_session_loop!(hub, Ref(false);
            store=session_store,
            processor=echo_processor,
            after_process=consolidator,
        )

        @test call_count[] == 1
        @test load_memory_state(memory_store, "telegram:loop").last_consolidated == 2
        @test occursin("Persisted fact", load_memory(memory_store, "telegram:loop"))
    end
end
