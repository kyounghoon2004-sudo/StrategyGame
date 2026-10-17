#!/bin/bash
# One collapse-mode trial game for Strata (2026-10-17, user): the HQ rotation is paused (RAM); play ONE collapse game
# (win = destroy 60% of BLUE's non-HQ units; TG_* env -> teacher_gx, RELAY_MODE -> relay_shim) in teacher_play/strata_col,
# then resume the HQ rotation (BASIC/INTER) with its bridge.
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
T="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"
BR="--effort low --effort-plan medium --aid --think-on short --think-budget 20000 --think-budget-other 1500"
cd "$R"
touch "$T/strata/STOP"
until grep -q "^none" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 15; done
mkdir -p "$T/strata_col"; rm -f "$T/strata_col/STOP"
n0=$(find "$T/strata_col" -maxdepth 1 -type d -name 'g[0-9]*' | wc -l)
[ -f "$T/strata_col/bridge.jsonl" ] && mv "$T/strata_col/bridge.jsonl" "$T/strata_col/bridge_upto_g$(printf %03d $n0).jsonl"
TG_ROUT_MIN=2 TG_NO_HQ_WIN=1 RELAY_MODE=collapse TIERS="BASIC" bash "$R/tools/synth_adv_v1/teacher_play.sh" strata_col 14 &
until [ "$(find "$T/strata_col" -maxdepth 1 -type d -name 'g[0-9]*' | wc -l)" -gt "$n0" ] && \
      ls "$(ls -d "$T"/strata_col/g[0-9]* | tail -1)"/inbox/req_0001.json >/dev/null 2>&1; do sleep 3; done
touch "$T/strata_col/STOP"
$PY -m tools.synth_adv_v1.teacher_play_llm --name strata_col $BR >> "$T/strata_col/bridge_loop.log" 2>&1
wait
rm -f "$T/strata/STOP"
TIERS="BASIC INTER" bash "$R/tools/synth_adv_v1/teacher_play.sh" strata 14 &
sleep 20
until grep -q "inbox" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm --name strata $BR >> "$T/strata/bridge_loop.log" 2>&1
wait
