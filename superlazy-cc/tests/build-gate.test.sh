#!/usr/bin/env bash
# Direct-invocation tests for superlazy-build-gate.sh — spec cases 18–22.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/superlazy-build-gate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
cd "$WS"
git init -q .; git commit -q --allow-empty -m init

SID="test-session-1"
RUN=".superlazy-build/run1"
mkdir -p "$RUN" docs
echo "$SID" > "$RUN/session"

PLAN="docs/plan.md";  echo "the plan"  > "$PLAN"
TASKS="$PLAN.tasks.json"; echo '{"tasks":[]}' > "$TASKS"
SPEC="docs/spec.md";  echo "the spec"  > "$SPEC"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

good_marker() {
  jq -n --arg pp "$PLAN" --arg ph "$(sha "$PLAN")" --arg th "$(sha "$TASKS")" \
        --arg sp "$SPEC" --arg sh "$(sha "$SPEC")" \
        '{planPath:$pp, planHash:$ph, tasksHash:$th, specPath:$sp, specHash:$sh}' \
    > "$RUN/plan-critic.passed"
}

invoke() { # $1 = args string for the Skill call → prints "allow" or "deny"
  local out
  out="$(jq -n --arg sid "$SID" --arg cwd "$WS" --arg args "${1:-}" \
    '{tool_name:"Skill", session_id:$sid, cwd:$cwd,
      tool_input:{skill:"superpowers-extended-cc:subagent-driven-development", args:$args}}' \
    | bash "$HOOK")"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo deny
  else
    echo allow
  fi
}
expect() { # $1 desc, $2 want, $3 args
  local got; got="$(invoke "$3")"
  [ "$got" = "$2" ] && ok "$1" || bad "$1 (want $2, got $got)"
}

# 18: intact + exact planPath= → allow
good_marker
expect "18 intact marker + exact planPath → allow" allow "planPath=$PLAN"

# 19: each file flipped independently → deny
echo "x" >> "$PLAN";  good_marker_stale=1
expect "19a plan byte flipped → deny" deny "planPath=$PLAN"
git checkout -q -- "$PLAN" 2>/dev/null || echo "the plan" > "$PLAN"; good_marker
echo "x" >> "$TASKS"
expect "19b tasks byte flipped → deny" deny "planPath=$PLAN"
echo '{"tasks":[]}' > "$TASKS"; good_marker
echo "x" >> "$SPEC"
expect "19c spec byte flipped → deny" deny "planPath=$PLAN"
echo "the spec" > "$SPEC"; good_marker

# 20: EMPTY legacy marker → allow (existence-only, no path binding)
: > "$RUN/plan-critic.passed"
expect "20a empty legacy marker → allow" allow ""
printf '  \n' > "$RUN/plan-critic.passed"
expect "20b whitespace-only marker → allow (legacy)" allow ""

# 21: corrupt / missing-field non-empty markers → deny
echo '{not json' > "$RUN/plan-critic.passed"
expect "21a corrupt JSON marker → deny" deny "planPath=$PLAN"
jq -n --arg pp "$PLAN" '{planPath:$pp}' > "$RUN/plan-critic.passed"
expect "21b missing-field marker → deny" deny "planPath=$PLAN"

# 22: structured planPath binding
good_marker
cp "$PLAN" "docs/plan-v2.md"; cp "$TASKS" "docs/plan-v2.md.tasks.json"
expect "22a planPath= names plan B → deny" deny "planPath=docs/plan-v2.md"
expect "22b path extending A's filename → deny" deny "planPath=${PLAN%.md}-v2.md"
expect "22c both paths present, planPath= = B → deny" deny "see $PLAN planPath=docs/plan-v2.md"
expect "22d missing planPath= argument → deny" deny "run the plan at $PLAN please"
expect "22e canonicalized exact match → allow" allow "planPath=./docs//plan.md"

# no marker at all → deny (pre-existing behavior)
rm -f "$RUN/plan-critic.passed"
expect "seam2 missing marker → deny" deny "planPath=$PLAN"

# writing-plans arm untouched: spec marker gates it, empty is fine
: > "$RUN/spec-critic.passed"
out="$(jq -n --arg sid "$SID" --arg cwd "$WS" \
  '{tool_name:"Skill", session_id:$sid, cwd:$cwd, tool_input:{skill:"superpowers-extended-cc:writing-plans"}}' | bash "$HOOK")"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  bad "writing-plans arm regressed"
else
  ok "writing-plans arm untouched"
fi

echo
echo "build-gate.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
