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

# Returns 0 if the submodule's current HEAD is present on its remote, 1 if not.
# Guards the parent gitlink: recording a pointer to an unpushed submodule commit
# produces a dangling reference other clones (and fresh submodule updates) fail
# to fetch — exactly the breakage that stranded omni-me at commit 1357151c.
submodule_head_pushed() {
  local dir="$1"
  local sha="$2"
  # A successful push updates the local remote-tracking refs; a failed one does
  # not. So if any origin/* ref contains $sha, it genuinely reached the remote.
  # No network round-trip needed, and it fails closed if the push silently died.
  [ -n "$(git -C "$dir" branch -r --contains "$sha" 2>/dev/null)" ]
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

# Commit parent: logs always, but the submodule pointer only if it was pushed.
git -C "$PARENT" add -A -- "logs/$PROJECT" 2>/dev/null || true

SUB_HEAD="$(git -C "$CWD" rev-parse HEAD)"
if submodule_head_pushed "$CWD" "$SUB_HEAD"; then
  git -C "$PARENT" add -- "$CWD"
else
  echo "WARNING: $PROJECT HEAD $SUB_HEAD not on remote; pointer NOT recorded" | tee -a "$DEBUG_LOG"
fi

git -C "$PARENT" diff --staged --quiet && exit 0  # nothing to commit
git -C "$PARENT" commit -m "auto: sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
git -C "$PARENT" push 2>/dev/null || true
