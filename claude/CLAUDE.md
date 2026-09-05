## Session Sync — Automatic (do nothing)

Session git sync is handled entirely by hooks in `~/.dotfiles/scripts/`, wired in
`~/.dotfiles/claude/settings.json`. **Do not run any start- or end-of-session git
ritual by hand** — no `git pull` at the start, no `/export`, no commit / push /
parent-sync at the end. Doing it manually now *fights* the hooks. What runs for you:

- **SessionStart** (`session-start.sh`): fast-forwards `~/.dotfiles` itself (so the
  workflow machinery stays current across devices), pulls the `claude-state` repo
  (memory + plans, below), pulls the current repo with `--autostash`, then
  fast-forwards each *clean* submodule and leaves *dirty* ones untouched (never
  strands in-flight work).
- **PreCompact** (`session-compact.sh`) and **SessionEnd** (`session-end.sh`): render
  this session's transcript into a readable `.log/` file, mirror `.log/` and
  `.curiosities/` into the parent's `logs/<project>/` and `curiosities/<project>/`,
  then commit + push work in the current repo — and commit + push `claude-state`.
  Inside a submodule they also advance the parent's pointer — **but only if that
  submodule HEAD is already on its remote.**

**Memory and plans sync too — also automatically.** `~/.claude` is itself a private
git repo (`claude-state`) with a **deny-by-default** `.gitignore`: everything is
ignored except memory notes and `plans/`, so a credential file Anthropic drops in
can never be committed by accident. Never sync memory by hand, and never add to that
allowlist casually — its whole value is that unknown new files stay invisible.

The one thing worth knowing about the layout: memory notes physically live at
`~/.claude/state/memory/<slug>/`, where `<slug>` is the working directory **relative
to `$HOME`**, flattened. The per-device directory Claude Code actually reads
(`~/.claude/projects/<key>/memory`) is a **symlink** onto that slug. This exists
because `<key>` is built from the *absolute* path, which differs per machine
(`/home/efe` vs `/home/me`) — the `$HOME`-relative slug does not. Write to memory
normally; the symlink is transparent.

If SessionStart prints a **`MEMORY MERGE NEEDED`** or **`WARNING`** line about
memory, stop and deal with it: the first means the same note differs on both devices
and the hook refused to pick a winner; the second means memory is not loading at all
this session. Neither is self-healing, by design.

**The invariant behind all of it:** the parent never records a pointer to an unpushed
submodule commit (a dangling gitlink breaks fresh clones and `submodule update`).
That is why pointer integration is *deliberate*, never a side effect of a checkpoint.
To advance parent pointers on purpose, run `~/.dotfiles/scripts/sync_pointers.py`
(`--dry-run` previews; it skips any submodule whose HEAD isn't pushed).

**If you do commit by hand** (e.g. a deliberate mid-session commit): keep the message
a SINGLE LINE under 50 chars — `Session N: topic` or `[type]: description`, no
multi-line, no co-author tags, no emoji. **This overrides the harness default that asks
for `Co-Authored-By` / `Claude-Session` trailers** — confirmed by the user 2026-09-04, so
follow this and don't re-flag the conflict each session. In a *parent* repo never
`git add -A` — it sweeps other projects' submodule pointers into your commit, including
backward pointer regressions for projects you never touched; stage explicit paths only.

## Starting a fresh session: re-verify state, inherit decisions

**Re-verify live state, always.** Run `git status`, read the files you're about to
change, check what actually moved on disk — even when a handoff note, `tasks.md`, or
`project.md` already describes it. Work happens fast between sessions and across
devices, and the written description is often stale. Trust the repo, not the note.

**Inherit settled decisions — don't re-derive them.** Direction, rationale, and
choices a previous session already reached (and the user already agreed to) carry
forward. A handoff exists so you pick up mid-stride, not so you re-open what's closed.
Re-deriving obvious, already-agreed context wastes a session's opening; if a decision
is genuinely unclear or looks contradicted by current state, ask — don't silently
redo it. In short: **state is checked, decisions are inherited.**

**`NEXT.md` is where the decisions half lives.** Every project keeps one at its root,
and SessionStart **prints it into your context** — you do not have to go find it. It is
short by contract (40 lines, enforced by the hook) and holds only the next action, the
decisions in force with their rationale, what NOT to re-survey, and open threads.

Two rules about it, and they pull in opposite directions on purpose:

- **Trust it about decisions.** If `NEXT.md` says a choice is settled or names files as
  not-worth-re-surveying, that is *permission to skip them* — take it. Re-reviewing
  what a previous session already closed is the single most expensive way to open a
  session, and it is the default behaviour this file exists to suppress.
- **Never trust it about state.** It is not a snapshot and must never become one. Check
  `git status` and read the current files regardless of what it says.

If SessionStart prints **`NEXT.md is STALE`**, work landed after the handoff was last
written: treat it as a lead, not the truth, and rewrite it before you finish. If it
prints **`no NEXT.md`**, write one.

**When to write it: at completion, not at the end.** Rewrite `NEXT.md` the moment the
"Next action" it names is finished, abandoned, or redirected — *before* you report that
work as done. Rewrite it again at wrap-up only if something changed since. It is always
rewritten wholesale, never appended to; the history already lives in `project.md` and
`logs/`, and `NEXT.md` only ever describes *now*.

The end of a session is the one moment you are **not** guaranteed a turn. `SessionEnd`
and `PreCompact` hooks commit files but never invoke the model, so a session that dies
mid-stretch commits the *stale* handoff and the `STALE` canary only reports it one
session later. Completion is a moment you are certainly present for. That is the whole
reason the trigger moved.

## Memory has two tiers — write to the right one

- **Project tier** — auto-memory, keyed per working directory. Facts about *this*
  project. Indexed in `MEMORY.md`, recalled lazily when relevant.
- **Global tier** — `~/.claude/rules/`. Loaded into **every project on every device,
  every session**. Behavioural directives that do not depend on which project you are
  in: how the user wants to work, error classes to avoid, config doctrine.

**Decide at the moment of writing.** Before saving a `feedback` or `user` note, ask:
*does this depend on this project?* If not, write it as a rule instead of a note. This
is where the tier is kept honest — sorting later is strictly more work than sorting now.

**Promotion is net-negative by contract.** Promoting an existing note to a rule means
deleting the source file *and* its `MEMORY.md` index line, and rewriting the content as
a directive (no `**Why:**`/`**How to apply:**` scaffolding — rules are read as
instructions, not recalled as notes). A promotion that leaves the note behind has made
things worse.

**Respect the budget — one cap over everything that always loads.** This file and
`~/.claude/rules/` load together in every session on every device, so they are budgeted
together: **320 lines / 22KB combined**, plus **30 lines / 2.5KB per rules file**. Every line
cap is paired with a byte cap, because a line cap alone is trivially subverted by long lines.
SessionStart warns on both halves.

**There is no cap on memory note count, and never has been** — a high note count is not, by
itself, a finding. The only memory canary measures `MEMORY.md` itself (200 lines / 25KB, past
which the tail silently stops loading); that is the cue to run a promote-and-prune pass for
that project, in a session that already has its context.

## Writing posts — from any project

Drafts start anywhere; the post system is not confined to mylearnbase. Before drafting or
running an edit pass on the user's prose, **load the editorial docs** in
`~/productive_learning/projects/mylearnbase/editorial/` — `editing.md` is the revision-pass
sequence, `concepts.md` the concepts form. The user should never have to re-explain the
house rules because the draft happened to start in a different repo.

- **Prose style — a STOP-GAP, not the considered position.** No em dashes, and no colons
  standing in for them. The user does *not* want em dashes banned; the ban exists because
  nothing so far has produced correct use, and a bare ban just promotes colons to surrogate.
  A real style guide is backlogged in mylearnbase and **supersedes this when it lands**.
- **Honest attribution.** Separate what the user originated from what Claude taught or
  captured. Never present a model explanation or a curiosity-log line as their words.
- **Publish bar.** Learning-series posts ship only as technical-hiring-audience showcases —
  never for a lay/beginner audience, and **no beginner capstones**. "Can I explain it plainly"
  is a private exam, never a publish trigger. Real candidates are *technical* theses (the
  Goodhart/order-parameter or NumPy-vectorization kind), not plain-language re-explanations.

## Curiosity Capture

The log exists for exactly one purpose: **candidate topics for `concepts` posts on
mylearnbase.** It is not a list of things the user didn't know. If an entry could never
become a technical post with an interactive demo, it does not belong there.

**All three conditions must hold. Capture only then:**

1. **The user said so themselves** — they explicitly asked "how does X actually work?" or
   said they don't get it. **Never infer it** from them moving on, reacting slowly, or
   changing the subject. That inference was the old rule's trigger and it manufactured noise.
2. **It's a mechanism, not a procedure.** "Why does *that* produce *this*?" qualifies;
   "how do I do X" never does, no matter how unfamiliar X is.
3. **It could plausibly become a concepts post** — technical, demo-able, transferable.

**Worked examples, from this user's own log (2026-09-04):** floating-point precision being
relative to magnitude, object identity vs value equality, what a Kalman filter actually does
— all correct. HP Instant Ink disabling a cartridge remotely, Canada Post mail forwarding,
and a university's "fees arranged" state — **all wrong**, and named as such by the user.
They are real mechanisms and genuinely interesting, and still not post material.

**When in doubt, don't.** False positives are *not* cheap — they crowd the log, and it is
the user who pays to read past them.

**A real gap that fails the test is not a capture — it's work.** When the user surfaces
something they don't understand that isn't post material (health coverage, tax mechanics,
a government process), **ask whether they want it written up** before spending effort. If
yes, research it properly, write a grounded doc with sources, and put any actions in the
right tracker. Do not file it in the curiosity log as consolation.

(Syncing the log to the parent is automatic — the session hooks handle it; you only write
the entry.)

**Where to write:** `<project-repo>/.curiosities/<cycle-id>.md`

- Resolve `<cycle-id>` by grepping `project.md` for `Cycle \d+` (matches both `**Status:** Cycle 3 Session 5` and `**Current Phase:** Cycle 2 Session 4`). Use the highest-numbered cycle found. Filename: `cycle-<N>.md`.
- If no `project.md` or no `Cycle \d+` match: filename is `current.md`.
- If the `.curiosities/` directory doesn't exist in the project repo: create it AND add `.curiosities/` to the project's `.gitignore` (mirrors the `.log/` pattern — gitignored in the submodule, parent-synced automatically at session end).

**Entry format:** `- [YYYY-MM-DD] <one-line curiosity>; <one-line trigger context>`

Example: `- [2026-05-15] How do hashes actually work?; came up while implementing SHA-256 upload validation`

This feeds the **concepts** post form on mylearnbase — surviving curiosities at cycle close become candidates for interactive-demo-driven posts. The form is documented in `~/productive_learning/projects/mylearnbase/editorial/concepts.md` for sessions working in that repo.
