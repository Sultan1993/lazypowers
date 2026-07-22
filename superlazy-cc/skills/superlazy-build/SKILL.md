---
name: superlazy-build
description: >
  Execute a Sol-approved plan. With a plan path: verify the hash-bound approval
  sidecar and skip straight to execution (stale sidecar = one-pass re-bless,
  never a re-brainstorm). Without a plan: run superlazy-brainstorm inline
  (Fable drafts, Sol gates) and continue into execution. Seam 3 (Sol
  code-critic) always gates the diff. Waves of concurrent subagents, per-task
  model routing via modelTier. Flags: --spec <path>, --skip-critics, --serial.
---

# superlazy-build — verify, (re-)bless, execute

You are the COORDINATOR. Approvals are files written only by `codex-critic.sh`;
your job is to route through them, never around them. ANNOUNCE the branch you
take in one line so a wrong classification is caught immediately.

## Announce
"Using superlazy-build to execute a critic-gated plan (critics on Codex)."

## Codex critics — how to run a seam
```bash
WRAP=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/scripts/codex-critic.sh 2>/dev/null | sort -V | tail -1)
```
- Read-only: the wrapper runs `codex exec -s read-only`. Seam modes
  (`spec|plan|code`) are PINNED to Sol (`gpt-5.6-sol`) — env overrides are
  ignored by design.
- Effort policy: first pass of a seam `CODEX_CRITIC_EFFORT=high`, re-review
  rounds `medium`; a user-exported `CODEX_CRITIC_EFFORT` wins in both directions.
- Marker mode: pass `MARKER_DIR="$d"` (+ `PLAN_PATH`/`SPEC_PATH` where noted) —
  the SCRIPT writes `<seam>-critic.passed` and the sidecar, only on
  `VERDICT: pass` with zero Critical/Important. You never write markers.
- `VERDICT: NEEDS-HUMAN` → surface stderr and STOP the seam.
- Requires the `codex` CLI installed + authenticated (`codex login`).

## Inputs
- Optional plan path (any phrasing — detection is artifact-driven, below).
- `--spec <path>` — spec location override for re-bless when no sidecar names it.
- `--skip-critics` — loud bypass, see below.
- `--serial` — opt out of wave parallelism.

## Parallelism — one checkout, one run
Parallel builds in a single checkout are FORBIDDEN at the git level (shared
working tree; observed live). A solo run may use a plain branch; parallel runs
MUST each live in their own git worktree.

## Step 0 — Classify the argument (artifact-driven, never phrasing)
Extract a file path from the argument if present.
```
no path, or path without <X>.md.tasks.json  →  BRIEF   (Step B)
<X>.md with <X>.md.tasks.json sibling       →  PLAN    (Step P) — brainstorm is NEVER called
```

`--skip-critics` (either branch): announce LOUDLY; create NO run dir (the gate
is dormant with no active run); with a brief, invoke Skill
`superlazy-cc:superlazy-brainstorm` with `--continue --skip-critics` (Fable
still authors; no markers, no sidecar); with a plan, skip verify/re-bless.
Execute, skip Seam 3, finish. State the consequence: nothing is approved, so a
later non-skip build re-critiques. Skipping defers review; it cannot fake it.

## Step 0.5 — Run dir (PLAN branch only, unless --skip-critics)
BRIEF branch: do NOT create a run dir here — `superlazy-brainstorm` owns
run-dir creation (its Step 0), and under `--continue` it leaves that run
ACTIVE; on return, build ADOPTS it (the newest same-session active run — the
same one the gate hook selects). Exactly one run dir exists per brief build.
PLAN branch: slug from the plan. Mutex scans the WHOLE slug family
(`<slug>`, `<slug>-2`, …): any ACTIVE member owned by a foreign session →
BUSY, stop loudly (never sidestep by suffixing). An active member owned by
THIS session → rebind (overwrite its `session` file) and reuse. Otherwise
allocate the first genuinely ABSENT name in the family — `.done` dirs are
historical records: never reused, cleared, or rebound.
```bash
mkdir -p "$d"; echo "$CLAUDE_CODE_SESSION_ID" > "$d/session"
grep -qxF '.superlazy-build/' .gitignore 2>/dev/null || echo '.superlazy-build/' >> .gitignore
```
Do NOT create tracker tasks — build creates no native tasks of any kind; the
execution stage (sdd) is the single TaskCreate owner.

## Step B — No plan: brainstorm inline, then execute
Invoke Skill `superlazy-cc:superlazy-brainstorm` with `--continue` and the
brief. It creates and owns the run dir, gathers requirements with the user,
has Fable draft spec + plan, runs Seams 1–2 (markers + sidecar land in ITS
run dir), generates the HTML, and returns WITHOUT stopping. Build then ADOPTS
that run dir (newest same-session active) for Seam 3 and `.done`. Then go to
Step E.

## Step P — Plan given: verify, else re-bless
Announce which of these fires:
1. `MARKER_DIR="$d" "$WRAP" verify <plan.md>`
   - exit 0 (`VERIFIED`) → "Approved plan verified — skipping to execution."
     Both markers are minted from the sidecar. Go to Step E. (Commit-drift
     warnings on stderr are informational — repeat them, never block.)
   - exit 3 → stale/missing/legacy sidecar → re-bless:
2. RE-BLESS ("Sidecar stale — re-blessing via plan-critic."):
   a. `MARKER_DIR="$d" "$WRAP" verify --spec-only <plan.md>` — exit 0 means the
      spec is provably the previously-approved bytes: spec marker minted, run
      ONE plan-critic pass (Step P3). Exit 3 → the spec changed too or no
      sidecar exists:
   b. Resolve the spec (deterministic, first hit): sidecar `specPath` → the
      plan doc's `Spec:` line → `--spec <path>` → none → STOP: "re-bless needs
      the spec; pass --spec <path> or run a fresh brainstorm." Never guess.
      With a spec in hand, run the spec critic first
      (`MARKER_DIR="$d" SPEC_PATH=<spec> "$WRAP" spec`, findings → surface to
      the user and stop — an unapproved spec is not silently fixable here),
      then:
   c. P3, one plan-critic pass:
      `MARKER_DIR="$d" PLAN_PATH=<plan> SPEC_PATH=<spec> "$WRAP" plan`
      - sidecar + marker written → "Re-blessed." Go to Step E.
      - findings → surface to the user, do not execute. (Fixing a plan is a
        coordinator edit + re-run of this step, or back to brainstorm — the
        user decides.)
   Never more than two Sol calls; never Fable; never the interactive flow.

## Step E — Execute (sdd)
Invoke Skill `superpowers-extended-cc:subagent-driven-development` **with the
argument `planPath=<canonical repo-relative plan path>`** — the gate parses
that exact token and requires equality with the approval marker; an invocation
that names a different plan (or none) is denied. sdd owns task creation and
extracts tasks from the gate-validated files.
- Keep sdd's per-task reviews AND its final reviewer — do NOT suppress them.
- Wave dispatch (skip if `--serial`):
  - Dispatch ALL unblocked file-disjoint tasks of a wave in ONE message
    (parallel Agent calls), then join. Route each task's implementer per its
    `modelTier` via the routing file mapping.
  - Wave agents do NOT commit — the coordinator commits at the join, one
    commit per task.
  - Barrier after each wave: codegen/regen, build, full test run. Failures go
    back to the owning task's agent; MAX 2 repair rounds, then surface.
  - Inherently serial tasks stay OUTSIDE waves. Uncertain file overlap →
    serialize.
- Capture the range:
  ```bash
  BASE_SHA=$(git merge-base <parent-branch> HEAD)   # before execution
  HEAD_SHA=$(git rev-parse HEAD)                    # after
  ```

## Step S3 — SEAM 3: code-critic (Sol; bounded auto-fix)
```bash
printf '%s\n' "WORKTREE: <path>" "BASE_SHA: <sha>" "HEAD_SHA: <sha>" \
  "PLAN_DOC: <plan path>" "SPEC_DOC: <spec path>" "" "<re-review: what changed>" \
  | MARKER_DIR="$d" CODEX_CRITIC_EFFORT=<per policy> "$WRAP" code
```
- pass (marker written) → Step F.
- findings → coordinator (or a fix subagent) addresses Critical/Important,
  commit, update HEAD_SHA, re-dispatch at `medium`. MAX 2 fix rounds, then
  surface residual findings to the user.
- `NEEDS-HUMAN` → surface stderr, STOP.

## Step F — Finish
Invoke Skill `superpowers-extended-cc:finishing-a-development-branch`.
Then `touch "$d/.done"` (terminal marker; gate and mutex ignore finished runs).

## VERDICT parser (informational — the SCRIPT is authoritative for approvals)
- VERDICT token = word after `^VERDICT:`. Clean = token exactly `pass` AND
  zero `^- \[Critical\]` AND zero `^- \[Important\]` lines. The script applies
  this same rule before writing any marker; you read the output only to relay
  findings to the user.
- `NEEDS-HUMAN` is never a pass: surface stderr, stop the seam, fix Codex.
