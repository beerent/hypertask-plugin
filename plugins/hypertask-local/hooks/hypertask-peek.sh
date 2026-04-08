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

# --- config ---
: "${HYPERTASK_TOKEN:=}"
: "${HYPERTASK_URL:=https://hypertask.app}"
: "${CLAUDE_PROJECT_DIR:=$PWD}"
: "${CLAUDE_SESSION_ID:=default}"

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
TITLES=$(echo "$NEW" | jq -r '.[] | "  - \"\(.title)\" (dispatch_id: \(.id))"')
cat <<EOF
<system-reminder>
hypertask: $NEW_COUNT pending task(s) sent to your local queue:
$TITLES
$UPDATE_NAG

Per the task-studio skill, offer to pick these up — but ONLY after you finish
whatever the user is currently asking about. Never abandon in-progress work.
To claim one, POST to $HYPERTASK_URL/api/local/<dispatch_id>/claim with body
{"sessionId": "$CLAUDE_SESSION_ID"}. On success you receive the full task
payload. When done, POST to /complete with {"status": "complete", "summary": "..."}.
</system-reminder>
EOF
exit 0
