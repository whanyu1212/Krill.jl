const _CLAUDE_CODE_TIMEOUT_S = 1800.0
const _CLAUDE_CODE_MAX_OUTPUT_CHARS = 20_000
const _CLAUDE_CODE_PROGRESS_INTERVAL_S = 15.0

function _parse_stream_json_result(lines::Vector{String})
    # First pass: extract rate limit info (forward scan)
    rate_limit_info = nothing
    for line in lines
        stripped = strip(line)
        isempty(stripped) && continue
        try
            event = JSON3.read(stripped)
            if get(event, :type, nothing) == "rate_limit_event"
                rate_limit_info = get(event, :rate_limit_info, nothing)
            end
        catch e
            @debug "claude_code: skipping unparseable stream line" line=stripped exception=e
        end
    end

    # Second pass: find result (backward scan)
    for i in length(lines):-1:1
        line = strip(lines[i])
        isempty(line) && continue
        try
            event = JSON3.read(line)
            get(event, :type, nothing) == "result" || continue

            is_error = get(event, :is_error, false)
            result = get(event, :result, nothing)
            cost = get(event, :total_cost_usd, nothing)
            subtype = get(event, :subtype, "")
            session_id = get(event, :session_id, nothing)

            parts = String[]
            if is_error || subtype != "success"
                push!(parts, "Error ($(subtype)):")
            end
            if result !== nothing && !isempty(string(result))
                push!(parts, string(result))
            end
            if cost !== nothing
                push!(parts, "\n[Cost: \$$(round(cost; digits=4))]")
            end
            if session_id !== nothing
                push!(parts, "[Session: $(session_id)]")
            end
            if rate_limit_info !== nothing
                status = get(rate_limit_info, :status, "unknown")
                resets_at = get(rate_limit_info, :resetsAt, nothing)
                if resets_at !== nothing
                    reset_time = Dates.unix2datetime(resets_at)
                    push!(parts, "[Rate limit: $(status), resets $(Dates.format(reset_time, "HH:MM")) UTC]")
                else
                    push!(parts, "[Rate limit: $(status)]")
                end
            end
            return join(parts, " ")
        catch e
            @debug "claude_code: skipping unparseable result line" line=line exception=e
            continue
        end
    end
    join(lines, "\n")
end

function _extract_progress_event(line::AbstractString)
    try
        event = JSON3.read(line)
        etype = get(event, :type, nothing)

        if etype == "assistant"
            msg = get(event, :message, nothing)
            msg === nothing && return nothing
            content = get(msg, :content, nothing)
            content === nothing && return nothing
            for part in content
                ptype = get(part, :type, nothing)
                if ptype == "tool_use"
                    tool_name = get(part, :name, "tool")
                    return "Using $(tool_name)..."
                end
            end
            return nothing  # skip text deltas
        elseif etype == "rate_limit_event"
            info = get(event, :rate_limit_info, nothing)
            info === nothing && return nothing
            status = get(info, :status, "unknown")
            if status != "allowed"
                return "Rate limit status: $(status)"
            end
            return nothing
        end
    catch e
        @debug "claude_code: skipping unparseable progress line" exception=e
    end
    return nothing
end

function _check_claude_code_rate_limit()
    claude_path = Sys.which("claude")
    claude_path === nothing && return (ok = false, msg = "claude CLI not found on PATH")

    cmd = Cmd(["claude", "-p", "ping", "--output-format", "stream-json", "--verbose",
        "--max-budget-usd", "0.01"])
    out_pipe = Pipe()
    err_pipe = Pipe()
    proc = try
        run(pipeline(cmd; stdout = out_pipe, stderr = err_pipe); wait = false)
    catch e
        return (ok = false, msg = "Failed to run claude: $(sprint(showerror, e))")
    end
    close(out_pipe.in)
    close(err_pipe.in)

    out_task = @async try
        ;
        String(read(out_pipe));
    catch _
        ;
        "";
    end
    err_task = @async try
        ;
        String(read(err_pipe));
    catch _
        ;
        "";
    end

    timedwait(() -> !process_running(proc), 30.0; pollint = 0.05)
    if process_running(proc)
        try
            ;
            kill(proc);
        catch _
            ;
        end
        return (ok = false, msg = "Rate limit check timed out")
    end

    stdout_text = fetch(out_task)
    for line in split(stdout_text, '\n')
        stripped = strip(line)
        isempty(stripped) && continue
        try
            event = JSON3.read(stripped)
            if get(event, :type, nothing) == "rate_limit_event"
                info = get(event, :rate_limit_info, nothing)
                info === nothing && continue
                status = get(info, :status, "unknown")
                resets_at = get(info, :resetsAt, nothing)
                if status != "allowed"
                    reset_str = ""
                    if resets_at !== nothing
                        reset_time = Dates.unix2datetime(resets_at)
                        reset_str = ", resets $(Dates.format(reset_time, "HH:MM")) UTC"
                    end
                    return (ok = false, msg = "Rate limited ($(status)$(reset_str)). Try again later.")
                end
                return (ok = true, msg = "")
            end
        catch _
            continue
        end
    end
    return (ok = true, msg = "")  # no rate limit event = assume ok
end

function _claude_code_impl(
    args::Dict{String,Any};
    workspace::AbstractString,
    timeout_s::Float64,
    model::String,
    permission_mode::String,
    max_budget::Union{Nothing,Float64},
    progress_fn::Union{Nothing,Function},
    progress_interval_s::Float64,
)
    task_text = get(args, "task", nothing)
    task_text isa AbstractString || return "Error: `task` must be a string"
    task_str = strip(String(task_text))
    isempty(task_str) && return "Error: `task` must not be empty"

    session_id = get(args, "session_id", nothing)
    resume = _parse_bool(get(args, "resume", false))

    # Pre-flight rate limit check
    rate_check = _check_claude_code_rate_limit()
    if !rate_check.ok
        return "Claude Code unavailable: $(rate_check.msg)"
    end

    # Build command
    cmd_parts = [
        "claude", "-p", task_str,
        "--output-format", "stream-json",
        "--verbose",
        "--model", model,
        "--permission-mode", permission_mode,
    ]
    max_budget !== nothing && append!(cmd_parts, ["--max-budget-usd", string(max_budget)])
    if session_id isa AbstractString && !isempty(strip(String(session_id)))
        append!(cmd_parts, ["--resume", strip(String(session_id))])
    elseif resume
        push!(cmd_parts, "--continue")
    end

    cmd = Cmd(Cmd(cmd_parts); dir = workspace)

    @info "Claude Code starting" model=model task=first(task_str, 80) workspace=workspace timeout_s=timeout_s

    # Subprocess with line-by-line streaming
    stderr_buf = IOBuffer()
    stdout_lines = String[]
    timed_out = Ref(false)

    proc = try
        open(pipeline(cmd; stderr = stderr_buf), "r")
    catch e
        return "Error starting Claude Code: $(sprint(showerror, e))"
    end

    watchdog = @async begin
        sleep(timeout_s)
        if process_running(proc)
            timed_out[] = true
            kill(proc)
        end
    end

    last_progress_at = Ref(time())

    try
        while !eof(proc)
            line = readline(proc)
            push!(stdout_lines, line)

            # Throttled progress updates
            if progress_fn !== nothing
                now_t = time()
                if now_t - last_progress_at[] >= progress_interval_s
                    progress_msg = _extract_progress_event(line)
                    if progress_msg !== nothing
                        try
                            ;
                            progress_fn(progress_msg);
                        catch _
                            ;
                        end
                        last_progress_at[] = now_t
                    end
                end
            end
        end
    catch e
        e isa Base.IOError || rethrow()
    end

    if !istaskdone(watchdog)
        Base.schedule(watchdog, InterruptException(); error = true)
    end

    if timed_out[]
        close(proc)
        @warn "Claude Code timed out" timeout_s=timeout_s lines=length(stdout_lines)
        partial = _parse_stream_json_result(stdout_lines)
        return _truncate_text("Claude Code timed out after $(timeout_s)s.\n$(partial)", _CLAUDE_CODE_MAX_OUTPUT_CHARS)
    end

    close(proc)

    result = _parse_stream_json_result(stdout_lines)
    @info "Claude Code finished" chars=length(result) lines=length(stdout_lines)
    return _truncate_text(result, _CLAUDE_CODE_MAX_OUTPUT_CHARS)
end
