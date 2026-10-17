#!/bin/bash
# Switch the Strata rotation to BASIC -> INTER -> COLLAPSE (2026-10-17, user): let the running game finish, then run the v2
# launcher with the three tiers and one bridge (AID detects collapse games from their system prompt).
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
T="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play"
cd "$R"
touch "$T/strata/STOP"
until grep -q "^none" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 15; done
sleep 15
rm -f "$T/strata/STOP"
TIERS="BASIC INTER COLLAPSE" bash "$R/tools/synth_adv_v1/teacher_play2.sh" strata 14 &
sleep 20
until grep -q "inbox" "$T/strata/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm --name strata --effort low --effort-plan medium --aid --think-on short \
    --think-budget 20000 --think-budget-other 1500 >> "$T/strata/bridge_loop.log" 2>&1
wait
