#!/usr/bin/env bash
# hypertask-peek.sh — UserPromptSubmit hook for Claude Code.
# Polls hypertask for pending local-task dispatches in the current repo and,
# if any are NEW (not previously announced in this Claude session), prints a
# <system-reminder> block to stdout. Also sends plugin telemetry headers and
# surfaces an update nag if the server reports a newer plugin version.
# Always exits 0; never blocks Claude.

set -u
exit_clean() { exit 0; }
trap exit_clean ERR

# --- Read Claude Code hook input from stdin ---
# Claude Code passes a JSON object to UserPromptSubmit hooks on stdin
# containing at minimum: { session_id, transcript_path, cwd,
# hook_event_name, prompt }. We extract session_id and cwd from there.
# When the hook is run manually (e.g. `bash hypertask-peek.sh` from a
# terminal for debugging), stdin is a terminal and we fall back to env
# vars or defaults.
HOOK_INPUT=""
if ! [ -t 0 ]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
fi

# --- config ---
: "${HYPERTASK_TOKEN:=}"
: "${HYPERTASK_URL:=https://hypertask.app}"

# Resolve the real session id + working dir, preferring stdin JSON over
# env vars. This is critical for two reasons:
#   1. Multi-window dedup — each Claude window gets its own session id,
#      so the per-session announce-state file is distinct per window.
#      Without this, every window shares announced-default.json and a
#      task announced in Window A would be silently deduped in Window B.
#   2. Claim tracking — the sessionId Claude sends on claim becomes
#      claimedBy in the DB, which is how the server knows which window
#      to attribute ownership to. "default" everywhere is useless.
if [ -n "$HOOK_INPUT" ] && command -v jq >/dev/null 2>&1; then
  _sid=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  [ -n "$_sid" ] && CLAUDE_SESSION_ID="$_sid"
  _cwd=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
  [ -n "$_cwd" ] && CLAUDE_PROJECT_DIR="$_cwd"
fi
: "${CLAUDE_SESSION_ID:=default}"
: "${CLAUDE_PROJECT_DIR:=$PWD}"

[ -z "$HYPERTASK_TOKEN" ] && exit 0

# Need git, curl, jq.
command -v git  >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

REPO=$(git -C "$CLAUDE_PROJECT_DIR" remote get-url origin 2>/dev/null) || exit 0
[ -z "$REPO" ] && exit 0

# --- plugin telemetry headers ---
# Read our own version from the bundled plugin.json. CLAUDE_PLUGIN_ROOT is
# set by Claude Code when the hook is invoked as part of a plugin. If we
# can't find it (e.g. manual install), version is "unknown" — still valid
# and the server treats it as an installed_legacy install.
PLUGIN_VERSION="unknown"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]; then
  V=$(jq -r '.version // "unknown"' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null) && PLUGIN_VERSION="$V"
fi
# Platform is just for telemetry — uname -sm gives e.g. "Darwin arm64".
PLUGIN_PLATFORM=$(uname -sm 2>/dev/null | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
: "${PLUGIN_PLATFORM:=unknown}"

# URL-encode the repo. Use jq for portability.
REPO_ENC=$(printf '%s' "$REPO" | jq -sRr @uri)

RESPONSE=$(curl -sS --max-time 1 \
  -H "Authorization: Bearer $HYPERTASK_TOKEN" \
  -H "X-Hypertask-Plugin-Version: $PLUGIN_VERSION" \
  -H "X-Hypertask-Plugin-Platform: $PLUGIN_PLATFORM" \
  "$HYPERTASK_URL/api/local/peek?repo=$REPO_ENC" 2>/dev/null) || exit 0

# --- parse tasks from response ---
COUNT=$(echo "$RESPONSE" | jq -r '.tasks | length' 2>/dev/null) || exit 0

# Read latest version for the update nag.
LATEST_VERSION=$(echo "$RESPONSE" | jq -r '.latestPluginVersion // empty' 2>/dev/null || echo "")

if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
  exit 0
fi

# --- announce state: {task_id: iso-timestamp} ---
STATE_DIR="$HOME/.claude/hypertask"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
STATE_FILE="$STATE_DIR/announced-$CLAUDE_SESSION_ID.json"
[ -f "$STATE_FILE" ] || echo "{}" > "$STATE_FILE"

# Migrate legacy array-format state files (from v1.0.1) to the new
# object format. On first encounter with an array, reset to empty.
FIRST_CHAR=$(head -c 1 "$STATE_FILE" 2>/dev/null)
if [ "$FIRST_CHAR" = "[" ]; then
  echo "{}" > "$STATE_FILE"
fi

# Filter to tasks that are NEW or have a newer updatedAt than what we've
# seen for this task id in the state file. The slurpfile reads the state
# file as a single JSON object; for each task in the response, we compare
# its updatedAt to the value keyed by its id.
NEW=$(jq --slurpfile seen "$STATE_FILE" \
  '.tasks | map(select(
    .id as $id
    | .updatedAt as $u
    | ($seen[0][$id] // "") < $u
  ))' <<<"$RESPONSE")

NEW_COUNT=$(echo "$NEW" | jq 'length')
[ "$NEW_COUNT" = "0" ] && exit 0

# Update the state file with the new (id, updatedAt) pairs.
jq --argjson new "$NEW" \
  '. + ($new | map({(.id): .updatedAt}) | add)' \
  "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

# --- update nag ---
UPDATE_NAG=""
if [ -n "$LATEST_VERSION" ] && [ "$PLUGIN_VERSION" != "unknown" ] && [ "$PLUGIN_VERSION" != "$LATEST_VERSION" ]; then
  UPDATE_NAG="
⚠ hypertask-local update available: you're on $PLUGIN_VERSION, latest is $LATEST_VERSION.
Run: /plugin marketplace update hypertask"
fi

# --- emit system-reminder ---
# Both $HYPERTASK_URL and $HYPERTASK_TOKEN are left as literal shell
# variable references (escaped in the heredoc) so Claude's own shell
# expands them at curl time — token never lands in the reminder text.
TITLES=$(echo "$NEW" | jq -r '.[] | "  - \"\(.title)\" (task_id: \(.id))"')
cat <<EOF
<system-reminder>
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

Before touching any files, create a fresh worktree for this task:
  SHORT=\$(echo <task_id> | cut -c1-6)
  SLUG=\$(echo "<task title>" | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9-]//g' | cut -c1-40)
  git worktree add -b "claude/\${SLUG}-\${SHORT}" ".worktrees/claude-\${SHORT}"
  cd ".worktrees/claude-\${SHORT}"
  # ... do your work in this worktree, commit to the branch, do NOT push ...

When done, POST to complete:
  curl -sS -X POST "\$HYPERTASK_URL/api/local/tasks/<task_id>/complete" \\
    -H "Authorization: Bearer \$HYPERTASK_TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"status":"complete","summary":"<what you did>","branchName":"claude/\${SLUG}-\${SHORT}","worktreePath":".worktrees/claude-\${SHORT}"}'

On failure: same URL, body {"status":"failed","summary":"<reason>"}.
</system-reminder>
EOF
exit 0
