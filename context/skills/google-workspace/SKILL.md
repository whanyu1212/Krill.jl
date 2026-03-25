---
name: google-workspace
description: "Interact with Google Workspace using the google_workspace tool (gws CLI wrapper). Send, reply, forward, and triage Gmail. Manage Calendar events, Drive files, and any Google Workspace API. Use when the user asks to send emails, check inbox, schedule meetings, or interact with Google services."
requires_bins: gws
---

# Google Workspace

Use the `google_workspace` tool to run `gws` CLI commands. The `gws` prefix is optional.

## Authentication

Before first use, authenticate:
```bash
gws auth setup      # Interactive — creates GCP project + enables APIs (requires gcloud)
gws auth login       # Manual — use existing client_secret.json
```

Credentials are stored encrypted at `~/.config/gws/`. Check auth status:
```bash
gws auth status
```

## Gmail

### Send email
```bash
gws gmail +send --to alice@example.com --subject "Meeting notes" --body "Here are the notes from today..."
```

With CC/BCC:
```bash
gws gmail +send --to alice@example.com --cc bob@example.com --bcc manager@example.com --subject "Update" --body "..."
```

### Triage inbox
Show unread messages (sender, subject, date):
```bash
gws gmail +triage
```

### Reply to a message
```bash
gws gmail +reply --id MESSAGE_ID --body "Thanks, got it."
```

Reply all:
```bash
gws gmail +reply-all --id MESSAGE_ID --body "Sounds good to everyone."
```

### Forward
```bash
gws gmail +forward --id MESSAGE_ID --to bob@example.com
```

### Watch for new emails (streaming)
```bash
gws gmail +watch
```
Returns NDJSON stream of new messages. Useful for monitoring.

### List and search messages
```bash
gws gmail messages list --userId me --q "is:unread"
gws gmail messages list --userId me --q "from:alice@example.com subject:invoice"
gws gmail messages list --userId me --q "newer_than:1d"
```

### Read a specific message
```bash
gws gmail messages get --userId me --id MESSAGE_ID --format full
```

### Labels
```bash
gws gmail labels list --userId me
gws gmail messages modify --userId me --id MESSAGE_ID --addLabelIds LABEL_ID
```

## Calendar

### List upcoming events
```bash
gws calendar events list --calendarId primary --timeMin "2026-03-25T00:00:00Z" --maxResults 10 --orderBy startTime --singleEvents true
```

### Create event
```bash
gws calendar events insert --calendarId primary --summary "Team standup" --start.dateTime "2026-03-26T09:00:00-07:00" --end.dateTime "2026-03-26T09:30:00-07:00"
```

## Drive

### List files
```bash
gws drive files list --q "name contains 'report'" --fields "files(id,name,mimeType)"
```

## General API Pattern

The `gws` CLI supports all Google Workspace APIs dynamically:
```
gws <service> <resource> <method> [--param value ...]
```

Examples:
```bash
gws gmail users getProfile --userId me
gws sheets spreadsheets get --spreadsheetId SHEET_ID
gws docs documents get --documentId DOC_ID
```

## Tips

- For long email bodies, use multi-line strings or compose the body separately.
- Message IDs come from `+triage` or `messages list` output.
- Gmail search syntax (the `--q` flag) follows Gmail's search operators: `is:unread`, `from:`, `subject:`, `newer_than:`, `has:attachment`, etc.
- If `gws` is not found, install with: `npm install -g @googleworkspace/cli`
