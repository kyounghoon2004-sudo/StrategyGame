#!/bin/bash
# BLOCKADE games only, portable (2026-10-18, user: run the blockade teacher games on another laptop).
# Same flow as teacher_play.sh (BLOCKADE branch): relay shim -> scripted BLUE blockade bot -> RED answers from the
# inbox folder (CURRENT.txt names it). Nothing here is hardcoded to the first computer.
#   bash tools/synth_adv_v1/blockade_laptop.sh <name> <slot 15..19>      stop: touch <out>/<name>/STOP
# Env (all optional):  SG_PY = python with the game-side packages (default: python on PATH)
#                      SG_GODOT = Godot_v4.2.2 console exe   SG_LAYA_PY = python of the Hands venv (torch, CPU)
# Teacher: another process answers req_NNNN.json in the inbox (another Claude session reading
# tools/synth_adv_v1/teacher_play_prompt.md, or: python -m tools.synth_adv_v1.teacher_play_llm --name <name> --url <endpoint> ...).
export MSYS_NO_PATHCONV=1 PYTHONIOENCODING=utf-8 GAME_TIMEOUT_S="${GAME_TIMEOUT_S:-14400}"
NAME="$1"; SLOT="$2"
[ -z "$NAME" ] || [ -z "$SLOT" ] && { echo "usage: $0 <name> <slot 15..19>"; exit 2; }
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SG_ROOT="$(cygpath -w "$R")"          # read by tools/contextual_brain/rl_vs_utility.py and brain_review/harvest.py
[ -n "$SG_PY" ] && export SG_PY="$(cygpath -w "$SG_PY")"
[ -n "$SG_GODOT" ] && export SG_GODOT="$(cygpath -w "$SG_GODOT")"
[ -n "$SG_LAYA_PY" ] && export SG_LAYA_PY="$(cygpath -w "$SG_LAYA_PY")"
PY="${SG_PY:-python}"
D="$R/artifacts/brain_pipeline_v1/synth_adv_v1/teacher_play/$NAME"
DW="$(cygpath -m "$D")"
mkdir -p "$D"; cd "$R"
SP=$((8240+SLOT)); PP=$((8250+SLOT)); BP=$((8260+SLOT)); BL=$((8270+SLOT))
n=$(find "$D" -maxdepth 1 -type d -name 'g[0-9]*' | wc -l)
while [ ! -f "$D/STOP" ]; do
  n=$((n+1)); ARM=$([ $((n % 2)) -eq 0 ] && echo no || echo yes)   # relay history no/yes alternates
  G=$(printf "g%03d_BLOCKADE_hist%s" $n $ARM); GW="$DW/$G"; mkdir -p "$D/$G/inbox" "$D/$G/game/manual"
  SEED=$((9995000 + SLOT*1000 + n))
  echo "$GW/inbox" > "$D/CURRENT.txt"
  "$PY" -m tools.synth_adv_v1.relay_shim --port $SP --target http://127.0.0.1:$PP --history $ARM --carry yes --log "$GW/relays.jsonl" > "$D/$G/shim.log" 2>&1 &
  SH=$!; sleep 2
  "$PY" -m tools.cmd_rl.blockade_bot --dir "$GW/game/manual" > /dev/null 2>&1 &
  BT=$!
  TEACHER_RED_PORT=$PP TEACHER_RED_DIR="$GW/inbox" "$PY" -m tools.synth_adv_v1.spar_teacher --manual --per-model 1 --slot $SLOT \
    --red-port $PP --red-brain-port $BP --blue-port0 $BL --seed0 $SEED --cmd-url http://127.0.0.1:$SP/v1/chat/completions \
    --out "$GW/game" > "$D/$G/game.log" 2>&1
  kill $BT $SH > /dev/null 2>&1
  echo "$(date '+%m-%d %H:%M:%S') $G seed=$SEED $(tail -1 "$D/$G/game/games.jsonl" 2>/dev/null)" >> "$D/results.log"
done
echo "none (stopped)" > "$D/CURRENT.txt"
echo "$(date '+%m-%d %H:%M:%S') stopped" >> "$D/results.log"
