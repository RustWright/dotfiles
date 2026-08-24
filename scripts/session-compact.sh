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

git rev-parse --git-dir &>/dev/null || exit 0
CWD="$(git rev-parse --show-toplevel)"

# File the readable log-so-far.
python3 "$DOTFILES/file-session-log.py" --repo "$CWD" >> "$DEBUG_LOG" 2>&1 || true

# Root/parent session: mirror the gitignored .log/ into tracked logs/root/.
PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
if [ -z "$PARENT" ] && [ -d "$CWD/.log" ]; then
  mkdir -p "$CWD/logs/root"
  cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true
fi

# Commit WIP in the current repo, excluding submodule pointer changes, and push.
git -C "$CWD" add -A
while IFS= read -r sub; do
  [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

if ! git -C "$CWD" diff --staged --quiet; then
  git -C "$CWD" commit -m "auto: compact checkpoint $(date '+%Y-%m-%d %H:%M')"
  git -C "$CWD" push 2>/dev/null || true
fi

# Submodule session: copy logs to the parent (pointer bump stays deliberate — run
# sync_pointers.py to integrate, never automatically on a checkpoint).
if [ -n "$PARENT" ] && [ -d "$CWD/.log" ]; then
  PROJECT="$(basename "$CWD")"
  mkdir -p "$PARENT/logs/$PROJECT"
  cp -r "$CWD/.log/." "$PARENT/logs/$PROJECT/" 2>/dev/null || true
  git -C "$PARENT" add -- "logs/$PROJECT" 2>/dev/null || true
  git -C "$PARENT" diff --staged --quiet || {
    git -C "$PARENT" commit -m "auto: compact log sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
    git -C "$PARENT" push 2>/dev/null || true
  }
fi
