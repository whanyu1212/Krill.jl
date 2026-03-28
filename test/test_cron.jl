using Krill
using Test
using Dates
using UUIDs
using Krill.Telegram: HTTP, JSON3

const CronMod = Krill.Cron
const BuiltinToolsMod = Krill.BuiltinTools

@testset "Krill.jl C.7 Cron expression parsing" begin
    @testset "parse_cron parses simple expression" begin
        sched = parse_cron("30 9 * * 1")
        @test sched.minute == [30]
        @test sched.hour == [9]
        @test sched.day_of_month == collect(1:31)
        @test sched.month == collect(1:12)
        @test sched.day_of_week == [1]
    end

    @testset "parse_cron parses wildcards" begin
        sched = parse_cron("* * * * *")
        @test sched.minute == collect(0:59)
        @test sched.hour == collect(0:23)
    end

    @testset "parse_cron parses step values" begin
        sched = parse_cron("*/15 */6 * * *")
        @test sched.minute == [0, 15, 30, 45]
        @test sched.hour == [0, 6, 12, 18]
    end

    @testset "parse_cron parses lists" begin
        sched = parse_cron("0 9,17 * * *")
        @test sched.minute == [0]
        @test sched.hour == [9, 17]
    end

    @testset "parse_cron parses ranges" begin
        sched = parse_cron("0 9 * * 1-5")
        @test sched.day_of_week == [1, 2, 3, 4, 5]
    end

    @testset "parse_cron rejects invalid field count" begin
        @test_throws ArgumentError parse_cron("* *")
        @test_throws ArgumentError parse_cron("* * * * * *")
    end

    @testset "parse_cron rejects out-of-range values" begin
        @test_throws ArgumentError parse_cron("60 * * * *")
        @test_throws ArgumentError parse_cron("* 24 * * *")
        @test_throws ArgumentError parse_cron("* * 0 * *")
        @test_throws ArgumentError parse_cron("* * * * 7")
    end
end

@testset "Krill.jl C.7 parse_schedule" begin
    @testset "at schedule" begin
        sched = parse_schedule("at", "2026-03-25T09:00:00")
        @test sched isa CronMod.AtSchedule
        @test sched.at == DateTime(2026, 3, 25, 9, 0, 0)
    end

    @testset "every schedule with units" begin
        sched_s = parse_schedule("every", "30s")
        @test sched_s isa CronMod.IntervalSchedule
        @test sched_s.interval_s == 30.0

        sched_m = parse_schedule("every", "5m")
        @test sched_m isa CronMod.IntervalSchedule
        @test sched_m.interval_s == 300.0

        sched_h = parse_schedule("every", "2h")
        @test sched_h isa CronMod.IntervalSchedule
        @test sched_h.interval_s == 7200.0
    end

    @testset "cron schedule" begin
        sched = parse_schedule("cron", "0 9 * * 1")
        @test sched isa CronMod.CronSchedule
    end

    @testset "unknown type" begin
        @test_throws ArgumentError parse_schedule("weekly", "monday")
    end
end

@testset "Krill.jl C.7 is_due evaluation" begin
    @testset "at schedule fires once at target time" begin
        sched = CronMod.AtSchedule(DateTime(2026, 3, 25, 9, 0, 0))
        job = CronMod.CronJob(
            uuid4(), "test", sched, "do something",
            :telegram, "telegram:42", "42",
            now(UTC), nothing, 0, true, false, false,
            CronMod.JobExecution[],
        )

        # Before target: not due
        @test !is_due(job, DateTime(2026, 3, 25, 8, 59, 59))

        # At target: due
        @test is_due(job, DateTime(2026, 3, 25, 9, 0, 0))

        # After target: still due (hasn't fired yet)
        @test is_due(job, DateTime(2026, 3, 25, 10, 0, 0))

        # After firing: not due anymore
        job.last_fired_at = DateTime(2026, 3, 25, 9, 0, 0)
        @test !is_due(job, DateTime(2026, 3, 25, 10, 0, 0))
    end

    @testset "interval schedule fires on interval" begin
        sched = CronMod.IntervalSchedule(60.0)  # every 60s
        job = CronMod.CronJob(
            uuid4(), "test", sched, "do something",
            :telegram, "telegram:42", "42",
            now(UTC), nothing, 0, true, false, false,
            CronMod.JobExecution[],
        )

        # Never fired: due immediately
        @test is_due(job, now(UTC))

        # Just fired: not due
        t0 = DateTime(2026, 3, 25, 9, 0, 0)
        job.last_fired_at = t0
        @test !is_due(job, t0 + Second(30))

        # After interval: due
        @test is_due(job, t0 + Second(61))
    end

    @testset "cron schedule fires at matching times" begin
        sched = parse_cron("30 9 * * *")  # 9:30 every day
        job = CronMod.CronJob(
            uuid4(), "test", sched, "do something",
            :telegram, "telegram:42", "42",
            now(UTC), nothing, 0, true, false, false,
            CronMod.JobExecution[],
        )

        # Matching time: due
        @test is_due(job, DateTime(2026, 3, 25, 9, 30, 0))

        # Non-matching time: not due
        @test !is_due(job, DateTime(2026, 3, 25, 9, 29, 0))
        @test !is_due(job, DateTime(2026, 3, 25, 10, 30, 0))

        # Same minute as last fire: not due (prevent double-fire)
        job.last_fired_at = DateTime(2026, 3, 25, 9, 30, 0)
        @test !is_due(job, DateTime(2026, 3, 25, 9, 30, 45))

        # Next day same time: due again
        @test is_due(job, DateTime(2026, 3, 26, 9, 30, 0))
    end

    @testset "disabled job is never due" begin
        sched = CronMod.IntervalSchedule(1.0)
        job = CronMod.CronJob(
            uuid4(), "test", sched, "do something",
            :telegram, "telegram:42", "42",
            now(UTC), nothing, 0, false, false, false,  # enabled=false
            CronMod.JobExecution[],
        )
        @test !is_due(job, now(UTC))
    end
end

@testset "Krill.jl C.7 CronJob constructor" begin
    @testset "creates job with defaults" begin
        job = CronJob(
            label = "test job",
            schedule = parse_schedule("every", "5m"),
            prompt = "check status",
            channel = :telegram,
            session_key = "telegram:42",
            chat_id = "42",
        )
        @test job.label == "test job"
        @test job.prompt == "check status"
        @test job.channel == :telegram
        @test job.enabled == true
        @test job.fire_count == 0
        @test job.last_fired_at === nothing
        @test job.id isa UUID
    end

    @testset "rejects from_cron=true" begin
        @test_throws ArgumentError CronJob(
            label = "bad",
            schedule = parse_schedule("every", "1m"),
            prompt = "nope",
            channel = :telegram,
            session_key = "telegram:1",
            chat_id = "1",
            from_cron = true,
        )
    end
end

@testset "Krill.jl C.7 CronService CRUD" begin
    workspace = mktempdir()

    @testset "add, list, get, remove" begin
        svc = CronService(workspace = workspace, tick_interval_s = 1.0)

        job = CronJob(
            label = "job1",
            schedule = parse_schedule("every", "10s"),
            prompt = "hello",
            channel = :telegram,
            session_key = "telegram:1",
            chat_id = "1",
        )
        add_job!(svc, job)

        @test length(list_jobs(svc)) == 1
        @test get_job(svc, job.id) !== nothing
        @test get_job(svc, job.id).label == "job1"

        # Add second job
        job2 = CronJob(
            label = "job2",
            schedule = parse_schedule("cron", "*/5 * * * *"),
            prompt = "check",
            channel = :telegram,
            session_key = "telegram:2",
            chat_id = "2",
        )
        add_job!(svc, job2)
        @test length(list_jobs(svc)) == 2

        # Remove
        @test remove_job!(svc, job.id) == true
        @test length(list_jobs(svc)) == 1
        @test get_job(svc, job.id) === nothing

        # Remove non-existent
        @test remove_job!(svc, uuid4()) == false
    end
end

@testset "Krill.jl C.7 CronService persistence" begin
    workspace = mktempdir()

    @testset "save and reload jobs" begin
        svc1 = CronService(workspace = workspace, tick_interval_s = 1.0)

        job = CronJob(
            label = "persist_test",
            schedule = parse_schedule("cron", "0 9 * * 1-5"),
            prompt = "daily standup",
            channel = :telegram,
            session_key = "telegram:99",
            chat_id = "99",
        )
        add_job!(svc1, job)

        # Verify file exists
        @test isfile(joinpath(workspace, "cron", "jobs.json"))

        # Create new service from same workspace — should load the job
        svc2 = CronService(workspace = workspace, tick_interval_s = 1.0)
        loaded = list_jobs(svc2)
        @test length(loaded) == 1
        @test loaded[1].id == job.id
        @test loaded[1].label == "persist_test"
        @test loaded[1].prompt == "daily standup"
        @test loaded[1].session_key == "telegram:99"
        @test loaded[1].schedule isa CronMod.CronSchedule
    end

    @testset "persistence roundtrip preserves all schedule types" begin
        ws = mktempdir()
        svc = CronService(workspace = ws, tick_interval_s = 1.0)

        add_job!(
            svc,
            CronJob(
                label = "at_job",
                schedule = parse_schedule("at", "2026-12-25T00:00:00"),
                prompt = "xmas",
                channel = :telegram,
                session_key = "t:1",
                chat_id = "1",
            ),
        )
        add_job!(
            svc,
            CronJob(
                label = "every_job",
                schedule = parse_schedule("every", "2h"),
                prompt = "check",
                channel = :telegram,
                session_key = "t:2",
                chat_id = "2",
            ),
        )
        add_job!(
            svc,
            CronJob(
                label = "cron_job",
                schedule = parse_schedule("cron", "*/10 * * * *"),
                prompt = "poll",
                channel = :telegram,
                session_key = "t:3",
                chat_id = "3",
            ),
        )

        svc2 = CronService(workspace = ws, tick_interval_s = 1.0)
        jobs = sort(list_jobs(svc2), by = j -> j.label)

        @test length(jobs) == 3
        @test jobs[1].label == "at_job" && jobs[1].schedule isa CronMod.AtSchedule
        @test jobs[2].label == "cron_job" && jobs[2].schedule isa CronMod.CronSchedule
        @test jobs[3].label == "every_job" && jobs[3].schedule isa CronMod.IntervalSchedule
        @test jobs[3].schedule.interval_s == 7200.0
    end
end

@testset "Krill.jl C.7 CronService tick loop" begin
    @testset "tick fires due interval job and publishes message" begin
        workspace = mktempdir()
        published = InboundMessage[]
        publish_fn = msg -> begin
            push!(published, msg)
            return true
        end

        svc = CronService(workspace = workspace, tick_interval_s = 0.1, publish_fn = publish_fn)

        job = CronJob(
            label = "tick_test",
            schedule = parse_schedule("every", "0.1s"),
            prompt = "ping",
            channel = :telegram,
            session_key = "telegram:50",
            chat_id = "50",
        )
        add_job!(svc, job)

        # Run tick manually
        CronMod._tick_once!(svc)

        @test length(published) == 1
        @test published[1].chat_id == "50"
        @test Krill.message_text(published[1]) == "ping"
        @test published[1].metadata["source"] == "cron"
        @test published[1].metadata["job_label"] == "tick_test"

        # Job state updated
        loaded = get_job(svc, job.id)
        @test loaded.fire_count == 1
        @test loaded.last_fired_at !== nothing
    end

    @testset "tick does not fire non-due job" begin
        workspace = mktempdir()
        published = InboundMessage[]
        publish_fn = msg -> (push!(published, msg); true)

        svc = CronService(workspace = workspace, tick_interval_s = 0.1, publish_fn = publish_fn)

        # Schedule far in the future
        job = CronJob(
            label = "future",
            schedule = parse_schedule("at", "2099-01-01T00:00:00"),
            prompt = "nope",
            channel = :telegram,
            session_key = "telegram:1",
            chat_id = "1",
        )
        add_job!(svc, job)

        CronMod._tick_once!(svc)
        @test isempty(published)
    end

    @testset "one-shot job auto-disables after firing" begin
        workspace = mktempdir()
        published = InboundMessage[]
        publish_fn = msg -> (push!(published, msg); true)

        svc = CronService(workspace = workspace, tick_interval_s = 0.1, publish_fn = publish_fn)

        # Schedule in the past so it fires immediately
        job = CronJob(
            label = "oneshot",
            schedule = parse_schedule("at", "2020-01-01T00:00:00"),
            prompt = "fire once",
            channel = :telegram,
            session_key = "telegram:1",
            chat_id = "1",
        )
        add_job!(svc, job)

        CronMod._tick_once!(svc)
        @test length(published) == 1

        # Second tick should not fire (auto-disabled)
        CronMod._tick_once!(svc)
        @test length(published) == 1

        loaded = get_job(svc, job.id)
        @test loaded.enabled == false
    end

    @testset "start! and stop! lifecycle" begin
        workspace = mktempdir()
        published = InboundMessage[]
        publish_fn = msg -> (push!(published, msg); true)

        svc = CronService(workspace = workspace, tick_interval_s = 0.1, publish_fn = publish_fn)

        job = CronJob(
            label = "lifecycle",
            schedule = parse_schedule("every", "0.05s"),
            prompt = "tick",
            channel = :telegram,
            session_key = "telegram:1",
            chat_id = "1",
        )
        add_job!(svc, job)

        Krill.Cron.start!(svc)
        @test svc.running[] == true
        @test svc.tick_task !== nothing

        # Wait for at least one tick
        sleep(0.5)

        Krill.Cron.stop!(svc)
        @test svc.running[] == false

        @test length(published) >= 1
    end

    @testset "start! without publish_fn throws" begin
        svc = CronService(workspace = mktempdir(), tick_interval_s = 1.0)
        @test_throws ArgumentError Krill.Cron.start!(svc)
    end
end

@testset "Krill.jl C.7 run history" begin
    workspace = mktempdir()
    published = InboundMessage[]
    publish_fn = msg -> (push!(published, msg); true)

    svc = CronService(workspace = workspace, tick_interval_s = 0.1, publish_fn = publish_fn)

    job = CronJob(
        label = "history_test",
        schedule = parse_schedule("every", "0.05s"),
        prompt = "go",
        channel = :telegram,
        session_key = "telegram:1",
        chat_id = "1",
    )
    add_job!(svc, job)

    # Fire a few times
    for _ in 1:3
        CronMod._tick_once!(svc)
        sleep(0.06)
    end

    loaded = get_job(svc, job.id)
    @test loaded.fire_count >= 2
    @test length(loaded.history) >= 2
    @test all(h -> h.success, loaded.history)
end

@testset "Krill.jl C.7 CronService validation" begin
    @test_throws ArgumentError CronService(workspace = mktempdir(), tick_interval_s = 0.0)
    @test_throws ArgumentError CronService(workspace = mktempdir(), tick_interval_s = -1.0)
end

@testset "Krill.jl C.7 cron day-of-week mapping" begin
    # Julia: Mon=1..Sun=7; cron: Sun=0,Mon=1..Sat=6
    # Wednesday = Julia dayofweek 3, cron dow 3
    sched = parse_cron("0 12 * * 3")  # noon every Wednesday
    wed = DateTime(2026, 3, 25, 12, 0, 0)  # 2026-03-25 is a Wednesday
    @test Dates.dayofweek(wed) == 3  # Julia confirms Wednesday

    job = CronMod.CronJob(
        uuid4(), "wed", sched, "test",
        :telegram, "t:1", "1",
        now(UTC), nothing, 0, true, false, false,
        CronMod.JobExecution[],
    )
    @test is_due(job, wed)

    # Thursday should not match
    thu = DateTime(2026, 3, 26, 12, 0, 0)
    @test !is_due(job, thu)

    # Sunday = Julia dayofweek 7, cron dow 0
    sched_sun = parse_cron("0 8 * * 0")
    sun = DateTime(2026, 3, 29, 8, 0, 0)  # 2026-03-29 is a Sunday
    @test Dates.dayofweek(sun) == 7

    job_sun = CronMod.CronJob(
        uuid4(), "sun", sched_sun, "test",
        :telegram, "t:1", "1",
        now(UTC), nothing, 0, true, false, false,
        CronMod.JobExecution[],
    )
    @test is_due(job_sun, sun)
end

# ─── Cron built-in tool tests ────────────────────────────────────────

@testset "Krill.jl C.7 cron_add tool" begin
    workspace = mktempdir()
    svc = CronService(workspace = workspace, tick_interval_s = 1.0)
    registry = ToolRegistry()
    register_cron_tools!(registry, svc)

    @testset "creates interval job via tool dispatch" begin
        result = dispatch_tool(
            registry,
            "cron_add",
            Dict{String,Any}(
                "label" => "test_add",
                "schedule_type" => "every",
                "schedule_value" => "5m",
                "task" => "check status",
                "session_key" => "telegram:42",
                "chat_id" => "42",
            ),
        )
        @test occursin("Added cron job", result)
        @test occursin("test_add", result)
        jobs = list_jobs(svc)
        @test length(jobs) == 1
        @test jobs[1].label == "test_add"
        @test jobs[1].prompt == "check status"
    end

    @testset "creates cron-expression job" begin
        result = dispatch_tool(
            registry,
            "cron_add",
            Dict{String,Any}(
                "label" => "daily",
                "schedule_type" => "cron",
                "schedule_value" => "0 9 * * 1-5",
                "task" => "standup",
                "session_key" => "telegram:1",
                "chat_id" => "1",
            ),
        )
        @test occursin("Added cron job", result)
        @test length(list_jobs(svc)) == 2
    end

    @testset "returns error on invalid schedule value" begin
        result = dispatch_tool(
            registry,
            "cron_add",
            Dict{String,Any}(
                "label" => "bad",
                "schedule_type" => "cron",
                "schedule_value" => "not a cron expr",
                "task" => "nope",
                "session_key" => "t:1",
                "chat_id" => "1",
            ),
        )
        @test occursin("Error", result)
    end

    @testset "returns error on missing required fields" begin
        result = dispatch_tool(
            registry,
            "cron_add",
            Dict{String,Any}(
                "label" => "missing",
                "schedule_type" => "every",
                "schedule_value" => "5m",
                "task" => "",
                "session_key" => "t:1",
                "chat_id" => "1",
            ),
        )
        @test occursin("Error", result)
    end
end

@testset "Krill.jl C.7 cron_list tool" begin
    workspace = mktempdir()
    svc = CronService(workspace = workspace, tick_interval_s = 1.0)
    registry = ToolRegistry()
    register_cron_tools!(registry, svc)

    @testset "empty list" begin
        result = dispatch_tool(registry, "cron_list", Dict{String,Any}())
        @test result == "No scheduled jobs."
    end

    @testset "lists added jobs" begin
        add_job!(
            svc,
            CronJob(
                label = "j1",
                schedule = parse_schedule("every", "1m"),
                prompt = "a",
                channel = :telegram,
                session_key = "t:1",
                chat_id = "1",
            ),
        )
        add_job!(
            svc,
            CronJob(
                label = "j2",
                schedule = parse_schedule("cron", "0 12 * * *"),
                prompt = "b",
                channel = :telegram,
                session_key = "t:2",
                chat_id = "2",
            ),
        )
        result = dispatch_tool(registry, "cron_list", Dict{String,Any}())
        @test occursin("j1", result)
        @test occursin("j2", result)
        @test occursin("every", result)
        @test occursin("cron '", result)
    end
end

@testset "Krill.jl C.7 cron_remove tool" begin
    workspace = mktempdir()
    svc = CronService(workspace = workspace, tick_interval_s = 1.0)
    registry = ToolRegistry()
    register_cron_tools!(registry, svc)

    job = CronJob(
        label = "removeme",
        schedule = parse_schedule("every", "1h"),
        prompt = "x",
        channel = :telegram,
        session_key = "t:1",
        chat_id = "1",
    )
    add_job!(svc, job)
    @test length(list_jobs(svc)) == 1

    @testset "removes existing job" begin
        result = dispatch_tool(registry, "cron_remove", Dict{String,Any}("label" => "removeme"))
        @test occursin("Removed", result)
        @test length(list_jobs(svc)) == 0
    end

    @testset "returns not found for unknown label" begin
        result = dispatch_tool(registry, "cron_remove", Dict{String,Any}("label" => "nonexistent"))
        @test occursin("not found", result) || occursin("Error", result)
    end

    @testset "returns error for empty label" begin
        result = dispatch_tool(registry, "cron_remove", Dict{String,Any}("label" => ""))
        @test occursin("Error", result) || occursin("empty", result)
    end
end

@testset "Krill.jl C.7 cron tool recursion prevention" begin
    # CronJob constructor throws when from_cron=true, preventing recursive scheduling
    @test_throws ArgumentError CronJob(
        label = "recursive",
        schedule = parse_schedule("every", "1m"),
        prompt = "should fail",
        channel = :telegram,
        session_key = "t:1",
        chat_id = "1",
        from_cron = true,
    )
end

@testset "Krill.jl C.7 RuntimeState cron integration" begin
    @testset "RuntimeState with LLM provider registers cron tools" begin
        mock_request =
            (method, url, headers, body) -> HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)

        workspace = mktempdir()
        provider = OpenAIProvider(
            api_key = "test",
            model = "gpt-4.1-mini",
            base_url = "https://example.test/v1",
            request = mock_request,
            max_retries = 0,
        )

        rt = RuntimeState(TelegramChannel(client);
            llm_provider = provider,
            workspace = workspace,
            data_dir = mktempdir(),
            llm_enable_cron = true,
        )

        @test rt.cron_service !== nothing
        @test rt.cron_service isa CronService
        st = status(rt)
        @test st["cron_enabled"] == true
        @test st["cron_job_count"] == 0

        shutdown!(rt)
    end

    @testset "RuntimeState without LLM provider has no cron" begin
        mock_request =
            (method, url, headers, body) -> HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)

        rt = RuntimeState(TelegramChannel(client); workspace = mktempdir())

        @test rt.cron_service === nothing
        st = status(rt)
        @test st["cron_enabled"] == false
        @test st["cron_job_count"] == 0

        shutdown!(rt)
    end

    @testset "RuntimeState with cron disabled" begin
        mock_request =
            (method, url, headers, body) -> HTTP.Response(200, JSON3.write(Dict("ok" => true, "result" => Any[])))
        client = TelegramClient("token"; base_url = "https://example.test/botTOKEN", request = mock_request)

        provider = OpenAIProvider(
            api_key = "test",
            model = "gpt-4.1-mini",
            base_url = "https://example.test/v1",
            request = mock_request,
            max_retries = 0,
        )

        rt = RuntimeState(TelegramChannel(client);
            llm_provider = provider,
            workspace = mktempdir(),
            llm_enable_cron = false,
        )

        @test rt.cron_service === nothing

        shutdown!(rt)
    end
end
