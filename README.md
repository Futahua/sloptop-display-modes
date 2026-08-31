# Display mode switching (SlopTop)

Scripts that switch a Windows 11 desktop between display arrangements — a
three-monitor desk setup, a virtual-display-only mode streamed to an iPad, and a
few variants that add a Samsung panel or a laptop screen.

MultiMonitorTool is retained for state reporting. Topology and geometry are
applied directly through the Windows display APIs because MMT can wedge after a
topology change while still returning success.

---

## Layout

| File | Role |
|---|---|
| `apply-mode.ps1` | All the logic. Resolves monitors by role, applies a mode, verifies the result. |
| `*.bat` | One-line wrappers: `apply-mode.ps1 -Mode <name>` |
| `*.cfg` | Saved layouts, written by MultiMonitorTool's GUI |
| `SetWallpaper.cs` | Per-monitor wallpaper via `IDesktopWallpaper` |
| `DisplayCtl.cs` | CCD attach/detach and dynamic geometry |
| `regenerate-modes.ps1` | Superseded by `apply-mode.ps1`; kept for reference |

Modes: `sloptop`, `ipad`, `samsung`, `ipadmon`, `ipadlap`.

A separate `TOGGLE MODE.bat` (outside this repo, under `Papers\User Generated\`)
alternates between `sloptop` and `ipad` using a `mode.state` file.

## Why it is shaped this way

Four non-obvious behaviours drove the design. Each one silently produced a wrong
result rather than an error.

**1. Monitor identifiers are not stable.** The class instance suffix changes as
devices re-enumerate — the same panel has been `EDR2380\…\0006` and
`EDR2380\…\0011`. Moving a panel to a different GPU port can change its identity
entirely: the AOC reports as `AOC2269` on one port and `HJW9291` (the adapter's
MacroSilicon EDID) on another. Any script holding a literal monitor ID stops
working the moment either shifts, and MultiMonitorTool reports success while
doing nothing. Hence role-based resolution with alias lists in `$RoleAliases`.

**2. `LoadConfig` does not fully restore a layout.** Config files are now read
only as geometry data. `DisplayCtl layout` applies position, size, rotation and
refresh directly; MultiMonitorTool never applies the layout.

**3. Disabling the primary needs a fresh anchor.** `DisplayCtl` blanks source
modes for the surviving paths and assigns fresh clone groups, allowing Windows
to re-anchor before geometry is applied.

**4. `SetWallpaper --primary` overwrites the primary monitor.** It calls
`SystemParametersInfo(SPI_SETDESKWALLPAPER)`, which lands last and repaints
whichever display is primary, clobbering the per-monitor assignment made moments
earlier. Every mode names all its monitors explicitly, so the global fallback has
nothing to fall back for — the flag is simply not used.

Additionally, MultiMonitorTool 2.21 on Windows 11 build 26200 intermittently
stops responding after a topology change: commands return success and do nothing,
and it does not recover on its own — something must change in Windows display
settings first. `apply-mode.ps1` therefore verifies its own result and reports
the failure explicitly instead of trusting exit codes.

## Attaching and detaching displays (solved)

`ipad` mode detaches the physical panels. Neither `DisplaySwitch.exe /extend` nor
MultiMonitorTool `/enable` can bring them back — a detached display exposes no
Monitor ID, so MMT cannot address it at all. `DisplayCtl.exe` does it through the
CCD API, and `apply-mode.ps1` calls it for both directions.

The piece that made it work: **under `SDC_VIRTUAL_MODE_AWARE` the source
`modeInfoIdx` is packed** — high 16 bits `sourceModeInfoIdx`, low 16 bits
`cloneGroupId`. Writing `0xffffffff` therefore does not mean "no mode", it means
no source mode *and no clone-group identity*. With no source mode supplied,
`cloneGroupId` is the only thing telling Windows how paths group into desktops,
so every independently extended display needs its own group:

```csharp
source.modeInfoIdx = (SOURCE_MODE_INVALID << 16) | (cloneGroup & 0xffff);
```

With distinct clone groups the topology validates on the first attempt. Without
them every multi-source arrangement is rejected with 87 — which had looked like
"the driver refuses multi-source topology" and was nothing of the kind.

Other things that matter here:

- `QDC_VIRTUAL_MODE_AWARE` / `SDC_VIRTUAL_MODE_AWARE` are mandatory. A `selftest`
  validating the *current, unmodified* config returns 0 with them and 87 without,
  so any experiment omitting them is uninterpretable.
- `QDC_ALL_PATHS` returns all source→target combinations in priority order, so
  activating the first candidate per monitor puts them all on source 0 — a clone
  group. That produced the "four active CCD paths, two GDI screens" symptom:
  `SetDisplayConfig` was building exactly what it was asked for.
- Enable every target in ONE call. Separate calls make each new path claim the
  source the previous one just took.
- Switching off the display that is currently primary is rejected. When
  disabling, blank the source modes of the surviving paths and give them fresh
  clone groups so Windows re-anchors and picks a new primary itself.
- Detach *before* the layout step. Detaching blanks source modes and makes Windows
  re-anchor the desktop, so geometry must be the final topology operation.
- Everything is checked with `SDC_VALIDATE` before being applied, and the enable
  path searches candidate source assignments rather than guessing at one.

## Dynamic geometry

`CDS_TEST` accepts the requested modes. `CDS_UPDATEREGISTRY` is specifically
refused on this machine, while `ChangeDisplaySettingsEx` with flags 0 succeeds.
Layouts are therefore dynamic; every batch switch reapplies them. Windows pins
the current primary at `(0,0)`, so the script translates each saved layout around
that display while preserving relative geometry. Changing the primary still
requires doing it once in Windows Settings.
## Refresh rates

Every display runs at the highest refresh it reports for its current resolution.
`DisplayCtl` enumerates the supported modes and picks the maximum rather than
trusting the rate saved in a cfg — a saved rate goes stale as soon as a link
renegotiates, and then either fails to apply or silently caps a panel below its
ceiling. `DisplayCtl.exe modes` shows what each panel offers.

`$RefreshPin` in `apply-mode.ps1` holds a role *below* its maximum. Only `VDD` is
pinned, to 60: it is streamed over the network to the iPad, so a higher rate
costs bandwidth and encoding for no visible benefit.

Note that modes are enumerated in the panel's native orientation, so a rotated
target (1080x1920) has to be matched against the 1920x1080 mode as well.

## Positions do not survive a reboot

`CDS_UPDATEREGISTRY` is refused on this machine, so positions are applied
dynamically only. Orientation, resolution and primary *are* stored by Windows,
which is why a fresh boot has those right and lays the monitors out in a
default three-in-a-row strip.

A scheduled task, `SlopTop display layout`, re-applies sloptop 25 seconds after
logon via `logon-layout.ps1`. The delay lets the GPU finish enumerating panels;
positioning them before that yields a half-applied layout.

It always applies sloptop, never ipad, even if the machine was in ipad mode when
it shut down — at logon there may be no iPad attached to receive the virtual
display, and a virtual-display-only desktop would leave every physical panel dark
with no way to see anything. It then rewrites `mode.state` to `slop`, because
`TOGGLE MODE.bat` reads that file to choose direction and would otherwise need
two presses to reach ipad mode.

Remove it with:

```powershell
Unregister-ScheduledTask -TaskName "SlopTop display layout" -Confirm:$false
```

The durable alternative, not yet attempted: build explicit
`DISPLAYCONFIG_SOURCE_MODE` records carrying each position and apply them with
`SetDisplayConfig` + `SDC_SAVE_TO_DATABASE`, the path Windows Settings itself
uses. That would persist without anything running at logon.
## Notes

- `.cfg` files are machine-specific — monitor IDs, positions, and one panel's
  serial number. They will not transfer to another setup.
- Wallpaper paths point at `D:\333\`.
- `SetWallpaper.exe` and `DisplayCtl.exe` are gitignored; build with
  `Build SetWallpaper.bat` or the `csc` line at the top of `DisplayCtl.cs`.
