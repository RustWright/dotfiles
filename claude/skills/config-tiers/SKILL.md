---
name: config-tiers
description: Where Claude Code config belongs - permission tiering by reversibility, the no-absolute-paths rule for the synced global tier, and the shared enabledPlugins union. Load before adding or moving a permission, editing settings.json or settings.local.json, or enabling a plugin, including when the update-config skill is handling the mechanics.
allowed-tools: Read, Edit, Write, Grep, Glob
---

# Claude Code config: which tier, and why

This is the *placement* doctrine. `update-config` covers the mechanics of editing
`settings.json`; this covers deciding **which file the entry goes in** and the two
cross-device traps that make a wrong choice fail silently.

Lived in `~/.claude/rules/claude-config.md` until 2026-09-04. It moved here because it
fires only when config is actually being edited — rarely — and the global rules tier is
paid on every session in every project on both devices.

## Permissions sort by reversibility

- **Reversible, non-destructive, path-agnostic → global `~/.claude/settings.json`** (synced):
  research MCP, read-only shell, `git add|pull|commit`.
- **Destructive (`rm`, `rebase`), outward-facing (`push`), arbitrary-exec (`cargo run`,
  `npm run`, `curl *`), or project-specific → that project's
  `.claude/settings.local.json`** (per-device, gitignored).

The test is not "will I use this often" but "what happens if this fires when I did not
expect it to."

## Never put an absolute path in the global tier

This user's home directory differs across devices (`/home/efe` vs `/home/me`). An
absolute-path permission written on one machine **silently fails to match** on the other —
no error, the permission simply never applies, and the prompt reappears on a machine where
the user believes they already granted it. Use `~/` or a relative pattern.

The same trap applies to any synced config that names a path, not just permissions. A
tracked `settings.local.json` full of `/home/efe/...` entries is the known failure case.

## `enabledPlugins` is one shared union, not a per-device list

The user works the same projects from several machines. Per-device plugin lists would mean
re-enabling everything twice and tracking which is where. Add to the tracked
`settings.json` and let it propagate. If a plugin is genuinely too heavy to run everywhere,
raise it as a decision rather than silently forking the config.

## Re-read immediately before every write

Approvals auto-accumulate raw into whichever file is active. An entry can be added by a
stray click *while you are mid-edit*, so a write based on a stale read silently drops it.
Re-read the file immediately before writing, and preserve the plugin/marketplace union —
those entries get merged, never clobbered.
