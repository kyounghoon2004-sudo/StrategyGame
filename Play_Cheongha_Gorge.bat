@echo off
setlocal
cd /d "%~dp0"

rem Use the same class-cache preflight as the normal game launcher.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\preflight\GodotClassCacheGuard.ps1"
if errorlevel 1 (
    echo [HC01] Godot class cache preflight failed.
    pause
    exit /b 1
)

set "GODOT_BIN=C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe"
if not exist "%GODOT_BIN%" set "GODOT_BIN=C:\Users\kyoun\AppData\Local\Programs\Godot\godot-editor-win64.exe"
if not exist "%GODOT_BIN%" set "GODOT_BIN=C:\Program Files\Godot\godot.exe"
if not exist "%GODOT_BIN%" (
    echo [HC01] Godot executable not found.
    pause
    exit /b 1
)

echo Starting HC01 Cheongha Gorge in the standard battle shell...
"%GODOT_BIN%" --path "%~dp0" "res://scenes/step2r_battlefield_shell.tscn" -- --battlefield=HC01
if errorlevel 1 (
    echo [HC01] Game failed to start.
    pause
    exit /b 1
)
exit /b 0
