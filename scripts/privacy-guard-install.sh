#!/usr/bin/env bash
#
# Install privacy-guard.sh on one PUBLIC repo, on this device.
#
# Per-device because both halves are deliberately absent from the public repo:
#   - the denylist is gitignored there, since it lists the exact strings that must
#     never appear in public history; its canonical copy lives in a private repo;
#   - git never clones hooks, and never clones `core.hooksPath` either.
# So a fresh clone has only credential-shape protection until this runs.
#
# Two hook layouts, picked by what the repo already has:
#   - a tracked `.githooks/pre-commit` (mylearnbase): set core.hooksPath to it. That
#     hook calls privacy-guard.sh itself, after its own work.
#   - none (omni-me): write a wrapper into the git dir's hooks/ that calls the guard.
#
#   usage: privacy-guard-install.sh <public-repo> <canonical-denylist>
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
target="${1:?usage: $0 <public-repo> <canonical-denylist>}"
src="${2:?usage: $0 <public-repo> <canonical-denylist>}"
target="$(cd "$target" && pwd)"

git -C "$target" rev-parse --git-dir >/dev/null
[ -f "$src" ] || { echo "no denylist at $src" >&2; exit 1; }

# The denylist must be gitignored BEFORE it lands, or the next `git add -A` from a
# session hook publishes it, which is the one outcome this whole thing exists to stop.
if ! git -C "$target" check-ignore -q .private-identity-denylist; then
    echo "!! .private-identity-denylist is NOT gitignored in $target. Add it first." >&2
    exit 1
fi
install -m 0644 "$src" "$target/.private-identity-denylist"
echo ">> denylist -> $target/.private-identity-denylist"

if [ -f "$target/.githooks/pre-commit" ]; then
    git -C "$target" config core.hooksPath .githooks
    echo ">> hooks    -> core.hooksPath = .githooks"
else
    # Submodules keep their real git dir elsewhere, so ask git rather than assuming.
    git_dir="$(git -C "$target" rev-parse --absolute-git-dir)"
    mkdir -p "$git_dir/hooks"
    cat > "$git_dir/hooks/pre-commit" <<EOF
#!/usr/bin/env bash
# Installed by privacy-guard-install.sh. Fails CLOSED if the shared guard is gone:
# a commit that cannot be checked is refused rather than waved through.
guard="$here/privacy-guard.sh"
[ -x "\$guard" ] || { echo "privacy-guard: \$guard missing; commit refused." >&2; exit 1; }
exec "\$guard"
EOF
    chmod 0755 "$git_dir/hooks/pre-commit"
    echo ">> hook     -> $git_dir/hooks/pre-commit"
fi

# Verify rather than assume: a guard that silently fails to match is worse than no
# guard, because it invites trust. Stage a probe carrying the first denylist pattern
# (as literal text) and require the commit to be refused.
term="$(grep -vE '^#|^[[:space:]]*$' "$src" | head -1 || true)"
if [ -n "$term" ]; then
    probe=".privacy-guard-probe"
    cleanup() { git -C "$target" reset -q HEAD -- "$probe" 2>/dev/null || true; rm -f "$target/$probe"; }
    trap cleanup EXIT
    printf 'probe %s\n' "$term" > "$target/$probe"
    git -C "$target" add -f -- "$probe"
    if git -C "$target" commit -q -m "probe" >/dev/null 2>&1; then
        git -C "$target" reset -q --soft HEAD~1
        echo "!! self-test FAILED — the guard did NOT block. Do not rely on it." >&2
        exit 1
    fi
    echo ">> self-test PASSED — the guard blocks a denylisted term"
fi
echo ">> done."
