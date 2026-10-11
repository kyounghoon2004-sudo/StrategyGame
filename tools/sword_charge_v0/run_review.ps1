param([switch]$Capture, [switch]$Movie, [switch]$SwordMovie)
$ErrorActionPreference = 'Stop'
$taskProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskGodot = if ($Capture -or $Movie -or $SwordMovie) { 'C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe' } else { 'C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64.exe' }
$taskOut = Join-Path $taskProject 'artifacts\sword_charge_v0'
New-Item -ItemType Directory -Path $taskOut -Force | Out-Null
$taskPreviousShadow = $env:JEV_SHADOW_ENABLE
try {
    $env:JEV_SHADOW_ENABLE = '0'
    $taskArgs = @('--path', ('"'+$taskProject+'"'), '--rendering-method', 'gl_compatibility', 'res://scenes/sword_charge_v0/review_sword_charge.tscn')
    if ($SwordMovie) {
        $taskArgs += @('--write-movie',('"'+(Join-Path $taskOut 'sword_cut_closeup.avi')+'"'),'--fixed-fps','30','--disable-vsync','--quit-after','90','--','--movie-solo')
    } elseif ($Movie) {
        $taskArgs += @('--write-movie',('"'+(Join-Path $taskOut 'full_sequence.avi')+'"'),'--fixed-fps','30','--disable-vsync','--quit-after','180','--','--movie')
    } elseif ($Capture) { $taskArgs += @('--quit-after','15000','--','--capture') }
    $taskWindowStyle = if ($Capture -or $Movie -or $SwordMovie) { 'Hidden' } else { 'Normal' }
    $taskProcess = Start-Process -FilePath $taskGodot -ArgumentList $taskArgs -WindowStyle $taskWindowStyle -RedirectStandardOutput (Join-Path $taskOut 'review.log') -RedirectStandardError (Join-Path $taskOut 'review_errors.log') -PassThru
    if ($Capture -or $Movie -or $SwordMovie) {
        if (-not $taskProcess.WaitForExit(60000)) {Stop-Process -Id $taskProcess.Id;throw 'Review exceeded 60 seconds. Inspect logs.'}
        if ($taskProcess.ExitCode -ne 0) {throw 'Godot review exited with an error.'}
        if ($Capture) {
            $taskLog = Get-Content -LiteralPath (Join-Path $taskOut 'review.log') -Raw
            if ($taskLog -notmatch 'SWORD_CHARGE_VALIDATED') {throw 'Validation marker missing.'}
            Copy-Item -LiteralPath (Join-Path $taskOut 'review.log') -Destination (Join-Path $taskOut 'validation.log')
            Get-Content -LiteralPath (Join-Path $taskOut 'runtime_validation.json')
        }
    } else {Write-Output ('Godot review PID: '+$taskProcess.Id)}
} finally {
    if ($null -eq $taskPreviousShadow) {Remove-Item Env:JEV_SHADOW_ENABLE -ErrorAction SilentlyContinue}
    else {$env:JEV_SHADOW_ENABLE = $taskPreviousShadow}
}
