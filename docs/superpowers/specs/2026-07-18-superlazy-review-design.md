# superlazy-review — design spec

Date: 2026-07-18
Status: approved (design), pending implementation plan
Repo: `Sultan1993/lazypowers` (plugin `superlazy-cc`)

## Purpose

A cross-model adversarial code review. Both **Claude** and **Codex / gpt-5.6-sol**
review the same diff independently, disagreements are refuted by the *other*
model, and the result is a report ranked so the ranking itself encodes
cross-model confidence. It is a deliberate two-model upgrade over the built-in
single-model `/code-review`.

**Advisory only** — it produces findings and (optionally) PR comments. It never
gates, blocks, or merges anything.

Two jobs it serves:
- Review my own big feature before I ship it (local branch/worktree diff).
- Review someone else's GitHub PR.

## Invocation & inputs

- `superlazy-review` — review the current branch vs its base. Base auto-detected
  as `git merge-base <default-branch> HEAD`; override with `--base <ref>`.
- `superlazy-review <PR#>` — `gh pr checkout` the PR into a **dedicated git
  worktree** (never mutate the user's current branch), review PR head vs base.

Flags:
- `--base <ref>` — explicit comparison base.
- `--post` — PR mode only: after a confirm step, post surviving Critical/Important
  findings as inline PR comments plus one summary comment. Default is OFF
  (report only).
- `--serial` — disable parallel fan-out (debug / rate-limit relief).
- `--dimensions <list>` — review a subset of the six dimensions.

Auto-detected context (drives conformance checks):
- A plan/spec from a superlazy-build run dir or `docs/superpowers/specs/`.
- In PR mode: the PR description + any linked issue (via `gh`).
- If context is present → reviewers ALSO check conformance to stated intent.
- If absent → pure diff review. One code path; conformance is an optional section.

## Review dimensions (both models, all dimensions)

1. **correctness** — logic bugs, edge cases, error handling, data-loss paths.
2. **security** — injection, secret handling, unsafe shell/SQL, authz gaps.
3. **performance** — needless O(n²), N+1, sync-in-loop, avoidable allocations.
4. **tests** — real assertions vs test theater; missing coverage of the change.
5. **api-design** — interface clarity, breaking changes, contract mismatches.
6. **over-engineering** — speculative abstraction, dead flexibility, reinvented
   stdlib (the ponytail lens).

Both models review ALL selected dimensions — full redundancy is required for the
agreement signal to exist.

## Pipeline (coordinator-driven)

The `superlazy-review` skill instructs the coordinator (Claude Code, this
session) to orchestrate directly. Rationale: the Workflow sandbox has no shell
access, so it cannot run `codex exec`; rather than tunnel every Codex review
through a throwaway relay subagent, the coordinator invokes Codex natively via
`Bash(codex-critic.sh)` and Claude via the `Agent` tool. The skill parses args,
resolves the diff / worktree / context, runs the pipeline below, then handles
`--post`:

1. **Resolve** — compute `BASE_SHA`/`HEAD_SHA`, ensure the worktree, gather
   context (plan/spec/PR body), emit the diff + changed-file list.
2. **Review (two parallel jobs)** — each model reviews the whole diff across all
   selected dimensions in ONE pass (findings carry a `dimension` tag), run
   concurrently. (Two comprehensive reviews, not 12 per-dimension calls — far
   leaner, same cross-model signal since findings are dimension-tagged.)
   - Claude side: the `Agent` tool with the `superlazy-review-critic` prompt,
     structured-output schema enforced.
   - Codex side: `Bash(codex-critic.sh review)` (gpt-5.6-sol, high reasoning
     effort, read-only sandbox), run in the worktree.
   - Each returns the findings JSON schema (see below).
3. **Bucket** — dedupe the two findings sets by `(file, dimension, line-
   proximity)` into **AGREED** (raised independently by both models) and
   **SINGLE** (one model only).
4. **Cross-refute (parallel, SINGLE only)** — hand each single-model finding to
   the *other* model using the `superlazy-refute-critic` prompt (Codex via
   `codex-critic.sh refute`, Claude via `Agent`), default-refuted-if-uncertain.
   It survives only if not refuted. AGREED findings skip this step.
5. **Synthesize** — final set = `AGREED ∪ SINGLE-survivors`, ranked by
   severity (Critical > Important > Minor) → agreement (both > one) → dimension.
   Each entry carries: title, severity, `file:loc`, failure scenario, suggested
   fix, raised-by (Claude / Codex / both), refutation outcome.
6. **Deliver** — write `.superlazy-review/<run-id>/report.md` + a terminal digest
   (counts + top findings). In PR mode with `--post`: confirm, then post inline
   comments on surviving Critical/Important + one summary comment.

## Findings interchange format (shared JSON)

Both reviewers emit the SAME strict JSON so bucketing/refutation is programmatic
(refinement over the spec's original prose VERDICT block — a text format is
error-prone to parse for dedup). The Claude side enforces it via the `Agent`
structured-output schema; the Codex prompt demands "output ONLY minified JSON
matching this schema" and the coordinator `JSON.parse`s stdout.

```json
{
  "verdict": "pass" | "findings",
  "summary": "one or two sentences",
  "findings": [
    {
      "severity": "Critical" | "Important" | "Minor",
      "dimension": "correctness|security|performance|tests|api-design|over-engineering",
      "file": "path/relative/to/repo",
      "line": 123,
      "title": "short label",
      "why": "reason + evidence",
      "failure_scenario": "concrete inputs -> wrong output/crash",
      "fix": "suggested fix"
    }
  ]
}
```

Refutation replies use `{ "refuted": true|false, "reason": "..." }`.
If Codex is unavailable the wrapper prints `VERDICT: NEEDS-HUMAN` (non-JSON) —
the coordinator treats an unparseable Codex reply as "Codex down," never as a
clean review (see Error handling).

## Components / files (in the fork)

- `skills/superlazy-review/SKILL.md` — the coordinator instructions. Parses
  args, resolves diff/worktree/context, runs the fan-out (`Agent` for Claude,
  `Bash(codex-critic.sh review)` for Codex), then delegates bucket/refute-target/
  rank/render to the node lib, handles `--post` with a confirm step.
- `skills/superlazy-review/lib/review-synth.mjs` — pure, unit-tested node module
  holding ALL deterministic logic: `findingKey`, `bucketFindings`,
  `rankFindings`, `renderReport`, `renderDigest`, plus a CLI entry
  (`node review-synth.mjs <in.json> <out-dir>`).
- `skills/superlazy-review/lib/review-synth.test.mjs` — `node --test` unit tests.
- `agents/superlazy-review-critic.md` — the shared **plan-agnostic** review
  prompt: the six dimensions + an optional conformance section that activates
  only when a plan/spec/PR-intent is supplied. Used by the Claude `Agent` side
  AND read by `codex-critic.sh` for the Codex side (symmetric). Emits the
  findings JSON above.
- `agents/superlazy-refute-critic.md` — the refutation prompt: given one finding
  + the diff, return `{refuted, reason}` (default refuted-if-uncertain). Used by
  the *other* model for each SINGLE finding. `codex-critic.sh refute` resolves it.
- `scripts/codex-critic.sh` — **reused unchanged**: it already resolves
  `agents/superlazy-${critic}-critic.md`, so `codex-critic.sh review` reads
  `superlazy-review-critic.md`. Same model (gpt-5.6-sol) / effort (high) /
  read-only sandbox as the build critics.
- `.claude-plugin/plugin.json` — version bump; mention the new skill.

## Error handling / edge cases

- **Codex unavailable / `NEEDS-HUMAN`** → continue with Claude-only reviews but
  flag the whole report as "single-model, unverified"; never fabricate agreement
  and never silently pass.
- **No base / detached HEAD** → require `--base`, stop with a clear message.
- **Empty diff** → report "nothing to review" and exit.
- **Huge diff** → split changed files across the fan-out (dimension jobs get file
  subsets); if any coverage cap is applied, LOG it in the report — no silent
  truncation.
- **PR checkout** → always a dedicated worktree; never dirty the user's current
  branch. Clean up the worktree at the end.
- **`--post`** → outward-facing action on someone's PR: confirm before posting.

## Testing

- **Golden diff fixture** with a planted real Critical bug AND a plausible-but-
  false finding → assert the Critical survives and is agreement-tagged, and the
  false finding is refuted out of the final report.
- **Wrapper `review` mode smoke test** — `codex-critic.sh review` on a tiny diff
  returns a well-formed VERDICT block (mirrors the spec-critic smoke test).
- **Dedupe/bucket unit check** — two findings at the same `file:line` from the two
  models collapse into one AGREED entry.

## Positioning

Complements `/code-review` (single-model, fast, current diff). `superlazy-review`
is the heavier two-model + adversarial pass for big features and PRs, where the
agreement/refutation ranking is worth the extra cost. Not a replacement for the
quick path.

## Non-goals

- No gating/merge/CI enforcement (advisory only).
- No auto-fixing — it reports; the human (or a separate build pass) fixes.
- No new model config — reuses the fork's `CODEX_CRITIC_MODEL` / `_EFFORT`.
