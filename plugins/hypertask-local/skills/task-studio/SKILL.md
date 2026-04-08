---
name: task-studio
description: Use when a hypertask <system-reminder> appears announcing pending local-queue tasks. Governs how to surface, claim, work, and complete tasks dispatched from the hypertask web UI.
---

# task-studio

You receive hypertask task dispatches via `<system-reminder>` blocks injected
by the hypertask-peek hook on each user turn. When you see one:

## Hard rules

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

4. **Claim atomically.** When the user says yes, POST to
   `$HYPERTASK_URL/api/local/<dispatch_id>/claim` with body
   `{"sessionId": "<your CLAUDE_SESSION_ID>"}`. Use `$HYPERTASK_TOKEN` as a
   bearer token. If you get HTTP 409, tell the user "looks like another window
   already grabbed it" and continue with whatever you were doing. Do not retry.

5. **On a successful claim**, the response includes the full task payload
   (`{dispatch, task}` with `task.title`, etc.). Work the task as you would any
   user-given task. When done, POST to
   `$HYPERTASK_URL/api/local/<dispatch_id>/complete` with body
   `{"status": "complete", "summary": "<one paragraph of what you did>"}`.
   On failure, post `{"status": "failed", "summary": "<reason>"}`.

6. **If the user says skip/not now**, do nothing. The hook will not re-announce
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
