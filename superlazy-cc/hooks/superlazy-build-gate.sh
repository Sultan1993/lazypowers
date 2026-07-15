#!/usr/bin/env bash
# superlazy-build-gate.sh — PreToolUse gate for the superlazy-build pipeline.
# Denies advancing to the next superpowers stage until the prior critic's
# marker exists. The run owned by THIS session is found by matching the
# hook's session_id against .superlazy-build/*/session, skipping runs with
# a terminal .done marker. No-op when this session owns no active run.
set -euo pipefail

input="$(cat)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
[ "$tool_name" = "Skill" ] || { printf '{}'; exit 0; }

# The Skill tool's target skill name (handles plugin-namespaced ids).
skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // .tool_input.command // empty')"
[ -n "$skill" ] || { printf '{}'; exit 0; }

# Run relative to the project the tool call happened in.
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$session_id" ] || { printf '{}'; exit 0; }

# Active run bound to this session; newest dir mtime wins if several.
# Run dirs without a `session` file and legacy `.superlazy-build/current`
# pointers are ignored.
mdir=""
mdir_mtime=-1
for d in .superlazy-build/*/; do
  if [ ! -f "${d}session" ] || [ -f "${d}.done" ]; then continue; fi
  [ "$(cat "${d}session" 2>/dev/null)" = "$session_id" ] || continue
  mtime="$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo 0)"
  if [ "$mtime" -gt "$mdir_mtime" ]; then
    mdir="${d%/}"
    mdir_mtime="$mtime"
  fi
done
[ -n "$mdir" ] || { printf '{}'; exit 0; }   # no active run in this session -> allow

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

case "$skill" in
  *writing-plans*)
    [ -f "${mdir}/spec-critic.passed" ] || \
      deny "superlazy-build: SEAM 1 not cleared — run superlazy-spec-critic on the design spec and resolve Critical/Important findings before writing-plans."
    ;;
  *subagent-driven-development*|*executing-plans*)
    [ -f "${mdir}/plan-critic.passed" ] || \
      deny "superlazy-build: SEAM 2 not cleared — run superlazy-plan-critic on the plan and clear Critical/Important findings before execution."
    ;;
esac

printf '{}'   # allow
