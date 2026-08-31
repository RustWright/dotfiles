# dotfiles

Claude Code config for RustWright's dev setup.

## Setup (new device)

```bash
git clone https://github.com/RustWright/dotfiles ~/.dotfiles && ~/.dotfiles/setup.sh
```

This symlinks commands, skills, and settings into `~/.claude/`.

## Contents

```
claude/
├── CLAUDE.md               # Global instructions (session sync, memory, curiosities)
├── commands/
│   ├── create-post.md      # Draft a new blog post for mylearnbase
│   ├── new-project.md      # Scaffold a new project
│   └── sync-dotfiles.md    # Pull latest config from this repo
├── skills/
│   ├── config-conflict/    # Surface instruction-vs-config contradictions
│   ├── dx-new/             # Dioxus project scaffolding
│   └── session-audit/      # Close-out audit by failure mode
└── settings.json           # Feature flags and hooks
scripts/
├── session-start.sh        # SessionStart: pull dotfiles, claude-state, repo, submodules
├── session-compact.sh      # PreCompact: checkpoint (/compact never fires SessionEnd)
├── session-end.sh          # SessionEnd: file log, commit + push, guarded pointer bump
├── file-session-log.py     # Render the transcript into .log/ under a stable name
├── render_session.py       # .jsonl -> readable .txt
└── sync_pointers.py        # Deliberate submodule pointer integration (never automatic)
git/
└── ignore                  # Global gitignore -> ~/.config/git/ignore (every repo, this device)
setup.sh                    # Run this after cloning
```

The three session hooks are the whole sync mechanism — see `claude/CLAUDE.md`
§ Session Sync for what each one does and why. Nothing here should be run by hand
except `sync_pointers.py`, which is deliberately manual.

## Cross-device state

Memory notes and saved plans live in a **separate private repo**, `claude-state`,
which is `~/.claude` itself. It is not part of this repo and is not cloned by
`setup.sh` — see `claude/CLAUDE.md` § Session Sync for the layout and the
deny-by-default ignore rule.

## Adding new commands

1. Create the file in `~/.dotfiles/claude/commands/new-thing.md`
2. Run `~/.dotfiles/setup.sh` to symlink it
3. `git -C ~/.dotfiles add -A && git commit -m "add new-thing command" && git push`

Since `~/.claude/commands/` files are symlinks, edits via Claude Code write directly to this repo.

## Sync on existing device

```
/sync-dotfiles
```
