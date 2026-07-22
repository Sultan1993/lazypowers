#!/usr/bin/env bash
# codex-critic.sh — run a superlazy critic on OpenAI Codex instead of a Claude subagent.
#
# Usage:
#   codex-critic.sh <spec|plan|code|review|refute>      (crafted inputs piped on stdin)
#   codex-critic.sh verify [--spec-only] <plan.md>      (non-LLM sidecar validation)
#
# Seam modes (spec|plan|code) optionally write hash-bearing approval markers and
# the approval sidecar when MARKER_DIR is set — see the 2026-07-22 design spec.
# review/refute behave exactly as before (superlazy-review depends on them).
set -euo pipefail

mode="${1:?usage: codex-critic.sh <spec|plan|code|review|refute|verify>}"

# --- model config -------------------------------------------------------------
# Seam critics are PINNED to Sol: "Sol is the only critic" is a design
# requirement, so CODEX_CRITIC_MODEL is deliberately ignored for spec|plan|code.
# review/refute keep the override (superlazy-review's --codex-model uses it).
SEAM_MODEL="gpt-5.6-sol"
MODEL="${CODEX_CRITIC_MODEL-gpt-5.6-sol}"
# Reasoning effort. Coordinators set this per round (first pass high, re-reviews
# medium); default high.
EFFORT="${CODEX_CRITIC_EFFORT:-high}"
# Live web search. Default ON. Disable with CODEX_CRITIC_SEARCH=0.
case "${CODEX_CRITIC_SEARCH:-1}" in 0|false|no) SEARCH="" ;; *) SEARCH="--search" ;; esac
# -------------------------------------------------------------------------------

fail() { echo "VERDICT: NEEDS-HUMAN"; echo "codex-critic: $1" >&2; exit 2; }
warn() { echo "codex-critic: $1" >&2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
# repo-root-relative canonical path: strip root prefix, ./, collapse //
canon() {
  local p="$1" root; root="$(repo_root)"
  p="${p#"$root"/}"
  printf '%s' "$p" | sed -e 's#\\#/#g' -e 's#^\./##' -e 's#//*#/#g'
}
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# atomic write: temp file in same dir + rename
atomic_write() { # $1=path $2=content
  local tmp; tmp="$(mktemp "$(dirname "$1")/.tmp.XXXXXX")"
  printf '%s\n' "$2" > "$tmp"
  mv -f "$tmp" "$1"
}

# ---- marker helpers ------------------------------------------------------------
SPEC_MARKER="spec-critic.passed"
PLAN_MARKER="plan-critic.passed"
CODE_MARKER="code-critic.passed"
sidecar_path() { printf '%s' "${1}.approved.json"; }

invalidate() { # $1 = mode being run — delete own marker + downstream
  [ -n "${MARKER_DIR:-}" ] || return 0
  case "$1" in
    spec)
      rm -f "$MARKER_DIR/$SPEC_MARKER" "$MARKER_DIR/$PLAN_MARKER"
      [ -n "${PLAN_PATH:-}" ] && rm -f "$(sidecar_path "$PLAN_PATH")" || true ;;
    plan)
      rm -f "$MARKER_DIR/$PLAN_MARKER"
      [ -n "${PLAN_PATH:-}" ] && rm -f "$(sidecar_path "$PLAN_PATH")" || true ;;
    code)
      rm -f "$MARKER_DIR/$CODE_MARKER" ;;
  esac
}

# ---- plan-markdown schema validation + plan/tasks equivalence --------------------
# Canonical TaskCreate source is the plan MARKDOWN; tasks.json is its mirror.
validate_plan_artifacts() { # $1=plan.md $2=tasks.json  → 0 ok / 1 violations (stderr)
  python3 - "$1" "$2" <<'PYEOF'
import json, re, sys
plan_path, tasks_path = sys.argv[1], sys.argv[2]
errs = []
src = open(plan_path, encoding='utf-8').read()
# Parse per TASK SECTION with a FENCE-AWARE line walk — a heading only counts
# when it is not inside a ``` code fence (a fenced '### Task' example must not
# mint approval), and ONLY '### Task\b' headings start a section; auxiliary H3
# sections (### Notes, ...) neither count as tasks nor invalidate valid ones.
lines = src.splitlines()
sections = []          # list of [start, end) line ranges
in_code = False
cur = None
for n, line in enumerate(lines):
    if line.startswith('```'):
        in_code = not in_code
        continue
    if in_code:
        continue
    if re.match(r'^### Task\b', line):
        if cur is not None: sections.append((cur, n))
        cur = n
    elif re.match(r'^##+ ', line):  # any other unfenced H2/H3 ends a section
        if cur is not None: sections.append((cur, n)); cur = None
if cur is not None: sections.append((cur, len(lines)))
if not sections:
    errs.append("plan markdown contains no '### Task' sections")
fences_md = []
for i, (a, b) in enumerate(sections):
    body = '\n'.join(lines[a:b])
    found = re.findall(r'```json:metadata\n(.*?)\n```', body, re.S)
    if len(found) != 1:
        errs.append(f"plan task section {i}: expected exactly one json:metadata fence, found {len(found)}")
        fences_md.append(found[0] if found else None)
    else:
        fences_md.append(found[0])
parsed_md = []
for i, f in enumerate(fences_md):
    if f is None:
        parsed_md.append(None); continue
    try:
        m = json.loads(f)
    except Exception as e:
        errs.append(f"plan task {i}: fence unparseable: {e}"); parsed_md.append(None); continue
    parsed_md.append(f)
    if m.get("modelTier") not in ("mechanical", "standard", "frontier"):
        errs.append(f"plan task {i}: modelTier invalid: {m.get('modelTier')!r}")
    if not isinstance(m.get("files"), list):
        errs.append(f"plan task {i}: files must be an array")
    if not str(m.get("verifyCommand") or "").strip():
        errs.append(f"plan task {i}: verifyCommand missing/blank")
    ac = m.get("acceptanceCriteria")
    if not isinstance(ac, list) or not ac:
        errs.append(f"plan task {i}: acceptanceCriteria missing/empty")
try:
    tj = json.load(open(tasks_path, encoding='utf-8'))
    tasks = tj.get("tasks", [])
except Exception as e:
    errs.append(f"tasks.json unparseable: {e}"); tasks = None
if tasks is not None:
    if len(tasks) != len(fences_md):
        errs.append(f"task count mismatch: plan has {len(fences_md)}, tasks.json has {len(tasks)}")
    else:
        for i, t in enumerate(tasks):
            m = re.search(r'```json:metadata\n(.*?)\n```', t.get("description", ""), re.S)
            if not m:
                errs.append(f"tasks.json task {i}: no json:metadata fence")
            elif parsed_md[i] is not None and m.group(1) != parsed_md[i]:
                errs.append(f"tasks.json task {i}: fence diverges from plan markdown (equivalence)")
for e in errs: print(e, file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF
}

# ==================================================================================
# verify mode — non-LLM: validate sidecar, mint session markers
# ==================================================================================
if [ "$mode" = "verify" ]; then
  spec_only=""
  if [ "${2:-}" = "--spec-only" ]; then spec_only=1; shift; fi
  plan="${2:?usage: codex-critic.sh verify [--spec-only] <plan.md>}"
  [ -n "${MARKER_DIR:-}" ] || fail "verify requires MARKER_DIR"
  tasks="${plan}.tasks.json"
  side="$(sidecar_path "$plan")"

  # self-invalidate before validating — a failed verify must not leave stale approvals
  if [ -n "$spec_only" ]; then rm -f "$MARKER_DIR/$SPEC_MARKER"
  else rm -f "$MARKER_DIR/$SPEC_MARKER" "$MARKER_DIR/$PLAN_MARKER"; fi

  [ -f "$side" ] || { warn "no sidecar at $side"; exit 3; }
  for field in planHash tasksHash specPath specHash; do
    v="$(jq -er ".$field" "$side" 2>/dev/null)" || { warn "sidecar missing/unparseable field: $field"; exit 3; }
    eval "SC_$field=\"\$v\""
  done
  root="$(repo_root)"
  spec_file="$root/$SC_specPath"
  [ -f "$spec_file" ] || { warn "spec not found at $SC_specPath"; exit 3; }
  [ "$(sha "$spec_file")" = "$SC_specHash" ] || { warn "spec bytes changed since approval"; exit 3; }

  if [ -z "$spec_only" ]; then
    [ -f "$plan" ] && [ -f "$tasks" ] || { warn "plan or tasks file missing"; exit 3; }
    [ "$(sha "$plan")"  = "$SC_planHash"  ] || { warn "plan bytes changed since approval"; exit 3; }
    [ "$(sha "$tasks")" = "$SC_tasksHash" ] || { warn "tasks bytes changed since approval"; exit 3; }
    sc_commit="$(jq -r '.commit // empty' "$side")"
    [ -n "$sc_commit" ] && [ "$sc_commit" != "$(git rev-parse HEAD 2>/dev/null)" ] \
      && warn "approved at commit ${sc_commit:0:12}, HEAD differs — drift warning only"
    atomic_write "$MARKER_DIR/$SPEC_MARKER" "$(jq -n --arg p "$SC_specPath" --arg h "$SC_specHash" '{specPath:$p, specHash:$h}')"
    atomic_write "$MARKER_DIR/$PLAN_MARKER" "$(jq -n --arg pp "$(canon "$plan")" --arg ph "$SC_planHash" --arg th "$SC_tasksHash" --arg sp "$SC_specPath" --arg sh "$SC_specHash" \
      '{planPath:$pp, planHash:$ph, tasksHash:$th, specPath:$sp, specHash:$sh}')"
  else
    atomic_write "$MARKER_DIR/$SPEC_MARKER" "$(jq -n --arg p "$SC_specPath" --arg h "$SC_specHash" '{specPath:$p, specHash:$h}')"
  fi
  echo "VERIFIED"
  exit 0
fi

# ==================================================================================
# LLM modes — spec | plan | code | review | refute
# ==================================================================================
case "$mode" in spec|plan|code|review|refute) ;; *) fail "unknown mode '$mode'" ;; esac

prompt_file="$here/../agents/superlazy-${mode}-critic.md"
seam=""
case "$mode" in spec|plan|code) seam=1 ;; esac

# seam modes self-invalidate BEFORE anything else (even wrapper failures must not
# leave a stale approval standing)
[ -n "$seam" ] && invalidate "$mode"

[ -f "$prompt_file" ] || fail "no prompt file at $prompt_file (critic='$mode')"
command -v codex >/dev/null 2>&1 || fail "codex CLI not found on PATH — install @openai/codex and 'codex login'"

# critic instructions = file with the leading YAML frontmatter removed
body="$(awk 'NR==1 && /^---/{f=1; next} f && /^---/{f=0; next} !f' "$prompt_file")"
inputs="$(cat)"   # coordinator pipes: doc paths, brief, diff range, what-changed

prompt="${body}

## Your assignment (inputs from the coordinator)
${inputs}

Read whatever files, paths, or git ranges are referenced above to perform the
review yourself. Do NOT modify any files. Output ONLY the VERDICT block in the
exact format specified above — no preamble, no text after it."

# review/refute: BYTE-PERFECT pass-through via exec — no capture, no marker
# logic (command substitution would strip trailing newlines; superlazy-review
# consumes this output verbatim). Seam modes below capture instead, because
# they must parse the verdict after printing it.
# NOTE: --search is a TOP-LEVEL codex flag, so it goes BEFORE `exec`.
if [ -z "$seam" ]; then
  if [ -n "$MODEL" ]; then
    exec codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" -m "$MODEL" "$prompt"
  else
    exec codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" "$prompt"
  fi
fi

out="$(codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" -m "$SEAM_MODEL" "$prompt")"
printf '%s\n' "$out"

[ -n "${MARKER_DIR:-}" ] || exit 0

# ---- clean check: exact pass token AND zero Critical/Important -------------------
verdict_line="$(printf '%s\n' "$out" | grep -m1 '^VERDICT:' || true)"
token="$(printf '%s' "$verdict_line" | sed -n 's/^VERDICT:[[:space:]]*\([a-zA-Z-]*\).*/\1/p')"
crit=$(printf '%s\n' "$out" | grep -c '^- \[Critical\]' || true)
imp=$(printf '%s\n' "$out" | grep -c '^- \[Important\]' || true)
if [ "$token" != "pass" ] || [ "$crit" -ne 0 ] || [ "$imp" -ne 0 ]; then
  warn "not clean (token='$token' critical=$crit important=$imp) — no approval written"
  exit 0
fi

# ---- clean: write approvals ------------------------------------------------------
case "$mode" in
  spec)
    [ -n "${SPEC_PATH:-}" ] || { warn "clean verdict but SPEC_PATH unset — cannot write spec marker"; exit 0; }
    [ -f "$SPEC_PATH" ] || { warn "SPEC_PATH not found: $SPEC_PATH"; exit 0; }
    atomic_write "$MARKER_DIR/$SPEC_MARKER" \
      "$(jq -n --arg p "$(canon "$SPEC_PATH")" --arg h "$(sha "$SPEC_PATH")" '{specPath:$p, specHash:$h}')"
    ;;
  plan)
    [ -n "${PLAN_PATH:-}" ] && [ -n "${SPEC_PATH:-}" ] || { warn "clean verdict but PLAN_PATH/SPEC_PATH unset — cannot write approval"; exit 0; }
    tasks="${PLAN_PATH}.tasks.json"
    [ -f "$PLAN_PATH" ] && [ -f "$tasks" ] && [ -f "$SPEC_PATH" ] || { warn "plan/tasks/spec file missing"; exit 0; }
    # seam ordering: spec marker must exist AND match current spec bytes
    if [ ! -s "$MARKER_DIR/$SPEC_MARKER" ]; then
      warn "spec-critic.passed missing — Seam 1 has not passed; no sidecar written"; exit 0
    fi
    m_hash="$(jq -er '.specHash' "$MARKER_DIR/$SPEC_MARKER" 2>/dev/null)" \
      || { warn "spec marker unparseable — treating as absent; no sidecar written"; exit 0; }
    cur_hash="$(sha "$SPEC_PATH")"
    [ "$m_hash" = "$cur_hash" ] || { warn "spec bytes changed since Seam 1 (edit-between-seams) — re-run spec critic"; exit 0; }
    # deterministic schema validation on the CANONICAL source + equivalence
    if ! validate_plan_artifacts "$PLAN_PATH" "$tasks"; then
      warn "plan/tasks schema or equivalence violations — no approval written"; exit 0
    fi
    spec_rel="$(canon "$SPEC_PATH")"
    plan_hash="$(sha "$PLAN_PATH")"; tasks_hash="$(sha "$tasks")"
    commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    # sidecar FIRST, marker LAST (marker authorizes execution → final commit)
    atomic_write "$(sidecar_path "$PLAN_PATH")" \
      "$(jq -n --arg ph "$plan_hash" --arg th "$tasks_hash" --arg sp "$spec_rel" --arg sh "$cur_hash" --arg c "$commit" \
        '{planHash:$ph, tasksHash:$th, specPath:$sp, specHash:$sh, commit:$c, seams:["spec","plan"]}')"
    atomic_write "$MARKER_DIR/$PLAN_MARKER" \
      "$(jq -n --arg pp "$(canon "$PLAN_PATH")" --arg ph "$plan_hash" --arg th "$tasks_hash" --arg sp "$spec_rel" --arg sh "$cur_hash" \
        '{planPath:$pp, planHash:$ph, tasksHash:$th, specPath:$sp, specHash:$sh}')"
    ;;
  code)
    atomic_write "$MARKER_DIR/$CODE_MARKER" "{}"
    ;;
esac
exit 0
