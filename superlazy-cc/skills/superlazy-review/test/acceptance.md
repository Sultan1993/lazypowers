# superlazy-review acceptance

## Automated (deterministic)
`node --test skills/superlazy-review/lib/review-synth.test.mjs` — bucket/rank/refute/render logic.

## Live (manual, needs Claude + Codex)
1. `mkdir /tmp/slr-accept && cd /tmp/slr-accept && git init -q && git commit -q --allow-empty -m base`
2. Apply the fixture: `git apply <plugin>/skills/superlazy-review/test/fixture.diff && git add -A && git commit -q -m fixture`
3. `superlazy-review --base HEAD~1`
4. EXPECT: report.md lists a **Critical** for `calc.js` around the `pct()` division (division-by-zero / Infinity), raised by at least one model and NOT refuted. The `isBlank` `== null` line should NOT appear as a surviving Critical/Important — if a model flags it, the other model's refutation should drop it (it is intentional and safe).
5. If the false finding survives, the refuter prompt is too weak — tighten `agents/superlazy-refute-critic.md` and re-run.
