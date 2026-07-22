#!/usr/bin/env bash
# codex-critic.sh — run a superlazy critic on OpenAI Codex instead of a Claude subagent.
#
# Usage:  codex-critic.sh <spec|plan|code|review|refute>   (crafted inputs piped on stdin)
#
# The critic's instruction body (including the exact VERDICT block spec) is read
# from ../agents/superlazy-<critic>-critic.md with its YAML frontmatter stripped,
# then handed to `codex exec` together with the coordinator's crafted inputs.
# Codex's stdout is the VERDICT block the coordinator parses.
#
# Seam critics (spec|plan|code) are ROUND-BUDGETED. A critic that re-reads a doc
# always finds one more [Important], so drafter<->critic never converges on its
# own. Pass CODEX_CRITIC_ROUND; the wrapper appends a GATE: line telling the
# coordinator what to do, and past CODEX_CRITIC_MAX_ROUNDS it refuses to spend
# another Codex call at all. Default budget 2 = draft -> critic -> revise ->
# critic -> revise(FINAL). The drafter always gets the last word.
set -euo pipefail

critic="${1:?usage: codex-critic.sh <spec|plan|code|review|refute>}"

seam=""; case "$critic" in spec|plan|code) seam=1 ;; esac

# --- model config (EDIT HERE) ------------------------------------------------
# Codex model the critics run on. "gpt-5.6-sol" ("Sol") is the current default
# on a ChatGPT-account Codex and is verified working. The bare id "sol" and
# "gpt-5-codex" are NOT accepted on ChatGPT accounts.
# Override per-run with CODEX_CRITIC_MODEL; set it to empty ("") to let Codex use
# whatever your account default is (safest if the id changes in a future release).
MODEL="${CODEX_CRITIC_MODEL-gpt-5.6-sol}"
# Live web search. Default ON — lets Codex verify current library APIs, CVEs, and
# breaking changes as review evidence. Disable with CODEX_CRITIC_SEARCH=0 for
# faster, offline critic runs. (Context7 MCP, if configured in ~/.codex, is
# always available regardless of this switch.)
case "${CODEX_CRITIC_SEARCH:-1}" in 0|false|no) SEARCH="" ;; *) SEARCH="--search" ;; esac
# Seam round budget.
MAX_ROUNDS="${CODEX_CRITIC_MAX_ROUNDS:-2}"
ROUND="${CODEX_CRITIC_ROUND:-1}"
# Reasoning effort. Every round runs `high`. Each `codex exec` is a fresh
# process with no memory of the last one, so a later round is not a cheap
# re-read — it is a full cold review of the whole document. And with a 2-round
# budget the last round is the final word before the drafter concludes, which
# is the worst place to spend less thinking.
EFFORT="${CODEX_CRITIC_EFFORT:-high}"
# -----------------------------------------------------------------------------

fail() { echo "VERDICT: NEEDS-HUMAN"; echo "codex-critic: $1" >&2; exit 2; }

# A non-numeric round silently DISABLES the budget: `[ junk -gt 2 ]` errors,
# the test reads false, and the loop runs forever. Refuse loudly instead —
# a malformed invocation must stop the pipeline, never quietly unbound it.
is_pos_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ]; }
is_pos_int "$MAX_ROUNDS" || fail "CODEX_CRITIC_MAX_ROUNDS must be a positive integer, got '$MAX_ROUNDS'"
is_pos_int "$ROUND"      || fail "CODEX_CRITIC_ROUND must be a positive integer, got '$ROUND'"

# Budget spent — refuse the call outright. This is the hard stop that keeps one
# seam from eating an afternoon: no Codex call, no findings, nothing left to
# argue about. Whatever the drafter wrote last is the deliverable.
if [ -n "$seam" ] && [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
  echo "GATE: conclude"
  echo "codex-critic: seam '$critic' round $ROUND exceeds CODEX_CRITIC_MAX_ROUNDS=$MAX_ROUNDS — no Codex call made. The drafter's current revision is FINAL; move on." >&2
  exit 0
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prompt_file="$here/../agents/superlazy-${critic}-critic.md"
[ -f "$prompt_file" ] || fail "no prompt file at $prompt_file (critic='$critic')"
command -v codex >/dev/null 2>&1 || fail "codex CLI not found on PATH — install @openai/codex and 'codex login'"

# critic instructions = file with the leading YAML frontmatter removed
body="$(awk 'NR==1 && /^---/{f=1; next} f && /^---/{f=0; next} !f' "$prompt_file")"

inputs="$(cat)"   # coordinator pipes: doc paths, brief, diff range (BASE/HEAD), what-changed

prompt="${body}

## Your assignment (inputs from the coordinator)
${inputs}

Read whatever files, paths, or git ranges are referenced above to perform the
review yourself. Do NOT modify any files. Output ONLY the VERDICT block in the
exact format specified above — no preamble, no text after it."

# Read-only sandbox: Codex may read the repo/spec/plan/diff but never edit.
# Empty MODEL -> omit -m so Codex uses the account default.
# NOTE: --search is a TOP-LEVEL codex flag, so it goes BEFORE `exec`.
#
# review/refute: BYTE-PERFECT pass-through via exec — no capture, no GATE line
# (command substitution would strip trailing newlines, and superlazy-review
# consumes this output verbatim). Seam modes capture instead, so they can append
# the gate directive after printing the verdict.
if [ -z "$seam" ]; then
  if [ -n "$MODEL" ]; then
    exec codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" -m "$MODEL" "$prompt"
  else
    exec codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" "$prompt"
  fi
fi

if [ -n "$MODEL" ]; then
  out="$(codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" -m "$MODEL" "$prompt")"
else
  out="$(codex $SEARCH exec -s read-only -c model_reasoning_effort="$EFFORT" "$prompt")"
fi
printf '%s\n' "$out"

# ---- GATE directive: what the coordinator does next --------------------------
# Clean requires BOTH the `pass` token AND zero parsed findings. Counting alone
# is not enough: a critic that formats a finding as `* [Critical]` instead of
# `- [Critical]` parses as zero, and a count-only gate would report a verdict of
# "rewrite — fundamentally broken" as clean. The two signals are deliberately
# redundant because they fail independently.
# NOTE: grep exits 1 on no-match and pipefail is on — the `|| true` is what
# keeps a garbled verdict reaching the needs-human branch instead of killing us.
verdict_line="$(printf '%s\n' "$out" | grep -m1 '^VERDICT:' || true)"
token="$(printf '%s' "$verdict_line" | sed -n 's/^VERDICT:[[:space:]]*\([a-zA-Z-]*\).*/\1/p' | tr '[:upper:]' '[:lower:]')"
crit=$(printf '%s\n' "$out" | grep -c '^- \[Critical\]' || true)
imp=$(printf '%s\n' "$out" | grep -c '^- \[Important\]' || true)

# Token says not-clean but nothing parsed: our parser and the critic disagree,
# so trust the critic and make the coordinator read the body itself.
if [ "$token" != "pass" ] && [ "$token" != "needs-human" ] && [ -n "$token" ] \
   && [ "$crit" -eq 0 ] && [ "$imp" -eq 0 ]; then
  echo "codex-critic: verdict token is '$token' but no '- [Critical]/[Important]' lines parsed — the critic's findings are in a format this wrapper does not count. READ THE VERDICT BODY; do not treat it as clean." >&2
fi

if [ "$token" = "needs-human" ] || [ -z "$token" ]; then
  echo "GATE: needs-human"
  echo "codex-critic: critic returned no usable verdict (token='$token') — surface the raw output, do not treat as clean." >&2
elif [ "$token" = "pass" ] && [ "$crit" -eq 0 ] && [ "$imp" -eq 0 ]; then
  echo "GATE: pass"
elif [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
  echo "GATE: final"
  echo "codex-critic: seam '$critic' round $ROUND/$MAX_ROUNDS was the LAST critic pass ($crit Critical, $imp Important). The drafter addresses what it can and CONCLUDES — do not re-run this seam." >&2
else
  echo "GATE: revise"
  echo "codex-critic: seam '$critic' round $ROUND/$MAX_ROUNDS ($crit Critical, $imp Important) — revise, then re-run at round $(( ROUND + 1 ))." >&2
fi
exit 0
