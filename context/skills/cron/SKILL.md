---
name: cron
description: Schedule reminders and recurring tasks using cron_add, cron_list, and cron_remove tools. Use when the user asks to set timers, reminders, periodic checks, or any time-based automation.
---

# Cron

Use the `cron_add`, `cron_list`, and `cron_remove` tools to schedule tasks.

## Three Modes

1. **Reminder** — prompt is a message sent to the user at the scheduled time.
2. **Task** — prompt is an instruction the agent executes, then sends the result.
3. **One-shot** — runs once at a specific time using `schedule_type: "at"`.

## Schedule Types

### `at` — one-shot

Fire once at an ISO 8601 datetime (UTC):
```
cron_add(label="meeting reminder", schedule_type="at", schedule_value="2026-03-25T14:00:00", prompt="Remind me about the 2pm meeting")
```

### `every` — recurring interval

Fire repeatedly at a fixed interval. Accepts: `30s`, `5m`, `2h`, `1d`.
```
cron_add(label="break reminder", schedule_type="every", schedule_value="20m", prompt="Time to take a break!")
```

```
cron_add(label="star check", schedule_type="every", schedule_value="10m", prompt="Check Krill.jl GitHub stars and report the count")
```

### `cron` — cron expression

Standard 5-field cron expression (minute hour day-of-month month day-of-week):
```
cron_add(label="weekday standup", schedule_type="cron", schedule_value="0 9 * * 1-5", prompt="Good morning! Time for standup.")
```

## Time Expression Reference

| User says | schedule_type | schedule_value |
|-----------|--------------|----------------|
| every 20 minutes | `every` | `20m` |
| every hour | `every` | `1h` |
| every day at 8am | `cron` | `0 8 * * *` |
| weekdays at 5pm | `cron` | `0 17 * * 1-5` |
| in 30 minutes | `at` | *(compute ISO datetime from current time + 30m)* |
| tomorrow at 9am | `at` | *(compute ISO datetime)* |

## Managing Jobs

List all jobs:
```
cron_list()
```

Remove a job by its UUID (shown in cron_list output):
```
cron_remove(job_id="<uuid>")
```

## Rules

- Always compute absolute ISO datetimes for `at` schedules — never pass relative times.
- Channel, session_key, and chat_id are auto-detected. Do not set them manually.
- Cron jobs cannot schedule more cron jobs (no recursion).
- Do NOT use `exec` to schedule tasks — always use cron tools.
