#!/usr/bin/env python3
"""File the current session's transcript into the repo's .log/ directory.

Called by the SessionEnd hook. Locates the harness's .jsonl for this session,
renders it to readable text via render-session.py, and writes it to .log/ so it
can be committed and synced across devices - replacing the manual
/export -> hand-typed-filename -> copy ritual.

Usage:
    file-session-log.py [--session-id ID] [--repo PATH] [--dry-run]
"""

import argparse
import hashlib
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_session import render  # noqa: E402  (sibling script)

PROJECTS_DIR = Path.home() / ".claude" / "projects"


def slug_for(path):
    """~/.claude/projects flattens the cwd: '/' and '_' both become '-'."""
    return str(Path(path).resolve()).replace("/", "-").replace("_", "-")


def find_transcript(repo, session_id=None):
    """Locate this session's .jsonl, falling back to the newest for this repo."""
    project_dir = PROJECTS_DIR / slug_for(repo)
    if not project_dir.is_dir():
        return None
    if session_id:
        candidate = project_dir / f"{session_id}.jsonl"
        if candidate.is_file():
            return candidate
    transcripts = sorted(
        (p for p in project_dir.glob("*.jsonl") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return transcripts[0] if transcripts else None


def git_repo_root(start):
    try:
        out = subprocess.run(
            ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return Path(out.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def session_start(transcript):
    """The session's start time - the first transcript record's own timestamp.

    Naming by START time (not mtime) is what keeps a growing session under ONE
    filename: /compact and SessionEnd re-render the same, longer session and must
    overwrite the same file rather than leave stale partial duplicates. The start
    timestamp is fixed for the life of the session, so the name is stable across
    re-files while distinct sessions still sort chronologically by name. Falls
    back to mtime if the transcript has no parseable timestamp.
    """
    try:
        with transcript.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                ts = json.loads(line).get("timestamp")
                if ts:
                    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    return datetime.fromtimestamp(transcript.stat().st_mtime)


def choose_log_path(log_dir, transcript, rendered):
    """Decide the filename for this session's log, and whether to write at all.

    Design responds to three documented archive failures:
      - a byte-identical duplicate session (a `--` filename-typo collision),
      - a log misdated because the filename used 'today' for a session that had
        actually run the day before, and
      - same-day logs the date-only name couldn't order (which came first?).

    So the name carries the session's START time to the second, so same-day logs
    sort chronologically from the title alone; dedup is by CONTENT - if this exact
    transcript is already filed under any name, skip. Naming by start-time +
    session-id keeps files unique without the collision counter that produced the
    `-pt2` duplicates, and re-filing the same (grown) session overwrites its own
    file idempotently because the start time doesn't move.

    Returns a Path to write to, or None to skip writing.
    """
    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    if log_dir.is_dir():
        for existing in log_dir.glob("*.txt"):
            try:
                if hashlib.sha256(existing.read_bytes()).hexdigest() == digest:
                    return None  # already filed, byte-for-byte
            except OSError:
                continue

    stamp = session_start(transcript).strftime("%Y-%m-%d-%H%M%S")
    session_short = transcript.stem[:8]
    return log_dir / f"{stamp}-session-{session_short}.txt"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-id")
    parser.add_argument("--repo", default=".", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    repo = git_repo_root(args.repo)
    if repo is None:
        sys.exit("not inside a git repository - nothing to file")

    transcript = find_transcript(repo, args.session_id)
    if transcript is None:
        sys.exit(f"no transcript found for {repo}")

    rendered = render(transcript)
    if not rendered:
        sys.exit("transcript contained no renderable turns")

    target = choose_log_path(repo / ".log", transcript, rendered)
    if target is None:
        print("skipped: choose_log_path declined to write")
        return

    if args.dry_run:
        print(f"[dry-run] would write {target} ({len(rendered):,} bytes)")
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(rendered, encoding="utf-8")
    print(f"filed {target} ({len(rendered):,} bytes)")


if __name__ == "__main__":
    main()
