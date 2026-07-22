---
name: superlazy-brainstorm
description: >
  Produce a Sol-approved, executable plan and STOP. Fable (via the
  superlazy-drafter subagent) authors the spec and plan; Sol (Codex) gates both
  seams with no user-override; the approval travels in a hash-bound sidecar; an
  HTML review page is generated for the user. Standalone by default — the user
  reviews and calls superlazy-build themselves. Flags: --continue (internal,
  used by superlazy-build: suppress the hard stop), --skip-critics (loud
  bypass: Fable still authors, nothing is approved).
---

# superlazy-brainstorm — Fable plans, Sol approves, you stop

You are the COORDINATOR. You transcribe and orchestrate; you do not design.
Fable (the `superlazy-drafter` subagent) makes every judgment call; Sol
approves through `codex-critic.sh`, which is the ONLY writer of markers and
the sidecar. There is NO "proceed anyway" in this command.

## Announce
"Using superlazy-brainstorm: Fable drafts, Sol gates, hard stop for your review."

## Step 0 — Setup + preflight
1. Preflight: `[ -z "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ] || [ "$CLAUDE_CODE_SUBAGENT_MODEL" = "fable" ]`
   — if set to anything else, STOP and tell the user: that env var outranks
   per-dispatch models, so the Fable-authorship guarantee cannot hold. Do not
   silently draft on the wrong model.
2. Resolve the wrapper:
   ```bash
   WRAP=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/scripts/codex-critic.sh 2>/dev/null | sort -V | tail -1)
   VIZ=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/skills/superlazy-brainstorm/lib/plan-viz.mjs 2>/dev/null | sort -V | tail -1)
   ```
3. Effort policy: each seam's FIRST critic pass runs `CODEX_CRITIC_EFFORT=high`;
   re-review rounds run `CODEX_CRITIC_EFFORT=medium`. If the user's environment
   already exports `CODEX_CRITIC_EFFORT`, that value wins in both directions.
4. `--skip-critics` path: announce LOUDLY that nothing will be approved; do NOT
   create a run dir; still gather requirements (Step 1) and author via Fable
   (Steps 2 & 4); skip Seams 1–2 entirely; write plan + tasks with NO markers
   and NO sidecar; generate the HTML; stop (or return, under `--continue`).
   Consequence to state: a later non-skip build will re-critique — skipping
   defers review, it cannot fake approval.
5. Otherwise, run-dir setup (slug from topic, e.g. `<topic>`):
   ```bash
   d=.superlazy-build/<slug>
   # mutex: scan the whole slug family — any ACTIVE foreign-session member = BUSY
   for dir in .superlazy-build/<slug> .superlazy-build/<slug>-*; do
     [ -d "$dir" ] && [ ! -f "$dir/.done" ] && [ -f "$dir/session" ] \
       && [ "$(cat "$dir/session")" != "$CLAUDE_CODE_SESSION_ID" ] && { echo BUSY; break; }
   done
   ```
   On BUSY: STOP loudly (another session owns an active run for this slug).
   An active family member owned by THIS session → rebind and reuse it (one
   run per brief — build adopts this same dir under `--continue`). Else
   allocate the first genuinely ABSENT name in the family (`<slug>`,
   `<slug>-2`, …) — `.done` dirs are historical records: never reuse, clear, or
   rebind them. Then bind:
   ```bash
   mkdir -p "$d"; echo "$CLAUDE_CODE_SESSION_ID" > "$d/session"
   grep -qxF '.superlazy-build/' .gitignore 2>/dev/null || echo '.superlazy-build/' >> .gitignore
   ```

## Step 1 — Requirements, interactively, ALL upfront
Gather requirements with the user BEFORE spending Fable tokens: purpose,
constraints, success criteria, non-goals. One question at a time; multiple
choice when possible. When the brief is complete, restate it in one paragraph
and get a yes.

## Step 2 — Fable drafts the spec
Dispatch the drafter (Agent tool, `subagent_type: superlazy-drafter` — its
frontmatter pins `model: fable`; do not override): Assignment A with the
complete brief + repo context. It RETURNS spec content; YOU write it to
`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`. If the content is
malformed (no success criteria, placeholders), reject and re-dispatch — do not
patch it yourself.

## Step 3 — SEAM 1: spec-critic (Sol; loop until the marker exists)
```bash
printf '%s\n' "SPEC_DOC: <spec path>" "" "ORIGINAL BRIEF (verbatim):" "<brief>" "" "<re-review: what changed>" \
  | MARKER_DIR="$d" SPEC_PATH="<spec path>" CODEX_CRITIC_EFFORT=<high|medium per policy> "$WRAP" spec
```
The script self-invalidates, reviews, and writes `spec-critic.passed` ONLY on
`VERDICT: pass` with zero Critical/Important. Parse the output:
- marker exists → Seam 1 clear, go to Step 4.
- findings → show them to the user, dispatch the drafter to REVISE (findings
  verbatim), rewrite the file, re-run at `medium`. Loop. No override exists:
  if the user wants to bypass critics, that is build's `--skip-critics`, not
  this command.
- `VERDICT: NEEDS-HUMAN` → surface stderr and STOP (codex broken ≠ approved).

## Step 4 — Fable drafts the plan
Dispatch the drafter: Assignment B with the approved spec path. It returns the
plan markdown (starting `Spec: <path>`, tasks with the four headers +
`json:metadata` fences, subjects ≤ 60 chars, real `blockedBy` only, tiers by
spec-completeness). YOU write `<plan>.md` under `docs/superpowers/plans/` and
derive `<plan>.md.tasks.json` from it (id/subject/description per task,
0-based `blockedBy`). Create NO native tasks — the execution stage owns
TaskCreate; a second creator only makes duplicates.

## Step 5 — SEAM 2: plan-critic + tier audit (Sol; loop until the sidecar exists)
```bash
printf '%s\n' "PLAN_DOC: <plan path>" "SPEC_DOC: <spec path>" "" "<re-review: what changed>" \
  | MARKER_DIR="$d" PLAN_PATH="<plan path>" SPEC_PATH="<spec path>" CODEX_CRITIC_EFFORT=<per policy> "$WRAP" plan
```
On a clean verdict the script ALSO deterministically validates the plan
markdown's task fences (canonical TaskCreate source) and plan/tasks
equivalence, then writes the sidecar (`<plan>.md.approved.json`) and
`plan-critic.passed` — sidecar first, marker last. Failure modes it reports on
stderr and how you react:
- "Seam 1 has not passed" → you skipped Step 3; go back.
- "edit-between-seams" → the spec changed after Seam 1: re-run Step 3 (its
  self-invalidation resets both seams correctly).
- schema/equivalence violations → fix the derivation (or re-dispatch the
  drafter if the plan itself is malformed), re-run.
- findings → user sees them, drafter revises, re-run at `medium`. Loop.
A user-directed spec-level change during this loop = back to Step 3.

## Step 6 — HTML review page
```bash
node "$VIZ" "<plan path>"    # writes <plan>.md.html, prints the path
```
The local self-contained file is the deliverable. (You MAY additionally
publish it via the Artifact tool if available — never required.)

## Step 7 — Hard stop
Print the paths: spec, plan, tasks.json, sidecar, HTML. Then:
- standalone: `touch "$d/.done"` (the run is complete — approval travels in
  the sidecar, and closing prevents cross-session mutex false-BUSY), and STOP.
  Never ask a question here; the user reviews the HTML and calls
  `superlazy-build <plan>` themselves.
- `--continue`: leave the run ACTIVE (build keeps using it in-session) and
  return control to superlazy-build.
