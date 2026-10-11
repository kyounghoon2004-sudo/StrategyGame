# Start_Game_With_Ollama.ps1 — Ollama 서버 + 게임 병행 시작
#
# 사용법:  powershell -ExecutionPolicy Bypass -File .\Start_Game_With_Ollama.ps1
# 테스트:  .\Start_Game_With_Ollama.ps1 -SkipGame   (서버/모델 확인만, 게임 미실행)
#
# 동작:
#   [1] 127.0.0.1:11434 응답 확인 → 이미 실행 중이면 그대로 재사용 (중복 시작 없음)
#       응답 없으면 'ollama serve'를 최소화 창으로 백그라운드 시작 (최대 ~20초 대기,
#       안 떠도 게임은 그대로 실행 — Advisor가 오프라인 메시지만 표시)
#   [2] 하드락 모델(qwen38-jrell-mtp-256k:latest)이 'ollama list'에 있는지 확인
#       없으면 경고만 출력 (자동 다운로드/로드/예열 일절 없음)
#   [3] 의미 모델(strategy-game-semantic-qwen06:latest) 확인 — 없으면 안내만
#       (게임 시작 시 자동 다운로드/등록/예열. 미리 받으려면 tools\ensure_semantic_model.ps1)
#   [4] Play_StrategyGame.bat로 게임 시작 (서버와 병행)
#
# 서버 종료: 최소화된 "ollama serve" 창을 닫거나
#   Stop-Process -Name ollama

param([switch]$SkipGame)

$ErrorActionPreference = "Stop"
$Endpoint = "http://127.0.0.1:11434"
$LockedModel = "qwen38-jrell-mtp-256k:latest"
$SemanticModel = "strategy-game-semantic-qwen06:latest"
$ProjectDir = $PSScriptRoot

function Find-Ollama {
    $c = Get-Command ollama -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Test-OllamaServer {
    try {
        Invoke-RestMethod -Uri "$Endpoint/api/version" -TimeoutSec 3 | Out-Null
        return $true
    } catch { return $false }
}

$ollama = Find-Ollama
if (-not $ollama) {
    throw "ollama 실행 파일을 찾을 수 없습니다 (PATH 또는 %LOCALAPPDATA%\Programs\Ollama)."
}

# [1] 서버 병행 시작
if (Test-OllamaServer) {
    Write-Host "[1/3] Ollama already running — reusing it."
} else {
    Write-Host "[1/3] Starting 'ollama serve' in background (minimized)..."
    Start-Process -FilePath $ollama -ArgumentList "serve" -WindowStyle Minimized
    $up = $false
    for ($i = 0; $i -lt 40 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 500
        $up = Test-OllamaServer
    }
    if ($up) { Write-Host "      Ollama is up." }
    else {
        Write-Warning "Ollama가 ~20초 내 응답하지 않습니다. 게임은 그대로 실행됩니다 (Advisor 오프라인 메시지)."
    }
}

# [2] 하드락 모델 확인 (경고만)
$listed = & $ollama list 2>$null
if ($listed -match [regex]::Escape($LockedModel)) {
    Write-Host "[2/4] Locked model present: $LockedModel"
    & $ollama ps 2>$null | Out-Host
} else {
    Write-Warning "[2/4] 하드락 모델 '$LockedModel' 이(가) 'ollama list'에 없습니다. Advisor가 모델 오류를 표시합니다."
}

# [3] 의미 모델 확인 (없으면 게임 시작 시 자동 다운로드/등록 — 여기서는 안내만)
if ($listed -match [regex]::Escape($SemanticModel)) {
    Write-Host "[3/4] Semantic model present: $SemanticModel"
} else {
    Write-Host "[3/4] Semantic model '$SemanticModel' 없음 — 게임 시작 시 자동 다운로드됩니다 (최초 1회 ~1142 MB)."
    Write-Host "      미리 받으려면: powershell -ExecutionPolicy Bypass -File .\tools\ensure_semantic_model.ps1"
}

# [4] 게임 시작
if ($SkipGame) {
    Write-Host "[4/4] SkipGame: launch skipped."
    return
}
Write-Host "[4/4] Launching game..."
& (Join-Path $ProjectDir "Play_StrategyGame.bat")
