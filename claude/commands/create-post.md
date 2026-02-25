# Create a new blog post draft for My Learn Base

The blog lives at `/home/me/productive_learning/projects/mylearnbase/`.

## Phase 1: Gather info (you do this in the main conversation)

**Topic/context from the user:** $ARGUMENTS

If arguments were provided, use them as the topic. Otherwise, ask the user:
1. What did you learn or work on?
2. What tags would be relevant?
3. Is this part of a series? If so, which one and what order number?

**Check for session logs (if the directory exists):**
1. Check if `/home/me/productive_learning/projects/mylearnbase/.log/` exists
2. If it does and contains files, tell the user what's available and ask which (if any) to use for context
3. If the user picks specific logs, read them now — you'll pass the key details to the subagent
4. If `.log/` doesn't exist or is empty, skip this step — no need to mention it to the user

**Check project state in the current working directory (optional — these may not exist):**
- If `project.md` exists in the current directory, read it for current project status
- If `tasks.md` exists in the current directory, read it for recent work
- If neither exists, that's fine — the post can be based purely on the user's topic and any logs

## Phase 2: Delegate to a subagent for clean-context writing

Once you have all the info, use the **Task tool** with `subagent_type: "general-purpose"` to create the post. Pass a detailed prompt that includes:

- The topic and any context gathered from the user
- Any relevant details extracted from session logs (summarize — don't dump raw logs)
- Current project state if found in project.md / tasks.md
- The full post format specification below
- Today's date for the filename and frontmatter

### Post format specification (include this in the subagent prompt)

**File location:** `/home/me/productive_learning/projects/mylearnbase/content/posts/YYYY-MM-DD-slug-here.md`

**Filename format:** `YYYY-MM-DD-slug-here.md` — date prefix, kebab-case slug.

**Frontmatter (TOML):**
```
+++
title = "Post Title Here"
slug = "post-slug-here"
date = YYYY-MM-DD
draft = true

[taxonomies]
tags = ["relevant", "tags"]
# series = ["Series Name"]       # Uncomment if part of a series

# [extra]
# series_order = N               # Uncomment if part of a series
+++
```

Frontmatter rules:
- `draft = true` always — the user sets false after review
- `date` has NO quotes (bare date literal)
- `slug` must match the filename slug
- Tags should be lowercase
- Only include `series` and `series_order` if the user specifies a series
- Existing series in the project: "Building My Learn Base"

**Body structure:**
```markdown
## Reflections

<!-- This section is written by the human author — replace this with your thoughts -->

---

## Tutorial: [Descriptive Title]

[Generated content here]
```

Tutorial content rules:
- Write detailed, reproducible technical steps
- Use clear headings (h3, h4) to organize subsections
- Include code blocks with language identifiers
- If context from logs or current work was provided, weave in relevant decisions, gotchas, or lessons
- Be thorough but concise — aim for a post someone could follow along with
- Do NOT use Zola shortcodes (the user can add them later)
- Do NOT include template syntax like `{{ }}` or `{% %}` in code blocks without proper Zola escaping (use `{{/*` `*/}}` and `{%/*` `*/%}` if absolutely necessary)
- **Cross-platform awareness:** Primary development is on Linux, but always include notes for macOS and Windows users where commands, paths, or tooling differ (e.g. package install commands, font paths, shell syntax). Add these as callout notes in an Assumptions section near the top of the tutorial, not inline throughout the steps.

**Tell the subagent to write the file using the Write tool and report back the file path, title, slug, and tags.**

## Phase 3: Summarize (back in the main conversation)

After the subagent completes, show the user:
1. Full path to the created file
2. Summary: title, slug, tags, series (if any)
3. Remind them to:
   - Write the Reflections section
   - Review and edit the tutorial content
   - Set `draft = false` when ready to publish
   - Commit and deploy
