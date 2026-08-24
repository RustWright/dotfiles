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
