#!/usr/bin/env bash
# codex-critic.sh — run a superlazy critic on OpenAI Codex instead of a Claude subagent.
#
# Usage:  codex-critic.sh <spec|plan|code>     (crafted inputs piped on stdin)
#
# The critic's instruction body (including the exact VERDICT block spec) is read
# from ../agents/superlazy-<critic>-critic.md with its YAML frontmatter stripped,
# then handed to `codex exec` together with the coordinator's crafted inputs.
# Codex's stdout is the VERDICT block the coordinator parses.
set -euo pipefail

critic="${1:?usage: codex-critic.sh <spec|plan|code>}"

# --- model config (EDIT HERE) ------------------------------------------------
# Codex model the critics run on. "gpt-5.6-sol" ("Sol") is the current default
# on a ChatGPT-account Codex and is verified working. The bare id "sol" and
# "gpt-5-codex" are NOT accepted on ChatGPT accounts.
# Override per-run with CODEX_CRITIC_MODEL; set it to empty ("") to let Codex use
# whatever your account default is (safest if the id changes in a future release).
MODEL="${CODEX_CRITIC_MODEL-gpt-5.6-sol}"
# -----------------------------------------------------------------------------

fail() { echo "VERDICT: NEEDS-HUMAN"; echo "codex-critic: $1" >&2; exit 2; }

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
if [ -n "$MODEL" ]; then
  exec codex exec -s read-only -m "$MODEL" "$prompt"
else
  exec codex exec -s read-only "$prompt"
fi
