#!/bin/bash
# Print a repo's GitHub visibility ("public" / "private"), or NOTHING if unknown.
#
# Extracted from session-start.sh so the SessionStart canary and the SessionEnd
# public-repo gate cannot drift apart — they must agree on what "public" means,
# because one warns about exactly what the other refuses to publish.
#
# Unknown stays SILENT and must keep doing so: a repo with no GitHub remote, or a
# device with no `gh` auth, prints nothing, and every caller treats that as "not
# known to be public" rather than as an error. Failing loud here would fire on
# every session on a machine that simply has no `gh`.
#
# Cached per remote URL for 7 days: one `gh` call a week per repo. Callers should
# still only invoke this when they actually have something to decide about.
#
# Usage: repo-visibility.sh <repo-path>

REPO="${1:-.}"

VURL="$(git -C "$REPO" remote get-url origin 2>/dev/null)"
[ -n "$VURL" ] || exit 0

VDIR="$HOME/.cache/claude-repo-visibility"
VKEY="$(printf '%s' "$VURL" | md5sum | cut -c1-16)"
VFILE="$VDIR/$VKEY"

if [ -f "$VFILE" ] && [ -z "$(find "$VFILE" -mtime +7 2>/dev/null)" ]; then
  cat "$VFILE" 2>/dev/null
  exit 0
fi

VSLUG="$(printf '%s' "$VURL" | sed -E 's|^.*github\.com[:/]||; s|\.git$||')"
VIS="$(timeout 5 gh api "repos/$VSLUG" --jq '.visibility' 2>/dev/null || true)"
[ -n "$VIS" ] && { mkdir -p "$VDIR"; printf '%s' "$VIS" > "$VFILE"; }

printf '%s' "$VIS"
