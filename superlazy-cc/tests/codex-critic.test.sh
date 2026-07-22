#!/usr/bin/env bash
# Stub-based tests for codex-critic.sh. No live Codex calls: a fake `codex` is
# PATH-prepended. The contract under test is small on purpose — run the critic,
# print its verdict, append a GATE: directive, and refuse to run past the round
# budget.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/codex-critic.sh"
chmod +x "$HERE/stubs/codex" 2>/dev/null || true
export PATH="$HERE/stubs:$PATH"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
cd "$WS"

V() { printf '%s\n' "$@" > "$WS/verdict.txt"; export CODEX_STUB_VERDICT="$WS/verdict.txt"; }
CLEAN=("VERDICT: pass" "SUMMARY: s" "FINDINGS:" "- (none)")
IMPORTANT=("VERDICT: targeted-fixes" "SUMMARY: s" "FINDINGS:" "- [Important] x — y — z — w")
CRITICAL=("VERDICT: rewrite" "SUMMARY: s" "FINDINGS:" "- [Critical] x — y — z — w")

run() { # mode [env...] — stdin fed automatically
  local mode="$1"; shift
  rm -f "$WS/args.txt"
  echo "input" | env CODEX_STUB_ARGS="$WS/args.txt" "$@" bash "$SCRIPT" "$mode" \
    >"$WS/out.txt" 2>"$WS/err.txt"
  echo $? > "$WS/rc.txt"
}
gate() { grep -m1 '^GATE:' "$WS/out.txt" | sed 's/^GATE: //'; }

echo "--- GATE directive ---"
V "${CLEAN[@]}"
run spec
check "1a clean verdict -> GATE: pass"        '[ "$(gate)" = pass ]'
check "1b verdict block still printed intact" 'grep -q "^VERDICT: pass" out.txt'

V "${IMPORTANT[@]}"
run spec CODEX_CRITIC_ROUND=1 CODEX_CRITIC_MAX_ROUNDS=2
check "2a Important, budget left -> revise"   '[ "$(gate)" = revise ]'
check "2b revise names the next round"        'grep -q "round 2" err.txt'

V "${IMPORTANT[@]}"
run spec CODEX_CRITIC_ROUND=2 CODEX_CRITIC_MAX_ROUNDS=2
check "3a Important at last round -> final"   '[ "$(gate)" = final ]'
check "3b final says do not re-run"           'grep -q "do not re-run" err.txt'

V "${CRITICAL[@]}"
run spec CODEX_CRITIC_ROUND=2 CODEX_CRITIC_MAX_ROUNDS=2
check "4 Critical at last round -> final too" '[ "$(gate)" = final ]'

echo "--- round budget is a hard stop ---"
V "${CLEAN[@]}"
run spec CODEX_CRITIC_ROUND=3 CODEX_CRITIC_MAX_ROUNDS=2
check "5a past budget -> GATE: conclude"      '[ "$(gate)" = conclude ]'
check "5b past budget spends NO codex call"   '[ ! -f args.txt ]'
check "5c past budget still exits 0"          '[ "$(cat rc.txt)" = 0 ]'
check "5d past budget says FINAL"             'grep -q "FINAL" err.txt'

for m in plan code; do
  run "$m" CODEX_CRITIC_ROUND=9 CODEX_CRITIC_MAX_ROUNDS=2
  check "5e budget applies to seam '$m'"      '[ "$(gate)" = conclude ]'
done

# review/refute are not seams — they must never be budgeted away
run review CODEX_CRITIC_ROUND=9 CODEX_CRITIC_MAX_ROUNDS=2
check "5f review ignores the budget"          '[ -f args.txt ] && ! grep -q "^GATE:" out.txt'

echo "--- a non-clean token is never a pass, however findings are formatted ---"
# Regression: a count-only gate reported this as clean.
V "VERDICT: rewrite" "SUMMARY: fundamentally broken" "FINDINGS:" "* [Critical] wrong model — corrupts on write"
run spec CODEX_CRITIC_ROUND=1 CODEX_CRITIC_MAX_ROUNDS=2
check "10a unparsed findings + bad token -> revise" '[ "$(gate)" = revise ]'
check "10b warns the body must be read"             'grep -q "READ THE VERDICT BODY" err.txt'
V "VERDICT: targeted-fixes" "FINDINGS:" "- (none)"
run spec CODEX_CRITIC_ROUND=2 CODEX_CRITIC_MAX_ROUNDS=2
check "10c non-pass token at last round -> final"   '[ "$(gate)" = final ]'
V "VERDICT: PASS" "FINDINGS:" "- (none)"
run spec
check "10d token match is case-insensitive"         '[ "$(gate)" = pass ]'

echo "--- a malformed round must stop, never silently unbound the loop ---"
V "${IMPORTANT[@]}"
for bad in two junk 0 -1 1.5 ""; do
  run spec CODEX_CRITIC_ROUND="$bad"
  if [ "$bad" = "" ]; then
    check "11 empty ROUND defaults to 1"            '[ "$(gate)" = revise ]'
  else
    check "11 ROUND='$bad' -> exit 2, no GATE"      '[ "$(cat rc.txt)" = 2 ] && ! grep -q "^GATE:" out.txt'
  fi
done
run spec CODEX_CRITIC_MAX_ROUNDS=nope
check "11 MAX_ROUNDS non-numeric -> exit 2"         '[ "$(cat rc.txt)" = 2 ]'
check "11 malformed round spends no codex call"     '[ ! -f args.txt ]'

echo "--- broken codex is never a pass ---"
V "VERDICT: NEEDS-HUMAN" "SUMMARY: s"
run spec
check "6a NEEDS-HUMAN -> GATE: needs-human"   '[ "$(gate)" = needs-human ]'
V "garbled output, no verdict line"
run spec
check "6b no VERDICT line -> needs-human"     '[ "$(gate)" = needs-human ]'
run spec PATH="/usr/bin:/bin"
check "6c missing codex CLI -> exit 2"        '[ "$(cat rc.txt)" = 2 ] && grep -q "NEEDS-HUMAN" out.txt'
run bogus-mode
check "6d unknown mode -> exit 2"             '[ "$(cat rc.txt)" = 2 ]'

echo "--- passthrough fidelity (superlazy-review depends on it) ---"
printf 'VERDICT: pass\nline with  spaces\n\ntrailing blank above\n' > "$WS/verdict.txt"
export CODEX_STUB_VERDICT="$WS/verdict.txt"
echo "input" | bash "$SCRIPT" review > "$WS/rv.txt" 2>/dev/null
check "7 review output is byte-identical"     'cmp -s rv.txt verdict.txt'

echo "--- codex invocation flags ---"
V "${CLEAN[@]}"
run spec
check "8a read-only sandbox"                  'grep -qx -- "-s" args.txt && grep -qx "read-only" args.txt'
check "8b search on by default"               'grep -qx -- "--search" args.txt'
run spec CODEX_CRITIC_SEARCH=0
check "8c search disabled"                    '! grep -qx -- "--search" args.txt'
run spec CODEX_CRITIC_MODEL=other-model
check "8d CODEX_CRITIC_MODEL honored"         'grep -qx "other-model" args.txt'
run spec CODEX_CRITIC_MODEL=
check "8e empty model omits -m"               '! grep -qx -- "-m" args.txt'

echo "--- effort: high on every round ---"
run spec CODEX_CRITIC_ROUND=1
check "9a round 1 -> high"                    'grep -qx "model_reasoning_effort=high" args.txt'
run spec CODEX_CRITIC_ROUND=2 CODEX_CRITIC_MAX_ROUNDS=2
check "9b last round stays high"              'grep -qx "model_reasoning_effort=high" args.txt'
run spec CODEX_CRITIC_ROUND=2 CODEX_CRITIC_MAX_ROUNDS=3 CODEX_CRITIC_EFFORT=low
check "9c explicit effort wins"               'grep -qx "model_reasoning_effort=low" args.txt'
run review
check "9d non-seam is high too"               'grep -qx "model_reasoning_effort=high" args.txt'

echo
echo "codex-critic.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
