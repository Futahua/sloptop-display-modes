# Runs at logon via the "SlopTop display layout" scheduled task.
#
# Why this exists: CDS_UPDATEREGISTRY is refused on this machine, so monitor
# POSITIONS are applied dynamically and do not survive a reboot - Windows brings
# the panels back in its default three-in-a-row strip. Orientation, resolution
# and primary do persist, which is why only the arrangement looks wrong.
#
# Always applies sloptop, never ipad, even if the machine was in ipad mode when
# it shut down: at logon there may be no iPad attached to receive the virtual
# display, and restoring a virtual-display-only desktop would leave every
# physical panel dark with no way to see what you are doing.
#
# It then syncs mode.state, because TOGGLE MODE.bat reads that file to decide
# which direction to switch. Leaving it saying "ipad" after we forced sloptop
# would make the next toggle press a no-op.

$ErrorActionPreference = 'Continue'
$d     = Split-Path -Parent $PSScriptRoot
$state = "D:\Letters\MatTroiSeConMoc\Papers\User Generated\mode.state"
$log   = Join-Path $PSScriptRoot 'logon-layout.log'

$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
try {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'apply-mode.ps1') -Mode sloptop 2>&1
  $rc  = $LASTEXITCODE
  "[$stamp] apply-mode sloptop -> exit $rc" | Out-File -FilePath $log -Append -Encoding utf8
  $out | Out-File -FilePath $log -Append -Encoding utf8

  if (Test-Path (Split-Path $state -Parent)) {
    Set-Content -Path $state -Value 'slop' -NoNewline -Encoding ascii
    "[$stamp] mode.state -> slop" | Out-File -FilePath $log -Append -Encoding utf8
  }
} catch {
  "[$stamp] ERROR: $_" | Out-File -FilePath $log -Append -Encoding utf8
}

# Keep the log from growing without bound.
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 200KB)) {
  $tail = Get-Content $log -Tail 400
  Set-Content -Path $log -Value $tail -Encoding utf8
}
