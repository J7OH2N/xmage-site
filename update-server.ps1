<#
.SYNOPSIS
    Update the always-on XMage game server on the Oracle Cloud VM to a published release.
    REQUIRED step of every release -- run it right after make-update.ps1 -Publish.

.DESCRIPTION
    Third companion to make-update.ps1 / make-full-install.ps1.

    make-update.ps1 publishes for LAUNCHER users only. The always-on game server at
    129.146.36.145:17171 runs its OWN copy of mage-server and does NOT update itself.
    (Older docs claimed "the server updates itself" -- that is exactly how release
    2026.7.17 shipped while the VM kept serving Jul 15 jars for hours. Players
    connecting to the cloud server silently got the old cards and the old bugs while
    their own client was perfectly up to date, and nothing anywhere warned about it.
    It was caught by eye. Hence this script.)

    What it does:
      1. Resolves the published version from xmage-site\config.json (the source of truth
         for what players are actually being served).
      2. Refuses to restart if anyone is connected -- a restart DROPS games in progress.
      3. Pulls the update zip from the VM's own Nginx feed over localhost (no re-upload:
         make-update.ps1 already put it there).
      4. Extracts ONLY mage-server/* . User data is never touched -- the packager never
         ships config/ or db/, so server settings and user accounts survive.
      5. Restarts the systemd unit and verifies properly (see below).

    Verification is the whole point of this script, because the obvious checks lie:
      - `systemctl is-active` reports "active" while the server is still BOOTING.
      - grepping 'Started MAGE' without a time window happily returns the PREVIOUS
        boot's line and reads as success.
    So: a restart marker timestamp is taken first, and we wait for a 'Started MAGE'
    line strictly newer than it. Expect ~60s -- a new mage.jar changes the manifest
    Build-Time, which forces a full card-DB rebuild ("DB: need to add 579 new sets").
    Then the installed jars are md5-compared against the golden tree, and the locator
    line is checked for serverBindAddress=0.0.0.0 (the NAT fix -- without it, remote
    clients fail with "remote task error").

.PARAMETER Version
    Release to install. Default: whatever config.json says is currently published.

.PARAMETER Force
    Restart even if players are connected. This DROPS their games.

.PARAMETER DryRun
    Report what would happen and change nothing.

.EXAMPLE
    .\update-server.ps1 -DryRun
    .\update-server.ps1
    .\update-server.ps1 -Version 2026.7.17 -Force
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$SiteRepo   = 'D:\Development\xmage-site',
    [string]$GoldenTree = 'S:\new release',
    [string]$SshKey     = 'S:\ssh-key-2026-07-12.key',
    [string]$SshTarget  = 'ubuntu@129.146.36.145',
    [string]$Unit       = 'xmage',
    [int]$StartTimeoutSec = 240,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say '== XMage VM game-server updater ==' 'Cyan'

# ---- resolve version from config.json (what players are actually served) -------------
$ConfigPath = Join-Path $SiteRepo 'config.json'
if (-not (Test-Path $ConfigPath)) { throw "config.json not found at $ConfigPath" }
if (-not $Version) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $Version = $cfg.xmage.version
    if (-not $Version) { throw "Could not read xmage.version from $ConfigPath" }
}
$ZipName = "mage-update-$Version.zip"

Say "VM        : $SshTarget (unit: $Unit)"
Say "Version   : $Version"
Say "Feed      : http://localhost/updates/$ZipName  (served by the VM's own Nginx)"
Say ''

if (-not (Test-Path $SshKey)) { throw "SSH key not found: $SshKey" }

# ---- preflight: reachable? what's running? anyone connected? -------------------------
Say 'Preflight...'
$preflight = & ssh -i $SshKey -o StrictHostKeyChecking=no -o ConnectTimeout=20 $SshTarget @'
echo "ACTIVE=$(systemctl is-active xmage)"
echo "CONNS=$(ss -tn state established '( sport = :17171 )' 2>/dev/null | tail -n +2 | wc -l)"
echo "ZIPHTTP=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/updates/REPLACEZIP)"
md5sum /home/ubuntu/mage-server/lib/mage-1.4.60.jar /home/ubuntu/mage-server/lib/mage-sets-1.4.60.jar 2>/dev/null | sed 's/^/HAVE /'
'@.Replace('REPLACEZIP', $ZipName)
if ($LASTEXITCODE -ne 0) { throw "Cannot reach $SshTarget (ssh exit $LASTEXITCODE)." }

$active  = ($preflight | Select-String '^ACTIVE=').ToString().Split('=')[1]
$conns   = [int]($preflight | Select-String '^CONNS=').ToString().Split('=')[1]
$ziphttp = ($preflight | Select-String '^ZIPHTTP=').ToString().Split('=')[1]

Say "  service   : $active"
Say "  connected : $conns player connection(s) on 17171"
Say "  feed zip  : HTTP $ziphttp"

if ($ziphttp -ne '200') {
    throw "$ZipName is not on the VM's feed (HTTP $ziphttp). Run make-update.ps1 -Publish first -- this script deliberately does not upload anything."
}

if ($conns -gt 0 -and -not $Force) {
    Say ''
    Say "REFUSING: $conns connection(s) established -- restarting would drop games in progress." 'Red'
    Say 'Re-run later, or pass -Force if you are sure.' 'Yellow'
    exit 1
}

# ---- golden-tree hashes: what the VM SHOULD end up with ------------------------------
$goldLib = Join-Path $GoldenTree 'xmage\mage-server\lib'
$want = @{}
foreach ($j in @('mage-1.4.60.jar', 'mage-sets-1.4.60.jar')) {
    $p = Join-Path $goldLib $j
    if (-not (Test-Path $p)) { throw "Golden tree jar missing: $p" }
    $want[$j] = (Get-FileHash $p -Algorithm MD5).Hash.ToLower()
}

$have = @{}
foreach ($line in ($preflight | Select-String '^HAVE ')) {
    $parts = $line.ToString().Substring(5).Trim() -split '\s+'
    $have[[System.IO.Path]::GetFileName($parts[1])] = $parts[0].ToLower()
}

$needed = $false
Say ''
Say 'Jar comparison (VM vs golden tree):'
foreach ($j in $want.Keys) {
    if ($have[$j] -eq $want[$j]) {
        Say ("  = {0}  already current" -f $j) 'Green'
    } else {
        Say ("  ! {0}  differs -- VM has {1}, release has {2}" -f $j, $have[$j].Substring(0,8), $want[$j].Substring(0,8)) 'Yellow'
        $needed = $true
    }
}

if (-not $needed) {
    Say ''
    Say 'VM is already running this release. Nothing to do.' 'Green'
    exit 0
}

if ($DryRun) {
    Say ''
    Say "[DryRun] Would curl http://localhost/updates/$ZipName on the VM, extract mage-server/*, and restart '$Unit'." 'Yellow'
    Say '[DryRun] Nothing changed.' 'Yellow'
    exit 0
}

# ---- update + restart ----------------------------------------------------------------
# A restart MARKER (epoch) is taken before restarting so we can wait for a 'Started MAGE'
# line strictly newer than it -- see the .DESCRIPTION note about why the obvious checks lie.
Say ''
Say 'Updating and restarting...'
$remote = @'
set -e
curl -sS -o /tmp/up.zip http://localhost/updates/REPLACEZIP
unzip -o -q /tmp/up.zip 'mage-server/*' -d /home/ubuntu/
MARK=$(date +%s)
sudo systemctl restart xmage
for i in $(seq 1 REPLACETRIES); do
  if journalctl -u xmage --since "@$MARK" --no-pager 2>/dev/null | grep -q 'Started MAGE'; then
    echo "STARTED_OK"
    journalctl -u xmage --since "@$MARK" --no-pager | grep 'Started MAGE' | tail -1 | sed 's/^/LOCATOR /'
    break
  fi
  sleep 5
done
echo "ELAPSED=$(( $(date +%s) - MARK ))"
md5sum /home/ubuntu/mage-server/lib/mage-1.4.60.jar /home/ubuntu/mage-server/lib/mage-sets-1.4.60.jar | sed 's/^/NOW /'
# grep -v '^--' drops journalctl's own meta lines ("-- No entries --", "-- Logs begin at ... --").
# Without it, a CLEAN run reports "ERR -- No entries --" and the script fails a good update.
journalctl -u xmage --since "@$MARK" --no-pager -p err | grep -vE '^-- ' | tail -5 | sed 's/^/ERR /'
rm -f /tmp/up.zip
'@
$remote = $remote.Replace('REPLACEZIP', $ZipName).Replace('REPLACETRIES', [string][int]($StartTimeoutSec / 5))
$out = & ssh -i $SshKey -o StrictHostKeyChecking=no -o ConnectTimeout=30 $SshTarget $remote
if ($LASTEXITCODE -ne 0) { throw "Remote update failed (ssh exit $LASTEXITCODE). Server may be down -- check: journalctl -u $Unit -n 50" }

# ---- verify --------------------------------------------------------------------------
$ok = $true

if ($out | Select-String -SimpleMatch 'STARTED_OK') {
    $elapsed = ($out | Select-String '^ELAPSED=').ToString().Split('=')[1]
    Say ("  server came up in ~{0}s" -f $elapsed) 'Green'
} else {
    Say "  NO fresh 'Started MAGE' line within ${StartTimeoutSec}s -- server may still be rebuilding the card DB, or failed." 'Red'
    Say "  Check: ssh -i `"$SshKey`" $SshTarget `"journalctl -u $Unit -n 40 --no-pager`"" 'Yellow'
    $ok = $false
}

foreach ($line in ($out | Select-String '^NOW ')) {
    $parts = $line.ToString().Substring(4).Trim() -split '\s+'
    $name  = [System.IO.Path]::GetFileName($parts[1])
    if ($parts[0].ToLower() -eq $want[$name]) {
        Say ("  = {0}  matches golden tree" -f $name) 'Green'
    } else {
        Say ("  ! {0}  MISMATCH after update" -f $name) 'Red'
        $ok = $false
    }
}

$locator = $out | Select-String '^LOCATOR '
if ($locator) {
    if ($locator -match 'serverBindAddress=0\.0\.0\.0') {
        Say '  = NAT fix present (serverBindAddress=0.0.0.0)' 'Green'
    } else {
        Say '  ! serverBindAddress=0.0.0.0 MISSING from the locator -- remote clients will hit "remote task error".' 'Red'
        $ok = $false
    }
}

$errs = $out | Select-String '^ERR '
if ($errs) { Say ''; Say '  errors since restart:' 'Red'; $errs | ForEach-Object { Say "    $_" 'Red' }; $ok = $false }

Say ''
if ($ok) {
    Say "== VM game server is live on $Version ==" 'Green'
} else {
    Say '== FINISHED WITH PROBLEMS -- see above ==' 'Red'
    exit 1
}
