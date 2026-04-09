---
name: task-studio
description: Use when a hypertask <system-reminder> appears announcing pending local-queue tasks. Governs how to surface, claim, work, and complete tasks dispatched from the hypertask web UI.
---

# task-studio

You receive hypertask task dispatches via `<system-reminder>` blocks injected
by the hypertask-peek hook on each user turn. When you see one:

## Hard rules

0. **Always work in a fresh git worktree for code-modifying tasks.** When you claim a task that involves modifying files in the current repo, create a new worktree BEFORE touching anything:

   ```bash
   TASK_ID="<id from claim response>"
   SHORT=$(echo "$TASK_ID" | cut -c1-6)
   SLUG=$(echo "<task title>" | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9-]//g' | cut -c1-40)
   BRANCH="claude/${SLUG}-${SHORT}"
   WORKTREE=".worktrees/claude-${SHORT}"
   git worktree add -b "$BRANCH" "$WORKTREE"
   cd "$WORKTREE"
   ```

   All file edits, test runs, and commits happen inside the worktree. The main worktree is sacrosanct — NEVER modify files outside the worktree you created. When complete, include the branch name and worktree path in your completion payload.

   **Exception:** if the task is pure research, documentation outside the repo, communication (email/Slack/etc), or any work that doesn't modify files in the repo, skip the worktree. Judge per task.

1. **NEVER interrupt in-progress work.** If the user asked you to do something
   in this turn, do that thing FIRST. Mention queued tasks only AFTER you've
   finished responding to what the user actually asked. The queue is not an
   interrupt — it is an "FYI, when you have a moment."

2. **NEVER poll, fetch, peek, or check the queue yourself.** The hook handles
   that automatically on every user prompt. Your only job is to react to
   notifications you've already been given. Do not curl `/api/local/peek`.

3. **Always ask before claiming.** Surface the task to the user with its title
   and ask whether to:
   - pick it up now (interrupt current work — only if the user explicitly says so),
   - pick it up after current work,
   - skip / not now.
   Do not claim until they confirm.

4. **Claim atomically.** When the user says yes, run exactly:

   ```bash
   curl -sS -X POST "$HYPERTASK_URL/api/local/tasks/<task_id>/claim" \
     -H "Authorization: Bearer $HYPERTASK_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"sessionId":"<session id from the reminder>"}'
   ```

   Both `$HYPERTASK_URL` and `$HYPERTASK_TOKEN` are already exported in the shell that launched Claude Code — let the shell expand them; do not hardcode the URL or embed the cleartext token. The `Authorization: Bearer` header is **required** — without it the server returns 401 and the claim silently fails.

   If you get HTTP 409, tell the user "looks like another window already grabbed it" (or "the task isn't in the queue anymore") and continue with whatever you were doing. Do not retry.

5. **On a successful claim**, the response includes the full task payload (`{task, dispatch}`). Work the task inside the worktree you created in rule 0. Commit your work to the branch. When the work is done and tests pass, **push the branch to origin** and then POST to the task's complete endpoint:

   ```bash
   # Inside the worktree:
   git push -u origin "$BRANCH"

   curl -sS -X POST "$HYPERTASK_URL/api/local/tasks/<task_id>/complete" \
     -H "Authorization: Bearer $HYPERTASK_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"status\":\"complete\",\"summary\":\"<one paragraph of what you did>\",\"branchName\":\"$BRANCH\",\"worktreePath\":\"$WORKTREE\"}"
   ```

   The server will automatically open a GitHub pull request from your pushed branch against the project's default branch. The Review card in hypertask will show the PR link, and a GitHub webhook will transition the task's status when the PR is merged (→ complete) or closed without merging (→ backlog, unassigning Claude).

   **You do NOT merge the branch yourself.** Review and merge happen in GitHub. Do not `git merge`, do not `git worktree remove`, do not do any cleanup — the user (or an automated cleanup pass on a future peek) will handle stale worktrees locally when GitHub has deleted the remote branch.

   If the push fails (no network, no remote, permission denied), surface the error to the user and still POST `/complete` with branch info — the server will log the PR-open failure and fall back to the manual Approve/Reject review card so nothing is lost.

   **On failure**, post `{"status":"failed","summary":"<reason>"}` (branch/worktree fields are optional when failing).

6. **If the user says skip/not now**, do nothing. The hook will not re-announce
   this dispatch in the current session. To revisit later, the user can ask
   "what's in my hypertask queue?" and only then may you do a one-shot peek.

## Opt-in continuous mode

If the user explicitly asks to "start listening", "drain the queue", "turn listen mode on", or similar, switch to the sibling `listen-mode` skill. That skill temporarily overrides rules 2 and 3 (allowing direct peeks and auto-claims without per-task confirmation) for the duration of the drain, while keeping every other rule in place — especially Rule 0 (fresh worktree per task) and Rule 4 (atomic claim). Default ambient behavior resumes the moment listen-mode exits.

## Why these rules

- Rule 1 exists because the entire premise of this feature is "ambient, not
  intrusive." If you yank the user away from what they were doing, the feature
  is worse than useless.
- Rule 2 exists because the hook is the polling layer. If you also poll, you
  burn tokens for no benefit and risk announcing the same task twice.
- Rule 3 exists because the user is in charge. You are an offer, not a fait
  accompli.
- Rule 4's atomic semantics exist because there may be multiple Claude Code
  windows in the same repo. The server guarantees only one can claim.
- Rule 5's "push + let the server open a PR" exists because merge decisions
  belong in GitHub, not in a shell script. The PR becomes the durable review
  artifact: CI runs, teammates can comment, merge policy applies, and the
  pull_request webhook closes the hypertask loop automatically.
