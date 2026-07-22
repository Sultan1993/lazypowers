Spec: docs/superpowers/specs/2026-07-22-superlazy-three-commands-design.md

# superlazy-cc 1.6.0 — three-command restructure — implementation plan

**Goal:** Implement the approved spec: `superlazy-brainstorm` (new),
`superlazy-build` (plan input + verify/re-bless), `superlazy-review` (Opus
default), with hash-bearing approvals written only by `codex-critic.sh`.

**Architecture:** coordinator-driven skills (no Workflow tool — its sandbox
cannot run Codex); one bash wrapper (`codex-critic.sh`) is the sole
approval-writer; one PreToolUse hook gates execution; pure-node lib for the
plan visualization. **Tech stack:** bash + jq + python3 (fence parsing),
node:test, no new dependencies. **User decisions honored:** Sol is the only
critic; Fable authors via subagent; no user-override in brainstorm; effort
policy high-first/medium-re-review. **Execution:** each task is executed by an
agentic worker at its `modelTier`, commits its own scoped change, and runs its
Verify command before completion.

**Test policy:** every wave-1 task ships its own runnable check (stub-based
shell tests or `node:test`); no task's tests depend on a sibling's files. The
integration task at the end runs everything plus the static grep matrix.
Tests live in `superlazy-cc/tests/`. The Codex CLI is stubbed via a fake
`codex` on PATH — no live Sol calls in tests.

**Cross-task contracts (pinned; wave tasks write blind):**
- Marker JSON: `spec-critic.passed` = `{"specPath","specHash"}`;
  `plan-critic.passed` = `{"planPath","planHash","tasksHash","specPath","specHash"}`;
  `code-critic.passed` = `{}`. Hashes = `shasum -a 256`, hex, per-file (no
  concatenation). Paths repo-root-relative (`git rev-parse --show-toplevel`).
- Sidecar `<plan>.md.approved.json` =
  `{"planHash","tasksHash","specPath","specHash","commit","seams":["spec","plan"]}`.
- Marker semantics: EMPTY file = legacy existence-only; non-empty must parse
  with all fields else treated as ABSENT (deny).
- Script env: `MARKER_DIR` (opt-in markers), `SPEC_PATH` (spec mode + plan
  mode), `PLAN_PATH` (plan mode). Modes: `spec|plan|code|verify|review|refute`;
  `verify [--spec-only] <plan.md>`; exit 3 = validation failed.
- Clean = `^VERDICT: pass` token AND zero `^- \[Critical\]` AND zero
  `^- \[Important\]` lines.
- Seam modes pin `-m gpt-5.6-sol` (ignore `CODEX_CRITIC_MODEL`); review/refute
  honor it.
- plan-viz CLI: `node plan-viz.mjs <plan.md> [--json]`; HTML to
  `<plan.md>.html`; `--json` emits `{stats, waves, problems}` to stdout.

## Tasks

### Task 1: Fable drafter agent
**Goal:** `superlazy-cc/agents/superlazy-drafter.md` — Fable drafter subagent.
**Files:** Create `superlazy-cc/agents/superlazy-drafter.md`
**Steps:** Frontmatter: `name: superlazy-drafter`, `description` (drafts specs
and parallel-ready plans for superlazy-brainstorm; returns CONTENT, never
writes), `model: fable`, `tools: Read, Grep, Glob, WebSearch,
mcp__context7__resolve-library-id, mcp__context7__query-docs`. Body: you are
the DRAFTER — return the requested artifact as your final message (spec
markdown, or plan markdown + tasks array); plan output format: plan starts
with `Spec: <path>` line; every task block carries the four headers +
`json:metadata` fence with `files`, `modelTier` (mechanical|standard|frontier;
tie-break = spec completeness), non-blank `verifyCommand`, non-empty
`acceptanceCriteria`; subjects ≤ 60 chars; tasks file-disjoint, real
`blockedBy` only.
**Acceptance Criteria:**
- frontmatter has `model: fable`, no Write/Edit/Bash in tools, exact
  `mcp__context7__*` names
- body demands content-return, `Spec:` line, fence schema, ≤60-char subjects
**Verify:** `grep -q 'model: fable' superlazy-cc/agents/superlazy-drafter.md && ! grep -qE '^tools:.*(Write|Edit|Bash)' superlazy-cc/agents/superlazy-drafter.md && grep -q 'mcp__context7__resolve-library-id' superlazy-cc/agents/superlazy-drafter.md && grep -q 'Spec:' superlazy-cc/agents/superlazy-drafter.md`

```json:metadata
{"files": ["superlazy-cc/agents/superlazy-drafter.md"], "modelTier": "mechanical", "verifyCommand": "grep checks per Verify", "acceptanceCriteria": ["model: fable", "no write tools", "exact mcp tool names", "content-return + format contract in body"]}
```

### Task 2: codex-critic.sh — capture, markers, verify modes
**Goal:** Rewrite the wrapper per the interface contract; add stub-based tests.
**Files:** Modify `superlazy-cc/scripts/codex-critic.sh`; create
`superlazy-cc/tests/codex-critic.test.sh`, `superlazy-cc/tests/stubs/codex`
**Steps:** (0) TDD: write `tests/codex-critic.test.sh` cases FIRST against the
current script and run them — the marker/verify cases MUST fail (red) before
any script change; implement; re-run the same command until green. (1) review/refute remain BYTE-PERFECT pass-through via `exec` — no
capture (command substitution strips trailing newlines); regression test 8d
compares output bytes via `cmp` against a stub payload with no trailing
newline. Seam modes capture (they must parse after printing); trailing-newline
normalization there is acceptable because only the VERDICT lines are parsed. (2) Seam modes (`spec|plan|code`): pin
`-m gpt-5.6-sol`; self-invalidate first (spec → rm spec+plan markers + sidecar
if PLAN_PATH known; plan → rm plan marker + sidecar; code → rm code marker);
capture output (`out=$(codex ...)`), print verbatim; parse clean = pass token
+ zero counts; on clean+MARKER_DIR: spec writes `{specPath,specHash}` marker;
plan REQUIRES spec marker whose specHash matches current SPEC_PATH bytes, runs
schema validation on the PLAN MARKDOWN's task fences (canonical TaskCreate
source: modelTier valid, files array, verifyCommand non-blank,
acceptanceCriteria non-empty) PLUS plan/tasks equivalence (count equal, each
tasks.json fence byte-equal to its plan counterpart; violations → stderr, not
clean), then writes sidecar FIRST, plan marker LAST (mktemp same dir + mv -f). (3) `verify <plan>`: rm both markers; validate sidecar
planHash/tasksHash/specPath/specHash; ok → write both markers from sidecar,
`VERIFIED`, exit 0 (commit drift → stderr warn); fail → exit 3.
`--spec-only`: rm spec marker; validate spec fields only; mint spec marker or
exit 3. (4) Tests: PATH-prepend `tests/stubs/codex` (prints canned VERDICT from
`$CODEX_STUB_VERDICT` file, records argv to `$CODEX_STUB_ARGS`); implement
spec acceptance cases 1–17 incl. 7b divergence, model-pin (case 11), and
effort/search propagation (case 11b).
**Acceptance Criteria:**
- cases 1–17 of the spec's matrix pass via `bash superlazy-cc/tests/codex-critic.test.sh`
- review mode stdout unchanged; seam modes ignore `CODEX_CRITIC_MODEL`
**Verify:** `bash superlazy-cc/tests/codex-critic.test.sh`

```json:metadata
{"files": ["superlazy-cc/scripts/codex-critic.sh", "superlazy-cc/tests/codex-critic.test.sh", "superlazy-cc/tests/stubs/codex"], "modelTier": "standard", "verifyCommand": "bash superlazy-cc/tests/codex-critic.test.sh", "acceptanceCriteria": ["matrix cases 1-17 + 8d byte-identity pass", "self-invalidation", "strict pass-token clean", "sidecar-then-marker order", "verify + --spec-only", "model pin for seam modes"]}
```

### Task 3: gate hook — hash validation
**Goal:** `superlazy-build-gate.sh` validates hash-bearing plan markers.
**Files:** Modify `superlazy-cc/hooks/superlazy-build-gate.sh`; create
`superlazy-cc/tests/build-gate.test.sh`
**Steps:** TDD: write `tests/build-gate.test.sh` cases 18–22 FIRST and run them —
the hash/binding cases MUST fail against the unmodified hook (red); implement;
re-run until green. In the execution arm (`*subagent-driven-development*|*executing-plans*`):
after the `-f` check, read the marker; empty/whitespace-only → allow (legacy);
non-empty → must parse as JSON with planPath/planHash/tasksHash/specPath/specHash
(jq), else DENY "corrupt approval marker"; recompute sha256 of the three files
(paths relative to repo root; missing file → deny) and deny on any mismatch
with a message naming the changed file; ALSO parse the structured
`planPath=<path>` argument from tool_input (never substring search) with
CARDINALITY EXACTLY ONE — zero tokens deny, two-or-more tokens deny even if
one matches (duplicates are ambiguous); then canonicalize and require exact
equality vs marker planPath (approved-A/executed-B incl. filename-extension,
both-paths, and duplicate-token cases). Keep all other behavior identical.
Tests: crafted-stdin invocations (existing repo test pattern): spec cases
18–22 (intact→allow; plan/tasks/spec byte flip→deny each; empty legacy→allow;
corrupt JSON / missing field→deny; planPath= arg naming B / extending A's filename / missing / DUPLICATED (2+ tokens, even identical) → deny; exactly one exact-match token → allow).
**Acceptance Criteria:** cases 18–22 pass (incl. planPath invocation binding); writing-plans arm untouched
**Verify:** `bash superlazy-cc/tests/build-gate.test.sh`

```json:metadata
{"files": ["superlazy-cc/hooks/superlazy-build-gate.sh", "superlazy-cc/tests/build-gate.test.sh"], "modelTier": "standard", "verifyCommand": "bash superlazy-cc/tests/build-gate.test.sh", "acceptanceCriteria": ["hash recompute + deny on mismatch incl. spec", "invocation-path binding with cardinality exactly one", "empty marker legacy allow", "malformed marker deny", "cases 18-22 incl. duplicate-token denials pass"]}
```

### Task 4: plan-viz — generator + tests
**Goal:** Pure-node plan visualizer with deterministic detectors.
**Files:** Create `superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.mjs`,
`superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs`
**Steps:** TDD: write `plan-viz.test.mjs` fixtures FIRST; `node --test` MUST
fail with module-not-found (red); implement `plan-viz.mjs`; re-run until green.
Input plan.md + `<plan>.md.tasks.json`. Parse each task's
`json:metadata` fence from its description (missing/unparseable fence = problem
`no-metadata`). Detectors (exact spec semantics): Kahn wave layering over
blockedBy; unknown ref → problem `unknown-dep`, edge ignored; Kahn leftovers →
problem `cycle`, "unschedulable" group; frontier > 30% of tasks → problem
`frontier-heavy`; same-wave file overlap after normalization (trim, `\\`→`/`,
strip leading `./`, collapse `//`) → problem `file-overlap`; missing/blank
verifyCommand → `no-verify`; missing/empty acceptanceCriteria → `no-criteria`.
`--json` → `{stats:{tasks,waves,tiers:{...}}, waves:[[ids]], problems:[...]}`.
HTML: self-contained (inline CSS only, both themes via prefers-color-scheme +
data-theme), header stats, wave columns with task cards (goal excerpt, files,
tier chip, verify), problems panel; write to `<plan>.md.html`, print the path.
Tests (node:test): fixture-driven — one fixture per detector (incl. 31%-flags /
30%-doesn't boundary), wave-layering correctness, `--json` shape.
**Acceptance Criteria:** `node --test` green; zero deps; HTML self-contained
**Verify:** `node --test superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs`

```json:metadata
{"files": ["superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.mjs", "superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs"], "modelTier": "standard", "verifyCommand": "node --test superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs", "acceptanceCriteria": ["all detectors per pinned semantics", "Kahn waves + cycle handling", "--json test surface", "self-contained dual-theme HTML"]}
```

### Task 5: superlazy-review — Opus default
**Goal:** Flip the Claude side to Opus at every layer that matters.
**Files:** Modify `superlazy-cc/agents/superlazy-review-critic.md`,
`superlazy-cc/agents/superlazy-refute-critic.md`,
`superlazy-cc/skills/superlazy-review/SKILL.md`,
`superlazy-cc/skills/superlazy-review/lib/review-synth.mjs`
**Steps:** Both agent frontmatters `model: sonnet` → `model: opus`. SKILL:
every Agent dispatch passes `model: <--claude-model or opus>` explicitly
(never rely on frontmatter); meta.json default `claudeModel` → `"opus"`; flag
doc line updated. review-synth.mjs fallback `'sonnet'` → `'opus'`.
**Acceptance Criteria:** no `model: sonnet` left in the two agents; SKILL
always passes model; synth fallback opus; review-synth tests still green
**Verify:** `bash -c 'set -e; for f in superlazy-cc/agents/superlazy-review-critic.md superlazy-cc/agents/superlazy-refute-critic.md; do grep -q "^model: opus" "$f"; done; grep -q "claudeModel:<--claude-model or \"opus\">" superlazy-cc/skills/superlazy-review/SKILL.md; grep -qc "model: <--claude-model or opus>" superlazy-cc/skills/superlazy-review/SKILL.md; grep -q "meta.claudeModel || .opus." superlazy-cc/skills/superlazy-review/lib/review-synth.mjs; node --test superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs >/dev/null'`

```json:metadata
{"files": ["superlazy-cc/agents/superlazy-review-critic.md", "superlazy-cc/agents/superlazy-refute-critic.md", "superlazy-cc/skills/superlazy-review/SKILL.md", "superlazy-cc/skills/superlazy-review/lib/review-synth.mjs"], "modelTier": "mechanical", "verifyCommand": "greps + node --test review-synth.test.mjs", "acceptanceCriteria": ["frontmatters opus", "explicit model passing", "fallback opus", "existing tests green"]}
```

### Task 6: plan-critic — tier-assignment audit
**Goal:** Add the tier audit dimension to the plan critic prompt.
**Files:** Modify `superlazy-cc/agents/superlazy-plan-critic.md`
**Steps:** Add a "Tier-assignment audit" check: every task's `modelTier`
against its steps — `frontier` where steps are complete = wasted money
(Important); `mechanical` where steps require judgment not captured = silent
quality loss (Critical); tie-break = spec completeness wins; blanket
assignments in either direction are findings.
**Acceptance Criteria:** dimension present with both failure directions + tie-break
**Verify:** `grep -qi 'tier' superlazy-cc/agents/superlazy-plan-critic.md && grep -qi 'spec completeness' superlazy-cc/agents/superlazy-plan-critic.md`

```json:metadata
{"files": ["superlazy-cc/agents/superlazy-plan-critic.md"], "modelTier": "mechanical", "verifyCommand": "grep tier + spec completeness", "acceptanceCriteria": ["audit dimension with both directions and tie-break"]}
```

### Task 7: superlazy-brainstorm SKILL
**Goal:** Coordinator instructions for the new command.
**Files:** Create `superlazy-cc/skills/superlazy-brainstorm/SKILL.md`
**Steps:** Frontmatter (name, description incl. hard-stop semantics +
`--continue` + `--skip-critics`). Body per spec §1: announce; requirements
Q&A upfront; run-dir init (slug mutex family-scan rules, session binding,
gitignore) + `CLAUDE_CODE_SUBAGENT_MODEL` preflight; `--skip-critics` branch
(no run dir, Fable still drafts, no markers/sidecar, loud announce); resolve
`WRAP`; effort policy: first pass of each seam `CODEX_CRITIC_EFFORT=high`,
re-review rounds `medium`, user-exported value wins; drafter dispatch spec → coordinator
writes file → Seam 1 loop (`MARKER_DIR=<run> SPEC_PATH=<spec> "$WRAP" spec`,
loop until marker exists; findings → re-dispatch drafter with findings); plan
drafting (Spec: line, fence schema, ≤60 subjects) → coordinator writes plan +
tasks.json, NO TaskCreate → Seam 2 loop (`MARKER_DIR=<run> PLAN_PATH=<plan>
SPEC_PATH=<spec> "$WRAP" plan`); plan-viz generation + print path
(non-normative MAY publish via Artifact); end: print all paths; standalone →
`touch .done` + STOP (never AskUserQuestion); `--continue` → return control to
build, run left active. VERDICT parser section (pass token + counts;
NEEDS-HUMAN → surface stderr + stop).
**Acceptance Criteria:** all wiring greps below; no TaskCreate anywhere; no
AskUserQuestion at the end
**Verify:** `bash -c 'set -e; f=superlazy-cc/skills/superlazy-brainstorm/SKILL.md; for a in superlazy-drafter CLAUDE_CODE_SUBAGENT_MODEL MARKER_DIR SPEC_PATH PLAN_PATH plan-viz .done -- --continue --skip-critics Spec: CODEX_CRITIC_EFFORT; do [ "$a" = -- ] && continue; grep -q -- "$a" "$f"; done; ! grep -qE "TaskCreate:|invoke TaskCreate|call TaskCreate" "$f"; ! grep -q "AskUserQuestion" "$f" || grep -q "never.*AskUserQuestion\|Never ask" "$f"'`

```json:metadata
{"files": ["superlazy-cc/skills/superlazy-brainstorm/SKILL.md"], "modelTier": "standard", "verifyCommand": "wiring greps + zero TaskCreate", "acceptanceCriteria": ["preflight", "seam loops via MARKER_DIR", "hard stop + .done", "--continue + --skip-critics", "no TaskCreate/AskUserQuestion"]}
```

### Task 8: superlazy-build SKILL — plan input, verify, re-bless
**Goal:** Rewrite build around the trust ladder.
**Files:** Modify `superlazy-cc/skills/superlazy-build/SKILL.md`
**Steps:** Inputs: optional plan path, `--spec`, `--skip-critics`, `--serial`.
Plan resolution ladder per spec (tasks.json presence → PLAN; announce branch
taken). `--skip-critics` two-branch bypass, fully spelled: LOUD announce; NO
run dir created (gate dormant by its no-active-run rule); BRIEF branch →
invoke brainstorm with BOTH flags `--continue --skip-critics` (Fable still
authors; no markers, no sidecar); PLAN branch → skip verify AND re-bless
entirely; both branches skip Seam 3; state on announce that nothing is
approved so a later non-skip build re-critiques (bypass defers review, never
forges it). Run-dir (non-skip): slug-family mutex scan, first-absent
allocation, .done rules.
With plan: `MARKER_DIR=<run> "$WRAP" verify <plan>`; exit 3 → re-bless
(`verify --spec-only` → plan critic; spec changed → spec critic then plan
critic; spec resolver: sidecar → `Spec:` line → `--spec` → STOP). Without
plan: invoke Skill `superlazy-cc:superlazy-brainstorm` with `--continue`
(replaces Step 1 + old OVERRIDE prose at :90/:109 — DELETE both). REMOVE Step
0.5 seam-tracker TaskCreate. Keep Steps 5–7 (execution, Seam 3 via
`MARKER_DIR` so code marker writes, finish) intact including wave policy;
execution materializes nothing — sdd owns TaskCreate, and the sdd Skill
invocation MUST carry the structured `planPath=<repo-relative>` token (gate
parses + exact-matches it). Update VERDICT parser to
pass-token semantics. Effort policy: first pass per seam high, re-reviews
medium, user-exported `CODEX_CRITIC_EFFORT` wins.
**Acceptance Criteria:** greps below; OVERRIDE prose gone; no TaskCreate
**Verify:** `bash -c 'set -e; f=superlazy-cc/skills/superlazy-build/SKILL.md; for a in verify spec-only planPath= Spec: superlazy-brainstorm slug CODEX_CRITIC_EFFORT; do grep -q -- "$a" "$f"; done; grep -q -- "--continue --skip-critics" "$f"; grep -qE "create NO run dir|NO run dir created|no run dir" "$f"; grep -qiE "skip Seam 3|Seam 3 is also skipped|skip .*code.critic" "$f"; grep -qiE "nothing is approved|cannot fake|never forges" "$f"; ! grep -q OVERRIDE "$f"; ! grep -q "seam-gate tasks" "$f"; ! grep -qE "TaskCreate:|invoke TaskCreate|call TaskCreate" "$f"'`

```json:metadata
{"files": ["superlazy-cc/skills/superlazy-build/SKILL.md"], "modelTier": "standard", "verifyCommand": "wiring greps + OVERRIDE/tracker absence", "acceptanceCriteria": ["trust ladder + announce", "verify/re-bless wiring", "brainstorm delegation with --continue --skip-critics propagation", "two-branch bypass: no run dir, no critic calls, no forged approval", "no OVERRIDE prose", "no TaskCreate", "run lifecycle rules"]}
```

### Task 9: integration — version, README, full matrix
**Goal:** Ship-ready branch: metadata + docs + everything green.
**Files:** Modify `superlazy-cc/.claude-plugin/plugin.json`, `README.md`
**Steps:** plugin.json → `"version": "1.6.0"`, description mentions the three
commands. README: three-command structure, quick-start per command, approval
sidecar explanation, model table (Fable/Sol/sonnet/opus), escape valves.
Then run EVERYTHING — the barrier re-executes every prior task's own Verify
command verbatim (Tasks 1–8), then the four suites. The full static matrix is
therefore the UNION of the per-task Verify commands, not a summary of them.
**Acceptance Criteria:** all suites green; version 1.6.0; README covers three commands
**Verify:** the literal ordered barrier command:

```bash
( grep -q 'model: fable' superlazy-cc/agents/superlazy-drafter.md && ! grep -qE '^tools:.*(Write|Edit|Bash)' superlazy-cc/agents/superlazy-drafter.md && grep -q 'mcp__context7__resolve-library-id' superlazy-cc/agents/superlazy-drafter.md && grep -q 'Spec:' superlazy-cc/agents/superlazy-drafter.md ) && \
( bash superlazy-cc/tests/codex-critic.test.sh ) && \
( bash superlazy-cc/tests/build-gate.test.sh ) && \
( node --test superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs ) && \
( bash -c 'set -e; for f in superlazy-cc/agents/superlazy-review-critic.md superlazy-cc/agents/superlazy-refute-critic.md; do grep -q "^model: opus" "$f"; done; grep -q "claudeModel:<--claude-model or \"opus\">" superlazy-cc/skills/superlazy-review/SKILL.md; grep -qc "model: <--claude-model or opus>" superlazy-cc/skills/superlazy-review/SKILL.md; grep -q "meta.claudeModel || .opus." superlazy-cc/skills/superlazy-review/lib/review-synth.mjs; node --test superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs >/dev/null' ) && \
( grep -qi 'tier' superlazy-cc/agents/superlazy-plan-critic.md && grep -qi 'spec completeness' superlazy-cc/agents/superlazy-plan-critic.md ) && \
( bash -c 'set -e; f=superlazy-cc/skills/superlazy-brainstorm/SKILL.md; for a in superlazy-drafter CLAUDE_CODE_SUBAGENT_MODEL MARKER_DIR SPEC_PATH PLAN_PATH plan-viz .done -- --continue --skip-critics Spec: CODEX_CRITIC_EFFORT; do [ "$a" = -- ] && continue; grep -q -- "$a" "$f"; done; ! grep -qE "TaskCreate:|invoke TaskCreate|call TaskCreate" "$f"; ! grep -q "AskUserQuestion" "$f" || grep -q "never.*AskUserQuestion\|Never ask" "$f"' ) && \
( bash -c 'set -e; f=superlazy-cc/skills/superlazy-build/SKILL.md; for a in verify spec-only planPath= Spec: superlazy-brainstorm slug CODEX_CRITIC_EFFORT; do grep -q -- "$a" "$f"; done; grep -q -- "--continue --skip-critics" "$f"; grep -qE "create NO run dir|NO run dir created|no run dir" "$f"; grep -qiE "skip Seam 3|Seam 3 is also skipped|skip .*code.critic" "$f"; grep -qiE "nothing is approved|cannot fake|never forges" "$f"; ! grep -q OVERRIDE "$f"; ! grep -q "seam-gate tasks" "$f"; ! grep -qE "TaskCreate:|invoke TaskCreate|call TaskCreate" "$f"' ) && \
( bash superlazy-cc/tests/codex-critic.test.sh >/dev/null ) && \
( bash superlazy-cc/tests/build-gate.test.sh >/dev/null ) && \
( node --test superlazy-cc/skills/superlazy-brainstorm/lib/plan-viz.test.mjs superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs >/dev/null ) && \
( grep -q '"version": "1.6.0"' superlazy-cc/.claude-plugin/plugin.json ) && \
( grep -q superlazy-brainstorm README.md ) && echo BARRIER-GREEN
```

```json:metadata
{"files": ["superlazy-cc/.claude-plugin/plugin.json", "README.md"], "modelTier": "standard", "verifyCommand": "the literal ordered barrier command in this task's Verify block (Tasks 1-8 verifies chained, then the four suites, then version/README greps; prints BARRIER-GREEN)", "acceptanceCriteria": ["1.6.0", "README three commands", "all suites green", "Tasks 1-8 Verify commands re-executed at the barrier"], "blockedBy": [1, 2, 3, 4, 5, 6, 7, 8]}
```

## Waves
- Wave 1 (parallel, file-disjoint): T1–T8 — every cross-task name they
  reference (script env/modes, marker filenames, plan-viz CLI, planPath=
  token) is pinned in the contracts header, so they write blind.
- Wave 2 (barrier): T9 — integration, full matrix, version, README.

## Commit policy (I3, partial)
Each task commits its own scoped change (`git add <task files> && git commit`)
after its Verify command passes. Tests are written alongside the code they
verify (test files are listed in each task's Files); red/green detail beyond
that is deliberately not restated here — the Verify commands are the
executable acceptance layer.

## Out of scope (post-plan, user-gated)
Push, plugin publish, and the 7-branch e2e run — they require the published
1.6.0 plugin and the user's session.
