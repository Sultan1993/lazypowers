# lazypowers

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin marketplace.
Currently ships one plugin: **superlazy-cc**.

## superlazy-cc

A gated, reviewed feature-build pipeline. It drives the existing
[`superpowers-extended-cc`](#requirements) skills as stages and dispatches an
adversarial critic at each seam, so a feature can't advance until the prior
critic's findings are cleared.

```
brainstorming ──▶ SEAM 1 ──▶ writing-plans ──▶ SEAM 2 ──▶ execution ──▶ SEAM 3 ──▶ finish
                spec-critic                  plan-critic              code-critic
```

A `PreToolUse` hook backstops the coordinator: it **denies** the Skill call that
would advance a stage until the prior critic has written its `*.passed` marker
under `.superlazy-build/<run-id>/`.

### What's inside

| Component | Role |
|---|---|
| `superlazy-build` (skill) | Coordinator that runs the pipeline. Invoke it with your brief. |
| `superlazy-spec-critic` (agent) | SEAM 1 — reviews the design spec. Surfaces findings; does **not** auto-edit. |
| `superlazy-plan-critic` (agent) | SEAM 2 — reviews the plan. Auto-fixes, bounded to 2 rounds. |
| `superlazy-code-critic` (agent) | SEAM 3 — reviews implemented code vs the plan. Auto-fixes, bounded to 2 rounds. |
| `superlazy-build-gate.sh` (hook) | PreToolUse seam gate. No-op outside a run. |

Critics use **WebSearch** and **Context7** to verify library/API claims.

### Install

```
/plugin marketplace add qrotux/lazypowers
/plugin install superlazy-cc@lazypowers
```

### Usage

```
/superlazy-build <your feature brief>
```

Add `--skip-critics` to run the plain superpowers flow without the gated critics
(also auto-skipped for trivial, single-file changes).

### Requirements

The [`superpowers-extended-cc`](https://github.com/pcvelz/superpowers) skills must
be installed and enabled — superlazy-cc orchestrates them (`brainstorming`,
`writing-plans`, `subagent-driven-development`, `finishing-a-development-branch`)
rather than reimplementing them.

## License

[MIT](LICENSE)
