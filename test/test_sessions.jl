@testset "Krill.jl SessionStore" begin
    @testset "sanitize_session_key replaces special chars" begin
        @test sanitize_session_key("telegram:5376") == "telegram_5376"
        @test sanitize_session_key("telegram:123:topic:456") == "telegram_123_topic_456"
        @test sanitize_session_key("plain") == "plain"
    end

    @testset "get_session_lock! returns same lock for same key" begin
        store = SessionStore(; workspace=mktempdir())
        lock1 = get_session_lock!(store, "session_a")
        lock2 = get_session_lock!(store, "session_a")
        @test lock1 === lock2
    end

    @testset "get_session_lock! returns different locks for different keys" begin
        store = SessionStore(; workspace=mktempdir())
        lock1 = get_session_lock!(store, "session_a")
        lock2 = get_session_lock!(store, "session_b")
        @test lock1 !== lock2
    end

    @testset "load_history returns empty for new session" begin
        store = SessionStore(; workspace=mktempdir())
        history = load_history(store, "new_session")
        @test isempty(history)
    end

    @testset "append_turn! and load_history roundtrip" begin
        store = SessionStore(; workspace=mktempdir())
        turn = TurnRecord(:user, "hello", uuid4(), nothing, now(UTC))
        append_turn!(store, "test_session", turn)

        history = load_history(store, "test_session")
        @test length(history) == 1
        @test history[1].role == :user
        @test history[1].text == "hello"
        @test history[1].message_id == turn.message_id
        @test history[1].correlation_id === nothing
    end

    @testset "append_turn! accumulates with correlation_id" begin
        store = SessionStore(; workspace=mktempdir())
        t1 = TurnRecord(:user, "msg1", uuid4(), nothing, now(UTC))
        t2 = TurnRecord(:assistant, "reply1", uuid4(), t1.message_id, now(UTC))
        t3 = TurnRecord(:user, "msg2", uuid4(), nothing, now(UTC))

        append_turn!(store, "s1", t1)
        append_turn!(store, "s1", t2)
        append_turn!(store, "s1", t3)

        history = load_history(store, "s1")
        @test length(history) == 3
        @test history[1].role == :user
        @test history[2].role == :assistant
        @test history[2].correlation_id == t1.message_id
        @test history[3].text == "msg2"
    end

    @testset "save_history overwrites" begin
        store = SessionStore(; workspace=mktempdir())
        t1 = TurnRecord(:user, "old", uuid4(), nothing, now(UTC))
        append_turn!(store, "s1", t1)

        t2 = TurnRecord(:user, "new", uuid4(), nothing, now(UTC))
        save_history(store, "s1", [t2])

        history = load_history(store, "s1")
        @test length(history) == 1
        @test history[1].text == "new"
    end

    @testset "session_dir creates directory" begin
        workspace = mktempdir()
        store = SessionStore(; workspace=workspace)
        dir = session_dir(store, "telegram:123")
        @test isdir(dir)
        @test dir == joinpath(workspace, "sessions", "telegram_123")
    end
end

@testset "Krill.jl MemoryStore" begin
    @testset "memory paths are per-session and sanitized" begin
        workspace = mktempdir()
        store = MemoryStore(; workspace=workspace)
        dir = memory_dir(store, "telegram:123:topic:9")
        @test isdir(dir)
        @test dir == joinpath(workspace, "memory", "telegram_123_topic_9")
        @test memory_path(store, "telegram:123:topic:9") == joinpath(dir, "MEMORY.md")
        @test history_path(store, "telegram:123:topic:9") == joinpath(dir, "HISTORY.md")
        @test memory_state_path(store, "telegram:123:topic:9") == joinpath(dir, "state.json")
    end

    @testset "save_memory! and load_memory roundtrip" begin
        store = MemoryStore(; workspace=mktempdir())
        @test load_memory(store, "s1") == ""

        save_memory!(store, "s1", "Important preference: terse replies.")
        loaded = load_memory(store, "s1")
        @test occursin("terse replies", loaded)
    end

    @testset "append_history! and memory state roundtrip" begin
        store = MemoryStore(; workspace=mktempdir())
        append_history!(store, "s2", "Archived turns 1-10")
        append_history!(store, "s2", "Archived turns 11-20")

        history_md = read(history_path(store, "s2"), String)
        @test occursin("Archived turns 1-10", history_md)
        @test occursin("Archived turns 11-20", history_md)

        @test load_memory_state(store, "s2").last_consolidated == 0
        @test load_memory_state(store, "s2").consolidation_failures == 0
        save_memory_state!(store, "s2", MemoryState(20))
        @test load_memory_state(store, "s2").last_consolidated == 20
        @test load_memory_state(store, "s2").consolidation_failures == 0
        save_memory_state!(store, "s2", MemoryState(20, 2))
        @test load_memory_state(store, "s2").consolidation_failures == 2
        @test_throws ArgumentError save_memory_state!(store, "s2", MemoryState(-1))
    end
end
