@echo off
rem Play against Qwen, COMBINED rules: win by destroying the enemy HQ OR 70% of its other units; lose if your HQ falls OR you lose 70%.
cd /d "%~dp0"
set PYTHONIOENCODING=utf-8
"D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe" -m tools.cmd_rl.play_vs_qwen --mission both %*
pause
