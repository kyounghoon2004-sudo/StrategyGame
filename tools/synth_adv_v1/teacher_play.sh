#!/bin/bash
# Cloud teacher plays RED (2026-10-16, user): an external model answers every RED turn from files (cold prompt
# teacher_play_prompt.md). Endless rounds of BASIC -> INTER -> BLOCKADE, one game at a time, through the relay shim
# (relay every 10 turns, short carried context, history no/yes alternating by round), until <dir>/STOP.
# Every game gets its own request folder; <dir>/CURRENT.txt names the folder being played. Wins are what we keep.
#   bash tools/synth_adv_v1/teacher_play.sh <teacher name> <slot 10..19>
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8 GAME_TIMEOUT_S=14400
NAME="$1"; SLOT="$2"
R="/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
DW="D:/Game development/Demon slayer/StrategyGame/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play/$NAME"
D="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play/$NAME"
mkdir -p "$D"; cd "$R"
SP=$((8240+SLOT)); PP=$((8250+SLOT)); BP=$((8260+SLOT)); BL=$((8270+SLOT))
n=$(find "$D" -maxdepth 1 -type d -name 'g[0-9]*' | wc -l)
r=$((n/3))
while [ ! -f "$D/STOP" ]; do
  if [ $((r % 2)) -eq 0 ]; then ARM=no; else ARM=yes; fi
  for TIER in ${TIERS:-BASIC INTER BLOCKADE}; do
    [ -f "$D/STOP" ] && break
    n=$((n+1)); G=$(printf "g%03d_%s_hist%s" $n $TIER $ARM); GW="$DW/$G"; mkdir -p "$D/$G/inbox"
    SEED=$((9995000 + SLOT*1000 + n))
    echo "$GW/inbox" > "$D/CURRENT.txt"
    $PY -m tools.synth_adv_v1.relay_shim --port $SP --target http://127.0.0.1:$PP --history $ARM --carry yes --log "$GW/relays.jsonl" > "$D/$G/shim.log" 2>&1 &
    SH=$!; sleep 2
    if [ "$TIER" = BLOCKADE ]; then
      mkdir -p "$D/$G/game/manual"
      $PY -m tools.cmd_rl.blockade_bot --dir "$GW/game/manual" > /dev/null 2>&1 &
      BT=$!
      TEACHER_RED_PORT=$PP TEACHER_RED_DIR="$GW/inbox" $PY -m tools.synth_adv_v1.spar_teacher --manual --per-model 1 --slot $SLOT \
        --red-port $PP --red-brain-port $BP --blue-port0 $BL --seed0 $SEED --cmd-url http://127.0.0.1:$SP/v1/chat/completions \
        --out "$GW/game" > "$D/$G/game.log" 2>&1
      kill $BT > /dev/null 2>&1
    else
      STY=$(echo SPEARHEAD BULWARK OUTRIDER HARRIER | cut -d' ' -f$(( SEED % 4 + 1 )))
      FAM=$(echo fixed mild broad counterfactual_valid | cut -d' ' -f$(( (SEED / 4) % 4 + 1 )))
      $PY -m tools.cmd_rl.teacher_gx --tier $TIER --games 1 --windows 1 --seed0 $SEED --style $STY --family $FAM --slot $SLOT \
        --proxy-port $PP --brain-port $BP --manual-dir "$GW/inbox" --cmd-url http://127.0.0.1:$SP/v1/chat/completions \
        --out "$GW/game" > "$D/$G/game.log" 2>&1
    fi
    kill $SH > /dev/null 2>&1
    echo "$(date '+%m-%d %H:%M:%S') $G seed=$SEED $(tail -1 "$D/$G/game/games.jsonl" 2>/dev/null)" >> "$D/results.log"
  done
  r=$((r+1))
done
echo "none (stopped)" > "$D/CURRENT.txt"
echo "$(date '+%m-%d %H:%M:%S') stopped" >> "$D/results.log"
