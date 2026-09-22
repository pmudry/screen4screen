<#
.SYNOPSIS
    Sets a different desktop wallpaper on each monitor, chosen from the
    monitor's native resolution. Reacts automatically to docking, undocking
    and plugging in external displays.

.DESCRIPTION
    Each physical monitor is identified by its device interface path. Its
    NATIVE resolution is read through EnumDisplaySettings(ENUM_CURRENT_SETTINGS),
    i.e. in real pixels and independently of DPI scaling. The wallpaper is
    then applied per monitor through the IDesktopWallpaper COM interface
    (Windows 8 and later).

    This file is a thin command-line wrapper. The logic lives in the
    Screen4Screen module next to it.

    Naming convention inside -WallpaperRoot, in decreasing priority for a
    1920x1200 monitor. For each name a FOLDER is tried before a FILE:

        1920x1200\             folder: a random image from it
        1920x1200.jpg          file for this exact resolution
        ratio-8x5\             folder: a random image from it
        ratio-8x5.jpg          file for this (reduced) aspect ratio
        default\               folder: a random image from it
        default.jpg            fallback

    A monitor may also be pinned to one image explicitly, which wins over all
    of the above. Those choices live in wallpapers.json at the root of
    -WallpaperRoot and are easiest to set from the graphical manager.

    Recognised extensions: .jpg .jpeg .png .bmp .webp

    Useful reduced aspect ratios:
        1920x1200 -> ratio-8x5
        1920x1080 -> ratio-16x9
        3840x2160 -> ratio-16x9
        5120x2160 -> ratio-64x27
        3440x1440 -> ratio-43x18

.PARAMETER WallpaperRoot
    Folder holding the images. Default: %USERPROFILE%\Pictures\Wallpapers

.PARAMETER Position
    Global fit mode: Center, Tile, Stretch, Fit, Fill, Span. Default: Fill.

.PARAMETER Gui
    Opens the graphical manager instead of applying anything.

.PARAMETER Once
    Apply once and exit. Handy for testing.

.PARAMETER Install
    Registers a scheduled task "screen4screen" that runs this
    script in the background at every logon.

.PARAMETER Uninstall
    Removes the scheduled task.

.PARAMETER PollSeconds
    Fallback interval for re-checking the displays. Changes are normally
    picked up instantly from the WM_DISPLAYCHANGE message, so this only
    matters if that mechanism is unavailable. Default: 15.

.PARAMETER SettleDelay
    Delay after a change is detected, giving Windows time to settle the new
    layout. Default: 2 seconds.

.EXAMPLE
    # Test: show what is detected and apply once
    .\screen4screen.ps1 -Once -Verbose

.EXAMPLE
    # Install as a permanent background task
    .\screen4screen.ps1 -Install -WallpaperRoot 'D:\Wallpapers'

.NOTES
    Turn off Windows Spotlight / the wallpaper slideshow in
    Settings > Personalization first, otherwise Windows keeps putting its
    own images back.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $WallpaperRoot = (Join-Path $env:USERPROFILE 'Pictures\Wallpapers'),

    [ValidateSet('Center', 'Tile', 'Stretch', 'Fit', 'Fill', 'Span')]
    [string] $Position = 'Fill',

    [switch] $Gui,
    [switch] $Once,
    [switch] $Install,
    [switch] $Uninstall,

    [ValidateRange(1, 300)]
    [int] $PollSeconds = 15,

    [ValidateRange(0, 30)]
    [double] $SettleDelay = 2.0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manifest = Join-Path $PSScriptRoot 'Screen4Screen\Screen4Screen.psd1'
if (Test-Path -LiteralPath $manifest) {
    Import-Module $manifest -Force -ErrorAction Stop -Verbose:$false
}
else {
    # Installed from the gallery rather than run from a clone.
    Import-Module Screen4Screen -ErrorAction Stop -Verbose:$false
}


#------------------------------------------------------------------------------
# Entry point
#------------------------------------------------------------------------------

if ($Gui) {
    & (Join-Path $PSScriptRoot 'Gui\Show-Screen4ScreenGui.ps1')
    return
}

if ($Uninstall) {
    Uninstall-WallpaperTask -Verbose
    return
}

if ($Install) {
    if (-not (Test-Path -LiteralPath $WallpaperRoot -PathType Container)) {
        Write-Warning "Folder $WallpaperRoot does not exist yet; create it before the first run."
    }

    # The module cannot be launched directly by the scheduled task, so it is
    # told explicitly which script to run: this one.
    Install-WallpaperTask -Root $WallpaperRoot `
                          -PositionName $Position `
                          -LauncherPath $PSCommandPath

    Write-Host "Task 'screen4screen' registered." -ForegroundColor Green
    Write-Host "Images  : $WallpaperRoot"
    Write-Host ("Log     : {0}" -f (Get-WallpaperLogPath))
    Write-Host ''
    Write-Host 'Start it now with:' -ForegroundColor Cyan
    Write-Host '  Start-ScheduledTask -TaskName screen4screen'
    return
}

if ($Once) {
    Write-Host 'Detected displays:' -ForegroundColor Cyan
    Get-AttachedDisplay |
        Format-Table Friendly,
                     @{ N = 'Resolution'; E = { '{0}x{1}' -f $_.Width, $_.Height } },
                     IsPrimary,
                     Adapter -AutoSize

    # -Verbose explicitly: preference variables set here do not reach the
    # module's own scope, so the per-monitor log lines would otherwise be
    # swallowed.
    Set-WallpapersNow -Root $WallpaperRoot -PositionName $Position -Verbose | Out-Null
    return
}

# --- watch mode -----------------------------------------------------------

Start-WallpaperWatch -Root $WallpaperRoot `
                     -PositionName $Position `
                     -PollSeconds $PollSeconds `
                     -SettleDelay $SettleDelay `
                     -Verbose:($VerbosePreference -eq 'Continue')
