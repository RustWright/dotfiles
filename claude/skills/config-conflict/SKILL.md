---
name: config-conflict
description: Check whether a user instruction contradicts CLAUDE.md, a skill definition, a project process doc, or a prior recorded decision - and surface the conflict before acting on it. Use when an instruction seems to cut against established rules, and always before writing a deviation to memory or into an approved plan.
allowed-tools: Read, Grep, Glob
---

# Configuration Conflict Check

## Why this exists

Across 270 mined sessions spanning eight months, the user's instructions
contradicted their own written configuration repeatedly - and the conflict was
surfaced **zero times**. Documented instances:

- Global `CLAUDE.md` mandates commit **and push** every session. An in-session
  "commit but don't push" instruction was complied with, **written to memory**,
  and two weeks later appeared in an approved plan as standing policy. 28 commits
  of a personal-data app sat on one machine for days.
- `CLAUDE.md`'s session-end protocol mandated `git add -A`. Both parties treated
  it as dangerous every session for **nine days** while the doc stayed wrong.
- The Learning output style is configured globally and waived in most production
  sessions - for **five months** - with 10-12 minutes of teaching scaffold built
  before each waiver, and no proposal to change the setting.
- Documented verification gates (visual walkthrough, Learn-by-Doing) were skipped
  on "full speed" instructions. The skipped check had a 2-of-2 bug-find rate.

The pattern is not that rules get broken. It is that **deviations get silently
promoted to canon**: complied with, recorded to memory, then copied into plans,
until the written config and actual practice have quietly forked.

## The rule

Before acting on an instruction that cuts against written config - and
**always** before recording such a deviation to memory or into a plan - stop and
surface it in this shape:

> You're asking for **Z**. **Y** says **X**.
> Is this a deliberate change we should update Y for, or a one-off for this case?

Then wait. Do not pre-resolve it, and do not proceed on the assumption that the
most recent instruction wins.

## What to check against

- global `~/.claude/CLAUDE.md`
- workspace and project `CLAUDE.md` files
- `PROJECT_PROCESS.md` (canonical copy in `setup_files/`)
- skill definitions in `.claude/skills/`
- recorded memories, especially `feedback_*` entries
- decisions approved earlier in this same session

## Triggering threshold

Surface a conflict when **any** of these hold. Otherwise stay quiet - a check
that fires on every trivial deviation gets tuned out, which is precisely how the
five-month waiver survived.

- **The rule is marked non-negotiable** ("must", "always", "non-negotiable" -
  "one question at a time" is one of these). Any deviation trips the check.
- **It's a repeat.** The same deviation has surfaced before, this session or in
  memory/logs. A one-off is a one-off; the second time, the doc is probably
  wrong and should be fixed rather than re-worked-around. *(The `git add -A`
  waiver ran 9 days; the Learning-style waiver ran 5 months. Both should have
  tripped on repeat #2.)*
- **It's about to be persisted.** You are one step from writing the deviation to
  memory or into a plan document. This is the moment it becomes canon - always
  check here, however minor it seems.
- **It reverses a same-session decision.** The instruction contradicts something
  the user approved earlier in this same session.

Do **not** trip on a first-time deviation from an advisory (non-"must") rule
that is not being persisted and does not reverse a prior decision. Just proceed.

## Recording the outcome

- **Deliberate change** - update the source document *now*, in the same session.
  A rule that keeps getting waived is a rule that is wrong; fix it rather than
  re-negotiating it every session.
- **One-off** - proceed, and do **not** write it to memory as a general
  preference. Note it as a scoped exception if it needs recording at all.

Never let a deviation reach memory or a plan document without one of these two
outcomes having been chosen explicitly.
