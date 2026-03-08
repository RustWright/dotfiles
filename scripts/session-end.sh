#!/bin/bash
# SessionEnd hook: commit current repo, and if inside a submodule, sync logs +
# update the parent repo's submodule pointer automatically.

# ── debug log (remove after confirming hook works) ──────────────────────────
DEBUG_LOG="/tmp/claude-session-end-debug.log"
echo "=== SessionEnd hook fired: $(date) ===" >> "$DEBUG_LOG"
echo "PWD: $(pwd)" >> "$DEBUG_LOG"
echo "CLAUDE_WORKING_DIRECTORY: ${CLAUDE_WORKING_DIRECTORY:-unset}" >> "$DEBUG_LOG"

# ── helpers ──────────────────────────────────────────────────────────────────

commit_and_push() {
  local dir="$1"
  local msg="$2"
  git -C "$dir" add -A
  git -C "$dir" diff --staged --quiet && return 0  # nothing to commit
  git -C "$dir" commit -m "$msg"
  git -C "$dir" push 2>/dev/null || true
}

# ── abort if not in a git repo ────────────────────────────────────────────────

git rev-parse --git-dir &>/dev/null || exit 0

CWD="$(git rev-parse --show-toplevel)"

# ── commit current repo if there are changes ─────────────────────────────────

commit_and_push "$CWD" "auto: session end $(date '+%Y-%m-%d %H:%M')"

# ── submodule handling ────────────────────────────────────────────────────────

PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
[ -z "$PARENT" ] && exit 0  # not a submodule — done

PROJECT="$(basename "$CWD")"
LOG_SRC="$CWD/.log"
LOG_DST="$PARENT/logs/$PROJECT"

# Copy any new log files into the parent's logs/<project>/ directory
if [ -d "$LOG_SRC" ] && [ -n "$(ls -A "$LOG_SRC" 2>/dev/null)" ]; then
  mkdir -p "$LOG_DST"
  cp -r "$LOG_SRC/." "$LOG_DST/"
fi

# Commit parent: updated logs + submodule pointer
commit_and_push "$PARENT" "auto: sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
