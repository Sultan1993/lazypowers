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
    marker="${mdir}/plan-critic.passed"
    [ -f "$marker" ] || \
      deny "superlazy-build: SEAM 2 not cleared — run superlazy-plan-critic on the plan and clear Critical/Important findings before execution."
    # Hash-bearing marker validation (1.6.0):
    #  - EMPTY marker (zero bytes / whitespace-only) = legacy existence-only, allow.
    #  - Non-empty marker MUST parse as JSON with all five fields, else DENY
    #    (corruption never downgrades to legacy authorization).
    #  - Recompute plan/tasks/spec hashes and DENY on any mismatch.
    #  - The Skill invocation must carry exactly one structured `planPath=<path>`
    #    argument equal (canonicalized) to the marker's planPath — never
    #    substring-search the invocation text.
    if [ -n "$(tr -d '[:space:]' < "$marker" 2>/dev/null)" ]; then
      root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      canon() { printf '%s' "$1" | sed -e 's#\\#/#g' -e 's#^\./##' -e 's#//*#/#g'; }
      m_planPath="$(jq -er '.planPath'  "$marker" 2>/dev/null)" || deny "superlazy-build: corrupt approval marker (plan-critic.passed is non-empty but not valid approval JSON) — re-run the plan critic."
      m_planHash="$(jq -er '.planHash'  "$marker" 2>/dev/null)" || deny "superlazy-build: approval marker missing planHash — re-run the plan critic."
      m_tasksHash="$(jq -er '.tasksHash' "$marker" 2>/dev/null)" || deny "superlazy-build: approval marker missing tasksHash — re-run the plan critic."
      m_specPath="$(jq -er '.specPath'  "$marker" 2>/dev/null)" || deny "superlazy-build: approval marker missing specPath — re-run the plan critic."
      m_specHash="$(jq -er '.specHash'  "$marker" 2>/dev/null)" || deny "superlazy-build: approval marker missing specHash — re-run the plan critic."
      for f in "$m_planPath" "${m_planPath}.tasks.json" "$m_specPath"; do
        [ -f "$root/$f" ] || deny "superlazy-build: approved file missing on disk: $f — re-run the plan critic."
      done
      sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
      [ "$(sha "$root/$m_planPath")" = "$m_planHash" ] || \
        deny "superlazy-build: PLAN changed after approval ($m_planPath) — re-bless via the plan critic before executing."
      [ "$(sha "$root/${m_planPath}.tasks.json")" = "$m_tasksHash" ] || \
        deny "superlazy-build: TASKS changed after approval (${m_planPath}.tasks.json) — re-bless via the plan critic before executing."
      [ "$(sha "$root/$m_specPath")" = "$m_specHash" ] || \
        deny "superlazy-build: SPEC changed after approval ($m_specPath) — re-run the seams before executing."
      # structured planPath= argument, exact equality after canonicalization
      args="$(printf '%s' "$input" | jq -r '.tool_input.args // empty')"
      inv_path="$(printf '%s' "$args" | grep -oE 'planPath=[^[:space:]]+' | head -1 | cut -d= -f2- || true)"
      [ -n "$inv_path" ] || \
        deny "superlazy-build: execution must name the approved plan — invoke sdd with a 'planPath=$m_planPath' argument."
      [ "$(canon "$inv_path")" = "$(canon "$m_planPath")" ] || \
        deny "superlazy-build: invocation names '$inv_path' but the approval is for '$m_planPath' — approved plan and executed plan must be identical."
    fi
    ;;
esac

printf '{}'   # allow
