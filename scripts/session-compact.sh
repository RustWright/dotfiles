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
# Shares session-end.sh's rule 3 — EVERY LOCAL STEP BEFORE EVERY NETWORK STEP —
# and shared the same defect until 2026-08-31: the mirror and the repo commit sat
# below the claude-state push, so a hook killed in that push checkpointed nothing.
# This path is *more* exposed than SessionEnd, not less: a compact is where big
# multi-sitting work and device handoffs get their only durable snapshot.

DEBUG_LOG="/tmp/claude-session-compact-debug.log"
echo "=== PreCompact: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
if git rev-parse --git-dir &>/dev/null; then
  CWD="$(git rev-parse --show-toplevel)"
  FILE_RESULT="$(python3 "$DOTFILES/file-session-log.py" --repo "$CWD" --transcript "$TRANSCRIPT" 2>&1)"
  printf '%s\n' "$FILE_RESULT" >> "$DEBUG_LOG"
  printf '%s\n' "$FILE_RESULT"
fi

# ── LOCAL: mirror logs and COMMIT the checkpoint, before any network I/O ──────
# Rule 3 (see the header). The CWD guard is DUPLICATED as an `if` rather than
# moved up as an early exit, so a session launched outside a checkout still
# reaches the memory sync below.
COMMITTED=0
if [ -n "$CWD" ]; then
  # Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
  # tracked parent dirs.
  PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
  if [ -z "$PARENT" ]; then
    [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
    [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
  fi

  # Stage WIP, then unstage every submodule path before committing.
  git -C "$CWD" add -A
  while IFS= read -r sub; do
    [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
  done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

  if ! git -C "$CWD" diff --staged --quiet; then
    git -C "$CWD" commit -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')"
    COMMITTED=1
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

# ── cross-device state: memory notes + saved plans (the claude-state repo) ────
# Runs regardless of whether we are in a checkout — memory belongs to the
# session, not the work repo, so it must sync even when Claude was launched
# outside one. None of the submodule-pointer rules apply here: this repo has no
# submodules, so `add -A` is safe. Non-fatal like every other sync step.
# Every push is BOUNDED so a hang costs seconds, never the rest of the script.
STATE="$HOME/.claude"
if [ -d "$STATE/.git" ]; then
  git -C "$STATE" add -A 2>/dev/null || true
  git -C "$STATE" diff --staged --quiet 2>/dev/null || {
    git -C "$STATE" commit -q -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
    timeout 30 git -C "$STATE" push -q 2>/dev/null || echo "WARNING: claude-state push FAILED or timed out — memory is committed locally but NOT synced. Fix: git -C $STATE pull --rebase && git -C $STATE push"
  }
fi

[ -z "$CWD" ] && exit 0

# ── NETWORK: push the checkpoint committed above ──────────────────────────────
# Split from its commit on purpose (rule 3). Also pushes when an EARLIER run
# committed but died before pushing — the state a killed hook leaves behind.
AHEAD="$(git -C "$CWD" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
if [ "$COMMITTED" = 1 ] || [ "${AHEAD:-0}" -gt 0 ]; then
  timeout 30 git -C "$CWD" push 2>/dev/null || echo "WARNING: push FAILED or timed out in $CWD — work is committed locally but NOT on the remote (usually the branch moved on another device). Fix: git -C $CWD pull --rebase && git -C $CWD push"
fi

# Submodule session: copy logs + curiosities to the parent (pointer bump stays
# deliberate — run sync_pointers.py to integrate, never automatically on a checkpoint).
if [ -n "$PARENT" ]; then
  PROJECT="$(basename "$CWD")"
  [ -d "$CWD/.log" ] && { mkdir -p "$PARENT/logs/$PROJECT"; cp -r "$CWD/.log/." "$PARENT/logs/$PROJECT/" 2>/dev/null || true; }
  [ -d "$CWD/.curiosities" ] && { mkdir -p "$PARENT/curiosities/$PROJECT"; cp -r "$CWD/.curiosities/." "$PARENT/curiosities/$PROJECT/" 2>/dev/null || true; }
  git -C "$PARENT" add -- "logs/$PROJECT" "curiosities/$PROJECT" 2>/dev/null || true
  git -C "$PARENT" diff --staged --quiet || {
    git -C "$PARENT" commit -m "auto: compact log sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
    timeout 30 git -C "$PARENT" push 2>/dev/null || echo "WARNING: parent push FAILED or timed out in $PARENT — pointer/log commit is local only. Fix: git -C $PARENT pull --rebase && git -C $PARENT push"
  }
fi
