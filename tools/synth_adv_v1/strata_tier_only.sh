#!/bin/bash
# Strata, one tier only (2026-10-18, user: "INTER only for now"): let the running game finish, then play only <TIER> games with the rotation's
# teacher settings, until strata/STOP is touched. To go back to the rotation: touch strata/STOP, wait for "none" in CURRENT.txt, then run
# strata_rotation3.sh-style TIERS="BASIC INTER COLLAPSE" (see strata_refill_monitor.sh, last lines).
#   bash tools/synth_adv_v1/strata_tier_only.sh INTER
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
TIER="${1:?tier: BASIC | INTER | COLLAPSE}"
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
T="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"
BR="--name strata --effort low --effort-plan medium --aid --think-on short --think-budget 20000 --think-budget-other 1500"
cd "$R"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$T/strata/refill.log"; }
touch "$T/strata/STOP"
until grep -q "^none" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 15; done
sleep 20; rm -f "$T/strata/STOP"
log "tier-only: $TIER"
TIERS="$TIER" bash "$R/tools/synth_adv_v1/teacher_play2.sh" strata 14 &
sleep 20
until grep -q "inbox" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm $BR >> "$T/strata/bridge_loop.log" 2>&1
wait
