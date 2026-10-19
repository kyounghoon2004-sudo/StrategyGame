#!/bin/bash
# Game eval of one model (2026-10-19): the student plays through the relay shim (carry yes), thinking off, held-out seeds:
# BASIC 9987000-05, INTER 9987100-05, COLLAPSE 9987200-05 (BASIC GX + the collapse rule), BLOCKADE 9820000-05; history no for the
# first 3 seeds of each tier, yes for the last 3 (as in collection).   bash run_eval_games.sh <model name on :8010> <out tag>
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8
M="$1"; TAG="$2"
R="/d/Game development/Demon slayer/StrategyGame"
DD="D:/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/synth_adv_v1/sft_teacher_v1/eval/$TAG"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
cd "$R"; mkdir -p "$DD"
i=0; GP=""; SP=""
for T in "BASIC 9987000 0" "INTER 9987100 0" "COLLAPSE 9987200 1"; do
  set -- $T; TIER=$1; S0=$2; COL=$3
  for ARM in no yes; do
    [ $ARM = no ] && SEED=$S0 || SEED=$((S0+3))
    N="${TIER}_hist${ARM}"
    if [ $COL = 1 ]; then ENVV="TG_ROUT_MIN=2 TG_NO_HQ_WIN=1 RELAY_MODE=collapse"; GT=BASIC; else ENVV=""; GT=$TIER; fi
    env $ENVV $PY -m tools.synth_adv_v1.relay_shim --port $((8171+i)) --target http://127.0.0.1:$((8120+i)) --history $ARM --log "$DD/${N}_relays.jsonl" > /dev/null 2>&1 &
    SP="$SP $!"; sleep 1
    env $ENVV $PY -m tools.cmd_rl.teacher_gx --tier $GT --games 3 --windows 3 --seed0 $SEED --slot $i --proxy-port $((8120+i)) --brain-port $((8130+i)) \
       --url http://127.0.0.1:8010/v1/chat/completions --model $M --cmd-url http://127.0.0.1:$((8171+i))/v1/chat/completions \
       --out "$DD/$N" > "$DD/$N.log" 2>&1 &
    GP="$GP $!"; i=$((i+1))
  done
done
(
for ARM in no yes; do
  [ $ARM = no ] && SEED=9820000 || SEED=9820003
  OUT="$DD/BLOCKADE_hist$ARM"; mkdir -p "$OUT/manual"
  $PY -m tools.synth_adv_v1.relay_shim --port 8178 --target http://127.0.0.1:8127 --history $ARM --log "$DD/BLOCKADE_hist${ARM}_relays.jsonl" > /dev/null 2>&1 &
  SH=$!
  $PY -m tools.cmd_rl.blockade_bot --dir "$OUT/manual" > /dev/null 2>&1 &
  BT=$!
  SPAR_MODEL=$M SPAR_THINK_PORT=8147 SPAR_THINK_BUDGET=9000 SPAR_RED_PORT=8127 $PY -m tools.synth_adv_v1.spar_relay --manual --per-model 3 --slot 6 \
     --red-port 8127 --red-brain-port 8137 --blue-port0 8160 --seed0 $SEED --cmd-url http://127.0.0.1:8178/v1/chat/completions \
     --out "$OUT" > "$DD/BLOCKADE_hist$ARM.log" 2>&1
  kill $SH $BT > /dev/null 2>&1
done ) &
wait $GP $!
for p in $SP; do kill $p > /dev/null 2>&1; done
echo "$(date '+%m-%d %H:%M:%S') eval $M done" >> "$DD/../eval_runs.log"
