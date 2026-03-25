const _GITHUB_TIMEOUT_S = 30.0
const _MAX_GITHUB_OUTPUT_CHARS = 10_000

function _github_impl(args::Dict{String,Any}; timeout_s::Float64=_GITHUB_TIMEOUT_S)
    command = get(args, "command", nothing)
    command isa AbstractString || return "Error: `command` must be a string"
    cmd_text = strip(String(command))
    isempty(cmd_text) && return "Error: `command` must not be empty"

    # Ensure the command starts with "gh"
    if !startswith(cmd_text, "gh ")
        cmd_text = "gh " * cmd_text
    end

    gh_path = Sys.which("gh")
    gh_path === nothing && return "Error: `gh` CLI not found on PATH. Install from https://cli.github.com/"

    shell_cmd = Cmd(["/bin/sh", "-c", cmd_text])
    out_pipe = Pipe()
    err_pipe = Pipe()
    proc = try
        run(pipeline(shell_cmd; stdout=out_pipe, stderr=err_pipe); wait=false)
    catch e
        return "Error executing gh: $(sprint(showerror, e))"
    end

    close(out_pipe.in)
    close(err_pipe.in)

    out_task = @async try; String(read(out_pipe)); catch _; ""; end
    err_task = @async try; String(read(err_pipe)); catch _; ""; end

    wait_status = timedwait(() -> !process_running(proc), timeout_s; pollint=0.05)
    if wait_status == :timed_out
        try; kill(proc); catch _; end
        return "Error: gh command timed out after $(timeout_s)s"
    end

    stdout_text = fetch(out_task)
    stderr_text = fetch(err_task)
    exit_code = proc.exitcode

    parts = String[]
    isempty(stdout_text) || push!(parts, stdout_text)
    isempty(stderr_text) || push!(parts, "STDERR:\n" * stderr_text)
    push!(parts, "Exit code: $(exit_code)")
    return _truncate_text(join(parts, "\n"), _MAX_GITHUB_OUTPUT_CHARS)
end
