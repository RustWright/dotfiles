#!/usr/bin/env python3
"""Deliberately integrate submodule pointers into the parent repo — safely.

This is the *integration* half of the submodule sync model. The SessionEnd hook
never bumps pointers; you run this when you want the parent to reflect submodule
progress. For each submodule it records the pointer ONLY if the submodule's
current HEAD is already on its remote. Unpushed submodules are reported and
skipped, so this can never write a dangling gitlink — the invariant that makes
the whole workflow resilient to dirty, half-pushed, multi-device state.

Usage:
    sync_pointers.py [--repo PATH] [--dry-run]
"""

import argparse
import subprocess
import sys
from pathlib import Path


def git(args, cwd=None):
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True
    ).stdout.strip()


def submodule_paths(repo):
    out = git(["config", "-f", ".gitmodules", "--get-regexp", r"\.path$"], cwd=repo)
    return [line.split(None, 1)[1] for line in out.splitlines() if line.strip()]


def head_is_pushed(sub):
    head = git(["rev-parse", "HEAD"], cwd=sub)
    if not head:
        return False, head
    contained = git(["branch", "-r", "--contains", head], cwd=sub)
    return bool(contained), head


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    repo = Path(git(["rev-parse", "--show-toplevel"], cwd=args.repo) or args.repo)
    bumped, skipped = [], []

    for path in submodule_paths(repo):
        sub = repo / path
        recorded = git(["ls-tree", "HEAD", "--", path], cwd=repo).split()
        recorded_sha = recorded[2] if len(recorded) >= 3 else None
        pushed, head = head_is_pushed(sub)
        if not head or head == recorded_sha:
            continue  # uninitialized, or pointer already current
        if pushed:
            bumped.append((path, head))
            if not args.dry_run:
                git(["add", "--", path], cwd=repo)
        else:
            skipped.append((path, head))

    for path, head in bumped:
        print(f"{'[dry-run] ' if args.dry_run else ''}bump: {path} -> {head[:10]}")
    for path, head in skipped:
        print(f"SKIP (unpushed): {path} @ {head[:10]} — push the submodule first")

    if args.dry_run:
        return
    staged = subprocess.run(
        ["git", "diff", "--staged", "--quiet"], cwd=repo
    ).returncode
    if staged != 0:
        git(["commit", "-m", "sync: bump submodule pointers"], cwd=repo)
        print("committed pointer bumps — run `git push` to publish.")
    elif not skipped:
        print("nothing to integrate; parent pointers already current.")


if __name__ == "__main__":
    main()
