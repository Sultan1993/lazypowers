# superlazy-cc — three-command restructure — design spec

Date: 2026-07-22 (rev 2 — full rewrite after spec-critic verdict `rewrite`, 5 Critical / 4 Important)
Status: in review (Seam 1)
Repo: `Sultan1993/lazypowers` (plugin `superlazy-cc`), version `1.5.0` → `1.6.0`

## Purpose

Restructure `superlazy-cc` into three standalone commands with a clean division of
labour between models, moving control-flow reliability out of fragile SKILL prose
and into script-enforced ordering, tool restrictions, and verifiable artifacts.

- **Fable** authors the spec and plan (the frontier planner).
- **Sol** (Codex `gpt-5.6-sol`) is the *only* critic, gating all three seams.
- **Execution model is per-task**, decided by Fable and audited by Sol, routed via
  `docs/superpowers/model-routing.json` (mechanical/standard → Sonnet, frontier → Opus).
- **Opus + Sol** is the one fixed frontier pair, used only in review.

## Threat model — what is enforced vs what is convention

The adversary is **accidental drift and skipped steps under cognitive load** — a
coordinator that waves findings through, a plan edited after approval, a seam
quietly skipped. It is **not** a malicious same-OS user: any process running as
the user can write any file, including markers and sidecars. No mechanism below
survives deliberate same-user forgery, and none tries (cryptographic provenance is
an explicit non-goal).

Enforced **by construction**:
- The drafter subagent has no Write/Edit tools → it cannot materialize files; it
  can only return content. (Tool restrictions bind the subagent, not the parent.)
- In the intended flow, markers and the approval sidecar are created only by
  `codex-critic.sh`, and the sidecar only after both seams passed (ordering below).
- The execution stage is blocked by the existing session-bound gate hook unless
  `plan-critic.passed` exists in the session's run dir.
- Every plan task must carry a valid `modelTier` or `TaskCreate` is blocked
  (harness gate `pre-taskcreate-model-tier`, armed by the routing file).

Honest **conventions** (SKILL prose, not enforcement):
- The coordinator faithfully transcribing Fable's returned content.
- The coordinator not hand-writing markers/sidecars outside the flow.
The design's job is to make the correct path the path of least resistance and to
make omissions *detectable* (a skipped seam produces no sidecar → a later build
re-critiques). Claims stronger than that are wrong and are not made here.

## The three commands

### 1. `superlazy-brainstorm` (NEW, standalone)

Produces an approved, executable plan and stops.

1. **Coordinator** gathers requirements interactively with the user (all questions
   upfront, before any Fable tokens are spent).
2. Coordinator initializes the run dir `.superlazy-build/<run-id>/` (same
   convention, session binding, and mutex as build; already gitignored).
3. **Fable drafter** (`superlazy-drafter` agent, `model: fable`) returns the design
   spec as content; the coordinator writes it to
   `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`.
4. **Seam 1:** coordinator runs `codex-critic.sh spec` (marker mode, below). The
   script writes `spec-critic.passed` only on a clean verdict. Loop — surface
   findings, Fable revises, re-run — until the marker exists. **No user-override**:
   there is no "proceed anyway" path in this command (deliberately unlike current
   build's `SKILL.md:105`). The bypass valve lives in build (`--skip-critics`),
   loud and explicit, not here.
5. **Fable drafter** returns the plan as content: plan markdown + per-task blocks
   in the exact `.tasks.json` task format (each task's description carries the
   four section headers and the `json:metadata` fence with `files`, `modelTier`,
   `verifyCommand`, `acceptanceCriteria`). Task subjects ≤ 60 chars (upstream
   6.2.x requirement). The coordinator writes `<plan>.md` and `<plan>.md.tasks.json`
   and creates the native tasks. (`pre-taskcreate-model-tier` blocks any task
   whose fence lacks a valid `modelTier` — this forces Fable's tier decisions all
   the way through.)
6. **Seam 2:** coordinator runs `codex-critic.sh plan` (marker mode with
   `PLAN_PATH`/`SPEC_PATH`). On a clean verdict **and** only if
   `spec-critic.passed` already exists, the script writes `plan-critic.passed`
   and then the approval sidecar (ordering below). The plan-critic prompt includes
   the **tier-assignment audit**: `frontier` where steps are complete = wasted
   money; `mechanical` where steps require judgment = silent quality loss;
   tie-break is spec completeness. Loop until the sidecar exists.
7. Coordinator generates the HTML review page with `plan-viz.mjs` → writes it
   next to the plan (`<plan>.md.html`). Publishing via the Artifact tool is
   **best-effort**: attempt it; on unavailability or denial, print the local file
   path instead. The local file is the contract; the URL is a convenience.
8. Ends by **printing** the paths (spec, plan, tasks, sidecar, HTML/URL) and
   stops. Ending-by-print (never `AskUserQuestion`) is a design rule of this
   command — the upstream handoff guard may not be armed in this flow (it arms on
   a `writing-plans` signal we never emit), so no enforcement is claimed for it.

Internal `--continue` flag: suppresses the hard stop; used only when
`superlazy-build` invokes brainstorm for its no-plan path.

### 2. `superlazy-build [plan]` (MODIFY existing)

- **With a plan** (arg resolves to `X.md` with an `X.md.tasks.json` sibling): run
  `codex-critic.sh verify X.md`. On success the script mints both seam markers in
  the run dir → skip Steps 1–4 straight to execution. On failure (exit 3) run the
  **auto re-bless**: a single `codex-critic.sh plan` pass over the current bytes
  (requires the spec at the sidecar's `specPath`, or a `--spec` argument when no
  sidecar exists); a clean verdict writes fresh markers + sidecar → execute.
  Never brainstorm when `tasks.json` exists.
- **Without a plan** (no path, or path without `.tasks.json`): invoke
  `superlazy-brainstorm --continue`, then execute without stopping.
- Build **announces the branch it took** in one line ("Approved plan verified —
  skipping to execution" / "Sidecar stale — re-blessing via plan-critic" / "No
  task plan found — brainstorming first").
- Step 1's invocation of `superpowers-extended-cc:brainstorming` is replaced by
  `superlazy-brainstorm --continue`, deleting the OVERRIDE prose at current
  `SKILL.md:90` and `SKILL.md:109`.
- **Seam 3** (`codex-critic.sh code`) always runs. sdd's per-task Claude
  reviewers are kept (different layer, `standard` tier).
- Existing flags unchanged: `--skip-critics` (the explicit bypass valve),
  `--serial`.

### 3. `superlazy-review` (MODIFY existing)

Default Claude reviewer becomes **Opus** — in every layer that currently says
sonnet, because the dispatch default lives in agent frontmatter, not in the
report:
- `agents/superlazy-review-critic.md` frontmatter: `model: sonnet` → `model: opus`
- `agents/superlazy-refute-critic.md` frontmatter: `model: sonnet` → `model: opus`
- `skills/superlazy-review/SKILL.md`: always pass `model: <--claude-model or opus>`
  explicitly on every Agent dispatch (never rely on frontmatter resolution), and
  default `claudeModel` in `meta.json` to `"opus"`.
- `lib/review-synth.mjs`: reporting fallback `'sonnet'` → `'opus'`.
Verification asserts the **dispatch configuration** (frontmatter + SKILL
instruction), not merely the rendered report header. Stays standalone and
advisory; works on arbitrary targets.

## `codex-critic.sh` — interface contract (rev 2)

Modes: `spec` | `plan` | `code` (LLM critics), `verify` (non-LLM), `review` |
`refute` (JSON modes — **byte-for-byte unchanged**, no marker logic).

Critic modes (`spec`/`plan`/`code`):
- Inputs: crafted context on stdin (unchanged). Env: `MARKER_DIR` (opt-in; absent
  → behave exactly as today), plus for `plan` mode `PLAN_PATH` and `SPEC_PATH`
  (repo-relative or absolute; stored in the sidecar as repo-root-relative via
  `git rev-parse --show-toplevel`).
- The script **captures** Codex output (no `exec`), prints it to stdout verbatim,
  then parses it: VERDICT = first `^VERDICT:` line; Critical = count of
  `^- \[Critical\]`; Important = count of `^- \[Important\]`.
- **Clean** = VERDICT line present, not `NEEDS-HUMAN`, Critical == 0, Important == 0.
- On clean + `MARKER_DIR` set: write `$MARKER_DIR/<mode>-critic.passed`
  (temp-file + `mv -f` rename, same directory). `plan` mode additionally requires
  `spec-critic.passed` to already exist in `$MARKER_DIR` — if it does not, no
  sidecar and no plan marker are written and a warning goes to stderr (**this is
  the seam-ordering enforcement**: a sidecar can only exist if both seams passed,
  in order). After the plan marker, the sidecar is written last (temp + rename) —
  sidecar-as-final-commit.
- On non-clean or unparseable output: print verbatim, write nothing. Wrapper-level
  failures (no codex CLI, no prompt file) keep today's behavior: `VERDICT:
  NEEDS-HUMAN` on stdout, exit 2, write nothing.

`verify <plan.md>` (non-LLM, no Codex call):
- Derives `tasks = <plan.md>.tasks.json`, `sidecar = <plan.md>.approved.json`.
- Checks: sidecar exists and parses; `planHash` equals
  `sha256(plan.md bytes ++ tasks.json bytes)`; `specPath` exists;
  `specHash` equals sha256 of its bytes. Any missing file, missing field, parse
  error, or hash mismatch → **exit 3**, reason on stderr, nothing written
  (legacy/foreign sidecars lacking `specPath`/`specHash` are therefore stale by
  definition and take the re-bless path).
- On success: writes `spec-critic.passed` and `plan-critic.passed` into
  `$MARKER_DIR` (temp + rename), prints `VERIFIED`, exit 0. If sidecar `commit`
  != `git rev-parse HEAD`: warning on stderr, still exit 0 (drift warns, never
  blocks).
- This mode exists so the fast path needs **no LLM call** while marker-writing
  stays inside the one trusted script (resolves the sole-writer/fast-path
  contradiction).

## Approval sidecar (rev 2)

`<plan>.md.approved.json`, written **only** by `codex-critic.sh` on a clean
`plan` verdict with the spec seam already passed:

```json
{
  "planHash": "<sha256 hex of plan.md bytes ++ tasks.json bytes>",
  "specPath": "<repo-root-relative path to the spec doc>",
  "specHash": "<sha256 hex of the spec bytes>",
  "commit":   "<git rev-parse HEAD at approval>",
  "seams":    ["spec", "plan"]
}
```

The sidecar now **binds the spec** it was approved against: a changed or missing
spec stales the sidecar (the plan-critic needs the spec for coverage review, so
approval without a pinned spec was meaningless). `commit` is stored separately
from the hashes so an unchanged plan on a moved repo warns instead of
invalidating. Binary semantics: existence = clean pass; no verdict detail or
residual counts. Tamper-evident, not tamper-proof (see threat model).

## Enforcement chain — where each guarantee actually lives

| Boundary | Mechanism | Kind |
|---|---|---|
| Drafter cannot write files | agent tool allowlist (no Write/Edit) | construction |
| Spec seam passed | `spec-critic.passed` written by script on clean verdict | script |
| Plan seam passed, in order | plan marker + sidecar written by script only when clean AND spec marker exists | script |
| Cross-session approval | `verify` mode validates sidecar, mints session markers | script |
| Execution start | existing `superlazy-build-gate.sh` denies `Skill(subagent-driven-development|executing-plans)` without `plan-critic.passed` in the session run dir — unchanged, still fires (build still enters execution via that Skill call) | hook |
| Tier on every task | `pre-taskcreate-model-tier` blocks fence-less/tier-less plan tasks | hook |
| Dispatch models | `pre-agent-model-routing` validates tiered dispatches; custom agent types (the drafter) are exempt by that hook's own rule | hook |

Corrected claim from rev 1: the gate hook does **not** cover Seams 1–2 in the
brainstorm flow (brainstorm never invokes `writing-plans`, so that arm never
fires). Seam ordering is enforced by the critic script instead, and the gate
hook's real contribution is the execution boundary. No new hooks are added.

## Plan resolution — how build classifies its argument

Deterministic, artifact-driven; invocation phrasing is irrelevant.

```
build <arg>
  ├─ no path, or no X.md.tasks.json  ──► BRIEF ──► brainstorm --continue ──► execute
  └─ X.md.tasks.json exists          ──► PLAN (brainstorm is never called)
        ├─ codex-critic.sh verify OK ──► markers minted ──► execute
        └─ exit 3 (stale/missing/legacy)
              ├─ spec locatable (sidecar specPath or --spec) ──► one plan-critic pass
              │     ├─ clean ──► fresh markers + sidecar ──► execute
              │     └─ findings ──► surface, do not execute
              └─ spec not locatable ──► STOP: report that re-bless needs the spec;
                    offer --spec <path> or a fresh brainstorm. Never guess.
```

## Plan visualization — `plan-viz.mjs` (deterministic semantics)

Pure Node module (no deps), same shape as `review-synth.mjs`. Input: plan path +
tasks path. Task metadata source of truth: each task description's
`json:metadata` fence (`files[]`, `modelTier`, `verifyCommand`,
`acceptanceCriteria[]`); a task with no parseable fence is itself a flagged
problem. Output: one self-contained HTML file (inline CSS/JS, no external
assets). Also `--json` flag emitting the computed stats + problems for tests.

Pinned semantics:
- **Waves:** Kahn topological layering over `blockedBy`. Wave 1 = tasks with no
  unresolved blockers; wave N = tasks whose blockers all sit in waves < N.
- **Unknown `blockedBy` id:** flagged problem; the edge is ignored for layering
  (task still renders, marked).
- **Cycle:** tasks left over after Kahn's = flagged problem, rendered in an
  "unschedulable" group, excluded from wave numbering.
- **Frontier-heavy:** flagged when frontier tasks > 30% of total tasks. One
  number, deterministic, testable.
- **Same-wave file overlap:** paths normalized (trim, backslashes → `/`, strip
  leading `./`, collapse duplicate `/`), then exact string comparison,
  case-sensitive. No symlink/realpath resolution — plans use repo-relative paths.
- **Missing verify/criteria:** `verifyCommand` absent or blank; or
  `acceptanceCriteria` absent or empty array.

## Error handling — all paths fail safe

| Condition | Behavior |
|---|---|
| Stale/missing/legacy sidecar, `tasks.json` present | One plan-critic re-bless — never brainstorm |
| Spec missing during re-bless | Stop with instructions (`--spec` or brainstorm); never execute unreviewed |
| No `tasks.json` | Treat as brief → brainstorm |
| Commit drift | Warn only |
| `NEEDS-HUMAN` / non-clean verdict | Nothing written → cannot advance |
| Drafter returns malformed content | Coordinator rejects, re-dispatches |
| Sol never converges in brainstorm | No sidecar → user stops; later build re-critiques |
| Artifact publish unavailable/denied | Local HTML path printed; publish is best-effort |

## Environment (verified live)

Active upstream plugin: **6.2.2-dev** (updated during this design). Tier→model
routing AND the per-tier effort map are both delivered by its session notice
(effort advisory: `mechanical: low, standard: medium, frontier: inherit`, labeled
user-set from our routing file). The three harness gates are present, registered,
and armed by `docs/superpowers/model-routing.json` (committed). Kill switch:
`SUPERPOWERS_ROUTING_GUARD=0`. The drafter agent may additionally pin effort in
its frontmatter as a determinism boost. `subagent-driven-development` is
byte-identical between 6.0.3 and 6.2.2 (verified), so the execution stage we
wrap is unchanged by the upstream update; `writing-plans`' new grep-count
self-check and ≤60-char subject rule are adopted in the drafter's output format.

## Components

**New**
- `superlazy-cc/skills/superlazy-brainstorm/SKILL.md`
- `superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.mjs` + `plan-viz.test.mjs`
- `superlazy-cc/agents/superlazy-drafter.md` — `model: fable`, tools: Read, Grep,
  Glob, WebSearch, context7 (NO Write/Edit/Bash)

**Modified**
- `superlazy-cc/scripts/codex-critic.sh` — capture (drop `exec`), parse, marker
  writing, sidecar writing, `verify` mode
- `superlazy-cc/skills/superlazy-build/SKILL.md` — plan resolution, verify/re-bless
  paths, brainstorm delegation, OVERRIDE prose removal
- `superlazy-cc/skills/superlazy-review/SKILL.md` — explicit model passing, opus default
- `superlazy-cc/agents/superlazy-review-critic.md` — `model: opus`
- `superlazy-cc/agents/superlazy-refute-critic.md` — `model: opus`
- `superlazy-cc/agents/superlazy-plan-critic.md` — tier-assignment audit dimension
- `superlazy-cc/skills/superlazy-review/lib/review-synth.mjs` — `'sonnet'` → `'opus'`
- `superlazy-cc/.claude-plugin/plugin.json` — `1.6.0` + description
- `README.md` — three-command structure

## Testing — pre-publication acceptance matrix

Everything below runs in the working tree, before any plugin publish. The Codex
CLI is **stubbed for script tests**: a fake `codex` executable prepended to
`PATH` that prints a canned VERDICT block (clean / one-Important / NEEDS-HUMAN
variants), so marker logic is exercised without the API.

`codex-critic.sh` (stubbed):
1. clean verdict + `MARKER_DIR` → `spec-critic.passed` written
2. verdict with 1 Important → nothing written
3. `NEEDS-HUMAN` → nothing written
4. `plan` mode, clean, **without** `spec-critic.passed` → no plan marker, no sidecar, stderr warning
5. `plan` mode, clean, with spec marker → plan marker then sidecar, correct
   `planHash`/`specPath`/`specHash`/`commit`
6. no `MARKER_DIR` → stdout byte-identical to today's behavior; `review` mode untouched
7. `verify`: valid sidecar → both markers, exit 0, `VERIFIED`
8. `verify`: flipped plan byte → exit 3, nothing written
9. `verify`: flipped spec byte / missing spec / legacy sidecar without `specPath` → exit 3
10. `verify`: commit drift only → exit 0 + stderr warning

`plan-viz.test.mjs` (node:test, pure):
fixtures for every detector — same-wave overlap, unknown `blockedBy`, cycle,
frontier-heavy (31% flags, 30% does not), missing verify/criteria, missing
fence — asserted via `--json` output; plus wave-layering correctness.

Static wiring (grep, matching repo precedent):
- drafter frontmatter has `model: fable` and no Write/Edit in tools
- both review agents have `model: opus`; SKILL contains the always-pass-model
  instruction; `review-synth.mjs` contains `'opus'` fallback
- build SKILL contains: `verify`, re-bless branch, `--spec`, brainstorm
  delegation, announce lines; OVERRIDE prose absent
- brainstorm SKILL contains: run-dir init, seam loops, sidecar path, plan-viz
  invocation, print-and-stop ending, `--continue`

End-to-end (the only post-publish, environment-dependent step): publish 1.6.0 →
`superlazy-brainstorm` on a toy feature → confirm triplet + HTML + hard stop →
`superlazy-build <plan>` → confirm verify-skip → execution → Seam 3. Artifact
publish observed but not required for pass.

## Non-goals (YAGNI)

- No defense against a malicious same-OS user; no cryptographic signing (threat
  model: drift, not malice).
- No re-approval shortcut that bypasses Sol: any byte change Sol did not bless
  re-triggers the plan-critic. The only bypass is build's loud `--skip-critics`.
- No new hooks. Script-side ordering + the existing execution gate suffice.
- No parallel-draft-then-merge for Fable/Sol; Fable authors, Sol red-teams.
- plan-viz renders and flags; it does not block anything.

## Deployment

Working-tree edits do not affect the running plugin until commit → push →
plugin update. Libs, the routing file, the critic script (stubbed), and all grep
assertions are exercised in the working tree; only the final e2e requires a
published 1.6.0.
