# Prints the mode the machine is ACTUALLY in right now: slop | ipad | unknown.
#
# TOGGLE MODE.bat used to decide direction purely from a mode.state file. That
# file drifts: anything that changes the topology without going through the
# toggle (the logon task, a manual "SLOPTOP MODE.bat", Windows itself deciding
# to reattach a panel) leaves the file describing a world that no longer
# exists, and the next press then "toggles" into the mode you are already in -
# which looks exactly like a dead hotkey.
#
# Live topology is the only honest source. mode.state stays as the fallback for
# the unknown case, and still gets written, so nothing else has to change.

$root = Split-Path -Parent $PSScriptRoot
$mmt  = Join-Path $root 'MultiMonitorTool.exe'
$tmp  = Join-Path $env:TEMP "curmode-$PID.txt"

$VDD      = @('MTT1337')
$Physical = @('SAC2453','EDR2380','AOC2269','HJW9291','FME7210','TS35505')

try {
    & $mmt /stab $tmp | Out-Null
    Start-Sleep -Milliseconds 600
    $rows = @(Import-Csv $tmp -Delimiter "`t" -ErrorAction Stop)
} catch {
    'unknown'; exit 0
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

$active = @($rows | Where-Object { $_.Active -eq 'Yes' } | ForEach-Object { $_.'Short Monitor ID' })

$vddOn  = @($active | Where-Object { $VDD -contains $_ }).Count -gt 0
$physOn = @($active | Where-Object { $Physical -contains $_ }).Count -gt 0

# ipad mode is the VDD alone. sloptop is any physical panel being lit - even a
# partially applied sloptop counts, because the way out of it is another
# sloptop apply, not an ipad apply.
if     ($physOn)          { 'slop' }
elseif ($vddOn)           { 'ipad' }
else                      { 'unknown' }
