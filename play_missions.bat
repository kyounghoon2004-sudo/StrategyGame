@echo off
rem Mission play (BLUE = you, RED = mission GX). F1-F5 mission, F8 same map, F6 tier, F7 style, B build base.
start "" "C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe" --path "%~dp0." --script res://tools/play_missions.gd -- %*
