<#
    screen4screen

    Per-monitor Windows wallpapers, chosen from each monitor's native
    resolution. See the repository README for the naming convention and
    CLAUDE.md for the design decisions behind the interop layer.

    ASCII only in this file. The embedded C# must stay C# 5 compatible so it
    compiles under Windows PowerShell 5.1's built-in compiler.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest


#------------------------------------------------------------------------------
# Host and platform requirements
#------------------------------------------------------------------------------

# Checked here rather than left to fail somewhere in the interop layer, since
# this ships to other machines. Windows PowerShell 5.1 and PowerShell 7 are
# both supported; 5.1 is what the scheduled task uses, because it is the one
# present on every Windows install.
if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw ("screen4screen needs Windows PowerShell 5.1 or PowerShell 7. This host is {0}." -f
           $PSVersionTable.PSVersion)
}

# $IsWindows only exists on PowerShell 6+, and reading it under StrictMode on
# 5.1 would throw, so the platform is read from the runtime instead.
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'screen4screen only runs on Windows.'
}

# IDesktopWallpaper is Windows 8 / Server 2012 and later (build 9200).
if ([System.Environment]::OSVersion.Version -lt [Version]'6.2') {
    throw ("screen4screen needs Windows 8 or later. This is Windows {0}." -f
           [System.Environment]::OSVersion.Version)
}


#------------------------------------------------------------------------------
# Module state
#------------------------------------------------------------------------------

$script:TaskName = 'screen4screen'

# $env:LOCALAPPDATA is null off Windows, and Join-Path would fail to bind at
# import time. The module must still import on Linux so the pure-PowerShell
# parts stay testable in CI.
$script:LogDir = if ($env:LOCALAPPDATA) {
                     Join-Path $env:LOCALAPPDATA 'screen4screen'
                 }
                 else {
                     Join-Path ([System.IO.Path]::GetTempPath()) 'screen4screen'
                 }

$script:LogFile        = Join-Path $script:LogDir 'log.txt'
$script:AssignmentFile = 'wallpapers.json'

# DESKTOP_WALLPAPER_POSITION
$script:PositionValue = @{
    Center = 0; Tile = 1; Stretch = 2; Fit = 3; Fill = 4; Span = 5
}

# Declaration order, for anything that needs to present the choices. The
# hashtable above is unordered, so never enumerate its keys for display.
$script:PositionOrder = @('Center', 'Tile', 'Stretch', 'Fit', 'Fill', 'Span')

$script:Extensions = @('.jpg', '.jpeg', '.png', '.bmp', '.webp')


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
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        # crude rotation: truncate beyond 512 KB
        if ((Test-Path -LiteralPath $script:LogFile) -and
            ((Get-Item -LiteralPath $script:LogFile).Length -gt 512KB)) {
            $keep = Get-Content -LiteralPath $script:LogFile -Tail 500
            Set-Content -LiteralPath $script:LogFile -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    catch { }   # logging must never break the caller
}


#------------------------------------------------------------------------------
# Win32 / COM interop
#------------------------------------------------------------------------------

function Initialize-NativeType {
    [CmdletBinding()]
    param()

    if ('WallByRes.Native' -as [type]) { return }

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

    // Signals when Windows reports a display change, so the watcher does not
    // have to re-enumerate the adapters every few seconds just to find out
    // nothing moved.
    //
    // This owns a real hidden top-level window and pumps it on its own thread.
    // Two reasons it is not built on Microsoft.Win32.SystemEvents: on the .NET
    // Framework that class listens on a message-only window, and message-only
    // windows never receive broadcasts such as WM_DISPLAYCHANGE, so nothing
    // ever fired from a headless Windows PowerShell host; and it is not part
    // of .NET Core at all.
    public class DisplayNotifier : IDisposable
    {
        private const int WM_DISPLAYCHANGE  = 0x007E;
        private const int WM_DESTROY        = 0x0002;
        private const int WS_EX_TOOLWINDOW  = 0x00000080;

        private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WNDCLASSEX
        {
            public uint   cbSize;
            public uint   style;
            public WndProcDelegate lpfnWndProc;
            public int    cbClsExtra;
            public int    cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
            public IntPtr hIconSm;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint   message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint   time;
            public int    ptX;
            public int    ptY;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ushort RegisterClassEx(ref WNDCLASSEX lpwcx);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowEx(
            int exStyle, string className, string windowName, int style,
            int x, int y, int width, int height,
            IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr DispatchMessage(ref MSG msg);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        private readonly System.Threading.ManualResetEvent _signal =
            new System.Threading.ManualResetEvent(false);
        private readonly System.Threading.ManualResetEvent _ready =
            new System.Threading.ManualResetEvent(false);

        // Kept in a field: if the delegate is collected the window procedure
        // becomes a dangling pointer and the process dies on the next message.
        private WndProcDelegate _proc;
        private System.Threading.Thread _thread;
        private IntPtr _hwnd;
        private bool _disposed;

        public DisplayNotifier()
        {
            _proc = new WndProcDelegate(WndProc);

            _thread = new System.Threading.Thread(new System.Threading.ThreadStart(Pump));
            _thread.IsBackground = true;
            _thread.Start();

            if (!_ready.WaitOne(5000))
            {
                throw new InvalidOperationException("The display notifier window did not start.");
            }
        }

        private void Pump()
        {
            string className = "screen4screen_display_" + Guid.NewGuid().ToString("N");

            WNDCLASSEX wc = new WNDCLASSEX();
            wc.cbSize        = (uint) Marshal.SizeOf(typeof(WNDCLASSEX));
            wc.lpfnWndProc   = _proc;
            wc.lpszClassName = className;

            if (RegisterClassEx(ref wc) == 0)
            {
                _ready.Set();
                return;
            }

            // A real top-level window, deliberately: HWND_MESSAGE windows are
            // excluded from broadcasts, and WM_DISPLAYCHANGE is a broadcast.
            // It is never shown, so it costs nothing on screen. WS_EX_TOOLWINDOW
            // keeps it out of Alt-Tab and the taskbar regardless, and the title
            // differs from the real window so lookups cannot confuse the two.
            _hwnd = CreateWindowEx(WS_EX_TOOLWINDOW, className,
                                   "screen4screen display sink", 0,
                                   0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

            _ready.Set();
            if (_hwnd == IntPtr.Zero) { return; }

            MSG msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                DispatchMessage(ref msg);
            }
        }

        private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            if (msg == WM_DISPLAYCHANGE) { _signal.Set(); }
            return DefWindowProc(hWnd, msg, wParam, lParam);
        }

        // Blocks up to timeoutMs. True means a change was signalled; the
        // signal is cleared either way so the next call starts fresh.
        public bool Wait(int timeoutMs)
        {
            bool signalled = _signal.WaitOne(timeoutMs);
            _signal.Reset();
            return signalled;
        }

        public bool Started { get { return _hwnd != IntPtr.Zero; } }

        public void Dispose()
        {
            if (_disposed) { return; }
            _disposed = true;

            if (_hwnd != IntPtr.Zero)
            {
                PostMessage(_hwnd, WM_DESTROY, IntPtr.Zero, IntPtr.Zero);
                DestroyWindow(_hwnd);
                _hwnd = IntPtr.Zero;
            }
        }
    }

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

    # Compiling this source at every start costs well over a second, which is
    # most of the window's launch time. Cache the built assembly next to the
    # log and load that instead. The file name carries a hash of the source,
    # so editing the C# above simply produces a new one.
    $dll = $null
    try {
        $sha  = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cs))
        $sha.Dispose()
        $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })

        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $dll = Join-Path $script:LogDir ('WallByRes-{0}.dll' -f $hash)
    }
    catch { $dll = $null }

    if ($dll -and (Test-Path -LiteralPath $dll -PathType Leaf)) {
        try {
            Add-Type -Path $dll -ErrorAction Stop
            return
        }
        catch { }   # stale or unreadable: fall through and rebuild
    }

    if ($dll) {
        try {
            Add-Type -TypeDefinition $cs -Language CSharp `
                     -OutputAssembly $dll -OutputType Library -ErrorAction Stop
            if (-not ('WallByRes.Native' -as [type])) { Add-Type -Path $dll }
            return
        }
        catch { }   # read-only profile, antivirus, whatever: compile in memory
    }

    Add-Type -TypeDefinition $cs -Language CSharp
}

Initialize-NativeType


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
# Manual assignments (wallpapers.json, stored in the image folder)
#------------------------------------------------------------------------------

function Get-AssignmentPath {
    param([string] $Root)
    return (Join-Path $Root $script:AssignmentFile)
}

function Resolve-AssignmentImage {
    # Assignment images are stored relative to the image folder when they live
    # inside it, absolute otherwise. Returns the absolute path, unverified.
    param([string] $Root, [string] $Image)

    if ([string]::IsNullOrWhiteSpace($Image)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Image)) { return $Image }
    return (Join-Path $Root $Image)
}

function Get-WallpaperAssignment {
    <#
    .SYNOPSIS
        Reads the manual per-monitor assignments from wallpapers.json.
    .DESCRIPTION
        Returns one object per saved assignment, including monitors that are
        not currently connected, so a caller can list them by name. A missing
        or unreadable file yields nothing and never throws: the watch loop
        must survive a hand-edited or half-synced file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Root)

    $path = Get-AssignmentPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }

    try {
        $raw  = Get-Content -LiteralPath $path -Raw
        $data = $raw | ConvertFrom-Json
    }
    catch {
        Write-Log ("Ignoring unreadable {0}: {1}" -f $script:AssignmentFile, $_.Exception.Message) 'WARN'
        return @()
    }

    if (-not $data) { return @() }
    if (-not ($data.PSObject.Properties.Name -contains 'assignments')) { return @() }

    $result = @()
    foreach ($a in @($data.assignments)) {
        if (-not $a) { continue }
        $names = $a.PSObject.Properties.Name
        if (-not ($names -contains 'devicePath')) { continue }
        if ([string]::IsNullOrWhiteSpace($a.devicePath)) { continue }

        $image = if ($names -contains 'image') { $a.image } else { $null }

        $result += [pscustomobject]@{
            DevicePath = $a.devicePath
            Friendly   = if ($names -contains 'friendly')   { $a.friendly }   else { $null }
            Resolution = if ($names -contains 'resolution') { $a.resolution } else { $null }
            LastSeen   = if ($names -contains 'lastSeen')   { $a.lastSeen }   else { $null }
            Image      = $image
            ImagePath  = Resolve-AssignmentImage -Root $Root -Image $image
        }
    }

    return $result
}

function Save-WallpaperAssignment {
    # Atomic write: the image folder may be synced by OneDrive, and a
    # half-written file there would be picked up by the watch loop.
    param([string] $Root, [object[]] $Assignment)

    $path = Get-AssignmentPath -Root $Root

    $payload = [pscustomobject]@{
        version     = 1
        assignments = @(
            foreach ($a in $Assignment) {
                [pscustomobject]@{
                    devicePath = $a.DevicePath
                    friendly   = $a.Friendly
                    resolution = $a.Resolution
                    lastSeen   = $a.LastSeen
                    image      = $a.Image
                }
            }
        )
    }

    $json = $payload | ConvertTo-Json -Depth 5
    $temp = '{0}.{1}.tmp' -f $path, [Guid]::NewGuid().ToString('N')

    # No BOM: a byte order mark upsets strict JSON parsers, and PowerShell
    # 5.1's -Encoding UTF8 always writes one.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $utf8)
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Set-WallpaperAssignment {
    <#
    .SYNOPSIS
        Pins an image to one monitor, overriding the resolution lookup.
    .DESCRIPTION
        Monitors are keyed on their device interface path, which is what tells
        two otherwise identical panels apart. Friendly, Resolution and LastSeen
        are stored for display only, so a disconnected monitor can still be
        listed by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $DevicePath,
        [Parameter(Mandatory = $true)][string] $Image,
        [string] $Friendly,
        [string] $Resolution
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Image folder not found: $Root"
    }

    # Store relative when the image lives inside the folder, so the folder
    # stays portable between machines.
    $stored   = $Image
    $fullRoot = (Get-Item -LiteralPath $Root).FullName
    if ([System.IO.Path]::IsPathRooted($Image)) {
        $prefix = $fullRoot.TrimEnd('\') + '\'
        if ($Image.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $stored = $Image.Substring($prefix.Length)
        }
    }

    $kept = @(Get-WallpaperAssignment -Root $Root |
              Where-Object { $_.DevicePath -ine $DevicePath })

    $kept += [pscustomobject]@{
        DevicePath = $DevicePath
        Friendly   = $Friendly
        Resolution = $Resolution
        LastSeen   = (Get-Date -Format 'yyyy-MM-dd')
        Image      = $stored
    }

    Save-WallpaperAssignment -Root $Root -Assignment $kept
    Write-Log ("Assignment saved: {0} -> {1}" -f $(if ($Friendly) { $Friendly } else { $DevicePath }), $stored)
}

function Remove-WallpaperAssignment {
    <#
    .SYNOPSIS
        Drops the manual assignment for one monitor, back to automatic choice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $DevicePath
    )

    $all  = @(Get-WallpaperAssignment -Root $Root)
    $kept = @($all | Where-Object { $_.DevicePath -ine $DevicePath })

    if ($kept.Count -eq $all.Count) { return }

    Save-WallpaperAssignment -Root $Root -Assignment $kept
    Write-Log ("Assignment removed for {0}" -f $DevicePath)
}


#------------------------------------------------------------------------------
# Image selection
#------------------------------------------------------------------------------

function Get-Gcd {
    param([int] $A, [int] $B)
    while ($B -ne 0) { $t = $B; $B = $A % $B; $A = $t }
    return [Math]::Abs($A)
}

function Resolve-WallpaperCandidate {
    # Returns the chosen path together with which candidate produced it, so
    # callers can explain the choice. Folder before file, for each candidate.
    param([int] $Width, [int] $Height, [string] $Root)

    $gcd = Get-Gcd $Width $Height
    if ($gcd -eq 0) { $gcd = 1 }

    $candidates = @(
        @{ Name = '{0}x{1}' -f $Width, $Height;                            Source = 'Exact'   }
        @{ Name = 'ratio-{0}x{1}' -f ($Width / $gcd), ($Height / $gcd);    Source = 'Ratio'   }
        @{ Name = 'default';                                               Source = 'Default' }
    )

    foreach ($c in $candidates) {

        # 1. a folder of that name: pick a random image inside it
        $dir = Join-Path $Root $c.Name
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $pick = Get-ChildItem -LiteralPath $dir -File |
                    Where-Object { $script:Extensions -contains $_.Extension.ToLowerInvariant() } |
                    Get-Random
            if ($pick) {
                return [pscustomobject]@{ Path = $pick.FullName; Source = $c.Source }
            }
        }

        # 2. a file of that name
        foreach ($ext in $script:Extensions) {
            $file = Join-Path $Root ($c.Name + $ext)
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                return [pscustomobject]@{ Path = (Get-Item -LiteralPath $file).FullName; Source = $c.Source }
            }
        }
    }

    return [pscustomobject]@{ Path = $null; Source = 'None' }
}

function Resolve-WallpaperFile {
    <#
    .SYNOPSIS
        Picks the image for a given resolution from the naming convention.
    .DESCRIPTION
        Tries, in order, the exact resolution, the reduced aspect ratio, then
        'default'. For each of those a FOLDER of that name is tried first (a
        random image from it), then a FILE of that name. Returns $null when
        nothing matches. Manual assignments are not consulted here; see
        Get-WallpaperPlan.
    #>
    [CmdletBinding()]
    param(
        [int]    $Width,
        [int]    $Height,
        [string] $Root
    )

    return (Resolve-WallpaperCandidate -Width $Width -Height $Height -Root $Root).Path
}


#------------------------------------------------------------------------------
# What would be applied
#------------------------------------------------------------------------------

function Get-WallpaperPlan {
    <#
    .SYNOPSIS
        Works out which image each attached monitor would get, without
        applying anything.
    .DESCRIPTION
        One object per attached monitor, carrying the monitor's identity, the
        chosen image, where that choice came from, and whether Windows knows
        the monitor well enough to target it individually. This is the single
        source of truth for the -Once table, the GUI and any future -WhatIf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root
    )

    $known = @()
    try   { $known = @([WallByRes.Wallpaper]::GetMonitorPaths()) }
    catch { Write-Log ("IDesktopWallpaper enumeration failed: {0}" -f $_.Exception.Message) 'WARN' }

    $assignments = @()
    if (Test-Path -LiteralPath $Root -PathType Container) {
        $assignments = @(Get-WallpaperAssignment -Root $Root)
    }

    $displays = @(Get-AttachedDisplay)

    foreach ($d in $displays) {

        $image  = $null
        $source = 'None'

        $pinned = $null
        if ($d.DevicePath) {
            $pinned = $assignments |
                      Where-Object { $_.DevicePath -ieq $d.DevicePath } |
                      Select-Object -First 1
        }

        if ($pinned -and $pinned.ImagePath -and
            (Test-Path -LiteralPath $pinned.ImagePath -PathType Leaf)) {
            $image  = (Get-Item -LiteralPath $pinned.ImagePath).FullName
            $source = 'Assignment'
        }
        else {
            if ($pinned) {
                Write-Log ("Assigned image missing for {0}, falling back: {1}" -f `
                           $d.Friendly, $pinned.Image) 'WARN'
            }
            if (Test-Path -LiteralPath $Root -PathType Container) {
                $chosen = Resolve-WallpaperCandidate -Width $d.Width -Height $d.Height -Root $Root
                $image  = $chosen.Path
                $source = $chosen.Source
            }
        }

        $target  = $null
        $matched = $false
        if ($d.DevicePath) {
            $target = $known | Where-Object { $_ -ieq $d.DevicePath } | Select-Object -First 1
            if ($target) { $matched = $true }
        }

        [pscustomobject]@{
            Adapter    = $d.Adapter
            DevicePath = $d.DevicePath
            Friendly   = $d.Friendly
            Width      = $d.Width
            Height     = $d.Height
            IsPrimary  = $d.IsPrimary
            Image      = $image
            Source     = $source
            Matched    = $matched
        }
    }
}


#------------------------------------------------------------------------------
# Apply wallpapers
#------------------------------------------------------------------------------

function Set-MonitorWallpaper {
    <#
    .SYNOPSIS
        Applies one image to one monitor, identified by its device path.
    .DESCRIPTION
        Pass an empty DevicePath to let Windows apply the image to every
        monitor, which is the only option when the monitor cannot be matched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $DevicePath,
        [Parameter(Mandatory = $true)][string] $Image,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Center', 'Tile', 'Stretch', 'Fit', 'Fill', 'Span')]
        [string] $PositionName
    )

    # A NULL monitor ID means "all monitors". Same trap as the adapter
    # enumeration: a plain $null would reach COM as "" and the call would fail.
    $target = [NullString]::Value
    if (-not [string]::IsNullOrEmpty($DevicePath)) { $target = $DevicePath }

    [WallByRes.Wallpaper]::Apply($target, $Image, $script:PositionValue[$PositionName])
}

function Set-WallpapersNow {
    <#
    .SYNOPSIS
        Applies the right wallpaper to every attached monitor.
    .DESCRIPTION
        Returns one result object per monitor, so a caller can report on the
        outcome instead of parsing the log.
    #>
    [CmdletBinding()]
    param(
        [string] $Root,
        [string] $PositionName
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Write-Log "Wallpaper folder not found: $Root" 'ERROR'
        return
    }

    $plan = @(Get-WallpaperPlan -Root $Root)
    if ($plan.Count -eq 0) {
        Write-Log 'No attached display detected.' 'WARN'
        return
    }

    $applied = 0

    foreach ($p in $plan) {

        $ok    = $false
        $error = $null

        if (-not $p.Image) {
            $error = 'no exact, ratio or default match'
            Write-Log ("No image for {0} ({1}x{2}) - {3}." -f `
                       $p.Friendly, $p.Width, $p.Height, $error) 'WARN'
        }
        elseif (-not $p.Matched -and $plan.Count -gt 1) {
            $error = 'monitor not found in IDesktopWallpaper'
            Write-Log ("Monitor not found in IDesktopWallpaper, skipped: {0} [{1}]" -f `
                       $p.Friendly, $p.DevicePath) 'WARN'
        }
        else {
            $devicePath = ''
            if ($p.Matched) {
                $devicePath = $p.DevicePath
            }
            else {
                Write-Log ("Path match failed for {0}, applying globally." -f $p.Friendly) 'WARN'
            }

            try {
                Set-MonitorWallpaper -DevicePath $devicePath -Image $p.Image -PositionName $PositionName
                $ok = $true
                $applied++
                Write-Log ("{0}  {1}x{2}  ->  {3}" -f `
                           $p.Friendly, $p.Width, $p.Height, (Split-Path $p.Image -Leaf))
            }
            catch {
                $error = $_.Exception.Message
                Write-Log ("Failed on {0}: {1}" -f $p.Friendly, $error) 'ERROR'
            }
        }

        [pscustomobject]@{
            Friendly   = $p.Friendly
            DevicePath = $p.DevicePath
            Width      = $p.Width
            Height     = $p.Height
            Image      = $p.Image
            Source     = $p.Source
            Applied    = $ok
            Error      = $error
        }
    }

    Write-Log ("{0}/{1} monitor(s) handled." -f $applied, $plan.Count)
}


#------------------------------------------------------------------------------
# Display configuration signature
#------------------------------------------------------------------------------

function Get-DisplaySignature {
    <#
    .SYNOPSIS
        A short string identifying the current display topology.
    #>
    [CmdletBinding()]
    param()

    $parts = Get-AttachedDisplay |
             ForEach-Object { '{0}|{1}x{2}' -f $_.DevicePath, $_.Width, $_.Height } |
             Sort-Object

    return ($parts -join ' ; ')
}


#------------------------------------------------------------------------------
# Watch mode
#------------------------------------------------------------------------------

function Start-WallpaperWatch {
    <#
    .SYNOPSIS
        Watches the display topology and re-applies on every change. Blocks.
    .DESCRIPTION
        Wakes on the WM_DISPLAYCHANGE message through DisplayNotifier, so a
        dock or undock is picked up at once. PollSeconds is only a ceiling on
        how long the wait may block, so the topology is still re-checked every
        so often even if no message arrives, and it becomes the sole trigger
        if the notifier window cannot be created.

        Two passes separated by a few seconds, because Windows restores its own
        transcoded wallpaper cache shortly after a topology change and the
        first pass is often overwritten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Center', 'Tile', 'Stretch', 'Fit', 'Fill', 'Span')]
        [string] $PositionName,
        [ValidateRange(1, 300)][int]    $PollSeconds = 15,
        [ValidateRange(0, 30)][double]  $SettleDelay = 2.0
    )

    # Event first, polling only as a safety net. Enumerating the adapters
    # costs about 50 ms, which is not free every few seconds on a laptop.
    $notifier = $null
    try   { $notifier = New-Object WallByRes.DisplayNotifier }
    catch { Write-Log "Display events unavailable, polling only: $($_.Exception.Message)" 'WARN' }

    Write-Log ("Starting. Images: {0} | Position: {1} | {2}" -f $Root, $PositionName,
               $(if ($notifier) { "event-driven, {0}s fallback poll" -f $PollSeconds }
                 else            { "polling every {0}s" -f $PollSeconds }))

    $lastSignature = $null

    try {
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

                    Set-WallpapersNow -Root $Root -PositionName $PositionName | Out-Null

                    # Windows often restores its own cached wallpaper right after a
                    # display change; a second pass takes it back.
                    Start-Sleep -Seconds 3
                    Set-WallpapersNow -Root $Root -PositionName $PositionName | Out-Null

                    $lastSignature = $signature
                }
            }
            catch {
                Write-Log ("Loop: {0}" -f $_.Exception.Message) 'ERROR'
                Start-Sleep -Seconds 10
            }

            # Wakes the instant Windows reports a change, and otherwise after the
            # fallback interval.
            if ($notifier) { [void] $notifier.Wait($PollSeconds * 1000) }
            else           { Start-Sleep -Seconds $PollSeconds }
        }
    }
    finally {
        if ($notifier) { $notifier.Dispose() }
    }
}


#------------------------------------------------------------------------------
# Scheduled task
#------------------------------------------------------------------------------

function Get-WallpaperTaskState {
    <#
    .SYNOPSIS
        Whether the logon task exists and whether it is currently running.
    .DESCRIPTION
        Uses the Task Scheduler COM API rather than Get-ScheduledTask. The CIM
        cmdlet costs around 700 ms on a normal machine and this is queried
        every time the window opens or the state changes, which was most of
        the launch time; the COM call costs around 40 ms. Get-ScheduledTask
        stays as a fallback for hosts where the COM service cannot be reached.
    #>
    [CmdletBinding()]
    param()

    $absent = [pscustomobject]@{ Installed = $false; Running = $false; State = 'NotInstalled' }

    $service = $null
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
    }
    catch { $service = $null }

    if ($service) {
        try {
            $task = $service.GetFolder('\').GetTask($script:TaskName)
        }
        catch {
            return $absent      # GetTask throws when it is simply not there
        }

        # TASK_STATE enumeration
        $value = [int] $task.State
        $name  = switch ($value) {
            0 { 'Unknown' }  1 { 'Disabled' } 2 { 'Queued' }
            3 { 'Ready' }    4 { 'Running' }  default { 'Unknown' }
        }

        return [pscustomobject]@{
            Installed = $true
            Running   = ($value -eq 4)
            State     = $name
        }
    }

    try {
        $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        return [pscustomobject]@{
            Installed = $true
            Running   = ($task.State -eq 'Running')
            State     = [string] $task.State
        }
    }
    catch { return $absent }
}

function Install-WallpaperTask {
    <#
    .SYNOPSIS
        Registers the logon task that keeps the wallpapers up to date.
    .PARAMETER LauncherPath
        The .ps1 the task must run. Defaults to the CLI wrapper shipped
        alongside this module; the module itself cannot be launched directly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Center', 'Tile', 'Stretch', 'Fit', 'Fill', 'Span')]
        [string] $PositionName,
        [string] $LauncherPath
    )

    if (-not $LauncherPath) {
        $LauncherPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'screen4screen.ps1'
    }

    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw ("Launcher script not found: {0}. Pass -LauncherPath explicitly." -f $LauncherPath)
    }

    $LauncherPath = (Get-Item -LiteralPath $LauncherPath).FullName

    # Windows PowerShell, deliberately: the task must not depend on PS 7 being
    # installed. -ExecutionPolicy Bypass because the machine policy may be
    # AllSigned and this script is not signed.
    $hostExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe -PathType Leaf)) {
        $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $psArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass ' +
              ('-File "{0}" -WallpaperRoot "{1}" -Position {2}' -f $LauncherPath, $Root, $PositionName)

    # -WindowStyle Hidden still creates the console and only then hides it,
    # which flashes a black window at every logon and every time the task is
    # started. conhost --headless never creates one. It arrived in Windows 11
    # 22H2; older builds keep the flash rather than route through Windows
    # Script Host, which is disabled on many managed machines.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'

    if (([System.Environment]::OSVersion.Version.Build -ge 22621) -and
        (Test-Path -LiteralPath $conhost -PathType Leaf)) {
        $execute  = $conhost
        $argument = '--headless "{0}" {1}' -f $hostExe, $psArgs
    }
    else {
        $execute  = $hostExe
        $argument = $psArgs
    }

    $action = New-ScheduledTaskAction -Execute $execute -Argument $argument

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

    # The tool registered its task as WallpaperByResolution before it was
    # renamed. Drop a leftover from that name, or both would run and fight
    # over the wallpaper.
    $legacy = 'WallpaperByResolution'
    if (Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask       -TaskName $legacy -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $legacy -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log ("Removed the task left behind by the previous name: {0}" -f $legacy) 'WARN'
    }

    Register-ScheduledTask -TaskName $script:TaskName `
                           -Action $action `
                           -Trigger $trigger `
                           -Settings $settings `
                           -Principal $principal `
                           -Description 'Per-monitor wallpaper chosen from the monitor resolution.' `
                           -Force | Out-Null

    Write-Log ("Task '{0}' registered for {1}" -f $script:TaskName, $LauncherPath)
}

function Uninstall-WallpaperTask {
    <#
    .SYNOPSIS
        Removes the logon task. Does nothing if it is not installed.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-WallpaperTaskState).Installed) {
        Write-Log ("Task '{0}' is not installed." -f $script:TaskName) 'WARN'
        return
    }

    Stop-ScheduledTask       -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
    Write-Log ("Task '{0}' removed." -f $script:TaskName)
}


#------------------------------------------------------------------------------
# Accessors used by the GUI
#------------------------------------------------------------------------------

function Get-WallpaperPosition {
    <#
    .SYNOPSIS
        The fit modes, in declaration order rather than hashtable order.
    #>
    [CmdletBinding()]
    param()
    return $script:PositionOrder
}

function Get-WallpaperLogPath {
    <#
    .SYNOPSIS
        Full path of the log file.
    #>
    [CmdletBinding()]
    param()
    return $script:LogFile
}


Export-ModuleMember -Function @(
    'Get-AttachedDisplay'
    'Get-DisplaySignature'
    'Get-WallpaperAssignment'
    'Get-WallpaperLogPath'
    'Get-WallpaperPlan'
    'Get-WallpaperPosition'
    'Get-WallpaperTaskState'
    'Install-WallpaperTask'
    'Remove-WallpaperAssignment'
    'Resolve-WallpaperFile'
    'Set-MonitorWallpaper'
    'Set-WallpaperAssignment'
    'Set-WallpapersNow'
    'Start-WallpaperWatch'
    'Uninstall-WallpaperTask'
) -Verbose:$false
