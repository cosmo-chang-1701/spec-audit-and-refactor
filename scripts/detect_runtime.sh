#!/usr/bin/env bash
# Detect the agent ecosystem and resolve Lead / Worker model assignments.
#
# Usage: detect_runtime.sh [--agent claude|gemini|codex]
#
# Detection priority (first hit wins):
#   1. --agent flag            (the running agent knows who it is; most reliable)
#   2. SAR_ECOSYSTEM env var   (user override)
#   3. Runtime markers         (env vars injected by the agent CLI itself)
#   4. API keys                (only when exactly ONE provider key is present;
#                               several keys at once are common and ambiguous)
#   5. Fallback                (claude)
#
# Roles: "lead" runs phase 1 (preflight, audit, spec, checkpoint); "lead_phase2" runs
# phase 2 (dispatch, gate, review, close-out) in a fresh session; "worker" implements.
# Per-field overrides: SAR_LEAD_MODEL, SAR_LEAD_EFFORT, SAR_LEAD2_MODEL, SAR_LEAD2_EFFORT,
# SAR_WORKER_MODEL, SAR_WORKER_EFFORT.
# Session split: SAR_SESSION_SPLIT = auto (default: split only multi-task or H-risk runs),
# always, or never; reported as "session_split".
# Output: a single JSON object on stdout.
set -euo pipefail

readonly VALID_ECOSYSTEMS="claude gemini codex"
readonly CODEX_DEFAULT_MODEL="gpt-5.4"

die() { printf 'detect_runtime: %s\n' "$*" >&2; exit 2; }

json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

is_valid_ecosystem() { [[ " $VALID_ECOSYSTEMS " == *" $1 "* ]]; }

has_env_prefix() {
  # Succeeds if any exported variable name matches the ERE (anchored at name start).
  compgen -e | grep -Eq "^($1)"
}

codex_configured_model() {
  local config="${CODEX_HOME:-$HOME/.codex}/config.toml" model=""
  if [[ -r $config ]]; then
    # Top-level `model = "..."` only (before the first [table] header).
    model=$(awk '/^\[/{exit} /^[[:space:]]*model[[:space:]]*=/{gsub(/^[^=]*=[[:space:]]*"|".*$/, ""); print; exit}' "$config")
  fi
  printf '%s' "${model:-$CODEX_DEFAULT_MODEL}"
}

agent_flag=""
while (($#)); do
  case $1 in
    --agent) [[ $# -ge 2 ]] || die "--agent needs a value"; agent_flag=$2; shift 2 ;;
    --agent=*) agent_flag=${1#*=}; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

session_split=${SAR_SESSION_SPLIT:-auto}
case $session_split in
  auto|always|never) ;;
  *) die "SAR_SESSION_SPLIT must be one of: auto always never" ;;
esac

ecosystem="" detected_by=""
if [[ -n $agent_flag ]]; then
  is_valid_ecosystem "$agent_flag" || die "--agent must be one of: $VALID_ECOSYSTEMS"
  ecosystem=$agent_flag detected_by="flag:--agent"
elif [[ -n ${SAR_ECOSYSTEM:-} ]]; then
  is_valid_ecosystem "$SAR_ECOSYSTEM" || die "SAR_ECOSYSTEM must be one of: $VALID_ECOSYSTEMS"
  ecosystem=$SAR_ECOSYSTEM detected_by="env:SAR_ECOSYSTEM"
elif [[ -n ${CLAUDECODE:-} ]] || has_env_prefix 'CLAUDE_CODE_'; then
  ecosystem=claude detected_by="runtime:claude-code"
elif has_env_prefix 'CODEX_(SANDBOX|THREAD_ID|SESSION|MANAGED)'; then
  ecosystem=codex detected_by="runtime:codex"
elif has_env_prefix 'ANTIGRAVITY_|AGY_|JETSKI|GEMINI_CLI'; then
  ecosystem=gemini detected_by="runtime:antigravity-or-gemini-cli"
else
  keys=()
  [[ -n ${ANTHROPIC_API_KEY:-} ]] && keys+=(claude)
  [[ -n ${GOOGLE_API_KEY:-}${GEMINI_API_KEY:-} ]] && keys+=(gemini)
  [[ -n ${OPENAI_API_KEY:-} ]] && keys+=(codex)
  if ((${#keys[@]} == 1)); then
    ecosystem=${keys[0]} detected_by="api-key:single"
  else
    ecosystem=claude detected_by="fallback(api-keys=${#keys[@]})"
  fi
fi

case $ecosystem in
  claude)
    lead_model=claude-opus-5-5   lead_effort=high
    lead2_model=claude-sonnet-5-5 lead2_effort=high
    worker_model=claude-sonnet-5-5 worker_effort=medium
    worker_alias=sonnet ;;
  gemini)
    # Antigravity encodes effort in the model id (see `agy models`).
    lead_model=gemini-4-argon-high     lead_effort=high
    lead2_model=gemini-3.8-flash-high  lead2_effort=high
    worker_model=gemini-3.8-flash-high worker_effort=high
    worker_alias=gemini-3.8-flash-high ;;
  codex)
    lead_model=$(codex_configured_model) lead_effort=high
    lead2_model=$lead_model              lead2_effort=$lead_effort
    worker_model=$lead_model             worker_effort=medium
    worker_alias=$lead_model ;;
esac

lead_model=${SAR_LEAD_MODEL:-$lead_model}
lead_effort=${SAR_LEAD_EFFORT:-$lead_effort}
lead2_model=${SAR_LEAD2_MODEL:-$lead2_model}
lead2_effort=${SAR_LEAD2_EFFORT:-$lead2_effort}
worker_model=${SAR_WORKER_MODEL:-$worker_model}
worker_effort=${SAR_WORKER_EFFORT:-$worker_effort}
[[ -n ${SAR_WORKER_MODEL:-} ]] && worker_alias=$SAR_WORKER_MODEL

printf '{"ecosystem":"%s","detected_by":"%s","lead":{"model":"%s","effort":"%s"},"lead_phase2":{"model":"%s","effort":"%s"},"worker":{"model":"%s","effort":"%s","dispatch_model":"%s"},"session_split":"%s"}\n' \
  "$ecosystem" "$(json_escape "$detected_by")" \
  "$(json_escape "$lead_model")" "$(json_escape "$lead_effort")" \
  "$(json_escape "$lead2_model")" "$(json_escape "$lead2_effort")" \
  "$(json_escape "$worker_model")" "$(json_escape "$worker_effort")" "$(json_escape "$worker_alias")" \
  "$session_split"
