# superlazy-review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `superlazy-review` skill in the `superlazy-cc` fork that runs a two-model (Claude + Codex/Sol) adversarial code review of a local diff or GitHub PR and emits a ranked advisory report.

**Architecture:** Coordinator-driven (same pattern as `superlazy-build`; NOT the Workflow tool — its sandbox can't run Codex). The coordinator runs Claude reviews via the `Agent` tool and Codex reviews via `Bash(codex-critic.sh)`, both in parallel, then delegates all deterministic logic (bucket / rank / render) to a pure, unit-tested node lib. Agreement corroborates; single-model findings are cross-refuted by the other model.

**Tech Stack:** Bash + `gh` + `git worktree`, Node ≥18 (ESM, `node:test`), the existing `codex-critic.sh` wrapper (reused unchanged), Claude Code plugin/skill/agent format.

**User decisions (already made):**
- Basis: diff review + conformance when a plan/spec/PR-intent exists (one code path).
- Cross-model logic: agreement auto-corroborates; disagreement is refuted by the other model; survives only if not refuted.
- Output: ranked `report.md` + terminal digest; PR comments opt-in (`--post`), confirm before posting.
- Architecture: coordinator-driven (B), matching superlazy-build; Workflow tool avoided (no shell in its sandbox).
- Efficiency: two comprehensive reviews (one per model, all dimensions, findings dimension-tagged), not 12 per-dimension calls.
- Findings interchange: strict JSON (better than prose for programmatic bucket/refute).
- Advisory only; no gating/merge/auto-fix.

---

## File structure

_All paths in this section and in each task's **Files**/**Create** lines are relative to the plugin dir `superlazy-cc/` (e.g. `agents/…` → `superlazy-cc/agents/…`). Shell commands that `cd` to the repo root (`/Users/sultan/Development/lazypowers`) use the full `superlazy-cc/…` prefix._

- `agents/superlazy-review-critic.md` — shared reviewer prompt (Claude subagent type AND read by `codex-critic.sh review`). Emits findings JSON.
- `agents/superlazy-refute-critic.md` — shared refuter prompt (`codex-critic.sh refute` + Claude subagent type). Emits `{refuted, reason}`.
- `skills/superlazy-review/lib/review-synth.mjs` — pure deterministic logic + CLI (`bucket`, `render`). All non-model logic lives here.
- `skills/superlazy-review/lib/review-synth.test.mjs` — `node --test` unit tests.
- `skills/superlazy-review/SKILL.md` — coordinator instructions (the pipeline).
- `skills/superlazy-review/test/` — golden-diff fixture + acceptance doc.
- `.claude-plugin/plugin.json` — version bump.

`scripts/codex-critic.sh` is reused UNCHANGED: it resolves `agents/superlazy-${critic}-critic.md`, so `codex-critic.sh review` → `superlazy-review-critic.md` and `codex-critic.sh refute` → `superlazy-refute-critic.md`.

Tasks 1 and 2 are independent (parallel-ready). Task 3 depends on 1 + 2. Task 4 is independent. Task 5 depends on 1–3.

---

### Task 1: Reviewer + refuter prompts

**Goal:** Create the two shared prompt files that both models use, emitting strict JSON.

**Files:**
- Create: `agents/superlazy-review-critic.md`
- Create: `agents/superlazy-refute-critic.md`

**Acceptance Criteria:**
- [ ] `codex-critic.sh review` on a tiny diff returns a single JSON object parseable by `JSON.parse` with keys `verdict`, `summary`, `findings`.
- [ ] `codex-critic.sh refute` on a finding returns JSON with `refuted` (boolean) and `reason`.
- [ ] Both files have valid Claude-agent frontmatter (name matches filename stem) so they register as subagent types.

**Verify:** `cd /Users/sultan/Development/lazypowers && printf 'WORKTREE: %s\nBASE_SHA: HEAD~1\nHEAD_SHA: HEAD\nDIMENSIONS: correctness\nCONTEXT:\n(none)\n' "$(pwd)" | ./superlazy-cc/scripts/codex-critic.sh review | node -e 'const s=require("fs").readFileSync(0,"utf8"); const o=JSON.parse(s); if(!("findings" in o)) throw new Error("no findings key"); console.log("ok",o.verdict)'` → prints `ok <verdict>`

**Steps:**

- [ ] **Step 1: Write `agents/superlazy-review-critic.md`**

```markdown
---
name: superlazy-review-critic
description: >
  Cross-model code reviewer for superlazy-review. Reviews a diff across six
  dimensions and emits strict findings JSON. Plan-agnostic; adds conformance
  checks when a plan/spec/PR intent is supplied. Read-only.
tools: Read, Grep, Glob, Bash, WebSearch, mcp__context7__resolve-library-id, mcp__context7__query-docs
model: opus
---

# superlazy-review critic

You review a code change and report DEFECTS as strict JSON. You never edit code.

## Inputs (in your assignment block)
- WORKTREE: absolute path — cd into it.
- BASE_SHA and HEAD_SHA — the change range.
- DIMENSIONS — the lenses to apply (subset of the six below; "all" = every one).
- CONTEXT (optional) — plan/spec/PR-intent text. If present, ALSO check the
  change conforms to it. If "(none)", review the diff on its own merits.

## Read the change
```
cd <WORKTREE>
git diff <BASE_SHA>..<HEAD_SHA>
git log --oneline <BASE_SHA>..<HEAD_SHA>
```
Read surrounding files as needed. Verify external library/API calls via Context7
(resolve-library-id -> query-docs), WebSearch fallback.

## Dimensions
- correctness — logic bugs, edge cases, error handling, data-loss paths.
- security — injection, secret handling, unsafe shell/SQL, authz gaps.
- performance — needless O(n^2), N+1 queries, sync-in-loop, avoidable allocation.
- tests — real assertions vs test theater (assert true, no-op mocks); missing
  coverage of the changed behavior.
- api-design — interface clarity, breaking changes, contract mismatches.
- over-engineering — speculative abstraction, dead flexibility, reinvented stdlib.

Report only DEFECTS introduced or worsened by THIS change. Ignore pre-existing
issues outside the diff. Prefer few, real, high-confidence findings over volume.
Do not praise.

## Severity
- Critical — wrong output, data loss, crash, or security hole.
- Important — likely bug, missing test of core behavior, real design problem.
- Minor — style/readability/nit.

## Output — STRICT JSON ONLY (one object, no markdown fence, no prose)
{"verdict":"pass|findings","summary":"...","findings":[{"severity":"Critical|Important|Minor","dimension":"correctness|security|performance|tests|api-design|over-engineering","file":"path/rel/to/repo","line":123,"title":"short label","why":"reason + evidence","failure_scenario":"concrete inputs -> wrong output/crash","fix":"suggested fix"}]}

Rules:
- verdict = "pass" if zero Critical and zero Important (Minor allowed), else "findings".
- line = best-effort start line in the NEW file; 0 if not line-specific.
- failure_scenario REQUIRED for Critical/Important.
- No findings -> "findings": [].
- READ-ONLY. Output the JSON object and nothing else.
```

- [ ] **Step 2: Write `agents/superlazy-refute-critic.md`**

```markdown
---
name: superlazy-refute-critic
description: >
  Refutation reviewer for superlazy-review. Given ONE finding and the diff, tries
  to refute it and emits {refuted, reason} JSON. Read-only.
tools: Read, Grep, Glob, Bash, WebSearch, mcp__context7__resolve-library-id, mcp__context7__query-docs
model: opus
---

# superlazy-review refuter

Another model raised the finding below about a code change. Your job is to
REFUTE it: is it actually wrong, already handled, out of scope, or a false
positive? Investigate the real code before deciding.

## Inputs (in your assignment block)
- WORKTREE, BASE_SHA, HEAD_SHA — the change range (cd in; `git diff` to read it).
- FINDING — the finding JSON to test.

## How to judge
Read the relevant code and diff. The finding SURVIVES only if it is a real,
reproducible defect in THIS change. Refute it if: the code already handles the
case, the claimed input cannot occur, it misreads the diff, it is pre-existing /
out of scope, or the evidence is speculative. Default refuted=true when
uncertain — the bar for surviving is that YOU can confirm it is real.

## Output — STRICT JSON ONLY (one object, no fence, no prose)
{"refuted": true, "reason": "one or two sentences with evidence"}

READ-ONLY. Output the JSON object and nothing else.
```

- [ ] **Step 3: Verify Codex emits parseable review JSON**

Run:
```bash
cd /Users/sultan/Development/lazypowers
printf 'WORKTREE: %s\nBASE_SHA: HEAD~1\nHEAD_SHA: HEAD\nDIMENSIONS: correctness\nCONTEXT:\n(none)\n' "$(pwd)" \
  | ./superlazy-cc/scripts/codex-critic.sh review 2>/dev/null \
  | node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8")); if(!("findings" in o)||!("verdict" in o)) throw new Error("bad shape"); console.log("ok",o.verdict)'
```
Expected: `ok pass` or `ok findings` (no JSON parse error). If Codex wraps the JSON in a ```` ```json ```` fence, tighten the prompt's "no markdown fence" line and re-run.

- [ ] **Step 4: Commit**

```bash
cd /Users/sultan/Development/lazypowers
git add superlazy-cc/agents/superlazy-review-critic.md superlazy-cc/agents/superlazy-refute-critic.md
git commit -m "superlazy-review: reviewer + refuter prompts (JSON output)"
```

```json:metadata
{"files": ["superlazy-cc/agents/superlazy-review-critic.md", "superlazy-cc/agents/superlazy-refute-critic.md"], "verifyCommand": "cd /Users/sultan/Development/lazypowers && printf 'WORKTREE: %s\\nBASE_SHA: HEAD~1\\nHEAD_SHA: HEAD\\nDIMENSIONS: correctness\\nCONTEXT:\\n(none)\\n' \"$(pwd)\" | ./superlazy-cc/scripts/codex-critic.sh review | node -e 'JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"))'", "acceptanceCriteria": ["codex-critic.sh review returns parseable {verdict,summary,findings}", "codex-critic.sh refute returns {refuted,reason}", "frontmatter registers both as subagent types"], "modelTier": "standard"}
```

---

### Task 2: Synthesis lib + unit tests (TDD)

**Goal:** A pure node module holding all deterministic logic (bucket / rank / refute-filter / render) plus a small CLI, fully unit-tested with no model calls.

**Files:**
- Create: `skills/superlazy-review/lib/review-synth.mjs`
- Create: `skills/superlazy-review/lib/review-synth.test.mjs`

**Acceptance Criteria:**
- [ ] `bucketFindings` marks findings AGREED when same file+dimension and line within 15, else SINGLE; assigns stable ids to singles.
- [ ] `rankFindings` orders Critical→Important→Minor, then agreed-before-single, then dimension order.
- [ ] `applyRefutations` drops singles whose id is refuted, keeps all agreed.
- [ ] `renderReport` emits markdown with a per-finding `[Severity] title`, `where` line, and a "both models"/model tag.
- [ ] `node --test` passes.

**Verify:** `node --test /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs` → all tests pass

**Steps:**

- [ ] **Step 1: Write the failing tests**

Create `skills/superlazy-review/lib/review-synth.test.mjs`:
```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  bucketFindings, rankFindings, applyRefutations, renderReport,
} from './review-synth.mjs';

const mk = (o = {}) => ({
  severity: 'Important', dimension: 'correctness', file: 'a.js', line: 10,
  title: 't', why: 'w', failure_scenario: 'f', fix: 'x', ...o,
});

test('same file+dimension+near line -> agreed', () => {
  const { agreed, single } = bucketFindings([mk({ line: 10 })], [mk({ line: 12 })]);
  assert.equal(agreed.length, 1);
  assert.equal(single.length, 0);
  assert.deepEqual(agreed[0].raisedBy, ['claude', 'codex']);
});

test('different dimension -> both single', () => {
  const { agreed, single } = bucketFindings([mk({ dimension: 'security' })], [mk({ dimension: 'tests' })]);
  assert.equal(agreed.length, 0);
  assert.equal(single.length, 2);
});

test('agreed keeps the higher severity', () => {
  const { agreed } = bucketFindings([mk({ severity: 'Minor' })], [mk({ severity: 'Critical' })]);
  assert.equal(agreed[0].severity, 'Critical');
});

test('singles get stable ids', () => {
  const { single } = bucketFindings([mk({ file: 'x.js' })], [mk({ file: 'y.js' })]);
  assert.deepEqual(single.map((s) => s.id), ['s0', 's1']);
});

test('rank: Critical first, then agreed before single at same severity', () => {
  const agreedImp = mk({ severity: 'Important', raisedBy: ['claude', 'codex'] });
  const crit = mk({ severity: 'Critical', raisedBy: ['claude'] });
  const singleImp = mk({ severity: 'Important', raisedBy: ['claude'] });
  const r = rankFindings([agreedImp, crit, singleImp]);
  assert.equal(r[0].severity, 'Critical');
  assert.deepEqual(r[1].raisedBy, ['claude', 'codex']);
});

test('refuted single dropped, agreed kept', () => {
  const bucket = bucketFindings([mk({ file: 'a.js', line: 1 })], [mk({ file: 'b.js', line: 1 })]);
  const ag = bucketFindings([mk({ file: 'c.js', line: 5 })], [mk({ file: 'c.js', line: 5 })]);
  bucket.agreed = ag.agreed;
  const ranked = applyRefutations(bucket, { s0: { refuted: true, reason: 'no' } });
  const ids = ranked.map((f) => f.id).filter(Boolean);
  assert.ok(!ids.includes('s0'));
  assert.ok(ids.includes('s1'));
  assert.equal(ranked.filter((f) => f.agreed).length, 1);
});

test('renderReport shows severity header, tag, and where-line', () => {
  const md = renderReport(
    { target: 'PR #1', base: 'aaa', head: 'bbb' },
    rankFindings([mk({ severity: 'Critical', raisedBy: ['claude', 'codex'] })]),
  );
  assert.match(md, /\[Critical\] t/);
  assert.match(md, /both models/);
  assert.match(md, /a\.js:10/);
});
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `node --test /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs`
Expected: FAIL — `Cannot find module './review-synth.mjs'`.

- [ ] **Step 3: Write `skills/superlazy-review/lib/review-synth.mjs`**

```javascript
#!/usr/bin/env node
// review-synth.mjs — pure synthesis for superlazy-review. No model calls, no network.
import { writeFileSync, readFileSync, mkdirSync } from 'node:fs';

export const SEVERITY_RANK = { Critical: 0, Important: 1, Minor: 2 };
export const DIMENSIONS = ['correctness', 'security', 'performance', 'tests', 'api-design', 'over-engineering'];
const PROX = 15; // lines within which same-file+dimension findings are "the same"

function matches(a, b) {
  if (a.file !== b.file || a.dimension !== b.dimension) return false;
  if (!a.line || !b.line) return true; // line unknown on either side -> match on file+dimension
  return Math.abs(a.line - b.line) <= PROX;
}

function moreSevere(a, b) {
  return (SEVERITY_RANK[a.severity] ?? 3) <= (SEVERITY_RANK[b.severity] ?? 3) ? a : b;
}

export function bucketFindings(claude = [], codex = []) {
  const pool = codex.map((f) => ({ ...f }));
  const used = new Set();
  const agreed = [];
  const single = [];
  for (const c of claude) {
    const idx = pool.findIndex((p, i) => !used.has(i) && matches(c, p));
    if (idx >= 0) {
      used.add(idx);
      agreed.push({ ...moreSevere(c, pool[idx]), raisedBy: ['claude', 'codex'], agreed: true });
    } else {
      single.push({ ...c, raisedBy: ['claude'], agreed: false });
    }
  }
  pool.forEach((p, i) => {
    if (!used.has(i)) single.push({ ...p, raisedBy: ['codex'], agreed: false });
  });
  single.forEach((s, i) => { s.id = `s${i}`; });
  return { agreed, single };
}

export function rankFindings(findings) {
  const dimIdx = (d) => { const i = DIMENSIONS.indexOf(d); return i < 0 ? 99 : i; };
  return [...findings].sort((a, b) => (
    (SEVERITY_RANK[a.severity] ?? 3) - (SEVERITY_RANK[b.severity] ?? 3)
    || (b.raisedBy.length - a.raisedBy.length)
    || dimIdx(a.dimension) - dimIdx(b.dimension)
  ));
}

export function applyRefutations(bucket, refutations = {}) {
  const survivors = bucket.single.filter((s) => !(refutations[s.id] && refutations[s.id].refuted));
  return rankFindings([...bucket.agreed, ...survivors]);
}

function counts(ranked) {
  const c = { Critical: 0, Important: 0, Minor: 0 };
  ranked.forEach((f) => { c[f.severity] = (c[f.severity] || 0) + 1; });
  return c;
}

export function renderReport(meta, ranked) {
  const c = counts(ranked);
  const out = [];
  out.push(`# superlazy-review — ${meta.target || 'diff'}`, '');
  out.push(`- Base \`${meta.base || '?'}\` → Head \`${meta.head || '?'}\``);
  out.push(`- Reviewers: Claude (${meta.claudeModel || 'opus'}) + Codex (${meta.codexModel || 'gpt-5.6-sol'})`);
  if (meta.note) out.push(`- Note: ${meta.note}`);
  out.push(`- Findings: ${c.Critical} Critical, ${c.Important} Important, ${c.Minor} Minor`, '');
  if (!ranked.length) { out.push('_No surviving findings._'); return `${out.join('\n')}\n`; }
  for (const f of ranked) {
    const tag = f.raisedBy.length === 2 ? 'both models' : f.raisedBy[0];
    out.push(`## [${f.severity}] ${f.title}`, '');
    out.push(`- **Where:** \`${f.file}${f.line ? `:${f.line}` : ''}\` · ${f.dimension} · raised by **${tag}**`);
    out.push(`- **Why:** ${f.why}`);
    if (f.failure_scenario) out.push(`- **Failure:** ${f.failure_scenario}`);
    if (f.fix) out.push(`- **Fix:** ${f.fix}`);
    out.push('');
  }
  return `${out.join('\n')}\n`;
}

export function renderDigest(meta, ranked) {
  const c = counts(ranked);
  const top = ranked.slice(0, 5).map((f) => {
    const tag = f.raisedBy.length === 2 ? 'both' : f.raisedBy[0];
    return `  [${f.severity}] ${f.title} (${f.file}${f.line ? `:${f.line}` : ''}, ${tag})`;
  });
  return [`superlazy-review: ${c.Critical} Critical, ${c.Important} Important, ${c.Minor} Minor`, ...top].join('\n');
}

// ---- CLI ----
function main(argv) {
  const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
  const [cmd, ...rest] = argv;
  if (cmd === 'bucket') {
    const [claudePath, codexPath] = rest;
    const claude = (readJson(claudePath).findings) || [];
    const codex = (readJson(codexPath).findings) || [];
    process.stdout.write(JSON.stringify(bucketFindings(claude, codex)));
    return;
  }
  if (cmd === 'render') {
    const [bucketPath, refutePath, outDir, metaPath] = rest;
    const bucket = readJson(bucketPath);
    const refutations = refutePath && refutePath !== '-' ? readJson(refutePath) : {};
    const meta = metaPath ? readJson(metaPath) : {};
    const ranked = applyRefutations(bucket, refutations);
    mkdirSync(outDir, { recursive: true });
    writeFileSync(`${outDir}/report.md`, renderReport(meta, ranked));
    process.stdout.write(renderDigest(meta, ranked));
    return;
  }
  process.stderr.write('usage: review-synth.mjs bucket <claude.json> <codex.json>\n'
    + '       review-synth.mjs render <bucket.json> <refute.json|-> <outDir> <meta.json>\n');
  process.exit(2);
}

if (import.meta.url === `file://${process.argv[1]}`) main(process.argv.slice(2));
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `node --test /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/sultan/Development/lazypowers
git add superlazy-cc/skills/superlazy-review/lib/review-synth.mjs superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs
git commit -m "superlazy-review: synthesis lib (bucket/rank/refute/render) + tests"
```

```json:metadata
{"files": ["superlazy-cc/skills/superlazy-review/lib/review-synth.mjs", "superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs"], "verifyCommand": "node --test /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs", "acceptanceCriteria": ["bucketFindings agreement/single + stable ids", "rankFindings severity then agreement then dimension", "applyRefutations drops refuted singles keeps agreed", "renderReport markdown shape", "node --test passes"], "modelTier": "standard"}
```

---

### Task 3: SKILL.md coordinator pipeline

**Goal:** Write the coordinator instructions that run the full pipeline end to end, wiring Task 1's prompts and Task 2's lib.

**Files:**
- Create: `skills/superlazy-review/SKILL.md`

**Acceptance Criteria:**
- [ ] Skill parses no-arg (local), numeric-arg (PR), and `--base/--post/--serial/--dimensions` flags.
- [ ] Resolves plugin paths via the cache glob; runs Claude via `Agent subagent_type superlazy-review-critic` and Codex via `codex-critic.sh review`, in parallel.
- [ ] Buckets via `review-synth.mjs bucket`, refutes only singles (other model), renders via `review-synth.mjs render`.
- [ ] Handles: Codex-down (single-model, flagged), empty diff, no base, `--post` confirm-before-post, PR worktree cleanup.
- [ ] References only files/agents that exist (superlazy-review-critic, superlazy-refute-critic, review-synth.mjs, codex-critic.sh).

**Verify:** `for a in 'subagent_type .superlazy-review-critic' 'codex-critic.sh review' 'review-synth.mjs bucket' 'superlazy-refute-critic' '--post' 'worktree remove'; do grep -q "$a" /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/SKILL.md || echo "MISSING: $a"; done` → prints nothing

**Steps:**

- [ ] **Step 1: Write `skills/superlazy-review/SKILL.md`**

````markdown
---
name: superlazy-review
description: >
  Cross-model adversarial code review: Claude and Codex/Sol independently review
  a diff (local branch or a GitHub PR), disagreements are refuted by the other
  model, and findings are ranked by severity + cross-model agreement. Advisory
  (never gates or merges). A two-model upgrade over /code-review.
---

# superlazy-review — cross-model code review

You are the COORDINATOR. Orchestrate a two-model review with your own tools:
Claude via the `Agent` tool, Codex via `Bash(codex-critic.sh)`, synthesis via the
node lib. Do NOT use the Workflow tool (its sandbox can't run Codex).

## Announce
"Using superlazy-review for a two-model (Claude + Codex/Sol) code review."

## Inputs
- No arg → review the current branch vs its base.
- Numeric arg (`superlazy-review 142`) → review GitHub PR #142.
- Flags: `--base <ref>`, `--post` (PR only), `--serial`, `--dimensions a,b,c`
  (default: all six — correctness, security, performance, tests, api-design,
  over-engineering).

## Step 0 — Resolve plugin paths
```bash
ROOT=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/ 2>/dev/null | sort -V | tail -1)
WRAP="$ROOT/scripts/codex-critic.sh"
SYNTH="$ROOT/skills/superlazy-review/lib/review-synth.mjs"
```

## Step 1 — Resolve the change + run dir
LOCAL (no numeric arg):
```bash
WT=$(git rev-parse --show-toplevel)
DEF=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'); DEF=${DEF:-main}
BASE=${BASE_OVERRIDE:-$(git merge-base "$DEF" HEAD)}
HEAD=$(git rev-parse HEAD)
RID="local-$(git rev-parse --short HEAD)"
```
PR (numeric arg N):
```bash
gh pr view N --json headRefName,baseRefName,headRefOid,title,body,url > /tmp/slr-pr.json
git fetch -q origin "pull/N/head:slr-pr-N"
WT="$(git rev-parse --show-toplevel)/../slr-pr-N-wt"
git worktree add -q "$WT" "slr-pr-N"
BASE=$(git -C "$WT" merge-base "origin/$(jq -r .baseRefName /tmp/slr-pr.json)" HEAD)
HEAD=$(git -C "$WT" rev-parse HEAD)
RID="pr-N"
```
Then: `RUN=".superlazy-review/$RID"; mkdir -p "$RUN"`.
If `git -C "$WT" diff --quiet "$BASE".."$HEAD"` → tell the user "nothing to review" and STOP.
If BASE is empty / HEAD detached with no base → STOP and ask for `--base`.

## Step 2 — Gather context (optional)
- Local: newest of `docs/superpowers/specs/*.md`, `docs/superpowers/plans/*.md`, or a `.superlazy-build/*/` plan. Read it (cap ~4KB).
- PR: title + body from `/tmp/slr-pr.json`; if the body references an issue (`#NN`), `gh issue view NN --json title,body`.
- Concatenate into CONTEXT text (or "(none)").

## Step 3 — Two parallel reviews
Build the shared input:
```
WORKTREE: <WT>
BASE_SHA: <BASE>
HEAD_SHA: <HEAD>
DIMENSIONS: <dims csv or "all">
CONTEXT:
<context or "(none)">
```
Run BOTH concurrently (issue the Bash and Agent calls in ONE message):
- Codex: `cd "$WT" && printf '%s' "$INPUT" | "$WRAP" review > "$RUN/codex.out" 2>"$RUN/codex.err"`
- Claude: `Agent` tool, `subagent_type: superlazy-review-critic`, `prompt` = the INPUT block. (Its system prompt is the reviewer; the INPUT is the assignment.)
Parse each result to `{verdict, summary, findings}`:
- Extract the first `{`…`}` JSON object (strip any stray prose/fence) and `JSON.parse`.
- If Codex output is not valid JSON (e.g. `VERDICT: NEEDS-HUMAN`) → Codex is DOWN: set `codex = {findings: []}` and `note = "single-model, unverified (Codex unavailable)"`. Do the same defensively for Claude.
Write `$RUN/claude.json` and `$RUN/codex.json` (each `{findings:[...]}`), and `$RUN/meta.json` = `{target, base, head, claudeModel:"opus", codexModel:"gpt-5.6-sol", note}`.

## Step 4 — Bucket
```bash
node "$SYNTH" bucket "$RUN/claude.json" "$RUN/codex.json" > "$RUN/bucket.json"
```
Read `bucket.json` → `{agreed, single}`. If `single` is empty, `refutations = {}` (skip Step 5).

## Step 5 — Cross-refute singles (parallel)
For each single finding, the OTHER model refutes. Build a refute input per finding:
```
WORKTREE: <WT>
BASE_SHA: <BASE>
HEAD_SHA: <HEAD>
FINDING: <the finding JSON>
```
- `raisedBy == ["claude"]` → Codex refutes: `cd "$WT" && printf '%s' "$REFUTE_INPUT" | "$WRAP" refute`
- `raisedBy == ["codex"]` → Claude refutes: `Agent` tool, `subagent_type: superlazy-refute-critic`, `prompt` = REFUTE_INPUT.
Run them in parallel (batch the calls). Parse each → `{refuted, reason}`.
- If a refuter call errors or is unparseable → treat as NOT refuted (keep the finding; conservative on infra failure), and note it.
Write `$RUN/refutations.json` = `{ "<id>": {refuted, reason}, ... }`.

## Step 6 — Synthesize + deliver
```bash
node "$SYNTH" render "$RUN/bucket.json" "$RUN/refutations.json" "$RUN" "$RUN/meta.json"
```
This writes `$RUN/report.md` and prints the digest. Show the user the digest and the `report.md` path.

## Step 7 — PR comments (only `--post`, PR mode)
CONFIRM with the user first (posting to a PR is outward-facing). On yes:
- For each surviving Critical/Important with a real `file`+`line`, post an inline comment via `gh api` (PR review comments), body = severity + title + why + fix + "(raised by <tag>)".
- Post one summary comment via `gh pr comment N` with the counts + top findings.
Then clean up: `git worktree remove --force "$WT" && git branch -D slr-pr-N`.

## Errors / edges
- Codex unavailable → continue Claude-only, report flagged "single-model, unverified". Never fake agreement.
- No base / detached → require `--base`. Empty diff → "nothing to review".
- Huge diff → if you must cap files, LOG the cap in the report (no silent truncation).

## Positioning
Advisory only — produces findings, never gates/merges/auto-fixes. Complements the
built-in single-model `/code-review`; this is the heavier two-model pass.
````

- [ ] **Step 2: Verify all referenced pieces exist and are wired**

Run:
```bash
for a in 'subagent_type: superlazy-review-critic' 'codex-critic.sh' 'review-synth.mjs bucket' 'superlazy-refute-critic' '--post' 'worktree remove'; do
  grep -q "$a" /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/SKILL.md || echo "MISSING: $a"
done
test -f /Users/sultan/Development/lazypowers/superlazy-cc/agents/superlazy-review-critic.md || echo "MISSING review-critic"
test -f /Users/sultan/Development/lazypowers/superlazy-cc/agents/superlazy-refute-critic.md || echo "MISSING refute-critic"
test -f /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.mjs || echo "MISSING synth"
```
Expected: no output.

Note: the SKILL.md lives at `superlazy-cc/skills/superlazy-review/SKILL.md`; adjust the create path to inside `superlazy-cc/` to match the plugin root. (All plugin content is under `superlazy-cc/`.)

- [ ] **Step 3: Commit**

```bash
cd /Users/sultan/Development/lazypowers
git add superlazy-cc/skills/superlazy-review/SKILL.md
git commit -m "superlazy-review: coordinator SKILL.md pipeline"
```

```json:metadata
{"files": ["superlazy-cc/skills/superlazy-review/SKILL.md"], "verifyCommand": "for a in 'subagent_type: superlazy-review-critic' 'codex-critic.sh' 'review-synth.mjs bucket' 'superlazy-refute-critic' '--post' 'worktree remove'; do grep -q \"$a\" /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/SKILL.md || echo MISSING $a; done", "acceptanceCriteria": ["parses local/PR/flags", "parallel Claude+Codex reviews", "bucket->refute-singles->render", "codex-down + empty-diff + no-base handling", "--post confirm + worktree cleanup", "references only existing files/agents"], "modelTier": "standard"}
```

Note on paths: the lib and SKILL live UNDER the plugin dir `superlazy-cc/`, i.e. `superlazy-cc/skills/superlazy-review/…` and `superlazy-cc/skills/superlazy-review/lib/…`. Task 2's create paths must be prefixed with `superlazy-cc/` too. (The plan shows repo-root-relative paths in a couple of Verify commands for brevity; the canonical location is under `superlazy-cc/`.)

---

### Task 4: plugin.json version bump

**Goal:** Bump the plugin version and note the new skill so `claude plugin update` picks it up.

**Files:**
- Modify: `superlazy-cc/.claude-plugin/plugin.json`

**Acceptance Criteria:**
- [ ] `version` bumped to `1.4.0`.
- [ ] description mentions the `superlazy-review` two-model review skill.
- [ ] File is valid JSON.

**Verify:** `node -e 'const p=require("/Users/sultan/Development/lazypowers/superlazy-cc/.claude-plugin/plugin.json"); if(p.version!=="1.4.0") throw new Error("version"); if(!/superlazy-review/.test(p.description)) throw new Error("desc"); console.log("ok")'` → prints `ok`

**Steps:**

- [ ] **Step 1: Edit `superlazy-cc/.claude-plugin/plugin.json`**

Set `"version": "1.4.0"` and append to the description: ` Also ships superlazy-review: a two-model (Claude + Codex) adversarial code-review skill.`

- [ ] **Step 2: Verify + commit**

```bash
cd /Users/sultan/Development/lazypowers
node -e 'const p=require("./superlazy-cc/.claude-plugin/plugin.json"); if(p.version!=="1.4.0"||!/superlazy-review/.test(p.description)) throw new Error("bad"); console.log("ok")'
git add superlazy-cc/.claude-plugin/plugin.json
git commit -m "superlazy-cc: v1.4.0 — add superlazy-review skill"
```

```json:metadata
{"files": ["superlazy-cc/.claude-plugin/plugin.json"], "verifyCommand": "node -e 'const p=require(\"/Users/sultan/Development/lazypowers/superlazy-cc/.claude-plugin/plugin.json\"); if(p.version!==\"1.4.0\") throw new Error(\"v\"); console.log(\"ok\")'", "acceptanceCriteria": ["version 1.4.0", "description mentions superlazy-review", "valid JSON"], "modelTier": "mechanical"}
```

---

### Task 5: Golden-fixture acceptance test + docs

**Goal:** A reproducible fixture with a planted real bug and a plausible-but-false finding, plus a documented live acceptance run and a README note.

**Files:**
- Create: `superlazy-cc/skills/superlazy-review/test/fixture.diff`
- Create: `superlazy-cc/skills/superlazy-review/test/acceptance.md`
- Modify: `README.md` (repo root) — add a superlazy-review section.

**Acceptance Criteria:**
- [ ] `fixture.diff` contains one clear Critical bug (e.g. an off-by-one / unchecked null that loses data) and one plausible-but-false line (looks risky, is actually safe).
- [ ] `acceptance.md` documents: apply the fixture to a scratch repo, run `superlazy-review`, and the EXPECTED qualitative result — the real Critical survives and is agreement- or single-but-unrefuted, the false one is refuted out.
- [ ] Deterministic gate (`node --test` on the synth lib) is referenced as the automated check; the live model run is the manual acceptance.
- [ ] README documents install + usage (`superlazy-review`, `superlazy-review <PR#>`, flags).

**Verify:** `node --test /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs && test -f /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/test/acceptance.md && grep -q superlazy-review /Users/sultan/Development/lazypowers/README.md && echo ok` → prints `ok`

**Steps:**

- [ ] **Step 1: Create `test/fixture.diff`** — a small unified diff adding a function with a planted Critical (e.g. `function pct(a,b){ return (a/b*100).toFixed(1) }` with no `b===0` guard → division-by-zero/`Infinity` corrupts output) AND a plausible-but-false line (e.g. a `// eslint-disable` or a `== ` comparison that is actually correct for the types). Include a comment header naming which is which for the acceptance check.

```diff
--- a/calc.js
+++ b/calc.js
@@ -0,0 +1,9 @@
+// FIXTURE: line 4 is the planted CRITICAL (no zero-divisor guard -> Infinity).
+// FIXTURE: line 8 is the PLAUSIBLE-BUT-FALSE finding (== is intentional/safe here).
+export function pct(a, b) {
+  return (a / b * 100).toFixed(1); // real bug: b === 0 -> "Infinity"
+}
+export function isBlank(s) {
+  // eslint-disable-next-line eqeqeq
+  return s == null; // safe: == null intentionally matches null AND undefined
+}
```

- [ ] **Step 2: Create `test/acceptance.md`** documenting the run:

```markdown
# superlazy-review acceptance

## Automated (deterministic)
`node --test skills/superlazy-review/lib/review-synth.test.mjs` — bucket/rank/refute/render logic.

## Live (manual, needs Claude + Codex)
1. `mkdir /tmp/slr-accept && cd /tmp/slr-accept && git init -q && git commit -q --allow-empty -m base`
2. Apply the fixture: `git apply <plugin>/skills/superlazy-review/test/fixture.diff && git add -A && git commit -q -m fixture`
3. `superlazy-review --base HEAD~1`
4. EXPECT: report.md lists a **Critical** for `calc.js:4` (division-by-zero / `Infinity`), raised by at least one model and NOT refuted. The `isBlank` `== null` line should NOT appear as a surviving Critical/Important — if a model flags it, the other model's refutation should drop it (it is intentional and safe).
5. If the false finding survives, the refuter prompt is too weak — tighten `agents/superlazy-refute-critic.md` and re-run.
```

- [ ] **Step 3: Add a `superlazy-review` section to `README.md`** (install from the fork, the two invocation modes, the flags, and the "advisory, two-model" positioning).

- [ ] **Step 4: Verify + commit**

```bash
cd /Users/sultan/Development/lazypowers
node --test superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs
test -f superlazy-cc/skills/superlazy-review/test/acceptance.md && grep -q superlazy-review README.md && echo ok
git add superlazy-cc/skills/superlazy-review/test README.md
git commit -m "superlazy-review: golden fixture, acceptance doc, README"
```

```json:metadata
{"files": ["superlazy-cc/skills/superlazy-review/test/fixture.diff", "superlazy-cc/skills/superlazy-review/test/acceptance.md", "README.md"], "verifyCommand": "node --test /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/lib/review-synth.test.mjs && test -f /Users/sultan/Development/lazypowers/superlazy-cc/skills/superlazy-review/test/acceptance.md && grep -q superlazy-review /Users/sultan/Development/lazypowers/README.md && echo ok", "acceptanceCriteria": ["fixture has planted Critical + plausible-false", "acceptance.md documents live run + expected outcome", "node --test referenced as automated gate", "README documents install/usage"], "modelTier": "standard"}
```

---

## Path note (applies to all tasks)

All plugin content lives UNDER `superlazy-cc/`. Canonical create paths:
- `superlazy-cc/agents/superlazy-review-critic.md`, `superlazy-cc/agents/superlazy-refute-critic.md`
- `superlazy-cc/skills/superlazy-review/SKILL.md`
- `superlazy-cc/skills/superlazy-review/lib/review-synth.mjs` (+ `.test.mjs`)
- `superlazy-cc/skills/superlazy-review/test/…`
- `superlazy-cc/.claude-plugin/plugin.json`

A few Verify commands above use repo-root-relative shorthands; the canonical location is under `superlazy-cc/`.

## Post-implementation

Install the new version and smoke-test on this very repo:
```bash
claude plugin update superlazy-cc          # or marketplace update + reload
# in a repo with a branch: superlazy-review --base main
```
