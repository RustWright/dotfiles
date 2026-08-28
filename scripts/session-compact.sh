#!/bin/bash
# PreCompact hook.
#
# /compact does NOT end the session, so SessionEnd never fires — but /compact is
# the primary checkpoint for big, multi-sitting work, and is often where a device
# handoff happens. This makes a compact a durable, syncable checkpoint: it files
# the readable log-so-far and commits+pushes work in the current repo, EXCLUDING
# submodule pointer bumps (same safety invariant as session-end.sh — a pointer
# bump is an integration action, never a side effect of a checkpoint).

DEBUG_LOG="/tmp/claude-session-compact-debug.log"
echo "=== PreCompact: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The hook hands us JSON on stdin; transcript_path is the authoritative .jsonl for
# THIS session - more reliable than guessing the newest one in the project dir.
HOOK_JSON="$(timeout 2 cat 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$HOOK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)"

# ── cross-device state: memory notes + saved plans (the claude-state repo) ────
# Sits ABOVE the is-this-a-git-repo guard on purpose — memory belongs to the
# session, not the work repo, so it must sync even when Claude was launched
# outside a checkout. None of the submodule-pointer rules apply here: this repo
# has no submodules, so `add -A` is safe. Non-fatal like every other sync step.
STATE="$HOME/.claude"
if [ -d "$STATE/.git" ]; then
  git -C "$STATE" add -A 2>/dev/null || true
  git -C "$STATE" diff --staged --quiet 2>/dev/null || {
    git -C "$STATE" commit -q -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
    git -C "$STATE" push -q 2>/dev/null || echo "WARNING: claude-state push FAILED — memory is committed locally but NOT synced. Fix: git -C $STATE pull --rebase && git -C $STATE push"
  }
fi

git rev-parse --git-dir &>/dev/null || exit 0
CWD="$(git rev-parse --show-toplevel)"

# File the readable log-so-far; surface the one-line result (filed/skipped) to the
# user, keeping full detail (incl. stderr) in the debug log.
python3 "$DOTFILES/file-session-log.py" --repo "$CWD" --transcript "$TRANSCRIPT" 2>>"$DEBUG_LOG" | tee -a "$DEBUG_LOG"

# Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
# tracked parent dirs.
PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
if [ -z "$PARENT" ]; then
  [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
  [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
fi

# Commit WIP in the current repo, excluding submodule pointer changes, and push.
git -C "$CWD" add -A
while IFS= read -r sub; do
  [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

if ! git -C "$CWD" diff --staged --quiet; then
  git -C "$CWD" commit -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')"
  git -C "$CWD" push 2>/dev/null || echo "WARNING: push FAILED in $CWD — work is committed locally but NOT on the remote (usually the branch moved on another device). Fix: git -C $CWD pull --rebase && git -C $CWD push"
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
    git -C "$PARENT" push 2>/dev/null || echo "WARNING: parent push FAILED in $PARENT — pointer/log commit is local only. Fix: git -C $PARENT pull --rebase && git -C $PARENT push"
  }
fi
