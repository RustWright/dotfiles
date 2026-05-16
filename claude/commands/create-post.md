# Create a new blog post for My Learn Base

The blog (mylearnbase) lives at `/home/me/productive_learning/projects/mylearnbase/`.

The blog has **five post forms**. Each has its own tools, section structure, and authoring rhythm — fully documented in `mylearnbase/editorial/<form>.md`. **Read the editorial doc for the chosen form before doing anything else.** The slash command is a router; the editorial docs are the source of truth.

The five forms:

| Form | Decision rule | Typical trigger |
|---|---|---|
| **logbook** | About a feature you built; evidence-of-shipping | A feature just landed in a project repo |
| **concepts** | A concept you came to understand via an interactive demo | Survived a cycle-close review of `.curiosities/<cycle-id>.md` |
| **workflows** | A process/workflow doc to reference or share | A source doc in a project repo is ready to publish/republish |
| **opinions** | A take, and the take is the point | You have something to say |
| **resources** | Curated external references | A project ended where resources earned their keep; or a theme collection feels ready |

## Phase 1: Determine the form

**Topic/context from user:** $ARGUMENTS

If the form is clear from arguments, proceed. Otherwise ask the user once which form fits, using the table above. If the user is ambiguous between two forms, pick the one with the lower default cadence — opinions over logbook, concepts over opinions — since the higher-bar form will surface friction earlier if it's wrong.

## Phase 2: Read the form's editorial doc

**Source of truth:** `/home/me/productive_learning/projects/mylearnbase/editorial/<form>.md`

The editorial doc covers: when to use, tools, section structure with LLM-vs-author ownership, anti-patterns, authoring rhythm. **Read it before executing any per-form workflow** — re-encoding section rules here would create drift.

## Phase 3: Execute the form's workflow

Each form has a different shape. The below is the quick-reference anchor for routing; the editorial doc is authoritative on details.

### logbook

- **Tools (installed via `uv tool install`):** `logbook init` / `what` / `why` / `scope` / `note` / `exec` / `screenshot` / `cite` / `tags` / `publish`. Cross-project — run from the project repo where the work is happening, NOT from mylearnbase.
- **Scaffold:** `logbook init <project> <feature_name> --title "..."`. Mandatory `--title` (no auto-derivation).
- **Capture during the work**, not after. Section ownership per `editorial/logbook.md` §3 — LLM drafts descriptive prose first (§1-4); user owns voice-bearing sections (especially §7 Notes / look-back). **The LLM does not draft §7 in the user's voice without explicit user input.**
- **Publish when feature lands:** `logbook publish <slug>` — runs `showboat verify` + `zola check` automatically; output at `mylearnbase/content/posts/logbook/<project>/<slug>.md`.

### concepts

- **No init tool.** Draft directly at `mylearnbase/content/posts/concepts/<slug>.md`.
- **Demo assets** in `mylearnbase/static/demos/<slug>/`, embedded via `{{ demo() }}` shortcode (project-level template).
- **Origin:** the post should trace back to an entry in `<project-repo>/.curiosities/<cycle-id>.md` that survived cycle-close review. Pull that entry's text + trigger context when drafting §2 (curiosity moment).
- **The intellectual work is the demo design** — choosing what interaction surfaces the concept's hard part. The LLM writes the code; the author decides what makes the concept teach. This is non-negotiable per `editorial/concepts.md`.
- **No demo, no post.** If the concept doesn't yield to interactivity, it's an opinions post or notes worth keeping unpublished.

### workflows

- **Tool:** `workflows publish <source-doc-path>`. The source doc lives in the project repo (e.g., `PROJECT_PROCESS.md`); the published post is a synced view.
- **Edit the source doc, then republish. Never edit the post directly** — the next republish overwrites it.
- **Always preview with `--dry-run`** before republish; review the unified diff before committing.
- **Supersession:** `workflows publish <new-source> --supersede-from <old-slug>` writes the new post and adds a banner to the old one.
- **Two categories** (`editorial/workflows.md` Topic 1): Cat 1 = LLM-referenced (dual-reader pressure: LLM at session start + human on the website); Cat 2 = personal-reference (future-self only). The editorial doc walks the discipline for each.

### opinions

- **No init tool, no publish tool.** Draft directly at `mylearnbase/content/posts/opinions/<slug>.md`.
- **Seven-phase workflow with entry-point spectrum** (`editorial/opinions.md` Topic 2) — the user enters at any phase and walks forward. Detect entry point by user declaration, by one clarifying question if ambiguous, or by artifact inference.
- **Phase 1 prompting modes:** *provocation* (extreme-same-direction, **NOT** opposing — push the user's own argument to absurdity along its existing dimension), *mirror-and-probe*, *multiple framings*. Default chain: provocation opens → mirror-and-probe consolidates → pause-and-ask between cycles → summary on user request closes Phase 1.
- **The LLM never drafts the take itself.** Opinions are user-voiced. The user's voice is non-negotiable.
- **Phase 6 (mechanical pass)** is the only phase where the LLM modifies the post — to implement approved fixes only (typo, capitalization, link sync, structural mechanics). Substantive changes require user voice.
- **Tier 1 substantive feedback** is suggest-then-decide: LLM offers, user accepts or declines per-post. Tiers 2/3/4 are request-only.

### resources

- **No init tool, no publish tool.** Draft directly at `mylearnbase/content/posts/resources/<slug>.md`.
- **Two sub-types** (`editorial/resources.md` Topic 1): *project-derived* (links back to logbook entries the resources informed) and *collection-driven* (curated theme without project anchor).
- **Author contribution is curation-by-act** — the user has done the lived using/bookmarking; the LLM handles surface gathering, organizing, formatting. Don't generate resource lists from web searches without lived backing.
- **Per-bullet structure is discretionary** — descriptive line (LLM-first) + optional context line. If there's nothing important to say about a link, the link alone is fine.
- **Section 5 cross-references to logbook entries** are a soft convention for project-derived, not a publish-time gate.

## Phase 4: Tag awareness

**Source of truth:** `mylearnbase/editorial/tagging.md`. **Read it first** — it covers style conventions, decision rules, anti-patterns, and the principle that tag ambiguity gets resolved in conversation (not via a canonical aliases catalog).

Then before introducing a new tag, run grep against the current inventory:

```bash
grep -rh '^tags = ' /home/me/productive_learning/projects/mylearnbase/content/posts/ | \
  tr ',' '\n' | tr -d '[]"' | sort -u | head -40
```

If two plausible near-synonyms surface (e.g., `ui` vs `ui-development`), **surface the choice to the user** — don't pick silently. The decision is made at post-creation time based on which framing the current post genuinely fits.

## Phase 5: Verification + summary

After the workflow lands a file:

- For tool-backed forms (`logbook`, `workflows`): the publish tool runs `zola check --skip-external-links` automatically. Confirm zero orphans.
- For draft-direct forms (`concepts`, `opinions`, `resources`): run `cd /home/me/productive_learning/projects/mylearnbase && zola check --skip-external-links` after `draft = false`.
- All forms: confirm `zola build` reports `0 orphan`.

Then report to the user:

1. Form chosen.
2. File path created or modified (and source doc path for workflows).
3. Tags applied.
4. Next steps specific to the form:
   - `logbook`: capture more sections or publish.
   - `concepts`: build/iterate on demo, draft prose around it.
   - `workflows`: edit source doc, then `workflows publish --dry-run` before publishing.
   - `opinions`: walk the Phase 1-7 chain at the user's entry point.
   - `resources`: gather more entries, refine annotations.
5. Reminder on `draft` default for the chosen form:
   - `logbook` defaults to `draft = true` (user reviews, flips to false).
   - `workflows` defaults to `draft = false` (the source doc was already considered ready).
   - `concepts` / `opinions` / `resources`: author sets explicitly when drafting.
