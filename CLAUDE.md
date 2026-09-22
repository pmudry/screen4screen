# CLAUDE.md

Working notes for this repository. Read before changing anything.

## What this is

A PowerShell tool that sets a different wallpaper on each monitor
based on the monitor's native resolution, and re-applies on display topology
changes (dock / undock / external screen). Windows 8+, Windows PowerShell 5.1
and PowerShell 7 both targeted.

Layout:

- `screen4screen/` - the module (`.psm1` + manifest). All the logic
  and the embedded C# live here.
- `screen4screen.ps1` - thin CLI wrapper at the repo root. Its
  parameter block and comment-based help are the documented surface; keep
  them in step with README.md.
- `Gui/` - the WPF manager: `Show-Screen4ScreenGui.ps1` (ASCII host) plus
  `MainWindow.xaml` (UTF-8, holds every user-facing string).
- `screen4screen.cmd` - launcher needing no build, but it shows a console.
- `build/` - `Launcher.cs` plus `Build-Launcher.ps1`, which compiles
  `screen4screen.exe` with the .NET Framework compiler that ships with
  Windows. `/target:winexe` is what removes the console for good, and
  `/win32icon` is the only way to get an icon in Explorer. The `.exe` is
  gitignored; build it after cloning.
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
- **Event-driven via our own hidden window, polling only as a fallback.**
  `WallByRes.DisplayNotifier` creates a real top-level window on its own
  thread, pumps it, and signals on `WM_DISPLAYCHANGE`. Two things were
  measured rather than assumed. `Microsoft.Win32.SystemEvents` does not work
  here: on the .NET Framework it listens on a message-only window, and
  message-only windows are excluded from broadcasts, so a broadcast
  `WM_DISPLAYCHANGE` never reached it from Windows PowerShell (it did reach
  PowerShell 7, which uses a different implementation). And the window must
  stay top-level for the same reason; do not "tidy" it into `HWND_MESSAGE`.
  Enumerating the adapters costs about 50 ms, too much to spend every 3 s on
  a laptop, so the fallback poll now defaults to 15 s.
- **The `WndProcDelegate` is held in a field.** If it is collected the window
  procedure becomes a dangling pointer and the process dies on the next
  message.
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
- **Launch cost has been measured; do not guess at it.** Roughly: 300 ms for
  the PowerShell process, 100 ms for the module, 250 ms to parse the XAML,
  350 ms for the first WPF render. That is the floor for a PowerShell-hosted
  WPF window, so `screen4screen.exe` shows a splash within a few tens of
  milliseconds and closes it when the real window appears. Deferring the
  list build was tried and reverted: it did not make the window appear
  sooner, only emptier.
- **`Get-WallpaperTaskState` uses the Task Scheduler COM API**, not
  `Get-ScheduledTask`. The cmdlet costs about 700 ms against 40 ms for COM,
  and this is queried on every state change.
- **Thumbnails decode in a runspace pool, never on the UI thread.** One
  sample webp takes about half a second no matter what `DecodePixelWidth`
  says, because the codec expands the whole image before scaling; on the UI
  thread that is a wait cursor per monitor. They come back `Freeze()`d,
  which is what makes a WPF image safe to cross threads. A C# helper was
  tried first and dropped: `Add-Type -ReferencedAssemblies` adds to the
  default reference set on Windows PowerShell but replaces it on
  PowerShell 7, and no single list satisfied both.
- The embedded C# is compiled once into a cached DLL under the data folder,
  named after a hash of the source. Worth a little, not the bottleneck.
- The window never re-applies on a topology change. That is the background
  task's job, and doing both would double-apply and flash.
- **The scheduled task runs through `conhost.exe --headless`.** Passing
  `-WindowStyle Hidden` to `powershell.exe` creates the console and only then
  hides it, so a black window flashes at every logon and every time the task
  starts. `conhost --headless` never creates one.
- `AboutWindow.xaml` states plainly what the tool touches on the machine: the
  wallpaper, the logon task, the log, the two JSON files, and what it does not
  do. Keep it truthful if any of that changes.

## Supported hosts

Windows PowerShell 5.1 and PowerShell 7, on Windows 8 or later. The module
checks all three at import and throws a plain message rather than failing
later inside the interop layer; the entry scripts carry `#Requires -Version
5.1`. The scheduled task always runs Windows PowerShell, because it is the
one present on every install.

## GUI traps found the hard way

- **`$args` inside a block handed to `Invoke-Guarded` is empty.** The block
  is invoked with no arguments, so `$args[1]` there indexes nothing. Read
  the event in the handler itself and pass it through `$script:State`. The
  row buttons never worked because of this.
- **Never use `.GetNewClosure()` in this window.** A closure gets its own
  script scope, so `$script:Ui` resolves to `$null` inside it and every
  control access throws.
- **WinForms dialogs need an owner.** Shown from the WPF window without
  one, they open behind it and never take focus, so the button looks dead.
  `Get-DialogOwner` wraps the window handle.
- **The icon must carry BMP frames, not PNG-compressed ones.**
  `System.Drawing.Icon` on the .NET Framework cannot decode PNG frames and
  renders them as noise, which is what the splash showed. Pillow writes PNG
  frames by default, so `assets/screen4screen.ico` is assembled by hand:
  BMP up to 64 px, PNG only for the 256 px frame, which is 50 KB instead of
  380 KB.
- **The taskbar groups by application id.** Without
  `SetCurrentProcessExplicitAppUserModelID` the button shows the PowerShell
  icon no matter what the window's own icon is.
- `screen4screen.exe` embeds the icon, so changing `assets/screen4screen.ico`
  or `build/Launcher.cs` needs a rebuild. Nothing else does: the window and
  the module are read at launch. `Build-Launcher.ps1` checks and says so.

## Conventions

- ASCII only inside `.ps1`/`.psm1`/`.psd1` (comment-based help included) so
  they behave identically whether read as UTF-8 or ANSI by PowerShell 5.1.
  `.xaml` is exempt: XML declares its own encoding, so the GUI's French
  strings are safe there. Keep every user-facing string in the XAML.
- `Set-StrictMode -Version Latest` is on. Keep it on.
- Functions are `Verb-Noun` with approved verbs.
- Log through `Write-Log`; never let logging throw.
- No external modules. The only binaries tracked are the three ISC sample
  backgrounds under `examples/wallpapers/` and the icon under `assets/`;
  keep it that way. The icon is generated by a short PIL script, kept in the
  commit message rather than as a build step.

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
5. ~~Event-driven trigger catching `WM_DISPLAYCHANGE`.~~ Done, for both the
   watcher and the window.
6. `-WhatIf` support on `Set-WallpapersNow`.
7. Publish to PowerShell Gallery. The module folder name already matches
   the module name, so `Publish-Module -Path ./screen4screen` works.
8. CI: PSScriptAnalyzer + Pester on `windows-latest`.

## Testing on a real machine

```powershell
.\screen4screen.ps1 -Once -Verbose
```

prints the detected monitors with their native resolutions and which file
was picked for each. Check `%LOCALAPPDATA%\screen4screen\log.txt`
for the background task.

## Commit messages

Plain imperative subject line, no tool attribution or trailers.
