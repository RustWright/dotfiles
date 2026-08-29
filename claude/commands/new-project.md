# Create a new project

Projects live at `~/productive_learning/projects/`.

## Phase 1: Gather info (you do this in the main conversation)

**Arguments from the user:** $ARGUMENTS

Parse `$ARGUMENTS` as follows:
- `"<name>"` — project name only
- `"<name> --type simple"` — name + simple type
- `"<name> --type full"` — name + full-process type

**If name not provided:** Ask for it.

**If type not provided:** Ask the user:
> "Simple project (scripts, experiments, tools — minimal structure) or full-process (5-session PROJECT_PROCESS.md workflow with tracking files)?"

**For full-process only:** Ask for a one-line description of the project (used to pre-fill `project.md`).

Store: `PROJECT_NAME`, `PROJECT_TYPE` (simple|full), `PROJECT_DESCRIPTION` (full only).

## Phase 2: Delegate scaffolding to a subagent

Use the **Task tool** with `subagent_type: "general-purpose"` to do the file creation. Pass:
- `PROJECT_NAME`, `PROJECT_TYPE`, `PROJECT_DESCRIPTION` (if full)
- Today's date (for project.md frontmatter)
- The full scaffolding spec below

### Scaffolding spec (include this in the subagent prompt)

**Base path:** `~/productive_learning/projects/<PROJECT_NAME>/`

**Always create (both types):**
- `.log/` — empty directory (create a `.gitkeep` file inside)
- `CLAUDE.md` — generated content (see CLAUDE.md templates below)

**Do NOT copy `.mcp.json` or `mcp-servers/`** — the user will set those up manually per project if needed. The MCP config is sensitive and project-specific.

**For full-process only, additionally create:**
- `project.md` — copy `~/productive_learning/setup_files/project_template.md`, then fill in:
  - Replace the placeholder title/name with `PROJECT_NAME`
  - Replace the placeholder description with `PROJECT_DESCRIPTION`
  - Replace the placeholder date with today's date (YYYY-MM-DD)
- `PROJECT_PROCESS.md` — copy from `~/productive_learning/setup_files/PROJECT_PROCESS.md` verbatim
- `architecture.md` — placeholder file: `# Architecture\n\n_To be filled in during Session 2._`
- `tasks.md` — placeholder file: `# Tasks\n\n_To be filled in during Session 3._`
- `NEXT.md` — the instant-resume handoff, seeded so the project is never without one.
  SessionStart prints this file into context, so it is the first thing every future
  session reads. Seed it as:

  ```markdown
  # NEXT — <PROJECT_NAME>

  **Updated:** <today> · scaffolded, Session 1 not yet run

  ## Next action
  Run Session 1 (Initiation) — see `PROJECT_PROCESS.md`.

  ## Decisions in force
  _None yet. Decisions land here as they're settled, each with its one-line why._

  ## Do NOT re-survey
  _Nothing yet — the project is empty._

  ## Open threads
  _None yet._
  ```

### CLAUDE.md template — full-process

```markdown
# Claude Code Instructions

This project follows the structured process defined in `PROJECT_PROCESS.md`.

## Session Management

Git sync — start-of-session pull, end-of-session commit/push, and log + curiosity
parent-sync — is **automatic** via the session hooks. See `~/.claude/CLAUDE.md`
§ Session Sync. Do not run any of it by hand (no `git pull`, no `/export`, no manual
parent-sync); doing so fights the hooks.

Project-specific session steps:
- **Start:** `NEXT.md` has already been printed into your context by SessionStart —
  start from it. Trust it about **decisions**: if it says a choice is settled, or names
  files as not-worth-re-surveying, skip them. Never trust it about **state** — re-verify
  that live (`git status`, read what you'll touch). Then read `project.md` for the
  session log, and `tasks.md` / `architecture.md` if resuming mid-session.
- **On completing a stretch:** **Rewrite `NEXT.md` wholesale** — the moment the
  next action it names is done, abandoned, or redirected, before reporting it
  done. Not saved for session end: the hooks commit files but never invoke the
  model, so a sitting that ends mid-stretch commits the stale handoff. Max 40 lines; decisions and next action only, never a state snapshot.
  Also update `project.md`'s session log and `tasks.md` (Session 4) when a phase wraps.
  The transcript is rendered into `.log/` and synced to the parent automatically — no
  `/export` step.

### Session Flow Reference
```
Session 1: Initiation     → Define goals, users, success, motivation
Session 2: Architecture   → Tech decisions, MVP scope, risk review
Session 3: Planning       → Break work into tasks (tasks.md)
Session 4: Implementation → Build with velocity
Session 5: Testing        → User writes tests, review, close cycle

First cycle: 1 → 2 → 3 → 4 → 5
Subsequent:      3 → 4 → 5 (repeat)
```

## AI Role by Session

| Session | My Role |
|---------|---------|
| 1-3 | Interview (one question at a time), propose options with trade-offs, document decisions |
| 4 | Orchestrate implementation, track progress, maintain velocity |
| 5 | Minimal scaffolding for tests, assist only when user is blocked |

## Key Files
- `project.md` — Persistent tracker, decision summaries, session log
- `architecture.md` — Technical decisions with rationale (created Session 2)
- `tasks.md` — Current cycle's task list (created Session 3, reset each cycle)
- `.log/` — Raw conversation exports
```

### CLAUDE.md template — simple

```markdown
# <PROJECT_NAME>

<!-- One-line description of what this project does -->

## Commands

<!-- Fill in after setup. Example:
```bash
python main.py
uv run script.py
cargo run
```
-->

## Notes

<!-- Add relevant context, dependencies, or gotchas here -->
```

**Tell the subagent to:**
1. Create all the files using the Write tool
2. Create `~/productive_learning/logs/<PROJECT_NAME>/` with a `.gitkeep` file inside (so the parent repo tracks a slot for this project's logs from the start)
3. Run `git init` inside the project directory using the Bash tool
4. Run `git add -A && git commit -m "init: scaffold <PROJECT_NAME>"` inside the project directory
5. Report back: list of all files created, git init status

## Phase 3: Git remote + submodule (back in main conversation)

After the subagent completes, ask the user:

> "Do you want to push this to GitHub? If yes, create a repo at `github.com/RustWright/<PROJECT_NAME>` first (leave it empty — no README), then I'll add the remote and register it as a submodule."

**If yes:**
- Run: `git -C ~/productive_learning/projects/<PROJECT_NAME> remote add origin https://github.com/RustWright/<PROJECT_NAME>.git`
- Run: `git -C ~/productive_learning/projects/<PROJECT_NAME> push -u origin main`
- Register as submodule in the parent repo:
  ```bash
  # Add entry to ~/productive_learning/.gitmodules
  # Then stage and commit from productive_learning/
  git -C ~/productive_learning add .gitmodules projects/<PROJECT_NAME>
  git -C ~/productive_learning commit -m "add <PROJECT_NAME> as submodule"
  ```

**If no:** Leave as local git repo. Remind user they can register it as a submodule later with `/new-project` or manually.

## Phase 4: Confirm

Report to the user:
1. Full file list created
2. Git init status (and push status if applicable)
3. **For full-process:** "Ready for Session 1 whenever you want to start — just open the project and I'll read `project.md`."
4. **For simple:** "Remember to fill in the `CLAUDE.md` with your run commands and any useful notes."
