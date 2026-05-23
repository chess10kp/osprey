---
name: commit-review-skill
description: Review git changes for quality and safety, then commit with a conventional message. Use when the user asks to review changes, commit work, or prepare a commit.
---

# Commit Review & Commit Workflow

When the user asks to review and commit git changes, follow these steps in order.

## 1. Inspect changes

Run these in parallel:

```bash
git diff --cached    # staged changes
git diff             # unstaged changes
git status           # untracked files
```

## 2. Review checklist

Review all staged and unstaged changes for:

- Bugs or logic errors
- Security issues (secrets, credentials, API keys in diffs)
- Missing error handling
- Incomplete implementations
- Files that should be in `.gitignore` (build artifacts, `.env`, local config)

Also check `git log -5 --oneline` for the project's commit message convention.

## 3. If no issues found

1. Stage relevant files: `git add .` (or stage specific paths if only part of the work should ship)
2. Confirm what will commit: `git diff --cached`
3. Commit with a descriptive message:
   - If the user provided a commit message argument, use it verbatim
   - Otherwise generate a message following project convention (`feat:`, `fix:`, `docs:`, `refactor:`, etc.)
   - Pass the message via HEREDOC:

```bash
git commit -m "$(cat <<'EOF'
<type>: short summary

Optional body with why, not just what.
EOF
)"
```

4. Show the result: `git log -1 --stat`

**Git safety (never unless the user explicitly asks):**

- Do not update git config
- Do not use `--no-verify`, `--no-gpg-sign`, or force push to `main`/`master`
- Do not amend unless the user requested it and the last commit was yours and unpushed
- Do not commit `.env`, credentials, or other secret files — warn the user instead

## 4. If issues found

Report issues clearly (file, line or hunk, what's wrong). Ask whether to proceed with the commit anyway. Do not commit until the user confirms.

## 5. After committing

Return a brief summary: commit hash, message, files changed, and any follow-up the user might want (e.g. push).
