#!/bin/bash
# PUBLIC-REPO GATE — refuse to auto-PUBLISH a new file that looks sensitive.
#
# Runs after `git add -A` and before the commit, in both session hooks. It unstages
# NEW files (staged as A) in a PUBLIC repo that match a risk pattern, and records
# each one in a cross-device manifest so the hold-back cannot go unnoticed.
#
# WHY A GATE AND NOT `git add -u`. The obvious fix — stage only tracked files in a
# public repo — was measured against this user's real history and rejected: across
# every `auto:` commit in the four public repos it would have prevented ONE unwanted
# file (the 2026-09-03 transcript) while silently deferring 142 wanted ones — Rust
# sources, tests, Cargo manifests, and every mylearnbase post, since a new post is
# only ever new files. It also breaks renames: after a plain on-disk `mv`, `git add
# -u` stages the DELETION and not the replacement, so the hook would push "file
# deleted" with nothing taking its place. Measured, not assumed.
#
# So the gate targets the HARM (publishing a secret or a transcript) rather than the
# MECHANISM (a file was added). Patterns are deliberately narrow: no source file,
# markdown post or image matches them, which keeps the false-positive rate — and
# therefore the manifest — near empty. A gate that fires often is one that gets
# ignored, exactly like a canary that fires every session.
#
# ONLY new files. A tracked file that matches a pattern is already public; unstaging
# its modification would strand edits to something the gate cannot un-publish anyway.
#
# Usage: public-gate.sh <repo-path>   (silent unless it holds something back)

REPO="$1"
[ -n "$REPO" ] && [ -d "$REPO" ] || exit 0
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Only public repos. Unknown visibility means "not known to be public" — see
# repo-visibility.sh for why that must stay silent rather than fail closed.
[ "$("$DOTFILES/repo-visibility.sh" "$REPO")" = "public" ] || exit 0

# Only files this commit would ADD. Nothing staged as A means nothing to gate.
mapfile -d '' NEW < <(git -C "$REPO" diff --staged --name-only --diff-filter=A -z 2>/dev/null)
[ "${#NEW[@]}" -gt 0 ] || exit 0

# The manifest is keyed by DEVICE, not by repo. Each machine only ever writes its
# own file, so two devices can never conflict on it — by construction, not by luck.
# That is the direct lesson from the 2026-08-28 cross-device memory sync, where
# `MEMORY.md` was the ONLY file that conflicted, precisely because it is the one
# file every session appends to.
MANIFEST_DIR="$HOME/.claude/state/held-back"
MANIFEST="$MANIFEST_DIR/$(hostname).tsv"

held=0
for f in "${NEW[@]}"; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  path="$REPO/$f"
  reason=""

  case "$base" in
    # Explicit exemptions FIRST — `.env.example` is the classic false positive, and
    # a gate that eats it teaches the user to distrust the gate.
    .env.example|.env.sample|.env.template|*.pem.example) reason="" ;;
    .env|.env.*)                                          reason="env-file" ;;
    *.pem|*.key|*.p12|*.pfx|*.keystore|id_rsa*|id_ed25519*|id_ecdsa*) reason="key-material" ;;
    .netrc|.git-credentials|credentials.json|.credentials.json)       reason="credential-file" ;;
    *-session-*.txt)                                      reason="session-transcript" ;;
  esac

  # A path inside a .log/ or .curiosities/ directory is a session artifact wherever
  # it turns up. This is the shape that caused the 2026-09-03 publish.
  case "/$f" in
    */.log/*|*/.curiosities/*) [ -z "$reason" ] && reason="session-artifact" ;;
  esac

  # Outsized binaries: over 10MB in a git repo is nearly always an accident, and it
  # is the one non-secret class worth stopping — it cannot be un-pushed either.
  if [ -z "$reason" ] && [ -f "$path" ]; then
    sz=$(stat -c%s "$path" 2>/dev/null || echo 0)
    [ "$sz" -gt 10485760 ] && reason="oversized-$((sz / 1048576))MB"
  fi

  # Content scan, bounded: only smallish text files, only well-known token shapes.
  # This is the check that catches a secret in a file with an innocent name — the
  # case no filename pattern can ever cover.
  if [ -z "$reason" ] && [ -f "$path" ] && [ "$(stat -c%s "$path" 2>/dev/null || echo 0)" -lt 1048576 ]; then
    if grep -qIaE '(ghp_|github_pat_|sk-ant-|xox[baprs]-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$path" 2>/dev/null; then
      reason="secret-shaped-content"
    fi
  fi

  [ -n "$reason" ] || continue

  # Unstage, mirroring the submodule-unstage idiom already in both hooks. The file
  # stays on disk and untracked, so the SessionStart untracked-in-public canary sees
  # it too — belt and braces, on the device that has it.
  git -C "$REPO" reset -q HEAD -- "$f" 2>/dev/null \
    || git -C "$REPO" rm --cached -q --force -- "$f" 2>/dev/null || true

  mkdir -p "$MANIFEST_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d')" "$REPO" "$f" "$reason" >> "$MANIFEST"
  held=$((held + 1))
done

[ "$held" -gt 0 ] || exit 0

# Loud here AND recorded for every other device. The print is for the transcript;
# the manifest is what actually crosses machines, because SessionEnd output is
# written at the one moment nobody is reading.
echo "session-end: HELD BACK $held new file(s) from the PUBLIC repo $(basename "$REPO") — NOT committed, NOT pushed:"
tail -n "$held" "$MANIFEST" | while IFS=$'\t' read -r _ _ rel why; do
  echo "  $rel  ($why)"
done
echo "session-end: they remain untracked on $(hostname). Commit deliberately, gitignore, or move them out. Every device will report this until then."
