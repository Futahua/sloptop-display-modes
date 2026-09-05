# Applies a display mode by ROLE rather than by hardcoded monitor ID.
#
# Why roles: monitor identifiers on this machine are not stable. The class
# instance suffix changes as devices re-enumerate (EDR2380 has been \0006 and
# \0011), and moving a panel to a different GPU port can change its identity
# entirely - the AOC reports as HJW9291 through the adapter on one port. Any
# script holding a literal monitor ID silently no-ops when that happens, and
# MultiMonitorTool reports success regardless.
#
# Why DisplayCtl: MultiMonitorTool 2.21 on Windows 11 build 26200 stops
# responding after topology changes - commands return success and do nothing -
# and it cannot address a detached display at all. So attach, detach AND geometry
# all go through DisplayCtl.exe (CCD + ChangeDisplaySettingsEx). MMT is used only
# to report state.
#
#   powershell -ExecutionPolicy Bypass -File "...\apply-mode.ps1" -Mode sloptop

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('sloptop','ipad','samsung','ipadmon','ipadlap')]
  [string]$Mode
)

$ErrorActionPreference = 'Stop'
$d    = "D:\Programs\multimonitortool-x64"
$mmt  = Join-Path $d 'MultiMonitorTool.exe'
$ctl  = Join-Path $d 'DisplayCtl.exe'
$wall = Join-Path $d 'SetWallpaper.exe'
$tmp  = Join-Path $env:TEMP "mmt-state-$PID.txt"

# A role may appear under any of these short monitor IDs. Add new aliases here if
# a panel shows up under another name after a port change.
$RoleAliases = [ordered]@{
  MAIN     = @('SAC2453')            # new Edra, the top panel
  LOWER    = @('EDR2380')            # older Edra, below
  # AOC, rotated. It reaches the GPU through an HDMI converter whose EDID
  # passthrough is unreliable, so it has enumerated under three different
  # identities so far: its own (AOC2269), and two converter chipsets
  # (HJW9291 = MacroSilicon, FME7210/TS35505). When it presents a converter
  # identity the mode list degrades too - 1024x768 only. Add any new identity
  # here; the symptom is PORTRAIT reported "absent" while the panel is lit.
  PORTRAIT = @('AOC2269','HJW9291','FME7210','TS35505')
  VDD      = @('MTT1337')            # virtual display the iPad receives
}

$Wallpaper = @{
  MAIN     = 'D:\333\dell.jpg'
  LOWER    = 'D:\333\edra.png'
  PORTRAIT = 'D:\333\aoc.png'
  VDD      = 'D:\333\ipad.png'
}

# Every display runs at the highest refresh it reports for its resolution.
# Add a role here to deliberately hold one BELOW its maximum.
# VDD is pinned: it is streamed over the network to the iPad, so refresh above
# 60 costs bandwidth and encoding effort for no visible benefit.
$RefreshPin = @{ VDD = 60 }

# Displays that only exist while something is streaming to them. Matched by UID
# substring for wallpaper only; never enabled or disabled here.
# NOTE the leading commas. In PowerShell @( @('a','b') ) collapses to a flat
# two-string array, so $x becomes the STRING 'UID257' and $x[0] is the character
# 'U' - which splatted "U","I","D",":" into the wallpaper helper. The unary comma
# forces a real array-of-arrays. ipadlap has two entries so it never collapsed.
$Extras = @{
  samsung = @( ,@('UID257','D:\333\samsung.jpg') )
  ipadmon = @( ,@('UID256','D:\333\ipadasmonitor.jpg') )
  ipadlap = @( @('UID256','D:\333\ipadasmonitor.jpg'), @('UID258','D:\333\ipadlaptoasmonitor.png') )
}

$Modes = @{
  sloptop = @{ Cfg='3_monitors.cfg';          On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='LOWER' }
  samsung = @{ Cfg='samsungasmonitor.cfg';    On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='LOWER' }
  ipadmon = @{ Cfg='ipadasmonitor.cfg';       On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='MAIN' }
  ipadlap = @{ Cfg='ipadlaptopasmonitor.cfg'; On=@('MAIN','LOWER','PORTRAIT'); Off=@('VDD'); Primary='LOWER' }
  # No cfg for ipad - one display, fixed geometry.
  ipad    = @{ Cfg=$null; On=@('VDD'); Off=@('MAIN','LOWER','PORTRAIT'); Primary='VDD'
               Fixed = @{ VDD = @{ X=0; Y=0; W=1366; H=768; Orient=0; Hz='max' } } }
}

function Get-Live {
  # Re-read every time: enabling or disabling a display changes what exists.
  & $mmt /stab $tmp | Out-Null
  Start-Sleep -Milliseconds 1500
  $rows = @{}
  if (Test-Path $tmp) {
    foreach ($r in (Import-Csv $tmp -Delimiter "`t")) {
      $short = $r.'Short Monitor ID'
      if (-not $short) { continue }
      $orientation = switch -Regex ($r.Orientation) {
        '^90'  { 1; break }
        '^180' { 2; break }
        '^270' { 3; break }
        default { 0 }
      }
      $frequency = if ($r.Frequency -match '(\d+)') { [int]$matches[1] } else { 0 }
      $rows[$short] = [PSCustomObject]@{
        Short = $short; Id = $r.'Monitor ID'; Active = ($r.Active -eq 'Yes')
        Primary = ($r.Primary -eq 'Yes'); Pos = $r.'Left-Top'; Res = $r.Resolution
        Frequency = $frequency; Orientation = $orientation
        # Which GPU it hangs off - the discriminator that makes matching a
        # generic-EDID panel by elimination safe.
        Adapter = $r.Adapter
      }
    }
  }
  $rows
}

function Resolve-Role($live, $role) {
  foreach ($alias in $RoleAliases[$role]) { if ($live.ContainsKey($alias)) { return $live[$alias] } }

  # Fallback: match by elimination.
  #
  # An adapter that fails to pass the monitor's EDID through leaves the panel
  # with no identity at all - it enumerates as Default_Monitor with a blank
  # name, so no alias can ever match it. Aliasing Default_Monitor directly is
  # not safe: the iPad, laptop and Samsung also arrive as Default_Monitor, and
  # the script would grab one of those instead.
  #
  # What separates them is the GPU. The physical panels hang off the NVIDIA
  # adapter; streamed displays come in on their own (spacedesk, VDD). So look
  # only at active displays on the same adapter as the roles that DID resolve,
  # and accept the answer only when exactly one candidate remains.
  if ($role -eq 'VDD') { return $null }   # never guess the virtual display

  $claimed = @()
  foreach ($other in $RoleAliases.Keys) {
    foreach ($a in $RoleAliases[$other]) { if ($live.ContainsKey($a)) { $claimed += $a } }
  }
  $anchorAdapter = ($live.Values |
    Where-Object { $_.Active -and $claimed -contains $_.Short -and $_.Adapter } |
    Group-Object Adapter | Sort-Object Count -Descending | Select-Object -First 1).Name
  if (-not $anchorAdapter) { return $null }

  $cands = @($live.Values | Where-Object {
    $_.Active -and $_.Adapter -eq $anchorAdapter -and $claimed -notcontains $_.Short })
  if ($cands.Count -eq 1) {
    Write-Host ("  NOTE: {0} has no known identity - matched '{1}' by elimination on {2}." -f $role, $cands[0].Short, $anchorAdapter) -ForegroundColor Yellow
    Write-Host ("        Its EDID has gone generic. Add '{0}' to `$RoleAliases.{1} to make this deterministic." -f $cands[0].Short, $role) -ForegroundColor Yellow
    return $cands[0]
  }
  if ($cands.Count -gt 1) {
    Write-Host ("  WARN: {0} unidentified and {1} candidates on {2} - refusing to guess." -f $role, $cands.Count, $anchorAdapter) -ForegroundColor Yellow
  }
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

# Match a cfg entry to a role by alias substring - the cfg may have been saved
# while the panel carried a different instance suffix or identity.
function Get-CfgEntry($cfg, $role) {
  foreach ($alias in $RoleAliases[$role]) {
    foreach ($e in $cfg) { if ($e.MonitorID -and $e.MonitorID -match [regex]::Escape($alias)) { return $e } }
  }
  $null
}

$m = $Modes[$Mode]
Write-Host "=== applying mode: $Mode ===" -ForegroundColor Cyan

# --- 1. attach whatever is missing -------------------------------------------
# A detached display exposes no Monitor ID, so MultiMonitorTool cannot see it and
# DisplaySwitch /extend will not bring these panels back. DisplayCtl re-attaches
# via CCD, giving each its own source and clone group - ALL in one call, since
# separate calls make each new path claim the source the previous one took.
$live = Get-Live
$missing = @($m.On | Where-Object { $r = Resolve-Role $live $_; -not $r -or -not $r.Active })
if ($missing.Count) {
  $aliases = @(); foreach ($role in $missing) { $aliases += $RoleAliases[$role] }
  Write-Host "  attaching: $($missing -join ', ')"
  & $ctl enable @aliases
  if ($LASTEXITCODE -ne 0) { Write-Host "  WARN: attach returned $LASTEXITCODE" -ForegroundColor Yellow }
  Start-Sleep -Seconds 6
  $live = Get-Live
}

# --- 2. detach what this mode does not want ----------------------------------
# Must happen BEFORE geometry: detaching blanks source modes so Windows
# re-anchors the desktop, which flattens any layout applied earlier.
# Loop, because switching one display off can make Windows re-materialise another.
for ($pass = 1; $pass -le 4; $pass++) {
  $live = Get-Live
  $offNow = @()
  foreach ($role in $m.Off) {
    $mon = Resolve-Role $live $role
    if ($mon -and $mon.Active) { $offNow += $mon.Short }
  }
  if (-not $offNow.Count) { break }
  Write-Host "  detach pass $pass : $($offNow -join ', ')"
  & $ctl disable @offNow | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "  WARN: detach returned $LASTEXITCODE" -ForegroundColor Yellow }
  Start-Sleep -Seconds 5
}

# --- 3. primary ---------------------------------------------------------------
# Windows may choose a different primary when the prior one is detached. MMT's
# geometry operations wedge on this build, but SetPrimary is reliable after the
# topology has settled and is the one operation that can persist the selection.
$live = Get-Live
$primaryMon = Resolve-Role $live $m.Primary
if ($primaryMon -and -not $primaryMon.Primary) {
  Write-Host "  setting primary: $($m.Primary)"
  & $mmt /SetPrimary $primaryMon.Id | Out-Null
  Start-Sleep -Seconds 4
}

# --- 4. geometry --------------------------------------------------------------
# Positions, size, rotation and refresh via DisplayCtl (ChangeDisplaySettingsEx,
# applied dynamically). MultiMonitorTool's LoadConfig/SetMonitors are not used:
# they no-op whenever it is wedged, and LoadConfig re-materialises the virtual
# display anyway.
$live = Get-Live
$want = @{}

if ($m.Cfg) {
  $cfg = Read-Cfg (Join-Path $d $m.Cfg)
  foreach ($role in $m.On) {
    $e = Get-CfgEntry $cfg $role
    if (-not $e) { Write-Host "  WARN: no $role entry in $($m.Cfg)" -ForegroundColor Yellow; continue }
    if ([int]$e.Width -le 0) { continue }
    # Hz comes from the cfg only when a mode deliberately pins one. Otherwise ask
    # for 'max' and let DisplayCtl enumerate what the panel actually supports at
    # this resolution - saved configs go stale when a link renegotiates, and a
    # hardcoded rate then either fails or silently caps a panel below its ceiling.
    $want[$role] = @{ X=[int]$e.PositionX; Y=[int]$e.PositionY; W=[int]$e.Width; H=[int]$e.Height
                      Orient=[int]$e.DisplayOrientation; Hz='max' }
    if ($RefreshPin.ContainsKey($role)) { $want[$role].Hz = $RefreshPin[$role] }
  }
} elseif ($m.Fixed) {
  foreach ($k in $m.Fixed.Keys) {
    # Clone the literal, so applying a pin does not mutate the mode table itself.
    $f = @{}; foreach ($kk in $m.Fixed[$k].Keys) { $f[$kk] = $m.Fixed[$k][$kk] }
    if ($RefreshPin.ContainsKey($k)) { $f.Hz = $RefreshPin[$k] }
    $want[$k] = $f
  }
}

if ($want.Count) {
  # Windows pins the primary display at 0,0 and will not let it move without a
  # registry write this machine refuses, so we cannot choose the primary. Instead
  # anchor the whole layout on whichever display IS primary: shift every cfg
  # coordinate so that one sits at the origin. Relative arrangement is preserved.
  $anchorRole = $null
  foreach ($role in $m.On) {
    $mon = Resolve-Role $live $role
    if ($mon -and $mon.Primary -and $want.ContainsKey($role)) { $anchorRole = $role; break }
  }
  $dx = 0; $dy = 0
  if ($anchorRole) {
    $dx = $want[$anchorRole].X; $dy = $want[$anchorRole].Y
    Write-Host "  anchoring layout on $anchorRole (it holds primary)"
  }

  $specs = @()
  # Apply the anchor first. Rotating the primary after its neighbours have moved
  # makes Windows normalize those neighbours a second time and destroys layouts
  # whose edges meet the rotated panel.
  $layoutOrder = @()
  if ($anchorRole) { $layoutOrder += $anchorRole }
  $layoutOrder += @($m.On | Where-Object { $_ -ne $anchorRole })
  foreach ($role in $layoutOrder) {
    if (-not $want.ContainsKey($role)) { continue }
    $mon = Resolve-Role $live $role
    if (-not $mon -or -not $mon.Active) { continue }
    $w = $want[$role]
    $specs += "{0}={1},{2},{3},{4},{5},{6}" -f $mon.Short, ($w.X - $dx), ($w.Y - $dy), $w.W, $w.H, $w.Orient, $w.Hz
  }
  if ($specs.Count) {
    & $ctl layout @specs
    if ($LASTEXITCODE -ne 0) { Write-Host "  WARN: layout returned $LASTEXITCODE" -ForegroundColor Yellow }
    Start-Sleep -Seconds 4
  }
}

# --- 5. wallpaper -------------------------------------------------------------
# One pass, no --primary: every monitor is named, so the global SPI repaint has
# nothing to fall back for, and it would land last and overwrite the primary.
$live = Get-Live
$wargs = @()
foreach ($role in $m.On) {
  $mon = Resolve-Role $live $role
  if ($mon -and $mon.Active -and $Wallpaper[$role]) { $wargs += $mon.Short; $wargs += $Wallpaper[$role] }
}
if ($Extras[$Mode]) {
  # Extras are matched by UID substring, and a UID only ever appears in the
  # wallpaper DEVICE PATH (\\?\DISPLAY#...#UID257#...), never in the MONITOR\...
  # id MultiMonitorTool reports - so ask the wallpaper helper what it can see.
  $devicePaths = @()
  try { $devicePaths = @(& $wall list 2>$null) } catch { }
  foreach ($x in $Extras[$Mode]) {
    if ($x -isnot [array] -or $x.Count -lt 2) { Write-Host "  WARN: malformed extras entry, skipped" -ForegroundColor Yellow; continue }
    $extraPresent = @($devicePaths | Where-Object { $_ -match [regex]::Escape($x[0]) }).Count -gt 0
    if ($extraPresent) { $wargs += $x[0]; $wargs += $x[1] }
    else { Write-Host "  (optional display $($x[0]) not connected - skipping its wallpaper)" }
  }
}
if ($wargs.Count) {
  # The desktop-wallpaper COM service can briefly retain a monitor path that
  # vanished during rotation. Give it one refresh/retry before reporting it.
  # Rotating a panel changes its device path, and the COM service can keep
  # serving the stale one for a few seconds. Let it settle, then retry.
  Start-Sleep -Seconds 3
  for ($wallAttempt = 1; $wallAttempt -le 3; $wallAttempt++) {
    & $wall @wargs | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    if ($wallAttempt -lt 3) { Start-Sleep -Seconds 3 }
  }
  if ($LASTEXITCODE -ne 0) { Write-Host "  WARN: wallpaper helper returned $LASTEXITCODE" -ForegroundColor Yellow }
}

# --- 6. taskbar auto-hide ------------------------------------------------------
# A topology change knocks Explorer out of auto-hide WITHOUT changing the
# setting: StuckRects3 still says auto-hide (byte 8, bit 0), the checkbox in
# Settings still looks right, but the bar stays on screen. The live state lives
# behind the AppBar API, so it has to be re-asserted rather than re-written.
#
# byte 8 holds the flags Explorer itself uses - bit 0 ABS_AUTOHIDE, bit 1
# ABS_ALWAYSONTOP - so feeding that byte straight back restores exactly the
# configured state instead of guessing at it.
try {
  $sr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
  $flags = (Get-ItemProperty -Path $sr -Name Settings -ErrorAction Stop).Settings[8]
  if ($flags -band 0x01) {
    if (-not ('TaskbarState' -as [type])) {
      # Fully qualified on purpose: -UsingNamespace collides with the using
      # statements Add-Type already generates.
      Add-Type -Namespace Win -Name TaskbarState -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int left, top, right, bottom; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct APPBARDATA {
  public uint cbSize; public System.IntPtr hWnd; public uint uCallbackMessage;
  public uint uEdge; public RECT rc; public System.IntPtr lParam;
}
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern System.IntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindow(string cls, string win);
'@ -ErrorAction Stop
    }
    $abd = New-Object Win.TaskbarState+APPBARDATA
    $abd.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($abd)
    $abd.hWnd   = [Win.TaskbarState]::FindWindow('Shell_TrayWnd', $null)
    $abd.lParam = [IntPtr]([int]$flags)
    [void][Win.TaskbarState]::SHAppBarMessage(0x0000000A, [ref]$abd)   # ABM_SETSTATE
    Write-Host "  taskbar auto-hide re-asserted"
  }
} catch {
  Write-Host "  WARN: could not re-assert taskbar auto-hide: $_" -ForegroundColor Yellow
}

# --- 7. report ----------------------------------------------------------------
# Everything here can fail silently, so verify against what was asked for.
$live = Get-Live
Write-Host ""
Write-Host "result:" -ForegroundColor Cyan
$ok = $true
foreach ($role in $RoleAliases.Keys) {
  $mon = Resolve-Role $live $role
  if (-not $mon) { Write-Host ("  {0,-9} absent" -f $role); if ($m.On -contains $role) { $ok = $false }; continue }
  $wantState = if ($m.On -contains $role) { 'on' } elseif ($m.Off -contains $role) { 'off' } else { '-' }
  $got  = if ($mon.Active) { 'on' } else { 'off' }
  $flag = ''
  if ($wantState -ne '-' -and $wantState -ne $got) { $flag = "  <-- WANTED $wantState"; $ok = $false }
  if ($mon.Active -and $want.ContainsKey($role)) {
    $expected = $want[$role]
    $expectedX = $expected.X - $dx; $expectedY = $expected.Y - $dy
    $actualX = $null; $actualY = $null
    if ($mon.Pos -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') { $actualX = [int]$matches[1]; $actualY = [int]$matches[2] }
    $actualW = $null; $actualH = $null
    if ($mon.Res -match '^\s*(\d+)\s+X\s+(\d+)\s*$') { $actualW = [int]$matches[1]; $actualH = [int]$matches[2] }
    # 'max' means "whatever this panel tops out at", which is only known after
    # DisplayCtl enumerates it - so there is no number to compare against here.
    # Comparing the literal string would fail every time.
    $hzBad = $false
    if ($expected.Hz -ne 'max') { $hzBad = ($mon.Frequency -ne [int]$expected.Hz) }
    # Windows occasionally rounds a touching edge by one pixel after rotation.
    $geometryBad = ($null -eq $actualX) -or ($null -eq $actualW) -or
      ([math]::Abs($actualX - $expectedX) -gt 1) -or ([math]::Abs($actualY - $expectedY) -gt 1) -or
      ($actualW -ne $expected.W) -or ($actualH -ne $expected.H) -or
      $hzBad -or ($mon.Orientation -ne $expected.Orient)
    if ($geometryBad) {
      $flag += "  <-- WANTED $($expected.W)x$($expected.H) @$($expected.Hz) orient=$($expected.Orient) at $expectedX,$expectedY"
      $ok = $false
    }
  }
  $pri = if ($mon.Primary) { ' PRIMARY' } else { '' }
  Write-Host ("  {0,-9} {1,-3} {2,-11} {3}{4}{5}" -f $role, $got, $mon.Res, $mon.Pos, $pri, $flag)
}
if ($primaryMon -and -not (Resolve-Role $live $m.Primary).Primary) {
  Write-Host "  $($m.Primary) is not primary  <-- WANTED PRIMARY" -ForegroundColor Red
  $ok = $false
}
Write-Host ""
if ($ok) {
  Write-Host "OK - $Mode applied" -ForegroundColor Green
  Remove-Item $tmp -ErrorAction SilentlyContinue
  exit 0
} else {
  Write-Host "FAILED - some displays are not in the requested state." -ForegroundColor Red
  Write-Host "Run again; if it persists, check that the panel is powered on and" -ForegroundColor Red
  Write-Host "that its cable is seated (a detached DisplayPort link needs a replug)." -ForegroundColor Red
  Remove-Item $tmp -ErrorAction SilentlyContinue
  exit 1
}
