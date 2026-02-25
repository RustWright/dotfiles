# Sync dotfiles from remote

1. Pull latest from the dotfiles repo:
   ```bash
   git -C ~/.dotfiles pull --rebase
   ```

2. Re-run setup to pick up any new files:
   ```bash
   ~/.dotfiles/setup.sh
   ```

3. Report what changed:
   ```bash
   git -C ~/.dotfiles diff HEAD@{1} --name-only
   ```
