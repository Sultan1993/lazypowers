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
- Model flags (independent per side):
  - `--claude-model <sonnet|opus|haiku>` — model for the Claude reviewer/refuter
    (default: **opus**; pass `sonnet` for a cheaper review). Pass it as the
    `Agent` tool's `model` on every review/refute dispatch.
  - `--codex-model <id>` — model for the Codex reviewer/refuter (default
    `gpt-5.6-sol`). Export as `CODEX_CRITIC_MODEL=<id>` before each
    `codex-critic.sh` call.
  Example — Sonnet on Claude's side, Sol on Codex's: `--claude-model sonnet`;
  default is Opus + Sol
  (leave `--codex-model` at its default).

## Step 0 — Resolve plugin paths
```bash
ROOT=$(ls -d ~/.claude/plugins/cache/*/superlazy-cc/*/ 2>/dev/null | sort -V | tail -1)
WRAP="$ROOT/scripts/codex-critic.sh"
SYNTH="$ROOT/skills/superlazy-review/lib/review-synth.mjs"
export CODEX_CRITIC_EFFORT=high   # pin effort; don't rely on the wrapper default
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
- Codex: `cd "$WT" && printf '%s' "$INPUT" | ${CODEX_MODEL:+CODEX_CRITIC_MODEL="$CODEX_MODEL"} "$WRAP" review > "$RUN/codex.out" 2>"$RUN/codex.err"` (set `CODEX_MODEL` from `--codex-model` if given; else omit → wrapper default gpt-5.6-sol).
- Claude: `Agent` tool, `subagent_type: superlazy-review-critic`, `prompt` = the INPUT block, and `model: <--claude-model or opus>` — ALWAYS pass the model parameter explicitly (never rely on agent frontmatter resolution). (Its system prompt is the reviewer; the INPUT is the assignment.)
Parse each result to `{verdict, summary, findings}`:
- Extract the first `{`…`}` JSON object (strip any stray prose/fence) and `JSON.parse`.
- If Codex output is not valid JSON (e.g. `VERDICT: NEEDS-HUMAN`) → Codex is DOWN: set `codex = {findings: []}` and `note = "single-model, unverified (Codex unavailable)"`. Do the same defensively for Claude.
Write `$RUN/claude.json` and `$RUN/codex.json` (each `{findings:[...]}`), and `$RUN/meta.json` = `{target, base, head, claudeModel:<--claude-model or "opus">, codexModel:<--codex-model or "gpt-5.6-sol">, note}` (so the report header names the models actually used).

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
- `raisedBy == ["claude"]` → Codex refutes: `cd "$WT" && printf '%s' "$REFUTE_INPUT" | ${CODEX_MODEL:+CODEX_CRITIC_MODEL="$CODEX_MODEL"} "$WRAP" refute`
- `raisedBy == ["codex"]` → Claude refutes: `Agent` tool, `subagent_type: superlazy-refute-critic`, `prompt` = REFUTE_INPUT, and `model: <--claude-model or opus>` — always explicit.

(Use the SAME `--claude-model` / `--codex-model` choices as Step 3 so each side is consistent between review and refute.)
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
