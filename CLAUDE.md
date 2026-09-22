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
- `Gui/` - the WPF manager: `Show-Screen4ScreenGui.ps1` (ASCII host),
  `MainWindow.xaml` and `AboutWindow.xaml` (UTF-8, structure only), and
  `Gui/Lang/{fr,en,de,it}.xaml`, which hold every user-facing string.
- `screen4screen.cmd` - launcher needing no build, but it shows a console.
- `build/` - `Launcher.cs` plus `Build-Launcher.ps1`, which compiles
  `screen4screen.exe` with the .NET Framework compiler that ships with
  Windows. `/target:winexe` is what removes the console for good, and
  `/win32icon` is the only way to get an icon in Explorer. The `.exe` is
  gitignored; build it after cloning.
- `wallpapers/` - the default image folder, holding three ISC sample
  backgrounds named for the lookup. Both entry points default here, so a
  fresh clone works with no argument; everything else in it is gitignored.

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
- **`DisplayNotifier` is torn down with `WM_CLOSE`, from the pump thread.**
  The first version posted `WM_DESTROY` and then called `DestroyWindow` from
  the disposing thread. Neither does anything: `WM_DESTROY` is a notification
  `DefWindowProc` ignores, and `DestroyWindow` only works on the thread that
  created the window. Measured, not assumed - after `Dispose()` the window was
  still a window and the pump thread still running. Posting `WM_CLOSE` lets
  `DefWindowProc` call `DestroyWindow` on the owning thread; `WndProc` answers
  `WM_DESTROY` with `PostQuitMessage`, which ends `GetMessage`, and only then
  can the class be unregistered. The constructor now throws when the window
  cannot be created, so a caller falls back to polling instead of holding a
  notifier whose `Wait` can only time out.
- **The compiled assembly is cached per host edition.** The file name carries
  the source hash *and* `Desktop`/`Core`. Windows PowerShell cannot load an
  assembly built by PowerShell 7, `Add-Type -Path` throws, and the failed load
  leaves the file locked so the rebuild cannot replace it either: every later
  5.1 run fell back to compiling in memory, permanently. The sweep of old
  builds matches on the hash, not the whole name, or each host would delete
  the other's copy and both would rebuild for ever.
- C# is embedded via `Add-Type` and must stay **C# 5 compatible** (no
  expression-bodied members, no string interpolation, no `nameof`) so it
  compiles under Windows PowerShell 5.1's built-in compiler.
- The `DEVMODE` struct layout is the standard one used everywhere; the
  union is flattened as `dmPositionX/Y + dmDisplayOrientation +
  dmDisplayFixedOutput` (16 bytes, matches both union arms). Do not
  reorder fields.
- **The scheduled task's `-WallpaperRoot` has its trailing backslashes
  doubled.** Inside a quoted argument a trailing `\` escapes the closing
  quote, so `"D:\Wallpapers\"` is read by `CommandLineToArgvW` as one
  argument running on into the rest of the line: `-WallpaperRoot` swallowed
  the remainder and `-Position` was never passed at all. A drive root is
  exactly what the folder picker in the window returns. Doubling the trailing
  run is the escape the C runtime expects.
- **Every public `-Root` is resolved to an absolute path** through
  `Resolve-RootPath`. The task starts in `system32`, so a relative folder
  baked into its command line can never be found; and PowerShell's current
  directory is not the process's, which `[System.IO.File]::WriteAllText` in
  `Save-WallpaperAssignment` uses.
- **Writers refuse to rebuild `wallpapers.json` from a read that failed.**
  `Get-AssignmentRecord` returns `Ok = $false` when the file is present but
  empty, unparseable or foreign in shape - the state a sync tool leaves
  mid-flight. Read-only callers carry on with nothing, as the watch loop must;
  `Set-` and `Remove-WallpaperAssignment` throw rather than drop every other
  monitor's pin.
- **`Start-Sleep -Milliseconds`, never `-Seconds`, for `SettleDelay`.** The
  parameter is a `[double]`, but `-Seconds` takes an `[int]` on Windows
  PowerShell 5.1 and a `[double]` on 7: measured, `-SettleDelay 0.4` slept
  2 ms under 5.1 and 413 ms under pwsh, on the host the task actually uses.
- **`$PSScriptRoot` is empty inside a `param()` default.** Defaults are
  evaluated before it is populated, so `[string] $WallpaperRoot = (Join-Path
  $PSScriptRoot 'wallpapers')` made `Join-Path` throw during parameter
  binding: the process died before the script body, and before any trap, so
  nothing reached the log and the launcher could only report an exit code.
  The default is filled in in the body instead. Reading the AST of a default
  proves nothing; run the script.
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

- **A custom `TextBox` template must not bind `Padding` into the content
  host's `Margin`.** `TextBoxBase` already pushes its `Padding` onto
  `PART_ContentHost`, so `Margin="{TemplateBinding Padding}"` applied it
  twice: the path sat 27px from its border (1 border + 12 margin + 12 padding
  + 2) while the drop-down underneath sat at 15, and the two rows visibly
  failed to line up. Measured through the visual tree, both are at x=156 now.
  The `ComboBox` template ignores `Padding` entirely and hardcodes
  `Margin="15,0,32,0"` on its `ContentPresenter`, which is the number the
  text box has to match.
- **The window can be measured and rendered without ever being shown**, which
  is the only way to check alignment from a machine that cannot open it: move
  `Window.Content` into a `Border`, carry `Window.Resources` across or every
  implicit style is lost, `Measure`/`Arrange`/`UpdateLayout`, then walk it
  with `VisualTreeHelper` and `TransformToAncestor`, or hand it to a
  `RenderTargetBitmap` and look at the PNG.
- **Every user-facing string lives in `Gui/Lang/<code>.xaml`,** one
  `ResourceDictionary` per language, all carrying the same keys. The window
  merges the chosen one into its resources and refers to each string with
  `{DynamicResource}`; swapping the merged dictionary re-resolves every one
  of them, so the window changes language where it stands, with nothing
  rebuilt and no reopening. `StaticResource` would not re-resolve, so never
  use it for a string. Two things the code owns instead of the markup and so
  must be refreshed by hand: the theme tooltip, which depends on which way
  the switch will go, and the monitor rows, whose text was copied into
  `DisplayRow` when the list was built.
- **The language dictionary is recognised by a key it must carry**
  (`S_Applying`) rather than by a reference kept in `$script:State`. That is
  what stops two dictionaries stacking up after a few switches, with no
  bookkeeping to keep in step.
- **The default language is `CurrentUICulture`, not `CurrentCulture`.** The
  first is the language Windows shows its own interface in, which is what the
  user actually reads; the second only decides how dates and numbers are
  written. An unknown one falls back to English, and the user's own choice is
  remembered in `gui-settings.json` from then on.
- German is written with Swiss spelling (`ss`, never `ß`), and English with
  British spelling, both deliberate for a Swiss school.
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

- **A local `$plan` IS the `$Plan` parameter.** Variable names are
  case-insensitive, so `Update-DisplayList`'s habitual `$plan = @()` emptied
  the argument it had just been handed, `if ($Plan)` was always false, and the
  plan was silently recomputed - picking a fresh random image every time. The
  local is `$entries` now. Watch for this wherever a parameter and a local
  read the same aloud.
- **`@($P).Count` throws under `Set-StrictMode -Version Latest` when `$P` is
  an unbound `[object[]]` parameter**, although `@($x).Count` on a plain
  `$null` variable is 1. Test `$null -ne $P` first and let it short-circuit,
  which is what `Set-Status` does.
- **`if ($Arg)` is false for `@(0)`.** A single-element array is evaluated as
  its element, so a count of zero skipped the `[string]::Format` and the user
  was shown a literal `{0}`. Use `$Arg.Count -gt 0`.
- **The image folder is committed in `Set-RootFolder`, nowhere else.** It used
  to live in `TxtRoot`'s `LostFocus` alone, which the Browse button cannot
  reach: clicking it moves focus away *before* the dialog opens, so LostFocus
  fired with the old text and nothing fired again afterwards. Enter on the
  text box is the same story, since `IsDefault` raises Apply without moving
  focus.
- **`Invoke-ApplyNow` wraps everything in `try/finally`.** Its early return on
  a missing folder used to skip the `finally` that re-enables the Apply
  button, which then stayed grey for the rest of the session.
- **The notifier gate stays open while a change is pending.** `Wait(0)` clears
  the event, so a change seen on one tick is gone by the next and the debounce
  could never reach its second tick; the list only refreshed on the 15 s
  fallback, which defeated the point of listening for `WM_DISPLAYCHANGE`.
- **`Invoke-Deferred` carries its body on the timer's `Tag`.** One shared slot
  in `$script:State` meant two deferrals queued inside the same 30 ms window
  dropped the first and ran the second twice.
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
  backgrounds under `wallpapers/` and the icon under `assets/`;
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
6. ~~`-WhatIf` support on `Set-WallpapersNow`.~~ Done, and on
   `Set-MonitorWallpaper`, `Set-WallpaperAssignment` and
   `Remove-WallpaperAssignment` with it. `Set-WallpapersNow` owns the
   interaction and passes `-Confirm:$false` inward so the inner function does
   not ask the same question twice; under `-WhatIf` it still returns the whole
   plan with `Applied` false, so it doubles as "show me what you would do".
   `Write-Log` passes `-WhatIf:$false` to its file cmdlets, or a preview
   announced every line it was not writing to the log. `Start-WallpaperWatch`
   and the window's private helpers carry a `SuppressMessageAttribute`
   instead, with the reason written where it applies.
7. Publish to PowerShell Gallery. The module folder name already matches
   the module name, so `Publish-Module -Path ./screen4screen` works.
8. CI: PSScriptAnalyzer + Pester on `windows-latest`.
   `PSScriptAnalyzerSettings.psd1` is in place and the tree is clean: run
   `Invoke-ScriptAnalyzer -Path . -Recurse -Settings
   .\PSScriptAnalyzerSettings.psd1` and expect nothing back. Only rules this
   repository breaks on purpose are excluded there; everything else is
   suppressed where it sits, with a reason.

## Testing on a real machine

```powershell
.\screen4screen.ps1 -Once -Verbose
```

prints the detected monitors with their native resolutions and which file
was picked for each. Check `%LOCALAPPDATA%\screen4screen\log.txt`
for the background task.

## Commit messages

Plain imperative subject line, no tool attribution or trailers.
