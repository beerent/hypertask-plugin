#!/usr/bin/env bash
# hypertask-peek.sh — UserPromptSubmit hook for Claude Code.
#
# On every user prompt:
#   1. Polls hypertask for pending tasks assigned to Claude in the current
#      repo. Announces new ones via a <system-reminder>.
#   2. Prunes any local .worktrees/claude-* whose branch no longer exists
#      on origin (merged + deleted by GitHub after the PR was closed).
#      Purely local housekeeping — no API calls involved.
#
# Always exits 0; never blocks Claude.

set -u
exit_clean() { exit 0; }
trap exit_clean ERR

# --- Read Claude Code hook input from stdin ---
HOOK_INPUT=""
if ! [ -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
fi

# --- config ---
: "${HYPERTASK_TOKEN:=}"
: "${HYPERTASK_URL:=https://hypertask.app}"

if [ -n "$HOOK_INPUT" ] && command -v jq >/dev/null 2>&1; then
  _sid=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  [ -n "$_sid" ] && CLAUDE_SESSION_ID="$_sid"
  _cwd=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  [ -n "$_cwd" ] && CLAUDE_PROJECT_DIR="$_cwd"
fi
: "${CLAUDE_SESSION_ID:=default}"
: "${CLAUDE_PROJECT_DIR:=$PWD}"

# Need git, curl, jq for the peek side. The worktree prune only needs git.
command -v git  >/dev/null 2>&1 || exit 0

REPO=$(git -C "$CLAUDE_PROJECT_DIR" remote get-url origin 2>/dev/null) || exit 0
[ -z "$REPO" ] && exit 0

# --- Worktree prune pass ---
# Fetch remote state (pruning deleted refs), then remove any
# .worktrees/claude-* whose branch no longer exists on origin. This is
# how the PR-workflow cleanup happens: GitHub deletes the branch on
# merge (if "auto-delete head branches" is on), the next peek prunes
# the stale worktree locally. Zero product logic, zero API calls.
prune_worktrees() {
  local root
  root=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -d "$root/.worktrees" ] || return 0
  git -C "$root" fetch --prune --quiet 2>/dev/null || return 0

  # For each claude-* worktree, check whether its branch still exists
  # on origin. If not, git worktree remove it (no --force).
  for wt in "$root"/.worktrees/claude-*; do
    [ -d "$wt" ] || continue
    local branch
    branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || continue
    case "$branch" in
      claude/*) ;;
      *) continue ;;
    esac
    # Does the branch still exist on origin?
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      continue
    fi
    # Gone from origin — safe to remove the worktree. Plain (non-force)
    # remove refuses if the worktree has uncommitted changes, which is
    # the behavior we want.
    git -C "$root" worktree remove "$wt" 2>/dev/null || true
  done
}
prune_worktrees

# Everything below is the peek path. Requires curl + jq + a token.
[ -z "$HYPERTASK_TOKEN" ] && exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

# --- plugin telemetry headers ---
PLUGIN_VERSION="unknown"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  V=$(jq -r '.version // "unknown"' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null) && PLUGIN_VERSION="$V"
fi
PLUGIN_PLATFORM=$(uname -sm 2>/dev/null | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
: "${PLUGIN_PLATFORM:=unknown}"

REPO_ENC=$(printf '%s' "$REPO" | jq -sRr @uri)

RESPONSE=$(curl -sS --max-time 1 \
  -H "Authorization: Bearer $HYPERTASK_TOKEN" \
  -H "X-Hypertask-Plugin-Version: $PLUGIN_VERSION" \
  -H "X-Hypertask-Plugin-Platform: $PLUGIN_PLATFORM" \
  "$HYPERTASK_URL/api/local/peek?repo=$REPO_ENC" 2>/dev/null) || exit 0

COUNT=$(echo "$RESPONSE" | jq -r '.tasks | length' 2>/dev/null) || exit 0
LATEST_VERSION=$(echo "$RESPONSE" | jq -r '.latestPluginVersion // empty' 2>/dev/null || echo "")

# --- announce state ---
STATE_DIR="$HOME/.claude/hypertask"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
ANNOUNCED_FILE="$STATE_DIR/announced-$CLAUDE_SESSION_ID.json"
[ -f "$ANNOUNCED_FILE" ] || echo "{}" > "$ANNOUNCED_FILE"

FIRST_CHAR=$(head -c 1 "$ANNOUNCED_FILE" 2>/dev/null)
if [ "$FIRST_CHAR" = "[" ]; then
  echo "{}" > "$ANNOUNCED_FILE"
fi

# Any stale cleaned-*.json files from v1.0.3/1.0.4 are now meaningless —
# best-effort delete them so the state dir doesn't accumulate garbage.
rm -f "$STATE_DIR"/cleaned-*.json 2>/dev/null || true

NEW="[]"
NEW_COUNT=0
if [ -n "$COUNT" ] && [ "$COUNT" != "0" ]; then
  NEW=$(jq --slurpfile seen "$ANNOUNCED_FILE" \
    '.tasks | map(select(
      .id as $id
      | .updatedAt as $u
      | ($seen[0][$id] // "") < $u
    ))' <<<"$RESPONSE")
  NEW_COUNT=$(echo "$NEW" | jq 'length')
  if [ "$NEW_COUNT" != "0" ]; then
    jq --argjson new "$NEW" \
      '. + ($new | map({(.id): .updatedAt}) | add)' \
      "$ANNOUNCED_FILE" > "$ANNOUNCED_FILE.tmp" && \
      mv "$ANNOUNCED_FILE.tmp" "$ANNOUNCED_FILE"
  fi
fi

# --- feedback dedupe (parallel to pending-tasks dedupe) ---
FEEDBACK_COUNT=$(echo "$RESPONSE" | jq -r '.feedback // [] | length' 2>/dev/null || echo "0")
NEW_FEEDBACK="[]"
NEW_FEEDBACK_COUNT=0
if [ -n "$FEEDBACK_COUNT" ] && [ "$FEEDBACK_COUNT" != "0" ]; then
  FEEDBACK_FILE="$STATE_DIR/feedback-announced-$CLAUDE_SESSION_ID.json"
  [ -f "$FEEDBACK_FILE" ] || echo "{}" > "$FEEDBACK_FILE"
  FB_FIRST_CHAR=$(head -c 1 "$FEEDBACK_FILE" 2>/dev/null)
  if [ "$FB_FIRST_CHAR" = "[" ]; then
    echo "{}" > "$FEEDBACK_FILE"
  fi
  NEW_FEEDBACK=$(jq --slurpfile seen "$FEEDBACK_FILE" \
    '.feedback | map(select(
      .taskId as $id
      | .lastFeedbackAt as $u
      | ($seen[0][$id] // "") < $u
    ))' <<<"$RESPONSE")
  NEW_FEEDBACK_COUNT=$(echo "$NEW_FEEDBACK" | jq 'length')
  if [ "$NEW_FEEDBACK_COUNT" != "0" ]; then
    jq --argjson new "$NEW_FEEDBACK" \
      '. + ($new | map({(.taskId): .lastFeedbackAt}) | add)' \
      "$FEEDBACK_FILE" > "$FEEDBACK_FILE.tmp" && \
      mv "$FEEDBACK_FILE.tmp" "$FEEDBACK_FILE"
  fi
fi

# Early-exit only if BOTH are empty.
if [ "$NEW_COUNT" = "0" ] && [ "$NEW_FEEDBACK_COUNT" = "0" ]; then
  exit 0
fi

UPDATE_NAG=""
if [ -n "$LATEST_VERSION" ] && [ "$PLUGIN_VERSION" != "unknown" ] && [ "$PLUGIN_VERSION" != "$LATEST_VERSION" ]; then
  UPDATE_NAG="
⚠ hypertask-local update available: you're on $PLUGIN_VERSION, latest is $LATEST_VERSION.
Run: /plugin marketplace update hypertask"
fi

printf '%s\n' "<system-reminder>"

if [ "$NEW_COUNT" != "0" ]; then
  TITLES=$(echo "$NEW" | jq -r '.[] | "  - \"\(.title)\" (task_id: \(.id))"')
  cat <<EOF
hypertask: $NEW_COUNT pending task(s) assigned to Claude:
$TITLES
$UPDATE_NAG

Per the task-studio skill, offer to pick these up — but ONLY after you finish
whatever the user is currently asking about. Never abandon in-progress work.

To claim a task, run:
  curl -sS -X POST "\$HYPERTASK_URL/api/local/tasks/<task_id>/claim" \\
    -H "Authorization: Bearer \$HYPERTASK_TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"sessionId":"$CLAUDE_SESSION_ID"}'

Before touching any files, create a fresh worktree:
  SHORT=\$(echo <task_id> | cut -c1-6)
  SLUG=\$(echo "<task title>" | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9-]//g' | cut -c1-40)
  git worktree add -b "claude/\${SLUG}-\${SHORT}" ".worktrees/claude-\${SHORT}"
  cd ".worktrees/claude-\${SHORT}"
  # ... do your work, commit to the branch ...

When done, PUSH the branch and POST /complete:
  git push -u origin "claude/\${SLUG}-\${SHORT}"
  curl -sS -X POST "\$HYPERTASK_URL/api/local/tasks/<task_id>/complete" \\
    -H "Authorization: Bearer \$HYPERTASK_TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"status":"complete","summary":"<what you did>","branchName":"claude/\${SLUG}-\${SHORT}","worktreePath":".worktrees/claude-\${SHORT}"}'

The server opens a GitHub PR from the pushed branch. Merge/close happens
in GitHub — do NOT merge or remove the worktree yourself.

On failure: same URL, body {"status":"failed","summary":"<reason>"}.
EOF
fi

if [ "$NEW_FEEDBACK_COUNT" != "0" ]; then
  if [ "$NEW_COUNT" != "0" ]; then
    printf '\n'
  fi
  FEEDBACK_LINES=$(echo "$NEW_FEEDBACK" | jq -r '.[] | "  - \"\(.taskTitle)\" (task_id: \(.taskId), PR #\(.prNumber), feedback at \(.lastFeedbackAt))"')
  cat <<EOF
hypertask: $NEW_FEEDBACK_COUNT task(s) with new PR feedback waiting:
$FEEDBACK_LINES

Per the task-studio skill Rule 5.5, offer to iterate — but only after
you finish whatever the user is currently asking about.

To iterate, re-claim the task (same claim POST as usual). The response
will include \`previousDispatch\` with the existing branchName, worktreePath,
and prNumber — see Rule 0 for how to reuse them in a new worktree attempt.
Before touching code, fetch the feedback:
  curl -sS "\$HYPERTASK_URL/api/local/tasks/<task_id>/pr-feedback" \\
    -H "Authorization: Bearer \$HYPERTASK_TOKEN"
EOF
fi

printf '%s\n' "</system-reminder>"
exit 0
