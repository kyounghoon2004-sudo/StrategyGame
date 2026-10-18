@echo off
rem Collection-game board (Step0 flat sandbox, HQ vs HQ 10v10, RED = GX BASIC) with logistics bases + morale.
rem Usage: Play_Sim.bat [fixed|mild|broad|counterfactual_valid] [BULWARK|SPEARHEAD|HARRIER|OUTRIDER]
rem In game: F1-F4 map family (new seed), F8 same game again, F6 GX tier, F7 GX style. HQ selected -> "병참기지" button.
setlocal
set "GODOT_BIN=%LOCALAPPDATA%\Programs\Godot\Godot_v4.2.2-stable_win64.exe"
if not exist "%GODOT_BIN%" set "GODOT_BIN=C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe"
set "FAM=%~1"
if "%FAM%"=="" set "FAM=fixed"
start "" "%GODOT_BIN%" --path "%~dp0." --script res://tools/play_missions.gd -- SIM %FAM% BASIC %2
