@echo off
rem Tutorial maps M1-M5 (BLUE = you, RED = mission GX, MissionRules judges, morale on).
rem Usage: Play_Tutorials.bat [T1..T5] [BASIC|INTER|ADV] [BULWARK|SPEARHEAD|HARRIER|OUTRIDER]
rem In game: F1-F5 tutorial M1-M5, F8 same map again, F6 GX tier, F7 GX style, B build base.
setlocal
set "GODOT_BIN=%LOCALAPPDATA%\Programs\Godot\Godot_v4.2.2-stable_win64.exe"
if not exist "%GODOT_BIN%" set "GODOT_BIN=C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe"
set "MAP=%~1"
if "%MAP%"=="" set "MAP=T1"
start "" "%GODOT_BIN%" --path "%~dp0." --script res://tools/play_missions.gd -- %MAP% %2 %3
