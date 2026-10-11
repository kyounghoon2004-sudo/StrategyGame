# CSFT5 HUMAN GAMEPLAY TEST — launcher for "DEV: Human vs Local (Qwen 8B)".
#
#   powershell -ExecutionPolicy Bypass -File "tools\contract_sft\launch_csft5_human_test.ps1"
#
# The game itself now owns the local CSFT5 Brain (Cloud2LocalBrainLauncher):
# choosing "DEV: Human vs Local (Qwen 8B)" on the title screen starts/verifies
# the server, auto-tests the connection, and runs STRICT (no repair / retry /
# fallback). No Ollama, no cloud settings, no saved connection file.
# This script only adds: preflight (RL paused, nothing training, GPU lock free)
# and captures the game log into the same session folder as the server
# telemetry so tools\contract_sft\stop_csft5_human_test.ps1 can join them.
$ErrorActionPreference = "Stop"
$Proj = "D:\Game development\Demon slayer\StrategyGame"
$Godot = "C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe"
$Marathon = Join-Path $Proj "artifacts\training_marathon_v1"
$Lock = "D:\StrategyAI\locks\training_marathon_v1.lock"
$Session = "human_" + (Get-Date -Format "yyyyMMdd_HHmmss")
$SessDir = Join-Path $Proj "artifacts\contract_sft_v1\human_benchmark\$Session"
New-Item -ItemType Directory -Force $SessDir | Out-Null

Write-Host "== preflight =="
foreach ($m in "PAUSE_RL_BEFORE_TRAIN", "STOP_REQUESTED") {
    if (-not (Test-Path (Join-Path $Marathon $m))) { throw "RL pause marker missing: $m (refusing to launch)" }
}
$busy = Get-CimInstance Win32_Process -Filter "Name like 'python%'" | Where-Object {
    $_.CommandLine -match "marathon_runner|marathon_phase|train_sft|contract_sft\.generate" }
if ($busy) { throw "training/RL/sampling process running: $($busy.ProcessId -join ',')" }
if (Test-Path $Lock) {
    $j = Get-Content $Lock -Raw | ConvertFrom-Json
    if ((Get-Process -Id $j.pid -ErrorAction SilentlyContinue) -and $j.run_id -ne "csft5_brain_server") {
        throw "GPU lock held by live pid $($j.pid) ($($j.purpose))" }
}
Write-Host "RL paused (markers present); no training process; GPU free for the Brain."

$prev = $env:LOCAL_BRAIN_SESSION
$env:LOCAL_BRAIN_SESSION = $Session
$game = Start-Process -FilePath $Godot -ArgumentList "--path", "`"$Proj`"" -WorkingDirectory $Proj `
    -RedirectStandardOutput (Join-Path $SessDir "game.log") -RedirectStandardError (Join-Path $SessDir "game.err.log") -PassThru
$env:LOCAL_BRAIN_SESSION = $prev
$game.Id | Out-File -Encoding ascii (Join-Path $SessDir "game.pid")
Write-Host ""
Write-Host "GAME LAUNCHED (pid $($game.Id)). Session folder: $SessDir"
Write-Host "  Title screen -> 'DEV: Human vs Local (Qwen 8B)'. The HUD line 'RED BRAIN: LOCAL Qwen3-8B CSFT5'"
Write-Host "  turns green (READY | CONNECTED) when the Brain is loaded (~40 s). Wait for it before ending BLUE turn 1."
Write-Host "After quitting the game: powershell -ExecutionPolicy Bypass -File `"$Proj\tools\contract_sft\stop_csft5_human_test.ps1`" -Session $Session"
