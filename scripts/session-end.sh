#!/bin/bash
# Stop hook: auto-commit if session ended without explicit commit.
# Runs when Claude Code stops. If Claude already committed via CLAUDE.md
# protocol, there are no changes and this exits immediately.

git rev-parse --git-dir &>/dev/null || exit 0
git diff --quiet && git diff --staged --quiet && exit 0

git add -A
git commit -m "auto: session end $(date '+%Y-%m-%d %H:%M')"
git push 2>/dev/null || true
