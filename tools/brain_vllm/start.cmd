@echo off
REM Start the vLLM-backed Brain service (shim on 127.0.0.1:8096).
REM Usage: start.cmd [adapter_dir] [session] [capture_dir]
setlocal
set PY=D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe
set ADAPTER=%~1
if "%ADAPTER%"=="" set ADAPTER=%~dp0..\..\artifacts\contextual_brain_s0b\candidate_S0B
set SESSION=%~2
if "%SESSION%"=="" set SESSION=manual_%RANDOM%%RANDOM%
set CAP=%~3
if "%CAP%"=="" set CAP=%~dp0..\..\artifacts\brain_pipeline_v1\vllm\manual_capture\%SESSION%
cd /d "%~dp0..\.."
"%PY%" -u -m tools.brain_vllm.client start --adapter "%ADAPTER%" --session "%SESSION%" --capture-dir "%CAP%"
endlocal
