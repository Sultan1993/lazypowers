---
name: superlazy-build
description: >
  Run the superpowers build pipeline (brainstorming -> writing-plans ->
  subagent-driven-development) with three adversarial critics gating each seam:
  superlazy-spec-critic, superlazy-plan-critic, superlazy-code-critic. Use when you want a reviewed,
  gated feature build. Critics run on OpenAI Codex (via codex exec), not Claude
  subagents. Plans are parallel-ready and executed in waves of concurrent
  subagents. Accepts optional --skip-critics and --serial flags.
---

# superlazy-build — gated superpowers pipeline

You are the COORDINATOR. Drive the existing superpowers skills as stages and
run a critic at each seam. Critics run on OpenAI Codex, NOT Claude subagents —
never use the `Agent` tool for a critic (see **Codex critics** below). Do NOT
skip seams. A PreToolUse gate hook backstops you by blocking stage transitions
until the prior critic's marker exists — but you must still run the critics.

## Announce
"Using superlazy-build to run a critic-gated build pipeline (critics on Codex)."

## Codex critics — how to run a seam
Every critic (spec/plan/code) runs on Codex via a wrapper. At each seam, resolve
the wrapper and pipe the crafted inputs to it on stdin; its stdout IS the VERDICT
block you parse (see Parser). Do NOT use the `Agent` tool for critics.

```bash
WRAP=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/scripts/codex-critic.sh 2>/dev/null | sort -V | tail -1)
"$WRAP" <spec|plan|code> <<'CTX'
<the crafted inputs for this seam: doc paths, original brief, diff range
 (BASE_SHA/HEAD_SHA for code), and (re-review) what changed>
CTX
```
- Read-only: the wrapper runs `codex exec -s read-only`, so Codex reads the
  spec/plan/diff/repo but never edits. All FIXING stays with the coordinator.
- Model: `CODEX_CRITIC_MODEL` env var (default `gpt-5.6-sol`, i.e. "Sol"); set it
  empty to use the Codex account default, or edit the wrapper.
- Requires the `codex` CLI installed + authenticated (`codex login`).
- Crafted context only — never pipe this session's history.
- If the wrapper emits `VERDICT: NEEDS-HUMAN` (codex missing/misconfigured),
  surface its stderr to the user and STOP; do not silently clear the seam.

## Inputs
- The user's brief (everything after the skill name).
- Optional `--skip-critics` flag.
- Optional `--serial` flag — opt out of wave parallelism: skip the
  parallel-ready plan override (Step 3) and the wave dispatch policy (Step 5).

## Parallelism — one checkout, one run
Parallel superlazy-build runs in a single checkout are FORBIDDEN at the git
level: sessions share one working tree, so one session's `git checkout` lands
the other session's commits on a foreign branch (observed live). Policy: a
solo run may use a plain branch; parallel runs MUST each live in their own
git worktree. The `session`/`.done` run markers fix only the gate hook — they
do not make a shared working tree safe for git.

## Step 0 — Setup
1. Choose a run id (slug of the topic), e.g. `superlazy-build-<topic>`.
2. SKIP path: if `--skip-critics` OR the brief is clearly trivial (single-file,
   sub-~30-line change), announce critics are skipped, do NOT create the run
   directory (the gate hook is then a no-op), run the plain flow
   (brainstorming -> writing-plans -> subagent-driven-development), and stop here.
3. Mutex check — never hijack another session's run:
   ```bash
   d=.superlazy-build/<run-id>
   [ -d "$d" ] && [ ! -f "$d/.done" ] && [ -f "$d/session" ] \
     && [ "$(cat "$d/session")" != "$CLAUDE_CODE_SESSION_ID" ] \
     && echo "BUSY" || echo "FREE"
   ```
   On BUSY: STOP loudly — tell the user this run is already active in another
   session: wait for it to finish or pick a different slug. Do not proceed.
   EXCEPTION: the user explicitly says they are continuing/resuming that run
   in THIS session (chain/resume) — then proceed to step 4, which re-binds it.
4. Initialize the run directory, bind it to this session, gitignore:
   ```bash
   mkdir -p .superlazy-build/<run-id>
   echo "$CLAUDE_CODE_SESSION_ID" > .superlazy-build/<run-id>/session
   grep -qxF '.superlazy-build/' .gitignore 2>/dev/null || echo '.superlazy-build/' >> .gitignore
   ```
   The `echo` also handles re-binding: when continuing an existing run in a
   new session, it overwrites `session` with this session's id — the gate hook
   only honors runs bound to the CURRENT session.
5. Create three native seam-gate tasks: "SEAM 1: spec-critic",
   "SEAM 2: plan-critic", "SEAM 3: code-critic".

## Step 1 — Brainstorm
Invoke Skill `superpowers-extended-cc:brainstorming` with the brief.
OVERRIDE: brainstorming ends by trying to invoke writing-plans. Do NOT let it.
When the design spec is written and user-approved, RETURN HERE for SEAM 1.

## Step 2 — SEAM 1: spec-critic (SURFACE, do not auto-fix)
1. Run the Codex critic `"$WRAP" spec` (see **Codex critics** above). Pipe ONLY:
   the spec doc path, the user's original brief verbatim, and (re-review) what
   changed. Never include this session's history. Its stdout is the VERDICT block.
2. Parse the VERDICT block (see Parser below).
3. Act:
   - pass -> record Minor to the run report; `touch
     .superlazy-build/<run-id>/spec-critic.passed`; go to Step 3.
   - targeted-fixes / rewrite -> SURFACE the Critical/Important findings to the
     user and ask how to handle each (fix / accept / reject). Spec findings are
     intent decisions; do NOT auto-edit. After the user directs fixes and the
     spec is updated, re-dispatch with a "what changed" note. Loop until pass or
     the user says proceed (then still write the marker).

## Step 3 — Write plan
Invoke Skill `superpowers-extended-cc:writing-plans`.
OVERRIDE: writing-plans ends with an AskUserQuestion choosing execution. Do NOT
let that run the executor. When the plan doc + .tasks.json exist, RETURN HERE.

OVERRIDE — the plan must be PARALLEL-READY (skip if `--serial`):
- Cut tasks file-disjoint. Encode waves via `blockedBy` — REAL dependencies
  only; a superfluous `blockedBy` kills parallelism.
- Pin cross-task contracts: any shared type/signature/name that one wave task
  references from a sibling goes in the plan header or in a dedicated
  contracts task scheduled as the FIRST wave. Parallel agents write blind,
  without compiling — each needs its neighbour's exact interface.
- Barrier tasks: shared steps (codegen/regeneration, wiring/registration,
  cleanup) become separate integration tasks AFTER the wave that needs them.
  Prefer a codegen wave FIRST (one regen) so later waves see generated types.
- State the test policy explicitly in the plan: when wave tasks share a build
  unit (e.g. one compilation package), agents WRITE code+tests but
  compile/test runs are deferred to the barrier.

## Step 4 — SEAM 2: plan-critic (AUTO-FIX, bounded)
1. Run the Codex critic `"$WRAP" plan` (see **Codex critics** above), piping: plan
   doc path, spec doc path, (re-review) what changed. Crafted context only. Its
   stdout is the VERDICT block.
2. Parse the VERDICT block.
3. Act:
   - pass -> `touch .superlazy-build/<run-id>/plan-critic.passed`; go to Step 5.
   - targeted-fixes -> YOU edit the plan doc + .tasks.json to address each
     Critical/Important, then re-dispatch with a "what changed" note. MAX 2
     fix-rounds. If still not pass after round 2, STOP and surface residual
     findings to the user.
   - rewrite -> surface to the user; do not auto-rewrite the whole plan.

## Step 5 — Execute
Invoke Skill `superpowers-extended-cc:subagent-driven-development`.
- Keep its per-task reviews AND its final reviewer (quality lens) — do NOT
  suppress them. Per-task reviews are read-only: run them in parallel after
  each wave's join.
- Wave dispatch (tightens sdd's Bounded Parallel Dispatch; skip if `--serial`):
  - Dispatch ALL unblocked file-disjoint tasks of a wave in ONE message
    (parallel Agent calls), then join.
  - Wave agents do NOT commit — they share one worktree and race on the git
    index. The coordinator commits at the join, one commit per task. (This
    overrides sdd's implementer-commits default for wave tasks.)
  - Barrier after each wave: codegen/regen, build, full test run. Failures go
    back to the owning task's agent (fresh dispatch with the failure output);
    MAX 2 repair rounds, then surface to the user. Next wave only after a
    green barrier.
  - Inherently serial tasks (live probes, checks against a running service)
    stay OUTSIDE waves, ordered as the plan states.
  - sdd's rule stands: uncertain file overlap → serialize.
- Capture the range:
  ```bash
  cd <worktree>                                   # the worktree sdd uses
  BASE_SHA=$(git merge-base <parent-branch> HEAD) # parent usually dev/main
  # ... sdd runs ...
  HEAD_SHA=$(git rev-parse HEAD)
  ```
  If unsure of the parent, use the branch the worktree was created from.

## Step 6 — SEAM 3: code-critic (AUTO-FIX, bounded)
1. Run the Codex critic `"$WRAP" code` (see **Codex critics** above), piping:
   worktree path, BASE_SHA, HEAD_SHA, plan doc path, spec doc path, (re-review)
   what changed. Its stdout is the VERDICT block.
2. Parse the VERDICT block.
3. Act:
   - pass -> go to Step 7.
   - targeted-fixes -> coordinator (or a fix subagent) edits code to address
     Critical/Important, commit, update HEAD_SHA, re-dispatch. MAX 2 rounds,
     then surface residual to user.
   - rewrite -> surface to user.

## Step 7 — Finish
Invoke Skill `superpowers-extended-cc:finishing-a-development-branch`.
Then `touch .superlazy-build/<run-id>/.done` (terminal marker; the gate
ignores finished runs).

## VERDICT parser (use at every seam)
- VERDICT = first line matching `^VERDICT:`; value is the token after the colon.
- VERDICT token `NEEDS-HUMAN` (the wrapper couldn't run Codex — missing CLI,
  bad model, no prompt file) is NEVER a pass regardless of counts: surface the
  wrapper's stderr and STOP the seam. Fix Codex, then re-run.
- Critical count = lines matching `^- \[Critical\]`. Important = `^- \[Important\]`.
- pass-gate = (VERDICT != NEEDS-HUMAN AND Critical == 0 AND Important == 0). The
  self-reported VERDICT token is otherwise advisory; the COUNTS are authoritative.
- Garbled/missing VERDICT line -> NEEDS-HUMAN: show raw output, ask how to proceed.
