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
├── commands/
│   ├── create-post.md      # Draft a new blog post for mylearnbase
│   ├── new-project.md      # Scaffold a new project
│   └── sync-dotfiles.md    # Pull latest config from this repo
├── skills/
│   └── dx-new/             # Dioxus project scaffolding
└── settings.json           # Feature flags and hooks
scripts/
└── session-end.sh          # Stop hook: auto-commit if Claude didn't
setup.sh                    # Run this after cloning
```

## Adding new commands

1. Create the file in `~/.dotfiles/claude/commands/new-thing.md`
2. Run `~/.dotfiles/setup.sh` to symlink it
3. `git -C ~/.dotfiles add -A && git commit -m "add new-thing command" && git push`

Since `~/.claude/commands/` files are symlinks, edits via Claude Code write directly to this repo.

## Sync on existing device

```
/sync-dotfiles
```
