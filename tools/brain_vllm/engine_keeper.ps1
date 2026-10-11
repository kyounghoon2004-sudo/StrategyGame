# BRAIN_VLLM_PHASE1 — detached ENGINE keeper (the WMI target).
#
# This host's command wrappers run commands inside Windows job objects and kill
# every child when the wrapping call ends; WSL also stops the distro ~18 s after
# the last wsl.exe session exits. The engine therefore needs ONE long-lived
# owner outside any caller's job. Launch THIS script via WMI so it lives under
# WmiPrvSE.exe (survives the launching call/session):
#
#   Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
#     CommandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<this file>" -GpuUtil 0.5651' }
#
# It runs the engine in the FOREGROUND of its wsl.exe session (the canonical
# common.engine_start layout: the engine lives exactly as long as this keeper).
param([double]$GpuUtil = 0.5651, [string]$Log = "")

$ROOT = "D:\Game development\Demon slayer\StrategyGame"
if (-not $Log) {
    $Log = Join-Path $ROOT "artifacts\brain_pipeline_v1\vllm\logs\vllm_engine_keeper.log"
}
$bash = "cd /opt/brain_vllm && VLLM_GPU_UTIL=$GpuUtil exec bash /opt/brain_vllm/run_vllm.sh"
& wsl.exe -d Ubuntu-24.04 -u root -- bash -lc $bash 1>> $Log 2>&1
