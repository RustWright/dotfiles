---
name: session-audit
description: Audit a session for overlooked, silently-dropped, or partially-completed work before closing out. Use when the user says "wrap up", "end session", "anything overlooked", "did you miss anything", or before any end-of-session sync.
allowed-tools: Read, Grep, Glob, Bash(git status:*), Bash(git diff:*), Bash(git log:*)
---

# Session Close-Out Audit

Run this **before** the end-of-session sync, not after. Its purpose is to catch
work that was claimed complete but isn't, before it gets committed and forgotten.

## Why this exists

Asking "did you overlook anything?" at session close has a documented **100% hit
rate** across this workspace - four probes, four instances of real missed work.
It surfaced: attachment bytes silently dropped so an original receipt was lost;
an LLM call wired client-side in violation of a recorded architecture principle;
Wise `fxRate` and `totalFees` fields discarded without comment; a journal
projection handling 3 of 16 event types; and a spec'd nightly scan that was never
wired up.

The failure mode is consistent: **completion is declared before integration and
operational angles are checked.** Every "100% complete" claim in that corpus got
revised within one or two follow-up prompts.

This skill exists so that safety net does not depend on the user remembering to
pull it.

## Protocol

1. Re-read the session's stated goals - the plan, `tasks.md`, or the opening prompt.
2. Work the checklist below. For each item, either cite concrete evidence it
   holds, or report it as a gap. **"Probably fine" is a gap.**
3. Report findings grouped by severity (see Output). Do not fix anything yet -
   surface first, then let the user choose what to address now versus defer.

## Checklist

Organized by **failure mode**, not by artifact - the work that gets missed is
exactly where you didn't think to look, so a by-artifact list ("check the code,
check the docs") misses the same things the session did.

1. **Dropped at a boundary.** Did data enter a function/parser/importer and not
   come out? Fields silently discarded, attachment bytes not persisted, values
   defaulted instead of carried. *(Real misses: attachment bytes lost so a
   receipt was gone; Wise `fxRate`/`totalFees` dropped without comment.)*

2. **Partial / one-of-N.** Did a fix land on every call-site, or only the one in
   front of you? Sibling handlers, other enum variants, the second of two
   near-identical functions. *(Real misses: a fix on `on_group_modified` but not
   the item handler; a projection handling 3 of 16 event types.)*

3. **Declared but unwired.** Was anything marked done that isn't actually
   connected - a feature built but never called, a trigger that only fires
   manually, a config flag never read? *(Real miss: a nightly scan with only a
   manual trigger.)*

4. **Rule violated without flagging.** Did a change cut against a recorded
   principle, a `CLAUDE.md` rule, or a `feedback_*` memory without that being
   surfaced? *(Real miss: an LLM call wired client-side against a recorded
   architecture rule.)*

5. **Claim vs. reality.** Re-check every "done / fixed / verified" claim from
   this session against the actual artifact. Was a fix tested under the
   conditions that reproduce the bug (fresh install, empty DB) or under warm
   state that hides it?

6. **Not persisted.** Do any decisions made this session live only in this
   conversation? Anything that must survive compaction or a device handoff
   belongs in `tasks.md`, `project.md`, or memory - not just here.

## Output

Report as:

- **Blocking** - would ship broken or lose data. Address before close-out.
- **Should fix** - real gap, safe to defer with an explicit note in `tasks.md`.
- **Noted** - minor or cosmetic; record and move on.

If a claim from earlier in the session turns out to be wrong, say so plainly and
name the claim. An audit that reports "nothing found" on a session with
substantive work should be treated as suspicious - re-check the integration
boundaries before accepting it.
