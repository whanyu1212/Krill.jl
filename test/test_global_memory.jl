@testset "GlobalMemory" begin
    # ── unit tests (no LLM) ──────────────────────────────────────────

    @testset "load/save round-trip" begin
        mktempdir() do dir
            store = GlobalMemoryStore(; data_dir = dir)
            # Fresh store returns empty string
            @test load_global_memory(store, "user42") == ""
            # Save and reload
            save_global_memory!(store, "user42", "- likes Julia\n")
            @test load_global_memory(store, "user42") == "- likes Julia\n"
            # Different users are isolated
            @test load_global_memory(store, "user99") == ""
        end
    end

    @testset "global_memory_path is deterministic" begin
        mktempdir() do dir
            store = GlobalMemoryStore(; data_dir = dir)
            p1 = global_memory_path(store, "alice")
            p2 = global_memory_path(store, "alice")
            @test p1 == p2
            @test endswith(p1, "MEMORY.md")
        end
    end

    @testset "user_id sanitization" begin
        mktempdir() do dir
            store = GlobalMemoryStore(; data_dir = dir)
            # Special characters in user_id should not crash
            save_global_memory!(store, "user@123/test", "data")
            @test load_global_memory(store, "user@123/test") == "data"
        end
    end

    # ── consolidation with mock LLM ──────────────────────────────────

    if !KRILL_FAST_TESTS
        @testset "consolidate_global_memory! merges via LLM" begin
            mktempdir() do dir
                store = GlobalMemoryStore(; data_dir = dir)
                captured = Ref{Any}(nothing)
                provider = make_mock_openai_provider(;
                    captured = captured,
                    response_text = "- likes Julia\n- prefers dark mode",
                )

                result = consolidate_global_memory!(provider, store, "user1", "prefers dark mode")

                # Result returned and saved
                @test result == "- likes Julia\n- prefers dark mode"
                @test load_global_memory(store, "user1") == "- likes Julia\n- prefers dark mode"

                # LLM was called with a prompt containing the fact
                @test captured[] !== nothing
                payload = captured[]
                @test haskey(payload, :input) || haskey(payload, "input")
            end
        end

        @testset "consolidate_global_memory! incorporates existing profile" begin
            mktempdir() do dir
                store = GlobalMemoryStore(; data_dir = dir)
                save_global_memory!(store, "user2", "- name: Bob\n")

                provider = make_mock_openai_provider(;
                    response_text = "- name: Bob\n- hobby: chess",
                )

                result = consolidate_global_memory!(provider, store, "user2", "hobby: chess")
                @test contains(result, "Bob")
            end
        end

        @testset "/remember slash command end-to-end" begin
            mktempdir() do dir
                store = GlobalMemoryStore(; data_dir = dir)
                provider = make_mock_openai_provider(;
                    response_text = "- remember this fact",
                )

                hub = MessageHubState()
                running = Ref(true)
                session_store = SessionStore(; workspace = dir)

                # Inject a /remember message
                msg = InboundMessage(
                    channel = :test,
                    session_key = "sess_rem",
                    chat_id = "42",
                    user_id = "user_rem",
                    text = "/remember loves Dota 2",
                )
                publish_inbound!(hub, msg)

                # Shut down after processing
                Threads.@spawn begin
                    sleep(0.3)
                    running[] = false
                end

                outbound = String[]
                consumer_task = Threads.@spawn begin
                    run_session_loop!(hub, running;
                        store = session_store,
                        global_memory_store = store,
                        global_memory_provider = provider,
                    )
                end

                # Drain outbound
                deadline = time() + 5.0
                while time() < deadline
                    om = try_take_outbound!(hub)
                    om !== nothing && push!(outbound, om.text)
                    length(outbound) >= 1 && break
                    sleep(0.05)
                end
                running[] = false
                wait(consumer_task)

                # Should have replied with "Remembered."
                @test any(t -> contains(t, "Remembered"), outbound)
                # Memory should be persisted
                saved = load_global_memory(store, "user_rem")
                @test !isempty(saved)
            end
        end
    end
end
