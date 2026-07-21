# superlazy-cc — three-command restructure — design spec

Date: 2026-07-22
Status: approved (design), pending implementation plan
Repo: `Sultan1993/lazypowers` (plugin `superlazy-cc`), version `1.5.0` → `1.6.0`

## Purpose

Restructure `superlazy-cc` into three standalone commands with a clean division of
labour between models, moving control-flow enforcement out of fragile SKILL prose
and into hooks, tool restrictions, and enforcement-backed artifacts.

- **Fable** authors the spec and plan (the frontier planner).
- **Sol** (Codex `gpt-5.6-sol`) is the *only* critic, gating all three seams.
- **Execution model is per-task**, decided by Fable and audited by Sol, routed via
  `docs/superpowers/model-routing.json` (mechanical/standard → Sonnet, frontier → Opus).
- **Opus + Sol** is the one fixed frontier pair, used only in review.

The guiding principle, borrowed from the upstream plugin's own lesson: *skill prose
is not enforcement.* Every guarantee in this design is backed by a hook, a tool
restriction, or an artifact whose existence can only be produced by the intended
actor — never by a "do NOT" instruction a loaded coordinator can skip.

## The three commands

### 1. `superlazy-brainstorm` (NEW, standalone)

Produces an approved, executable plan and stops.

Flow:
1. **Coordinator** gathers requirements interactively with the user (all questions
   upfront, before any Fable tokens are spent).
2. **Fable subagent** (`superlazy-drafter`, `model: fable`) drafts the design spec
   and returns it *as content*. The coordinator writes the spec file.
3. **Sol** runs spec-critic (`codex-critic.sh spec`). On a clean verdict the script
   writes `spec-critic.passed`. Loop until clean — **no user-override escape hatch**
   (deliberately unlike current build's "or the user says proceed").
4. **Fable subagent** drafts the plan + per-task metadata (including `modelTier`) and
   returns it as content. The coordinator writes the plan doc and creates the tasks.
5. **Sol** runs plan-critic (`codex-critic.sh plan`). On a clean verdict the script
   writes `plan-critic.passed` **and** the approval sidecar. The plan-critic prompt
   includes an explicit **tier-assignment audit** (below). Loop until clean.
6. Coordinator generates the HTML visualization (`plan-viz.mjs`) and publishes it via
   the Artifact tool.
7. **Ends by printing paths** (plan doc, HTML URL). **Never `AskUserQuestion`** — the
   `pre-askuser-handoff-guard` blocks any non-mandated question after tasks are
   created. **Hard stop.** The user reviews the HTML and calls build themselves.

Internal `--continue` flag: suppresses the hard stop. Used **only** when
`superlazy-build` invokes brainstorm for the no-plan path.

### 2. `superlazy-build [plan]` (MODIFY existing)

Executes a plan. Resolution is deterministic — driven by artifacts on disk, never by
parsing the phrasing of the invocation. See **Plan resolution** below.

- **With a plan** (arg points at `X.md` that has an `X.md.tasks.json` sibling): verify
  the sidecar; on match, mint the seam markers and skip Steps 1–4 straight to
  execution. On a stale/missing sidecar, auto re-bless via a single plan-critic pass.
- **Without a plan** (no path, or a path with no `.tasks.json`): invoke
  `superlazy-brainstorm --continue`, then execute **without stopping**.
- Step 1's invocation of `superpowers-extended-cc:brainstorming` is replaced with
  `superlazy-brainstorm`. This **deletes the OVERRIDE prose** at current `SKILL.md:90`
  and `SKILL.md:109` — brainstorm now ends where build needs it to.
- **Seam 3 (code-critic, Sol) always runs.** sdd's per-task Claude reviewers are
  **kept** (a different layer — per-task, inside execution, at `standard` tier).

### 3. `superlazy-review` (MODIFY existing)

- Flip default `--claude-model` from `sonnet` to `opus` (reverses commit `86d5485`):
  update the `meta.json` default and the `review-synth.mjs` fallback string.
- Stays standalone and advisory. Still works on arbitrary targets (a branch or PR the
  user did not build). This is the one command with a fixed model pair (Opus + Sol).

## Architecture: who does what

| Actor | Role | How it is constrained |
|---|---|---|
| Coordinator (session model) | Interactive Q&A, writes files, `TaskCreate`, runs the critic script, publishes HTML | Ordinary session; does only mechanical work |
| `superlazy-drafter` (Fable) | Authors spec + plan + tier assignments | Subagent, `model: fable`, **no Write/Edit tools** — cannot materialize files, must return content |
| Sol (`codex-critic.sh`) | Critic at all three seams; **sole writer** of pass markers and the approval sidecar | Read-only sandbox; writes markers/sidecar only on a clean parsed VERDICT |

**Why Fable via subagent, not session model.** Dispatching a `model: fable` subagent
makes "Fable authors the plan" a *guarantee* independent of which model the user's
session runs. The drafter's lack of write tools makes the authoring split
structural: it physically cannot write files, so it must hand content back for the
coordinator to materialize. Enforcement over convention.

**Why the drafter is exempt from the routing gate.** `pre-agent-model-routing`
exempts any dispatch whose `subagent_type` is a custom type (not `general-purpose`).
`superlazy-drafter` is a custom type, so dispatching it at `model: fable` — a value
absent from the routing map — is allowed. As a bonus, agent-definition frontmatter
can pin reasoning effort, recovering per-agent effort control that the active plugin
version (6.0.3-dev) otherwise ignores.

## Enforcement model — markers and sidecar

**Marker protocol.** `codex-critic.sh` (in `spec`/`plan`/`code` modes) parses its own
VERDICT block and writes `$MARKER_DIR/<mode>-critic.passed` **only** when
`Critical == 0 && Important == 0`. `NEEDS-HUMAN` never writes a marker regardless of
counts. Marker-writing is opt-in via a `MARKER_DIR` env/arg so the `review`/`refute`
JSON modes used by `superlazy-review` do not regress. Because the *critic* writes the
marker, the coordinator physically cannot advance on an overridden verdict.

**Approval sidecar.** `<plan>.md.approved.json` = `{hash, commit, seams:["spec","plan"]}`
where `hash = sha256(plan.md bytes ++ plan.md.tasks.json bytes)` and
`commit = git rev-parse HEAD` at approval time. **Written only by `codex-critic.sh`
on a clean `plan` verdict** — never by the coordinator. This makes "update the hash
without Sol" an unsupported operation by construction: a valid sidecar can only exist
as a product of Sol passing. It is binary — its existence means a clean pass, so it
carries no verdict detail or residual counts. Tamper-evident, not tamper-proof; the
real adversary is accidental drift, not malice, so no signing/crypto.

**Run directory.** Brainstorm and build share the existing `.superlazy-build/<run-id>/`
convention (already gitignored), so the existing `superlazy-build-gate.sh` hook
enforces Seam 1 and Seam 2 for brainstorm **with zero hook changes**. The gate denies
`writing-plans` without `spec-critic.passed` and execution without `plan-critic.passed`,
and allows freely when no run dir is bound to the session.

**Why the sidecar exists (session portability).** Markers are *session-bound* — the
gate hook only honors a run-dir whose `session` file matches the current session id.
So brainstorm's markers cannot authorize a build that runs later, in a different
session. The sidecar is the **portable** proof of Sol's approval: a build session
verifies the sidecar hash against the plan bytes and, on match, *mints fresh markers
in its own run-dir*. Markers gate within a session; the sidecar carries approval
across them.

## Plan resolution — how build classifies its argument

Deterministic, artifact-driven. The verb in the invocation ("implement", "run", "build")
is irrelevant; only the file it points at matters.

Plans exist as a triplet, written atomically by brainstorm:
```
X.md                 plan doc
X.md.tasks.json      tasks (writing-plans always emits this)
X.md.approved.json   approval sidecar (only on a clean Sol plan verdict)
```

The trust ladder:

```
build <arg>
  ├─ extract file path from arg
  ├─ no path, OR path has no  X.md.tasks.json  ──► BRIEF ──► brainstorm --continue (heavy)
  └─ path has  X.md.tasks.json  ──► it is a PLAN (brainstorm is never called)
        ├─ sidecar present AND hash matches   ──► mint markers ──► execute      (normal path)
        └─ sidecar missing OR hash mismatch   ──► ONE plan-critic pass (Sol re-bless)
              ├─ clean  ──► script writes fresh sidecar ──► execute
              └─ finds Critical/Important ──► surface, do not execute
   (commit != HEAD is a WARNING only, never blocks and never invalidates)
```

Key invariants:
- **`tasks.json` present ⇒ it is a plan ⇒ brainstorm is never invoked.** The heaviest
  fallback for an existing plan is a *single* plan-critic pass — never the spec seam,
  never Fable re-drafting, never the interactive Q&A.
- **Coordinator edits stay valid cheaply.** User asks the coordinator to fix a plan →
  bytes change → sidecar hash no longer matches → build auto re-blesses with one Sol
  plan-critic pass → executes. This is the "auto re-bless" decision. `commit` is
  stored separately from the hash so an unchanged plan on a moved repo warns instead
  of invalidating.
- Build **announces the branch it took** in one line (e.g. "Detected approved plan …
  skipping to execution" / "Sidecar stale — re-blessing via plan-critic" / "No task
  plan found — brainstorming first") so a wrong guess is caught immediately. No
  `AskUserQuestion` — build is not the interactive command.

## Plan visualization — `plan-viz.mjs`

Pure Node module, same pure/testable shape as the existing `review-synth.mjs`. Reads
`plan.md` + `plan.md.tasks.json`, emits **self-contained HTML** (inline CSS/JS only,
no external assets — CSP-safe for the Artifact tool). Published via the Artifact tool
for browser review.

Shows:
- **Header stats:** task count, wave count, tier distribution (a cost preview before
  any spend).
- **Dependency DAG:** waves and `blockedBy` edges.
- **Task cards:** goal, files, acceptance criteria, `verifyCommand`, tier.
- **Auto-flagged problems** (the part that beats reading markdown — it *finds* issues,
  it does not merely display):
  - two tasks in the same wave touching the same file (parallelism hazard),
  - a task missing `verifyCommand` or with empty acceptance criteria,
  - a frontier-heavy plan (plan smell by the plugin's own standard),
  - a `blockedBy` referencing a nonexistent task id.

The flagged-problem detectors are the valuable, testable core.

## Error handling — all paths fail safe

| Condition | Behavior |
|---|---|
| No sidecar / hash mismatch, but `tasks.json` present | One plan-critic re-bless — never refuse, never brainstorm |
| No `tasks.json` (or no path) | Treat arg as a brief → brainstorm |
| Commit drift (`commit != HEAD`) | **Warn only** |
| `NEEDS-HUMAN` from Sol | No marker/sidecar written → cannot advance; surface stderr and stop the seam |
| Drafter returns malformed content | Coordinator rejects and re-dispatches |
| Sol never converges in brainstorm | No marker, no sidecar → user stops; a later build re-critiques from the artifacts |

## Cross-cutting constraints (harness gates, armed by the routing file)

The routing file `docs/superpowers/model-routing.json` already exists and is verified
live, which **arms** three PreToolUse gates in the active plugin (6.0.3-dev):
- `pre-taskcreate-model-tier` — every plan task must carry a valid `modelTier` in its
  `json:metadata` fence or `TaskCreate` is blocked. This *forces* Fable to assign a
  tier to every task.
- `pre-agent-model-routing` — Agent dispatches are validated against the routing map;
  custom `subagent_type`s (like `superlazy-drafter`) are exempt.
- `pre-askuser-handoff-guard` — after tasks are created, the only permitted
  `AskUserQuestion` is the mandated two-option handoff; hence brainstorm ends by
  printing, not asking.
- Kill switch for all three: `SUPERPOWERS_ROUTING_GUARD=0`.

**Active-version caveat.** 6.0.3-dev is the loaded version; it honors tier→model
routing but **ignores the `effort` map** (no effort support). Subagents inherit
session effort there. The `effort` key is kept in the routing file as harmless,
forward-compatible config (6.2.2-dev reads it). Per-agent effort, where needed, is
pinned in the drafter's agent-definition frontmatter instead.

**Tier-assignment audit (plan-critic).** The plan-critic prompt gains an explicit
dimension: Sol checks Fable's `modelTier` calls. `frontier` where the steps are
complete = wasted money; `mechanical` where the steps require judgment they do not
capture = silent quality loss. Tie-break: spec completeness wins.

## Components

**New**
- `superlazy-cc/skills/superlazy-brainstorm/SKILL.md` — coordinator instructions
- `superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.mjs` — pure HTML generator
- `superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs` — `node:test` suite
- `superlazy-cc/agents/superlazy-drafter.md` — Fable drafter, `model: fable`, no write tools

**Modified**
- `superlazy-cc/scripts/codex-critic.sh` — write marker + sidecar on clean verdict (opt-in via `MARKER_DIR`)
- `superlazy-cc/skills/superlazy-build/SKILL.md` — plan resolution, skip path, re-bless, remove OVERRIDE prose
- `superlazy-cc/skills/superlazy-review/SKILL.md` — Opus default
- `superlazy-cc/skills/superlazy-review/lib/review-synth.mjs` — fallback `'sonnet'` → `'opus'`
- `superlazy-cc/agents/superlazy-plan-critic.md` — add tier-assignment audit dimension
- `superlazy-cc/.claude-plugin/plugin.json` — version `1.6.0`, description
- `README.md` — three-command structure

## Testing strategy — hybrid (static + unit, one e2e at the end)

Skills go live only after commit → push → plugin update (the plugin loads from a
versioned cache, `~/.claude/plugins/cache/lazypowers/superlazy-cc/<version>/`, not the
working tree). Libs and the routing file are testable directly.

- **`plan-viz.mjs`** — real `node:test` suite; the auto-flagged-problem detectors are
  the priority cases.
- **`codex-critic.sh`** — marker/sidecar-writing smoke test (clean verdict writes;
  `NEEDS-HUMAN` and non-zero counts do not).
- **SKILL.md tasks** — grep-based wiring assertions, matching this repo's existing
  `verifyCommand` precedent (e.g. presence of `superlazy-drafter`, `approved.json`,
  `MARKER_DIR`, `plan-viz.mjs`).
- **One real end-to-end run** after publishing 1.6.0, as a final user-gate task: run
  `superlazy-brainstorm` on a toy feature, confirm the triplet + HTML + hard stop, then
  `superlazy-build <plan>` and confirm the sidecar path skips to execution.

## Non-goals (YAGNI)

- No hand-edit accommodation beyond the single re-bless pass; no "re-approve without
  Sol" shortcut. Any change Sol did not bless re-triggers Sol.
- No cryptographic signing of the sidecar. Tamper-evident is sufficient.
- No reliance on the `effort` map under the active plugin version.
- No new gate hook — the existing seam gate is reused via the shared run-dir convention.
- No parallel-draft-then-merge for Fable/Sol; Fable authors, Sol red-teams.

## Deployment

Working-tree edits do not affect the running plugin until the plugin is updated
(commit → push to `github.com/Sultan1993/lazypowers` → update the plugin). Libs, the
routing file, and grep assertions are exercised in the working tree; only the final
end-to-end gate requires a published 1.6.0.
