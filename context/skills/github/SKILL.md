---
name: github
description: "Interact with GitHub using the github tool (gh CLI wrapper). Use for issues, pull requests, CI status, repository info, notifications, and advanced API queries. Trigger when the user mentions GitHub repos, PRs, issues, CI, or asks to check repository activity."
requires_bins: gh
---

# GitHub

Use the `github` tool to run `gh` CLI commands. The `gh` prefix is optional.

Always specify `-R owner/repo` (or `--repo owner/repo`) when not operating on a local git repo.

## Output Control

Prefer `--json` for structured, compact output that stays within the 10k char limit:
```bash
gh issue list -R owner/repo --json number,title,labels --limit 20
```

Chain `--jq` to filter and transform:
```bash
gh issue list -R owner/repo --json number,title --jq '.[] | "\(.number): \(.title)"'
```

Always use `--limit N` to cap results.

## Repository Info

```bash
gh repo view owner/repo
gh repo view owner/repo --json name,description,defaultBranchRef,issues,pullRequests
gh repo list OWNER --json name,description,updatedAt --limit 20
```

Check if a repo has open issues/PRs:
```bash
gh api repos/owner/repo --jq '{issues: .open_issues_count, has_issues: .has_issues}'
```

Scan multiple repos for activity:
```bash
gh repo list OWNER --json name,openIssues --limit 50 --jq '.[] | select(.openIssues > 0)'
```

## Issues

```bash
gh issue list -R owner/repo --state open --json number,title,labels,assignees --limit 20
gh issue list -R owner/repo --label "bug" --json number,title,createdAt
gh issue view 123 -R owner/repo --json title,body,comments
gh search issues "query" --repo owner/repo --state open
gh search issues "query" --owner ORG --state open --json repository,title,url
```

## Pull Requests

```bash
gh pr list -R owner/repo --state open --json number,title,author,reviewDecision,updatedAt
gh pr view 456 -R owner/repo --json title,body,reviews,statusCheckRollup
gh pr checks 456 -R owner/repo
gh search prs "query" --repo owner/repo --state open
```

## CI / Workflow Runs

```bash
gh run list -R owner/repo --limit 10
gh run view <run-id> -R owner/repo
gh run view <run-id> -R owner/repo --log-failed
```

## API for Advanced Queries

Use `gh api` for anything the CLI doesn't cover directly:

```bash
gh api repos/owner/repo/pulls/55 --jq '.title, .state, .user.login'
gh api repos/owner/repo/issues --jq '.[].title'
gh api repos/owner/repo/commits --jq '.[0:5] | .[] | {sha: .sha[0:7], message: .commit.message}'
gh api notifications --jq '.[].subject | {title, type, url}'
gh api search/repositories?q=QUERY --jq '.items[0:5] | .[].full_name'
```

GraphQL is available for complex queries:
```bash
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO") { issues(first:5, states:OPEN) { nodes { title number } } } }'
```
