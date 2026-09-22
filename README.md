# wallpaper-by-resolution

Per-monitor wallpapers on Windows, chosen from each monitor's **native resolution**, re-applied automatically when you dock, undock or plug in an external display.

Built for the usual laptop setup: a 1920x1200 panel, a 5120x2160 ultrawide at the desk, the odd 1920x1080 projector in a meeting room. Each one gets an image that was actually made for its aspect ratio instead of a cropped or stretched compromise.

No dependencies. One PowerShell script, Windows 8 or later.

## How it works

1. Attached monitors are enumerated with `EnumDisplayDevices` and their native mode is read with `EnumDisplaySettings(ENUM_CURRENT_SETTINGS)`. This yields real pixels, unaffected by DPI scaling (a 5120x2160 display at 150 % reports 5120x2160, not 3413x1440).
2. Each monitor is matched to its `IDesktopWallpaper` entry by device interface path.
3. An image is picked by naming convention (below) and applied per monitor through `IDesktopWallpaper::SetWallpaper`.
4. A lightweight loop polls the display topology every few seconds and re-applies on change, with a short settle delay and a second pass, because Windows likes to restore its own cached wallpaper right after a topology change.

## Image naming

Put your images in one folder (default `%USERPROFILE%\Pictures\Wallpapers`). For a given monitor the script tries, in order:

| Priority | Name                    | Meaning                                      |
|----------|-------------------------|----------------------------------------------|
| 1        | `1920x1200.jpg`         | exact resolution                             |
| 2        | `1920x1200\`            | folder: random image from it                 |
| 3        | `ratio-8x5.jpg`         | reduced aspect ratio                         |
| 4        | `ratio-8x5\`            | folder: random image from it                 |
| 5        | `default.jpg`           | fallback                                     |

Extensions: `.jpg`, `.jpeg`, `.png`, `.bmp`, `.webp`.

Reduced ratios for common panels:

| Resolution | Ratio name    |
|------------|---------------|
| 1920x1200  | `ratio-8x5`   |
| 1920x1080  | `ratio-16x9`  |
| 2560x1440  | `ratio-16x9`  |
| 3840x2160  | `ratio-16x9`  |
| 3440x1440  | `ratio-43x18` |
| 5120x2160  | `ratio-64x27` |

## Usage

Test first. This prints what is detected and applies once:

```powershell
.\Set-WallpaperByResolution.ps1 -Once -Verbose
```

Install as a background task that starts at logon:

```powershell
.\Set-WallpaperByResolution.ps1 -Install -WallpaperRoot 'D:\Wallpapers' -Position Fill
Start-ScheduledTask -TaskName WallpaperByResolution
```

Remove it:

```powershell
.\Set-WallpaperByResolution.ps1 -Uninstall
```

Parameters:

| Parameter        | Default                            | Notes                                            |
|------------------|------------------------------------|--------------------------------------------------|
| `-WallpaperRoot` | `%USERPROFILE%\Pictures\Wallpapers`| image folder                                     |
| `-Position`      | `Fill`                             | `Center`, `Tile`, `Stretch`, `Fit`, `Fill`, `Span` |
| `-PollSeconds`   | `3`                                | topology polling interval                        |
| `-SettleDelay`   | `2`                                | seconds to wait after a change before applying   |
| `-Once`          |                                    | apply once and exit                              |
| `-Install`       |                                    | register the logon task                          |
| `-Uninstall`     |                                    | remove the logon task                            |

Log file: `%LOCALAPPDATA%\WallpaperByResolution\log.txt`.

## Before you start

Disable Windows Spotlight and the wallpaper slideshow in *Settings > Personalization > Background*. Both will fight the script.

If `powershell.exe` refuses to run the script, the scheduled task already passes `-ExecutionPolicy Bypass`; for a manual run use:

```powershell
powershell -ExecutionPolicy Bypass -File .\Set-WallpaperByResolution.ps1 -Once
```

## Known limitations

- Polling, not event-driven. Reaction time is `PollSeconds + SettleDelay`, a few seconds. `WM_DISPLAYCHANGE` would be instant but needs a message pump, which a headless PowerShell process does not have without extra machinery.
- The `-Position` mode is global; Windows does not expose per-monitor fit.
- `powershell.exe -WindowStyle Hidden` may flash a console window for a fraction of a second at logon. A `.vbs` or `conhost --headless` launcher avoids it; see roadmap.

## Roadmap

See [CLAUDE.md](CLAUDE.md) for the working notes and the list of planned improvements.

## License

MIT, see [LICENSE](LICENSE).
