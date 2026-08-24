#!/bin/bash
# SessionStart hook: bring this device current WITHOUT disturbing in-flight work.
#
# Replaces the manual "at session start run git pull --rebase + submodule update"
# instruction. Deliberately gentle, because the workflow assumes dirty/unpushed
# submodules are normal (you move between devices mid-task):
#   - the current repo is pulled with --autostash (your dirty work is preserved)
#   - each submodule is fast-forwarded ONLY if clean; dirty ones are left ALONE
#     (never force-checked-out to the recorded pointer, which would strand work)
# Everything is non-fatal: a failure here must never block starting a session.

git rev-parse --git-dir &>/dev/null || exit 0
CWD="$(git rev-parse --show-toplevel)"

# Pull the current repo; autostash keeps any uncommitted work out of the way.
git -C "$CWD" pull --rebase --autostash 2>/dev/null || true

# Gently advance submodules: fetch + fast-forward the clean ones, skip dirty ones.
git -C "$CWD" submodule --quiet foreach '
  if [ -z "$(git status --porcelain)" ]; then
    git fetch --quiet 2>/dev/null || true
    git merge --ff-only "@{u}" 2>/dev/null || true
  else
    echo "session-start: skipping dirty submodule $sm_path (work in flight)"
  fi
' 2>/dev/null || true

exit 0
