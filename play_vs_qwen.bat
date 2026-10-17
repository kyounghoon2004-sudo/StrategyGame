@echo off
rem Play against the local Qwen 9B (YOU = BLUE, Qwen = RED, collapse mission). Needs ~3 min for vLLM to load.
rem Win: destroy 70%+ of RED's non-HQ units. Lose: you lose 70%+ or your HQ falls. End Turn button hands the round to Qwen.
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe" -m tools.cmd_rl.play_vs_qwen %*
pause
