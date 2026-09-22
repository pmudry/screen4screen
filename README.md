# screen4screen

<img src="assets/screen4screen.png" width="96" align="right" alt="">

Per-monitor wallpapers on Windows, chosen from each monitor's **native resolution**, re-applied automatically when you dock, undock or plug in an external display.

Built for the usual laptop setup: a 1920x1200 panel, a 5120x2160 ultrawide at the desk, the odd 1920x1080 projector in a meeting room. Each one gets an image that was actually made for its aspect ratio instead of a cropped or stretched compromise.

No dependencies. PowerShell and Windows 8 or later, nothing else to install.

## How it works

1. Attached monitors are enumerated with `EnumDisplayDevices` and their native mode is read with `EnumDisplaySettings(ENUM_CURRENT_SETTINGS)`. This yields real pixels, unaffected by DPI scaling (a 5120x2160 display at 150 % reports 5120x2160, not 3413x1440).
2. Each monitor is matched to its `IDesktopWallpaper` entry by device interface path.
3. An image is picked by naming convention (below) and applied per monitor through `IDesktopWallpaper::SetWallpaper`.
4. A hidden window listens for `WM_DISPLAYCHANGE`, so docking or undocking is picked up at once; a slow poll (`-PollSeconds`, default 15) is only a fallback for when that window cannot be created. Either way the change is followed by a short settle delay and then two passes, because Windows likes to restore its own cached wallpaper right after a topology change.

## Image naming

Put your images in one folder (default `%USERPROFILE%\Pictures\Wallpapers`). For a given monitor the script tries, in order. Note that for each name a **folder is tried before a file**:

| Priority | Name                    | Meaning                                      |
|----------|-------------------------|----------------------------------------------|
| 1        | `1920x1200\`            | folder: random image from it                 |
| 2        | `1920x1200.jpg`         | exact resolution                             |
| 3        | `ratio-8x5\`            | folder: random image from it                 |
| 4        | `ratio-8x5.jpg`         | reduced aspect ratio                         |
| 5        | `default\`              | folder: random image from it                 |
| 6        | `default.jpg`           | fallback                                     |

Extensions: `.jpg`, `.jpeg`, `.png`, `.bmp`, `.webp`.

### Pinning one image to one monitor

The table above keys off resolution, which cannot tell two identical panels apart. A monitor can instead be pinned to an explicit image, which wins over every row above. Those choices live in `wallpapers.json` at the root of your image folder, keyed on the monitor's device interface path:

```powershell
Import-Module .\Screen4Screen\Screen4Screen.psd1
$d = @(Get-AttachedDisplay)[0]
Set-WallpaperAssignment -Root 'D:\Wallpapers' -DevicePath $d.DevicePath -Image 'D:\Wallpapers\left.webp' -Friendly $d.Friendly
Remove-WallpaperAssignment -Root 'D:\Wallpapers' -DevicePath $d.DevicePath   # back to automatic
```

Assignments for monitors that are currently unplugged are kept, not discarded, and reconnect silently when the monitor comes back.

Reduced ratios for common panels:

| Resolution | Ratio name    |
|------------|---------------|
| 1920x1200  | `ratio-8x5`   |
| 1920x1080  | `ratio-16x9`  |
| 2560x1440  | `ratio-16x9`  |
| 3840x2160  | `ratio-16x9`  |
| 3440x1440  | `ratio-43x18` |
| 5120x2160  | `ratio-64x27` |

## The graphical manager

Build the launcher once, then double-click `screen4screen.exe`:

```powershell
.\build\Build-Launcher.ps1
```

It carries the program icon in Explorer and opens the window with no console at all. The compiler it uses ships with Windows, so nothing needs installing, and the `.exe` is not tracked in git. `screen4screen.cmd` works without the build step but shows a console window.

You can also run:

```powershell
.\screen4screen.ps1 -Gui
```

One window: pick the image folder and the fit mode, see every attached monitor with the image it will get, pin a different image to any one of them, and turn the automatic behaviour on or off with a single switch. It refreshes itself when you dock or undock.

It opens on `wallpapers` the first time, and takes its language and its light or dark appearance from Windows. It speaks French, English, German and Italian; the button showing the current code in the top right switches between them, and remembers your choice. The sun/crescent button in the top right switches between the two and remembers your choice; the `?` next to it explains exactly what the tool changes on your machine.

Turning the switch on registers the logon task through `conhost --headless`, so no console window flashes when it starts. Windows builds older than 22621 fall back to the plain host, where a brief flash remains.

The timing knobs (`-PollSeconds`, `-SettleDelay`) are deliberately not in the window; they stay on the command line.

## Usage

Test first. This prints what is detected and applies once:

```powershell
.\screen4screen.ps1 -Once -Verbose
```

Install as a background task that starts at logon:

```powershell
.\screen4screen.ps1 -Install -WallpaperRoot 'D:\Wallpapers' -Position Fill
Start-ScheduledTask -TaskName screen4screen
```

Remove it:

```powershell
.\screen4screen.ps1 -Uninstall
```

Parameters:

| Parameter        | Default                            | Notes                                            |
|------------------|------------------------------------|--------------------------------------------------|
| `-WallpaperRoot` | `wallpapers` next to the script    | image folder                                     |
| `-Position`      | `Fill`                             | `Center`, `Tile`, `Stretch`, `Fit`, `Fill`, `Span` |
| `-PollSeconds`   | `15`                               | fallback poll, used only when `WM_DISPLAYCHANGE` is unavailable |
| `-SettleDelay`   | `2`                                | seconds to wait after a change before applying   |
| `-Gui`           |                                    | open the graphical manager                       |
| `-Once`          |                                    | apply once and exit                              |
| `-Install`       |                                    | register the logon task                          |
| `-Uninstall`     |                                    | remove the logon task                            |

Log file: `%LOCALAPPDATA%\screen4screen\log.txt`.

The module's state-changing functions support `-WhatIf`, so you can see what
would be applied without touching anything:

```powershell
Import-Module .\Screen4Screen\Screen4Screen.psd1
Set-WallpapersNow -Root .\wallpapers -PositionName Fill -WhatIf
```

## Before you start

Disable Windows Spotlight and the wallpaper slideshow in *Settings > Personalization > Background*. Both will fight the script.

If `powershell.exe` refuses to run the script, the scheduled task already passes `-ExecutionPolicy Bypass`; for a manual run use:

```powershell
powershell -ExecutionPolicy Bypass -File .\screen4screen.ps1 -Once
```

## Known limitations

- Reaction is event-driven: a hidden window catches `WM_DISPLAYCHANGE` and the watcher wakes immediately, then waits `SettleDelay` for Windows to finish rearranging. `PollSeconds` (default 15) is only a fallback for the case where that window cannot be created.
- The `-Position` mode is global; Windows does not expose per-monitor fit.
- The logon task runs through `conhost --headless`, so nothing flashes at logon. Windows builds older than 22621 do not have it and fall back to the plain host, where a brief console flash remains.
- `-ExecutionPolicy Bypass` is a Process-scope setting, so it loses to an execution policy set by Group Policy. On a managed machine where that is in force the window will not start; it now says so rather than failing silently.

## Roadmap

See [CLAUDE.md](CLAUDE.md) for the working notes and the list of planned improvements.

## License

MIT, see [LICENSE](LICENSE).
