#!/bin/bash
# PreCompact hook.
#
# /compact does NOT end the session, so SessionEnd never fires — but /compact is
# the primary checkpoint for big, multi-sitting work, and is often where a device
# handoff happens. This makes a compact a durable, syncable checkpoint: it files
# the readable log-so-far and commits+pushes work in the current repo, EXCLUDING
# submodule pointer bumps (same safety invariant as session-end.sh — a pointer
# bump is an integration action, never a side effect of a checkpoint).
#
# Shares session-end.sh's rule 3 and shared its defects: until 2026-08-31 the mirror
# and the repo commit sat below the claude-state push, so a hook killed in that push
# checkpointed nothing. Since 2026-09-03 the rule is enforced structurally rather than
# by ordering — this script does LOCAL work only and hands the whole network phase to
# session-push.sh. This path is *more* exposed than SessionEnd, not less: a compact is
# where big multi-sitting work and device handoffs get their only durable snapshot.

DEBUG_LOG="/tmp/claude-session-compact-debug.log"
echo "=== PreCompact: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Anchor the session's repo on where the session STARTED, never the shell's cwd —
# session-end.sh rule 4, and the identical defect lived here. The Bash tool keeps
# one cwd per session, so a `cd` in any command leaks into this hook; deriving the
# repo from it makes a parent session that stepped into a submodule check point as
# that submodule. $CLAUDE_PROJECT_DIR is documented to stay at the session's start
# directory; the hook JSON's `cwd` field follows `cd` and is no help. PreCompact is
# MORE exposed than SessionEnd here, not less: a compact is often a big multi-sitting
# checkpoint, so a misfiled one loses more.
ANCHOR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[ -d "$ANCHOR" ] || ANCHOR="$(pwd)"
echo "anchor=$ANCHOR (CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-unset}) pwd=$(pwd)" >> "$DEBUG_LOG"

# The hook hands us JSON on stdin; transcript_path is the authoritative .jsonl for
# THIS session - more reliable than guessing the newest one in the project dir.
HOOK_JSON="$(timeout 2 cat 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$HOOK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)"

# File the readable log-so-far. ORDERING IS LOAD-BEARING — see the long note in
# session-end.sh: this is local and unrecoverable-if-skipped, so it must run
# BEFORE any network I/O. Behind the claude-state push it silently lost six
# session logs on 2026-08-30. The repo guard is DUPLICATED rather than moved, so
# a session launched outside a checkout still falls through to the memory sync.
# Capture-then-emit (not `| tee`) so a closed stdout cannot cost us the record;
# surface the one-line result (filed/skipped) to the user, full detail in the log.
CWD=""
if git -C "$ANCHOR" rev-parse --git-dir &>/dev/null; then
  CWD="$(git -C "$ANCHOR" rev-parse --show-toplevel)"
  FILE_RESULT="$(python3 "$DOTFILES/file-session-log.py" --repo "$CWD" --transcript "$TRANSCRIPT" 2>&1)"
  printf '%s\n' "$FILE_RESULT" >> "$DEBUG_LOG"
  printf '%s\n' "$FILE_RESULT"
fi

# ── LOCAL: mirror logs and COMMIT the checkpoint, before any network I/O ──────
# Rule 3 (see the header). The CWD guard is DUPLICATED as an `if` rather than
# moved up as an early exit, so a session launched outside a checkout still
# reaches the memory sync below.
if [ -n "$CWD" ]; then
  # Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
  # tracked parent dirs.
  PARENT="$(git -C "$CWD" rev-parse --show-superproject-working-tree 2>/dev/null)"
  if [ -z "$PARENT" ]; then
    [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
    [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
  else
    # Submodule session: same mirror into the PARENT's tracked dirs, then STAGED.
    # Local, so rule 3 puts it here; the pusher commits and pushes it. It never
    # bumps the parent's POINTER — a compact is a checkpoint, not an integration.
    PROJECT="$(basename "$CWD")"
    [ -d "$CWD/.log" ] && { mkdir -p "$PARENT/logs/$PROJECT"; cp -r "$CWD/.log/." "$PARENT/logs/$PROJECT/" 2>/dev/null || true; }
    [ -d "$CWD/.curiosities" ] && { mkdir -p "$PARENT/curiosities/$PROJECT"; cp -r "$CWD/.curiosities/." "$PARENT/curiosities/$PROJECT/" 2>/dev/null || true; }
    # TWO adds, not one — `git add -- a b` is atomic, so a missing
    # curiosities/$PROJECT aborted the whole command and staged neither. See the
    # longer note at the same spot in session-end.sh.
    git -C "$PARENT" add -A -- "logs/$PROJECT" 2>/dev/null || true
    git -C "$PARENT" add -A -- "curiosities/$PROJECT" 2>/dev/null || true
  fi

  # Stage WIP, then unstage every submodule path before committing.
  git -C "$CWD" add -A
  while IFS= read -r sub; do
    [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
  done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

  # No "did we commit?" flag: the pusher decides from the branch being ahead of its
  # upstream, which also retries whatever an earlier killed run stranded.
  if ! git -C "$CWD" diff --staged --quiet; then
    git -C "$CWD" commit -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')"
  fi

  # Visibility, NOT automation — see the long note in session-end.sh. A parent
  # session never commits a submodule's own modified files, so that work is
  # stranded on this device unless someone commits it from inside the submodule.
  if [ -z "$PARENT" ]; then
    while IFS= read -r sub; do
      [ -n "$sub" ] || continue
      [ -e "$CWD/$sub/.git" ] || continue
      [ -n "$(git -C "$CWD/$sub" status --porcelain 2>/dev/null)" ] || continue
      printf 'NOTE: %s has uncommitted work — a parent session never commits it, so it will not reach your other device. Commit from inside %s, or let a session running there do it.\n' "$sub" "$sub" | tee -a "$DEBUG_LOG"
    done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
  fi
fi

# ── LOCAL: commit memory notes + saved plans (the claude-state repo) ──────────
# Runs regardless of whether we are in a checkout — memory belongs to the
# session, not the work repo, so it must sync even when Claude was launched
# outside one. None of the submodule-pointer rules apply here: this repo has no
# submodules, so `add -A` is safe. Non-fatal like every other sync step.
# The COMMIT is here; the push is not. See the detach note below.
STATE="$HOME/.claude"
if [ -d "$STATE/.git" ]; then
  git -C "$STATE" add -A 2>/dev/null || true
  git -C "$STATE" diff --staged --quiet 2>/dev/null || \
    git -C "$STATE" commit -q -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
fi

# ── NETWORK: handed to a DETACHED process; this hook is now done ──────────────
# The same session-push.sh that SessionEnd uses, in `compact` mode: it pushes but
# never advances the parent's submodule POINTER, preserving the invariant that a
# checkpoint is not an integration (run sync_pointers.py for that, deliberately).
#
# PreCompact is not a shutdown, so it is not exposed to the kill that forced this
# split in session-end.sh — but sharing the pusher removes a duplicated network
# tail that had already drifted, routes push failures into the debug log instead of
# a stdout nobody reads, and stops a compact blocking the user on three pushes.
#
# `--fork` with no trailing `&` — see the note in session-end.sh: a backgrounded
# `setsid ... &` leaves the child in this process group until setsid() runs, and a
# kill landing in that window takes it down with the hook.
setsid --fork "$DOTFILES/session-push.sh" "$CWD" compact </dev/null >>"$DEBUG_LOG" 2>&1

exit 0
