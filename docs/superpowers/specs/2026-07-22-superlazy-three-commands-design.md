# superlazy-cc — three-command restructure — design spec

Date: 2026-07-22 (rev 7 — canonical-source binding after spec-critic round 6 `targeted-fixes`, 1 Critical)
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
- The execution stage is blocked by the session-bound gate hook unless
  `plan-critic.passed` exists in the session's run dir — and, for hash-bearing
  markers, unless the plan, tasks, AND spec bytes still match what was approved.
- Every task in an approved plan carries a valid `modelTier` — enforced by the
  deterministic `.tasks.json` schema validation `plan` mode runs before writing
  any approval (the upstream `pre-taskcreate-model-tier` harness gate also
  exists but fails open by design, so it is defense-in-depth, not the guarantee).

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
   **Preflight:** if `CLAUDE_CODE_SUBAGENT_MODEL` is set to anything other than
   `fable`, STOP and tell the user — that env var outranks both per-dispatch
   and frontmatter model settings (per the Claude Code subagent contract), so
   the Fable-authorship guarantee cannot hold under it. The guarantee is
   explicitly scoped: *absent that override*, drafting runs on Fable.
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
   6.2.x requirement). The plan markdown MUST begin with a
   `Spec: <repo-root-relative path>` reference line (part of the drafter's
   output template) — this is the spec resolver's fallback when no sidecar
   exists. The coordinator writes `<plan>.md` and `<plan>.md.tasks.json` —
   **no native tasks are created** (the execution stage owns task creation and
   extracts them from the gate-validated files when build later runs).
6. **Seam 2:** coordinator runs `codex-critic.sh plan` (marker mode with
   `PLAN_PATH`/`SPEC_PATH`). On a clean verdict, **and** only if the
   `spec-critic.passed` marker exists AND its recorded `specHash` still matches
   the current spec bytes (edit-between-seams rejection), the script writes the
   approval sidecar and then `plan-critic.passed` (marker last — ordering
   below). If the user directs a *spec-level* change during this loop, the next
   `spec` run's self-invalidation clears both markers and the loop correctly
   returns to Seam 1.
   **Native tasks are NEVER created by brainstorm or build.** The execution
   stage (`subagent-driven-development`) is the single creation owner — its own
   skill begins by extracting tasks from the plan and creating them. Since the
   gate validates the plan/tasks bytes immediately before `Skill(sdd)` is
   allowed, sdd extracts from exactly the approved bytes; a second creator
   would only produce duplicates. (The upstream `pre-taskcreate-model-tier`
   gate fires on sdd's creations as fail-open defense-in-depth; the schema
   guarantee came from `plan` mode.) The plan-critic prompt includes
   the **tier-assignment audit**: `frontier` where steps are complete = wasted
   money; `mechanical` where steps require judgment = silent quality loss;
   tie-break is spec completeness. Loop until the sidecar exists.
7. Coordinator generates the HTML review page with `plan-viz.mjs` → writes it
   next to the plan (`<plan>.md.html`) and prints its path. That local
   self-contained file IS the deliverable. (Non-normative: a coordinator MAY
   additionally publish it via the Artifact tool when that capability happens to
   be available; nothing in this design requires, tests, or depends on it.)
8. Ends by **printing** the paths (spec, plan, tasks, sidecar, HTML) and stops.
   Standalone, the hard stop also **closes the run**: `touch
   .superlazy-build/<run-id>/.done`. The run dir's job is done — approval
   travels in the sidecar, and closing prevents the cross-session mutex from
   false-BUSYing a later `build <plan>` in another session (see Run lifecycle).
   Under `--continue` the run stays active for build to keep using in-session.
   Ending-by-print (never `AskUserQuestion`) is a design rule of this command —
   the upstream handoff guard may not be armed in this flow (it arms on a
   `writing-plans` signal we never emit), so no enforcement is claimed for it.

Internal `--continue` flag: suppresses the hard stop; used only when
`superlazy-build` invokes brainstorm for its no-plan path.

### 2. `superlazy-build [plan]` (MODIFY existing)

- **With a plan** (arg resolves to `X.md` with an `X.md.tasks.json` sibling): run
  `codex-critic.sh verify X.md`. On success both seam markers are minted in the
  run dir → skip Steps 1–4 straight to execution. On failure (exit 3) run the
  **auto re-bless** composition (see Plan resolution): `verify --spec-only` to
  carry forward the spec approval when the spec is unchanged, then one
  `codex-critic.sh plan` pass; if the spec changed too, the spec seam re-runs
  first (two Sol calls, still no Fable). Never brainstorm when `tasks.json`
  exists. Build creates **no native tasks of any kind** — the execution stage
  (sdd) is the single task-creation owner. This REMOVES current build's
  Step 0.5 ("Create three native seam-gate tasks", `SKILL.md:85-86`): the
  marker files are the seam state, and tracker tasks would make build a second
  task owner. Neither brainstorm nor build contains a `TaskCreate` call at all.
- **Without a plan** (no path, or path without `.tasks.json`): invoke
  `superlazy-brainstorm --continue`, then execute without stopping.
- Build **announces the branch it took** in one line ("Approved plan verified —
  skipping to execution" / "Sidecar stale — re-blessing via plan-critic" / "No
  task plan found — brainstorming first").
- Step 1's invocation of `superpowers-extended-cc:brainstorming` is replaced by
  `superlazy-brainstorm --continue`, deleting the OVERRIDE prose at current
  `SKILL.md:90` and `SKILL.md:109`.
- **The sdd invocation names the approved plan.** When build invokes
  `Skill(subagent-driven-development)`, the invocation args MUST contain the
  canonical plan path — the gate compares it to the marker's `planPath` and
  denies on absence or mismatch (approved-A/executed-B protection).
- **Seam 3** (`codex-critic.sh code`) always runs (except under `--skip-critics`).
  sdd's per-task Claude reviewers are kept (different layer, `standard` tier).
- **`--skip-critics` — the one loud bypass, fully specified.** Announce
  prominently, then: do NOT create a run dir (the execution gate hook is then
  dormant by its own no-active-run rule); with no plan, invoke
  `superlazy-brainstorm --continue --skip-critics`, which still gathers
  requirements and still authors via the Fable drafter but skips Seams 1–2
  entirely — plan + tasks are written, **no markers and no sidecar** (nothing
  was approved, so nothing claims to be); Seam 3 is also skipped. With a plan,
  skip `verify`/re-bless and execute as-is. Consequence, stated on announce: the
  resulting plan carries no approval, so any *later* non-skip build of it takes
  the re-bless path — skipping critics defers review, it cannot fake it.
- `--serial` unchanged.

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

**Markers are hash-bearing JSON, not bare touch-files.** Same filenames as
today (the gate's `-f` check keeps working), but the content records what was
approved:
- `spec-critic.passed` = `{"specPath": "...", "specHash": "<sha256>"}`
- `plan-critic.passed` = `{"planPath": "...", "planHash": "<sha256>", "tasksHash": "<sha256>", "specPath": "...", "specHash": "<sha256>"}`
  (spec fields copied from the validated spec marker at approval time — the
  plan approval names the whole approved set, spec included)
- `code-critic.passed` = `{}` (nothing downstream consumes it)
An approval is always bound to the exact bytes it approved; existence alone
proves nothing to any consumer that can read the content.

**Strict parsing, narrow legacy.** A marker that is an EMPTY file (zero bytes
or whitespace-only) is the legacy representation: existence-only semantics,
allowed for compatibility with runs made by older versions. Any NON-empty
marker MUST parse as JSON with all required fields — corrupt JSON, missing
fields, or unknown shapes are treated as NO marker (deny), never downgraded to
existence-only. Corruption cannot buy authorization.

**Seam modes pin Sol.** For `spec`/`plan`/`code` the model is hard-pinned to
`gpt-5.6-sol` — `CODEX_CRITIC_MODEL` is **ignored** for these modes (an
inherited environment variable must not silently move the seams to another
model; "Sol is the only critic" is a brief requirement, not a default).
`review`/`refute` keep the env override — `superlazy-review`'s `--codex-model`
flag depends on it. The test stub asserts the `-m` argument it receives.

**Effort policy (wall-clock control).** A high-effort Sol round runs 5–9
minutes; looping at all-high makes brainstorm too slow. Policy: each seam's
FIRST pass runs at `high` (the broad adversarial sweep), re-review rounds run
at `medium` (the what-changed note narrows the question). The coordinator sets
`CODEX_CRITIC_EFFORT` per dispatch accordingly. An explicitly exported
`CODEX_CRITIC_EFFORT` in the user's environment overrides the policy in BOTH
directions (always-medium for speed, always-high for depth). Live web search
stays on — the highest-value findings (platform-doc contract checks) come from
it, including on re-review rounds.

Critic modes (`spec`/`plan`/`code`):
- Inputs: crafted context on stdin (unchanged). Env: `MARKER_DIR` (opt-in; absent
  → behave exactly as today), `SPEC_PATH` for `spec` mode (the file whose bytes
  are being reviewed — recorded in the marker on pass), and `PLAN_PATH` +
  `SPEC_PATH` for `plan` mode (paths stored repo-root-relative via
  `git rev-parse --show-toplevel`).
- **Self-invalidation first.** With `MARKER_DIR` set, each critic mode BEGINS by
  deleting its own marker and everything downstream of it — `spec`: removes
  `spec-critic.passed`, `plan-critic.passed`, and the sidecar (if `PLAN_PATH` is
  known); `plan`: removes `plan-critic.passed` and the sidecar; `code`: removes
  `code-critic.passed`. A revised artifact therefore can never inherit a stale
  pass, and the brainstorm loop's "until the marker exists" condition is safe:
  every loop iteration re-runs the critic, and the marker present after a run is
  always the product of *that* run.
- The script **captures** Codex output (no `exec`), prints it to stdout verbatim,
  then parses it: VERDICT = first `^VERDICT:` line; Critical = count of
  `^- \[Critical\]`; Important = count of `^- \[Important\]`.
- **Clean** = the VERDICT token is exactly `pass` **AND** Critical == 0 AND
  Important == 0. Any other token (`targeted-fixes`, `rewrite`, `NEEDS-HUMAN`,
  garbled, missing) is not clean regardless of counts — the pass token and the
  zero counts are independent requirements and both are asserted (a malformed
  findings list can zero the counts; it cannot forge the token).
- `plan` mode, on clean, additionally: (a) requires `spec-critic.passed` to
  exist in `$MARKER_DIR` **with `specHash` matching the sha256 of the current
  `SPEC_PATH` bytes** — a bare/legacy marker or a hash mismatch means the spec
  on disk is not the spec Seam 1 approved (edit-between-seams), so nothing is
  written and the mismatch is reported on stderr (the re-bless path supplies a
  valid marker via `verify --spec-only`, below); (b) **validates the task
  schema on the CANONICAL TaskCreate source — the plan MARKDOWN** (upstream
  sdd extracts and creates tasks from the plan doc; `.tasks.json` is its
  persistence mirror, written later): every task block in `PLAN_PATH` parses,
  carries a `json:metadata` fence with `modelTier` ∈ {mechanical, standard,
  frontier}, a `files` array, a non-blank `verifyCommand`, and non-empty
  `acceptanceCriteria`; (c) **validates plan/tasks equivalence**: task count
  equal AND each `.tasks.json` task's fence byte-equal to its plan-doc
  counterpart — equal-count-but-divergent artifacts are a violation. Any
  (b)/(c) violation = not clean, nothing written, violations on stderr. (This
  makes the tier guarantee real for the artifact sdd actually consumes; the
  upstream harness gate is only defense-in-depth, see Enforcement chain.)
- Write order on clean `plan`: **sidecar first, `plan-critic.passed` last**
  (each temp-file + `mv -f` rename). The marker is what authorizes execution
  in-session (the gate hook checks it), so it is the final commit; an
  interruption between the two leaves a genuine-but-unusable sidecar and a
  blocked execution — never the reverse.
- On non-clean or unparseable output: print verbatim, write nothing (the
  self-invalidation at start has already cleared any stale approval).
  Wrapper-level failures (no codex CLI, no prompt file) keep today's behavior:
  `VERDICT: NEEDS-HUMAN` on stdout, exit 2 — after self-invalidation.

`verify <plan.md>` (non-LLM, no Codex call):
- **Self-invalidates first**, like the critic modes: deletes both seam markers
  from `$MARKER_DIR` before validating, so a failed verification can never
  leave a previously-seeded approval standing in a reused run dir.
- Derives `tasks = <plan.md>.tasks.json`, `sidecar = <plan.md>.approved.json`.
- Checks: sidecar exists and parses; `planHash` = sha256 of the plan bytes;
  `tasksHash` = sha256 of the tasks bytes (hashed **separately** — no
  concatenation, so no boundary-shifting ambiguity); `specPath` exists;
  `specHash` matches its bytes. Any missing file, missing field, parse error, or
  hash mismatch → **exit 3**, reason on stderr, nothing further written
  (legacy/foreign sidecars lacking fields are stale by definition).
- On success: writes hash-bearing `spec-critic.passed` and `plan-critic.passed`
  (content derived from the validated sidecar) into `$MARKER_DIR` (temp +
  rename), prints `VERIFIED`, exit 0. Sidecar `commit` != `git rev-parse HEAD`:
  stderr warning, still exit 0 (drift warns, never blocks).
- **`verify --spec-only <plan.md>`** — the partial mode that makes re-bless
  possible: deletes the spec marker, then validates ONLY `specPath` + `specHash`
  against the existing sidecar (ignoring the plan/tasks hashes, which are
  known-stale). On match it mints the hash-bearing `spec-critic.passed` alone —
  carrying the *spec's* approval forward from the old sidecar because the spec
  bytes are provably the ones Sol approved — exit 0. No sidecar, or spec
  missing/changed → exit 3, nothing further written.
- These modes exist so the fast path needs **no LLM call** while marker-writing
  stays inside the one trusted script.

## Approval sidecar (rev 2)

`<plan>.md.approved.json`, written **only** by `codex-critic.sh` on a clean
`plan` verdict with the spec seam already passed:

```json
{
  "planHash":  "<sha256 hex of plan.md bytes>",
  "tasksHash": "<sha256 hex of tasks.json bytes>",
  "specPath":  "<repo-root-relative path to the spec doc>",
  "specHash":  "<sha256 hex of the spec bytes>",
  "commit":    "<git rev-parse HEAD at approval>",
  "seams":     ["spec", "plan"]
}
```

Each file is hashed independently (no concatenation), so a byte moved across the
plan/tasks boundary cannot preserve the digest.

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
| No stale approvals | critic modes self-invalidate (delete own marker + downstream) before every run | script |
| Spec seam passed | `spec-critic.passed` written by script only on `VERDICT: pass` + zero counts | script |
| Plan seam passed, in order | sidecar then plan marker, written only when clean AND spec marker exists; marker last = execution authorized last | script |
| Tier on every task | deterministic `.tasks.json` schema validation in `plan` mode — no valid `modelTier` on every task, no approval | script |
| Cross-session approval | `verify` mode validates sidecar, mints session markers; `--spec-only` carries spec approval into re-bless | script |
| Execution start | `superlazy-build-gate.sh` (ours — **modified**) denies `Skill(subagent-driven-development|executing-plans)` without `plan-critic.passed` in the session run dir; when the marker is JSON it (a) recomputes `planHash`/`tasksHash`/`specHash` against the files it names and denies on any mismatch, and (b) requires the Skill invocation's `tool_input` (args/prompt text) to CONTAIN the marker's `planPath` — an invocation that names a different plan, or none, is denied ("execution must name the approved plan"). A marker for plan A can therefore never authorize sdd consuming plan B. EMPTY markers: existence-only (legacy, no path binding). Non-empty malformed: **deny** | hook |
| Tier/dispatch harness gates | `pre-taskcreate-model-tier` and `pre-agent-model-routing` are **defense-in-depth only** — by design they fail open (ad-hoc tasks without a fence allowed, malformed fence JSON allowed, concrete `model` pins exempt, several routing states allow). The tier *guarantee* lives in the script validation above, not in these hooks. | hook (fail-open) |

Corrected claim from rev 1: the gate hook does **not** cover Seams 1–2 in the
brainstorm flow (brainstorm never invokes `writing-plans`, so that arm never
fires). Seam ordering is enforced by the critic script instead, and the gate
hook's real contribution is the execution boundary — now strengthened with
marker-hash validation. No NEW hooks are added; the one existing gate (part of
this plugin) is modified.

## Run-directory lifecycle

The gate hook binds to the most-recent non-`.done` run dir owned by the current
session, and the mutex BUSYs on a foreign session's active dir. The commands
therefore manage runs as:

| Flow | Run dir | At end |
|---|---|---|
| `superlazy-brainstorm` (standalone) | creates `<slug>` (mutex-checked as today) | **`.done` at the hard stop** — its job ends with the sidecar written; leaving it active would false-BUSY a later session's build |
| `superlazy-brainstorm --continue` | creates `<slug>` | left **active**; build keeps using it in-session (markers present, gate armed), `.done` at build's finish as today |
| `superlazy-build <plan>` | mutex scans the **whole slug family** (`<plan-slug>` and every `<plan-slug>-N`): any family member ACTIVE and owned by a foreign session → **BUSY, stop** (a `.done` base must not let allocation sidestep a foreign `-2`); a family member active and owned by THIS session → rebind and reuse it. Only then allocate the first **genuinely absent** name in the family. `.done` dirs are never reused, cleared, or rebound — historical records the gate ignores | `verify`/re-bless mint markers into it; `.done` at finish |

Same slug, brainstorm-today/build-tomorrow, different sessions: brainstorm's
dir is `.done` (ignored by gate and mutex), build allocates fresh, `verify`
re-mints from the sidecar. No false-BUSY, no ungated window.

## Plan resolution — how build classifies its argument

Deterministic, artifact-driven; invocation phrasing is irrelevant.

```
build <arg>
  ├─ no path, or no X.md.tasks.json  ──► BRIEF ──► brainstorm --continue ──► execute
  └─ X.md.tasks.json exists          ──► PLAN (brainstorm is never called)
        ├─ codex-critic.sh verify OK ──► both markers minted ──► execute
        └─ exit 3 (stale/missing/legacy) ──► RE-BLESS:
              ├─ verify --spec-only OK   (sidecar exists, spec unchanged)
              │     ──► spec marker minted from the old approval
              │     ──► codex-critic.sh plan (one Sol call)
              │           ├─ clean ──► sidecar + plan marker ──► execute
              │           └─ findings ──► surface, do not execute
              ├─ verify --spec-only fails, spec locatable (resolver below)
              │     ──► spec changed too (or no prior approval to carry forward):
              │         codex-critic.sh spec, then codex-critic.sh plan (two Sol
              │         calls — still no Fable, no interactive brainstorm)
              └─ spec not locatable ──► STOP: report that re-bless needs the spec;
                    offer --spec <path> or a fresh brainstorm. Never guess.
```

**Spec resolver** (deterministic order, first hit wins):
1. the sidecar's `specPath` (when a sidecar exists);
2. the plan doc's mandatory `Spec:` reference line (survives sidecar deletion —
   this is why the drafter template requires it);
3. an explicit `--spec <path>` argument;
4. none of the above → STOP.

The re-bless composition is why `plan` mode's spec-marker precondition is
satisfiable in a fresh session: `verify --spec-only` supplies the spec marker
when the spec bytes are provably the previously-approved ones; otherwise the
spec seam genuinely re-runs. A re-bless never costs more than two Sol calls and
never drops to Fable or the interactive flow.

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
| Stale/missing/legacy sidecar, `tasks.json` present | Re-bless: spec-only verify + one plan-critic call — never brainstorm |
| Spec changed since approval | Spec seam re-runs, then plan seam (two Sol calls, no Fable) |
| Spec missing during re-bless | Stop with instructions (`--spec` or brainstorm); never execute unreviewed |
| No `tasks.json` | Treat as brief → brainstorm |
| Commit drift | Warn only |
| `NEEDS-HUMAN` / non-pass verdict / schema violation | Self-invalidation already cleared stale approvals; nothing new written → cannot advance |
| Interrupted between sidecar and marker writes | Sidecar exists, marker absent → in-session execution stays blocked; a fresh `verify` re-validates and mints cleanly |
| Drafter returns malformed content | Coordinator rejects, re-dispatches |
| Sol never converges in brainstorm | No sidecar → user stops; later build re-critiques |
| Artifact publish unavailable/denied | Local HTML path printed; publish is best-effort |

## Environment (verified live)

Active upstream plugin: **6.2.2-dev** (updated during this design). Tier→model
routing AND the per-tier effort map are both delivered by its session notice
(effort advisory: `mechanical: low, standard: medium, frontier: inherit`, labeled
user-set from our routing file). The three harness gates are installed and
**enabled** by `docs/superpowers/model-routing.json` (committed) — but enabled
≠ flow-armed: only the tier gate (`pre-taskcreate-model-tier`, fires on sdd's
TaskCreate calls) and the dispatch gate (`pre-agent-model-routing`) actually
participate in these flows. The handoff guard (`pre-askuser-handoff-guard`)
arms on a `writing-plans` signal followed by TaskCreate, which brainstorm never
emits — it stays dormant here, which is why brainstorm's ending-by-print is a
design rule, not an enforced one. Kill switch: `SUPERPOWERS_ROUTING_GUARD=0`. The drafter agent may additionally pin effort in
its frontmatter as a determinism boost. `subagent-driven-development` is
byte-identical between 6.0.3 and 6.2.2 (verified), so the execution stage we
wrap is unchanged by the upstream update; `writing-plans`' new grep-count
self-check and ≤60-char subject rule are adopted in the drafter's output format.

## Components

**New**
- `superlazy-cc/skills/superlazy-brainstorm/SKILL.md`
- `superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.mjs` + `plan-viz.test.mjs`
- `superlazy-cc/agents/superlazy-drafter.md` — `model: fable`, tools: `Read`,
  `Grep`, `Glob`, `WebSearch`, `mcp__context7__resolve-library-id`,
  `mcp__context7__query-docs` (exact MCP tool names — a bare `context7` entry
  is not a valid tools-list pattern and would grant nothing; NO Write/Edit/Bash)

**Modified**
- `superlazy-cc/scripts/codex-critic.sh` — capture (drop `exec`), strict pass-token
  parse, self-invalidation, hash-bearing JSON markers, spec-marker matching in
  `plan` mode, tasks-schema validation, seam-mode model pinning,
  sidecar-then-marker writing, `verify` + `verify --spec-only` modes
- `superlazy-cc/hooks/superlazy-build-gate.sh` — validate hash-bearing plan
  markers (recompute plan/tasks/spec hashes + compare, AND require the Skill
  invocation text to contain the marker's `planPath`) before allowing
  execution; EMPTY markers keep existence-only legacy behavior; non-empty
  malformed markers deny
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
1. `VERDICT: pass`, zero counts, `MARKER_DIR` → `spec-critic.passed` written
2. `VERDICT: pass` but 1 Important line → nothing written
3. every non-pass token → nothing written: `targeted-fixes` (zero counts),
   `rewrite` (zero counts), `NEEDS-HUMAN`, missing VERDICT line, garbled token
4. **self-invalidation**: pre-seed a stale `spec-critic.passed`, run `spec` mode
   with a failing verdict → the stale marker is GONE afterward; same for `plan`
   (stale plan marker + sidecar cleared; spec marker untouched)
5. `plan` mode, clean, **without** `spec-critic.passed` → nothing written, stderr warning
6. `plan` mode, clean, with spec marker → sidecar written BEFORE plan marker
   (ordering observable via the stub pausing between writes or mtime), correct
   separate `planHash`/`tasksHash` + `specPath`/`specHash`/`commit`
7. `plan` mode, clean verdict but a plan-doc task with missing `modelTier` /
   blank `verifyCommand` / empty `acceptanceCriteria` → not clean, nothing
   written, violation on stderr (schema runs on the plan MARKDOWN — the
   canonical TaskCreate source)
7b. `plan` mode, clean verdict, plan doc valid but `.tasks.json` diverges
   (same task count, one fence differs) → not clean, nothing written
   (equivalence check)
8. no `MARKER_DIR` → stdout byte-identical to today's behavior; `review`/`refute`
   modes untouched
9. **edit-between-seams rejection**: `spec` mode passes (marker carries
   `specHash`), spec file is then edited, stubbed clean `plan` run → nothing
   written, mismatch on stderr
10. markers are hash-bearing JSON: after case 1/6, marker contents parse and
    carry the correct hashes/paths
11. seam-mode model pin: stub asserts `-m gpt-5.6-sol` for `spec`/`plan`/`code`
    even with `CODEX_CRITIC_MODEL=other` exported; `review` mode still honors
    the env var
12. `verify`: valid sidecar → both hash-bearing markers, exit 0, `VERIFIED`
13. `verify`: flipped plan byte / flipped tasks byte (independently) → exit 3;
    **pre-seeded stale markers are gone afterward** (verify self-invalidation)
14. `verify`: flipped spec byte / missing spec / legacy sidecar without `specPath` → exit 3
15. `verify`: commit drift only → exit 0 + stderr warning
16. `verify --spec-only`: spec unchanged vs sidecar → only `spec-critic.passed`
    written, exit 0; spec changed or no sidecar → exit 3 and a pre-seeded spec
    marker is gone
17. re-bless composition (script-level): stale sidecar → `verify` exit 3 →
    `verify --spec-only` exit 0 → stubbed clean `plan` → fresh sidecar + both markers present

`superlazy-build-gate.sh` (direct invocation with crafted stdin, like the
existing hook tests):
18. hash-bearing plan marker, files intact → allow
19. one plan byte / one tasks byte / **one spec byte** flipped after approval
    (each independently) → deny
20. EMPTY legacy marker → allow (existence-only compat, no path binding)
21. non-empty corrupt-JSON marker / JSON missing a required field → **deny**
    (no downgrade)
22. hash-bearing marker for plan A, Skill invocation naming plan B (or naming
    no plan at all) → **deny** (approved-A/executed-B)

`plan-viz.test.mjs` (node:test, pure):
fixtures for every detector — same-wave overlap, unknown `blockedBy`, cycle,
frontier-heavy (31% flags, 30% does not), missing verify/criteria, missing
fence — asserted via `--json` output; plus wave-layering correctness.

Static wiring (grep, matching repo precedent):
- drafter frontmatter has `model: fable` and no Write/Edit in tools
- both review agents have `model: opus`; SKILL contains the always-pass-model
  instruction; `review-synth.mjs` contains `'opus'` fallback
- build SKILL contains: `verify`, re-bless branch, `--spec`, brainstorm
  delegation, announce lines; OVERRIDE prose absent; **no `TaskCreate`**
  (seam-tracker task creation removed — single-owner check covers BOTH new
  SKILLs)
- brainstorm SKILL contains: run-dir init, the `CLAUDE_CODE_SUBAGENT_MODEL`
  preflight, seam loops, sidecar path, plan-viz invocation, print-and-stop
  ending, `.done` at standalone stop, `--continue` — and NO `TaskCreate`
  (execution owns task creation); drafter template contains the `Spec:`
  reference line and the exact `mcp__context7__*` tool names

End-to-end (post-publish; the coordinator-level branches that greps cannot
prove). One toy feature, then walk every deterministic plan-resolution branch:
1. `superlazy-brainstorm` → triplet + HTML + hard stop (no execution occurred)
2. `superlazy-build <plan>` untouched → announce "verified", no Sol call before
   execution, Seam 3 runs
3. edit one plan byte → build → announce "re-blessing", exactly one Sol plan
   call, fresh sidecar, executes
4. delete the sidecar → build → re-bless path: spec located via the plan doc's
   `Spec:` line (resolver step 2), spec seam re-runs (no sidecar for
   `--spec-only` to validate against), then plan seam, executes
4b. brainstorm standalone in session A (`.done` written) → `build <plan>` in a
   NEW session → no mutex BUSY, fresh run dir allocated, verify fast path works
4c. base slug `.done` + a foreign-session ACTIVE `<slug>-2` → build → **BUSY,
   stop** (slug-family scan; allocation must not sidestep to `<slug>-3`)
4d. after execution completes: native task count == task count in the approved
   `.tasks.json` (single-owner proof — no duplicates from brainstorm/build)
5. `superlazy-build` with a brief (no plan) → brainstorm runs inline, no hard
   stop, executes
6. `superlazy-build --skip-critics` with a plan → executes with no run dir, no
   Sol calls, and the plan still has no forged approval afterward
Artifact publish observed but not required for pass. The non-pass critic loop is
exercised by the stubbed tests (case 3/4), not e2e — forcing a real Sol failure
deterministically is not reliable and is not attempted.

## Non-goals (YAGNI)

- No defense against a malicious same-OS user; no cryptographic signing (threat
  model: drift, not malice).
- No re-approval shortcut that bypasses Sol: any byte change Sol did not bless
  re-triggers the plan-critic. The only bypass is build's loud `--skip-critics`.
- No NEW hooks. Script-side ordering + the existing execution gate (modified to
  validate hash-bearing markers) suffice.
- No parallel-draft-then-merge for Fable/Sol; Fable authors, Sol red-teams.
- plan-viz renders and flags; it does not block anything.

## Deployment

Working-tree edits do not affect the running plugin until commit → push →
plugin update. Libs, the routing file, the critic script (stubbed), and all grep
assertions are exercised in the working tree; only the final e2e requires a
published 1.6.0.
