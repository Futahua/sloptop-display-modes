# Display mode switching (SlopTop)

Scripts that switch a Windows 11 desktop between display arrangements — a
three-monitor desk setup, a virtual-display-only mode streamed to an iPad, and a
few variants that add a Samsung panel or a laptop screen.

Built around [NirSoft MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html)
(not redistributed here — download separately into this folder).

**Open problem below.** Review is most useful on that.

---

## Layout

| File | Role |
|---|---|
| `apply-mode.ps1` | All the logic. Resolves monitors by role, applies a mode, verifies the result. |
| `*.bat` | One-line wrappers: `apply-mode.ps1 -Mode <name>` |
| `*.cfg` | Saved layouts, written by MultiMonitorTool's GUI |
| `SetWallpaper.cs` | Per-monitor wallpaper via `IDesktopWallpaper` |
| `DisplayCtl.cs` | CCD path inspection (`QueryDisplayConfig`) — see open problem |
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

**2. `LoadConfig` does not fully restore a layout.** It re-anchors positions on
whichever monitor it chooses, drops rotation, and drops refresh rate. Config
files also do not record which display is primary. So each mode applies the cfg,
then re-asserts primary, then re-asserts each panel's full mode via
`/SetMonitors` using geometry read back out of that same cfg.

**3. Windows refuses to disable the primary display.** Primary must move to a
panel that will stay on *before* anything is switched off, or the disable is
silently refused and everything downstream cascades.

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
- Detach *after* the layout step. `LoadConfig` / `/SetMonitors` re-materialise the
  virtual display, so anything switched off earlier comes back.
- Everything is checked with `SDC_VALIDATE` before being applied, and the enable
  path searches candidate source assignments rather than guessing at one.

## Still open: geometry when MultiMonitorTool is wedged

Attach/detach no longer depends on MultiMonitorTool. Positions, rotation, refresh
rate and primary selection still do, and MMT wedges regularly on this build — so
a round trip currently ends with the right *set* of displays in the wrong
arrangement, and `apply-mode.ps1` reports the failure.

`DisplayCtl.exe primary <match>` is a first attempt at moving primary via
`ChangeDisplaySettingsEx` (shift all displays so the target sits at 0,0, with
`CDS_SET_PRIMARY`). It currently returns `DISP_CHANGE_FAILED` (-1) per display
while the final commit returns 0, and the primary does not move. Unresolved.
## Notes

- `.cfg` files are machine-specific — monitor IDs, positions, and one panel's
  serial number. They will not transfer to another setup.
- Wallpaper paths point at `D:\333\`.
- `SetWallpaper.exe` and `DisplayCtl.exe` are gitignored; build with
  `Build SetWallpaper.bat` or the `csc` line at the top of `DisplayCtl.cs`.
