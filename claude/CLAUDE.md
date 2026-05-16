## Session Sync Protocol

### At the START of every session (do this first, before anything else):
If the current directory is a git repo, run:
```bash
git pull --rebase --autostash
git submodule update --init --recursive
```

### At the END of every session (before closing):

**Step 1 — Commit and push the current repo:**
1. Stage all changes: `git add -A`
2. Commit with a concise message describing what was done
3. Push: `git push`

**Step 2 — If inside a submodule, sync to the parent repo:**

Check: `git rev-parse --show-superproject-working-tree`

If that returns a path (you are in a submodule):
1. Identify the parent path (output of the above command)
2. Copy any files from `.log/` into `<parent>/logs/<project-name>/`
3. Copy any files from `.curiosities/` into `<parent>/curiosities/<project-name>/` (skip if `.curiosities/` doesn't exist)
4. From the parent: `git add -A && git commit -m "sync <project-name>: <brief description>" && git push`

This keeps the parent's submodule pointer current and syncs logs + curiosities to the private repo in one step.

**Commit message format (SINGLE LINE, under 50 chars):**
- `Session N: Brief topic`
- `[type]: Brief description`
- NO multi-line commits, NO co-author tags, NO emoji

## Curiosity Capture

While working on any project, watch for **curiosities** — concepts the user surfaces but doesn't fully grasp. Triggers:

- User asks "how does X actually work?" or "I don't really get this"
- You half-explain something technical and the user moves on without engaging
- The user pauses on a concept (longer reaction, off-tangent question) suggesting it didn't land

When you notice one, append a one-line entry to the project's curiosity log. Bias toward capturing — false positives are cheap; missed captures are unrecoverable. The cycle-close review pass decides what survives.

**Where to write:** `<project-repo>/.curiosities/<cycle-id>.md`

- Resolve `<cycle-id>` by grepping `project.md` for `Cycle \d+` (matches both `**Status:** Cycle 3 Session 5` and `**Current Phase:** Cycle 2 Session 4`). Use the highest-numbered cycle found. Filename: `cycle-<N>.md`.
- If no `project.md` or no `Cycle \d+` match: filename is `current.md`.
- If the `.curiosities/` directory doesn't exist in the project repo: create it AND add `.curiosities/` to the project's `.gitignore` (mirrors the `.log/` pattern — gitignored in the submodule, parent-synced at session end).

**Entry format:** `- [YYYY-MM-DD] <one-line curiosity>; <one-line trigger context>`

Example: `- [2026-05-15] How do hashes actually work?; came up while implementing SHA-256 upload validation`

This feeds the **concepts** post form on mylearnbase — surviving curiosities at cycle close become candidates for interactive-demo-driven posts. The form is documented in `~/productive_learning/projects/mylearnbase/editorial/concepts.md` for sessions working in that repo.
