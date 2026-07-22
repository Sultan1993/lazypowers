# lazypowers

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin marketplace.
Ships one plugin — **superlazy-cc** — with three skills:

- **`superlazy-brainstorm`** — Fable plans, Sol approves, you review. Stops
  with a hash-bound approved plan + an HTML review page.
- **`superlazy-build`** — executes an approved plan (verify → skip to
  execution; stale → one-pass re-bless). No plan? It brainstorms inline first.
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
  subagent) authors the spec and plan; Sol gates both seams; approval is a
  sidecar carrying the sha256 of the exact approved bytes. Hard stop — you
  review the generated HTML and decide.
- `superlazy-build` **executes**: with a plan it runs `codex-critic.sh verify`
  (no LLM call) and skips straight to execution; a stale/edited plan gets one
  Sol re-bless pass — never a re-brainstorm. Per-task model routing
  (mechanical/standard → Sonnet, frontier → Opus) via
  `docs/superpowers/model-routing.json`. Sol's code-critic gates the diff.
- `superlazy-review` **reviews** an existing diff (yours or a PR) with two
  models — Claude on **Opus** by default + Sol — and ranks findings by
  cross-model agreement.

All three share one wrapper, `scripts/codex-critic.sh`, which runs a prompt on
Codex in a **read-only sandbox** — and is the ONLY writer of approval markers
and sidecars (`spec|plan|code` modes write them solely on `VERDICT: pass` with
zero Critical/Important findings; `verify` re-validates a sidecar without any
LLM call).

### The trust chain (1.6.0)

```
superlazy-brainstorm:  you ──▶ Fable drafts ──▶ Sol spec-critic ──▶ Fable plans
                       ──▶ Sol plan-critic (+tier audit) ──▶ sidecar + HTML ──▶ STOP
superlazy-build <plan>: verify sidecar ──▶ execute (Sonnet/Opus per task)
                        ──▶ Sol code-critic ──▶ finish
```

Approvals are hash-bound: `spec-critic.passed` records the spec's sha256,
`plan-critic.passed` records plan+tasks+spec sha256s, and the execution gate
recomputes all three (and requires the sdd invocation to name the approved
plan via a structured `planPath=` argument) before allowing execution. Edit
anything after approval → one re-bless pass, automatically. Tamper-evident,
not tamper-proof: the adversary is drift, not malice.

---

## superlazy-build — verify, (re-)bless, execute

Executes a Sol-approved plan, delegating planning to `superlazy-brainstorm`
when none is given:

```
build <plan.md>:  verify sidecar ──▶ execute ──▶ SEAM 3 ──▶ finish
                  (stale? one Sol re-bless — never a re-brainstorm)
build <brief>:    superlazy-brainstorm --continue ──▶ execute ──▶ SEAM 3 ──▶ finish
```

A `PreToolUse` hook gates execution: it recomputes the plan/tasks/spec hashes
recorded in `plan-critic.passed` and requires the sdd invocation to name the
approved plan via exactly one `planPath=` argument — post-approval edits and
approved-A/executed-B swaps are both denied at the authorization point.

### Who runs what

| Role | Model | Where |
|---|---|---|
| Planner/drafter | **Fable** | `superlazy-drafter` subagent (no write tools) |
| Critic — all three seams | **Sol** (`gpt-5.6-sol`, pinned) | `codex-critic.sh spec\|plan\|code` |
| mechanical / standard tasks | **Sonnet** (low / medium) | execution waves, via `model-routing.json` |
| frontier tasks | **Opus** | execution waves |
| Review pair | **Opus + Sol** | `superlazy-review` (the one fixed pair) |

### What's inside

| Component | Role |
|---|---|
| `superlazy-build` (skill) | Coordinator that runs the pipeline. Invoke with your brief. |
| `superlazy-spec-critic` (prompt) | SEAM 1 — reviews the design spec. Surfaces findings; does **not** auto-edit. |
| `superlazy-plan-critic` (prompt) | SEAM 2 — reviews the plan. Auto-fixes, bounded to 2 rounds. |
| `superlazy-code-critic` (prompt) | SEAM 3 — reviews implemented code vs the plan. Auto-fixes, bounded to 2 rounds. |
| `codex-critic.sh` (script) | Runs a critic prompt on Codex (`codex exec -s read-only`) and returns its VERDICT block. |
| `superlazy-build-gate.sh` (hook) | PreToolUse seam gate. No-op outside a run. |

The three critics run on **Codex/Sol** in a read-only sandbox — seam modes are
pinned to Sol (env overrides ignored). The SCRIPT parses its own verdict and
writes the markers; the coordinator can only route through them.

### Usage

```
/superlazy-brainstorm <your feature brief>     # plan today…
/superlazy-build docs/superpowers/plans/X.md   # …build when you're ready
/superlazy-build <your feature brief>          # or do both in one go
```

Flags (build):
- `--spec <path>` — spec location for re-bless when no sidecar names it.
- `--skip-critics` — loud bypass: Fable still authors, but nothing is
  approved (no sidecar), so a later normal build re-critiques.
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
| `CODEX_CRITIC_EFFORT` | `high` | Reasoning effort (`minimal\|low\|medium\|high`). Adversarial review benefits from `high`. |
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
