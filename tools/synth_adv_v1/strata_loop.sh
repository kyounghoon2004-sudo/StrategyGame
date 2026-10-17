#!/bin/bash
# Strata teacher loop (2026-10-17, user): after the running strata game ends, play BASIC -> INTER -> BLOCKADE endlessly
# (until teacher_play/strata/STOP is created again) with the current bridge: plan turns (turn 1 + relays) medium, cap 20000,
# other turns low, cap 1500, AID with siege forecast on plan turns.
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
D="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play/strata"
cd "$R"
until grep -q "^none" "$D/CURRENT.txt" 2>/dev/null; do sleep 15; done
[ -f "$D/bridge.jsonl" ] && mv "$D/bridge.jsonl" "$D/bridge_$(ls -d "$D"/g0* | tail -1 | xargs basename)_v23.jsonl"
rm -f "$D/STOP"
bash "$R/tools/synth_adv_v1/teacher_play.sh" strata 14 &
sleep 20
until grep -q "inbox" "$D/CURRENT.txt" 2>/dev/null; do sleep 5; done
$PY -m tools.synth_adv_v1.teacher_play_llm --name strata --effort low --effort-plan medium --aid --think-on short \
    --think-budget 20000 --think-budget-other 1500 >> "$D/bridge_loop.log" 2>&1
wait
