#!/bin/bash
# SessionEnd hook — a LAUNCHER. The work lives in session-work.sh.
#
# ── WHY THIS FILE IS NINE LINES LONG ─────────────────────────────────────────────
# This hook is killed roughly ONE SECOND after it starts, wherever it happens to be.
# That is the real invariant, and it took four recurrences to see it, because each fix
# named the place the previous failure had landed:
#
#   2026-08-30  "it dies in the push"        → moved the pushes below the log filing.
#                                              Cost: six session logs.
#   2026-08-31  "it dies in the push"        → hoisted all filing above all pushes.
#                                              Cost: NEXT.md written but UNCOMMITTED.
#   2026-09-03  "it dies in the FIRST push"  → detached the network phase (af69170).
#                                              Cost: the work repo left unpushed.
#   2026-09-03  and then it died in the LOCAL phase, which that fix had declared safe:
#               an omni-me session filed its log at 18:38:36.664, staged both repos, and
#               was killed inside public-gate.sh before ever reaching the commit.
#
# Three orderings and one partial detach, each moving the failure one step. Nothing that
# remains in this hook's lifetime is safe, however cheap it looks — the 18:38 run spent
# 0.65s of its budget just rendering a 4MB transcript, and the run at 12:29:09 the same
# day died in `timeout 2 cat` before filing anything at all.
#
# So the hook now hands EVERYTHING off and exits. `setsid --fork` puts the worker in a
# new session and process group, which a process-group kill aimed at this hook cannot
# reach. Both halves of that invocation are load-bearing, and both are old lessons:
#   - `--fork` guarantees setsid forks rather than exec'ing in place (which would block
#     this hook and defeat the whole point).
#   - NO trailing `&`. A backgrounded `setsid ... &` forks a subshell that still belongs
#     to THIS process group until setsid() actually runs; a kill in that window takes the
#     worker with it. Measured 2026-09-03: with `&` the child was killed before it
#     started; with `--fork` it survived its launcher being SIGKILLed.
#   - NO `</dev/null`. The worker must INHERIT fd 0 to read the hook JSON after this
#     process is gone. If it comes back empty the worker falls back to the newest
#     transcript for the repo, so this is a soft dependency, not a hard one.
#
# DO NOT move work back up here. The next thing left in this hook is the next thing lost.

DEBUG_LOG="/tmp/claude-session-end-debug.log"
echo "=== SessionEnd: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── which repo does this session belong to? ANCHOR, never the inherited cwd ──────
# The Bash tool keeps ONE shell cwd for a whole session, so a `cd` in any command
# persists into this hook. On 2026-09-03 a parent session's last command was
# `cd setup_files/dotfiles && git pull`; the bare `git rev-parse` that used to live here
# read that leftover cwd, concluded the session belonged to the dotfiles SUBMODULE, and
# every step downstream inherited the lie — a private workspace transcript was filed,
# committed and PUSHED to a PUBLIC repo.
#
# $CLAUDE_PROJECT_DIR is documented as "the project root where the session started" and
# explicitly stays put when Claude changes directory. The hook JSON's `cwd` field is NOT
# a substitute — the docs say it follows Claude and reports the directory after a `cd`,
# i.e. the identical wrong value. Resolved HERE rather than in the worker so the log
# records it even if the worker never starts.
ANCHOR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[ -d "$ANCHOR" ] || ANCHOR="$(pwd)"
echo "anchor=$ANCHOR (CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-unset}) pwd=$(pwd)" >> "$DEBUG_LOG"

setsid --fork "$DOTFILES/session-work.sh" end "$ANCHOR" >>"$DEBUG_LOG" 2>&1

exit 0
