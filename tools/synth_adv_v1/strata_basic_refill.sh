#!/bin/bash
# BASIC refill (2026-10-18, user): 11 BASIC wins were dropped from the SFT set (the BLUE HQ's fieldworks regenerated, old rule; see
# regen_audit.py / strata/EXCLUDED_regen.json). Let the running game finish, play BASIC games only until N clean BASIC wins (no regen
# event) are in, then resume the BASIC -> INTER -> COLLAPSE rotation. Teacher settings are the rotation's (no change).
#   bash tools/synth_adv_v1/strata_basic_refill.sh [N=11]        stop early: touch strata/STOP_REFILL
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
N="${1:-11}"
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
T="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"
TW="D:/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"   # python needs a Windows path
BR="--name strata --effort low --effort-plan medium --aid --think-on short --think-budget 20000 --think-budget-other 1500"
cd "$R"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$T/strata/refill.log"; }
waitnone() { until grep -q "^none" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 15; done; sleep 15; }
touch "$T/strata/STOP"; waitnone; rm -f "$T/strata/STOP"
N0=$($PY -m tools.synth_adv_v1.regen_audit --dir "$TW/strata" --max-no)
log "refill start: need $N clean BASIC wins after g$N0"
TIERS="BASIC" bash "$R/tools/synth_adv_v1/teacher_play2.sh" strata 14 &
sleep 20
until grep -q "inbox" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm $BR >> "$T/strata/bridge_loop.log" 2>&1 &
BP=$!
while kill -0 $BP 2>/dev/null; do
  sleep 60
  C=$($PY -m tools.synth_adv_v1.regen_audit --dir "$TW/strata" --clean-wins BASIC --after "$N0" 2>/dev/null)
  if [ "${C:-0}" -ge "$N" ] || [ -f "$T/strata/STOP_REFILL" ]; then log "clean BASIC wins $C -> stop after the running game"; touch "$T/strata/STOP"; break; fi
done
wait $BP
wait
rm -f "$T/strata/STOP" "$T/strata/STOP_REFILL"
log "refill done ($C clean BASIC wins), resuming the rotation"
TIERS="BASIC INTER COLLAPSE" bash "$R/tools/synth_adv_v1/teacher_play2.sh" strata 14 &
sleep 20
until grep -q "inbox" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm $BR >> "$T/strata/bridge_loop.log" 2>&1
wait
