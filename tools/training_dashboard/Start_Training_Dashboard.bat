@echo off
title Strategy AI Training Dashboard V1
cd /d "%~dp0"

echo ========================================================
echo    Strategy AI Training Dashboard V1
echo    Bound strictly to 127.0.0.1 (Local Only)
echo ========================================================
echo.
echo Starting local supervisor on http://127.0.0.1:8124/ ...
echo.

:: Open browser in background after short delay
start "" cmd /c "timeout /t 2 /nobreak >nul & start http://127.0.0.1:8124/"

:: Run supervisor server
python "%~dp0training_dashboard_server.py" --port 8124

pause
