@echo off
setlocal
title Strategy AI Training Bridge V1
cd /d "%~dp0"

echo ========================================================
echo    Strategy AI Training Bridge V1
echo    Bound strictly to 127.0.0.1:8125  (loopback only)
echo    Supervisor target  http://127.0.0.1:8124
echo    Auth  HMAC-SHA256  (TRAINING_BRIDGE_SECRET from env)
echo    The secret value is NEVER printed by this launcher.
echo ========================================================
echo.

where python >nul 2>nul
if errorlevel 1 (
  echo [bridge] ERROR: python was not found on PATH.
  exit /b 1
)

:: Validate configuration and secret presence without starting the server.
python "%~dp0local_training_bridge.py" --config "%~dp0bridge_config.json" --check
if errorlevel 1 (
  echo.
  echo [bridge] ERROR: pre-flight check failed. See the message above.
  exit /b 1
)

echo.
echo [bridge] Pre-flight OK. Starting the bridge on http://127.0.0.1:8125/ ...
echo [bridge] Endpoints: GET  /bridge/health  GET  /bridge/status
echo                     POST /bridge/start   POST /bridge/pause
echo                     POST /bridge/resume  POST /bridge/stop
echo [bridge] Every endpoint requires a valid HMAC signature.
echo.

python "%~dp0local_training_bridge.py" --config "%~dp0bridge_config.json"

echo.
echo [bridge] exited.
endlocal
pause
