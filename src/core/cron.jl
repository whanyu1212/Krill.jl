module Cron

using Dates
using UUIDs

using ..Types: InboundMessage

export CronJob, CronService,
    AtSchedule, IntervalSchedule, CronSchedule, Schedule,
    add_job!, remove_job!, list_jobs, get_job,
    start!, stop!, is_due, parse_schedule, parse_cron,
    save_jobs!, load_jobs!

# ─── Schedule types ──────────────────────────────────────────────────

"""Schedule type: run once at a specific UTC time."""
struct AtSchedule
    at::DateTime
end

"""Schedule type: run every `interval` seconds."""
struct IntervalSchedule
    interval_s::Float64
end

"""
Schedule type: cron expression (minute hour day_of_month month day_of_week).

Supports:
- Exact values: `30 9 * * 1` (9:30 every Monday)
- Wildcards: `*`
- Step values: `*/5` (every 5 units)
- Lists: `1,15` (1st and 15th)
- Ranges: `1-5` (1 through 5)
"""
struct CronSchedule
    expression::String
    minute::Vector{Int}
    hour::Vector{Int}
    day_of_month::Vector{Int}
    month::Vector{Int}
    day_of_week::Vector{Int}  # 0=Sunday, 1=Monday, ..., 6=Saturday
end

const Schedule = Union{AtSchedule, IntervalSchedule, CronSchedule}

"""Parse a cron field into a sorted vector of matching integers."""
function _parse_cron_field(field::AbstractString, min_val::Int, max_val::Int)::Vector{Int}
    results = Set{Int}()
    for part in split(field, ',')
        part = strip(part)
        if part == "*"
            union!(results, min_val:max_val)
        elseif startswith(part, "*/")
            step = parse(Int, part[3:end])
            step > 0 || throw(ArgumentError("Invalid cron step: $part"))
            union!(results, min_val:step:max_val)
        elseif occursin('-', part)
            lo, hi = split(part, '-'; limit=2)
            lo_val = parse(Int, lo)
            hi_val = parse(Int, hi)
            min_val <= lo_val <= max_val || throw(ArgumentError("Cron range out of bounds: $part"))
            min_val <= hi_val <= max_val || throw(ArgumentError("Cron range out of bounds: $part"))
            union!(results, lo_val:hi_val)
        else
            val = parse(Int, part)
            min_val <= val <= max_val || throw(ArgumentError("Cron value out of bounds: $part"))
            push!(results, val)
        end
    end
    return sort!(collect(results))
end

"""Parse a standard 5-field cron expression into a CronSchedule."""
function parse_cron(expr::AbstractString)::CronSchedule
    fields = split(strip(expr))
    length(fields) == 5 || throw(ArgumentError("Cron expression must have 5 fields, got $(length(fields)): \"$expr\""))
    minute      = _parse_cron_field(fields[1], 0, 59)
    hour        = _parse_cron_field(fields[2], 0, 23)
    day_of_month = _parse_cron_field(fields[3], 1, 31)
    month       = _parse_cron_field(fields[4], 1, 12)
    day_of_week = _parse_cron_field(fields[5], 0, 6)
    return CronSchedule(expr, minute, hour, day_of_month, month, day_of_week)
end

"""Parse a schedule from a type string and value."""
function parse_schedule(type::AbstractString, value::AbstractString)::Schedule
    t = lowercase(strip(type))
    if t == "at"
        dt = DateTime(strip(value), dateformat"yyyy-mm-ddTHH:MM:SS")
        return AtSchedule(dt)
    elseif t == "every"
        return IntervalSchedule(_parse_interval(value))
    elseif t == "cron"
        return parse_cron(value)
    else
        throw(ArgumentError("Unknown schedule type: $type (expected at, every, or cron)"))
    end
end

"""Parse an interval string like '30s', '5m', '2h' into seconds."""
function _parse_interval(s::AbstractString)::Float64
    s = strip(s)
    if endswith(s, 's')
        return parse(Float64, s[1:end-1])
    elseif endswith(s, 'm')
        return parse(Float64, s[1:end-1]) * 60.0
    elseif endswith(s, 'h')
        return parse(Float64, s[1:end-1]) * 3600.0
    else
        return parse(Float64, s)
    end
end

# ─── CronJob ─────────────────────────────────────────────────────────

"""Execution record for a single cron job run."""
struct JobExecution
    started_at::DateTime
    success::Bool
    error_message::Union{Nothing,String}
end

"""A scheduled job definition."""
mutable struct CronJob
    id::UUID
    label::String
    schedule::Schedule
    prompt::String
    channel::Symbol
    session_key::String
    chat_id::String
    created_at::DateTime
    last_fired_at::Union{Nothing,DateTime}
    fire_count::Int
    enabled::Bool
    from_cron::Bool  # true if this job was created from within a cron execution
    once::Bool       # if true, disable after first fire
    history::Vector{JobExecution}
end

const _MAX_HISTORY_ENTRIES = 20

function CronJob(;
    label::AbstractString,
    schedule::Schedule,
    prompt::AbstractString,
    channel::Symbol,
    session_key::AbstractString,
    chat_id::AbstractString,
    from_cron::Bool=false,
    once::Bool=false,
)
    from_cron && throw(ArgumentError("Cannot schedule cron jobs from within a cron execution"))
    return CronJob(
        uuid4(), String(label), schedule, String(prompt),
        channel, String(session_key), String(chat_id),
        now(UTC), nothing, 0, true, false, once,
        JobExecution[],
    )
end

function _record_execution!(job::CronJob, success::Bool; error_message::Union{Nothing,String}=nothing)
    push!(job.history, JobExecution(now(UTC), success, error_message))
    while length(job.history) > _MAX_HISTORY_ENTRIES
        popfirst!(job.history)
    end
    return nothing
end

# ─── Schedule evaluation ─────────────────────────────────────────────

"""Check if a job is due to fire at the given time."""
function is_due(job::CronJob, now_utc::DateTime)::Bool
    job.enabled || return false
    return _schedule_is_due(job.schedule, now_utc, job.last_fired_at)
end

function _schedule_is_due(sched::AtSchedule, now_utc::DateTime, last_fired::Union{Nothing,DateTime})::Bool
    last_fired !== nothing && return false  # one-shot: already fired
    return now_utc >= sched.at
end

function _schedule_is_due(sched::IntervalSchedule, now_utc::DateTime, last_fired::Union{Nothing,DateTime})::Bool
    if last_fired === nothing
        return true  # never fired; fire immediately on first tick
    end
    elapsed_ms = Dates.value(now_utc - last_fired)
    return elapsed_ms >= sched.interval_s * 1000.0
end

function _schedule_is_due(sched::CronSchedule, now_utc::DateTime, last_fired::Union{Nothing,DateTime})::Bool
    m = Dates.minute(now_utc)
    h = Dates.hour(now_utc)
    dom = Dates.day(now_utc)
    mon = Dates.month(now_utc)
    dow = Dates.dayofweek(now_utc) % 7  # Julia: Mon=1..Sun=7 → 0=Sun,1=Mon..6=Sat

    matches = (m in sched.minute) &&
              (h in sched.hour) &&
              (dom in sched.day_of_month) &&
              (mon in sched.month) &&
              (dow in sched.day_of_week)
    matches || return false

    # Don't fire twice in the same minute
    if last_fired !== nothing
        same_minute = Dates.floor(now_utc, Dates.Minute) == Dates.floor(last_fired, Dates.Minute)
        same_minute && return false
    end
    return true
end

# ─── CronService ─────────────────────────────────────────────────────

"""
    CronService(; workspace, tick_interval_s, publish_fn)

In-process job scheduler. Runs a background tick loop that checks all
registered jobs and fires due ones by injecting `InboundMessage` into the
message hub via `publish_fn`.

`publish_fn` should be a function `(InboundMessage) -> Bool` (e.g.,
`try_publish_inbound!` bound to a hub).
"""
mutable struct CronService
    jobs::Dict{UUID,CronJob}
    lock::ReentrantLock
    running::Ref{Bool}
    tick_task::Union{Nothing,Task}
    tick_interval_s::Float64
    publish_fn::Union{Nothing,Function}
    workspace::String
    jobs_path::String
end

function CronService(;
    workspace::AbstractString="workspace",
    tick_interval_s::Float64=15.0,
    publish_fn::Union{Nothing,Function}=nothing,
)
    tick_interval_s > 0 || throw(ArgumentError("tick_interval_s must be > 0"))
    jobs_path = joinpath(workspace, "cron", "jobs.json")
    svc = CronService(
        Dict{UUID,CronJob}(),
        ReentrantLock(),
        Ref(false),
        nothing,
        tick_interval_s,
        publish_fn,
        String(workspace),
        jobs_path,
    )
    load_jobs!(svc)
    return svc
end

"""Add a job to the service. Returns the job."""
function add_job!(svc::CronService, job::CronJob)::CronJob
    lock(svc.lock) do
        svc.jobs[job.id] = job
    end
    save_jobs!(svc)
    return job
end

"""Remove a job by ID. Returns true if found and removed."""
function remove_job!(svc::CronService, job_id::UUID)::Bool
    removed = lock(svc.lock) do
        haskey(svc.jobs, job_id) || return false
        delete!(svc.jobs, job_id)
        return true
    end
    removed && save_jobs!(svc)
    return removed
end

"""List all jobs."""
function list_jobs(svc::CronService)::Vector{CronJob}
    return lock(svc.lock) do
        collect(values(svc.jobs))
    end
end

"""Get a job by ID."""
function get_job(svc::CronService, job_id::UUID)::Union{Nothing,CronJob}
    return lock(svc.lock) do
        get(svc.jobs, job_id, nothing)
    end
end

# ─── Persistence ─────────────────────────────────────────────────────

function _schedule_to_dict(s::AtSchedule)
    Dict{String,Any}("type" => "at", "value" => Dates.format(s.at, dateformat"yyyy-mm-ddTHH:MM:SS"))
end
function _schedule_to_dict(s::IntervalSchedule)
    Dict{String,Any}("type" => "every", "value" => "$(s.interval_s)s")
end
function _schedule_to_dict(s::CronSchedule)
    Dict{String,Any}("type" => "cron", "value" => s.expression)
end

function _job_to_dict(job::CronJob)
    Dict{String,Any}(
        "id" => string(job.id),
        "label" => job.label,
        "schedule" => _schedule_to_dict(job.schedule),
        "prompt" => job.prompt,
        "channel" => string(job.channel),
        "session_key" => job.session_key,
        "chat_id" => job.chat_id,
        "created_at" => Dates.format(job.created_at, dateformat"yyyy-mm-ddTHH:MM:SS"),
        "last_fired_at" => job.last_fired_at === nothing ? nothing : Dates.format(job.last_fired_at, dateformat"yyyy-mm-ddTHH:MM:SS"),
        "fire_count" => job.fire_count,
        "enabled" => job.enabled,
        "once" => job.once,
        "history" => [Dict{String,Any}(
            "started_at" => Dates.format(h.started_at, dateformat"yyyy-mm-ddTHH:MM:SS"),
            "success" => h.success,
            "error_message" => h.error_message,
        ) for h in job.history],
    )
end

function _dict_to_job(d::AbstractDict)
    sched_d = d["schedule"]
    schedule = parse_schedule(sched_d["type"], sched_d["value"])
    last_fired = d["last_fired_at"] === nothing ? nothing : DateTime(d["last_fired_at"], dateformat"yyyy-mm-ddTHH:MM:SS")
    history = JobExecution[
        JobExecution(
            DateTime(h["started_at"], dateformat"yyyy-mm-ddTHH:MM:SS"),
            h["success"],
            get(h, "error_message", nothing),
        )
        for h in get(d, "history", [])
    ]
    return CronJob(
        UUID(d["id"]),
        d["label"],
        schedule,
        d["prompt"],
        Symbol(d["channel"]),
        d["session_key"],
        d["chat_id"],
        DateTime(d["created_at"], dateformat"yyyy-mm-ddTHH:MM:SS"),
        last_fired,
        get(d, "fire_count", 0),
        get(d, "enabled", true),
        false,
        get(d, "once", false),
        history,
    )
end

"""Persist all jobs to disk."""
function save_jobs!(svc::CronService)
    dir = dirname(svc.jobs_path)
    isdir(dir) || mkpath(dir)
    jobs_list = lock(svc.lock) do
        [_job_to_dict(job) for job in values(svc.jobs)]
    end
    # Simple JSON serialization (no dependency on JSON3 at this level)
    open(svc.jobs_path, "w") do io
        _write_json(io, jobs_list)
    end
    return nothing
end

"""Load jobs from disk. Silently no-ops if file doesn't exist."""
function load_jobs!(svc::CronService)
    isfile(svc.jobs_path) || return nothing
    raw = read(svc.jobs_path, String)
    isempty(strip(raw)) && return nothing
    jobs_list = _parse_json(raw)
    lock(svc.lock) do
        empty!(svc.jobs)
        for d in jobs_list
            try
                job = _dict_to_job(d)
                svc.jobs[job.id] = job
            catch e
                @warn "Failed to load cron job" exception=(e, catch_backtrace())
            end
        end
    end
    return nothing
end

# ─── Minimal JSON (no external dependency) ───────────────────────────

function _write_json(io::IO, v::AbstractVector)
    print(io, "[")
    for (i, item) in enumerate(v)
        i > 1 && print(io, ",")
        _write_json(io, item)
    end
    print(io, "]")
end

function _write_json(io::IO, d::AbstractDict)
    print(io, "{")
    first = true
    for (k, v) in d
        first || print(io, ",")
        first = false
        _write_json(io, string(k))
        print(io, ":")
        _write_json(io, v)
    end
    print(io, "}")
end

function _write_json(io::IO, s::AbstractString)
    print(io, "\"")
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        else
            print(io, c)
        end
    end
    print(io, "\"")
end

function _write_json(io::IO, n::Number)
    print(io, n)
end

function _write_json(io::IO, b::Bool)
    print(io, b ? "true" : "false")
end

function _write_json(io::IO, ::Nothing)
    print(io, "null")
end

# Minimal JSON parser — just enough for our jobs.json format
function _parse_json(s::AbstractString)
    pos = Ref(1)
    result = _parse_value(s, pos)
    return result
end

function _skip_ws(s, pos)
    while pos[] <= length(s) && s[pos[]] in (' ', '\t', '\n', '\r')
        pos[] += 1
    end
end

function _parse_value(s, pos)
    _skip_ws(s, pos)
    pos[] > length(s) && error("Unexpected end of JSON")
    c = s[pos[]]
    if c == '"'
        return _parse_string(s, pos)
    elseif c == '{'
        return _parse_object(s, pos)
    elseif c == '['
        return _parse_array(s, pos)
    elseif c == 't'
        s[pos[]:pos[]+3] == "true" || error("Invalid JSON at $(pos[])")
        pos[] += 4
        return true
    elseif c == 'f'
        s[pos[]:pos[]+4] == "false" || error("Invalid JSON at $(pos[])")
        pos[] += 5
        return false
    elseif c == 'n'
        s[pos[]:pos[]+3] == "null" || error("Invalid JSON at $(pos[])")
        pos[] += 4
        return nothing
    elseif c == '-' || isdigit(c)
        return _parse_number(s, pos)
    else
        error("Unexpected character '$c' at position $(pos[])")
    end
end

function _parse_string(s, pos)
    pos[] += 1  # skip opening quote
    buf = IOBuffer()
    while pos[] <= length(s)
        c = s[pos[]]
        if c == '"'
            pos[] += 1
            return String(take!(buf))
        elseif c == '\\'
            pos[] += 1
            pos[] > length(s) && error("Unexpected end of string escape")
            esc = s[pos[]]
            if esc == '"'; write(buf, '"')
            elseif esc == '\\'; write(buf, '\\')
            elseif esc == 'n'; write(buf, '\n')
            elseif esc == 'r'; write(buf, '\r')
            elseif esc == 't'; write(buf, '\t')
            elseif esc == '/'; write(buf, '/')
            else write(buf, esc)
            end
        else
            write(buf, c)
        end
        pos[] += 1
    end
    error("Unterminated string")
end

function _parse_number(s, pos)
    start = pos[]
    if s[pos[]] == '-'
        pos[] += 1
    end
    while pos[] <= length(s) && (isdigit(s[pos[]]) || s[pos[]] == '.' || s[pos[]] in ('e', 'E', '+', '-'))
        pos[] += 1
    end
    num_str = s[start:pos[]-1]
    if occursin('.', num_str) || occursin('e', num_str) || occursin('E', num_str)
        return parse(Float64, num_str)
    else
        return parse(Int, num_str)
    end
end

function _parse_array(s, pos)
    pos[] += 1  # skip [
    result = Any[]
    _skip_ws(s, pos)
    if pos[] <= length(s) && s[pos[]] == ']'
        pos[] += 1
        return result
    end
    while true
        push!(result, _parse_value(s, pos))
        _skip_ws(s, pos)
        pos[] > length(s) && error("Unterminated array")
        if s[pos[]] == ','
            pos[] += 1
        elseif s[pos[]] == ']'
            pos[] += 1
            return result
        else
            error("Expected ',' or ']' in array at position $(pos[])")
        end
    end
end

function _parse_object(s, pos)
    pos[] += 1  # skip {
    result = Dict{String,Any}()
    _skip_ws(s, pos)
    if pos[] <= length(s) && s[pos[]] == '}'
        pos[] += 1
        return result
    end
    while true
        _skip_ws(s, pos)
        key = _parse_string(s, pos)
        _skip_ws(s, pos)
        pos[] > length(s) && error("Unterminated object")
        s[pos[]] == ':' || error("Expected ':' after key \"$key\"")
        pos[] += 1
        result[key] = _parse_value(s, pos)
        _skip_ws(s, pos)
        pos[] > length(s) && error("Unterminated object")
        if s[pos[]] == ','
            pos[] += 1
        elseif s[pos[]] == '}'
            pos[] += 1
            return result
        else
            error("Expected ',' or '}' in object at position $(pos[])")
        end
    end
end

# ─── Tick loop ───────────────────────────────────────────────────────

"""Start the background tick loop."""
function start!(svc::CronService)
    svc.running[] && return svc
    svc.publish_fn !== nothing || throw(ArgumentError("publish_fn must be set before starting"))
    svc.running[] = true
    svc.tick_task = Threads.@spawn _tick_loop(svc)
    return svc
end

"""Stop the tick loop and wait for it to finish."""
function stop!(svc::CronService)
    svc.running[] || return svc
    svc.running[] = false
    task = svc.tick_task
    if task !== nothing && !istaskdone(task)
        wait(task)
    end
    svc.tick_task = nothing
    save_jobs!(svc)
    return svc
end

function _tick_loop(svc::CronService)
    while svc.running[]
        try
            _tick_once!(svc)
        catch e
            e isa InterruptException && return
            @error "Cron tick error" exception=(e, catch_backtrace())
        end
        _interruptible_sleep(svc.tick_interval_s, svc.running)
    end
end

function _interruptible_sleep(seconds::Float64, running::Ref{Bool})
    deadline = time() + seconds
    while running[] && time() < deadline
        sleep(min(0.5, deadline - time()))
    end
end

function _tick_once!(svc::CronService)
    now_utc = now(UTC)
    due_jobs = lock(svc.lock) do
        [job for job in values(svc.jobs) if is_due(job, now_utc)]
    end

    for job in due_jobs
        _fire_job!(svc, job, now_utc)
    end

    # Auto-disable one-shot jobs that have fired
    lock(svc.lock) do
        for job in values(svc.jobs)
            if job.schedule isa AtSchedule && job.last_fired_at !== nothing
                job.enabled = false
            end
        end
    end

    isempty(due_jobs) || save_jobs!(svc)
end

_schedule_summary(s::AtSchedule) = "at $(Dates.format(s.at, "yyyy-mm-dd HH:MM"))"
_schedule_summary(s::IntervalSchedule) = "every $(s.interval_s)s"
_schedule_summary(s::CronSchedule) = "cron '$(s.expression)'"

function _fire_job!(svc::CronService, job::CronJob, now_utc::DateTime)
    @info "cron job firing" label=job.label schedule=_schedule_summary(job.schedule) fire_count=job.fire_count+1
    msg = InboundMessage(
        channel=job.channel,
        session_key=job.session_key,
        user_id="cron",
        chat_id=job.chat_id,
        text=job.prompt,
        metadata=Dict{String,Any}(
            "source" => "cron",
            "job_id" => string(job.id),
            "job_label" => job.label,
        ),
    )

    success = try
        svc.publish_fn(msg)
    catch e
        @warn "Cron job publish failed" job_id=job.id label=job.label exception=(e, catch_backtrace())
        false
    end

    lock(svc.lock) do
        job.last_fired_at = now_utc
        job.fire_count += 1
        job.once && (job.enabled = false)
        error_msg = success ? nothing : "publish_fn returned false (queue full?)"
        _record_execution!(job, success; error_message=error_msg)
    end
end

end  # module Cron
