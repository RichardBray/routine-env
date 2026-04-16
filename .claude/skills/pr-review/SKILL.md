---
name: pr-review
description: Review GitHub pull requests autonomously - posts inline review comments with suggested LLM prompts to fix issues. Designed for Claude Code cloud routines (no gh CLI, no interactive auth).
allowed-tools: Bash, Read, Grep, Glob, Agent, WebFetch
---

# PR Review (Autonomous / Cloud)

## Overview

Review a GitHub PR autonomously. Posts inline review comments on the exact lines where issues are found. Each comment includes a suggested prompt (in markdown backticks) the user can give to an LLM to fix the issue.

**Designed for Claude Code cloud routines** — no `gh` CLI required, no interactive auth, no user prompts.

## Environment Detection & Auth

Cloud routines can authenticate to GitHub in two ways. Detect which is available:

```bash
# Check for GITHUB_TOKEN (user-provided PAT in environment config)
if [ -n "$GITHUB_TOKEN" ]; then
  echo "AUTH: Using GITHUB_TOKEN"
  AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
# Check for GH_TOKEN (alternative env var name)
elif [ -n "$GH_TOKEN" ]; then
  echo "AUTH: Using GH_TOKEN"
  AUTH_HEADER="Authorization: token $GH_TOKEN"
else
  echo "ERROR: No GitHub token found. Set GITHUB_TOKEN or GH_TOKEN in your routine's environment config at claude.ai/code/routines."
fi
```

If neither token is set, stop and report the error. Do not proceed.

**Setup note for routine creators:** Add `GITHUB_TOKEN` (a GitHub PAT with `repo` scope) as an environment variable in your routine's cloud environment settings at claude.ai. The cloud environment stores env vars — do NOT wrap values in quotes.

## Inputs

The PR to review comes from one of these sources:

1. **GitHub trigger** — When the routine is triggered by `pull_request.opened` or similar, the PR context is injected into the session prompt automatically. Parse the PR URL from the trigger context.
2. **API trigger** — The caller passes a PR URL or details in the `text` field of the `/fire` request.
3. **Direct prompt** — A PR URL like `https://github.com/owner/repo/pull/123` or owner/repo + PR number in the routine prompt.

Parse `OWNER`, `REPO`, and `PR_NUMBER` from whichever input is available.

## Core Workflow

### Step 1: Fetch PR metadata

```bash
curl -s -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER" \
  | jq '{title: .title, body: .body, head_sha: .head.sha, base_ref: .base.ref, head_ref: .head.ref, user: .user.login}'
```

Save the `head_sha` — needed for posting the review.

### Step 2: Fetch the diff

```bash
curl -s -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3.diff" \
  "https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER"
```

If the diff is very large (>50KB), focus on the most critical files first and paginate.

### Step 3: Fetch changed files

```bash
curl -s -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/files?per_page=100" \
  | jq '.[] | {filename, status, additions, deletions, patch}'
```

For large PRs with 100+ files, paginate with `&page=2`, `&page=3`, etc.

### Step 4: Analyze the code

Read the diff carefully. Look for:

- **Bugs** — logic errors, off-by-one, null/undefined access, race conditions
- **Security issues** — injection, XSS, exposed secrets, missing auth checks
- **Performance problems** — N+1 queries, unnecessary re-renders, missing indexes
- **Error handling gaps** — uncaught exceptions, missing validation at boundaries
- **Breaking changes** — API contract changes, removed exports, changed signatures
- **Test gaps** — untested edge cases, missing error-path tests

Skip: style nitpicks, formatting, naming opinions, import ordering. Focus on things that matter.

### Step 5: Fetch full file content when needed

If the diff context is insufficient to understand the code, the repo is cloned locally in the cloud session. Read the file directly:

```bash
# Option A: Read from the local clone (preferred in cloud routines — repo is already cloned)
cat path/to/file.ts

# Option B: Fetch via API if file isn't in the local clone
curl -s -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/$OWNER/$REPO/contents/$FILE_PATH?ref=$HEAD_SHA"
```

### Step 6: Post the review

Build a JSON payload with all comments and post as a single review.

**CRITICAL: Each comment body MUST include a suggested prompt in triple backticks that the user can give to an LLM to fix the issue.**

#### Comment format

Every review comment must follow this structure:

```
**[Category]** Brief description of the issue.

<explanation of what's wrong and why it matters — 1-3 sentences>

**Suggested prompt to fix:**
\`\`\`
<A self-contained prompt the user can copy-paste to an LLM to fix this specific issue.
Include the file path, line number(s), what's wrong, and what the fix should accomplish.
Be specific enough that an LLM with access to the codebase can act on it without ambiguity.>
\`\`\`
```

Categories: `Bug`, `Security`, `Performance`, `Error Handling`, `Breaking Change`, `Test Gap`, `Suggestion`

#### Example comment body

```
**[Bug]** `getUserById` doesn't handle the case where the user is deleted but still referenced in the cache.

When a user is soft-deleted, cached references remain valid objects with `deletedAt` set. This function returns them as if active, which causes downstream 403s when the returned user object is used for permission checks.

**Suggested prompt to fix:**
\`\`\`
In src/services/user.ts around line 45, the getUserById function returns cached user objects without checking if the user has been soft-deleted. Add a check after the cache lookup: if the user object has a non-null deletedAt field, evict it from the cache and fall through to the database query. If the DB also returns a soft-deleted user, return null instead of the user object.
\`\`\`
```

#### Posting the review via API

Use `jq` to build the JSON payload safely (avoids escaping issues with heredocs):

```bash
# Build comments array with jq
REVIEW_JSON=$(jq -n \
  --arg commit_id "$HEAD_SHA" \
  --arg body "Automated PR review — found N issue(s). Each comment includes a suggested prompt you can use with an LLM to fix the issue." \
  --argjson comments '[
    {
      "path": "src/services/user.ts",
      "line": 45,
      "side": "RIGHT",
      "body": "**[Bug]** ... \n\n**Suggested prompt to fix:**\n```\n...\n```"
    }
  ]' \
  '{commit_id: $commit_id, event: "COMMENT", body: $body, comments: $comments}')

# Post the review
curl -s -X POST \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
  -d "$REVIEW_JSON"
```

**Use `event: "COMMENT"` always** — autonomous reviews should not approve or request changes, only comment.

#### Multi-line comments

For issues spanning multiple lines, add `start_line` and `start_side`:

```json
{
  "path": "src/auth.ts",
  "start_line": 20,
  "start_side": "RIGHT",
  "line": 35,
  "side": "RIGHT",
  "body": "..."
}
```

### Step 7: Verify the review posted

```bash
curl -s -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
  | jq '.[-1] | {id, state, body, submitted_at}'
```

If the POST returned an error, diagnose and retry (see Error Handling).

## Line Number Rules

**CRITICAL:** The `line` field must reference a line that appears in the diff hunk. You cannot comment on lines that aren't part of the diff.

- Use `side: "RIGHT"` for added or modified lines (most common)
- Use `side: "LEFT"` for deleted lines
- The line number is the line number in the file, not the position in the diff

If you need to comment on code that isn't in the diff, use a file-level comment by omitting `line` and `side`.

## If No Issues Found

Post a single review with no inline comments:

```bash
curl -s -X POST \
  -H "$AUTH_HEADER" \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
  -d "{\"commit_id\": \"$HEAD_SHA\", \"event\": \"COMMENT\", \"body\": \"Automated review complete — no issues found. The changes look good.\"}"
```

## Error Handling

- **401/403**: Token is invalid or lacks permissions. Report and stop.
- **404**: PR doesn't exist or repo is private and token lacks access. Report and stop.
- **422 "Validation Failed"**: Usually means a `line` number isn't in the diff. Log the failed comment, adjust line numbers, and retry. If a specific comment keeps failing, fall back to a file-level comment (omit `line`/`side`).
- **422 with "pull_request_review_thread.path diff too large"**: The file diff is too large for inline comments. Use a file-level comment instead.
- **Large PRs (100+ files)**: Paginate the files endpoint. Prioritize reviewing the most impactful files (business logic > config/generated files).

## Cloud Environment Checklist

When setting up this skill as a routine at claude.ai/code/routines:

1. **Environment variables**: Add `GITHUB_TOKEN` with a PAT that has `repo` scope. No quotes around the value.
2. **Network access**: Use "Trusted" (default) — `api.github.com` is on the allowlist.
3. **No setup script needed** — `curl` and `jq` are pre-installed in cloud sessions.
4. **Trigger options**:
   - **GitHub trigger** on `pull_request.opened` for automatic review of new PRs
   - **API trigger** to review PRs on-demand from CI/CD pipelines
   - **Schedule trigger** for periodic review sweeps
5. **Repository**: Add the repo(s) you want reviewed. The repo is cloned each run, so files are available locally.

## Important Notes

- This skill is designed for **autonomous execution** — never use AskUserQuestion
- Always use `event: "COMMENT"` — never approve or request changes autonomously
- Every inline comment **must** include a suggested prompt in triple backticks
- Post **one review** with all comments batched — never post comments individually
- Keep suggested prompts **specific and self-contained** — include file path, line numbers, what's wrong, and what the fix should do
- Use `jq` to build JSON payloads — avoid heredoc escaping issues with comment bodies containing backticks
- The repo is cloned locally in cloud sessions — prefer reading files from disk over API calls
