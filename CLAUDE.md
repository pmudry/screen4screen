# CLAUDE.md

Working notes for this repository. Read before changing anything.

## What this is

A single-file PowerShell tool that sets a different wallpaper on each monitor
based on the monitor's native resolution, and re-applies on display topology
changes (dock / undock / external screen). Windows 8+, Windows PowerShell 5.1
and PowerShell 7 both targeted.

Entry point: `Set-WallpaperByResolution.ps1`. Everything lives there for now.

## Design decisions, do not undo without a reason

- **Native resolution comes from `EnumDisplaySettings(ENUM_CURRENT_SETTINGS)`**,
  never from `System.Windows.Forms.Screen`, `GetSystemMetrics` or
  `IDesktopWallpaper::GetMonitorRECT`. Those return DPI-scaled logical pixels
  unless the process is per-monitor DPI aware, which a PowerShell host is not.
- **Monitors are matched by device interface path**
  (`EnumDisplayDevices` with `EDD_GET_DEVICE_INTERFACE_NAME` on the monitor
  level, compared case-insensitively with `IDesktopWallpaper::GetMonitorDevicePathAt`).
  Do not match by index: `GetMonitorDevicePathCount` includes monitors that
  are currently disconnected.
- **Wallpaper is applied with `IDesktopWallpaper::SetWallpaper`**, not
  `SystemParametersInfo(SPI_SETDESKWALLPAPER)`, which is single-image only.
- **Two passes after a change**, separated by ~3 s. Windows restores its own
  transcoded wallpaper cache shortly after a topology change and the first
  pass is often overwritten.
- **Polling loop, not `SystemEvents.DisplaySettingsChanged`.** The event
  needs a message pump and is unreliable from a headless PowerShell process.
  Polling `EnumDisplayDevices` every 3 s costs nothing measurable.
- C# is embedded via `Add-Type` and must stay **C# 5 compatible** (no
  expression-bodied members, no string interpolation, no `nameof`) so it
  compiles under Windows PowerShell 5.1's built-in compiler.
- The `DEVMODE` struct layout is the standard one used everywhere; the
  union is flattened as `dmPositionX/Y + dmDisplayOrientation +
  dmDisplayFixedOutput` (16 bytes, matches both union arms). Do not
  reorder fields.
- **Never pass `$null` to a P/Invoke or COM `[string]` parameter.** PowerShell
  binds `$null` as the empty string, and `EnumDisplayDevices("")` fails where
  `EnumDisplayDevices(NULL)` enumerates the adapters. This silently returned
  zero displays until it was tracked down. Use `[NullString]::Value`; the two
  call sites (adapter enumeration, and the all-monitors `SetWallpaper`) are
  commented in place.
- **All `IDesktopWallpaper` calls live in the C# `Wallpaper` helper class.**
  PowerShell cannot drive the interface itself: `New-Object` plus a cast to a
  `[ComImport]` interface does not issue the QueryInterface, and an object
  returned as `IDesktopWallpaper` arrives back in PowerShell as
  `System.__ComObject` with no methods, the interface being IUnknown-only with
  no IDispatch. Add new COM calls to that class, not to the script body.

## Conventions

- ASCII only inside the script (comment-based help included) so it behaves
  identically whether the file is read as UTF-8 or ANSI by PowerShell 5.1.
- `Set-StrictMode -Version Latest` is on. Keep it on.
- Functions are `Verb-Noun` with approved verbs.
- Log through `Write-Log`; never let logging throw.
- No external modules. The only binaries tracked are the three ISC sample
  backgrounds under `examples/wallpapers/`; keep it that way.

## Roadmap (rough priority order)

1. Split into a module (`WallpaperByResolution.psm1` + manifest), keep the
   `.ps1` as a thin CLI wrapper. Enables Pester tests on
   `Resolve-WallpaperFile` and `Get-AttachedDisplay` (mock the P/Invoke layer).
2. Pester tests for the naming/fallback logic.
3. Optional JSON config (`wallpapers.json`) mapping a monitor's friendly name
   or device path to an explicit image, overriding the resolution lookup.
   Useful when two monitors share a resolution.
4. Console-flash-free launcher for the scheduled task (`conhost --headless`
   on Windows 11, or a tiny `.vbs` shim for older builds).
5. Optional event-driven trigger: hidden `NativeWindow` catching
   `WM_DISPLAYCHANGE`, with polling kept as a fallback.
6. `-WhatIf` support on `Set-WallpapersNow`.
7. Publish to PowerShell Gallery once the module split is done.
8. CI: PSScriptAnalyzer + Pester on `windows-latest`.

## Testing on a real machine

```powershell
.\Set-WallpaperByResolution.ps1 -Once -Verbose
```

prints the detected monitors with their native resolutions and which file
was picked for each. Check `%LOCALAPPDATA%\WallpaperByResolution\log.txt`
for the background task.

## Commit messages

Plain imperative subject line, no tool attribution or trailers.
