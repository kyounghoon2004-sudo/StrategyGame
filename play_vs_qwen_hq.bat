@echo off
rem Play against the local Qwen 9B, HQ mission (YOU = BLUE, Qwen = RED, 10v10, destroy the enemy HQ, 60 turns).
rem The collapse version is play_vs_qwen.bat. Run only one of them at a time (vLLM, ports).
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe" -m tools.cmd_rl.play_vs_qwen --mission hq %*
pause
