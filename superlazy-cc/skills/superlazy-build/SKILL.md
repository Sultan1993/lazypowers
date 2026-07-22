---
name: superlazy-build
description: >
  Execute an implementation plan. Given a plan path, go straight to execution —
  the plan is the contract, no approval to verify. Without a plan, run
  superlazy-brainstorm inline (Fable drafts, Sol critiques) and continue into
  execution. Waves of concurrent subagents, per-task model routing via
  modelTier, then Sol reviews the diff. Flags: --skip-critics, --serial.
---

# superlazy-build — execute the plan you were handed

You are the COORDINATOR. If the user hands you a plan, that plan is done —
execute it. There is nothing to verify: no approval marker, no sidecar, no
hashes. Reviewing the plan was `superlazy-brainstorm`'s job and the user's;
your job starts after that.

## Announce
"Using superlazy-build to execute <plan> (Sol reviews the diff at the end)."

## Codex critic — how to run the code seam
```bash
WRAP=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/scripts/codex-critic.sh 2>/dev/null | sort -V | tail -1)
```
- Read-only: the wrapper runs `codex exec -s read-only`. All FIXING stays with
  the coordinator.
- Round budget: pass `CODEX_CRITIC_ROUND`. Sol reviews at most
  `CODEX_CRITIC_MAX_ROUNDS` (default 2) times, then you fix what you can and
  finish. Read the trailing `GATE:` line; never reset the round to buy passes.
- Every round runs at `high` effort. Do not set `CODEX_CRITIC_EFFORT` yourself.
- Requires the `codex` CLI installed + authenticated (`codex login`).

## Inputs
- Optional plan path (any phrasing — detection is artifact-driven, below).
- `--skip-critics` — Sol never runs, at either stage.
- `--serial` — opt out of wave parallelism.

## Parallelism — one checkout, one run
Parallel builds in a single checkout are FORBIDDEN at the git level: sessions
share one working tree, so one session's `git checkout` lands the other's
commits on a foreign branch (observed live). A solo run may use a plain branch;
parallel runs MUST each live in their own git worktree.

## Step 0 — Classify the argument (artifact-driven, never phrasing)
Extract a file path from the argument if present.
```
<X>.md with an <X>.md.tasks.json sibling  →  PLAN   (Step E) — brainstorm is NEVER called
anything else, or no path                 →  BRIEF  (Step B)
```
Announce which branch you took in one line, so a wrong classification is caught
immediately.

## Step B — No plan: brainstorm inline, then execute
Invoke Skill `superlazy-cc:superlazy-brainstorm` with `--continue` and the
brief (adding `--skip-critics` if it was passed to you). It gathers
requirements with the user, has Fable draft the spec and plan, runs Sol over
each, generates the HTML, and returns the plan path without stopping. Then go
to Step E.

## Step E — Execute (sdd)
Invoke Skill `superpowers-extended-cc:subagent-driven-development` with the
argument `planPath=<repo-relative plan path>`. sdd owns task creation — build
creates no native tasks of any kind.
- Keep sdd's per-task reviews AND its final reviewer — do NOT suppress them.
- Wave dispatch (skip if `--serial`):
  - Dispatch ALL unblocked file-disjoint tasks of a wave in ONE message
    (parallel Agent calls), then join. Route each task's implementer per its
    `modelTier`.
  - Wave agents do NOT commit — they share one worktree and race on the git
    index. The coordinator commits at the join, one commit per task.
  - Barrier after each wave: codegen/regen, build, full test run. Failures go
    back to the owning task's agent; MAX 2 repair rounds, then surface.
  - Inherently serial tasks stay OUTSIDE waves. Uncertain file overlap →
    serialize.
- Capture the range:
  ```bash
  BASE_SHA=$(git merge-base <parent-branch> HEAD)   # before execution
  HEAD_SHA=$(git rev-parse HEAD)                    # after
  ```

## Step S3 — Sol reviews the diff (≤2 rounds, then finish)
Skip entirely under `--skip-critics`.
```bash
printf '%s\n' "WORKTREE: <path>" "BASE_SHA: <sha>" "HEAD_SHA: <sha>" \
  "PLAN_DOC: <plan path>" "SPEC_DOC: <spec path>" "" "<re-review: what changed>" \
  | CODEX_CRITIC_ROUND=<1,2> "$WRAP" code
```
| `GATE:` | What you do |
|---|---|
| `pass` | Step F. |
| `revise` | Address Critical/Important (coordinator or a fix subagent), commit, update `HEAD_SHA`, re-run at `ROUND+1`. |
| `final` | Last review. Fix what you can, commit, then go to Step F and LIST what is still open. |
| `conclude` | Budget spent, no call made. Go to Step F. |
| `needs-human` | Surface stderr and STOP. |

## Step F — Finish
Invoke Skill `superpowers-extended-cc:finishing-a-development-branch`.
If Step S3 ended on `final`, repeat Sol's residual findings to the user first —
they are shipping with those open and should hear it from you, not discover it.

## VERDICT parser
- VERDICT token = the word after `^VERDICT:`. Counts are authoritative:
  `^- \[Critical\]` and `^- \[Important\]` lines.
- The wrapper's trailing `GATE:` line already applies this rule — read it and
  act. You parse the findings themselves only to relay and fix them.
- `NEEDS-HUMAN` is never a pass: surface stderr, stop the seam, fix Codex.
