# hypertask-local

A Claude Code plugin that surfaces tasks queued from the hypertask.app web UI into your local Claude Code session. Click **→ local** on any task in hypertask and Claude will mention it in its next response — claim it atomically (safe across multiple Claude windows), work it, report back.

## Install

The recommended install path is through the hypertask web UI — visit **Settings → Connect Claude Code** on hypertask.app for step-by-step instructions with your personal API key pre-filled. If you prefer to install by hand:

```
/plugin marketplace add hypertask
/plugin install hypertask-local
```

Then set two environment variables in your shell rc so the plugin can reach hypertask:

```bash
export HYPERTASK_TOKEN="ht_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export HYPERTASK_URL="https://hypertask.app"
```

Reload Claude Code. You're done.

## Prerequisites

- `bash`, `curl`, `jq`, `git` on your `$PATH`
- An `ht_*` API key from hypertask **Settings → API Keys**
- A hypertask project with a linked GitHub repo, checked out locally

## How it works

- On every prompt you send to Claude, a small shell hook (`hypertask-peek.sh`, timeout 1s) queries hypertask for pending tasks in the current repo.
- If there are any, Claude's next response mentions them as a `<system-reminder>` — *"By the way, hypertask sent over 'X' — want me to grab it after this?"*
- When you say yes, Claude atomically claims the task (first window to confirm wins; other windows get a graceful `already_claimed` response) and works it, then marks it complete with a summary.
- The hook hard-times-out at 1s and always exits 0, so it can never slow Claude down or block a prompt.

## Multi-window behavior

Multiple Claude Code windows in the same repo each announce a new task **at most once**, in their next turn after the task arrives. Whichever window you say "yes" in first claims it; the others will say "another window grabbed it" if you also confirm there.

## Configuration

The plugin reads two environment variables:

| Var | Default | Purpose |
|---|---|---|
| `HYPERTASK_TOKEN` | *(required)* | Your `ht_*` API key from hypertask Settings → API Keys |
| `HYPERTASK_URL` | `https://hypertask.app` | Base URL of your hypertask server (override for local dev) |

## Updates

Plugins auto-install updates when the marketplace is updated. Run this periodically, or whenever Claude mentions an update is available:

```
/plugin marketplace update hypertask
```

The plugin reports its installed version to hypertask on every peek — you can see which version you're on, and whether there's an update available, at **Settings → Connect Claude Code**.

## Troubleshooting

- **Nothing happens.** Run the hook manually with the same env vars Claude sees:
  ```bash
  HYPERTASK_TOKEN=$HYPERTASK_TOKEN HYPERTASK_URL=$HYPERTASK_URL \
    CLAUDE_PROJECT_DIR=$PWD CLAUDE_SESSION_ID=debug \
    bash ~/.claude/plugins/cache/hypertask/plugins/hypertask-local/hooks/hypertask-peek.sh
  ```
  If silent, there are no pending dispatches matching your repo. If it errors, check that `git remote get-url origin` returns the same URL that the project has linked in hypertask.
- **The hook is slow.** It hard-times-out at 1s. If your hypertask server is consistently slower than that, raise `--max-time` in the script or run hypertask locally.
- **Same task announced in 5 windows.** Expected; bounded to once per window per session. If this is annoying, close the windows you're not using.
- **Update nag keeps appearing.** Run `/plugin marketplace update hypertask` followed by `/plugin update hypertask-local` in Claude Code, then restart.
