<#
.SYNOPSIS
    XMage full portable-install packager (the "starter kit" for NEW players).

.DESCRIPTION
    Companion to make-update.ps1. Existing players never need this -- their launcher
    pulls delta updates forever. This builds the one-time download for people who
    don't have the game yet: a clean, version-stamped zip of the golden tree
    (S:\new release) with all personal/runtime data stripped:

      - card image cache (launcher re-syncs it from the VM on first update check)
      - H2 databases (regenerate on first run; server db holds YOUR user accounts)
      - logs, game logs, game history, saved games, plugin runtime data

    Everything else ships: launcher jar, bundled Java runtime, startup/config
    scripts, installed.properties, xmage server+client with config templates,
    backgrounds/sounds/sample decks, and the current version.txt (so a fresh
    install immediately knows what version it is -- if the starter zip is a few
    releases old, the first "Check for Updates" simply deltas it forward).

    The zip wraps everything in a top-level "XMage-Portable/" folder so extracting
    it anywhere produces one tidy directory.

.PARAMETER Version
    Stamp for the zip filename. Default: whatever the golden tree's xmage/version.txt says.

.PARAMETER Publish
    scp the zip to the VM and verify the public URL, then point config.json's
    xmage.url_full at it (local edit only -- it rides along with your next site push).

.EXAMPLE
    .\make-full-install.ps1 -DryRun
    .\make-full-install.ps1 -Publish
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$SourceRoot = 'S:\new release',
    [string]$SiteRepo = 'D:\Development\xmage-site',
    [string]$UrlBase = 'http://129.146.36.145/updates',
    [switch]$DryRun,
    [switch]$Publish,
    [string]$SshKey = 'S:\ssh-key-2026-07-12.key',
    [string]$SshTarget = 'ubuntu@129.146.36.145',
    [string]$RemoteDir = '/var/www/html/updates',
    [string]$TopFolder = 'XMage-Portable'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

if (-not (Test-Path $SourceRoot)) { throw "Golden tree not found: $SourceRoot" }
if (-not $Version) {
    $vtxt = Join-Path $SourceRoot 'xmage\version.txt'
    if (Test-Path $vtxt) { $Version = (Get-Content $vtxt -First 1).Trim() } else { $Version = (Get-Date).ToString('yyyy.M.d') }
}

$DistDir = Join-Path $SiteRepo 'dist'
$ZipName = "xmage-full-$Version.zip"
$ZipPath = Join-Path $DistDir $ZipName
$ConfigPath = Join-Path $SiteRepo 'config.json'

# Excluded paths, matched against forward-slash paths relative to the install root.
$ExcludePatterns = @(
    'xmage/mage-client/plugins/images/*',
    'xmage/mage-client/plugins/plugin.data',
    'xmage/*/db/*',
    '*.log',
    'xmage/mage-client/gamelogs/*',
    'xmage/mage-server/gamesHistory/*',
    'xmage/mage-server/saved/*',
    '*/Thumbs.db', 'Thumbs.db', '*.lock.db',
    # never recursively swallow packager output if someone runs this against a weird tree
    'dist/*'
)

function Test-Excluded([string]$RelPath) {
    foreach ($p in $ExcludePatterns) {
        if ($RelPath -like $p) { return $true }
    }
    return $false
}

Write-Host "== XMage full-install packager ==" -ForegroundColor Cyan
Write-Host "Golden tree : $SourceRoot"
Write-Host "Version     : $Version"
Write-Host "Output      : $ZipPath"
Write-Host ""

Write-Host "Scanning (this walks the whole tree incl. the bundled JRE)..." -ForegroundColor Cyan
$srcFull = (Resolve-Path $SourceRoot).Path
$files = @()
$totalBytes = 0
$scanErrors = @()
Get-ChildItem -Path $srcFull -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {
    $rel = $_.FullName.Substring($srcFull.Length).TrimStart('\','/') -replace '\\','/'
    if (-not (Test-Excluded $rel)) {
        $files += $rel
        $totalBytes += $_.Length
    }
}
if ($scanErrors.Count -gt 0) {
    Write-Host ("  {0} filesystem warnings during scan (locked files? close the game/launcher if running from the golden tree)." -f $scanErrors.Count) -ForegroundColor Yellow
}
Write-Host ("  {0} files, {1:N0} MB raw." -f $files.Count, ($totalBytes/1MB))

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] Top-level contents that would ship:" -ForegroundColor Cyan
    $files | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique | ForEach-Object { Write-Host "  $TopFolder/$_" }
    Write-Host "[DryRun] Nothing written."
    exit 0
}

if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

Write-Host ""
Write-Host "Writing $ZipPath (large -- this takes a while)..." -ForegroundColor Cyan
$zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $done = 0
    foreach ($rel in $files) {
        $entry = $zip.CreateEntry("$TopFolder/$rel", [System.IO.Compression.CompressionLevel]::Optimal)
        $in = [System.IO.File]::OpenRead((Join-Path $srcFull $rel))
        try {
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        $done++
        if ($done % 500 -eq 0) { Write-Host ("  {0}/{1} files..." -f $done, $files.Count) }
    }
} finally {
    $zip.Dispose()
}
$zipSize = (Get-Item $ZipPath).Length
Write-Host ("Zip written: {0:N0} MB, {1} files." -f ($zipSize/1MB), $files.Count) -ForegroundColor Green

if ($Publish) {
    Write-Host ""
    Write-Host "Uploading to $SshTarget`:$RemoteDir/ ..." -ForegroundColor Cyan
    & scp -i $SshKey $ZipPath "$SshTarget`:$RemoteDir/"
    if ($LASTEXITCODE -ne 0) { throw "scp upload failed (exit $LASTEXITCODE)" }
    Write-Host "Verifying public URL..." -ForegroundColor Cyan
    try {
        $head = Invoke-WebRequest -Uri "$UrlBase/$ZipName" -Method Head -UseBasicParsing -TimeoutSec 60
        $remoteLen = [long]$head.Headers['Content-Length']
        if ($remoteLen -eq $zipSize) {
            Write-Host ("VERIFIED: {0}/{1} is live ({2:N0} MB)." -f $UrlBase, $ZipName, ($remoteLen/1MB)) -ForegroundColor Green
            # point config.json's url_full at it (informational field; rides along with the next site push)
            $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $config.xmage.url_full = "$UrlBase/$ZipName"
            $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
            Write-Host "config.json xmage.url_full updated (commit+push whenever convenient)." -ForegroundColor Green
        } else {
            Write-Host ("WARNING: URL responds but size mismatch (local {0} vs remote {1}) -- re-upload." -f $zipSize, $remoteLen) -ForegroundColor Yellow
        }
    } catch {
        Write-Host "WARNING: could not verify $UrlBase/$ZipName -- check it in a browser. ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "== Done ==" -ForegroundColor Cyan
Write-Host "Share this link with new players: $UrlBase/$ZipName"
Write-Host "They extract it anywhere, open the $TopFolder folder, run the launcher, done."
Write-Host "(First launch rebuilds the card database; card images arrive via the launcher's image sync.)"
