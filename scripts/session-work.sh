#!/bin/bash
# The BODY of both session hooks — everything session-end.sh and session-compact.sh
# used to do inline. They are now thin launchers; this is the work.
#
# Usage: session-work.sh <MODE> <ANCHOR>     MODE = end | compact
#        Hook JSON arrives on stdin (may be empty — see the fallback note below).
#
# ── WHY THE HOOKS NO LONGER DO THIS THEMSELVES ───────────────────────────────────
# Rule 3 used to read "local work is cheap and unrecoverable-if-skipped, so it stays
# synchronous; only the network phase is detached." That premise was measured false on
# 2026-09-03 and this file is the correction.
#
# The hook is NOT killed "inside its first push". It is killed roughly ONE SECOND after
# it starts, wherever it happens to be. Four recurrences, each landing wherever the
# previous fix had moved the tail:
#   2026-08-30  pushes ran before the log filing            → six session logs lost.
#   2026-08-31  filing hoisted above them                   → NEXT.md written, UNCOMMITTED.
#   2026-09-03  all local work hoisted, two pushes in series → work repo left unpushed.
#   2026-09-03  network phase fully detached (af69170)      → died in the LOCAL phase:
#               an omni-me session filed its log at 18:38:36.664, staged both repos, and
#               was killed in public-gate.sh before the commit. The gate (a7ec06e, added
#               that morning) calls repo-visibility.sh, which on a cache MISS makes a
#               `gh api` network call — sitting between the staging and the commit, in
#               the phase Rule 3 declared free. Proof it was a cold miss: omni-me's cache
#               key did not exist until it was created by hand nine minutes later.
#               A second run the same day (12:29:09) died even earlier, in `timeout 2 cat`
#               or inside file-session-log.py — before filing anything at all.
#
# Reordering moved the failure three times; detaching one phase moved it a fourth. The
# only fix that generalises is to remove the ENTIRE body from the hook's lifetime. So:
#   - SessionEnd  launches this DETACHED (`setsid --fork`) and exits in microseconds.
#   - PreCompact  runs this INLINE. /compact is not a shutdown, so it is not exposed to
#     the kill, and running inline keeps two properties worth having: the transcript is
#     read before compaction can touch it, and the user still sees the result. Sharing
#     one body is what matters — the two copies had already drifted once.
#
# DO NOT put anything back into the hooks. The next thing left in a hook's lifetime is
# the next thing lost.

MODE="${1:-end}"
ANCHOR="${2:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
[ -d "$ANCHOR" ] || ANCHOR="$(pwd)"

if [ "$MODE" = "compact" ]; then
  DEBUG_LOG="/tmp/claude-session-compact-debug.log"
  LABEL="compact checkpoint"
else
  DEBUG_LOG="/tmp/claude-session-end-debug.log"
  LABEL="session end"
fi

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# say <text> — always to the debug log; to stdout only when someone can read it.
# In `end` mode this process is detached and its stdout IS the debug log, so an
# unconditional print would double every line.
say() {
  printf '%s\n' "$*" >> "$DEBUG_LOG"
  [ "$MODE" = "compact" ] && printf '%s\n' "$*"
  return 0
}

# ── the hook JSON, and why a miss is now survivable ──────────────────────────────
# transcript_path is the authoritative .jsonl for THIS session. Reading it used to be
# the first thing the hook did, and `timeout 2 cat` could therefore burn the hook's
# entire ~1s budget before anything was filed — the 12:29:09 signature above.
# Down here the wait is free: detached in `end` mode, and PreCompact is not on a clock.
# If it comes back empty, file-session-log.py's find_transcript() falls back to the
# newest .jsonl for this repo, so an empty read degrades instead of failing.
HOOK_JSON="$(timeout 5 cat 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$HOOK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || true)"

CWD=""
if git -C "$ANCHOR" rev-parse --git-dir &>/dev/null; then
  CWD="$(git -C "$ANCHOR" rev-parse --show-toplevel)"
fi

# ── LOCK: this body can now genuinely overlap another session in the same repo ───
# While the body ran inside the hook it was over in a second and could not realistically
# collide. Detached, it can: on 2026-09-03 a new session started in omni-me SEVEN SECONDS
# after the previous one's SessionEnd fired. session-start.sh runs
# `git pull --rebase --autostash` on the same repo, which takes .git/index.lock and would
# corrupt or abort this commit. session-start.sh takes this same per-repo lock.
#
# PER-REPO, not global: two sessions ending in DIFFERENT repos must not serialise on each
# other. The shared claude-state repo is the one exception and takes its own lock below —
# the same one session-push.sh uses, for the reason its header gives.
# Bounded wait: a stuck holder must cost this run, not wedge it forever.
WORK_LOCK="/tmp/claude-session-work.$(printf '%s' "${CWD:-no-repo}" | md5sum | cut -c1-16).lock"

{
  flock -w 120 9 || say "WARNING: work lock wait timed out for ${CWD:-<no repo>}; proceeding unlocked"

  # ── file the readable log-so-far (replaces the manual /export ritual) ─────────
  # Still the first real step: it is local, and it is the only output that cannot be
  # reconstructed once the transcript is gone. The repo guard is DUPLICATED as an `if`
  # rather than an early exit, so a session launched outside a checkout still reaches
  # the memory sync at the bottom.
  if [ -n "$CWD" ]; then
    FILE_RESULT="$(python3 "$DOTFILES/file-session-log.py" --repo "$CWD" --transcript "$TRANSCRIPT" 2>&1)"
    say "$FILE_RESULT"
  fi

  if [ -n "$CWD" ]; then
    PARENT="$(git -C "$CWD" rev-parse --show-superproject-working-tree 2>/dev/null)"

    # Root/parent session: mirror the gitignored .log/ + .curiosities/ into their
    # tracked parent dirs (the convention the manual protocol used — these dirs are
    # parent-synced, never committed inside the project).
    if [ -z "$PARENT" ]; then
      [ -d "$CWD/.log" ] && { mkdir -p "$CWD/logs/root"; cp -r "$CWD/.log/." "$CWD/logs/root/" 2>/dev/null || true; }
      [ -d "$CWD/.curiosities" ] && { mkdir -p "$CWD/curiosities/root"; cp -r "$CWD/.curiosities/." "$CWD/curiosities/root/" 2>/dev/null || true; }
    else
      # Submodule session: same mirror, into the PARENT's tracked dirs, then STAGED —
      # the commit itself waits for the pusher, which combines it with the guarded
      # pointer bump (`end` mode only; a compact is a checkpoint, not an integration).
      PROJECT="$(basename "$CWD")"
      [ -d "$CWD/.log" ] && { mkdir -p "$PARENT/logs/$PROJECT"; cp -r "$CWD/.log/." "$PARENT/logs/$PROJECT/" 2>/dev/null || true; }
      [ -d "$CWD/.curiosities" ] && { mkdir -p "$PARENT/curiosities/$PROJECT"; cp -r "$CWD/.curiosities/." "$PARENT/curiosities/$PROJECT/" 2>/dev/null || true; }
      # TWO adds, not one. `git add -- a b` is ATOMIC: if either pathspec matches
      # nothing git aborts the whole command and stages NEITHER. Most projects have no
      # .curiosities/, so `curiosities/$PROJECT` usually does not exist, and the single
      # combined add was silently staging nothing at all (exit 128, swallowed by
      # `|| true`) — the mirrored logs then sat untracked until some later root session's
      # blanket `add -A` happened to sweep them in. Found 2026-09-03.
      git -C "$PARENT" add -A -- "logs/$PROJECT" 2>/dev/null || true
      git -C "$PARENT" add -A -- "curiosities/$PROJECT" 2>/dev/null || true
    fi

    # Stage work, then unstage every submodule path before committing.
    # A bare `git add -A` in a parent stages every dirty gitlink, recording a pointer to
    # an unpushed (or in-flight) submodule commit — a dangling gitlink that breaks fresh
    # clones and `submodule update`. Advancing a pointer is a deliberate integration
    # (see session-push.sh), never a side effect of a checkpoint.
    git -C "$CWD" add -A
    while IFS= read -r sub; do
      [ -n "$sub" ] && git -C "$CWD" reset -q HEAD -- "$sub" 2>/dev/null || true
    done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')

    # PUBLIC-REPO GATE: in a public repo, unstage NEW files that look sensitive before
    # they can be committed and pushed. Runs after the staging and before the commit, so
    # it sees exactly what would ship. See public-gate.sh for why this is a narrow
    # content gate and not `git add -u` (measured: -u would have cost 142 wanted files to
    # stop 1 unwanted one, and it half-applies renames).
    #
    # This is the step that killed the hook on 2026-09-03 — it makes a `gh api` call on a
    # cold cache. That is now survivable because the whole body is off the hook's clock,
    # and less likely because session-start.sh warms the cache for $CWD every session.
    GATE_RESULT="$("$DOTFILES/public-gate.sh" "$CWD" 2>&1)"
    [ -n "$GATE_RESULT" ] && say "$GATE_RESULT"

    # No "did we commit?" flag is kept: the pusher decides what to push from the branch
    # actually being ahead of its upstream, which also retries whatever an earlier killed
    # run stranded.
    if ! git -C "$CWD" diff --staged --quiet; then
      git -C "$CWD" commit -q -m "auto: $LABEL $(date '+%Y-%m-%d %H:%M')" >>"$DEBUG_LOG" 2>&1 \
        || say "WARNING: commit FAILED in $CWD — work is STAGED but not committed"
    fi

    # ── visibility, NOT automation: name the work this session will not commit ──
    # Git treats a submodule as an opaque gitlink, so the `add -A` above stages only its
    # POINTER (which the loop then unstages) — a submodule's own modified files are never
    # touched by a parent session. That work is silently stranded on this device.
    # Deliberately a NOTE and not a commit: committing here would sweep another repo's
    # in-flight work, and a concurrent session working in that submodule would have its
    # half-finished staging committed out from under it (observed live 2026-08-31).
    # session-start.sh reports this too, and that is now the copy that gets READ — this
    # one goes to the debug log at a moment nobody is watching.
    if [ -z "$PARENT" ]; then
      while IFS= read -r sub; do
        [ -n "$sub" ] || continue
        [ -e "$CWD/$sub/.git" ] || continue
        [ -n "$(git -C "$CWD/$sub" status --porcelain 2>/dev/null)" ] || continue
        say "NOTE: $sub has uncommitted work — a parent session never commits it, so it will not reach your other device. Commit from inside $sub, or let a session running there do it."
      done < <(git -C "$CWD" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
    fi
  fi
} 9>"$WORK_LOCK"

# ── LOCAL: commit memory notes + saved plans (the claude-state repo) ─────────────
# Runs regardless of whether we are in a checkout — memory belongs to the session, not
# the work repo, so it must sync even when Claude was launched outside one. None of the
# submodule-pointer rules apply: this repo has no submodules, so `add -A` is safe.
#
# Under the PUSH lock, not the per-repo work lock: claude-state is the one repo EVERY
# session touches, so two workers in different repos do collide here, and session-push.sh
# pushes this same repo under that same lock. Per-repo locking would not cover it — the
# reason session-push.sh's header gives for its lock being global.
STATE="$HOME/.claude"
if [ -d "$STATE/.git" ]; then
  {
    flock -w 120 9 || true
    git -C "$STATE" add -A 2>/dev/null || true
    git -C "$STATE" diff --staged --quiet 2>/dev/null || \
      git -C "$STATE" commit -q -m "auto: $LABEL $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || true
  } 9>"/tmp/claude-session-push.lock"
fi

# ── NETWORK ──────────────────────────────────────────────────────────────────────
# In `end` mode this process is already detached and has nothing left to do, so it
# simply becomes the pusher — a second `setsid` would buy nothing. In `compact` mode we
# ARE the hook, so the pusher still has to be detached the careful way: `--fork` with NO
# trailing `&`. A backgrounded `setsid ... &` forks a subshell that still belongs to this
# process group until setsid() actually runs, and a kill arriving in that window takes
# the pusher down too. Measured 2026-09-03.
if [ "$MODE" = "compact" ]; then
  setsid --fork "$DOTFILES/session-push.sh" "$CWD" compact </dev/null >>"$DEBUG_LOG" 2>&1
  exit 0
fi

exec "$DOTFILES/session-push.sh" "$CWD" end
