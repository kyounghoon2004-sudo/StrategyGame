#!/bin/bash
# Relay cycle watchdog (2026-10-16): every 30 min append relay_check to <root>/watch.log. Exits (after touching STOP) when
# INVALID > 15% or no new finished game for 40 min, so the agent is woken. Exits quietly when STOP already exists.
export MSYS_NO_PATHCONV=1
cd "/d/Game development/Demon slayer/StrategyGame"
PY=/d/StrategyAI/runtimes/qwen3_8b_rl_v0/.venv/Scripts/python.exe
R=artifacts/brain_pipeline_v1/synth_adv_v1/relay3
last_n=-1; last_t=$(date +%s)
while [ ! -f "$R/STOP" ]; do
  for k in $(seq 1 30); do [ -f "$R/STOP" ] && break; sleep 60; done
  out=$($PY -m tools.synth_adv_v1.relay_check $R 2>&1)
  { echo "=== $(date '+%m-%d %H:%M')"; echo "$out"; } >> "$R/watch.log"
  tot=$(echo "$out" | grep '^TOTAL')
  n=$(echo "$tot" | sed -E 's/.*games=([0-9]+).*/\1/'); pct=$(echo "$tot" | sed -E 's/.*\(([0-9]+)%\).*/\1/')
  now=$(date +%s)
  [ "$n" != "$last_n" ] && { last_n=$n; last_t=$now; }
  if [ "${n:-0}" -ge 8 ] && [ "${pct:-0}" -gt 15 ]; then touch "$R/STOP"; echo "FAULT invalid ${pct}%: $tot"; exit 1; fi
  if [ $((now - last_t)) -ge 2400 ]; then touch "$R/STOP"; echo "FAULT no new game for 40 min: $tot"; exit 1; fi
done
echo "STOP present, watchdog exits"
