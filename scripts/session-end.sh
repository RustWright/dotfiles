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
#   3. THIS HOOK DOES LOCAL WORK ONLY. It is killed when it outlives the CLI's
#      shutdown grace, and it always dies inside a push. Ordering alone cannot fix
#      that — it was tried twice and moved the failure both times. On 2026-08-30
#      the pushes ran first and cost six session logs; hoisting the log filing left
#      the kill one step lower, and on 2026-08-31 it landed on the repo commit,
#      leaving NEXT.md written but UNCOMMITTED. On 2026-09-03 all local work was
#      above all network work, yet TWO pushes remained in series with the work repo
#      second: the hook died in the claude-state push and a ~/life commit had to be
#      pushed by hand. Every ordering leaves something after the first push.
#      So the network phase is no longer in this process at all — it is handed to
#      session-push.sh under `setsid` at the bottom of this file. Local work is
#      cheap and unrecoverable-if-skipped, so it stays synchronous here; pushes are
#      expensive, always retryable, and now outlive the hook. Do not re-pair a
#      commit with a push, and do not move a push back into this script.

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
if [ -n "$CWD" ]; then
  PARENT="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"

  # Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
  # tracked parent dirs (same convention the manual protocol used — these dirs are
  # parent-synced, never committed inside the project).
  if [ -z "$PARENT" ]; then
    [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
    [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
  else
    # Submodule session: same mirror, into the PARENT's tracked dirs, then STAGED —
    # the commit itself waits for the pusher, which combines it with the guarded
    # pointer bump. Rule 3 puts the copy here: it is local, and it used to sit AFTER
    # the repo push, where a killed hook dropped it exactly the way 2026-08-30 lost
    # six session logs. Staged-but-uncommitted is a recoverable end state; not copied
    # at all is not.
    PROJECT="$(basename "$CWD")"
    [ -d "$CWD/.log" ] && { mkdir -p "$PARENT/logs/$PROJECT"; cp -r "$CWD/.log/." "$PARENT/logs/$PROJECT/" 2>/dev/null || true; }
    [ -d "$CWD/.curiosities" ] && { mkdir -p "$PARENT/curiosities/$PROJECT"; cp -r "$CWD/.curiosities/." "$PARENT/curiosities/$PROJECT/" 2>/dev/null || true; }
    git -C "$PARENT" add -A -- "logs/$PROJECT" "curiosities/$PROJECT" 2>/dev/null || true
  fi

  # Stage work, then unstage every submodule path before committing (rule 1).
  git -C "$CWD" add -A
  while IFS= read -r sub; do
    [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
  done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

  # No "did we commit?" flag is kept: the pusher decides what to push from the branch
  # actually being ahead of its upstream, which also retries whatever an earlier
  # killed run stranded.
  if ! git -C "$CWD" diff --staged --quiet; then
    git -C "$CWD" commit -m "auto: session end $(date '+%Y-%m-%d %H:%M')"
  fi

  # ── visibility, NOT automation: name the work this session will not commit ──
  # Git treats a submodule as an opaque gitlink, so the `add -A` above stages only
  # its POINTER (which rule 1 then unstages) — a submodule's own modified files are
  # never touched by a parent session. Work edited under projects/<x>/ from a root
  # session is therefore silently stranded on this device: the session ends
  # "successfully" and the other device never sees it.
  # Deliberately a NOTE and not a commit. Committing here would sweep another
  # repo's in-flight work as a side effect — the exact thing rules 1 and 2 exist to
  # prevent — and a concurrent session working in that submodule would have its
  # half-finished staging committed out from under it (observed live 2026-08-31).
  # The human decides; the hook only makes the boundary visible.
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
    git -C "$STATE" commit -q -m "auto: session end $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
fi

# ── NETWORK: handed to a DETACHED process; this hook is now done ──────────────
# Rule 3 used to be enforced by ORDERING — all local steps above all network steps.
# That was necessary but never sufficient, because the hook is killed inside its
# FIRST push, so whatever is sequenced second is a coin flip no matter how the
# steps are arranged. Two fixes proved it by moving the failure rather than removing
# it (2026-08-30: six session logs; 2026-08-31: an uncommitted NEXT.md). On
# 2026-09-03 it landed lower again: two pushes remained in series with the WORK repo
# second, the hook died in the claude-state push, and a ~/life session's commit had to
# be pushed by hand. Tell-tale: the claude-state remote HAD the commit while the local
# remote-tracking ref did not — a push killed between the server accepting the ref and
# the client recording it.
#
# So the network phase no longer runs in this process at all. `setsid` puts the pusher
# in a new session and process group, which a process-group kill aimed at this hook
# cannot reach; redirecting all three fds keeps it from holding the terminal open.
# Everything above stays synchronous — local work is unrecoverable if skipped, and
# cheap enough that it always completes inside the grace.
#
# `--fork` with NO trailing `&`, and both halves matter. A backgrounded `setsid ... &`
# forks a subshell that still belongs to THIS process group until setsid() actually
# runs, so a kill arriving in that window takes the pusher down with the hook — the
# very failure this is meant to end. Measured 2026-09-03: with `&` the child was killed
# before it ever started; with `--fork` it landed in its own session (own sid+pgid,
# reparented to init) and completed after its launcher was SIGKILLed. `--fork` also
# guarantees setsid forks rather than exec'ing in place, which would block this hook.
#
# DO NOT re-inline this, and do not "simplify" it back into a push here. The ordering
# fix has been attempted twice and moved the failure both times.
setsid --fork "$DOTFILES/session-push.sh" "$CWD" end </dev/null >>"$DEBUG_LOG" 2>&1

exit 0
