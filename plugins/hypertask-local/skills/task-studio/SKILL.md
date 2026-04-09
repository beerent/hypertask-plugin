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

   **Never `git push` the branch.** Leave it local. The user decides when and whether to push, merge, or PR.

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

5. **On a successful claim**, the response includes the full task payload (`{task, dispatch}`). Work the task inside the worktree you created in rule 0. Commit your work to the branch. When done, POST to the task's complete endpoint:

   ```bash
   curl -sS -X POST "$HYPERTASK_URL/api/local/tasks/<task_id>/complete" \
     -H "Authorization: Bearer $HYPERTASK_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"status\":\"complete\",\"summary\":\"<one paragraph of what you did>\",\"branchName\":\"$BRANCH\",\"worktreePath\":\"$WORKTREE\"}"
   ```

   On failure, post `{"status":"failed","summary":"<reason>"}` (branch/worktree fields are optional when failing).

6. **Handle worktree cleanup reminders.** The peek hook will sometimes inject a `hypertask cleanup:` block listing worktrees the user previously created whose tasks are now resolved (approved → complete, or acknowledged-after-failure → backlog). The user clicking **Approve** in the web UI is itself the consent — do not ask again before merging or cleaning up. Do this work proactively. For EACH entry, run the steps below in order; if any rail trips, REFUSE cleanup for that entry, surface the reason, and move on. The next prompt will re-emit the reminder once the user fixes things.

   1. **Verify the worktree has no uncommitted changes.** Run `git -C <worktreePath> status --porcelain`. If non-empty, refuse with "leftover changes in `<worktreePath>` — review them before re-approving cleanup."
   2. **Locate and verify the main checkout.** The worktree path is `<main>/.worktrees/claude-<short>`, so `<main>` is the parent of the parent. In the main checkout, run `git symbolic-ref refs/remotes/origin/HEAD --short` (strip the `origin/` prefix) to discover the project's default branch, and `git -C <main> symbolic-ref --short HEAD` to see what's currently checked out. If they don't match, refuse: "main checkout is on `<X>`, expected `<default>` — switch back before re-approving cleanup." Then `git -C <main> status --porcelain` must be empty; otherwise refuse with "main checkout has uncommitted changes."
   3. **Merge the branch into main.** In the main checkout, run `git merge --no-ff <branchName>`. If git reports a conflict, run `git merge --abort` and refuse with "merge conflict on `<branchName>` — resolve manually before re-approving cleanup." On success, do NOT push.
   4. **Remove the worktree.** Run `git worktree remove <worktreePath>` (never `--force`). If git refuses, surface the exact error verbatim.
   5. **Acknowledge the cleanup with the server** so peek doesn't re-announce this entry to other Claude windows:

      ```bash
      curl -sS -X POST "$HYPERTASK_URL/api/local/tasks/<task_id>/cleaned" \
        -H "Authorization: Bearer $HYPERTASK_TOKEN"
      ```

      The endpoint is idempotent — re-posting is harmless.
   6. **Do NOT delete the branch ref** (`git branch -D`) unless the user explicitly asks for it.

   Surface what you did (or refused to do, and why) in plain language in your reply: which worktrees were merged + cleaned, and which were skipped with the rail that tripped.

7. **If the user says skip/not now**, do nothing. The hook will not re-announce
   this dispatch in the current session. To revisit later, the user can ask
   "what's in my hypertask queue?" and only then may you do a one-shot peek.

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
