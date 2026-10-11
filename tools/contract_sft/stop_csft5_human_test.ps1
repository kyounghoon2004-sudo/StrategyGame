# Stop the CSFT5 human test: graceful Brain-server shutdown (releases the GPU lock),
# then build the joined telemetry report for the session.
#   powershell -ExecutionPolicy Bypass -File "tools\contract_sft\stop_csft5_human_test.ps1" [-Session human_YYYYMMDD_HHMMSS]
param([string]$Session = "")
$Proj = "D:\Game development\Demon slayer\StrategyGame"
$Py = "D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe"
$Root = Join-Path $Proj "artifacts\contract_sft_v1\human_benchmark"
if (-not $Session) { $Session = (Get-ChildItem $Root -Directory -Filter "human_*" | Sort-Object Name | Select-Object -Last 1).Name }
$SessDir = Join-Path $Root $Session
try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8096/admin/shutdown" -TimeoutSec 5 | Out-Null; Write-Host "Brain server stopping." }
catch { Write-Host "Brain server not reachable (already stopped?)." }
Start-Sleep -Seconds 5
$pidFile = Join-Path $SessDir "server.pid"
if (Test-Path $pidFile) {
    $sp = [int](Get-Content $pidFile)
    if (Get-Process -Id $sp -ErrorAction SilentlyContinue) { Write-Host "server pid $sp still alive after graceful stop; stopping it."; Stop-Process -Id $sp -Force }
}
Push-Location $Proj
& $Py -B -m tools.contract_sft.human_benchmark_report $SessDir
Pop-Location
Write-Host "Report: $SessDir\HUMAN_BENCHMARK_REPORT.json"
