#!/usr/bin/env bash
# Tests for detect_runtime.sh.  Run: bash tests/detect_runtime_test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
D=$SCRIPTS/detect_runtime.sh
# A clean env so the caller's agent markers and API keys do not leak into detection.
run() { env -i PATH="$PATH" HOME="$WORK" "$@" bash "$D" --agent "$AGENT"; }

section "claude defaults"
AGENT=claude; out=$(run)
check_eq "lead model" "$(json_get '["lead"]["model"]' <<<"$out")" claude-opus-5-5
check_eq "lead effort" "$(json_get '["lead"]["effort"]' <<<"$out")" high
check_eq "phase 2 lead model" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" claude-sonnet-5-5
check_eq "phase 2 lead effort" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" high
check_eq "worker model" "$(json_get '["worker"]["model"]' <<<"$out")" claude-sonnet-5-5
check_eq "worker effort" "$(json_get '["worker"]["effort"]' <<<"$out")" medium
check_eq "worker dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" sonnet

section "gemini defaults"
AGENT=gemini; out=$(run)
check_eq "lead model" "$(json_get '["lead"]["model"]' <<<"$out")" gemini-4-argon-high
check_eq "phase 2 lead model" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" gemini-3.8-flash-high
check_eq "phase 2 lead effort" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" high
check_eq "worker model" "$(json_get '["worker"]["model"]' <<<"$out")" gemini-3.8-flash-high
check_eq "worker dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" gemini-3.8-flash-high

section "codex: phase 2 lead = lead"
AGENT=codex; out=$(run)
check_eq "codex" "$(json_get '["lead_phase2"]' <<<"$out")" "$(json_get '["lead"]' <<<"$out")"

section "overrides"
AGENT=claude; out=$(run SAR_LEAD2_MODEL=claude-opus-5-5 SAR_LEAD2_EFFORT=medium SAR_LEAD_EFFORT=max SAR_WORKER_MODEL=haiku)
check_eq "SAR_LEAD2_MODEL" "$(json_get '["lead_phase2"]["model"]' <<<"$out")" claude-opus-5-5
check_eq "SAR_LEAD2_EFFORT" "$(json_get '["lead_phase2"]["effort"]' <<<"$out")" medium
check_eq "SAR_LEAD_EFFORT leaves phase 2 alone" "$(json_get '["lead_phase2"]["effort"]' <<<"$(run SAR_LEAD_EFFORT=max)")" high
check_eq "SAR_WORKER_MODEL sets the dispatch alias" "$(json_get '["worker"]["dispatch_model"]' <<<"$out")" haiku

section "detection"
check_eq "--agent wins over runtime markers" \
  "$(env -i PATH="$PATH" HOME="$WORK" CLAUDECODE=1 bash "$D" --agent codex | json_get '["ecosystem"]')" codex
check_eq "Claude Code marker" "$(env -i PATH="$PATH" HOME="$WORK" CLAUDECODE=1 bash "$D" | json_get '["ecosystem"]')" claude
bash "$D" --agent other >/dev/null 2>&1; rc=$?
check_eq "invalid --agent: exit 2" "$rc" 2

finish
