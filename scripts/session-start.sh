#!/bin/bash
# SessionStart hook: bring this device current WITHOUT disturbing in-flight work.
#
# Replaces the manual "at session start run git pull --rebase + submodule update"
# instruction. Deliberately gentle, because the workflow assumes dirty/unpushed
# submodules are normal (you move between devices mid-task):
#   - ~/.dotfiles is fast-forwarded first, so the workflow machinery itself stays
#     current across devices (changes apply next session — a hook can't reload the
#     script it's already running)
#   - the current repo is pulled with --autostash (your dirty work is preserved)
#   - each submodule is fast-forwarded ONLY if clean; dirty ones are left ALONE
#     (never force-checked-out to the recorded pointer, which would strand work)
# Everything is non-fatal: a failure here must never block starting a session.
#
# The whole body runs inside main(), invoked at the very end. That matters: the
# dotfiles pull below can overwrite THIS script on disk mid-run, and a bash script
# read line-by-line would then execute garbage from the new file at the old byte
# offset. Parsing the entire function before executing it makes the on-disk swap
# harmless — bash runs from memory, not from the changed file.

main() {
  # Keep the workflow machinery itself current. ff-only never clobbers local
  # dotfiles edits; if the tree is dirty in a conflicting way it simply declines.
  DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  git -C "$DOTFILES" pull --ff-only 2>/dev/null || true

  # ── cross-device memory + plans (the claude-state repo) ─────────────────────
  # Deliberately ABOVE the is-this-a-git-repo guard below: memory belongs to the
  # session, not to the work repo, so it must sync even when Claude is launched
  # somewhere that isn't a checkout.
  STATE="$HOME/.claude"
  if [ -d "$STATE/.git" ]; then
    git -C "$STATE" pull --rebase --autostash 2>/dev/null || true

    # Memory lives under a slug keyed on the path RELATIVE TO $HOME, because the
    # absolute path differs per device (/home/efe vs /home/me) while ~/... does
    # not. The per-device directory Claude Code actually reads is a symlink onto
    # that slug, so one tracked copy serves every machine.
    #
    # Take the device-local key from transcript_path (.../projects/<KEY>/x.jsonl)
    # rather than re-deriving it: it comes from Claude Code itself, so the link
    # cannot end up pointing at a directory nothing reads. $PWD is the fallback.
    HOOK_JSON="$(timeout 2 cat 2>/dev/null || true)"
    KEY="$(printf '%s' "$HOOK_JSON" | python3 -c "import json,sys,os; print(os.path.basename(os.path.dirname(json.load(sys.stdin).get('transcript_path',''))))" 2>/dev/null || true)"
    [ -z "$KEY" ] && KEY="$(printf '%s' "$PWD" | sed 's|[/_]|-|g')"
    SLUG="$(printf '%s' "$PWD" | sed "s|^$HOME/||" | sed 's|[/_]|-|g')"

    LINK="$STATE/projects/$KEY/memory"
    TARGET="$STATE/state/memory/$SLUG"

    # Order matters: the two alarm conditions are tested BEFORE any branch that
    # could repair them. `mkdir -p "$TARGET"` in the create-link branch below
    # would otherwise resurrect a deleted directory and mask the very thing the
    # canary exists to report — leaving the session running on empty memory.
    if [ ! -d "$STATE/state/memory" ]; then
      # The allowlist in .gitignore names exact paths, so if Anthropic relocates
      # this layout the sync stops silently. Shouting is the whole mitigation.
      echo "session-start: WARNING — $STATE/state/memory is missing. Cross-device memory sync is NOT running."
    elif [ -L "$LINK" ] && [ ! -e "$LINK" ]; then
      echo "session-start: WARNING — $LINK points at a missing $TARGET. Memory will not load this session; not recreating it silently."
    elif [ -d "$LINK" ] && [ ! -L "$LINK" ]; then
      # A real directory is sitting where the link belongs — this is the other
      # device's own accumulated notes on first sync. Adopt ONLY what is
      # unambiguous: files absent from the tracked copy, or byte-identical to it.
      # A file that exists on both sides with different content is a genuine
      # content merge, which a hook must never decide; refuse and say so.
      CONFLICT=""
      for f in "$LINK"/*; do
        [ -f "$f" ] || continue
        t="$TARGET/$(basename "$f")"
        [ -f "$t" ] && ! cmp -s "$f" "$t" && CONFLICT="$CONFLICT $(basename "$f")"
      done
      if [ -n "$CONFLICT" ]; then
        echo "session-start: MEMORY MERGE NEEDED for $SLUG — differing on both sides:$CONFLICT"
        echo "session-start: left untouched at $LINK; reconcile by hand, nothing was overwritten."
      else
        mkdir -p "$TARGET"
        cp -an "$LINK"/. "$TARGET"/ 2>/dev/null || true
        rm -rf "$LINK" && ln -s "../../state/memory/$SLUG" "$LINK"
      fi
    elif [ ! -e "$LINK" ] && [ ! -L "$LINK" ] && [ -d "$STATE/projects/$KEY" ]; then
      mkdir -p "$TARGET"
      ln -s "../../state/memory/$SLUG" "$LINK"
    fi
  fi

  git rev-parse --git-dir &>/dev/null || return 0
  CWD="$(git rev-parse --show-toplevel)"

  # Pull the current repo; autostash keeps any uncommitted work out of the way.
  git -C "$CWD" pull --rebase --autostash 2>/dev/null || true

  # Gently advance submodules: fetch + ff the clean ones, skip dirty ones.
  git -C "$CWD" submodule --quiet foreach '
    if [ -z "$(git status --porcelain)" ]; then
      git fetch --quiet 2>/dev/null || true
      git merge --ff-only "@{u}" 2>/dev/null || true
    else
      echo "session-start: skipping dirty submodule $sm_path (work in flight)"
    fi
  ' 2>/dev/null || true
}

main "$@"
exit 0
