# BRAIN_VLLM_PHASE1 — detached SERVICE keeper (the WMI target).
#
# Same reason as engine_keeper.ps1: the shim (tools.brain_vllm.service) must
# outlive the launching call. WMI-launch this script:
#
#   Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
#     CommandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<this file>" -Adapter <dir> -Session <tok> -CaptureDir <dir>' }
#
# The shim owns its engine session (starts/reuses/wakes the vLLM engine) and
# serves the full serve contract on 127.0.0.1:8096 until /admin/shutdown.
param([Parameter(Mandatory = $true)][string]$Adapter,
      [Parameter(Mandatory = $true)][string]$Session,
      [Parameter(Mandatory = $true)][string]$CaptureDir,
      [double]$GpuMemGb = 13.5,
      [int]$Port = 8096)

$ROOT = "D:\Game development\Demon slayer\StrategyGame"
$PY = "D:\StrategyAI\runtimes\qwen3_8b_rl_v0\.venv\Scripts\python.exe"
Set-Location $ROOT
& $PY -u -m tools.brain_vllm.service --adapter $Adapter --session $Session `
    --capture-dir $CaptureDir --gpu-mem-gb $GpuMemGb --port $Port
