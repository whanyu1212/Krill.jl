# Tool Usage Notes

Tool signatures are provided automatically via function calling.
This file documents non-obvious constraints, best practices, and patterns that go beyond the schema.

---

## read_file
- Returns numbered lines in `N| content` format.
- Default limit is 2,000 lines. For large files, paginate with `offset` and `limit`.
- When you get a truncation notice like `(Showing lines 1-2000 of 5432. Use offset=2001 to continue.)`, follow the hint.
- Relative paths resolve against the workspace root. Absolute paths work if filesystem access is unrestricted.
- Read before you edit — `edit_file` requires matching exact text that exists in the file.

## write_file
- Overwrites the entire file. Creates parent directories automatically.
- For surgical changes, prefer `edit_file` over `write_file` — it's safer and shows intent.
- If workspace restriction is on, writes outside the workspace will fail.

## edit_file
- Performs exact string replacement: `old_text` → `new_text`.
- If `old_text` appears more than once and `replace_all` is not set, the edit is rejected with a warning. Either provide more surrounding context to make the match unique, or set `replace_all=true`.
- Always read the file first to get the exact text. Do not guess indentation or whitespace.
- For renaming a variable across a file, use `replace_all=true`.

## delete_file
- Deletes a single file from the workspace.
- Fails clearly if the file does not exist — no silent no-ops.
- Respects workspace restriction — cannot delete files outside the workspace if restriction is on.
- Prefer this over `exec rm` for workspace file deletions.

## move_file
- Moves or renames a file or directory. Works across directories within the workspace.
- `src` and `dst` are both required. Creates parent directories of `dst` automatically.
- Overwrites `dst` if it already exists (`force=true`).
- Use for: renaming files, reorganizing workspace structure.

## search_files
- Searches for a regex pattern across all files in a directory (recursive by default).
- Returns matching lines in `path:lineno: content` format — same as `grep -rn`.
- `glob` parameter filters by filename pattern, e.g. `*.jl`, `*.py`, `*.md` (default `*`).
- `case_sensitive` defaults to true. Set to false for case-insensitive search.
- `max_results` defaults to 50. Increase if you need more matches.
- Use this instead of `exec grep` — it respects workspace restrictions and is safer.
- Examples:
  - Find all uses of a function: `pattern="my_function"`, `glob="*.jl"`
  - Find TODOs: `pattern="TODO|FIXME"`, `glob="*.jl"`
  - Case-insensitive search: `pattern="error"`, `case_sensitive=false`

## list_dir
- Default limit is 200 entries. Set `max_entries` higher if you need a full listing.
- `recursive=true` walks subdirectories (sorted). Useful for understanding project structure.
- Directories are suffixed with `/` in the output.
- Relative paths resolve against the workspace root.

---

## Web search (provider-native)
- The provider's built-in search (OpenAI `web_search` / Gemini `googleSearch`) is the **primary** way to search the web. It returns rich results with snippets and citations.
- Use for: factual lookups, current events, research questions, finding documentation.
- You do NOT need to call `web_fetch` after a provider search — results already include content.
- If the provider search returns poor or insufficient results, delegate a deeper search to `claude_code` or `codex` — they have their own built-in web search and can perform multi-step research.

## web_fetch
- Fetches a specific URL and converts HTML to simplified markdown. Non-HTML content is returned raw.
- Use when: a user shares a link and asks you to read it, or you need the full content of a specific page that search snippets don't cover.
- Do NOT use `web_fetch` as a replacement for search — use provider-native search for discovery, and `web_fetch` only for targeted URL reads.
- Default character limit is 8,000. Set `max_chars` higher if you need more content.
- SSRF protection blocks private IPs, localhost, and link-local addresses. This also applies to redirects.
- Timeouts after 15 seconds. If a page is slow, it may fail.
- For certificate errors on HTTPS, the runtime can optionally allow insecure fetches via `KRILL_WEB_FETCH_ALLOW_INSECURE=1`.

---

## exec
- Runs a shell command via `/bin/sh -lc` (login shell, inherits user profile).
- Default timeout: 60 seconds. Override with the `timeout` parameter.
- Output (stdout + stderr combined) is truncated at 10,000 characters.
- **Security denylist** — the following patterns are blocked: `rm -rf`, `dd` to devices, `mkfs`, `fdisk`, `sudo rm/dd/chmod 777`, fork bombs, `shutdown`/`reboot`, overwriting `/etc/passwd` etc.
- URLs in commands are validated against SSRF rules (same as `web_fetch`).
- `working_dir` defaults to the workspace. Can be set to any allowed directory.
- Use for: running tests, git commands, building projects, checking system state.
- Do NOT use exec to run `gh` commands — use the `github` tool instead.

---

## github
- Wraps `gh` CLI. The `gh` prefix is optional in the command string.
- Requires `gh` to be installed and authenticated (`gh auth login`).
- Timeout: 30 seconds. Output truncated at 10,000 characters.

### Output control
- **Always prefer `--json` output** for structured, compact results. Plain text tables waste tokens.
- Use `--json field1,field2` to select only the fields you need.
- Chain with `--jq '.[]'` to filter/transform JSON output.
- Use `--limit N` to cap result count and stay within the 10k char limit.

### Common patterns

**Repository info:**
```
gh repo view owner/repo
gh repo view owner/repo --json name,description,defaultBranchRef,issues,pullRequests
gh repo list OWNER --json name,description,updatedAt --limit 20
```

**Issues:**
```
gh issue list -R owner/repo --state open --json number,title,labels,assignees --limit 20
gh issue list -R owner/repo --label "bug" --json number,title,createdAt
gh issue view 123 -R owner/repo --json title,body,comments
gh search issues "query" --repo owner/repo --state open
gh search issues "query" --owner ORG --state open --json repository,title,url
```

**Pull requests:**
```
gh pr list -R owner/repo --state open --json number,title,author,reviewDecision,updatedAt
gh pr view 456 -R owner/repo --json title,body,reviews,statusCheckRollup
gh pr checks 456 -R owner/repo
gh search prs "query" --repo owner/repo --state open
```

**Notifications and activity:**
```
gh api notifications --jq '.[].subject | {title, type, url}'
gh api repos/owner/repo/events --jq '.[0:5] | .[].type'
gh api repos/owner/repo/commits --jq '.[0:5] | .[] | {sha: .sha[0:7], message: .commit.message}'
```

**API calls (for anything `gh` doesn't cover):**
```
gh api repos/owner/repo
gh api repos/owner/repo/issues --jq '.[].title'
gh api repos/owner/repo/pulls --jq '.[] | {number, title, user: .user.login}'
gh api users/USERNAME
gh api search/repositories?q=QUERY --jq '.items[0:5] | .[].full_name'
```

### Tips
- For checking if a repo has issues/PRs, use `gh repo view -R owner/repo --json hasIssuesEnabled,openIssues` or `gh api repos/owner/repo --jq '{issues: .open_issues_count, has_issues: .has_issues}'`.
- To scan multiple repos: `gh repo list OWNER --json name,openIssues --limit 50 --jq '.[] | select(.openIssues > 0)'`.
- GitHub GraphQL is available via `gh api graphql -f query='...'` for complex queries.
- If a command returns nothing, check that the repo name and owner are correct.

---

## google_workspace
- Wraps `gws` CLI (Google Workspace CLI). The `gws` prefix is optional.
- Requires `gws` to be installed (`npm install -g @googleworkspace/cli`) and authenticated (`gws auth setup` or `gws auth login`).
- Timeout: 30 seconds. Output truncated at 10,000 characters.
- Supports all Google Workspace APIs: Gmail, Calendar, Drive, Sheets, Docs, etc.

### Gmail shortcuts
- `gws gmail +send --to EMAIL --subject "..." --body "..."` — send email (supports `--cc`, `--bcc`)
- `gws gmail +triage` — show unread inbox summary
- `gws gmail +reply --id MSG_ID --body "..."` — reply to a message
- `gws gmail +reply-all --id MSG_ID --body "..."` — reply all
- `gws gmail +forward --id MSG_ID --to EMAIL` — forward a message
- `gws gmail +watch` — stream new emails as NDJSON

### Gmail API commands
- `gws gmail messages list --userId me --q "is:unread"` — search/list messages
- `gws gmail messages get --userId me --id MSG_ID --format full` — read a message
- `gws gmail labels list --userId me` — list labels

### Other services
- Calendar: `gws calendar events list --calendarId primary --timeMin "..." --maxResults 10 --orderBy startTime --singleEvents true`
- Drive: `gws drive files list --q "name contains 'report'" --fields "files(id,name,mimeType)"`
- General: `gws <service> <resource> <method> [--param value ...]`

### Tips
- Message IDs come from `+triage` or `messages list` output. Use them for reply/forward.
- Gmail search syntax for `--q`: `is:unread`, `from:`, `subject:`, `newer_than:`, `has:attachment`, etc.
- For long email bodies, compose the text carefully — the entire command runs in a single shell invocation.

---

## claude_code
- Delegates a coding task to an autonomous Claude Code agent subprocess.
- Requires `claude` CLI to be installed and authenticated.
- Pre-flight rate limit check runs before each invocation. If rate-limited, the reset time and status are reported — do not retry immediately.
- Returns: result text, cost in USD, and a session ID.
- **Session resume**: pass `session_id` from a previous result's `[Session: ...]` field to continue that conversation. Or set `resume=true` to continue the most recent session in the workspace.
- Budget cap is enforced per invocation.
- Best for: multi-file changes, refactors, writing features, debugging, running tests. Anything that would take you many tool calls.
- Always report cost, session ID, and rate limit status back to the user.

## codex
- Delegates a coding task to an autonomous Codex (OpenAI) agent subprocess.
- Requires `codex` CLI to be installed and authenticated.
- No programmatic rate limit checking — errors are relayed if limits are hit.
- Returns: result text, token usage (input/output/cached), and a thread ID.
- Set `resume=true` to continue the most recent Codex session.
- Runs in sandboxed mode (workspace-write) by default.
- Use when Claude Code is rate-limited, or for a second opinion.
- Always report token usage and thread ID back to the user.

---

## message
- Sends a message to a specific chat by `chat_id`.
- `disable_web_page_preview=true` prevents link previews (useful for Telegram).
- Only works when a send function is configured by the channel (e.g., Telegram, Discord).
- Use to proactively notify users, deliver results from background tasks, or communicate across sessions.

---

## spawn / spawn_list / spawn_cancel
- `spawn` launches a background subagent with its own LLM conversation loop.
- Subagents have access to: file tools, web tools, exec — but NOT spawn, message, or cron (no recursion).
- Results are automatically announced back to the originating chat when complete.
- Use for: parallel research, long file operations, tasks that can run independently.
- `spawn_list` shows all subagent tasks with their status and elapsed time.
- `spawn_cancel` stops a running subagent by its task ID.
- Concurrent limit applies (default 5). If at capacity, wait for existing tasks to finish.

---

## cron_add / cron_list / cron_remove
- `cron_add` schedules a recurring or one-shot task. The prompt fires as if a user sent it.
- Schedule types:
  - `at` — one-shot at an ISO datetime (e.g., `2026-03-25T09:00:00`)
  - `every` or `interval` — recurring interval (e.g., `30s`, `5m`, `2h`)
  - `cron` — standard 5-field cron expression (e.g., `0 9 * * 1-5` for weekdays at 9am)
- Channel, session_key, and chat_id are auto-detected from the current conversation.
- Use `cron_list` to see all jobs with status, fire count, and last fired time.
- Use `cron_remove` with the job label to delete a scheduled job.
- Do NOT schedule via `exec` — always use the cron tools directly.
- Cron jobs cannot recursively schedule more cron jobs.

---

## read_skill
- Loads the full instructions from a SKILL.md file by name.
- Available skills are listed in the tool description and the system prompt skills summary.
- Skills marked `[unavailable]` are missing required binaries or env vars.
- Use when a task matches a skill's domain — the skill provides detailed, domain-specific instructions.
- Skills are discovered from the workspace `skills/` directory, the built-in skills directory, and the ClawHub verified store.

---

## clawhub_search
- Searches the ClawHub public skill registry by natural language query (vector similarity).
- Returns matching skills with name, slug, description, author, downloads, and stars.
- Use to discover community skills that might help with the current task.
- The slug is the identifier used with `clawhub_install`.

## clawhub_install
- Installs a skill from ClawHub into the local verified store.
- **Security pipeline:** Download → quarantine → validation gate → verified store (or rejection).
- The validation gate checks:
  - Content scanning for dangerous patterns (shell code, `run()`, `ENV[]`, `@eval`, `ccall`, etc.)
  - Metadata validation (SKILL.md exists with description in frontmatter)
  - Popularity thresholds (configurable minimum downloads/stars)
  - Allow/blocklist (configurable by slug or author)
- If validation passes, the skill is promoted to the verified store and immediately available via `read_skill`.
- If validation fails, the skill is rejected and removed. The failure reasons are reported.
- Do NOT use `exec npx clawhub install` — it bypasses the security pipeline. Always use this tool.
- Pass `version` to install a specific version; defaults to "latest".

## clawhub_remove
- Removes a skill from the local verified store.
- Use when a skill is no longer needed or to clean up the store.

## clawhub_list
- Lists all skills in the local store with their status (verified, quarantined, rejected), version, author, and install date.
- Use to check what skills are currently installed.
