#!/usr/bin/env python3
"""Render a Claude Code .jsonl session transcript into a readable .txt log.

The harness already persists every session to
~/.claude/projects/<slug>/<session-id>.jsonl. This turns that into the same
human-readable conversation flow that /export produced, so session logs can be
filed into the repo automatically instead of by hand.

Usage:
    render-session.py <session.jsonl> [-o output.txt]
    render-session.py <session.jsonl> --stdout
"""

import argparse
import json
import sys
from pathlib import Path

# Record types that carry no conversation content.
SKIP_TYPES = {
    "attachment", "queue-operation", "mode", "permission-mode",
    "ai-title", "last-prompt", "file-history-snapshot",
}

# Tool inputs whose first named field reads best as the call summary.
SUMMARY_FIELDS = (
    "command", "file_path", "pattern", "query", "path",
    "prompt", "url", "description", "skill",
)


def summarize_tool_input(name, tool_input):
    """One-line summary of a tool call, e.g. Bash(git status)."""
    if not isinstance(tool_input, dict):
        return name
    for field in SUMMARY_FIELDS:
        if field in tool_input:
            value = str(tool_input[field]).replace("\n", " ").strip()
            return f"{name}({value})"
    return name


def render_tool_result(content, is_error=False, max_chars=2000, head=1200, tail=600):
    """Decide how much of a tool result to keep in the readable transcript.

    Policy is deliberately simple - this is setup tooling that has to track
    harness changes, so it favours maintainability over cleverness:

      - Errors are preserved WHOLE, regardless of length. They are the single
        highest-value thing in a log when you return to understand a session,
        and are usually short anyway.
      - Everything else is kept whole up to `max_chars`; beyond that it is
        head+tail truncated with an elided-middle marker, so both the start
        (what the command was doing) and the end (final state / trailing error)
        survive. A flat head-only cut would drop errors that surface last.

    Args:
        content:  the tool's full output as a string (may be very long)
        is_error: whether the harness flagged this result as an error
        max_chars/head/tail: truncation budget for non-error output

    Returns:
        the string to embed (caller handles indentation); "" omits the body.
    """
    text = (content or "").rstrip()
    if not text:
        return ""
    if is_error or len(text) <= max_chars:
        return text
    elided = len(text) - head - tail
    return f"{text[:head]}\n     … [{elided:,} chars elided] …\n{text[-tail:]}"


def indent_block(text, prefix="  ⎿  ", cont="     "):
    """Indent a result block: first line gets the elbow, the rest align under it."""
    if not text:
        return ""
    lines = text.split("\n")
    out = [prefix + lines[0]]
    out.extend(cont + line for line in lines[1:])
    return "\n".join(out)


def build_header(first_record):
    """Recreate the banner /export put at the top of each log."""
    version = first_record.get("version", "unknown")
    cwd = first_record.get("cwd", "")
    branch = first_record.get("gitBranch", "")
    home = str(Path.home())
    if cwd.startswith(home):
        cwd = "~" + cwd[len(home):]
    lines = [
        f" ▐▛███▜▌   Claude Code v{version}",
        f"▝▜█████▛▘  {cwd}",
    ]
    if branch:
        lines.append(f"  ▘▘ ▝▝    branch: {branch}")
    return "\n".join(lines) + "\n\n"


def render(jsonl_path):
    records = []
    with open(jsonl_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    if not records:
        return ""

    # The first line is often a metadata record with no version/cwd; use the
    # first record that actually carries them for the banner.
    header_src = next(
        (r for r in records if r.get("version") and r.get("cwd")), records[0]
    )
    out = [build_header(header_src)]

    for record in records:
        rtype = record.get("type")

        # Hook output arrives as an `attachment`, which is otherwise skipped as
        # noise. Keep it: the session hooks are this workflow's only self-report,
        # and their stdout is the sole evidence that sync/pull/handoff actually
        # ran. Without it "did the hook fire?" is unanswerable after the fact —
        # the same failure shape as a push that swallowed its own error.
        if rtype == "attachment":
            att = record.get("attachment")
            if isinstance(att, dict) and str(att.get("type", "")).startswith("hook_"):
                name = att.get("hookName") or att.get("hookEvent") or "hook"
                code = att.get("exitCode")
                ms = att.get("durationMs")
                bits = []
                if code is not None:
                    bits.append(f"exit {code}")
                if isinstance(ms, (int, float)):
                    bits.append(f"{ms / 1000:.1f}s")
                head = f"⚙ {name}" + (f" ({', '.join(bits)})" if bits else "")
                body = []
                for label, stream in (("", att.get("stdout")), ("stderr: ", att.get("stderr"))):
                    text = (stream or "").strip()
                    if text:
                        body += [f"    {label}{ln}" for ln in text.splitlines()]
                out.append(head + "\n" + ("\n".join(body) + "\n" if body else "") + "\n")
            continue

        if rtype in SKIP_TYPES:
            continue
        # Subagent turns live in their own transcript files; keep the main log clean.
        if record.get("isSidechain"):
            continue

        message = record.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content")

        if rtype == "user":
            if isinstance(content, str):
                text = content.strip()
                if text:
                    out.append(f"❯ {text}\n\n")
            elif isinstance(content, list):
                for block in content:
                    if block.get("type") != "tool_result":
                        continue
                    raw = block.get("content")
                    if isinstance(raw, list):
                        raw = "\n".join(
                            part.get("text", "")
                            for part in raw
                            if isinstance(part, dict)
                        )
                    body = render_tool_result(str(raw or ""), block.get("is_error", False))
                    if body:
                        out.append(indent_block(body) + "\n\n")

        elif rtype == "assistant" and isinstance(content, list):
            for block in content:
                btype = block.get("type")
                if btype == "text":
                    text = block.get("text", "").strip()
                    if text:
                        out.append(f"● {text}\n\n")
                elif btype == "tool_use":
                    summary = summarize_tool_input(
                        block.get("name", "Tool"), block.get("input")
                    )
                    out.append(f"● {summary}\n")
                # 'thinking' blocks carry no readable text (signature only) - skipped.

    return "".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", type=Path, help="path to the session .jsonl")
    parser.add_argument("-o", "--output", type=Path, help="output .txt path")
    parser.add_argument("--stdout", action="store_true", help="write to stdout")
    args = parser.parse_args()

    if not args.jsonl.is_file():
        sys.exit(f"no such transcript: {args.jsonl}")

    text = render(args.jsonl)
    if not text:
        sys.exit("transcript contained no renderable turns")

    if args.stdout or not args.output:
        sys.stdout.write(text)
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
        print(f"wrote {args.output} ({len(text):,} bytes)")


if __name__ == "__main__":
    main()
