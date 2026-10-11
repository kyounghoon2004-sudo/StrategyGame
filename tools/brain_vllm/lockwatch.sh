#!/usr/bin/env bash
# Wait until the project GPU lock (training_marathon_v1.lock) is free.
# Polls every 60 s; exits 0 when the lock file is gone or its pid is dead.
LOCK="D:/StrategyAI/locks/training_marathon_v1.lock"
echo "[lockwatch] watching $LOCK at $(date '+%H:%M:%S')"
while true; do
  if [ ! -f "$LOCK" ]; then
    echo "[lockwatch] FREE (no lock file) at $(date '+%H:%M:%S')"
    exit 0
  fi
  pid=$(grep -o '"pid": *[0-9]*' "$LOCK" | head -1 | grep -o '[0-9]*')
  live=$(powershell.exe -NoProfile -Command "(Get-Process -Id $pid -ErrorAction SilentlyContinue) -ne \$null" 2>/dev/null | tr -d '\r\n ')
  mtime=$(date -r "$LOCK" '+%H:%M:%S' 2>/dev/null)
  if [ "$live" != "True" ]; then
    echo "[lockwatch] STALE (pid $pid not alive, mtime $mtime) at $(date '+%H:%M:%S')"
    exit 0
  fi
  echo "[lockwatch] held by pid $pid (lock mtime $mtime) $(date '+%H:%M:%S')"
  sleep 60
done
