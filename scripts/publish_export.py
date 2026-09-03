#!/usr/bin/env python3
"""Publish an allowlisted, scrubbed export of a private repo to a public one.

THE INVARIANT: nothing is published unless a manifest names it. A project with no
`.publish.ini` cannot be published at all — the script refuses. That is the whole
point. The recipe this replaces was a BLOCKLIST (`filter-repo --invert-paths`),
which fails OPEN: every file added to the private repo after the list was written
gets published by default, and you find out afterwards. On 2026-09-03 that had
already silently queued `CLAUDE.md` and `NEXT.md` — both naming the private repo —
for publication to a public one. An allowlist fails CLOSED: an unlisted new file is
simply absent, and the run reports it as held back.

Three guards sit between the manifest and the push, because a manifest can be wrong:

  1. REMOTE GUARD — refuses if the public URL is already a remote of the private
     repo. That misconfiguration means the ordinary session-end `git push` publishes
     everything, with no export step involved at all.
  2. PATH VERIFICATION — after the rewrite, every path in EVERY commit of the new
     history (not merely HEAD) is checked against the allowlist. A survivor aborts
     the run before the push.
  3. CONTENT TRIPWIRE — greps the rewritten blobs AND commit messages for strings
     the manifest forbids. Catches the case the path allowlist cannot see: an
     allowlisted file that *mentions* private material.

Rewriting changes every SHA, so the public history is a separate lineage rather
than an ancestor of the private one. The force-push is expected, not a warning
sign. The public remote is only ever added inside a throwaway clone; this script
never touches the private repo's own remotes.

Usage:
    publish_export.py [--repo PATH] [--dry-run] [--yes] [--keep]

    --dry-run   do everything except the push, and report what would ship
    --yes       skip the interactive confirmation (required for the real push
                when stdin is not a terminal)
    --keep      leave the throwaway clone on disk for inspection
"""

import argparse
import configparser
import fnmatch
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

MANIFEST = ".publish.ini"


def git(args, cwd=None, check=False):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        die(f"git {' '.join(args)} failed:\n{r.stderr.strip()}")
    return r.stdout.strip()


def die(msg):
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def read_list(cfg, section, option):
    """Multi-line INI value -> list. Blank lines and '#' comments dropped.

    configparser keeps '#' lines inside a multi-line value, so they are stripped
    here; that is what lets a manifest annotate its own allowlist.
    """
    if not cfg.has_option(section, option):
        return []
    raw = cfg.get(section, option)
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def path_allowed(path, rules):
    """Mirror filter-repo's --paths-from-file matching for verification.

    literal (the default): exact file, or a directory prefix.
    'glob:' / 'regex:' prefixes behave as filter-repo documents them.
    """
    for rule in rules:
        if rule.startswith("glob:"):
            if fnmatch.fnmatch(path, rule[5:]):
                return True
        elif rule.startswith("regex:"):
            if re.search(rule[6:], path):
                return True
        else:
            lit = rule[8:] if rule.startswith("literal:") else rule
            if lit.endswith("/"):
                if path.startswith(lit):
                    return True
            elif path == lit or path.startswith(lit + "/"):
                return True
    return False


def all_paths_in_history(repo):
    """Every path in every commit — not just HEAD.

    A file deleted before HEAD still sits in the history's older trees, reachable
    through the API and through clones. Verifying HEAD alone would miss exactly the
    leak this script exists to prevent.
    """
    paths = set()
    for commit in git(["rev-list", "--all"], cwd=repo).split():
        paths.update(git(["ls-tree", "-r", "--name-only", commit], cwd=repo).splitlines())
    return paths


def tripwire_hits(repo, needles):
    """Search rewritten blobs and commit messages for forbidden strings."""
    hits = []
    commits = git(["rev-list", "--all"], cwd=repo).split()
    for needle in needles:
        r = subprocess.run(
            ["git", "grep", "-F", "-I", "-n", "-e", needle, *commits],
            cwd=repo, capture_output=True, text=True,
        )
        for line in r.stdout.splitlines()[:5]:
            hits.append(f"content: {line}")
        messages = git(["log", "--all", "--format=%H %s%n%b"], cwd=repo)
        for line in messages.splitlines():
            if needle in line:
                hits.append(f"commit message: {line.strip()[:120]}")
                break
    return hits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    root = git(["rev-parse", "--show-toplevel"], cwd=args.repo)
    if not root:
        die(f"{args.repo} is not a git repository.")
    root = Path(root)

    # ── manifest: absent means not publishable, deliberately ──────────────────
    manifest = root / MANIFEST
    if not manifest.is_file():
        die(
            f"no {MANIFEST} in {root} — this project is not set up for publishing.\n"
            f"       That is the safe default, not an error. To make it publishable,\n"
            f"       write a {MANIFEST} allowlist; see ~/.dotfiles/scripts/publish_export.py."
        )

    cfg = configparser.ConfigParser()
    cfg.read(manifest)
    if not cfg.has_option("publish", "remote"):
        die(f"{MANIFEST} has no [publish] remote.")
    remote_url = cfg.get("publish", "remote").strip()
    branch = cfg.get("publish", "branch", fallback="main").strip()
    allow = read_list(cfg, "paths", "allow")
    deny = read_list(cfg, "tripwire", "deny")
    if not allow:
        die(f"{MANIFEST} has an empty [paths] allow list — nothing would be published.")

    # ── guard 1: the public URL must not be a remote of the private repo ──────
    for line in git(["remote", "-v"], cwd=root).splitlines():
        if remote_url.rstrip("/").removesuffix(".git") in line:
            die(
                f"the public URL is configured as a remote of the PRIVATE repo:\n"
                f"       {line}\n"
                f"       Remove it. With that remote present, an ordinary `git push`\n"
                f"       publishes everything and this export step is bypassed entirely."
            )

    print(f"repo:     {root}")
    print(f"target:   {remote_url} ({branch})")
    print(f"manifest: {len(allow)} allow rule(s), {len(deny)} tripwire string(s)")

    # ── report what the export cannot see, rather than dropping it silently ───
    dirty = git(["status", "--porcelain"], cwd=root)
    if dirty:
        n = len(dirty.splitlines())
        print(f"\nNOTE: {n} uncommitted change(s) in the private repo. The export reads")
        print("      committed history only, so these are NOT included.")
    if not git(["branch", "-r", "--contains", "HEAD"], cwd=root):
        print("\nNOTE: private HEAD is not on its own remote. You are about to publish")
        print("      commits that are not yet backed up privately.")

    # ── rewrite in a throwaway clone; the private repo is never touched ───────
    tmp = Path(tempfile.mkdtemp(prefix="publish-export-"))
    clone = tmp / root.name
    try:
        git(["clone", "--no-hardlinks", "--quiet", str(root), str(clone)], check=True)

        paths_file = tmp / "allow.txt"
        paths_file.write_text("\n".join(allow) + "\n")

        r = subprocess.run(
            ["git", "filter-repo", "--paths-from-file", str(paths_file), "--force"],
            cwd=clone, capture_output=True, text=True,
        )
        if r.returncode != 0:
            die(f"filter-repo failed:\n{r.stdout.strip()}\n{r.stderr.strip()}")

        if not git(["rev-list", "--all"], cwd=clone):
            die("the rewrite produced an empty history — check the allow list.")

        # ── guard 2: nothing outside the allowlist survived, in ANY commit ────
        survivors = all_paths_in_history(clone)
        leaked = sorted(p for p in survivors if not path_allowed(p, allow))
        if leaked:
            die(
                "paths survived the rewrite that the allowlist does not permit:\n"
                + "\n".join(f"       {p}" for p in leaked)
            )

        # ── guard 3: forbidden strings in content or commit messages ──────────
        if deny:
            hits = tripwire_hits(clone, deny)
            if hits:
                die(
                    "tripwire strings found in the export:\n"
                    + "\n".join(f"       {h}" for h in hits)
                )

        # ── report: what ships, and what was held back ────────────────────────
        published = sorted(git(["ls-tree", "-r", "--name-only", "HEAD"], cwd=clone).splitlines())
        private_head = set(git(["ls-files"], cwd=root).splitlines())
        held = sorted(private_head - set(published))

        print(f"\nWOULD PUBLISH ({len(published)} paths, {len(git(['rev-list', '--all'], cwd=clone).split())} commits):")
        for p in published:
            print(f"  + {p}")
        print(f"\nHELD BACK ({len(held)} tracked path(s) staying private):")
        for p in held:
            print(f"  - {p}")
        print("\nall three guards passed: remote, path verification, content tripwire.")

        if args.dry_run:
            print(f"\n--dry-run: nothing pushed.")
            if args.keep:
                print(f"clone kept at {clone}")
            return

        if not args.yes:
            if not sys.stdin.isatty():
                die("refusing to push non-interactively without --yes.")
            reply = input(f"\nforce-push this to {remote_url} ({branch})? [y/N] ")
            if reply.strip().lower() not in ("y", "yes"):
                print("aborted by user; nothing pushed.")
                return

        # filter-repo drops `origin` so a rewritten history cannot be pushed back
        # to its source. Re-adding the PUBLIC url here, in the throwaway clone, is
        # the only place these two lineages ever meet.
        git(["remote", "remove", "origin"], cwd=clone)
        git(["remote", "add", "public", remote_url], cwd=clone)
        subprocess.run(["git", "fetch", "--quiet", "public", branch], cwd=clone,
                       capture_output=True, text=True)
        remote_sha = git(["rev-parse", f"public/{branch}"], cwd=clone)

        if remote_sha:
            # Lease against what we just fetched: refuses if the public branch moved
            # underneath us. Histories never share ancestry, so a plain --force would
            # silently clobber a push made from elsewhere.
            push = ["push", f"--force-with-lease={branch}:{remote_sha}", "public", f"HEAD:{branch}"]
        else:
            push = ["push", "public", f"HEAD:{branch}"]  # empty remote; nothing to clobber

        r = subprocess.run(["git", *push], cwd=clone, capture_output=True, text=True)
        if r.returncode != 0:
            die(f"push failed:\n{r.stderr.strip()}")
        print(f"\npushed to {remote_url} ({branch}).")
        print("verify the held-back paths 404 on the public repo.")

    finally:
        if args.keep:
            print(f"clone left at {clone}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
