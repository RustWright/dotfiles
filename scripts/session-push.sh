#!/bin/bash
# The DETACHED network phase for both session hooks. Launched by session-end.sh and
# session-compact.sh via `setsid`, never run inline by them.
#
# Usage: session-push.sh <REPO> <MODE>      MODE = end | compact
#        REPO may be empty (Claude launched outside a checkout) — claude-state still syncs.
#
# ── WHY THIS IS DETACHED, AND WHY IT MUST NOT BE INLINED BACK ────────────────────
# The hooks are killed when they outlive the CLI's shutdown grace, and they always die
# INSIDE a push. Two previous fixes tried to survive that by REORDERING, and each time
# the kill simply landed one step lower:
#   2026-08-30  the pushes ran before the log filing      → six session logs lost.
#   2026-08-31  the log filing was hoisted above them     → the kill landed one step
#               lower and left NEXT.md written but UNCOMMITTED.
#   2026-09-03  local work was all hoisted, but TWO pushes remained in series with the
#               work repo second. The hook died in the claude-state push and never
#               reached the ~/life push, so the session's commit sat unpushed and had
#               to be pushed by hand.
# The 2026-09-03 fingerprint is worth recognising: the claude-state REMOTE had the
# commit while the local remote-tracking ref did not — a push killed after the server
# accepted the ref update and before the client recorded it.
#
# Reordering cannot fix this, because every ordering still leaves something after the
# first push. So the network phase is removed from the hook's LIFETIME instead: the hook
# does all local work synchronously, launches this script under `setsid` (new session and
# process group, so a process-group kill aimed at the hook cannot reach it), and exits.
#
# Four consequences are load-bearing here:
#   1. THERE IS NO STDOUT. Nothing printed here can reach the user, so every message
#      goes to the debug log. In the old inline version the three push WARNINGs were
#      bare `echo` while neighbouring notices used `tee -a "$DEBUG_LOG"` — so a failed
#      push was invisible AND unlogged. That is how 2026-09-03 survived a week unnoticed.
#   2. Pushes are AHEAD-guarded, never "we just committed"-guarded, so every run also
#      retries whatever an earlier killed run stranded. That retry always existed inline;
#      it had simply never been reached.
#   3. The submodule pointer bump lives HERE, after the push, because its guard reads the
#      remote-tracking refs that only a completed push updates. Left behind in the hook it
#      would fail closed on every single session.
#   4. ONE GLOBAL LOCK, not per-repo: two sessions ending in DIFFERENT repos still push
#      the SAME claude-state repo, so a per-repo lock would not cover the shared one.
#
# The invariant from session-end.sh still holds absolutely: the parent never records a
# pointer to an unpushed submodule commit.

REPO="$1"
MODE="${2:-end}"

if [ "$MODE" = "compact" ]; then
  DEBUG_LOG="/tmp/claude-session-compact-debug.log"
else
  DEBUG_LOG="/tmp/claude-session-end-debug.log"
fi
LOCK="/tmp/claude-session-push.lock"

log() { printf '[push %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DEBUG_LOG"; }

# Serialise pushers against each other. Re-exec once under flock; the env var stops the
# re-exec recursing. Bounded wait: a stuck holder must cost this run, not wedge it forever.
if [ -z "${CLAUDE_SESSION_PUSH_LOCKED:-}" ]; then
  export CLAUDE_SESSION_PUSH_LOCKED=1
  flock -w 180 "$LOCK" "$0" "$@"
  rc=$?
  [ "$rc" -eq 0 ] || log "WARNING: pusher exited $rc (lock wait timed out, or a push failed)"
  exit "$rc"
fi

log "start mode=$MODE repo=${REPO:-<none>} pid=$$"

# push_if_ahead <repo> <label>
# Pushes only when the branch is genuinely ahead of its upstream, so this doubles as the
# retry for commits an earlier killed run left stranded. Bounded: a detached process has
# no supervisor, so it must never be able to hang forever.
push_if_ahead() {
  local repo="$1" label="$2" ahead out
  [ -n "$repo" ] || return 0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  ahead="$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -le 0 ]; then
    log "$label: nothing to push"
    return 0
  fi
  if out="$(timeout 30 git -C "$repo" push 2>&1)"; then
    log "$label: pushed $ahead commit(s)"
    return 0
  fi
  log "WARNING: $label push FAILED or timed out — committed locally but NOT on the remote (usually the branch moved on another device). Fix: git -C $repo pull --rebase && git -C $repo push"
  log "  git said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
  return 1
}

# Memory + plans. Pushed first only because it is repo-independent; nothing is sequenced
# behind it any more, so its position no longer costs anything if it fails.
push_if_ahead "$HOME/.claude" "claude-state"

# The workflow machinery itself. Every session can edit it — via `git -C`, per the standing
# rule against `cd`-ing into either checkout — but it is the ANCHOR repo of almost none, and
# only the anchor repo gets pushed. So nothing pushed it and nothing reported it: on
# 2026-09-04 it sat 4 commits ahead for six hours, carrying a session-start.sh fix that left
# the OTHER device loading empty memory. The ff-only pull in session-start.sh is structurally
# blind to this — it prints "Already up to date" when YOU are the one ahead.
#
# Safe to push unattended precisely because no hook ever STAGES anything here: dotfiles gets
# only deliberate hand-made commits, and push_if_ahead never commits, so this merely completes
# an intent already expressed. Above the no-repo exit on purpose — a session launched outside
# a checkout can still have edited the machinery.
#
# Derives its own path because $DOTFILES is ambiguous across this tree: the SCRIPTS dir in
# session-work.sh / session-end.sh / session-compact.sh / public-gate.sh, the REPO ROOT in
# session-start.sh. Hence the `/..` and the unambiguous name.
DOTFILES_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
push_if_ahead "$DOTFILES_REPO" "dotfiles"

[ -n "$REPO" ] || { log "done (no repo)"; exit 0; }

# The work repo. A failure here is NOT fatal to the rest: the pointer guard below fails
# closed on its own, and the parent's staged log mirror is still worth committing.
push_if_ahead "$REPO" "$(basename "$REPO")"

# ── submodule session: guarded pointer bump + parent push ────────────────────────
# The hook has already mirrored .log/ and .curiosities/ into the parent and STAGED them
# (local work belongs in the hook, before the detach boundary). What is left here is
# only what genuinely cannot run before the push.
PARENT="$(git -C "$REPO" rev-parse --show-superproject-working-tree 2>/dev/null)"
[ -n "$PARENT" ] || { log "done"; exit 0; }

PROJECT="$(basename "$REPO")"

if [ "$MODE" = "compact" ]; then
  # A compact is a checkpoint, never an integration: it must not advance the pointer.
  # Run sync_pointers.py to integrate deliberately.
  MSG="auto: compact log sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
else
  MSG="auto: sync $PROJECT $(date '+%Y-%m-%d %H:%M')"
  # Record this submodule's pointer only if its HEAD is present on the remote. A
  # successful push updates the local remote-tracking refs; a failed one does not, so
  # this fails closed if the push above silently died — no network round-trip needed.
  SUB_HEAD="$(git -C "$REPO" rev-parse HEAD)"
  if [ -n "$(git -C "$REPO" branch -r --contains "$SUB_HEAD" 2>/dev/null)" ]; then
    git -C "$PARENT" add -- "$REPO"
    log "$PROJECT: pointer staged ($SUB_HEAD)"
  else
    log "WARNING: $PROJECT HEAD $SUB_HEAD not on remote; pointer NOT recorded"
  fi
fi

if ! git -C "$PARENT" diff --staged --quiet; then
  git -C "$PARENT" commit -q -m "$MSG" && log "parent: committed \"$MSG\""
fi
push_if_ahead "$PARENT" "parent $(basename "$PARENT")"

log "done"
