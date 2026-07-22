# lazypowers

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin marketplace.
Ships one plugin — **superlazy-cc** — with three skills:

- **`superlazy-brainstorm`** — Fable drafts, Sol critiques, Fable concludes.
  Stops with a detailed plan, rendered as an HTML page you can actually read.
- **`superlazy-build`** — executes the plan you hand it. No plan? It
  brainstorms inline first.
- **`superlazy-review`** — a two-model (Opus + Sol) adversarial code review.

> **This is a fork of [qrotux/lazypowers](https://github.com/qrotux/lazypowers).**
> The key difference: every critic/reviewer runs on **OpenAI Codex** (model
> `gpt-5.6-sol`, "Sol") via `codex exec`, instead of Claude subagents. Claude
> does the building; Codex does the adversarial reviewing — a genuine
> cross-model check. `superlazy-review` is new in this fork.

---

## superlazy-cc

### How the three skills relate

- `superlazy-brainstorm` **plans**: Fable (via a write-tool-less drafter
  subagent) authors the spec and plan; Sol critiques each one, at most twice;
  Fable revises and concludes. Hard stop — you read the generated HTML page
  (the whole plan: brief, then every task with goal/steps/files/criteria/verify,
  grouped into execution waves) and decide.
- `superlazy-build` **executes**: hand it a plan and it goes straight to work.
  Per-task model routing (mechanical/standard → Sonnet, frontier → Opus) via
  `docs/superpowers/model-routing.json`. Sol reviews the diff at the end.
- `superlazy-review` **reviews** an existing diff (yours or a PR) with two
  models — Claude on **Opus** by default + Sol — and ranks findings by
  cross-model agreement.

All three share one wrapper, `scripts/codex-critic.sh`, which runs a prompt on
Codex in a **read-only sandbox** and returns its VERDICT block.

### The loop (1.7.0)

```
superlazy-brainstorm:  you ──▶ Fable drafts ──▶ Sol ──▶ Fable ──▶ Sol ──▶ Fable
                       ──▶ plan + tasks.json + HTML ──▶ STOP
superlazy-build <plan>: execute (Sonnet/Opus per task) ──▶ Sol reviews the diff
                        ──▶ finish
```

**Every critic loop is round-budgeted.** A critic that re-reads a document
always finds one more `[Important]`, so drafter↔critic never converges on its
own — left unbounded it will happily spend an afternoon on a small feature.
Sol gets `CODEX_CRITIC_MAX_ROUNDS` passes per seam (default 2), then the
drafter revises once more and **concludes**. Past the budget the wrapper
refuses to spend a Codex call at all and prints `GATE: conclude`.

There is no approval to verify, no marker, no hash. If you hand a plan to
`superlazy-build`, it is done by definition — you are the one who reviewed it.

---

## superlazy-build — execute the plan you were handed

```
build <plan.md>:  execute ──▶ Sol reviews the diff ──▶ finish
build <brief>:    superlazy-brainstorm --continue ──▶ execute ──▶ Sol ──▶ finish
```

### Who runs what

| Role | Model | Where |
|---|---|---|
| Planner/drafter — always the last word | **Fable** | `superlazy-drafter` subagent (no write tools) |
| Critic — all three seams, ≤2 rounds each | **Sol** (`gpt-5.6-sol`) | `codex-critic.sh spec\|plan\|code` |
| mechanical / standard tasks | **Sonnet** (low / medium) | execution waves, via `model-routing.json` |
| frontier tasks | **Opus** | execution waves |
| Review pair | **Opus + Sol** | `superlazy-review` (the one fixed pair) |

### What's inside

| Component | Role |
|---|---|
| `superlazy-brainstorm` (skill) | Plans with Fable + Sol, then stops. |
| `superlazy-build` (skill) | Executes a plan. Invoke with a plan path or a brief. |
| `superlazy-spec-critic` (prompt) | Reviews the design spec. Findings are intent decisions — surfaced, never auto-edited. |
| `superlazy-plan-critic` (prompt) | Reviews the plan. ≤2 rounds, then Fable concludes. |
| `superlazy-code-critic` (prompt) | Reviews implemented code vs the plan. ≤2 rounds, then you ship with what's open. |
| `codex-critic.sh` (script) | Runs a critic prompt on Codex (`codex exec -s read-only`), returns its VERDICT block, appends a `GATE:` directive, and enforces the round budget. |

The three critics run on **Codex/Sol** in a read-only sandbox. The script never
edits anything and never blocks anything — it reports, and the round budget
decides when the conversation is over.

### Usage

```
/superlazy-brainstorm <your feature brief>     # plan today…
/superlazy-build docs/superpowers/plans/X.md   # …build when you're ready
/superlazy-build <your feature brief>          # or do both in one go
```

Flags (build):
- `--skip-critics` — Sol never runs; Fable still authors everything.
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
- `--codex-model <id>` — Codex reviewer model (**default: gpt-5.6-sol**).
- `--claude-model <sonnet|opus|haiku>` — Claude reviewer model (**default: opus**; use `sonnet` for a cheaper pass).

Out of the box: **Opus on the Claude side, Sol on the Codex side.** The report
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
| `CODEX_CRITIC_EFFORT` | `high` | Reasoning effort (`minimal\|low\|medium\|high`). Every round runs `high`: each Codex call is a fresh cold read, not a cheap re-read, and the last round is the final word before the drafter concludes. |
| `CODEX_CRITIC_MAX_ROUNDS` | `2` | Critic passes per seam before the drafter concludes. Raise it if you want more argument, lower it to `1` for one look and done. |
| `CODEX_CRITIC_ROUND` | `1` | Which round this call is; the coordinator increments it. Past `MAX_ROUNDS` the wrapper makes no Codex call and prints `GATE: conclude`. |
| `CODEX_CRITIC_SEARCH` | `1` (on) | Live web search (`codex exec --search`) so critics verify current library APIs, CVEs, and breaking changes. Set `0` for faster/offline runs. |

Reviewers also use the **Context7 MCP** (if configured in `~/.codex/config.toml`,
which the setup above keeps) to pull library docs — independent of the web-search
switch. Together, web search + Context7 make the Codex critics evidence-backed.

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
