# GodotClassCacheGuard.ps1 — preflight guard for Godot's global class registry
#
# WHY THIS EXISTS
# Godot resolves global `class_name` types through the generated cache
# .godot/global_script_class_cache.cfg. If that cache goes stale (new scripts
# added while the engine never completed a full editor rescan), scripts that
# reference those types fail to PARSE — and the failure cascades
# (chicken-and-egg): new panel scripts cannot parse because their dependency
# classes are unregistered, so their own class_name never registers either.
# Real failure seen 2026-09-23: title_screen.gd referenced AISSetupPanel; the
# cache held 61 of 190 declarations; the title screen rendered 4 dead static
# buttons because _ready() never ran. A plain editor rescan does NOT self-heal
# this cascade, so this guard performs the deterministic
# filesystem-ground-truth rebuild that proved successful.
#
# CONTRACT
#   exit 0  -> cache healthy or repaired+verified: launch Godot
#   exit 1  -> guard failed: DO NOT launch; details in the log file
#
# Scan ground truth = every .gd under <project>/scripts and <project>/addons
# (recursively). These are the only trees whose class_name declarations Godot
# registers; files elsewhere (tools probes, evidence backups, artifacts) are
# deliberately excluded — this matches the proven repair exactly.
#
# Never edits source files; never deletes unrelated .godot state; rebuilds
# only the generated cache via atomic temp-file replacement.

[CmdletBinding()]
param(
    [switch]$Quiet,
    # Test/diagnostic override: scan these directories instead of the default
    # scripts/+addons roots. NEVER used by the launcher; lets fixture tests
    # exercise the scan/duplicate logic without touching production source.
    [string[]]$ScanDirs = @()
)

$ErrorActionPreference = "Stop"

# ── Paths ────────────────────────────────────────────────────────────────────
$ProjectDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # tools/preflight -> project root
$ScriptsDir = Join-Path $ProjectDir "scripts"
$AddonsDir  = Join-Path $ProjectDir "addons"
$GodotDir   = Join-Path $ProjectDir ".godot"
$CachePath  = Join-Path $GodotDir "global_script_class_cache.cfg"
$LogDir     = Join-Path $GodotDir "class_cache_guard"
$LogPath    = Join-Path $LogDir "guard.log"
$StatusPath = Join-Path $GodotDir "class_cache_guard_status.json"

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8
    } catch { }
}

function Fail([string]$msg, [string[]]$details = @()) {
    Write-Log ("FAIL: {0}" -f $msg)
    foreach ($d in $details) { Write-Log ("  {0}" -f $d) }
    if (-not $Quiet) {
        Write-Host ("[ClassCacheGuard] FAIL: {0}" -f $msg) -ForegroundColor Red
        foreach ($d in $details) { Write-Host ("  {0}" -f $d) -ForegroundColor DarkGray }
        Write-Host ("[ClassCacheGuard] details: {0}" -f $LogPath) -ForegroundColor Yellow
    }
    exit 1
}

# ── Ground truth: scan source class_name declarations ────────────────────────
# class_name is a top-level GDScript statement; the proven repair accepted
# optional leading whitespace and that superset booted correctly, so keep it.
$RxClass = [regex]'(?m)^[ \t]*class_name[ \t]+([A-Za-z_][A-Za-z0-9_]*)'

function Res-Path([string]$fsPath) {
    return ("res://" + $fsPath.Substring($ProjectDir.Length + 1).Replace('\', '/'))
}

function Get-SourceDeclarations {
    $fsMap      = @{}                                                    # class -> filesystem path
    $dupes      = [System.Collections.Generic.List[string]]::new()
    $unreadable = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $(if ($ScanDirs.Count -gt 0) { $ScanDirs } else { @($ScriptsDir, $AddonsDir) })) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $files = Get-ChildItem -LiteralPath $root -Recurse -Filter *.gd -File |
                 Where-Object { $_.FullName -notmatch '\\\.godot\\' }
        foreach ($f in $files) {
            $src = $null
            try { $src = [System.IO.File]::ReadAllText($f.FullName) } catch { }
            if ($null -eq $src) { $unreadable.Add($f.FullName); continue }
            foreach ($m in $RxClass.Matches($src)) {
                $cls = $m.Groups[1].Value
                if ($fsMap.ContainsKey($cls) -and $fsMap[$cls] -ne $f.FullName) {
                    # NOTE: inside method-call parens, -f binds only the next
                    # expression — hoist the format into a variable first.
                    $dupeDesc = "{0}  ({1} <-> {2})" -f $cls, (Res-Path $fsMap[$cls]), (Res-Path $f.FullName)
                    $dupes.Add($dupeDesc)
                } else {
                    $fsMap[$cls] = $f.FullName
                }
            }
        }
    }
    $map = @{}
    foreach ($k in $fsMap.Keys) { $map[$k] = Res-Path $fsMap[$k] }
    return @{ map = $map; dupes = $dupes; unreadable = $unreadable }
}

# ── Cache reading (fault-tolerant; malformed entries are reported) ───────────
function Read-Cache {
    param([string]$Path)
    $entries   = @{}                                                  # class -> res:// path
    $malformed = [System.Collections.Generic.List[string]]::new()
    $exists    = (Test-Path -LiteralPath $Path)
    if (-not $exists) {
        return @{ entries = $entries; malformed = $malformed; exists = $false }
    }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($Path) } catch { }
    if ($null -eq $text) {
        $malformed.Add("file unreadable")
        return @{ entries = $entries; malformed = $malformed; exists = $true }
    }
    # Entries appear as '"class": &"Name"' followed within a few lines by
    # '"path": "res://..."'. A broken entry (missing/unbalanced path line) is
    # caught as malformed instead of silently dropped.
    $cm = [regex]::Matches($text, '"class":\s*&"([^"]+)"')
    $pm = [regex]::Matches($text, '"path":\s*"([^"]+)"')
    if ($cm.Count -ne $pm.Count) {
        $pairDesc = "class/path pair count mismatch ({0} vs {1})" -f $cm.Count, $pm.Count
        $malformed.Add($pairDesc)
    }
    $n = [Math]::Min($cm.Count, $pm.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $cls  = $cm[$i].Groups[1].Value
        $path = $pm[$i].Groups[1].Value
        if ($entries.ContainsKey($cls)) { $malformed.Add("duplicate cache entry: $cls") }
        else { $entries[$cls] = $path }
    }
    return @{ entries = $entries; malformed = $malformed; exists = $true }
}

# ── Compare source vs cache ──────────────────────────────────────────────────
function Compare-Registry {
    param($Source, $Cache)
    $missing   = [System.Collections.Generic.List[string]]::new()
    $stale     = [System.Collections.Generic.List[string]]::new()
    $wrongPath = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Source.map.Keys) {
        if (-not $Cache.entries.ContainsKey($k)) { $missing.Add($k) }
        elseif ($Cache.entries[$k] -ne $Source.map[$k]) {
            $wpDesc = "{0}: cache={1} source={2}" -f $k, $Cache.entries[$k], $Source.map[$k]
            $wrongPath.Add($wpDesc)
        }
    }
    foreach ($k in $Cache.entries.Keys) {
        if (-not $Source.map.ContainsKey($k)) {
            $staleDesc = "{0} -> {1}" -f $k, $Cache.entries[$k]
            $stale.Add($staleDesc)
        }
    }
    return @{ missing = $missing; stale = $stale; wrongPath = $wrongPath }
}

# ── Rebuild (the proven filesystem-ground-truth algorithm) ───────────────────
# Godot 4.2 format, byte-compatible with the proven repair: 2-space indents,
# StringName values (&"...") for base/class/language, plain strings for icon/
# path, NO trailing comma on the path line, element separator inside "}, {".
function New-CacheText {
    param($Source)
    $sb    = [System.Text.StringBuilder]::new()
    $items = @($Source.map.GetEnumerator() | Sort-Object Key)
    [void]$sb.Append("list=Array[Dictionary]([{`n")
    for ($i = 0; $i -lt $items.Count; $i++) {
        $cls  = $items[$i].Key
        $path = $items[$i].Value
        [void]$sb.Append('  "base": &"RefCounted",' + "`n")
        [void]$sb.Append('  "class": &"' + $cls + '",' + "`n")
        [void]$sb.Append('  "icon": "",' + "`n")
        [void]$sb.Append('  "language": &"GDScript",' + "`n")
        [void]$sb.Append('  "path": "' + $path + '"' + "`n")
        if ($i -lt $items.Count - 1) { [void]$sb.Append("  }, {`n") }
    }
    [void]$sb.Append("  }`n")
    [void]$sb.Append("])")
    return $sb.ToString()
}

function Repair-Cache {
    param($Source)
    if (-not (Test-Path -LiteralPath $GodotDir)) {
        New-Item -ItemType Directory -Path $GodotDir -Force | Out-Null
    }
    $text = New-CacheText $Source
    $tmp  = Join-Path $GodotDir ("global_script_class_cache.cfg.tmp.{0}" -f $PID)
    $bak  = Join-Path $GodotDir "global_script_class_cache.cfg.guardbak"
    try {
        [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $CachePath) {
            # Atomic on NTFS. NOTE: this box rejects a null backup path
            # ("invalid file name"), so a real .guardbak path is required;
            # it is removed right after the swap is verified.
            [System.IO.File]::Replace($tmp, $CachePath, $bak)
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item -LiteralPath $tmp -Destination $CachePath  # first creation
        }
    } catch {
        # Fallback: overwrite copy (not atomic, but only reached if Replace
        # itself is unavailable; content is already verified below anyway).
        try {
            [System.IO.File]::Copy($tmp, $CachePath, $true)
        } catch {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            throw
        }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    # Re-read from disk and verify exact parity before declaring success.
    $cache2 = Read-Cache -Path $CachePath
    if ($cache2.malformed.Count -gt 0) {
        throw ("repaired cache still malformed: {0}" -f ($cache2.malformed -join "; "))
    }
    $diff = Compare-Registry -Source $Source -Cache $cache2
    if ($diff.missing.Count -gt 0 -or $diff.stale.Count -gt 0 -or $diff.wrongPath.Count -gt 0) {
        throw ("repair verification failed: missing={0} stale={1} wrong_path={2}" -f `
            $diff.missing.Count, $diff.stale.Count, $diff.wrongPath.Count)
    }
}

# ── Optional generated status file ───────────────────────────────────────────
function Write-Status {
    param([string]$Status, [bool]$Repaired, $Source, [int]$CacheCount, $Diff)
    try {
        $obj = [ordered]@{
            timestamp    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            source_count = $Source.map.Count
            cache_count  = $CacheCount
            status       = $Status
            repaired     = $Repaired
            missing      = @($Diff.missing)
            stale        = @($Diff.stale)
            wrong_path   = @($Diff.wrongPath)
        }
        [System.IO.File]::WriteAllText($StatusPath, ($obj | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ── Main ─────────────────────────────────────────────────────────────────────
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not (Test-Path -LiteralPath (Join-Path $ProjectDir "project.godot"))) {
    Fail ("project.godot not found under '{0}'" -f $ProjectDir)
}
# Fixture mode (-ScanDirs) is diagnostic only: it must never rebuild the
# canonical cache from partial ground truth nor touch the real status file.
$FixtureMode = ($ScanDirs.Count -gt 0)

$source = Get-SourceDeclarations
if ($source.unreadable.Count -gt 0) {
    Fail ("unreadable .gd files: {0}" -f ($source.unreadable -join ", "))
}
if ($source.dupes.Count -gt 0) {
    Fail "duplicate class_name declaration(s) - refusing to generate an ambiguous registry" $source.dupes
}

$cache = Read-Cache -Path $CachePath
$diff  = Compare-Registry -Source $source -Cache $cache

if ($diff.missing.Count -eq 0 -and $diff.stale.Count -eq 0 -and $diff.wrongPath.Count -eq 0 -and $cache.malformed.Count -eq 0) {
    Write-Log ("PASS classes={0} duration_ms={1}" -f $source.map.Count, $sw.ElapsedMilliseconds)
    if (-not $Quiet) {
        Write-Host ("[ClassCacheGuard] PASS classes={0}" -f $source.map.Count) -ForegroundColor Green
    }
    if (-not $FixtureMode) {
        Write-Status -Status "PASS" -Repaired $false -Source $source -CacheCount $cache.entries.Count -Diff $diff
    }
    exit 0
}

# ── Self-heal path ───────────────────────────────────────────────────────────
# Fixture mode (-ScanDirs) is diagnostic only: report findings, never rebuild
# the canonical cache from partial ground truth, never touch the real status.
if ($FixtureMode) {
    Write-Log "FIXTURE-MODE report-only: repair suppressed"
    if (-not $Quiet) {
        Write-Host "[ClassCacheGuard] FIXTURE-MODE report-only (no repair)" -ForegroundColor Cyan
    }
    exit 0
}
$diag = "source={0} cache={1} missing={2} stale={3} wrong_path={4} malformed={5}" -f `
    $source.map.Count, $cache.entries.Count, $diff.missing.Count, $diff.stale.Count, $diff.wrongPath.Count, $cache.malformed.Count
Write-Log ("STALE {0}" -f $diag)
foreach ($m in $diff.missing)    { Write-Log ("  missing: {0}" -f $m) }
foreach ($s in $diff.stale)      { Write-Log ("  stale:   {0}" -f $s) }
foreach ($w in $diff.wrongPath)  { Write-Log ("  wrong:   {0}" -f $w) }
foreach ($m in $cache.malformed) { Write-Log ("  malform: {0}" -f $m) }
if (-not $Quiet) {
    # Console stays concise (full lists are in the guard log): show at most
    # 8 items per category, then a summary line.
    function Show-Capped([string]$tag, $list) {
        $i = 0
        foreach ($item in $list) {
            if ($i -ge 8) { break }
            Write-Host ("  {0} {1}" -f $tag, $item) -ForegroundColor DarkYellow
            $i++
        }
        if ($list.Count -gt 8) {
            Write-Host ("  {0} ... and {1} more (full list in guard log)" -f $tag, ($list.Count - 8)) -ForegroundColor DarkYellow
        }
    }
    Write-Host ("[ClassCacheGuard] STALE {0}" -f $diag) -ForegroundColor Yellow
    Show-Capped "missing:" $diff.missing
    Show-Capped "stale:"   $diff.stale
    Show-Capped "wrong:"   $diff.wrongPath
    Show-Capped "malform:" $cache.malformed
}

try {
    Repair-Cache -Source $source
} catch {
    Fail ("repair failed: {0}" -f $_.Exception.Message)
}

Write-Log ("REPAIRED classes={0} duration_ms={1}" -f $source.map.Count, $sw.ElapsedMilliseconds)
if (-not $Quiet) {
    Write-Host ("[ClassCacheGuard] REPAIRED classes={0}" -f $source.map.Count) -ForegroundColor Green
}
Write-Status -Status "REPAIRED" -Repaired $true -Source $source -CacheCount $source.map.Count `
    -Diff @{ missing = @(); stale = @(); wrongPath = @() }
exit 0
