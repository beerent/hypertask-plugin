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

# Validate JSON shape.
COUNT=$(echo "$RESPONSE" | jq -r '.dispatches | length' 2>/dev/null) || exit 0

# Read latest version from response for the update nag (may be null/missing
# if the server hasn't been upgraded yet — treat as "no update available").
LATEST_VERSION=$(echo "$RESPONSE" | jq -r '.latestPluginVersion // empty' 2>/dev/null || echo "")

if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
  exit 0
fi

# Per-session announce-state file.
STATE_DIR="$HOME/.claude/hypertask"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
STATE_FILE="$STATE_DIR/announced-$CLAUDE_SESSION_ID.json"
[ -f "$STATE_FILE" ] || echo "[]" > "$STATE_FILE"

# Filter out dispatches we've already announced in this session.
NEW=$(jq --slurpfile seen "$STATE_FILE" \
  '.dispatches | map(select(.id as $id | ($seen[0] | index($id) | not)))' \
  <<<"$RESPONSE")

NEW_COUNT=$(echo "$NEW" | jq 'length')
[ "$NEW_COUNT" = "0" ] && exit 0

# Append the new ids to state.
jq --argjson new "$NEW" '. + ($new | map(.id))' "$STATE_FILE" > "$STATE_FILE.tmp" \
  && mv "$STATE_FILE.tmp" "$STATE_FILE"

# Build the update-nag line if server reports a newer version.
# Simple string inequality — don't try to parse semver in shell. If the
# user is on an unexpectedly-new version, the nag fires once and is
# harmless; normally the server is always at or ahead of the user.
UPDATE_NAG=""
if [ -n "$LATEST_VERSION" ] && [ "$PLUGIN_VERSION" != "unknown" ] && [ "$PLUGIN_VERSION" != "$LATEST_VERSION" ]; then
  UPDATE_NAG="
⚠ hypertask-local update available: you're on $PLUGIN_VERSION, latest is $LATEST_VERSION.
Run: /plugin marketplace update hypertask"
fi

# Print the system reminder.
# We emit an explicit curl template (with the Authorization header) rather
# than describing the API abstractly, because without the header Claude's
# first claim call 401s and has to retry — a wasted round-trip the user
# sees as a broken "first attempt." $HYPERTASK_URL and $HYPERTASK_TOKEN
# are escaped as literal shell-variable references so Claude runs them
# through its own shell at curl time (both are already exported in the
# shell that launched Claude Code).
TITLES=$(echo "$NEW" | jq -r '.[] | "  - \"\(.title)\" (dispatch_id: \(.id))"')
cat <<EOF
<system-reminder>
hypertask: $NEW_COUNT pending task(s) sent to your local queue:
$TITLES
$UPDATE_NAG

Per the task-studio skill, offer to pick these up — but ONLY after you finish
whatever the user is currently asking about. Never abandon in-progress work.

To claim a task, run:
  curl -sS -X POST "\$HYPERTASK_URL/api/local/<dispatch_id>/claim" \\
    -H "Authorization: Bearer \$HYPERTASK_TOKEN" \\
    -H "Content-Type: application/json" \\
    -d '{"sessionId":"$CLAUDE_SESSION_ID"}'

On success the response body is {dispatch, task} with the full task payload.
When done, POST the same way to .../complete with body:
  {"status":"complete","summary":"<one paragraph of what you did>"}
On failure: {"status":"failed","summary":"<reason>"}.
</system-reminder>
EOF
exit 0
