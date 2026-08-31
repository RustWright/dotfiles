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

# Global gitignore. Unlike everything above, this path may already hold a REAL file
# that predates the dotfiles repo and that no other device has a copy of — clobbering
# it with `ln -sf` would destroy rules found nowhere else. So: back up anything that
# is a real file and differs from ours, and say so loudly. Content-identical files are
# replaced silently (nothing is lost); an existing symlink is just repointed.
mkdir -p ~/.config/git
# Compare EFFECTIVE RULES, not bytes: ours carries explanatory comments the older
# hand-written copies do not, so a byte compare would "differ" on every existing
# device and litter each one with a pointless backup and a scary warning.
git_ignore_rules() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | sed 's/[[:space:]]*$//' | sort; }
if [ -f ~/.config/git/ignore ] && [ ! -L ~/.config/git/ignore ]; then
  if [ "$(git_ignore_rules ~/.config/git/ignore)" = "$(git_ignore_rules "$DIR/git/ignore")" ]; then
    rm -f ~/.config/git/ignore
  else
    BAK=~/.config/git/ignore.bak-$(date +%Y%m%d-%H%M%S)
    mv ~/.config/git/ignore "$BAK"
    echo "NOTE: existing ~/.config/git/ignore differed — backed up to $BAK"
    echo "      Merge any rules it had into $DIR/git/ignore, then delete the backup."
  fi
fi
ln -sf "$DIR/git/ignore" ~/.config/git/ignore
echo "linked: ~/.config/git/ignore"

echo ""
echo "Done — Claude config linked from dotfiles."
