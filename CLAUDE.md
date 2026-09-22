# CLAUDE.md

Working notes for this repository. Read before changing anything.

## What this is

A PowerShell tool that sets a different wallpaper on each monitor
based on the monitor's native resolution, and re-applies on display topology
changes (dock / undock / external screen). Windows 8+, Windows PowerShell 5.1
and PowerShell 7 both targeted.

Layout:

- `WallpaperByResolution/` - the module (`.psm1` + manifest). All the logic
  and the embedded C# live here.
- `Set-WallpaperByResolution.ps1` - thin CLI wrapper at the repo root. Its
  parameter block and comment-based help are the documented surface; keep
  them in step with README.md.
- `Gui/` - the WPF manager: `Show-WallpaperGui.ps1` (ASCII host) plus
  `MainWindow.xaml` (UTF-8, holds every user-facing string).
- `WallpaperGui.cmd` - double-clickable launcher, passes `-ExecutionPolicy Bypass`.
- `examples/wallpapers/` - three ISC sample backgrounds, named for the lookup.

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
- **Preference variables do not cross into the module.** `-Once` used to set
  `$VerbosePreference = 'Continue'` in script scope and `Write-Log` picked it
  up. Once the logic moved into a module, a module function's scope chain is
  local -> module -> global and skips the calling script entirely, so the
  per-monitor log lines vanished. The wrapper now passes `-Verbose` explicitly
  to the module functions. Do not replace that with a preference assignment.
- **`Add-Type` types never unload.** `Remove-Module` and `Import-Module -Force`
  keep the old `WallByRes` assembly in the AppDomain. Editing the embedded C#
  requires a fresh PowerShell process; the `-as [type]` guard in
  `Initialize-NativeType` exists so a re-import does not throw.
- **All `IDesktopWallpaper` calls live in the C# `Wallpaper` helper class.**
  PowerShell cannot drive the interface itself: `New-Object` plus a cast to a
  `[ComImport]` interface does not issue the QueryInterface, and an object
  returned as `IDesktopWallpaper` arrives back in PowerShell as
  `System.__ComObject` with no methods, the interface being IUnknown-only with
  no IDispatch. Add new COM calls to that class, not to the script body.

## GUI notes

- **Assigning a brush into `Window.Resources` needs an explicit cast.** The
  `ResourceDictionary` indexer takes an `object`, so nothing forces PowerShell
  to unwrap its `PSObject`; WPF then stores the wrapper and falls back to its
  `ToString`, failing with "'#FF1B1D20' is not a valid value for property
  'Background'". Cast to `[System.Windows.Media.Brush]` on the way in.
- **A `DispatcherTimer` on the UI thread, never a background runspace.** The
  work is a few `EnumDisplayDevices` calls and two COM calls; a worker runspace
  would be MTA and every `IDesktopWallpaper` call would cross an apartment
  boundary. The only slow thing in the watch loop is `Start-Sleep`, which is
  exactly what a timer replaces.
- **Thumbnails are decoded from a stream we dispose**, with `CacheOption =
  OnLoad` set before `EndInit` and `DecodePixelWidth` capped. A `BitmapImage`
  with a `UriSource` holds the file open and caches on the URI, so a replaced
  image would keep showing old pixels. `.webp` has no WIC decoder on a stock
  Windows, so every thumbnail load is wrapped and degrades to a blank tile;
  applying a `.webp` wallpaper is unaffected, that path is Windows' own.
- The window never re-applies on a topology change. That is the background
  task's job, and doing both would double-apply and flash.
- **The scheduled task runs through `conhost.exe --headless`.** Passing
  `-WindowStyle Hidden` to `powershell.exe` creates the console and only then
  hides it, so a black window flashes at every logon and every time the task
  starts. `conhost --headless` never creates one.
- `AboutWindow.xaml` states plainly what the tool touches on the machine: the
  wallpaper, the logon task, the log, the two JSON files, and what it does not
  do. Keep it truthful if any of that changes.

## Conventions

- ASCII only inside `.ps1`/`.psm1`/`.psd1` (comment-based help included) so
  they behave identically whether read as UTF-8 or ANSI by PowerShell 5.1.
  `.xaml` is exempt: XML declares its own encoding, so the GUI's French
  strings are safe there. Keep every user-facing string in the XAML.
- `Set-StrictMode -Version Latest` is on. Keep it on.
- Functions are `Verb-Noun` with approved verbs.
- Log through `Write-Log`; never let logging throw.
- No external modules. The only binaries tracked are the three ISC sample
  backgrounds under `examples/wallpapers/`; keep it that way.

## Roadmap (rough priority order)

1. ~~Split into a module.~~ Done.
2. Pester tests for the naming/fallback logic. `Resolve-WallpaperFile` is now
   a thin wrapper over the private `Resolve-WallpaperCandidate`, which returns
   both the path and which candidate matched, so both are testable. Mock
   `Get-Random` or the folder branch is non-deterministic.
3. ~~`wallpapers.json` pinning an image to a monitor.~~ Done. Keyed on device
   interface path only: the friendly name cannot tell two identical panels
   apart, which was the whole point. Stored in the image folder, with the
   image path relative when it lives inside that folder.
4. ~~Console-flash-free launcher for the scheduled task.~~ Done, via
   `conhost --headless`. A `.vbs` shim was considered and rejected: Windows
   Script Host is disabled on many managed machines. Builds older than 22621
   fall back to the plain host and keep the flash.
5. Optional event-driven trigger: hidden `NativeWindow` catching
   `WM_DISPLAYCHANGE`, with polling kept as a fallback.
6. `-WhatIf` support on `Set-WallpapersNow`.
7. Publish to PowerShell Gallery. The module folder name already matches
   the module name, so `Publish-Module -Path ./WallpaperByResolution` works.
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
