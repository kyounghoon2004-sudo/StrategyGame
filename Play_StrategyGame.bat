@echo off
setlocal
cd /d "%~dp0"

rem [1/2] Preflight guard: Godot resolves global class_name types through the
rem generated cache .godot/global_script_class_cache.cfg. If it is stale,
rem scripts fail to PARSE and the title screen renders dead buttons. The guard
rem verifies source-vs-cache parity and self-heals a stale cache BEFORE launch.
echo [ClassCacheGuard] preflight...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\preflight\GodotClassCacheGuard.ps1"
if errorlevel 1 (
    echo [ClassCacheGuard] Launch aborted - see details above.
    pause
    exit /b 1
)

set "GODOT_BIN=C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe"

if not exist "%GODOT_BIN%" (
    set "GODOT_BIN=C:\Users\kyoun\AppData\Local\Programs\Godot\godot-editor-win64.exe"
)

if not exist "%GODOT_BIN%" (
    set "GODOT_BIN=C:\Program Files\Godot\godot.exe"
)

if not exist "%GODOT_BIN%" (
    echo [ERROR] Godot executable not found at %GODOT_BIN%
    pause
    exit /b 1
)

echo Starting Strategy Game...
"%GODOT_BIN%"
if errorlevel 1 (
    echo.
    echo Game crashed or failed to start.
    pause
)
exit /b 0