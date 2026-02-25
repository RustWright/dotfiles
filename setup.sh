#!/bin/bash
# Links Claude Code config files from ~/.dotfiles into ~/.claude/
# Safe to run multiple times — ln -sf is idempotent

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p ~/.claude/commands ~/.claude/skills

for f in "$DIR/claude/commands/"*.md; do
  ln -sf "$f" ~/.claude/commands/"$(basename "$f")"
  echo "linked: ~/.claude/commands/$(basename "$f")"
done

for d in "$DIR/claude/skills/"/*/; do
  ln -sfn "$d" ~/.claude/skills/"$(basename "$d")"
  echo "linked: ~/.claude/skills/$(basename "$d")"
done

ln -sf "$DIR/claude/settings.json" ~/.claude/settings.json
echo "linked: ~/.claude/settings.json"

ln -sf "$DIR/claude/CLAUDE.md" ~/.claude/CLAUDE.md
echo "linked: ~/.claude/CLAUDE.md"

echo ""
echo "Done — Claude config linked from dotfiles."
