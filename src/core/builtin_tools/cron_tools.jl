function _cron_add_impl(args::Dict{String,Any}; cron_service::CronService, from_cron::Bool=false)
    label = String(get(args, "label", "unnamed"))
    schedule_type = String(get(args, "schedule_type", ""))
    schedule_value = String(get(args, "schedule_value", ""))
    task_text = String(get(args, "task", ""))

    isempty(schedule_type) && return "Error: `schedule_type` is required (at, interval, cron)"
    isempty(task_text) && return "Error: `task` is required"

    schedule = try
        parse_schedule(schedule_type, schedule_value)
    catch e
        return "Error parsing schedule: $(sprint(showerror, e))"
    end

    once = get(args, "once", false) === true
    ctx = _CRON_CONTEXT[]
    job = CronJob(
        label=label,
        schedule=schedule,
        prompt=task_text,
        channel=ctx.channel,
        session_key=ctx.session_key,
        chat_id=ctx.chat_id,
        from_cron=from_cron,
        once=once,
    )

    try
        add_job!(cron_service, job)
    catch e
        return "Error adding cron job: $(sprint(showerror, e))"
    end
    return "Added cron job '$(label)' ($(schedule_type): $(schedule_value))"
end

function _cron_list_impl(args::Dict{String,Any}; cron_service::CronService)
    jobs = list_jobs(cron_service)
    isempty(jobs) && return "No scheduled jobs."
    lines = String["Scheduled jobs:", ""]
    for job in jobs
        status = job.enabled ? "enabled" : "disabled"
        push!(lines, "- $(job.label) [$(status)] schedule=$(_schedule_display(job.schedule)) prompt=$(first(job.prompt, 60))")
    end
    return join(lines, "\n")
end

function _cron_remove_impl(args::Dict{String,Any}; cron_service::CronService)
    label = get(args, "label", nothing)
    label isa AbstractString || return "Error: `label` must be a string"
    label_s = strip(String(label))
    isempty(label_s) && return "Error: `label` must not be empty"

    jobs = list_jobs(cron_service)
    idx = findfirst(j -> j.label == label_s, jobs)
    idx === nothing && return "Error: no job found with label '$(label_s)'"

    try
        remove_job!(cron_service, jobs[idx].id)
    catch e
        return "Error removing job: $(sprint(showerror, e))"
    end
    return "Removed cron job '$(label_s)'"
end

function _schedule_display(s::AtSchedule)
    return "at $(Dates.format(s.at, "yyyy-mm-dd HH:MM"))"
end
function _schedule_display(s::IntervalSchedule)
    total = Int(round(s.interval_s))
    if total >= 3600
        return "every $(total ÷ 3600)h$(total % 3600 ÷ 60)m"
    elseif total >= 60
        return "every $(total ÷ 60)m"
    else
        return "every $(total)s"
    end
end
function _schedule_display(s::CronSchedule)
    return "cron '$(s.expression)'"
end

"""
    register_cron_tools!(registry, cron_service; replace=false)

Register cron management tools (add, list, remove) into the given `ToolRegistry`.
"""
function register_cron_tools!(
    registry::ToolRegistry,
    cron_service::CronService;
    replace::Bool=false,
)
    defs = ToolDef[]

    push!(defs, ToolDef(
        name="cron_add",
        description="Schedule a recurring or one-shot task. For 'in X minutes/hours' use schedule_type='interval' with schedule_value like '5m' or '2h' — do NOT use 'at' for relative times. Use 'at' only when you know the exact UTC datetime. Use 'cron' for wall-clock schedules like 'every day at 9am'.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "label" => Dict{String,Any}("type" => "string", "description" => "Unique job label"),
                "schedule_type" => Dict{String,Any}("type" => "string", "description" => "One of: 'at' (one-shot at exact UTC datetime), 'interval' (recurring or one-shot delay, e.g. '1m', '30s', '2h'), 'cron' (cron expression)"),
                "schedule_value" => Dict{String,Any}("type" => "string", "description" => "Schedule value: ISO datetime (yyyy-mm-ddTHH:MM:SS) for 'at'; duration like '60s', '5m', '2h' for 'interval'; 5-field cron expression for 'cron'"),
                "task" => Dict{String,Any}("type" => "string", "description" => "Task description (processed as an LLM prompt when the job fires)"),
                "once" => Dict{String,Any}("type" => "boolean", "description" => "If true, disable the job after it fires once (useful for 'interval' one-shot delays like 'remind me in 5m')"),
            ),
            "required" => Any["label", "schedule_type", "schedule_value", "task"],
        ),
        execute=args -> _cron_add_impl(args; cron_service=cron_service),
    ))

    push!(defs, ToolDef(
        name="cron_list",
        description="List all scheduled jobs.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(),
            "required" => Any[],
        ),
        execute=args -> _cron_list_impl(args; cron_service=cron_service),
    ))

    push!(defs, ToolDef(
        name="cron_remove",
        description="Remove a scheduled job by label.",
        parameters=Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "label" => Dict{String,Any}("type" => "string", "description" => "Job label to remove"),
            ),
            "required" => Any["label"],
        ),
        execute=args -> _cron_remove_impl(args; cron_service=cron_service),
    ))

    for def in defs
        register_tool!(registry, def; replace=replace)
    end
    return defs
end
