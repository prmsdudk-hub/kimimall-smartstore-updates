param(
    [Parameter(Mandatory=$true)][string]$Root,
    [ValidateSet('Startup','Manual')][string]$Mode = 'Startup',
    [int]$WaitPid = 0,
    [switch]$Restart
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ManifestUrl = 'https://raw.githubusercontent.com/prmsdudk-hub/kimimall-smartstore-updates/main/admin-channel/stable/manifest.json'
$State = Join-Path $env:LOCALAPPDATA 'KimimallAdminUpdater'
$LogDir = Join-Path $State 'logs'
$BackupRoot = Join-Path $State 'backups'
$StagingRoot = Join-Path $State 'staging'
$LastResult = Join-Path $State 'last_result.json'
$LastAutoCheck = Join-Path $State 'last_auto_check.txt'
New-Item -ItemType Directory -Force -Path $LogDir,$BackupRoot,$StagingRoot | Out-Null
$LogFile = Join-Path $LogDir ('update_' + (Get-Date -Format 'yyyyMMdd') + '.log')

function Log([string]$Text) {
    $line = ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    if ($Mode -eq 'Manual') { Write-Host $line }
}
function Save-Result([string]$Status, [string]$Message, [string]$Version) {
    [ordered]@{time=(Get-Date).ToString('o');status=$Status;message=$Message;version=$Version} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LastResult -Encoding UTF8
}
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Safe-Target([string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'Empty update path.' }
    $rel = $Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|[\\/])\.\.([\\/]|$)') { throw ('Unsafe update path: ' + $Relative) }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\\') + '\\'
    $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw ('Update path escaped root: ' + $Relative) }
    return $full
}
function Get-RemoteText([string]$Url, [int]$TimeoutSec = 8) {
    $joiner = if ($Url.Contains('?')) {'&'} else {'?'}
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $r = Invoke-WebRequest -UseBasicParsing -Uri ($Url + $joiner + 't=' + $stamp) -TimeoutSec $TimeoutSec -Headers @{
        'Cache-Control'='no-cache'; 'User-Agent'='kimimall-admin-updater/1.2'
    }
    return [string]$r.Content
}
function Restart-App {
    if (-not $Restart) { return }
    $start = Join-Path $Root 'START_KIMIMALL_ADMIN.cmd'
    if (Test-Path -LiteralPath $start) { Start-Process -FilePath $start -WorkingDirectory $Root }
}
function Should-AutoCheck {
    if ($Mode -eq 'Manual') { return $true }
    if (-not (Test-Path -LiteralPath $LastAutoCheck)) { return $true }
    try {
        $last = [DateTime]::Parse((Get-Content -LiteralPath $LastAutoCheck -Raw).Trim())
        return (((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalHours -ge 6)
    } catch { return $true }
}

$mutex = New-Object System.Threading.Mutex($false, 'KimimallAdminUpdaterMutex')
$hasMutex = $false
try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { Log 'Another updater instance is active; skipping.'; Restart-App; exit 0 }

    if ($WaitPid -gt 0) {
        Log ('Waiting for app process ' + $WaitPid + ' to exit.')
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 250
        }
        if (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) { throw 'The running app did not exit in time.' }
    }

    $versionFile = Join-Path $Root 'VERSION.json'
    $localVersion = '0.0.0'
    if (Test-Path -LiteralPath $versionFile) {
        try { $localVersion = [string]((Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8 | ConvertFrom-Json).version) } catch {}
    }

    if (-not (Should-AutoCheck)) { Log 'Automatic update check throttled.'; Restart-App; exit 0 }
    if ($Mode -eq 'Startup') { Set-Content -LiteralPath $LastAutoCheck -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII }

    Log ('Checking stable manifest. Local=' + $localVersion)
    try { $manifest = (Get-RemoteText $ManifestUrl 8) | ConvertFrom-Json }
    catch {
        Log ('Network/manifest check failed: ' + $_.Exception.Message)
        Save-Result 'check_failed' $_.Exception.Message $localVersion
        Restart-App; exit 0
    }

    if ([string]$manifest.product -ne 'kimimall_admin' -or [string]$manifest.channel -ne 'stable') { throw 'Manifest product/channel mismatch.' }
    $remoteVersion = [string]$manifest.version
    try { $localV=[version]$localVersion; $remoteV=[version]$remoteVersion } catch { throw 'Invalid semantic version in manifest.' }
    if ($remoteV -le $localV) { Log ('No update. Remote=' + $remoteVersion); Save-Result 'up_to_date' 'No update required.' $localVersion; Restart-App; exit 0 }

    $files = @($manifest.files)
    $deletes = @($manifest.delete)
    if ($files.Count -eq 0 -and $deletes.Count -eq 0) { throw 'Manifest contains no managed changes.' }
    $baseUrl = [string]$manifest.base_url
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw 'Manifest base_url is missing.' }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $staging = Join-Path $StagingRoot ($remoteVersion + '_' + $stamp)
    $backup = Join-Path $BackupRoot ($localVersion + '_to_' + $remoteVersion + '_' + $stamp)
    New-Item -ItemType Directory -Force -Path $staging,$backup | Out-Null
    $changes = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[object]

    Log ('Preparing update ' + $localVersion + ' -> ' + $remoteVersion)
    foreach ($f in $files) {
        $rel=[string]$f.path; $source=if ($f.source){[string]$f.source}else{$rel}; $expected=([string]$f.sha256).ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw ('Invalid SHA256 for ' + $rel) }
        $target=Safe-Target $rel
        if (Test-Path -LiteralPath $target) { try { if ((Get-Sha256 $target) -eq $expected) { continue } } catch {} }
        $stageFile=Join-Path $staging ($rel.Replace('/',[IO.Path]::DirectorySeparatorChar))
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stageFile) | Out-Null
        $url=$baseUrl.TrimEnd('/') + '/' + $source.Replace('\\','/').TrimStart('/')
        if ([string]$f.encoding -eq 'base64') {
            $txt=Get-RemoteText $url 25
            [IO.File]::WriteAllBytes($stageFile,[Convert]::FromBase64String(($txt -replace '\s','')))
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri ($url + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -OutFile $stageFile -TimeoutSec 35 -Headers @{'Cache-Control'='no-cache';'User-Agent'='kimimall-admin-updater/1.2'}
        }
        if ((Get-Sha256 $stageFile) -ne $expected) { throw ('SHA256 mismatch for ' + $rel) }
        $changes.Add([pscustomobject]@{rel=$rel;target=$target;stage=$stageFile;existed=(Test-Path -LiteralPath $target)})
        Log ('Verified: ' + $rel)
    }

    foreach ($relObj in $deletes) {
        $rel=[string]$relObj
        $target=Safe-Target $rel
        if (Test-Path -LiteralPath $target) { $removed.Add([pscustomobject]@{rel=$rel;target=$target}) }
    }

    foreach ($c in $changes) {
        if ($c.existed) {
            $b=Join-Path $backup ($c.rel.Replace('/',[IO.Path]::DirectorySeparatorChar)); New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null; Copy-Item -LiteralPath $c.target -Destination $b -Force
        }
    }
    foreach ($c in $removed) {
        $b=Join-Path $backup ($c.rel.Replace('/',[IO.Path]::DirectorySeparatorChar)); New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null; Copy-Item -LiteralPath $c.target -Destination $b -Force
    }

    try {
        foreach ($c in $changes) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $c.target) | Out-Null; Copy-Item -LiteralPath $c.stage -Destination $c.target -Force }
        foreach ($c in $removed) { Remove-Item -LiteralPath $c.target -Force }
        foreach ($f in $files) {
            $target=Safe-Target ([string]$f.path)
            if (-not (Test-Path -LiteralPath $target) -or (Get-Sha256 $target) -ne ([string]$f.sha256).ToLowerInvariant()) { throw ('Post-update verification failed: ' + [string]$f.path) }
        }
    } catch {
        Log ('Apply failed, rolling back: ' + $_.Exception.Message)
        foreach ($c in $changes) {
            $b=Join-Path $backup ($c.rel.Replace('/',[IO.Path]::DirectorySeparatorChar))
            if ($c.existed -and (Test-Path -LiteralPath $b)) { Copy-Item -LiteralPath $b -Destination $c.target -Force }
            elseif (-not $c.existed -and (Test-Path -LiteralPath $c.target)) { Remove-Item -LiteralPath $c.target -Force -ErrorAction SilentlyContinue }
        }
        foreach ($c in $removed) {
            $b=Join-Path $backup ($c.rel.Replace('/',[IO.Path]::DirectorySeparatorChar)); if (Test-Path -LiteralPath $b) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $c.target) | Out-Null; Copy-Item -LiteralPath $b -Destination $c.target -Force }
        }
        throw
    }

    [ordered]@{schema=1;product='kimimall_admin';channel='stable';version=$remoteVersion;updated_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $versionFile -Encoding UTF8
    Save-Result 'updated' ('Updated from ' + $localVersion + ' to ' + $remoteVersion) $remoteVersion
    Log ('Update complete: ' + $remoteVersion)
    try { Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force } } catch {}
    try { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Restart-App; exit 0
}
catch {
    $msg=$_.Exception.Message; Log ('UPDATE ERROR: ' + $msg); Save-Result 'failed' $msg ''
    if ($Mode -eq 'Manual') { Write-Host ''; Write-Host 'Update failed. The previous installation was preserved or restored.'; Write-Host $msg; Write-Host 'Press Enter to continue.'; [void](Read-Host) }
    Restart-App; exit 20
}
finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() | Out-Null } catch {} }
    $mutex.Dispose()
}
