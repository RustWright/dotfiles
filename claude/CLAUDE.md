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
3. From the parent: `git add -A && git commit -m "sync <project-name>: <brief description>" && git push`

This keeps the parent's submodule pointer current and syncs logs to the private repo in one step.

**Commit message format (SINGLE LINE, under 50 chars):**
- `Session N: Brief topic`
- `[type]: Brief description`
- NO multi-line commits, NO co-author tags, NO emoji
