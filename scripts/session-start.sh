#!/bin/bash
# SessionStart hook: bring this device current WITHOUT disturbing in-flight work.
#
# Replaces the manual "at session start run git pull --rebase + submodule update"
# instruction. Deliberately gentle, because the workflow assumes dirty/unpushed
# submodules are normal (you move between devices mid-task):
#   - ~/.dotfiles is fast-forwarded first, so the workflow machinery itself stays
#     current across devices (changes apply next session — a hook can't reload the
#     script it's already running)
#   - the current repo is pulled with --autostash (your dirty work is preserved)
#   - each submodule is fast-forwarded ONLY if clean; dirty ones are left ALONE
#     (never force-checked-out to the recorded pointer, which would strand work)
# Everything is non-fatal: a failure here must never block starting a session.
#
# The whole body runs inside main(), invoked at the very end. That matters: the
# dotfiles pull below can overwrite THIS script on disk mid-run, and a bash script
# read line-by-line would then execute garbage from the new file at the old byte
# offset. Parsing the entire function before executing it makes the on-disk swap
# harmless — bash runs from memory, not from the changed file.

main() {
  # Keep the workflow machinery itself current. ff-only never clobbers local
  # dotfiles edits; if the tree is dirty in a conflicting way it simply declines.
  DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  git -C "$DOTFILES" pull --ff-only 2>/dev/null || echo "session-start: WARNING — ~/.dotfiles pull failed; workflow machinery may be stale on this device."

  # ── cross-device memory + plans (the claude-state repo) ─────────────────────
  # Deliberately ABOVE the is-this-a-git-repo guard below: memory belongs to the
  # session, not to the work repo, so it must sync even when Claude is launched
  # somewhere that isn't a checkout.
  STATE="$HOME/.claude"
  if [ -d "$STATE/.git" ]; then
    if ! git -C "$STATE" pull --rebase --autostash 2>/dev/null; then
      # A conflicted rebase would otherwise leave the repo mid-operation, silently.
      # Aborting restores the pre-pull state: local commits intact, nothing lost.
      git -C "$STATE" rebase --abort 2>/dev/null || true
      echo "session-start: WARNING — claude-state pull failed (likely a local commit conflicting with the remote). Rolled back. Memory may be STALE this session. Fix: git -C $STATE pull --rebase"
    fi

    # Memory lives under a slug keyed on the path RELATIVE TO $HOME, because the
    # absolute path differs per device (/home/efe vs /home/me) while ~/... does
    # not. The per-device directory Claude Code actually reads is a symlink onto
    # that slug, so one tracked copy serves every machine.
    #
    # Take the device-local key from transcript_path (.../projects/<KEY>/x.jsonl)
    # rather than re-deriving it: it comes from Claude Code itself, so the link
    # cannot end up pointing at a directory nothing reads. $PWD is the fallback.
    HOOK_JSON="$(timeout 2 cat 2>/dev/null || true)"
    KEY="$(printf '%s' "$HOOK_JSON" | python3 -c "import json,sys,os; print(os.path.basename(os.path.dirname(json.load(sys.stdin).get('transcript_path',''))))" 2>/dev/null || true)"
    KEY_TRUSTED=1
    [ -z "$KEY" ] && { KEY="$(printf '%s' "$PWD" | sed 's|[/_]|-|g')"; KEY_TRUSTED=0; }
    SLUG="$(printf '%s' "$PWD" | sed "s|^$HOME/||" | sed 's|[/_]|-|g')"

    LINK="$STATE/projects/$KEY/memory"
    TARGET="$STATE/state/memory/$SLUG"

    # Order matters: the two alarm conditions are tested BEFORE any branch that
    # could repair them. `mkdir -p "$TARGET"` in the create-link branch below
    # would otherwise resurrect a deleted directory and mask the very thing the
    # canary exists to report — leaving the session running on empty memory.
    if [ ! -d "$STATE/state/memory" ]; then
      # The allowlist in .gitignore names exact paths, so if Anthropic relocates
      # this layout the sync stops silently. Shouting is the whole mitigation.
      echo "session-start: WARNING — $STATE/state/memory is missing. Cross-device memory sync is NOT running."
    elif [ -L "$LINK" ] && [ ! -e "$LINK" ]; then
      echo "session-start: WARNING — $LINK points at a missing $TARGET. Memory will not load this session; not recreating it silently."
    elif [ -d "$LINK" ] && [ ! -L "$LINK" ]; then
      # A real directory is sitting where the link belongs — this is the other
      # device's own accumulated notes on first sync. Adopt ONLY what is
      # unambiguous: files absent from the tracked copy, or byte-identical to it.
      # A file that exists on both sides with different content is a genuine
      # content merge, which a hook must never decide; refuse and say so.
      CONFLICT=""
      for f in "$LINK"/*; do
        [ -f "$f" ] || continue
        t="$TARGET/$(basename "$f")"
        [ -f "$t" ] && ! cmp -s "$f" "$t" && CONFLICT="$CONFLICT $(basename "$f")"
      done
      if [ -n "$CONFLICT" ]; then
        echo "session-start: MEMORY MERGE NEEDED for $SLUG — differing on both sides:$CONFLICT"
        echo "session-start: left untouched at $LINK; reconcile by hand, nothing was overwritten."
      else
        mkdir -p "$TARGET"
        cp -an "$LINK"/. "$TARGET"/ 2>/dev/null || true
        rm -rf "$LINK" && ln -s "../../state/memory/$SLUG" "$LINK"
      fi
    elif [ ! -e "$LINK" ] && [ ! -L "$LINK" ] && { [ -d "$STATE/projects/$KEY" ] || [ "$KEY_TRUSTED" = 1 ]; }; then
      # On the FIRST session from a new cwd, projects/$KEY does not exist yet — Claude
      # Code creates it moments after this hook runs. Testing the directory alone
      # therefore matched no branch at all and the session ran on EMPTY memory, silently,
      # because the canaries above only cover a missing store or a dangling link. A
      # transcript-derived KEY comes from Claude Code itself, so it is authoritative and
      # the directory can be created here; a $PWD-derived guess still gets refused.
      mkdir -p "$TARGET" "$STATE/projects/$KEY"
      ln -s "../../state/memory/$SLUG" "$LINK"
    fi

    # ── pressure canary: MEMORY.md against the real load limits ────────────────
    # Claude Code loads only the first 200 lines / 25KB of MEMORY.md. Past that the
    # tail is silently dropped — the index still LOOKS complete, so nothing reports
    # it. (omni-me sat at 29.7KB before this canary existed.) This is the trigger
    # for a promote-to-rules pass: it fires in a session that already has that
    # project's context, instead of demanding one 159-note audit somewhere.
    IDX="$TARGET/MEMORY.md"
    if [ -f "$IDX" ]; then
      IL="$(grep -c '' "$IDX" 2>/dev/null || echo 0)"
      IB="$(wc -c < "$IDX" 2>/dev/null || echo 0)"
      if [ "${IL:-0}" -gt 200 ] || [ "${IB:-0}" -gt 25600 ]; then
        echo "session-start: WARNING — MEMORY.md for $SLUG is $IL lines / $IB bytes, PAST the 200-line / 25KB load cap. The tail is NOT loading this session. Promote general notes to ~/.claude/rules/ and prune the rest."
      elif [ "${IL:-0}" -gt 160 ] || [ "${IB:-0}" -gt 20480 ]; then
        echo "session-start: NOTE — MEMORY.md for $SLUG is $IL lines / $IB bytes, nearing the 200-line / 25KB load cap. Promote or prune before it starts dropping entries."
      fi
    fi

    # ── budget canary: the global rules tier ───────────────────────────────────
    # Deliberately tighter than the memory cap, because the failure is worse. An
    # oversized MEMORY.md merely truncates — lazy waste. Rules load in EVERY
    # project on EVERY device, so an oversized tier is paid on every single
    # session forever. The cure must not become the disease.
    if [ -d "$STATE/rules" ]; then
      RC="$(find "$STATE/rules" -name '*.md' 2>/dev/null | wc -l)"
      RL="$(cat "$STATE"/rules/*.md 2>/dev/null | grep -c '' || echo 0)"
      if [ "${RC:-0}" -gt 10 ] || [ "${RL:-0}" -gt 120 ]; then
        echo "session-start: NOTE — global rules tier is $RC files / $RL lines (budget 12 / 150). Every line here costs context in every session; merge or demote before adding more."
      fi
    fi

    # ── canary: files the PUBLIC-REPO GATE held back, on ANY device ─────────────
    # public-gate.sh refuses to auto-publish new sensitive-looking files. That
    # protection creates a new hazard the user named directly: a false positive is
    # held back on device A, the user moves to device B, and B has no knowledge of
    # it — the work is stranded exactly like a submodule's tree in a parent session.
    #
    # So the record lives in claude-state, which is private and syncs on EVERY
    # session regardless of which repo Claude was launched in. This block sits above
    # the is-this-a-git-repo guard for the same reason the memory sync does: a file
    # held back in ~/life must still be reported from a productive_learning session.
    #
    # Manifests are keyed by device. This device re-validates and PRUNES its own
    # (resolved = now tracked, gitignored, or gone), so the warning disappears the
    # moment it is acted on. Other devices' entries are printed verbatim and never
    # touched — only the machine that holds the file can prove it is resolved.
    HB="$STATE/state/held-back"
    if [ -d "$HB" ]; then
      MINE="$HB/$(hostname).tsv"
      if [ -f "$MINE" ]; then
        KEPT="$(mktemp)"
        while IFS=$'\t' read -r d r rel why; do
          [ -n "$rel" ] || continue
          # Resolved if the repo is gone, the file is gone, or git now accounts for
          # it (tracked or ignored). Anything else is still genuinely stranded.
          [ -d "$r" ] || continue
          [ -e "$r/$rel" ] || continue
          git -C "$r" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && continue
          git -C "$r" check-ignore -q -- "$rel" 2>/dev/null && continue
          printf '%s\t%s\t%s\t%s\n' "$d" "$r" "$rel" "$why" >> "$KEPT"
        done < "$MINE"
        if [ -s "$KEPT" ]; then mv "$KEPT" "$MINE"; else rm -f "$KEPT" "$MINE"; fi
      fi
      for M in "$HB"/*.tsv; do
        [ -f "$M" ] || continue
        DEV="$(basename "$M" .tsv)"
        N="$(grep -c '' "$M" 2>/dev/null || echo 0)"
        [ "${N:-0}" -gt 0 ] || continue
        if [ "$DEV" = "$(hostname)" ]; then
          echo "session-start: WARNING — the public-repo gate is holding $N file(s) on THIS device ($DEV), uncommitted and unpushed:"
        else
          echo "session-start: WARNING — device '$DEV' is holding $N file(s) that are NOT on this machine and will not sync until resolved THERE:"
        fi
        while IFS=$'\t' read -r d r rel why; do
          [ -n "$rel" ] || continue
          echo "  $(basename "$r")/$rel  ($why, held $d)"
        done < <(head -10 "$M")
        [ "$N" -gt 10 ] && echo "  … and $((N - 10)) more"
        echo "session-start: if the gate was wrong, commit it deliberately on $DEV; otherwise gitignore it or move it out."
      done
    fi
  fi

  git rev-parse --git-dir &>/dev/null || return 0
  CWD="$(git rev-parse --show-toplevel)"

  # Pull the current repo; autostash keeps any uncommitted work out of the way.
  #
  # Under the SAME per-repo lock session-work.sh takes, and this is now REQUIRED. The
  # SessionEnd body runs DETACHED, so the previous session's staging and commit can still
  # be in flight when this one starts — on 2026-09-03 a new session started in omni-me
  # SEVEN SECONDS after the previous SessionEnd fired. `pull --rebase --autostash` takes
  # .git/index.lock; unserialised, the two abort each other and one loses its work.
  # Bounded wait, and we proceed anyway: a stuck holder must not block the session.
  {
    flock -w 60 9 || echo "session-start: NOTE — waited on a previous session's commit in $CWD and gave up; if the pull below misbehaves, that is why."
    if ! git -C "$CWD" pull --rebase --autostash 2>/dev/null; then
      git -C "$CWD" rebase --abort 2>/dev/null || true
      echo "session-start: WARNING — pull failed in $CWD (likely an unpushed local commit conflicting with the remote). Rolled back to a clean state; you are working from STALE code. Fix by hand: git -C $CWD pull --rebase"
    fi
  } 9>"/tmp/claude-session-work.$(printf '%s' "$CWD" | md5sum | cut -c1-16).lock"

  # ── canary: commits that never reached the remote ───────────────────────────
  # Nothing used to report this, and the pull above actively MASKS it: with nothing
  # to fetch it prints "Current branch main is up to date." while the branch is
  # ahead. That is precisely how a week of dropped SessionEnd pushes went unnoticed
  # (2026-09-03: ~/life ahead 1, productive_learning ahead 1 from a session two
  # hours earlier). session-push.sh now retries an ahead branch on its own, so
  # anything still reported here has failed at least twice — worth a human look.
  #
  # Deliberately VISIBILITY, NOT AUTOMATION, matching the doctrine in session-end.sh:
  # auto-pushing at session start is still an open user decision (see NEXT.md).
  for R in "$CWD" "$STATE"; do
    [ -n "$R" ] && [ -d "$R/.git" ] || continue
    A="$(git -C "$R" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "${A:-0}" -gt 0 ] || continue
    echo "session-start: WARNING — $R has $A commit(s) NOT on the remote. They will not reach your other device. Check /tmp/claude-session-end-debug.log for the failure, then: git -C $R pull --rebase && git -C $R push"
  done

  # ── canary: untracked files about to be PUBLISHED to a public repo ──────────
  # SessionEnd does `git add -A` in $CWD and commits everything, and since dotfiles
  # af69170 the push that follows actually lands (it used to die in the claude-state
  # push often enough to act as an accidental safety net). So an untracked file in a
  # public repo gets published automatically, and a push to a public remote cannot be
  # taken back.
  #
  # Scoped tight ON PURPOSE, three ways: only $CWD (a parent session never commits a
  # submodule's tree — rule 1), only UNTRACKED files (modified tracked files are
  # normal in-flight work here), and only PUBLIC repos. A warning that fires every
  # session is one you stop reading within a week — the same reason the NEXT.md STALE
  # canary excludes `auto:` commits.
  #
  # Visibility, NOT automation (user's decision, 2026-09-03): this reports so the
  # human can gitignore / commit deliberately / move the file out. It never alters
  # what any hook commits or pushes.
  # The lookup runs UNCONDITIONALLY; only the warning is conditional. It is cached per
  # remote URL for 7 days, so this costs one `gh` call per repo per week — and paying it
  # HERE is what keeps the SessionEnd gate off the network.
  #
  # It used to sit behind the untracked-files guard below, and that is exactly how
  # 2026-09-03 was lost: omni-me had never been looked up, so public-gate.sh made the
  # first call itself — a cold, blocking `gh api` wedged between the staging and the
  # commit, mid-shutdown, with a ~1s budget. The hook died there and the session's whole
  # day of work sat staged and uncommitted. Warm the cache when there is time to spare.
  #
  # Unknown visibility stays SILENT — a repo with no GitHub remote, or a device with no
  # `gh` auth, must not warn on every session. The lookup lives in repo-visibility.sh,
  # shared with the gate, so the two can never disagree about what "public" means.
  VIS="$("$DOTFILES/scripts/repo-visibility.sh" "$CWD")"

  UNTRACKED="$(git -C "$CWD" ls-files --others --exclude-standard 2>/dev/null)"
  if [ -n "$UNTRACKED" ] && [ "$VIS" = "public" ]; then
    UN="$(printf '%s\n' "$UNTRACKED" | grep -c '')"
    echo "session-start: WARNING — $(basename "$CWD") is a PUBLIC repo and has $UN untracked file(s) that SessionEnd will commit and PUSH:"
    printf '%s\n' "$UNTRACKED" | head -10 | sed 's|^|  |'
    [ "$UN" -gt 10 ] && echo "  … and $((UN - 10)) more"
    echo "session-start: gitignore them, commit them deliberately, or move them out before this session ends."
  fi

  # Gently advance submodules: fetch + ff the clean ones, skip dirty ones.
  #
  # The skip list doubles as the stranded-work canary. session-work.sh prints the same
  # thing at SessionEnd, but that is a moment nobody is reading — and since the body was
  # detached, it goes to the debug log only. THIS is the copy that gets read, and it
  # arrives at the one time it can still be acted on: the start of the next session.
  SUBOUT="$(git -C "$CWD" submodule --quiet foreach '
    if [ -z "$(git status --porcelain)" ]; then
      git fetch --quiet 2>/dev/null || true
      git merge --ff-only "@{u}" 2>/dev/null || true
    else
      echo "session-start: skipping dirty submodule $sm_path (work in flight)"
    fi
  ' 2>/dev/null || true)"
  if [ -n "$SUBOUT" ]; then
    printf '%s\n' "$SUBOUT"
    echo "session-start: a parent session NEVER commits a submodule's tree, so that work will not reach your other device. Commit from inside the submodule, or run the session there."
  fi

  # ── instant-resume handoff: NEXT.md ─────────────────────────────────────────
  # PRINTED, not merely pointed at. SessionStart stdout is injected into the
  # session's context, so this makes the handoff the first thing read rather than
  # something the model must know to go looking for. A pointer alone was already
  # tried and failed: a session opened at a repo root, asked "what's next", and
  # went digging through logs/ — while the correct answer sat in a file that
  # nothing surfaced. Discoverability, not mere presence, is the requirement.
  #
  # Printed LAST on purpose: closest to the model's reading position.
  #
  # NEXT.md carries DECISIONS + the next action. It is never a state snapshot —
  # state is always re-verified live (see CLAUDE.md). Two canaries keep it honest,
  # because a stale handoff is worse than none: it reads exactly like a fresh one.
  NEXT="$CWD/NEXT.md"
  if [ -f "$NEXT" ]; then
    echo "───── NEXT.md — handoff for $(basename "$CWD"): inherit these decisions, verify state live ─────"
    cat "$NEXT"
    echo "───── end NEXT.md ─────"

    # Staleness: count commits landed since NEXT.md was last written. Anchored on
    # the commit SHA, not a timestamp window, so the boundary commit can't be
    # double-counted. An untracked (brand-new) NEXT.md has no SHA and is fresh.
    HSHA="$(git -C "$CWD" log -1 --format=%H -- NEXT.md 2>/dev/null)"
    if [ -n "$HSHA" ]; then
      # Exclude the hooks' own "auto:" checkpoints. They land on EVERY session end
      # and compact, so counting them would report "STALE: 1" every single time —
      # a warning that fires unconditionally is one you stop reading within a week,
      # which is the same way the --since boundary bug would have killed it.
      BEHIND="$(git -C "$CWD" rev-list --count --invert-grep --grep='^auto:' "$HSHA"..HEAD 2>/dev/null || echo 0)"
      if [ "${BEHIND:-0}" -gt 0 ]; then
        HT="$(git -C "$CWD" log -1 --format=%ct "$HSHA" 2>/dev/null || echo 0)"
        RT="$(git -C "$CWD" log -1 --format=%ct 2>/dev/null || echo 0)"
        echo "session-start: WARNING — NEXT.md is STALE: $BEHIND commit(s) landed after it was last written ($(( (RT - HT) / 86400 )) days ago). Treat it as a lead, not the truth; rewrite it the moment the next action it names is done."
      fi
    fi

    # Size cap: enforce the discipline mechanically. Prose asking for brevity is
    # the thing that failed before — a 161-line "handoff" that was really a
    # context dump, and rotted unnoticed for 42 days.
    LINES="$(grep -c '' "$NEXT" 2>/dev/null || echo 0)"
    [ "${LINES:-0}" -gt 40 ] && echo "session-start: NOTE — NEXT.md is $LINES lines (cap 40). It is drifting into a state snapshot; trim it back to decisions + next action."
  else
    echo "session-start: no NEXT.md in $CWD — there is no handoff. Write one as soon as you finish the first stretch of work (see ~/.claude/CLAUDE.md, Starting a fresh session)."
  fi
}

main "$@"
exit 0
