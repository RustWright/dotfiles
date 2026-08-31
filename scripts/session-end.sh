#!/bin/bash
# SessionEnd hook: file the readable session log, commit work in the current repo
# (never sweeping submodule pointers), and — inside a submodule — sync logs to the
# parent and record the submodule pointer ONLY if it is already pushed.
#
# Three independent safety rules, all learned the hard way:
#   1. A root/parent session must NOT auto-commit submodule pointer bumps. A bare
#      `git add -A` in the parent stages every dirty gitlink, recording a pointer
#      to an unpushed (or unrelated, in-flight) submodule commit — a dangling
#      gitlink that breaks fresh clones and `submodule update`. So we stage work
#      but then unstage every submodule path before committing.
#   2. A submodule session MAY advance the parent's pointer, but only when that
#      submodule HEAD is already on its remote (else the same dangling gitlink).
#      That guarded bump is a deliberate integration; the sweep in rule 1 is not.
#   3. EVERY LOCAL STEP RUNS BEFORE EVERY NETWORK STEP. This hook is killed when
#      it outlives the CLI's shutdown grace, and it always dies inside a push —
#      so anything sequenced after a push is a coin flip. Local work is cheap and
#      unrecoverable-if-skipped; a push is expensive and always retryable next
#      session. On 2026-08-30 that cost six session logs, and the fix hoisted only
#      the log filing. On 2026-08-31 the same kill landed one step lower: the hook
#      filed its log, entered the claude-state push, and never reached the repo
#      commit — leaving NEXT.md, the handoff artifact, written but UNCOMMITTED and
#      therefore absent on every other device. Hence the rule is now the whole
#      script's shape, not one hoisted line: mirror and COMMIT locally up front,
#      push afterwards. The commit/push split below is deliberate; do not re-pair
#      them.

DEBUG_LOG="/tmp/claude-session-end-debug.log"
echo "=== SessionEnd: $(date) PWD=$(pwd) ===" >> "$DEBUG_LOG"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The hook hands us JSON on stdin; transcript_path is the authoritative .jsonl for
# THIS session - more reliable than guessing the newest one in the project dir.
HOOK_JSON="$(timeout 2 cat 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$HOOK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)"

# ── file the readable log-so-far (replaces the manual /export ritual) ─────────
# ORDERING IS LOAD-BEARING: this runs BEFORE any network I/O. It is local, fast,
# and the only step whose output cannot be reconstructed once the transcript is
# gone. It used to sit *after* the claude-state sync below, and every session end
# that had memory to push died inside that push before ever reaching this line —
# silently losing six session logs on 2026-08-30 (omni-me and the workspace
# root). The repo guard is DUPLICATED rather than moved, so a session launched
# outside a checkout still falls through to the memory sync.
# Capture-then-emit (not `| tee`): a closed stdout must not cost us the debug
# record. Surface the one-line result to the user; keep full detail in the log.
CWD=""
if git rev-parse --git-dir &>/dev/null; then
  CWD="$(git rev-parse --show-toplevel)"
  FILE_RESULT="$(python3 "$DOTFILES/file-session-log.py" --repo "$CWD" --transcript "$TRANSCRIPT" 2>&1)"
  printf '%s\n' "$FILE_RESULT" >> "$DEBUG_LOG"
  printf '%s\n' "$FILE_RESULT"
fi

# ── LOCAL: mirror logs and COMMIT the current repo, before any network I/O ────
# Rule 3. This whole block used to sit *below* the claude-state push; on
# 2026-08-31 the hook died in that push and never got here, so the session's
# NEXT.md was written but never committed. Nothing in here touches the network,
# so nothing in here can be lost to a killed push.
# The CWD guard is DUPLICATED as an `if` rather than moved up as an early exit —
# same reason the log-filing block above duplicates it: a session launched
# outside a checkout has no repo to commit, but must still reach the memory sync.
COMMITTED=0
if [ -n "$CWD" ]; then
  PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"

  # Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
  # tracked parent dirs (same convention the manual protocol used — these dirs are
  # parent-synced, never committed inside the project).
  if [ -z "$PARENT" ]; then
    [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
    [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
  fi

  # Stage work, then unstage every submodule path before committing (rule 1).
  git -C "$CWD" add -A
  while IFS= read -r sub; do
    [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
  done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

  if ! git -C "$CWD" diff --staged --quiet; then
    git -C "$CWD" commit -m "auto: session end $(date '+%Y-%m-%d %H:%M')"
    COMMITTED=1
  fi
fi

# ── cross-device state: memory notes + saved plans (the claude-state repo) ────
# Runs regardless of whether we are in a checkout — memory belongs to the
# session, not the work repo, so it must sync even when Claude was launched
# outside one. None of the submodule-pointer rules apply here: this repo has no
# submodules, so `add -A` is safe. Non-fatal like every other sync step.
# Every push is BOUNDED: a hook that outlives the CLI's shutdown grace is killed
# mid-flight, so a hang must cost seconds, never the rest of the script.
STATE="$HOME/.claude"
if [ -d "$STATE/.git" ]; then
  git -C "$STATE" add -A 2>/dev/null || true
  git -C "$STATE" diff --staged --quiet 2>/dev/null || {
    git -C "$STATE" commit -q -m "auto: session end $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
    timeout 30 git -C "$STATE" push -q 2>/dev/null || echo "WARNING: claude-state push FAILED or timed out — memory is committed locally but NOT synced. Fix: git -C $STATE pull --rebase && git -C $STATE push"
  }
fi

[ -z "$CWD" ] && exit 0

# ── NETWORK: push the commit made above ───────────────────────────────────────
# Split from its commit on purpose (rule 3) — losing this push costs a retry next
# session; losing the commit costs the work. Also pushes when an EARLIER run
# committed but died before pushing, which is exactly the state a killed hook
# leaves behind. Must stay AHEAD of the pointer bump below, which reads the
# remote-tracking refs that only a successful push updates.
AHEAD="$(git -C "$CWD" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
if [ "$COMMITTED" = 1 ] || [ "${AHEAD:-0}" -gt 0 ]; then
  timeout 30 git -C "$CWD" push 2>/dev/null || echo "WARNING: push FAILED or timed out in $CWD — work is committed locally but NOT on the remote (usually the branch moved on another device). Fix: git -C $CWD pull --rebase && git -C $CWD push"
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
  timeout 30 git -C "$PARENT" push 2>/dev/null || echo "WARNING: parent push FAILED or timed out in $PARENT — pointer/log commit is local only. Fix: git -C $PARENT pull --rebase && git -C $PARENT push"
fi
