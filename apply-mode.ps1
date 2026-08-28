# Applies a display mode by ROLE rather than by hardcoded monitor ID.
#
# Why: on this machine the monitor identifiers are not stable. The class instance
# suffix changes as devices re-enumerate (EDR2380 has been \0006 and \0011), and
# moving a panel to a different GPU port can change its identity entirely - the
# AOC reports as HJW9291 through the adapter on one port. Any bat with a literal
# MonitorID in it silently no-ops the moment either of those shifts, which is the
# failure mode that made every mode "do nothing" with no error.
#
# So: each role lists the identities it may appear under, we look up whatever is
# actually present right now, and drive MultiMonitorTool with that.
#
#   powershell -ExecutionPolicy Bypass -File "...\apply-mode.ps1" -Mode sloptop

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('sloptop','ipad','samsung','ipadmon','ipadlap')]
  [string]$Mode
)

$ErrorActionPreference = 'Stop'
$d   = "D:\Programs\multimonitortool-x64"
$mmt = Join-Path $d 'MultiMonitorTool.exe'
$tmp = Join-Path $env:TEMP "mmt-state-$PID.txt"

# A role may appear under any of these short monitor IDs. Add new aliases here if
# a panel shows up under another name after a port change.
$RoleAliases = [ordered]@{
  MAIN     = @('SAC2453')            # new Edra, the top panel
  LOWER    = @('EDR2380')            # older Edra, below
  PORTRAIT = @('AOC2269','HJW9291')  # AOC, rotated; identity varies by port
  VDD      = @('MTT1337')            # virtual display the iPad receives
}

$Wallpaper = @{
  MAIN     = 'D:\333\dell.jpg'
  LOWER    = 'D:\333\edra.png'
  PORTRAIT = 'D:\333\aoc.png'
  VDD      = 'D:\333\ipad.png'
}

# Extra displays that only exist while something is streaming to them. Matched by
# UID substring against the wallpaper device path, never enabled or disabled here.
$Extras = @{
  samsung = @( @('UID257','D:\333\samsung.jpg') )
  ipadmon = @( @('UID256','D:\333\ipadasmonitor.jpg') )
  ipadlap = @( @('UID256','D:\333\ipadasmonitor.jpg'), @('UID258','D:\333\ipadlaptoasmonitor.png') )
}

$Modes = @{
  sloptop = @{ Cfg='3_monitors.cfg';          On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='LOWER' }
  samsung = @{ Cfg='samsungasmonitor.cfg';    On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='LOWER' }
  ipadmon = @{ Cfg='ipadasmonitor.cfg';       On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='MAIN' }
  ipadlap = @{ Cfg='ipadlaptopasmonitor.cfg'; On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='LOWER' }
  ipad    = @{ Cfg=$null;                     On=@('VDD'); Off=@('MAIN','LOWER','PORTRAIT'); Primary='VDD'
               VddMode='BitsPerPixel=32 Width=1366 Height=768 DisplayFlags=0 DisplayFrequency=60 DisplayOrientation=0 PositionX=0 PositionY=0' }
}

function Get-Live {
  # Re-read every time: enabling or disabling a display changes what exists.
  & $mmt /stab $tmp | Out-Null
  Start-Sleep -Milliseconds 1500
  $rows = @{}
  foreach ($r in (Import-Csv $tmp -Delimiter "`t")) {
    $short = $r.'Short Monitor ID'
    if (-not $short) { continue }
    $rows[$short] = [PSCustomObject]@{
      Short = $short; Id = $r.'Monitor ID'; Active = ($r.Active -eq 'Yes')
      Primary = ($r.Primary -eq 'Yes'); Pos = $r.'Left-Top'; Res = $r.Resolution
    }
  }
  $rows
}

function Resolve-Role($live, $role) {
  foreach ($alias in $RoleAliases[$role]) { if ($live.ContainsKey($alias)) { return $live[$alias] } }
  $null
}

function Read-Cfg($path) {
  $sections = @(); $cur = $null
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    $l = $line.Trim()
    if ($l -match '^\[(.+)\]$') { $cur = @{}; $sections += $cur; continue }
    if ($cur -ne $null -and $l -match '^([^=]+)=(.*)$') { $cur[$matches[1]] = $matches[2] }
  }
  $sections
}

# Find the cfg entry belonging to a role, by alias substring - the cfg may have
# been saved when the panel carried a different instance suffix or identity.
function Get-CfgEntry($cfg, $role) {
  foreach ($alias in $RoleAliases[$role]) {
    foreach ($e in $cfg) { if ($e.MonitorID -and $e.MonitorID -match [regex]::Escape($alias)) { return $e } }
  }
  $null
}

$m = $Modes[$Mode]
Write-Host "=== applying mode: $Mode ===" -ForegroundColor Cyan

# --- 1. make sure everything we need is attached -----------------------------
# A disconnected display exposes no Monitor ID at all, so MultiMonitorTool cannot
# address it. Only this Windows-level call pulls it back into the topology.
$live = Get-Live
$missing = @($m.On | Where-Object { -not (Resolve-Role $live $_) })
if ($missing.Count) {
  Write-Host "  missing: $($missing -join ', ') - running DisplaySwitch /extend"
  & "$env:SystemRoot\System32\DisplaySwitch.exe" /extend | Out-Null
  Start-Sleep -Seconds 9
  $live = Get-Live
}

# --- 2. enable required roles, one call each ---------------------------------
# Separately, because one unresolvable id in a multi-target call makes the whole
# command fail silently.
foreach ($role in $m.On) {
  $mon = Resolve-Role $live $role
  if (-not $mon) { Write-Host "  WARN: $role not present, skipping enable" -ForegroundColor Yellow; continue }
  if (-not $mon.Active) {
    & $mmt /enable $mon.Id | Out-Null
    Start-Sleep -Seconds 3
  }
}
$live = Get-Live

# --- 3. primary first, then disable ------------------------------------------
# Windows refuses to disable whichever display is currently primary, so the
# primary has to move before anything gets switched off.
$primaryMon = Resolve-Role $live $m.Primary
if ($primaryMon) {
  & $mmt /SetPrimary $primaryMon.Id | Out-Null
  Start-Sleep -Seconds 4
} else {
  Write-Host "  WARN: primary role $($m.Primary) not present" -ForegroundColor Yellow
}

if ($Mode -eq 'ipad' -and $primaryMon) {
  & $mmt /SetMonitors "Name=$($primaryMon.Id) $($m.VddMode)" | Out-Null
  Start-Sleep -Seconds 4
  & $mmt /SetPrimary $primaryMon.Id | Out-Null
  Start-Sleep -Seconds 3
}

$live = Get-Live
foreach ($role in $m.Off) {
  $mon = Resolve-Role $live $role
  if ($mon -and $mon.Active) {
    & $mmt /disable $mon.Id | Out-Null
    Start-Sleep -Seconds 4
  }
}

# --- 4. layout ----------------------------------------------------------------
if ($m.Cfg) {
  & $mmt /LoadConfig (Join-Path $d $m.Cfg) | Out-Null
  Start-Sleep -Seconds 6

  # LoadConfig re-anchors on whichever monitor it feels like and does not record
  # the primary, so set it again afterwards.
  $live = Get-Live
  $primaryMon = Resolve-Role $live $m.Primary
  if ($primaryMon) { & $mmt /SetPrimary $primaryMon.Id | Out-Null; Start-Sleep -Seconds 4 }

  # Re-anchoring also drops rotation and refresh rate. Re-assert each panel using
  # geometry from the cfg but the id that is live right now.
  $cfg = Read-Cfg (Join-Path $d $m.Cfg)
  $live = Get-Live
  $specs = @()
  foreach ($role in $m.On) {
    $mon = Resolve-Role $live $role; if (-not $mon) { continue }
    $e = Get-CfgEntry $cfg $role
    if (-not $e) { Write-Host "  WARN: no $role entry in $($m.Cfg)" -ForegroundColor Yellow; continue }
    if ([int]$e.Width -le 0) { continue }
    $specs += "Name=$($mon.Id) BitsPerPixel=$($e.BitsPerPixel) Width=$($e.Width) Height=$($e.Height) DisplayFlags=$($e.DisplayFlags) DisplayFrequency=$($e.DisplayFrequency) DisplayOrientation=$($e.DisplayOrientation) PositionX=$($e.PositionX) PositionY=$($e.PositionY)"
  }
  if ($specs.Count) { & $mmt /SetMonitors @specs | Out-Null; Start-Sleep -Seconds 5 }
}

# --- 5. wallpaper -------------------------------------------------------------
# One pass, no --primary: every monitor is named, so the global SPI repaint has
# nothing to fall back for, and it would land last and overwrite the primary.
$live = Get-Live
$args = @()
foreach ($role in $m.On) {
  $mon = Resolve-Role $live $role
  if ($mon -and $Wallpaper[$role]) { $args += $mon.Short; $args += $Wallpaper[$role] }
}
if ($Extras[$Mode]) { foreach ($x in $Extras[$Mode]) { $args += $x[0]; $args += $x[1] } }
if ($args.Count) {
  & (Join-Path $d 'SetWallpaper.exe') @args | Out-Null
  Start-Sleep -Seconds 2
  & (Join-Path $d 'SetWallpaper.exe') @args | Out-Null
}

# --- 6. report ----------------------------------------------------------------
# MultiMonitorTool reports success even when it is wedged and did nothing, so
# verify against what was asked for and say so plainly.
$live = Get-Live
Write-Host ""
Write-Host "result:" -ForegroundColor Cyan
$ok = $true
foreach ($role in $RoleAliases.Keys) {
  $mon = Resolve-Role $live $role
  if (-not $mon) { Write-Host ("  {0,-9} absent" -f $role); continue }
  $want = if ($m.On -contains $role) { 'on' } elseif ($m.Off -contains $role) { 'off' } else { '-' }
  $got  = if ($mon.Active) { 'on' } else { 'off' }
  $flag = ''
  if ($want -ne '-' -and $want -ne $got) { $flag = "  <-- WANTED $want"; $ok = $false }
  $pri = if ($mon.Primary) { ' PRIMARY' } else { '' }
  Write-Host ("  {0,-9} {1,-3} {2,-11} {3}{4}{5}" -f $role, $got, $mon.Res, $mon.Pos, $pri, $flag)
}
if ($primaryMon -and -not (Resolve-Role $live $m.Primary).Primary) {
  Write-Host "  WARN: primary is not $($m.Primary)" -ForegroundColor Yellow; $ok = $false
}
Write-Host ""
if ($ok) {
  Write-Host "OK - $Mode applied" -ForegroundColor Green
} else {
  Write-Host "FAILED - MultiMonitorTool is probably wedged (a known fault on this" -ForegroundColor Red
  Write-Host "Windows build: it returns success while doing nothing)." -ForegroundColor Red
  Write-Host "Fix: Settings > System > Display > pick a monitor > Make this my main" -ForegroundColor Red
  Write-Host "display. Then run this again." -ForegroundColor Red
}
Remove-Item $tmp -ErrorAction SilentlyContinue
