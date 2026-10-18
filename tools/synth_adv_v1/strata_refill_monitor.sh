#!/bin/bash
# Monitor half of the BASIC refill (2026-10-18): the BASIC-only loop and its bridge are already running. Count clean BASIC wins (no
# HQ fieldworks regen) after game N0; at N, STOP after the running game, wait for the end, then resume BASIC -> INTER -> COLLAPSE.
#   bash tools/synth_adv_v1/strata_refill_monitor.sh <N0> [N=11]      early stop: touch strata/STOP_REFILL
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
N0="$1"; N="${2:-11}"
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
T="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"
TW="D:/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"   # the python side needs a Windows path
BR="--name strata --effort low --effort-plan medium --aid --think-on short --think-budget 20000 --think-budget-other 1500"
cd "$R"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$T/strata/refill.log"; }
log "monitor: need $N clean BASIC wins after g$N0"
C=0
while true; do
  sleep 60
  C=$($PY -m tools.synth_adv_v1.regen_audit --dir "$TW/strata" --clean-wins BASIC --after "$N0" 2>/dev/null)
  if [ -z "$C" ]; then log "counter failed"; continue; fi
  if [ "$C" -ge "$N" ] || [ -f "$T/strata/STOP_REFILL" ]; then break; fi
done
log "clean BASIC wins $C -> stop after the running game"
touch "$T/strata/STOP"
until grep -q "^none" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 15; done
sleep 20
rm -f "$T/strata/STOP" "$T/strata/STOP_REFILL"
log "refill done ($C clean BASIC wins), resuming the rotation"
TIERS="BASIC INTER COLLAPSE" bash "$R/tools/synth_adv_v1/teacher_play2.sh" strata 14 &
sleep 20
until grep -q "inbox" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm $BR >> "$T/strata/bridge_loop.log" 2>&1
wait
