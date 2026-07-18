# lazypowers

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin marketplace.
Ships one plugin — **superlazy-cc** — with two skills:

- **`superlazy-build`** — a gated, reviewed feature-build pipeline.
- **`superlazy-review`** — a two-model adversarial code review.

> **This is a fork of [qrotux/lazypowers](https://github.com/qrotux/lazypowers).**
> The key difference: every critic/reviewer runs on **OpenAI Codex** (model
> `gpt-5.6-sol`, "Sol") via `codex exec`, instead of Claude subagents. Claude
> does the building; Codex does the adversarial reviewing — a genuine
> cross-model check. `superlazy-review` is new in this fork.

---

## superlazy-cc

### How the two skills relate

- `superlazy-build` **builds** a feature and gates each stage behind a Codex critic.
- `superlazy-review` **reviews** an existing diff (yours or a PR) with two models and ranks the findings.

Both share one wrapper, `scripts/codex-critic.sh`, which runs a prompt on Codex
in a **read-only sandbox** and returns its verdict.

---

## superlazy-build — gated build pipeline

Drives the [`superpowers-extended-cc`](#requirements) skills as stages and
dispatches an adversarial critic at each seam, so a feature can't advance until
the prior critic's findings are cleared.

```
brainstorming ──▶ SEAM 1 ──▶ writing-plans ──▶ SEAM 2 ──▶ execution ──▶ SEAM 3 ──▶ finish
                spec-critic                  plan-critic              code-critic
                (Codex)                       (Codex)                  (Codex)
```

A `PreToolUse` hook backstops the coordinator: it **denies** the Skill call that
would advance a stage until the prior critic has written its `*.passed` marker
under `.superlazy-build/<run-id>/`.

### What's inside

| Component | Role |
|---|---|
| `superlazy-build` (skill) | Coordinator that runs the pipeline. Invoke with your brief. |
| `superlazy-spec-critic` (prompt) | SEAM 1 — reviews the design spec. Surfaces findings; does **not** auto-edit. |
| `superlazy-plan-critic` (prompt) | SEAM 2 — reviews the plan. Auto-fixes, bounded to 2 rounds. |
| `superlazy-code-critic` (prompt) | SEAM 3 — reviews implemented code vs the plan. Auto-fixes, bounded to 2 rounds. |
| `codex-critic.sh` (script) | Runs a critic prompt on Codex (`codex exec -s read-only`) and returns its VERDICT block. |
| `superlazy-build-gate.sh` (hook) | PreToolUse seam gate. No-op outside a run. |

The three critics run on **Codex/Sol** in a read-only sandbox. The coordinator
parses each critic's `VERDICT:` block and writes the marker the gate checks.

### Usage

```
/superlazy-build <your feature brief>
```

Flags:
- `--skip-critics` — run the plain superpowers flow without the gated critics
  (also auto-skipped for trivial, single-file changes).
- `--serial` — opt out of wave parallelism during execution.

---

## superlazy-review — two-model code review

Reviews a diff with **both** Claude and Codex/Sol, independently, then has each
model try to **refute** the other's single-model findings. Findings are ranked so
the ranking itself encodes cross-model confidence. **Advisory only** — it never
gates, merges, or auto-fixes. A two-model upgrade over the built-in
single-model `/code-review`.

```
resolve diff ──▶ Claude review ─┐
   (or PR)      Codex review  ──┴─▶ bucket ──▶ refute ─────▶ rank ──▶ report.md
                (parallel)         agreed vs   (singles,     by         + digest
                                   single      other model)  severity ×  (+ opt-in
                                                             agreement    PR comments)
```

- **Agreement corroborates:** a finding both models raise independently is top-confidence and skips refutation.
- **Disagreement is tested:** a single-model finding is handed to the *other* model to refute; it survives only if it can't be refuted.
- Six dimensions: correctness, security, performance, tests, api-design, over-engineering.
- If a plan/spec (from a `superlazy-build` run) or a PR description/linked issue exists, reviewers also check **conformance** to intent; otherwise it's a pure diff review.

### Usage

```
/superlazy-review                 # review the current branch vs its base
/superlazy-review <PR#>           # review a GitHub PR (via gh)
```

Flags:
- `--base <ref>` — explicit comparison base.
- `--post` — PR mode only: post surviving Critical/Important findings as inline PR comments (opt-in; confirms first).
- `--serial` — disable parallel fan-out.
- `--dimensions correctness,security,...` — review a subset of the six dimensions.
- `--claude-model <sonnet|opus|haiku>` — Claude reviewer model (**default: sonnet**; use `opus` for the heaviest reviews).
- `--codex-model <id>` — Codex reviewer model (**default: gpt-5.6-sol**).

Out of the box: **Sonnet on the Claude side, Sol on the Codex side.** The report
header names the models actually used. Output lands in `.superlazy-review/<run-id>/report.md`.

---

## Codex setup (shared by both skills)

Both skills run their critics/reviewers through `scripts/codex-critic.sh`, which
calls the [Codex CLI](https://github.com/openai/codex). You need:

```
npm i -g @openai/codex
codex login          # ChatGPT-plan auth
```

Model / effort are configurable via environment variables (the wrapper's
defaults are already sensible):

| Variable | Default | Notes |
|---|---|---|
| `CODEX_CRITIC_MODEL` | `gpt-5.6-sol` | The "Sol" model. Set empty to use your Codex account default. On a ChatGPT-account Codex, `gpt-5-codex` is **not** available — `gpt-5.6-sol` is. |
| `CODEX_CRITIC_EFFORT` | `high` | Reasoning effort (`minimal\|low\|medium\|high`). Adversarial review benefits from `high`. |

The wrapper always runs Codex with `-s read-only`, so it can read the repo,
diff, spec, and plan but never edits — all fixing stays with the coordinator.

If Codex is unavailable, the wrapper emits `VERDICT: NEEDS-HUMAN`; `superlazy-build`
stops the seam, and `superlazy-review` continues single-model and flags the
report as "single-model, unverified" (it never fakes agreement).

---

## Install

```
/plugin marketplace add Sultan1993/lazypowers
/plugin install superlazy-cc@lazypowers
```

Update later:

```
claude plugin marketplace update lazypowers
claude plugin update superlazy-cc@lazypowers      # note the @lazypowers suffix
```

Restart Claude Code after a version update so the new skills register.

## Requirements

- The [`superpowers-extended-cc`](https://github.com/pcvelz/superpowers) skills
  installed and enabled — `superlazy-build` orchestrates them (`brainstorming`,
  `writing-plans`, `subagent-driven-development`, `finishing-a-development-branch`)
  rather than reimplementing them.
- The Codex CLI installed and authenticated (see [Codex setup](#codex-setup-shared-by-both-skills)).
- `gh` (GitHub CLI) for `superlazy-review <PR#>`.

## Credits

Fork of [qrotux/lazypowers](https://github.com/qrotux/lazypowers). Original
`superlazy-build` pipeline and seam-gate design by qrotux; this fork moves the
critics to Codex and adds `superlazy-review`.

## License

[MIT](LICENSE)
