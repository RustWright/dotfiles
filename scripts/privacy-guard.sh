#!/usr/bin/env bash
#
# Privacy guard for PUBLIC repos, called from each repo's pre-commit hook.
#
# Blocks any STAGED ADDITION that carries a credential, or a personal term the
# repo's denylist names. The denylist is GITIGNORED in the public repo, so the
# sensitive terms themselves never enter public history; its canonical copy lives
# in a private repo and is installed per device by privacy-guard-install.sh.
#
#   denylist : <repo>/.private-identity-denylist   (one ERE pattern per line;
#              '# hint: ...' lines are printed when the guard blocks)
#   bypass   : git commit --no-verify              (rare false positives)
#
# Scans only ADDED lines (the '+' side of the staged diff), so pre-existing
# tokens already in the tree never block unrelated commits — only NEW ones do.
#
# One shared copy on purpose. It began as omni-me's private hook; a second copy
# for mylearnbase would have needed every later fix ported by hand (the 2026-09-07
# credential shapes were exactly such a fix).

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
denylist="$repo_root/.private-identity-denylist"

# A missing denylist skips only the personal-term half. Credential shapes need
# no denylist, so they still run: a fresh clone is protected from the worse leak.
if [ ! -f "$denylist" ]; then
    echo "privacy-guard: no denylist at $denylist — personal terms NOT checked; run privacy-guard-install.sh." >&2
    denylist=/dev/null
fi

# Added content lines only (drop the '+++' file header).
added="$(git diff --cached --unified=0 --diff-filter=ACM | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
[ -n "$added" ] || exit 0

fail=0

# --- Credential shapes -------------------------------------------------------
# These live in the SCRIPT, not the denylist, and the split is deliberate: the
# denylist is gitignored because its terms are themselves sensitive, whereas a key
# *shape* reveals nothing. Keeping them here means they version-control, sync
# across machines, and survive a fresh clone -- which the denylist does not.
#
# Added 2026-09-07: the assistant work introduced hosted-inference API keys, and a
# test confirmed this guard passed an OpenRouter key, a Gemini key and a bearer
# token straight through. It was built for identity leaks and had no notion of
# credentials.
#
# Prefix-anchored on purpose. A generic `api_key = "..."` rule would block
# `secrets/credentials.toml.example`, whose placeholders are exactly that shape --
# and a guard that cries wolf on the template gets bypassed with --no-verify,
# after which it protects nothing at all.
secret_patterns=(
    'sk-or-v1-[A-Za-z0-9]{24,}'                 # OpenRouter
    'sk-(proj-)?[A-Za-z0-9_-]{32,}'             # OpenAI-style
    'AIza[0-9A-Za-z_-]{30,}'                    # Google / Gemini
    'hf_[A-Za-z0-9]{20,}'                       # Hugging Face
    'gh[pousr]_[A-Za-z0-9]{30,}'                # GitHub
    'xox[baprs]-[0-9A-Za-z-]{10,}'              # Slack
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'        # private keys
    'Bearer[[:space:]]+[A-Za-z0-9_.=-]{24,}'    # bearer tokens
)
for pattern in "${secret_patterns[@]}"; do
    # `-e` is required, not stylistic: the private-key pattern begins with dashes,
    # which grep otherwise parses as options. Combined with `|| true` that made the
    # rule silently dead while the guard still reported success.
    matches="$(printf '%s\n' "$added" | grep -nE -e "$pattern" || true)"
    if [ -n "$matches" ]; then
        if [ "$fail" -eq 0 ]; then
            echo "privacy-guard: BLOCKED — staged changes contain what looks like a CREDENTIAL:" >&2
            echo >&2
        fi
        echo "  pattern /$pattern/ matched:" >&2
        # Line numbers only. Printing the match would copy the secret into the
        # terminal, the scrollback, and any session transcript.
        printf '%s\n' "$matches" | cut -d: -f1 | sed 's/^/    at line /' | head -5 >&2
        fail=1
    fi
done

while IFS= read -r pattern; do
    [[ -z "${pattern// /}" || "$pattern" == \#* ]] && continue
    matches="$(printf '%s\n' "$added" | grep -niE -e "$pattern" || true)"
    if [ -n "$matches" ]; then
        if [ "$fail" -eq 0 ]; then
            echo "privacy-guard: BLOCKED — staged changes reintroduce private identity into the PUBLIC repo:" >&2
            echo >&2
        fi
        echo "  pattern /$pattern/ matched:" >&2
        printf '%s\n' "$matches" | sed 's/^/    /' | head -5 >&2
        fail=1
    fi
done < "$denylist"

if [ "$fail" -ne 0 ]; then
    echo >&2
    grep -E '^# hint:' "$denylist" | sed 's/^# hint:[[:space:]]*/  /' >&2 || true
    echo "  Fix the staged content, or bypass with: git commit --no-verify" >&2
    exit 1
fi

exit 0
