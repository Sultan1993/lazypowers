#!/usr/bin/env bash
# Stub-based tests for codex-critic.sh — spec acceptance cases 1–17 (+11b).
# No live Codex calls: a fake `codex` is PATH-prepended.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/codex-critic.sh"
chmod +x "$HERE/stubs/codex" 2>/dev/null || true
export PATH="$HERE/stubs:$PATH"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- workspace ------------------------------------------------------------------
WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
cd "$WS"
git init -q .; git commit -q --allow-empty -m init

mkdir -p run docs
SPEC="docs/spec.md";  echo "# the spec" > "$SPEC"
PLAN="docs/plan.md"
TASKS="$PLAN.tasks.json"
SIDE="$PLAN.approved.json"

FENCE='{"files": ["src/a.js"], "modelTier": "mechanical", "verifyCommand": "true", "acceptanceCriteria": ["a"]}'
write_plan() { # $1 = fence json for task 0
  printf 'Spec: docs/spec.md\n\n### Task 1: t\n**Goal:** g\n\n```json:metadata\n%s\n```\n' "$1" > "$PLAN"
  python3 -c "
import json,sys
fence=sys.argv[1]
desc='**Goal:** g\n\n\`\`\`json:metadata\n'+fence+'\n\`\`\`'
json.dump({'planPath':'docs/plan.md','tasks':[{'id':0,'subject':'Task 1: t','status':'pending','description':desc}]},open('$TASKS','w'))
" "$1"
}
write_plan "$FENCE"

V() { printf '%s\n' "$@" > "$WS/verdict.txt"; export CODEX_STUB_VERDICT="$WS/verdict.txt"; }
CLEAN=("VERDICT: pass" "SUMMARY: s" "FINDINGS:" "- (none)")
run() { # mode [env...]  — stdin fed automatically
  local mode="$1"; shift
  echo "input" | env MARKER_DIR="$WS/run" "$@" bash "$SCRIPT" "$mode" >"$WS/out.txt" 2>"$WS/err.txt"
}

# --- case 1: pass + zero counts → spec marker written ------------------------------
V "${CLEAN[@]}"
run spec SPEC_PATH="$SPEC"
check "1 clean spec writes marker" '[ -s run/spec-critic.passed ]'
check "10a marker is JSON with specHash" 'jq -e ".specHash and .specPath" run/spec-critic.passed >/dev/null'
check "10b specHash correct" '[ "$(jq -r .specHash run/spec-critic.passed)" = "$(shasum -a 256 "$SPEC" | cut -d" " -f1)" ]'

# --- case 2: pass token but 1 Important → nothing ---------------------------------
rm -f run/*
V "VERDICT: pass" "SUMMARY: s" "FINDINGS:" "- [Important] x — y — z — w"
run spec SPEC_PATH="$SPEC"
check "2 pass+Important writes nothing" '[ ! -e run/spec-critic.passed ]'

# --- case 3: every non-pass token → nothing ----------------------------------------
for tok in "VERDICT: targeted-fixes" "VERDICT: rewrite" "VERDICT: NEEDS-HUMAN" "NO VERDICT LINE" "VERDICT: pAsS?"; do
  rm -f run/*
  V "$tok" "SUMMARY: s" "FINDINGS:" "- (none)"
  run spec SPEC_PATH="$SPEC"
  [ ! -e run/spec-critic.passed ] || { bad "3 token '$tok' wrote marker"; continue; }
done
ok "3 non-pass tokens write nothing"

# --- case 4: self-invalidation ------------------------------------------------------
echo '{"specPath":"stale","specHash":"stale"}' > run/spec-critic.passed
echo '{"stale":true}' > run/plan-critic.passed
echo '{"stale":true}' > "$SIDE"
V "VERDICT: rewrite" "FINDINGS:" "- [Critical] x — y — z — w"
run spec SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "4a failing spec run cleared stale spec marker" '[ ! -e run/spec-critic.passed ]'
check "4b failing spec run cleared downstream plan marker" '[ ! -e run/plan-critic.passed ]'
check "4c failing spec run cleared sidecar" '[ ! -e "$SIDE" ]'
# plan invalidation leaves spec marker alone
V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"           # mint a real spec marker
echo '{"stale":true}' > run/plan-critic.passed
V "VERDICT: rewrite" "FINDINGS:" "- [Critical] x — y — z — w"
run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "4d failing plan run cleared plan marker" '[ ! -e run/plan-critic.passed ]'
check "4e failing plan run kept spec marker" '[ -s run/spec-critic.passed ]'

# --- case 5: plan clean without spec marker → nothing -------------------------------
rm -f run/*
V "${CLEAN[@]}"
run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "5 plan without spec marker writes nothing" '[ ! -e run/plan-critic.passed ] && [ ! -e "$SIDE" ]'
check "5b stderr explains" 'grep -q "Seam 1" err.txt'

# --- case 6: plan clean with spec marker → sidecar then marker ----------------------
rm -f run/* "$SIDE"
V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"
V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "6a sidecar written" '[ -s "$SIDE" ]'
check "6b plan marker written" '[ -s run/plan-critic.passed ]'
check "6c sidecar hashes correct" '[ "$(jq -r .planHash "$SIDE")" = "$(shasum -a 256 "$PLAN" | cut -d" " -f1)" ] && [ "$(jq -r .tasksHash "$SIDE")" = "$(shasum -a 256 "$TASKS" | cut -d" " -f1)" ]'
check "6d sidecar binds spec" '[ "$(jq -r .specPath "$SIDE")" = "docs/spec.md" ] && [ "$(jq -r .specHash "$SIDE")" = "$(shasum -a 256 "$SPEC" | cut -d" " -f1)" ]'
check "6e sidecar not younger than marker" 'python3 -c "import os,sys; sys.exit(0 if os.stat(\"$SIDE\").st_mtime_ns <= os.stat(\"run/plan-critic.passed\").st_mtime_ns else 1)"'
check "6f marker carries all five fields" 'jq -e ".planPath and .planHash and .tasksHash and .specPath and .specHash" run/plan-critic.passed >/dev/null'

# --- case 7: plan-md schema violations → nothing -------------------------------------
for badfence in \
  '{"files": ["a"], "verifyCommand": "true", "acceptanceCriteria": ["a"]}' \
  '{"files": ["a"], "modelTier": "mechanical", "verifyCommand": "  ", "acceptanceCriteria": ["a"]}' \
  '{"files": ["a"], "modelTier": "mechanical", "verifyCommand": "true", "acceptanceCriteria": []}'; do
  rm -f run/* "$SIDE"; write_plan "$badfence"
  V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"
  V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
  [ ! -e "$SIDE" ] || bad "7 schema violation approved: $badfence"
done
ok "7 plan-md schema violations write nothing"
write_plan "$FENCE"

# --- case 7b: equivalence violation → nothing ----------------------------------------
rm -f run/* "$SIDE"
python3 -c "
import json
d=json.load(open('$TASKS')); d['tasks'][0]['description']=d['tasks'][0]['description'].replace('mechanical','standard')
json.dump(d,open('$TASKS','w'))
"
V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"
V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "7b divergent mirror rejected" '[ ! -e "$SIDE" ] && grep -q equivalence err.txt'
write_plan "$FENCE"

# --- case 9: edit-between-seams → nothing --------------------------------------------
rm -f run/* "$SIDE"
V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"
echo "edited after seam 1" >> "$SPEC"
V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "9 edit-between-seams rejected" '[ ! -e "$SIDE" ] && grep -qi "edit-between-seams\|changed since Seam 1" err.txt'
echo "# the spec" > "$SPEC"

# --- case 8: no MARKER_DIR → no side effects; review passthrough ----------------------
rm -f run/*
V "${CLEAN[@]}"
echo "input" | bash "$SCRIPT" spec > out.txt 2>err.txt
check "8a no MARKER_DIR writes nothing" '[ -z "$(ls -A run)" ]'
check "8b stdout carries verdict verbatim" 'grep -q "^VERDICT: pass" out.txt'
V "VERDICT: NEEDS-HUMAN" "whatever"
echo "input" | bash "$SCRIPT" review > out.txt 2>err.txt
check "8c review mode passes output through" 'grep -q "NEEDS-HUMAN" out.txt'
# byte-identity: review output must equal the stub's bytes exactly, including
# a missing trailing newline (command substitution would destroy this)
printf '{"findings":[]}' > "$WS/verdict.txt"        # deliberately NO trailing \n
echo "input" | bash "$SCRIPT" review > out.txt 2>err.txt
check "8d review mode is byte-identical (no trailing-newline mangling)" 'cmp -s out.txt "$WS/verdict.txt"'
V "${CLEAN[@]}"

# --- case 11: model pinning ------------------------------------------------------------
V "${CLEAN[@]}"
export CODEX_STUB_ARGS="$WS/args.txt"
run spec SPEC_PATH="$SPEC" CODEX_CRITIC_MODEL=other-model
check "11a seam mode pins gpt-5.6-sol" 'grep -qx "gpt-5.6-sol" args.txt && ! grep -qx "other-model" args.txt'
echo "input" | env CODEX_CRITIC_MODEL=other-model bash "$SCRIPT" review >/dev/null 2>&1
check "11b review honors CODEX_CRITIC_MODEL" 'grep -qx "other-model" args.txt'

# --- case 11b: effort + search propagation ----------------------------------------------
run spec SPEC_PATH="$SPEC" CODEX_CRITIC_EFFORT=medium
check "11c effort medium propagates" 'grep -qx "model_reasoning_effort=medium" args.txt'
run spec SPEC_PATH="$SPEC" CODEX_CRITIC_EFFORT=high
check "11d effort high propagates" 'grep -qx "model_reasoning_effort=high" args.txt'
check "11e search on by default" 'grep -qx -- "--search" args.txt'
run spec SPEC_PATH="$SPEC" CODEX_CRITIC_SEARCH=0
check "11f search disabled" '! grep -qx -- "--search" args.txt'
unset CODEX_STUB_ARGS

# --- cases 12–15: verify ------------------------------------------------------------------
rm -f run/* "$SIDE"
V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"
V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"   # mint a real sidecar
rm -f run/*
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" > out.txt 2>err.txt
check "12 verify valid: exit 0 + VERIFIED + both markers" '[ $? -eq 0 ] && grep -q VERIFIED out.txt && [ -s run/spec-critic.passed ] && [ -s run/plan-critic.passed ]'

echo "flip" >> "$PLAN"
echo '{"stale":true}' > run/spec-critic.passed; echo '{"stale":true}' > run/plan-critic.passed
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" >/dev/null 2>&1; rc=$?
check "13a flipped plan byte: exit 3" '[ $rc -eq 3 ]'
check "13b pre-seeded markers gone after failed verify" '[ ! -e run/spec-critic.passed ] && [ ! -e run/plan-critic.passed ]'
git checkout -q -- . 2>/dev/null || write_plan "$FENCE"
# restore approved state
rm -f run/* "$SIDE"; V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"; V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"

echo "flip" >> "$TASKS"
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" >/dev/null 2>&1
check "13c flipped tasks byte: exit 3" '[ $? -eq 3 ]'
rm -f run/* "$SIDE"; write_plan "$FENCE"; V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"; V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"

echo "flip" >> "$SPEC"
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" >/dev/null 2>&1
check "14a flipped spec byte: exit 3" '[ $? -eq 3 ]'
echo "# the spec" > "$SPEC"
rm -f run/* "$SIDE"; V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"; V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"

echo '{"planHash":"x"}' > "$SIDE"   # legacy/missing-field sidecar
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" >/dev/null 2>&1
check "14b legacy sidecar missing fields: exit 3" '[ $? -eq 3 ]'
rm -f run/* "$SIDE"; V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"; V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"

git commit -q --allow-empty -m drift
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" > out.txt 2>err.txt
check "15 commit drift: exit 0 + warning" '[ $? -eq 0 ] && grep -qi drift err.txt'

# --- case 16: --spec-only --------------------------------------------------------------------
rm -f run/*
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify --spec-only "$PLAN" >/dev/null 2>&1
check "16a spec-only mints only spec marker" '[ $? -eq 0 ] && [ -s run/spec-critic.passed ] && [ ! -e run/plan-critic.passed ]'
echo "changed" >> "$SPEC"
echo '{"stale":true}' > run/spec-critic.passed
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify --spec-only "$PLAN" >/dev/null 2>&1; rc=$?
check "16b spec changed: exit 3 + stale spec marker gone" '[ $rc -eq 3 ] && [ ! -e run/spec-critic.passed ]'
echo "# the spec" > "$SPEC"

# --- case 17: re-bless composition ------------------------------------------------------------
rm -f run/* "$SIDE"; V "${CLEAN[@]}"; run spec SPEC_PATH="$SPEC"; V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
printf '\n<!-- coordinator edit -->\n' >> "$PLAN"   # stale the sidecar
python3 -c "
import json
d=json.load(open('$TASKS'))
json.dump(d,open('$TASKS','w'))
"
rm -f run/*
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify "$PLAN" >/dev/null 2>&1
check "17a stale plan: verify exit 3" '[ $? -eq 3 ]'
env MARKER_DIR="$WS/run" bash "$SCRIPT" verify --spec-only "$PLAN" >/dev/null 2>&1
check "17b spec-only carries spec approval forward" '[ $? -eq 0 ] && [ -s run/spec-critic.passed ]'
V "${CLEAN[@]}"; run plan SPEC_PATH="$SPEC" PLAN_PATH="$PLAN"
check "17c clean plan re-bless: fresh sidecar + both markers" '[ -s "$SIDE" ] && [ -s run/plan-critic.passed ] && [ -s run/spec-critic.passed ]'
check "17d fresh sidecar matches edited plan bytes" '[ "$(jq -r .planHash "$SIDE")" = "$(shasum -a 256 "$PLAN" | cut -d" " -f1)" ]'

echo
echo "codex-critic.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
