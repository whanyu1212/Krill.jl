const _CODEX_TIMEOUT_S = 1800.0
const _MAX_CODEX_OUTPUT_CHARS = 20_000

function _parse_codex_result(lines::Vector{String})
    last_message = nothing
    total_input_tokens = 0
    total_output_tokens = 0
    total_cached_tokens = 0
    thread_id = nothing
    had_error = false
    error_msg = nothing

    for line in lines
        stripped = strip(line)
        isempty(stripped) && continue
        try
            event = JSON3.read(stripped)
            etype = get(event, :type, nothing)

            if etype == "thread.started"
                thread_id = get(event, :thread_id, nothing)
            elseif etype == "item.completed"
                item = get(event, :item, nothing)
                item === nothing && continue
                itype = get(item, :type, nothing)
                if itype == "agent_message"
                    last_message = get(item, :text, nothing)
                end
            elseif etype == "turn.completed"
                usage = get(event, :usage, nothing)
                if usage !== nothing
                    total_input_tokens += get(usage, :input_tokens, 0)
                    total_output_tokens += get(usage, :output_tokens, 0)
                    total_cached_tokens += get(usage, :cached_input_tokens, 0)
                end
            elseif etype == "turn.failed"
                had_error = true
                err = get(event, :error, nothing)
                if err !== nothing
                    error_msg = get(err, :message, nothing)
                end
            elseif etype == "error"
                had_error = true
                error_msg = get(event, :message, error_msg)
            end
        catch _
            continue
        end
    end

    parts = String[]
    if had_error && error_msg !== nothing
        push!(parts, "Error: $(error_msg)")
    end
    if last_message !== nothing && !isempty(string(last_message))
        push!(parts, string(last_message))
    elseif isempty(parts)
        push!(parts, "(no output)")
    end
    usage_str = "[Tokens: $(total_input_tokens) in / $(total_output_tokens) out"
    total_cached_tokens > 0 && (usage_str *= ", $(total_cached_tokens) cached")
    usage_str *= "]"
    push!(parts, "\n$(usage_str)")
    thread_id !== nothing && push!(parts, "[Thread: $(thread_id)]")
    return join(parts, " ")
end

function _extract_codex_progress(line::AbstractString)
    try
        event = JSON3.read(line)
        etype = get(event, :type, nothing)
        if etype == "item.completed"
            item = get(event, :item, nothing)
            item === nothing && return nothing
            itype = get(item, :type, nothing)
            if itype == "command_execution"
                cmd = get(item, :command, nothing)
                status = get(item, :status, nothing)
                if cmd !== nothing
                    short_cmd = length(string(cmd)) > 80 ? string(cmd)[1:80] * "…" : string(cmd)
                    return "Ran: $(short_cmd) ($(status))"
                end
            end
        elseif etype == "error" || etype == "turn.failed"
            return "Codex error encountered"
        end
    catch _
    end
    return nothing
end

function _codex_impl(
    args::Dict{String,Any};
    workspace::AbstractString,
    timeout_s::Float64,
    model::Union{Nothing,String},
    sandbox_mode::String,
    progress_fn::Union{Nothing,Function},
    progress_interval_s::Float64,
)
    task_text = get(args, "task", nothing)
    task_text isa AbstractString || return "Error: `task` must be a string"
    task_str = strip(String(task_text))
    isempty(task_str) && return "Error: `task` must not be empty"

    resume_last = _parse_bool(get(args, "resume", false))

    codex_path = Sys.which("codex")
    codex_path === nothing &&
        return "Error: `codex` CLI not found on PATH. Install from https://github.com/openai/codex"

    # Build command
    cmd_parts = if resume_last
        ["codex", "exec", "resume", "--last", "--json", "--sandbox", sandbox_mode, "-C", workspace]
    else
        ["codex", "exec", task_str, "--json", "--sandbox", sandbox_mode, "-C", workspace]
    end
    model !== nothing && append!(cmd_parts, ["-m", model])

    cmd = Cmd(cmd_parts)

    @info "Codex starting" model=something(model, "default") task=first(task_str, 80) workspace=workspace timeout_s=timeout_s

    # Subprocess with line-by-line streaming
    stderr_buf = IOBuffer()
    stdout_lines = String[]
    timed_out = Ref(false)

    proc = try
        open(pipeline(cmd; stderr = stderr_buf), "r")
    catch e
        return "Error starting Codex: $(sprint(showerror, e))"
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

            if progress_fn !== nothing
                now_t = time()
                if now_t - last_progress_at[] >= progress_interval_s
                    progress_msg = _extract_codex_progress(line)
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
        @warn "Codex timed out" timeout_s=timeout_s lines=length(stdout_lines)
        partial = _parse_codex_result(stdout_lines)
        return _truncate_text("Codex timed out after $(timeout_s)s.\n$(partial)", _MAX_CODEX_OUTPUT_CHARS)
    end

    close(proc)

    result = _parse_codex_result(stdout_lines)
    @info "Codex finished" chars=length(result) lines=length(stdout_lines)
    return _truncate_text(result, _MAX_CODEX_OUTPUT_CHARS)
end
