param([switch]$Capture)
$ErrorActionPreference = 'Stop'
$taskProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskGodot = 'C:\Users\kyoun\AppData\Local\Programs\Godot\Godot_v4.2.2-stable_win64_console.exe'
$taskPreviousShadow = $env:JEV_SHADOW_ENABLE
try {
    $env:JEV_SHADOW_ENABLE = '0'
    $taskArgs = @('--path', ('"' + $taskProject + '"'), '--rendering-method', 'gl_compatibility', 'res://scenes/formation_v0/review_20man.tscn')
    if ($Capture) {
        $taskOut = Join-Path $taskProject 'artifacts\godot_20man_formation_v0'
        $taskArgs += @('--quit-after','3600','--','--capture')
        $taskProcess = Start-Process -FilePath $taskGodot -ArgumentList $taskArgs -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskOut 'capture.log') -RedirectStandardError (Join-Path $taskOut 'capture_errors.log') -PassThru
        if (-not $taskProcess.WaitForExit(60000)) {
            Stop-Process -Id $taskProcess.Id
            throw 'Review capture exceeded 60 seconds.'
        }
        $taskLog = Get-Content -LiteralPath (Join-Path $taskOut 'capture.log') -Raw
        if ($taskProcess.ExitCode -ne 0 -or $taskLog -notmatch 'GODOT_20MAN_FORMATION_VALIDATED') { throw 'Review did not complete validation. Inspect capture logs.' }
        Get-Content -LiteralPath (Join-Path $taskOut 'runtime_validation.json')
    } else {
        Start-Process -FilePath $taskGodot -ArgumentList $taskArgs -WindowStyle Hidden
    }
} finally {
    if ($null -eq $taskPreviousShadow) { Remove-Item Env:JEV_SHADOW_ENABLE -ErrorAction SilentlyContinue }
    else { $env:JEV_SHADOW_ENABLE = $taskPreviousShadow }
}
