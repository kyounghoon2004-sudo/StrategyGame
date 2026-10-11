# JEV shadow inference worker launcher (SHADOW ONLY) — LEGACY / DEBUG ONLY.
# The game now owns the worker lifecycle automatically (single-launch):
# normal play never needs this script. Keep it for manual fixed-endpoint
# debugging with JEV_SHADOW_URL=http://127.0.0.1:11439 (Godot reuses the
# endpoint only after a strict identity handshake, never kills it).
# The worker loads jev-policy-v0.6.0-mission1 (seed205) ONCE after verifying
# its SHA-256, then serves single-decision inference until stopped.
# Usage: powershell -ExecutionPolicy Bypass -File Start_JevShadowWorker.ps1 [-Port 11439]
param([int]$Port = 11439)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = "C:\Users\kyoun\AppData\Local\Programs\Python\Python313\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

Write-Host "[jev-shadow] starting worker on 127.0.0.1:$Port ..."
& $py -u "$root\tools\jev_shadow\worker.py" --host 127.0.0.1 --port $Port
