@echo off
REM Stop the vLLM-backed Brain service. Usage: stop.cmd [--hard-engine]
setlocal
set PY=D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe
cd /d "%~dp0..\.."
"%PY%" -u -m tools.brain_vllm.client stop %*
endlocal
