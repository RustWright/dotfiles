# Create a new project

Projects live at `/home/me/productive_learning/projects/`.

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

**Base path:** `/home/me/productive_learning/projects/<PROJECT_NAME>/`

**Always create (both types):**
- `.log/` — empty directory (create a `.gitkeep` file inside)
- `CLAUDE.md` — generated content (see CLAUDE.md templates below)

**Do NOT copy `.mcp.json` or `mcp-servers/`** — the user will set those up manually per project if needed. The MCP config is sensitive and project-specific.

**For full-process only, additionally create:**
- `project.md` — copy `/home/me/productive_learning/setup_files/project_template.md`, then fill in:
  - Replace the placeholder title/name with `PROJECT_NAME`
  - Replace the placeholder description with `PROJECT_DESCRIPTION`
  - Replace the placeholder date with today's date (YYYY-MM-DD)
- `PROJECT_PROCESS.md` — copy from `/home/me/productive_learning/setup_files/PROJECT_PROCESS.md` verbatim
- `architecture.md` — placeholder file: `# Architecture\n\n_To be filled in during Session 2._`
- `tasks.md` — placeholder file: `# Tasks\n\n_To be filled in during Session 3._`

### CLAUDE.md template — full-process

```markdown
# Claude Code Instructions

This project follows the structured process defined in `PROJECT_PROCESS.md`.

## Session Management

### At Session Start
1. Read `project.md` to understand current state and which session comes next
2. Read `PROJECT_PROCESS.md` if needed to refresh on session details
3. Confirm with user which session we're starting
4. If resuming mid-session, read relevant files (`tasks.md`, `architecture.md`) for context

### At Session End
When the user indicates they want to end the session or take a break or the session comes to its natural conclusion:

1. **Remind user to export:** Ask them to run `/export` command
2. **Provide filename:** `session-0X-[type]-cycle-Y.txt`
   - Examples: `session-01-initiation.txt`, `session-03-planning-cycle-1.txt`
3. **Confirm save location:** `.log/` directory
4. **Update project.md:** Add/update session summary in the Session Log section
5. **Update tasks.md:** If Session 4, ensure task statuses are current
6. **Suggest commit:** Remind user to commit changes if appropriate

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
2. Run `git init` inside the project directory using the Bash tool
3. Run `git add -A && git commit -m "init: scaffold <PROJECT_NAME>"` inside the project directory
4. Report back: list of all files created, git init status

## Phase 3: Git remote + submodule (back in main conversation)

After the subagent completes, ask the user:

> "Do you want to push this to GitHub? If yes, create a repo at `github.com/RustWright/<PROJECT_NAME>` first (leave it empty — no README), then I'll add the remote and register it as a submodule."

**If yes:**
- Run: `git -C /home/me/productive_learning/projects/<PROJECT_NAME> remote add origin https://github.com/RustWright/<PROJECT_NAME>.git`
- Run: `git -C /home/me/productive_learning/projects/<PROJECT_NAME> push -u origin main`
- Register as submodule in the parent repo:
  ```bash
  # Add entry to /home/me/productive_learning/.gitmodules
  # Then stage and commit from productive_learning/
  git -C /home/me/productive_learning add .gitmodules projects/<PROJECT_NAME>
  git -C /home/me/productive_learning commit -m "add <PROJECT_NAME> as submodule"
  ```

**If no:** Leave as local git repo. Remind user they can register it as a submodule later with `/new-project` or manually.

## Phase 4: Confirm

Report to the user:
1. Full file list created
2. Git init status (and push status if applicable)
3. **For full-process:** "Ready for Session 1 whenever you want to start — just open the project and I'll read `project.md`."
4. **For simple:** "Remember to fill in the `CLAUDE.md` with your run commands and any useful notes."
