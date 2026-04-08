# hypertask-plugin

Official Claude Code plugins for [hypertask.app](https://hypertask.app).

Currently ships one plugin:

## hypertask-local

Surfaces tasks queued from the hypertask web UI in your local Claude Code session. Click **→ local** on any task in hypertask, then open Claude Code in the matching repo — Claude's next response will mention the queued task. Say yes, Claude claims it atomically (safe across multiple windows), works it, and reports back.

### Install

The easiest install path is through the hypertask web UI at **Settings → Connect Claude Code** — it generates your API token and gives you the exact paste commands.

If you'd rather install by hand:

```
/plugin marketplace add beerent/hypertask-plugin
/plugin install hypertask-local
```

Then set up your credentials. See the plugin's own [README](plugins/hypertask-local/README.md) for details.

### Update

```
/plugin marketplace update hypertask
/plugin update hypertask-local
```

The plugin reports its installed version back to hypertask on every prompt-submit; you can see which version each of your machines is on at **Settings → Connect Claude Code**.

## License

MIT
