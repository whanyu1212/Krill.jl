# Patterns that match destructive or escalation-prone shell commands.
# Each entry is (pattern, reason). Checked against the full command string.
const _EXEC_DENYLIST = Tuple{Regex,String}[
    # Recursive forced deletion
    (r"\brm\s+.*-[a-zA-Z]*r[a-zA-Z]*f|rm\s+.*-[a-zA-Z]*f[a-zA-Z]*r"i, "recursive forced delete (rm -rf)"),
    # Disk wipe / raw block writes
    (r"\bdd\b.*(of=/dev/|if=/dev/zero|if=/dev/urandom)"i, "raw disk write via dd"),
    # Filesystem creation (formats a device)
    (r"\bmkfs\b", "filesystem formatting (mkfs)"),
    # Partition tools
    (r"\b(fdisk|parted|diskutil\s+eraseDisk|diskutil\s+partitionDisk)\b"i, "disk partitioning"),
    # Fork bomb
    (r":\(\)\s*\{.*\|.*&.*\}", "fork bomb"),
    # Privilege escalation
    (r"\bsudo\s+(rm|dd|mkfs|fdisk|parted|chmod\s+777|chown)\b"i, "privileged destructive command"),
    # Overwrite critical system paths
    (r">\s*/etc/(passwd|shadow|sudoers|hosts)\b", "overwrite of critical system file"),
    # Wipe home or root (~ as path, $HOME, or /root)
    (r"\brm\s+[^|;&]*(?:~|\$HOME|/root)\b"i, "delete of home/root directory"),
    # Shutdown / reboot
    (r"\b(shutdown|reboot|halt|poweroff|init\s+[06])\b"i, "system shutdown/reboot"),
]

function _check_exec_denylist(cmd_text::AbstractString)
    for (pattern, reason) in _EXEC_DENYLIST
        if occursin(pattern, cmd_text)
            return reason
        end
    end
    return nothing
end

# Extract all http/https URLs from a shell command string and validate each
# against SSRF rules. Returns an error string if any URL is blocked, nothing if safe.
function _check_exec_urls(cmd_text::AbstractString)
    for m in eachmatch(r"https?://[^\s\"'\\>|;&)]+", cmd_text)
        url = m.match
        _, err = _validate_http_url(url)
        if err !== nothing
            @warn "exec URL scan blocked command" url err cmd=cmd_text
            return "Error: command contains a blocked URL ($(url)): $(err)"
        end
    end
    return nothing
end

function _exec_impl(
    args::Dict{String,Any},
    workspace::AbstractString;
    timeout_s::Float64,
    path_append::AbstractString,
    restrict_to_workspace::Bool,
)
    command = get(args, "command", nothing)
    command isa AbstractString || return "Error: `command` must be a string"
    cmd_text = strip(String(command))
    isempty(cmd_text) && return "Error: `command` must not be empty"

    if (reason = _check_exec_denylist(cmd_text)) !== nothing
        @warn "exec denylist blocked command" reason cmd=cmd_text
        return "Error: command blocked by security denylist ($(reason))"
    end

    if (url_err = _check_exec_urls(cmd_text)) !== nothing
        return url_err
    end

    working_dir_raw = get(args, "working_dir", workspace)
    working_dir = try
        _resolve_path(String(working_dir_raw), workspace; restrict_to_workspace=restrict_to_workspace)
    catch e
        return "Error: $(sprint(showerror, e))"
    end
    isdir(working_dir) || return "Error: working_dir is not a directory: $(working_dir)"

    timeout_val = try
        Float64(get(args, "timeout", timeout_s))
    catch _
        timeout_s
    end
    timeout_val > 0 || return "Error: timeout must be > 0"

    shell_cmd = Sys.iswindows() ? Cmd(["cmd", "/c", cmd_text]) : Cmd(["/bin/sh", "-lc", cmd_text])
    final_cmd = if isempty(path_append)
        shell_cmd
    else
        path_sep = Sys.iswindows() ? ";" : ":"
        env = merge(Dict{String,String}(String(k) => String(v) for (k, v) in ENV), Dict("PATH" => get(ENV, "PATH", "") * path_sep * String(path_append)))
        Cmd(shell_cmd; env=env)
    end

    out_pipe = Pipe()
    err_pipe = Pipe()
    proc = try
        run(pipeline(final_cmd; stdout=out_pipe, stderr=err_pipe); wait=false, dir=working_dir)
    catch e
        return "Error executing command: $(sprint(showerror, e))"
    end

    close(out_pipe.in)
    close(err_pipe.in)

    out_task = @async try
        String(read(out_pipe))
    catch _
        ""
    end
    err_task = @async try
        String(read(err_pipe))
    catch _
        ""
    end

    wait_status = timedwait(() -> !process_running(proc), timeout_val; pollint=0.05)
    if wait_status == :timed_out
        try
            kill(proc)
        catch _
        end
        return "Error: command timed out after $(timeout_val)s"
    end

    stdout_text = fetch(out_task)
    stderr_text = fetch(err_task)
    exit_code = proc.exitcode

    parts = String[]
    isempty(stdout_text) || push!(parts, stdout_text)
    isempty(stderr_text) || push!(parts, "STDERR:\n" * stderr_text)
    push!(parts, "Exit code: $(exit_code)")
    return _truncate_text(join(parts, "\n"), _MAX_EXEC_OUTPUT_CHARS)
end
