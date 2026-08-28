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

## Open problem: re-attaching a detached display

`ipad` mode disconnects the three physical panels. Nothing here can reliably
reconnect them.

- `DisplaySwitch.exe /extend` does not re-attach them (tested to 35s). It applies
  a blanket topology; these paths stay detached.
- MultiMonitorTool `/enable` cannot address them — a detached display exposes no
  Monitor ID, so there is nothing to match on.
- Windows Settings → *Extend desktop to this display* **does** work, so the
  operation is possible; it enables one specific path rather than a preset.

`DisplayCtl.cs` does what Settings does, via `QueryDisplayConfig` /
`SetDisplayConfig`. Reading works and the allocator is now correct; applying is
still blocked.

**Confirmed by review and measurement:**

- `SDC_VIRTUAL_MODE_AWARE` / `QDC_VIRTUAL_MODE_AWARE` are mandatory here. A
  `selftest` that validates the *current, unmodified* config returns 0 with
  `supplied+changes+vma`, and `87` without the virtual-mode flag. Any experiment
  run without it was meaningless.
- The earlier `SDC_TOPOLOGY_SUPPLIED` attempt was malformed: that flag requires
  *every* supplied path to have invalid source and target mode indices, and this
  code only invalidated the newly-enabled ones. Its 87 was expected.
- `QDC_ALL_PATHS` returns every source→target combination in priority order, so
  the first candidate for each monitor is always `src=0`. Activating those gives
  three targets on one source, which is a **clone group** — the documented way to
  request cloning. That fully explains the old "four active CCD paths, two GDI
  screens" symptom: `SetDisplayConfig` was not failing, it was building exactly
  the clone topology it was handed.
- Rewriting `sourceInfo.id` to force a free source yields 87. Source→target
  pairings that Windows did not enumerate are not legal.

The tool now reserves sources held by displays it is not rebuilding, then
searches the enumerated candidate rows for a combination of distinct sources,
checking each with `SDC_VALIDATE` before applying anything.

**Where it still fails.** On this machine every multi-source topology is
rejected:

- 3 monitors, all 24 distinct-source combinations → `87`
- 2 monitors, all 6 combinations → `87`
- the existing 3-targets-on-`src=0` clone, unmodified → validates `0`

So Windows currently accepts these targets only as a clone group. That is not an
allocation bug — the search covers the whole space and validates before acting —
which suggests display-driver state rather than the code. Untested since: whether
Windows Settings can still extend by hand in this state, and whether a clean boot
changes it.
Current workaround: re-attach via Settings, then run `SLOPTOP MODE.bat`, which
handles everything else.

## Notes

- `.cfg` files are machine-specific — monitor IDs, positions, and one panel's
  serial number. They will not transfer to another setup.
- Wallpaper paths point at `D:\333\`.
- `SetWallpaper.exe` and `DisplayCtl.exe` are gitignored; build with
  `Build SetWallpaper.bat` or the `csc` line at the top of `DisplayCtl.cs`.
