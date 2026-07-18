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

## Pipeline (Workflow-driven)

The `superlazy-review` skill is a thin launcher: parse args, resolve the diff /
worktree / context, invoke the Workflow, then handle `--post`. The Workflow does:

1. **Resolve** — compute `BASE_SHA`/`HEAD_SHA`, ensure the worktree, gather
   context (plan/spec/PR body), emit the diff + changed-file list.
2. **Review (parallel fan-out)** — `dimensions × {Claude, Codex}` review jobs.
   - Claude side: a review subagent (`superlazy-review-critic` prompt).
   - Codex side: `codex-critic.sh review` (same prompt, run on gpt-5.6-sol,
     high reasoning effort, read-only sandbox).
   - Every job returns the shared VERDICT/FINDINGS format.
3. **Bucket** — dedupe all result sets by `(file, line-proximity, claim overlap)`
   into **AGREED** (raised independently by both models) and **SINGLE** (one
   model only).
4. **Cross-refute (parallel, SINGLE only)** — hand each single-model finding to
   the *other* model, prompted to refute, default-refuted-if-uncertain. It
   survives only if not refuted. AGREED findings skip this step (already
   corroborated).
5. **Synthesize** — final set = `AGREED ∪ SINGLE-survivors`, ranked by
   severity (Critical > Important > Minor) → agreement (both > one) → dimension.
   Each entry carries: title, severity, `file:loc`, failure scenario, suggested
   fix, raised-by (Claude / Codex / both), refutation outcome.
6. **Deliver** — write `.superlazy-review/<run-id>/report.md` + a terminal digest
   (counts + top findings). In PR mode with `--post`: confirm, then post inline
   comments on surviving Critical/Important + one summary comment.

## VERDICT / FINDINGS format (shared)

Reuse the existing critic format so Claude and Codex outputs are apples-to-apples:

```
VERDICT: pass | findings
SUMMARY: <one or two sentences>
FINDINGS:
- [Critical] <title> — <why + evidence> — <file:loc> — <failure scenario> — <fix>
- [Important] <...>
- [Minor] <...>
```

`NEEDS-HUMAN` verdict (wrapper couldn't run Codex) is never treated as a clean
review — see Error handling.

## Components / files (in the fork)

- `skills/superlazy-review/SKILL.md` — the launcher + the Workflow script
  (inline). Parses args, resolves diff/worktree/context, runs the pipeline,
  handles `--post` with a confirm step.
- `agents/superlazy-review-critic.md` — the shared **plan-agnostic** review
  prompt: the six dimensions + an optional conformance section that activates
  only when a plan/spec/PR-intent is supplied. Used by the Claude subagent AND
  read by `codex-critic.sh` for the Codex side (symmetric).
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
