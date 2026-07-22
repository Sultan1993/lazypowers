---
name: superlazy-brainstorm
description: >
  Write a detailed, executable plan with Fable and Sol, then STOP. Fable (the
  superlazy-drafter subagent) authors the design spec and the implementation
  plan; Sol (Codex) critiques each one at most twice; Fable revises and
  concludes. Produces the spec, the plan, its .tasks.json, and an HTML review
  page. You read it and hand it to superlazy-build yourself. Flags: --continue
  (internal, used by superlazy-build: suppress the hard stop), --skip-critics
  (Fable drafts alone, Sol never runs).
---

# superlazy-brainstorm — Fable drafts, Sol sharpens, you get a plan

You are the COORDINATOR. You transcribe and orchestrate; you do not design.
Fable (the `superlazy-drafter` subagent) makes every judgment call; Sol
critiques through `codex-critic.sh`.

This command GATES NOTHING. Its output is a plan document. Handing that plan to
`superlazy-build` is the user's decision — there is no approval to verify, no
marker, no hash. If the user hands over a plan, it is done by definition.

## Announce
"Using superlazy-brainstorm: Fable drafts, Sol critiques twice, Fable concludes."

## The loop — identical at both seams

```
Fable drafts → Sol → Fable revises → Sol → Fable revises → DONE
```

Two Sol passes per seam, then **Fable has the last word**. A critic that
re-reads a document always finds one more `[Important]`, so this never
converges on its own — the budget is the whole point. Pass
`CODEX_CRITIC_ROUND` on every seam call and act on the trailing `GATE:` line:

| `GATE:` | What you do |
|---|---|
| `pass` | Clean — the critic said `pass` AND no findings parsed. Move on. |
| `revise` | Show findings to the user, dispatch Fable to revise, re-run at `ROUND+1`. |
| `final` | Last critic pass. Fable revises once, addressing what it can. Then MOVE ON. |
| `conclude` | Budget already spent; no Codex call was made. Move on immediately. |
| `needs-human` | Surface stderr and STOP — a broken Codex is not a clean verdict. |

Never re-run a seam after `final` or `conclude`. Never reset `CODEX_CRITIC_ROUND`
to 1 to buy extra passes. Never argue a finding on Fable's behalf. If the user
wants another round they will ask; that is their call, not yours.

`CODEX_CRITIC_ROUND` must be a literal positive integer — `1`, then `2`. The
wrapper exits 2 with `VERDICT: NEEDS-HUMAN` on anything else (including the
`<1,2>` placeholder below, copied verbatim). Also read stderr on every call: it
may warn that the critic's findings were in a format the wrapper cannot count,
which means you must read the verdict body yourself rather than trust the gate.

## Step 0 — Preflight
1. `[ -z "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ] || [ "$CLAUDE_CODE_SUBAGENT_MODEL" = "fable" ]`
   — if set to anything else, STOP and tell the user: that env var outranks
   per-dispatch models, so the Fable-authorship guarantee cannot hold. Do not
   silently draft on the wrong model.
2. Resolve the wrapper and the viz:
   ```bash
   WRAP=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/scripts/codex-critic.sh 2>/dev/null | sort -V | tail -1)
   VIZ=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/skills/superlazy-brainstorm/lib/plan-viz.mjs 2>/dev/null | sort -V | tail -1)
   ```
3. Every critic round runs at `high` effort — each Codex call is a fresh cold
   read, and the last round is the final word before Fable concludes. Do not
   set `CODEX_CRITIC_EFFORT` yourself; a user who exports it overrides it.
4. `--skip-critics`: announce that Sol will not run, then do Steps 1, 2, 4, 6, 7
   and skip Steps 3 and 5. Fable still authors everything.

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

## Step 3 — Sol critiques the spec (≤2 rounds)
```bash
printf '%s\n' "SPEC_DOC: <spec path>" "" "ORIGINAL BRIEF (verbatim):" "<brief>" "" "<re-review: what changed>" \
  | CODEX_CRITIC_ROUND=<1,2> "$WRAP" spec
```
Follow the GATE table. Spec findings are intent decisions: show them to the
user, and dispatch Fable to revise with the findings verbatim. On `final`,
Fable's revision closes the spec — go to Step 4 regardless of what is left.

## Step 4 — Fable drafts the plan
Dispatch the drafter: Assignment B with the spec path. It returns the plan
markdown (starting `Spec: <path>`, tasks with the four headers +
`json:metadata` fences, subjects ≤ 60 chars, real `blockedBy` only, tiers by
spec-completeness). YOU write `<plan>.md` under `docs/superpowers/plans/` and
derive `<plan>.md.tasks.json` from it (id/subject/description per task,
0-based `blockedBy`). Create NO native tasks — the execution stage owns
TaskCreate; a second creator only makes duplicates.

## Step 5 — Sol critiques the plan (≤2 rounds)
```bash
printf '%s\n' "PLAN_DOC: <plan path>" "SPEC_DOC: <spec path>" "" "<re-review: what changed>" \
  | CODEX_CRITIC_ROUND=<1,2> "$WRAP" plan
```
Follow the GATE table. When Fable revises the plan markdown, re-derive
`.tasks.json` from it — the markdown is the source, the JSON is its mirror.
A user-directed spec change mid-loop = back to Step 3 with `ROUND=1`.

## Step 6 — HTML plan page
```bash
node "$VIZ" "<plan path>"    # writes <plan>.md.html, prints the path
```
This renders THE PLAN — the brief, then every task in execution order with its
goal, steps, files, acceptance criteria and verify command, grouped into the
waves they run in. It is what the user reads instead of the markdown; the
structural checks are a collapsed footnote, not the subject. The local
self-contained file is the deliverable. (You MAY additionally publish it via
the Artifact tool if available — never required.)

If it prints structural problems on stderr, they go in your Step 7 summary
verbatim. `plan-tasks-order-mismatch` / `-count-mismatch` / `-fence-drift` mean
YOUR `.tasks.json` derivation disagrees with Fable's markdown — build executes
the JSON while the user reads the page, so fix the derivation and re-run the
viz before stopping. `no-verify` / `no-criteria` / `bad-tier` are Fable's to
fix. Nothing blocks here, but shipping an unreported problem is not an option.

## Step 7 — Hard stop
Print the paths: spec, plan, tasks.json, HTML. If any seam ended on `final` or
`conclude`, say so plainly and list what Sol still had open — the user is
deciding whether to build, and they need to know what went unaddressed.

- standalone: STOP. Never ask a question here; the user reviews the HTML and
  runs `superlazy-build <plan>` when they are ready.
- `--continue`: return the plan path to the caller and keep going.
