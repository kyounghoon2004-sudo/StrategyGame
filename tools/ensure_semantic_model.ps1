# ensure_semantic_model.ps1 — semantic-frontend model acquisition helper
#
# Mirrors the game's Step7SemanticModel constants (single source of truth is
# scripts/step7/step7_semantic_model.gd; keep values in sync):
#   HF repo : distil-labs/distil-home-assistant-qwen3-gguf
#   Artifact: distil-home-assistant-qwen3.gguf  (~1142 MB, F16, sole artifact)
#   Tag     : strategy-game-semantic-qwen06:latest
#
# The game itself performs this automatically at startup (download once,
# register once, warm every launch). This script is the manual/dev
# equivalent: download (resumable) -> size check -> write Modelfile ->
# `ollama create` -> warm. Idempotent: skips download when the cache is
# intact, skips registration when the tag exists.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\tools\ensure_semantic_model.ps1

param([switch]$Force)

$ErrorActionPreference = "Stop"
$HfRepo = "distil-labs/distil-home-assistant-qwen3-gguf"
$HfFile = "distil-home-assistant-qwen3.gguf"
$HfBranch = "main"
$ExpectedBytes = 1198182624
$SlackBytes = 8388608
$Tag = "strategy-game-semantic-qwen06:latest"
$Url = "https://huggingface.co/$HfRepo/resolve/$HfBranch/$HfFile"
$CacheDir = Join-Path $env:LOCALAPPDATA "StrategyGame\models"
$Gguf = Join-Path $CacheDir $HfFile
$Modelfile = Join-Path $CacheDir "Modelfile.semantic-qwen06"

function Find-Ollama {
    $c = Get-Command ollama -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

$ollama = Find-Ollama
if (-not $ollama) { throw "ollama executable not found." }
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

# [1] Cache check (size gate against upstream metadata).
$needDl = $true
if ((Test-Path -LiteralPath $Gguf) -and (-not $Force)) {
    $sz = (Get-Item -LiteralPath $Gguf).Length
    if ([Math]::Abs($sz - $ExpectedBytes) -le $SlackBytes) {
        Write-Host "[1/4] Cache intact: $Gguf ($([int]($sz / 1MB)) MB). Skipping download."
        $needDl = $false
    } else {
        Write-Warning "[1/4] Cache size mismatch ($sz bytes). Re-downloading."
        Remove-Item -LiteralPath $Gguf -Force -ErrorAction SilentlyContinue
    }
}
if ($needDl) {
    Write-Host "[1/4] Downloading $Url (~$([int]($ExpectedBytes / 1MB)) MB, first run only)..."
    # curl.exe ships with Windows and supports resume (-C -) + retries.
    & curl.exe -fL --retry 5 --retry-all-errors -C - -o $Gguf $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE). Re-run to resume." }
    $sz2 = (Get-Item -LiteralPath $Gguf).Length
    if ([Math]::Abs($sz2 - $ExpectedBytes) -gt $SlackBytes) {
        throw "Size mismatch after download ($sz2 bytes). Delete and re-run."
    }
    Write-Host "      Verified: $sz2 bytes."
}

# [2] Modelfile (native template: Qwen3 turns + thinking DISABLED block).
$ggufSlash = $Gguf -replace '\\', '/'
$templateLines = @(
    "FROM `"$ggufSlash`"",
    'TEMPLATE """{{- range $i, $m := .Messages -}}<|im_start|>{{ $m.Role }}',
    '{{ $m.Content }}<|im_end|>',
    '{{ end -}}<|im_start|>assistant',
    '<think>',
    '',
    '</think>',
    '',
    '"""',
    'PARAMETER temperature 0.0',
    'PARAMETER num_ctx 4096',
    'PARAMETER num_predict 1024',
    'PARAMETER stop "<|im_end|>"',
    'PARAMETER stop "<|im_start|>"'
)
[System.IO.File]::WriteAllLines($Modelfile, $templateLines, [System.Text.Encoding]::UTF8)
Write-Host "[2/4] Modelfile written: $Modelfile"

# [3] Register (skip when present).
$listed = & $ollama list 2>$null
if (($listed -match [regex]::Escape($Tag)) -and (-not $Force)) {
    Write-Host "[3/4] Tag present: $Tag. Skipping registration."
} else {
    Write-Host "[3/4] Registering $Tag ..."
    & $ollama create $Tag -f $Modelfile
    if ($LASTEXITCODE -ne 0) { throw "ollama create failed." }
}

# [4] Warm into VRAM (residency; keep_alive mirrors game default 12h).
Write-Host "[4/4] Warming into VRAM..."
$payload = @{
    model = $Tag; stream = $false; keep_alive = "12h"; think = $false
    options = @{ temperature = 0.0; num_predict = 8; num_ctx = 512 }
    messages = @(
        @{ role = "system"; content = "You are a local game preload endpoint." },
        @{ role = "user"; content = "Reply with exactly: READY." }
    )
} | ConvertTo-Json -Depth 6 -Compress
$t0 = Get-Date
$r = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/chat" -Method Post `
    -Body $payload -ContentType "application/json" -TimeoutSec 300
$ms = [int]((Get-Date) - $t0).TotalMilliseconds
Write-Host "      Warm reply: [$($r.message.content)] in ${ms}ms."
& $ollama ps 2>$null | Out-Host
Write-Host "SEMANTIC READY ($Tag)."
