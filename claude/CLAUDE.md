## Session Sync — Automatic (do nothing)

Session git sync is handled entirely by hooks in `~/.dotfiles/scripts/`, wired in
`~/.dotfiles/claude/settings.json`. **Do not run any start- or end-of-session git
ritual by hand** — no `git pull` at the start, no `/export`, no commit / push /
parent-sync at the end. Doing it manually now *fights* the hooks. What runs for you:

- **SessionStart** (`session-start.sh`): fast-forwards `~/.dotfiles` itself (so the
  workflow machinery stays current across devices), pulls the `claude-state` repo
  (memory + plans, below), pulls the current repo with `--autostash`, then
  fast-forwards each *clean* submodule and leaves *dirty* ones untouched (never
  strands in-flight work).
- **PreCompact** (`session-compact.sh`) and **SessionEnd** (`session-end.sh`): render
  this session's transcript into a readable `.log/` file, mirror `.log/` and
  `.curiosities/` into the parent's `logs/<project>/` and `curiosities/<project>/`,
  then commit + push work in the current repo — and commit + push `claude-state`.
  Inside a submodule they also advance the parent's pointer — **but only if that
  submodule HEAD is already on its remote.**

**Memory and plans sync too — also automatically.** `~/.claude` is itself a private
git repo (`claude-state`) with a **deny-by-default** `.gitignore`: everything is
ignored except memory notes and `plans/`, so a credential file Anthropic drops in
can never be committed by accident. Never sync memory by hand, and never add to that
allowlist casually — its whole value is that unknown new files stay invisible.

The one thing worth knowing about the layout: memory notes physically live at
`~/.claude/state/memory/<slug>/`, where `<slug>` is the working directory **relative
to `$HOME`**, flattened. The per-device directory Claude Code actually reads
(`~/.claude/projects/<key>/memory`) is a **symlink** onto that slug. This exists
because `<key>` is built from the *absolute* path, which differs per machine
(`/home/efe` vs `/home/me`) — the `$HOME`-relative slug does not. Write to memory
normally; the symlink is transparent.

If SessionStart prints a **`MEMORY MERGE NEEDED`** or **`WARNING`** line about
memory, stop and deal with it: the first means the same note differs on both devices
and the hook refused to pick a winner; the second means memory is not loading at all
this session. Neither is self-healing, by design.

**The invariant behind all of it:** the parent never records a pointer to an unpushed
submodule commit (a dangling gitlink breaks fresh clones and `submodule update`).
That is why pointer integration is *deliberate*, never a side effect of a checkpoint.
To advance parent pointers on purpose, run `~/.dotfiles/scripts/sync_pointers.py`
(`--dry-run` previews; it skips any submodule whose HEAD isn't pushed).

**If you do commit by hand** (e.g. a deliberate mid-session commit): keep the message
a SINGLE LINE under 50 chars — `Session N: topic` or `[type]: description`, no
multi-line, no co-author tags, no emoji. In a *parent* repo never `git add -A` — it
sweeps other projects' submodule pointers into your commit, including backward
pointer regressions for projects you never touched; stage explicit paths only.

## Starting a fresh session: re-verify state, inherit decisions

**Re-verify live state, always.** Run `git status`, read the files you're about to
change, check what actually moved on disk — even when a handoff note, `tasks.md`, or
`project.md` already describes it. Work happens fast between sessions and across
devices, and the written description is often stale. Trust the repo, not the note.

**Inherit settled decisions — don't re-derive them.** Direction, rationale, and
choices a previous session already reached (and the user already agreed to) carry
forward. A handoff exists so you pick up mid-stride, not so you re-open what's closed.
Re-deriving obvious, already-agreed context wastes a session's opening; if a decision
is genuinely unclear or looks contradicted by current state, ask — don't silently
redo it. In short: **state is checked, decisions are inherited.**

## Curiosity Capture

While working on any project, watch for **curiosities** — concepts the user surfaces
but doesn't fully grasp. Triggers:

- User asks "how does X actually work?" or "I don't really get this"
- You half-explain something technical and the user moves on without engaging
- The user pauses on a concept (longer reaction, off-tangent question) suggesting it didn't land

When you notice one, append a one-line entry to the project's curiosity log. Bias
toward capturing — false positives are cheap; missed captures are unrecoverable. The
cycle-close review pass decides what survives. (Syncing the log to the parent is
automatic — the session hooks handle it; you only write the entry.)

**Where to write:** `<project-repo>/.curiosities/<cycle-id>.md`

- Resolve `<cycle-id>` by grepping `project.md` for `Cycle \d+` (matches both `**Status:** Cycle 3 Session 5` and `**Current Phase:** Cycle 2 Session 4`). Use the highest-numbered cycle found. Filename: `cycle-<N>.md`.
- If no `project.md` or no `Cycle \d+` match: filename is `current.md`.
- If the `.curiosities/` directory doesn't exist in the project repo: create it AND add `.curiosities/` to the project's `.gitignore` (mirrors the `.log/` pattern — gitignored in the submodule, parent-synced automatically at session end).

**Entry format:** `- [YYYY-MM-DD] <one-line curiosity>; <one-line trigger context>`

Example: `- [2026-05-15] How do hashes actually work?; came up while implementing SHA-256 upload validation`

This feeds the **concepts** post form on mylearnbase — surviving curiosities at cycle close become candidates for interactive-demo-driven posts. The form is documented in `~/productive_learning/projects/mylearnbase/editorial/concepts.md` for sessions working in that repo.
