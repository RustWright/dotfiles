#!/bin/bash
# SessionEnd hook: file the readable session log, commit work in the current repo
# (never sweeping submodule pointers), and — inside a submodule — sync logs to the
# parent and record the submodule pointer ONLY if it is already pushed.
#
# Two independent safety rules, both learned the hard way:
#   1. A root/parent session must NOT auto-commit submodule pointer bumps. A bare
#      `git add -A` in the parent stages every dirty gitlink, recording a pointer
#      to an unpushed (or unrelated, in-flight) submodule commit — a dangling
#      gitlink that breaks fresh clones and `submodule update`. So we stage work
#      but then unstage every submodule path before committing.
#   2. A submodule session MAY advance the parent's pointer, but only when that
#      submodule HEAD is already on its remote (else the same dangling gitlink).
#      That guarded bump is a deliberate integration; the sweep in rule 1 is not.

DEBUG_LOG="/tmp/claude-session-end-debug.log"
echo "=== SessionEnd: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git rev-parse --git-dir &>/dev/null || exit 0
CWD="$(git rev-parse --show-toplevel)"

# ── file the readable log-so-far (replaces the manual /export ritual) ──────────
python3 "$DOTFILES/file-session-log.py" --repo "$CWD" >> "$DEBUG_LOG" 2>&1 || true

PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"

# Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
# tracked parent dirs (same convention the manual protocol used — these dirs are
# parent-synced, never committed inside the project).
if [ -z "$PARENT" ]; then
  [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
  [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
fi

# ── commit work in the current repo, EXCLUDING submodule pointer bumps (rule 1)
git -C "$CWD" add -A
while IFS= read -r sub; do
  [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

if ! git -C "$CWD" diff --staged --quiet; then
  git -C "$CWD" commit -m "auto: session end $(date '+%Y-%m-%d %H:%M')"
  git -C "$CWD" push 2>/dev/null || true
fi

# ── submodule session: sync logs to the parent + guarded pointer bump (rule 2) ─
[ -z "$PARENT" ] && exit 0

PROJECT="$(basename "$CWD")"
[ -d "$CWD/.log" ] && { mkdir -p "$PARENT/logs/$PROJECT"; cp -r "$CWD/.log/." "$PARENT/logs/$PROJECT/" 2>/dev/null || true; }
[ -d "$CWD/.curiosities" ] && { mkdir -p "$PARENT/curiosities/$PROJECT"; cp -r "$CWD/.curiosities/." "$PARENT/curiosities/$PROJECT/" 2>/dev/null || true; }
git -C "$PARENT" add -A -- "logs/$PROJECT" "curiosities/$PROJECT" 2>/dev/null || true

# Record THIS submodule's pointer only if its HEAD is present on the remote. A
# successful push updates the local remote-tracking refs; a failed one does not,
# so this fails closed if the push silently died — no network round-trip needed.
SUB_HEAD="$(git -C "$CWD" rev-parse HEAD)"
if [ -n "$(git -C "$CWD" branch -r --contains "$SUB_HEAD" 2>/dev/null)" ]; then
  git -C "$PARENT" add -- "$CWD"
else
  echo "WARNING: $PROJECT HEAD $SUB_HEAD not on remote; pointer NOT recorded" | tee -a "$DEBUG_LOG"
fi

if ! git -C "$PARENT" diff --staged --quiet; then
  git -C "$PARENT" commit -m "auto: sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
  git -C "$PARENT" push 2>/dev/null || true
fi
