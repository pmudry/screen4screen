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

    Naming convention inside -WallpaperRoot, in decreasing priority for a
    1920x1200 monitor:

        1920x1200.jpg          file for this exact resolution
        1920x1200\             folder: a random image from it
        ratio-8x5.jpg          file for this (reduced) aspect ratio
        ratio-8x5\             folder: a random image from it
        default.jpg            fallback

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

.PARAMETER Once
    Apply once and exit. Handy for testing.

.PARAMETER Install
    Registers a scheduled task "WallpaperByResolution" that runs this
    script in the background at every logon.

.PARAMETER Uninstall
    Removes the scheduled task.

.PARAMETER PollSeconds
    Polling interval for the display configuration. Default: 3.

.PARAMETER SettleDelay
    Delay after a change is detected, giving Windows time to settle the new
    layout. Default: 2 seconds.

.EXAMPLE
    # Test: show what is detected and apply once
    .\Set-WallpaperByResolution.ps1 -Once -Verbose

.EXAMPLE
    # Install as a permanent background task
    .\Set-WallpaperByResolution.ps1 -Install -WallpaperRoot 'D:\Wallpapers'

.NOTES
    Turn off Windows Spotlight / the wallpaper slideshow in
    Settings > Personalization first, otherwise Windows keeps putting its
    own images back.
#>

[CmdletBinding()]
param(
    [string] $WallpaperRoot = (Join-Path $env:USERPROFILE 'Pictures\Wallpapers'),

    [ValidateSet('Center', 'Tile', 'Stretch', 'Fit', 'Fill', 'Span')]
    [string] $Position = 'Fill',

    [switch] $Once,
    [switch] $Install,
    [switch] $Uninstall,

    [ValidateRange(1, 300)]
    [int] $PollSeconds = 3,

    [ValidateRange(0, 30)]
    [double] $SettleDelay = 2.0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$TaskName = 'WallpaperByResolution'
$LogDir   = Join-Path $env:LOCALAPPDATA 'WallpaperByResolution'
$LogFile  = Join-Path $LogDir 'log.txt'


#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')

    $line = '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Warning $Message }
        default { Write-Verbose $line }
    }

    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        # crude rotation: truncate beyond 512 KB
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 512KB)) {
            $keep = Get-Content -LiteralPath $LogFile -Tail 500
            Set-Content -LiteralPath $LogFile -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch { }   # logging must never break the script
}


#------------------------------------------------------------------------------
# Win32 / COM interop
#------------------------------------------------------------------------------

if (-not ('WallByRes.Native' -as [type])) {

    $cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WallByRes
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int   dmFields;
        public int   dmPositionX;
        public int   dmPositionY;
        public int   dmDisplayOrientation;
        public int   dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int   dmBitsPerPel;
        public int   dmPelsWidth;
        public int   dmPelsHeight;
        public int   dmDisplayFlags;
        public int   dmDisplayFrequency;
        public int   dmICMMethod;
        public int   dmICMIntent;
        public int   dmMediaType;
        public int   dmDitherType;
        public int   dmReserved1;
        public int   dmReserved2;
        public int   dmPanningWidth;
        public int   dmPanningHeight;
    }

    public static class Native
    {
        public const int  ENUM_CURRENT_SETTINGS         = -1;
        public const uint EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001;
        public const int  DISPLAY_DEVICE_ATTACHED       = 0x00000001;
        public const int  DISPLAY_DEVICE_PRIMARY        = 0x00000004;
        public const int  DISPLAY_DEVICE_MIRRORING      = 0x00000008;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevices(
            string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplaySettings(
            string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);
    }

    // IDesktopWallpaper : shobjidl_core.h  (Windows 8 and later)
    [ComImport]
    [Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    [CoClass(typeof(DesktopWallpaperClass))]
    public interface IDesktopWallpaper
    {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID,
                          [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);

        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);

        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetMonitorDevicePathAt(uint monitorIndex);

        uint GetMonitorDevicePathCount();

        RECT GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);

        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();

        void SetPosition(int position);
        int  GetPosition();

        void   SetSlideshow(IntPtr items);
        IntPtr GetSlideshow();

        void SetSlideshowOptions(int options, uint slideshowTick);
        void GetSlideshowOptions(out int options, out uint slideshowTick);

        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);

        int GetStatus();

        [return: MarshalAs(UnmanagedType.Bool)]
        bool Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }

    [ComImport]
    [Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")]
    [ClassInterface(ClassInterfaceType.None)]
    public class DesktopWallpaperClass { }

    // Every IDesktopWallpaper call goes through here. PowerShell cannot call
    // the interface itself: the object comes back as System.__ComObject and,
    // the interface being IUnknown-only with no IDispatch, PowerShell finds
    // no methods on it. Keeping the calls on this side also keeps the COM
    // lifetime contained.
    public static class Wallpaper
    {
        private static IDesktopWallpaper Create()
        {
            Type t = Type.GetTypeFromCLSID(
                         new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD"));
            return (IDesktopWallpaper) Activator.CreateInstance(t);
        }

        // Monitor interface paths Windows currently knows about. The list
        // includes monitors that are no longer connected, so callers match
        // on path rather than on index.
        public static string[] GetMonitorPaths()
        {
            IDesktopWallpaper w = Create();
            try
            {
                List<string> paths = new List<string>();
                uint n = w.GetMonitorDevicePathCount();
                for (uint i = 0; i < n; i++)
                {
                    string path = w.GetMonitorDevicePathAt(i);
                    if (!String.IsNullOrEmpty(path)) { paths.Add(path); }
                }
                return paths.ToArray();
            }
            finally { Marshal.ReleaseComObject(w); }
        }

        // A null monitorId applies the image to every monitor.
        public static void Apply(string monitorId, string imagePath, int position)
        {
            IDesktopWallpaper w = Create();
            try
            {
                w.SetPosition(position);
                w.SetWallpaper(monitorId, imagePath);
            }
            finally { Marshal.ReleaseComObject(w); }
        }
    }
}
'@

    Add-Type -TypeDefinition $cs -Language CSharp
}

$PositionValue = @{
    Center = 0; Tile = 1; Stretch = 2; Fit = 3; Fill = 4; Span = 5
}


#------------------------------------------------------------------------------
# Enumerate the monitors actually attached to the desktop
#------------------------------------------------------------------------------

function Get-AttachedDisplay {
    [CmdletBinding()]
    param()

    $displays = @()
    $index    = 0

    while ($true) {
        $adapter    = New-Object WallByRes.DISPLAY_DEVICE
        $adapter.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($adapter)

        # [NullString]::Value, never $null: PowerShell binds $null to a [string]
        # parameter as the empty string, and EnumDisplayDevices("") fails where
        # EnumDisplayDevices(NULL) enumerates the adapters.
        if (-not [WallByRes.Native]::EnumDisplayDevices(
                     [NullString]::Value, $index, [ref] $adapter, 0)) { break }
        $index++

        if (-not ($adapter.StateFlags -band [WallByRes.Native]::DISPLAY_DEVICE_ATTACHED)) { continue }
        if ($adapter.StateFlags -band [WallByRes.Native]::DISPLAY_DEVICE_MIRRORING)        { continue }

        # The monitor's device interface path is the key that matches
        # IDesktopWallpaper's monitor IDs. EDD_GET_DEVICE_INTERFACE_NAME
        # returns it in DeviceID.
        $monitor    = New-Object WallByRes.DISPLAY_DEVICE
        $monitor.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($monitor)
        $hasMonitor = [WallByRes.Native]::EnumDisplayDevices(
                          $adapter.DeviceName, 0, [ref] $monitor,
                          [WallByRes.Native]::EDD_GET_DEVICE_INTERFACE_NAME)

        # Native resolution in real pixels: immune to DPI scaling.
        $mode        = New-Object WallByRes.DEVMODE
        $mode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mode)

        if (-not [WallByRes.Native]::EnumDisplaySettings(
                     $adapter.DeviceName,
                     [WallByRes.Native]::ENUM_CURRENT_SETTINGS,
                     [ref] $mode)) { continue }

        $displays += [pscustomobject]@{
            Adapter    = $adapter.DeviceName
            DevicePath = if ($hasMonitor) { $monitor.DeviceID } else { $null }
            Friendly   = if ($hasMonitor) { $monitor.DeviceString } else { $adapter.DeviceString }
            Width      = $mode.dmPelsWidth
            Height     = $mode.dmPelsHeight
            IsPrimary  = [bool]($adapter.StateFlags -band [WallByRes.Native]::DISPLAY_DEVICE_PRIMARY)
        }
    }

    return $displays
}


#------------------------------------------------------------------------------
# Image selection
#------------------------------------------------------------------------------

function Get-Gcd {
    param([int] $A, [int] $B)
    while ($B -ne 0) { $t = $B; $B = $A % $B; $A = $t }
    return [Math]::Abs($A)
}

function Resolve-WallpaperFile {
    [CmdletBinding()]
    param(
        [int]    $Width,
        [int]    $Height,
        [string] $Root
    )

    $extensions = @('.jpg', '.jpeg', '.png', '.bmp', '.webp')

    $gcd   = Get-Gcd $Width $Height
    if ($gcd -eq 0) { $gcd = 1 }
    $ratio = 'ratio-{0}x{1}' -f ($Width / $gcd), ($Height / $gcd)

    $candidates = @(('{0}x{1}' -f $Width, $Height), $ratio, 'default')

    foreach ($name in $candidates) {

        # 1. a folder of that name: pick a random image inside it
        $dir = Join-Path $Root $name
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $pick = Get-ChildItem -LiteralPath $dir -File |
                    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                    Get-Random
            if ($pick) { return $pick.FullName }
        }

        # 2. a file of that name
        foreach ($ext in $extensions) {
            $file = Join-Path $Root ($name + $ext)
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                return (Get-Item -LiteralPath $file).FullName
            }
        }
    }

    return $null
}


#------------------------------------------------------------------------------
# Apply wallpapers
#------------------------------------------------------------------------------

function Set-WallpapersNow {
    [CmdletBinding()]
    param(
        [string] $Root,
        [string] $PositionName
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Write-Log "Wallpaper folder not found: $Root" 'ERROR'
        return
    }

    $displays = @(Get-AttachedDisplay)
    if ($displays.Count -eq 0) {
        Write-Log 'No attached display detected.' 'WARN'
        return
    }

    $position = $PositionValue[$PositionName]

    # Monitor paths known to Windows, used for matching
    $known = @()
    try   { $known = @([WallByRes.Wallpaper]::GetMonitorPaths()) }
    catch { Write-Log "IDesktopWallpaper enumeration failed: $($_.Exception.Message)" 'WARN' }

    $applied = 0

    foreach ($d in $displays) {

        $image = Resolve-WallpaperFile -Width $d.Width -Height $d.Height -Root $Root

        if (-not $image) {
            Write-Log ("No image for {0} ({1}x{2}) - no exact, ratio or default match." -f `
                       $d.Friendly, $d.Width, $d.Height) 'WARN'
            continue
        }

        # Match on device interface path, case-insensitive
        $target = $null
        if ($d.DevicePath) {
            $target = $known | Where-Object { $_ -ieq $d.DevicePath } | Select-Object -First 1
        }

        if (-not $target) {
            if ($displays.Count -eq 1) {
                # Single display: a NULL monitor ID means "all monitors".
                # Same trap as the adapter enumeration above: a plain $null
                # would reach COM as "" and the call would fail.
                $target = [NullString]::Value
                Write-Log ("Path match failed for {0}, applying globally." -f $d.Friendly) 'WARN'
            }
            else {
                Write-Log ("Monitor not found in IDesktopWallpaper, skipped: {0} [{1}]" -f `
                           $d.Friendly, $d.DevicePath) 'WARN'
                continue
            }
        }

        try {
            [WallByRes.Wallpaper]::Apply($target, $image, $position)
            $applied++
            Write-Log ("{0}  {1}x{2}  ->  {3}" -f $d.Friendly, $d.Width, $d.Height, (Split-Path $image -Leaf))
        }
        catch {
            Write-Log ("Failed on {0}: {1}" -f $d.Friendly, $_.Exception.Message) 'ERROR'
        }
    }

    Write-Log ("{0}/{1} monitor(s) handled." -f $applied, $displays.Count)
}


#------------------------------------------------------------------------------
# Display configuration signature
#------------------------------------------------------------------------------

function Get-DisplaySignature {
    $parts = Get-AttachedDisplay |
             ForEach-Object { '{0}|{1}x{2}' -f $_.DevicePath, $_.Width, $_.Height } |
             Sort-Object
    return ($parts -join ' ; ')
}


#------------------------------------------------------------------------------
# Scheduled task
#------------------------------------------------------------------------------

function Install-WallpaperTask {
    param([string] $Root, [string] $PositionName)

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { throw 'Cannot determine the script path.' }

    $hostExe = Join-Path $PSHOME 'powershell.exe'
    $argList = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass ' +
               ('-File "{0}" -WallpaperRoot "{1}" -Position {2}' -f $scriptPath, $Root, $PositionName)

    $action = New-ScheduledTaskAction -Execute $hostExe -Argument $argList

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

    $settings = New-ScheduledTaskSettingsSet `
                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable `
                    -MultipleInstances IgnoreNew `
                    -ExecutionTimeLimit ([TimeSpan]::Zero)

    $principal = New-ScheduledTaskPrincipal `
                     -UserId "$env:USERDOMAIN\$env:USERNAME" `
                     -LogonType Interactive `
                     -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName `
                           -Action $action `
                           -Trigger $trigger `
                           -Settings $settings `
                           -Principal $principal `
                           -Description 'Per-monitor wallpaper chosen from the monitor resolution.' `
                           -Force | Out-Null

    Write-Host "Task '$TaskName' registered." -ForegroundColor Green
    Write-Host "Images  : $Root"
    Write-Host "Log     : $LogFile"
    Write-Host ''
    Write-Host 'Start it now with:' -ForegroundColor Cyan
    Write-Host "  Start-ScheduledTask -TaskName $TaskName"
}

function Uninstall-WallpaperTask {
    Stop-ScheduledTask       -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Host "Task '$TaskName' removed." -ForegroundColor Green
}


#------------------------------------------------------------------------------
# Entry point
#------------------------------------------------------------------------------

if ($Uninstall) {
    Uninstall-WallpaperTask
    return
}

if ($Install) {
    if (-not (Test-Path -LiteralPath $WallpaperRoot -PathType Container)) {
        Write-Warning "Folder $WallpaperRoot does not exist yet; create it before the first run."
    }
    Install-WallpaperTask -Root $WallpaperRoot -PositionName $Position
    return
}

if ($Once) {
    $VerbosePreference = 'Continue'

    Write-Host 'Detected displays:' -ForegroundColor Cyan
    Get-AttachedDisplay |
        Format-Table Friendly,
                     @{ N = 'Resolution'; E = { '{0}x{1}' -f $_.Width, $_.Height } },
                     IsPrimary,
                     Adapter -AutoSize

    Set-WallpapersNow -Root $WallpaperRoot -PositionName $Position
    return
}

# --- watch mode -----------------------------------------------------------

Write-Log "Starting. Images: $WallpaperRoot | Position: $Position | Poll: ${PollSeconds}s"

$lastSignature = $null

while ($true) {
    try {
        $signature = Get-DisplaySignature

        if ($signature -ne $lastSignature) {

            if ($null -ne $lastSignature) {
                Write-Log 'Display configuration change detected.'
            }

            # Let Windows finish rearranging the desktop.
            Start-Sleep -Seconds $SettleDelay
            $signature = Get-DisplaySignature

            Set-WallpapersNow -Root $WallpaperRoot -PositionName $Position

            # Windows often restores its own cached wallpaper right after a
            # display change; a second pass takes it back.
            Start-Sleep -Seconds 3
            Set-WallpapersNow -Root $WallpaperRoot -PositionName $Position

            $lastSignature = $signature
        }
    }
    catch {
        Write-Log ("Loop: {0}" -f $_.Exception.Message) 'ERROR'
        Start-Sleep -Seconds 10
    }

    Start-Sleep -Seconds $PollSeconds
}
