#!/bin/bash
# PreCompact hook — a thin wrapper. The work lives in session-work.sh.
#
# /compact does NOT end the session, so SessionEnd never fires — but /compact is the
# primary checkpoint for big, multi-sitting work, and is often where a device handoff
# happens. This makes a compact a durable, syncable checkpoint: it files the readable
# log-so-far and commits+pushes work in the current repo, EXCLUDING submodule pointer
# bumps (a pointer bump is an integration action, never a side effect of a checkpoint).
#
# ── WHY THIS ONE RUNS INLINE AND SessionEnd DOES NOT ─────────────────────────────
# session-end.sh launches the shared worker DETACHED, because that hook is killed about
# a second in (see its header — four recurrences). PreCompact is not a shutdown and is
# not exposed to that kill, so it runs the worker inline and keeps two properties that
# detaching would cost:
#   - the transcript is read before compaction can touch it, rather than racing it;
#   - the user still sees "filed …" and any held-back-file warning, at a moment they are
#     actually looking at the terminal.
# What matters is that both hooks share ONE body. They were near-identical copies and had
# already drifted once — the atomic-`git add` bug had to be fixed in two places.
#
# If PreCompact ever does start getting killed, the fix is one word: change the call
# below to the same `setsid --fork` form session-end.sh uses. Do not re-inline the body.

DEBUG_LOG="/tmp/claude-session-compact-debug.log"
echo "=== PreCompact: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Anchor the session's repo on where the session STARTED, never the shell's cwd. The
# Bash tool keeps one cwd per session, so a `cd` in any command leaks into this hook;
# deriving the repo from it makes a parent session that stepped into a submodule check
# point as that submodule — that is how a private transcript reached a PUBLIC repo on
# 2026-09-03. $CLAUDE_PROJECT_DIR stays at the session's start directory; the hook JSON's
# `cwd` field follows `cd` and is no help. PreCompact is MORE exposed here, not less: a
# compact is often a big multi-sitting checkpoint, so a misfiled one loses more.
ANCHOR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[ -d "$ANCHOR" ] || ANCHOR="$(pwd)"
echo "anchor=$ANCHOR (CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-unset}) pwd=$(pwd)" >> "$DEBUG_LOG"

exec "$DOTFILES/session-work.sh" compact "$ANCHOR"
