## Session Sync Protocol

### At the START of every session (do this first, before anything else):
If the current directory is a git repo, run:
```bash
git pull --rebase --autostash
```

### At the END of every session (before closing):
If there are uncommitted changes:
1. Stage all changes: `git add -A`
2. Commit with a concise message describing what was done
3. Push: `git push`

**Commit message format (SINGLE LINE, under 50 chars):**
- `Session N: Brief topic`
- `[type]: Brief description`
- NO multi-line commits, NO co-author tags, NO emoji

### Submodule pointer updates (productive-learning)
When a project repo (submodule) advances, update the parent pointer weekly or when switching machines:
```bash
# From ~/productive_learning/
git add projects/mylearnbase  # or img_gen
git commit -m "update mylearnbase submodule pointer"
git push
```
