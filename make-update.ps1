<#
.SYNOPSIS
    XMage update packager (Tier 1 of the launcher update workflow).

.DESCRIPTION
    Builds mage-update zips for the XMagePortableLauncher update system by diffing
    the "golden" release tree (a maintained copy of the portable install) against
    release-manifest.json (the recorded state of the last published release).

    Only files that are NEW or CHANGED since the last release go into the zip --
    never source code, never user data. The zip's internal layout mirrors the
    install's xmage/ folder (mage-server/..., mage-client/...), because the
    launcher's extractZip() unpacks entries relative to {install}/xmage/.

    On a successful package this script also:
      - bumps config.json's xmage.version and xmage.url (versioned zip filename)
      - rewrites release-manifest.json with the full current inventory
      - updates the golden tree's own xmage/version.txt to the new version

    What it deliberately NEVER ships (excluded from inventory entirely):
      - mage-client/plugins/images/**   (card image cache -- synced separately, see IMAGE_SYNC)
      - **/db/**                        (H2 databases: server user data, client card DB)
      - **/config/**                    (user-modified settings; templates ship in full installs only)
      - logs, game history, saved games, gamelogs
      - version.txt                     (owned by the launcher: it writes the remote version after extract)

    KNOWN LIMITATION (launcher contract): updates are add/overwrite only -- the
    launcher cannot delete files. If a file disappears or is renamed in the golden
    tree (e.g. a version-bumped jar filename), this script WARNS about the orphan;
    stale files linger on user installs until handled some other way. Keep the
    Maven project version pinned so jar filenames stay stable.

.PARAMETER Version
    Release version string (date scheme). Default: today as yyyy.M.d (e.g. 2026.7.15).
    Users' launchers compare by exact string equality -- any difference triggers the update.

.PARAMETER SourceRoot
    The golden tree's xmage/ folder. Default: S:\new release\xmage

.PARAMETER SiteRepo
    Local clone of xmage-site (holds config.json + release-manifest.json). Default: D:\Development\xmage-site

.PARAMETER UrlBase
    Public base URL where update zips are hosted (Oracle VM / Nginx). The zip must be
    uploaded there manually after packaging. Default: http://129.146.36.145/updates

.PARAMETER DryRun
    Show what would be packaged; write nothing.

.PARAMETER Baseline
    Record the manifest from the current golden tree WITHOUT producing a zip or
    touching config.json. Use once to establish "what users already have."

.EXAMPLE
    .\make-update.ps1                    # package today's changes
    .\make-update.ps1 -DryRun            # preview
    .\make-update.ps1 -Version 2026.7.20 # explicit version
    .\make-update.ps1 -Baseline          # record current state as already-published
#>
[CmdletBinding()]
param(
    [string]$Version = (Get-Date).ToString('yyyy.M.d'),
    [string]$SourceRoot = 'S:\new release\xmage',
    [string]$SiteRepo = 'D:\Development\xmage-site',
    [string]$UrlBase = 'http://129.146.36.145/updates',
    [switch]$DryRun,
    [switch]$Baseline,
    # -Publish: after packaging, scp the zip to the VM and verify the public URL responds.
    [switch]$Publish,
    # -PushSite: after a VERIFIED publish, git commit+push config.json/release-manifest.json
    # in the site repo, making the release live for launcher users. Implies nothing else --
    # only runs if -Publish succeeded and the URL check passed.
    [switch]$PushSite,
    [string]$SshKey = 'S:\ssh-key-2026-07-12.key',
    [string]$SshTarget = 'ubuntu@129.146.36.145',
    [string]$RemoteDir = '/var/www/html/updates'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ---------------------------------------------------------------- configuration
$ManifestPath = Join-Path $SiteRepo 'release-manifest.json'
$ConfigPath   = Join-Path $SiteRepo 'config.json'
$DistDir      = Join-Path $SiteRepo 'dist'
$ZipName      = "mage-update-$Version.zip"
$ZipPath      = Join-Path $DistDir $ZipName

# Exclusion rules, matched against forward-slash paths relative to xmage/.
# Wildcards: PowerShell -like patterns.
$ExcludePatterns = @(
    'mage-client/plugins/images/*',   # card image cache (synced separately)
    'mage-client/plugins/plugin.data',# plugin runtime data
    '*/db/*',                          # H2 databases (user + generated data)
    '*/config/*',                      # user-modified settings
    '*.log',                           # logs anywhere
    'mage-client/gamelogs/*',
    'mage-server/gamesHistory/*',
    'mage-server/saved/*',
    'version.txt',                     # launcher-owned
    '*/Thumbs.db', 'Thumbs.db', '*.lock.db'
)

function Test-Excluded([string]$RelPath) {
    foreach ($p in $ExcludePatterns) {
        if ($RelPath -like $p) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- sanity checks
if (-not (Test-Path $SourceRoot))            { throw "Golden tree not found: $SourceRoot" }
if (-not (Test-Path (Join-Path $SourceRoot 'mage-server'))) { throw "'$SourceRoot' doesn't look like an xmage/ folder (no mage-server/)" }
if (-not (Test-Path $ConfigPath))            { throw "config.json not found: $ConfigPath" }

Write-Host "== XMage update packager ==" -ForegroundColor Cyan
Write-Host "Golden tree : $SourceRoot"
Write-Host "Site repo   : $SiteRepo"
Write-Host "Version     : $Version"
Write-Host ""

# ---------------------------------------------------------------- inventory + hash
Write-Host "Scanning golden tree (hashing shippable files)..." -ForegroundColor Cyan
$inventory = @{}   # relPath (fwd slashes) -> sha256
$srcFull = (Resolve-Path $SourceRoot).Path

# Enumerate resiliently: access errors on individual files (locks, long paths) are
# reported and skipped rather than aborting the whole scan. The card-image cache is
# pruned by the exclusion filter; its enumeration cost is accepted for simplicity.
$scanErrors = @()
Get-ChildItem -Path $srcFull -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {
    $rel = $_.FullName.Substring($srcFull.Length).TrimStart('\','/') -replace '\\','/'
    if (-not (Test-Excluded $rel)) {
        try {
            $inventory[$rel] = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
        } catch {
            $scanErrors += $_
            Write-Host "  ! could not hash (skipped): $rel" -ForegroundColor Yellow
        }
    }
}
if ($scanErrors.Count -gt 0) {
    Write-Host ("  {0} filesystem warnings during scan (see above / locked files are normal if the game is running -- CLOSE the client/server before packaging)." -f $scanErrors.Count) -ForegroundColor Yellow
}
Write-Host ("  {0} shippable files in inventory." -f $inventory.Count)

# ---------------------------------------------------------------- baseline mode
if ($Baseline) {
    if ($DryRun) { Write-Host "[DryRun] Would write baseline manifest ($($inventory.Count) files) to $ManifestPath"; exit 0 }
    $manifestOut = [ordered]@{
        version   = $Version
        generated = (Get-Date).ToString('s')
        note      = 'baseline (recorded without publishing a package)'
        files     = $inventory
    }
    $manifestOut | ConvertTo-Json -Depth 5 | Set-Content -Path $ManifestPath -Encoding UTF8
    Write-Host "Baseline manifest written: $ManifestPath" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- load previous manifest, diff
$previous = @{}
$haveManifest = Test-Path $ManifestPath
if ($haveManifest) {
    $mf = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    foreach ($prop in $mf.files.PSObject.Properties) { $previous[$prop.Name] = $prop.Value }
    Write-Host ("Previous release manifest: version {0}, {1} files." -f $mf.version, $previous.Count)

    # Same-day re-release: launchers compare version STRINGS, so a second release today
    # must not reuse today's string. Auto-suffix: 2026.7.15 -> 2026.7.15.2 -> 2026.7.15.3 ...
    if (-not $PSBoundParameters.ContainsKey('Version') -and ($mf.version -eq $Version -or $mf.version -like "$Version.*")) {
        $suffix = 2
        if ($mf.version -match [regex]::Escape($Version) + '\.(\d+)$') { $suffix = [int]$Matches[1] + 1 }
        $Version = "$Version.$suffix"
        $ZipName = "mage-update-$Version.zip"
        $ZipPath = Join-Path $DistDir $ZipName
        Write-Host ("Same-day re-release detected -- version auto-bumped to {0}." -f $Version) -ForegroundColor Yellow
    }
} else {
    Write-Host "NO previous manifest found -- this becomes a FULL first release (every shippable file is packaged)." -ForegroundColor Yellow
}

$changed = @()
foreach ($rel in ($inventory.Keys | Sort-Object)) {
    if (-not $previous.ContainsKey($rel) -or $previous[$rel] -ne $inventory[$rel]) {
        $changed += $rel
    }
}
$orphans = @()
foreach ($rel in ($previous.Keys | Sort-Object)) {
    if (-not $inventory.ContainsKey($rel)) { $orphans += $rel }
}

Write-Host ""
Write-Host ("Changed/new files: {0}" -f $changed.Count) -ForegroundColor Cyan
$totalBytes = 0
foreach ($rel in $changed) {
    # forward slashes are valid path separators on Windows too
    $size = (Get-Item (Join-Path $srcFull $rel)).Length
    $totalBytes += $size
    Write-Host ("  + {0}  ({1:N1} MB)" -f $rel, ($size/1MB))
}
Write-Host ("Total payload: {0:N1} MB (before zip compression)" -f ($totalBytes/1MB))

if ($orphans.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: files present in the last release but missing from the golden tree." -ForegroundColor Yellow
    Write-Host "The launcher CANNOT delete files -- these will linger on user installs:" -ForegroundColor Yellow
    $orphans | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

if ($changed.Count -eq 0) {
    Write-Host ""
    Write-Host "Nothing changed since the last release -- no package produced." -ForegroundColor Green
    exit 0
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] Would write: $ZipPath"
    Write-Host "[DryRun] Would set config.json xmage.version=$Version, xmage.url=$UrlBase/$ZipName"
    Write-Host "[DryRun] Would rewrite $ManifestPath and golden version.txt"
    exit 0
}

# ---------------------------------------------------------------- build the zip
if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

Write-Host ""
Write-Host "Writing $ZipPath ..." -ForegroundColor Cyan
$zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($rel in $changed) {
        $srcFile = Join-Path $srcFull $rel
        # entry names MUST use forward slashes (launcher-side ZipInputStream + cross-consistency)
        $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $in  = [System.IO.File]::OpenRead($srcFile)
        try {
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
    }
} finally {
    $zip.Dispose()
}
$zipSize = (Get-Item $ZipPath).Length
Write-Host ("Zip written: {0:N1} MB, {1} files." -f ($zipSize/1MB), $changed.Count) -ForegroundColor Green

# ---------------------------------------------------------------- update config.json
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$config.xmage.version = $Version
$config.xmage.url = "$UrlBase/$ZipName"
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
Write-Host "config.json updated: xmage.version=$Version, xmage.url=$UrlBase/$ZipName" -ForegroundColor Green

# ---------------------------------------------------------------- record manifest + golden version.txt
$manifestOut = [ordered]@{
    version   = $Version
    generated = (Get-Date).ToString('s')
    zip       = $ZipName
    files     = $inventory
}
$manifestOut | ConvertTo-Json -Depth 5 | Set-Content -Path $ManifestPath -Encoding UTF8
Write-Host "release-manifest.json rewritten ($($inventory.Count) files)." -ForegroundColor Green

Set-Content -Path (Join-Path $srcFull 'version.txt') -Value $Version -Encoding ASCII
Write-Host "Golden tree version.txt set to $Version." -ForegroundColor Green

# ---------------------------------------------------------------- publish (optional)
$publishVerified = $false
if ($Publish) {
    Write-Host ""
    Write-Host "Uploading to $SshTarget`:$RemoteDir/ ..." -ForegroundColor Cyan
    & scp -i $SshKey $ZipPath "$SshTarget`:$RemoteDir/"
    if ($LASTEXITCODE -ne 0) { throw "scp upload failed (exit $LASTEXITCODE) -- zip was built but NOT published; config.json/manifest are already updated, so either retry the upload or revert the xmage-site changes." }
    Write-Host "Upload complete. Verifying public URL..." -ForegroundColor Cyan
    try {
        $head = Invoke-WebRequest -Uri "$UrlBase/$ZipName" -Method Head -UseBasicParsing -TimeoutSec 30
        $remoteLen = [long]$head.Headers['Content-Length']
        if ($remoteLen -eq $zipSize) {
            Write-Host ("VERIFIED: {0}/{1} is live ({2:N1} MB, size matches)." -f $UrlBase, $ZipName, ($remoteLen/1MB)) -ForegroundColor Green
            $publishVerified = $true
        } else {
            Write-Host ("WARNING: URL responds but size mismatch (local {0} vs remote {1}) -- re-upload before pushing xmage-site." -f $zipSize, $remoteLen) -ForegroundColor Yellow
        }
    } catch {
        Write-Host "WARNING: could not verify $UrlBase/$ZipName -- check it in a browser before pushing xmage-site. ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- push site (optional)
$sitePushed = $false
if ($PushSite) {
    if (-not $publishVerified) {
        Write-Host ""
        Write-Host "-PushSite SKIPPED: the publish step didn't verify cleanly. Fix the upload first, then push manually." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "Committing and pushing xmage-site (config.json + release-manifest.json)..." -ForegroundColor Cyan
        Push-Location $SiteRepo
        try {
            & git add config.json release-manifest.json
            & git commit -m "release $Version"
            if ($LASTEXITCODE -ne 0) { throw "git commit failed (nothing to commit, or git not configured)" }
            & git push
            if ($LASTEXITCODE -ne 0) { throw "git push failed -- push manually when resolved" }
            $sitePushed = $true
            Write-Host "xmage-site pushed -- the release is LIVE for launcher users." -ForegroundColor Green
        } finally {
            Pop-Location
        }
    }
}

# ---------------------------------------------------------------- next steps
Write-Host ""
Write-Host "== Publish checklist ==" -ForegroundColor Cyan
if ($sitePushed) {
    Write-Host "Nothing left to do -- release $Version is fully live. Users get it via 'Check for Updates'."
} elseif ($Publish) {
    Write-Host "1. Commit + push xmage-site (config.json + release-manifest.json). Do NOT commit dist/."
    Write-Host "2. Users click 'Check for Updates' in the launcher."
} else {
    Write-Host "1. Upload $ZipPath to the VM (or rerun with -Publish): must be reachable at $UrlBase/$ZipName"
    Write-Host "2. Verify the URL responds (open in a browser)."
    Write-Host "3. Commit + push xmage-site (config.json + release-manifest.json). Do NOT commit dist/."
    Write-Host "4. Users click 'Check for Updates' in the launcher."
}
