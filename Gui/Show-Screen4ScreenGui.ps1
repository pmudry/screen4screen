<#
.SYNOPSIS
    Graphical manager for screen4screen.

.DESCRIPTION
    A single window to pick the image folder, see what each monitor will get,
    pin an image to a monitor, and turn the automatic behaviour on or off.

    ASCII only in this file. Every user-facing string lives in MainWindow.xaml,
    which is UTF-8 and declares its own encoding, so the French text is safe
    there and this host stays readable under Windows PowerShell 5.1.

.NOTES
    Machine policy may be AllSigned, so launch through:
      powershell -ExecutionPolicy Bypass -File .\Gui\Show-Screen4ScreenGui.ps1
#>

#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# WPF needs a single-threaded apartment. Both shipped hosts are STA by
# default, but pwsh -MTA exists and would fail later with an opaque
# COMException instead of a sentence.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'This window needs an STA host. Start it with: powershell -STA -File ...'
}

# The taskbar groups windows by application id, which defaults to the host
# process, so the button showed the PowerShell icon however the window was
# painted. Claiming an id of our own makes it a separate app and the taskbar
# then uses the window icon. Must happen before any window exists.
if (-not ('WallByResGui.Shell' -as [type])) {
    Add-Type -Namespace WallByResGui -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string appId);
'@
}
try { [WallByResGui.Shell]::SetCurrentProcessExplicitAppUserModelID('mui.screen4screen') } catch { }

$moduleManifest = Join-Path (Split-Path $PSScriptRoot -Parent) `
                            'Screen4Screen\Screen4Screen.psd1'
Import-Module $moduleManifest -Force -ErrorAction Stop -Verbose:$false


#------------------------------------------------------------------------------
# Row type bound to the monitor list
#------------------------------------------------------------------------------

# A plain CLR type rather than a pscustomobject: WPF binds to PSObject only
# through its type descriptor, and that path behaves differently between
# 5.1 and 7. Thumbnail stays 'object' so this type needs no WPF reference.
if (-not ('WallByResGui.DisplayRow' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
namespace WallByResGui
{
    public class DisplayRow
    {
        public string Friendly           { get; set; }
        public string DevicePath         { get; set; }
        public string ResolutionText     { get; set; }
        public string ImageText          { get; set; }
        public string ImagePath          { get; set; }
        public string SourceText         { get; set; }
        public string ProblemText        { get; set; }
        public string PickLabel          { get; set; }
        public string BadgeVisibility    { get; set; }
        public string ProblemVisibility  { get; set; }
        public string AutoVisibility     { get; set; }
        public double ThumbWidth         { get; set; }
        public double ThumbHeight        { get; set; }
        public object Thumbnail          { get; set; }
    }
}
'@
}


#------------------------------------------------------------------------------
# State
#------------------------------------------------------------------------------

# One hashtable, deliberately: handler script blocks resolve variables against
# the script scope when they run, not over a closure, and a missing hashtable
# key returns $null quietly where a missing variable would throw under
# Set-StrictMode -Version Latest.
$script:State = @{
    Root         = $null
    Position     = 'Fill'
    Signature    = $null
    Pending      = $null
    StableTicks  = 0
    TaskChecked  = 0
    Thumbs       = @{}
    Queued       = @{}
    Failed       = @{}
    KeyPath      = @{}
    Pool         = $null
    Jobs         = @()
    WantAuto     = $false
    RowEvent     = $null
    DrainTimer   = $null
    Notifier     = $null
    Deferred     = $null
    FallbackTick = 0
    Rows         = $null
    Loaded       = $false
    Dark         = $false
}

$script:SettingsPath = Join-Path (Split-Path (Get-WallpaperLogPath) -Parent) 'gui-settings.json'

function Get-DefaultRoot {
    # The three sample backgrounds that ship with the repository, so a fresh
    # clone opens on something real instead of an empty folder.
    $examples = Join-Path (Split-Path $PSScriptRoot -Parent) 'examples\wallpapers'
    if (Test-Path -LiteralPath $examples -PathType Container) {
        return (Get-Item -LiteralPath $examples).FullName
    }
    return (Join-Path $env:USERPROFILE 'Pictures\Wallpapers')
}

function Import-GuiSetting {
    $root     = Get-DefaultRoot
    $position = 'Fill'
    $dark     = Get-WindowsDarkMode

    if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
        try {
            $d = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            $names = $d.PSObject.Properties.Name
            if ($names -contains 'root'     -and $d.root)     { $root     = $d.root }
            if ($names -contains 'position' -and $d.position) { $position = $d.position }
            if ($names -contains 'dark') { $dark = [bool] $d.dark }
        }
        catch { }   # a hand-mangled file must not stop the window opening
    }

    $script:State.Root     = $root
    $script:State.Position = $position
    $script:State.Dark     = $dark
}

function Export-GuiSetting {
    try {
        $dir = Split-Path $script:SettingsPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = [pscustomobject]@{
            root     = $script:State.Root
            position = $script:State.Position
            dark     = $script:State.Dark
        } | ConvertTo-Json
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, $utf8)
    }
    catch { }
}


#------------------------------------------------------------------------------
# Window
#------------------------------------------------------------------------------

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'

# XmlReader.Create on the path, not [xml](Get-Content): Get-Content guesses the
# encoding and would mangle the accented strings under 5.1.
$reader = [System.Xml.XmlReader]::Create($xamlPath)
try   { $window = [System.Windows.Markup.XamlReader]::Load($reader) }
finally { $reader.Dispose() }

$ui = @{}
foreach ($name in @('TxtRoot', 'BtnBrowse', 'CmbPosition', 'LstDisplays', 'BtnRefresh',
                    'TglAuto', 'TxtAutoState', 'TxtStatus', 'BtnLog', 'BtnApply',
                    'BtnTheme', 'BtnAbout', 'IconSun', 'IconMoon')) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw ("MainWindow.xaml has no control named '{0}'." -f $name) }
    $ui[$name] = $control
}
$script:Ui = $ui

function Get-Text {
    param([string] $Key)
    return [string] $window.FindResource($Key)
}

function Set-Status {
    param([string] $Key, [object[]] $Arg)
    $text = Get-Text $Key
    if ($Arg) { $text = [string]::Format($text, $Arg) }
    $script:Ui.TxtStatus.Text = $text
}

function Invoke-Deferred {
    # A click that runs a second of work inline looks frozen: the status text
    # and the disabled button never get painted. Hand the work to a one-shot
    # timer so the UI renders first, then blocks.
    param([scriptblock] $Body)

    $script:State.Deferred = $Body

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(30)
    $timer.Add_Tick({
        $this.Stop()
        Invoke-Guarded { & $script:State.Deferred }
    })
    $timer.Start()
}

function Write-GuiLog {
    # The status line tells the user to look in the log, so something has to
    # actually be there. Write-Warning goes nowhere in a process with no
    # console, which is exactly how the window is launched.
    param([string] $Message)

    try {
        $path = Get-WallpaperLogPath
        $dir  = Split-Path $path -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), 'GUI', $Message
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    }
    catch { }   # logging must never break the window
}

function Get-DialogOwner {
    # WinForms dialogs shown from a WPF window with no owner open behind it and
    # never take focus, so the click looks like it did nothing. Wrapping the
    # WPF handle gives them a proper owner.
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
    $owner  = New-Object System.Windows.Forms.NativeWindow
    $owner.AssignHandle($helper.Handle)
    return $owner
}

function Invoke-Guarded {
    # No Application object means no DispatcherUnhandledException hook, so an
    # exception escaping a handler would kill the window with no message.
    param([scriptblock] $Body)
    try { & $Body }
    catch {
        try { $script:Ui.TxtStatus.Text = Get-Text 'S_Error' } catch { }
        Write-GuiLog ("{0} | at {1}" -f $_.Exception.Message,
                      ($_.ScriptStackTrace -replace "`r?`n", ' <- '))
    }
}


#------------------------------------------------------------------------------
# Theme
#------------------------------------------------------------------------------

function Set-WindowIcon {
    # Drives both the title bar and the taskbar button. Missing file is not
    # worth failing over: the window just keeps the host's default icon.
    param([System.Windows.Window] $Target)

    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\screen4screen.ico'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }

    try {
        $image = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri] $path)
        $Target.Icon = [System.Windows.Media.ImageSource] $image
    }
    catch { }
}

# Both palettes are spelled out here rather than relying on the values baked
# into the XAML: switching back to light has to restore them explicitly.
$script:Palette = @{
    Light = @(
        @('WindowBrush',   '#FFF3F4F6'), @('SurfaceBrush',     '#FFFFFFFF'),
        @('FieldBrush',    '#FFFFFFFF'), @('BorderBrush2',     '#FFD9DCE0'),
        @('TextBrush',     '#FF1A1C1E'), @('SubtleBrush',      '#FF5A6068'),
        @('AccentBrush',   '#FFB0296A'), @('OnAccentBrush',    '#FFFFFFFF'),
        @('ThumbBrush',    '#FFE8EAEC'), @('HoverBrush',       '#FFEBEDEF'),
        @('PressedBrush',  '#FFDFE2E6'), @('ScrollThumbBrush', '#FFC4C8CD'),
        @('FabBrush',      '#FFFFFFFF'), @('FabEdgeBrush',     '#FFD9DCE0'),
        @('FabIconBrush',  '#FF1A1C1E'), @('PopupBrush',       '#FFFFFFFF'),
        @('PopupEdgeBrush',  '#FFAEB4BC')
    )
    Dark = @(
        @('WindowBrush',   '#FF1B1D20'), @('SurfaceBrush',     '#FF24272B'),
        @('FieldBrush',    '#FF1F2226'), @('BorderBrush2',     '#FF3A3F45'),
        @('TextBrush',     '#FFECEEF0'), @('SubtleBrush',      '#FFA8AFB7'),
        @('AccentBrush',   '#FFE2ABBA'), @('OnAccentBrush',    '#FF1B1D20'),
        @('ThumbBrush',    '#FF2E3236'), @('HoverBrush',       '#FF2E3236'),
        @('PressedBrush',  '#FF3A3F45'), @('ScrollThumbBrush', '#FF4A5057'),
        @('FabBrush',      '#FFFFFFFF'), @('FabEdgeBrush',     '#00000000'),
        @('FabIconBrush',  '#FF1A1C1E'), @('PopupBrush',       '#FF1F2226'),
        @('PopupEdgeBrush',  '#FF565C64')
    )
}

function Get-WindowsDarkMode {
    # Only consulted on the very first launch; after that the user's own
    # choice is remembered.
    try {
        $key = Get-ItemProperty -ErrorAction Stop `
               -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
               -Name 'AppsUseLightTheme'
        return (([int] $key.AppsUseLightTheme) -eq 0)
    }
    catch { return $false }   # key absent on older builds: assume light
}

function Set-WindowPalette {
    # Takes the window so the about box can be themed the same way.
    param([System.Windows.Window] $Target, [bool] $Dark)

    $palette = if ($Dark) { $script:Palette.Dark } else { $script:Palette.Light }

    foreach ($pair in $palette) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($pair[1])
        $brush = New-Object System.Windows.Media.SolidColorBrush $color
        $brush.Freeze()
        # Cast, or PowerShell stores its PSObject wrapper in the dictionary
        # (the indexer takes an object, so nothing forces an unwrap) and WPF
        # then tries to use the brush's ToString as the property value.
        $Target.Resources[$pair[0]] = [System.Windows.Media.Brush] $brush
    }
}

function Set-Theme {
    param([bool] $Dark)

    Set-WindowPalette -Target $window -Dark $Dark
    $script:State.Dark = $Dark

    # The icon shows where a click leads, not where you are: a sun while the
    # window is dark, a crescent while it is light.
    $script:Ui.IconSun.Visibility  = if ($Dark) { 'Visible' }   else { 'Collapsed' }
    $script:Ui.IconMoon.Visibility = if ($Dark) { 'Collapsed' } else { 'Visible' }
    $script:Ui.BtnTheme.ToolTip    =
        if ($Dark) { Get-Text 'S_ThemeToLight' } else { Get-Text 'S_ThemeToDark' }
}

function Show-AboutWindow {
    $path   = Join-Path $PSScriptRoot 'AboutWindow.xaml'
    $reader = [System.Xml.XmlReader]::Create($path)
    try   { $about = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }

    Set-WindowPalette -Target $about -Dark $script:State.Dark
    Set-WindowIcon    -Target $about
    $about.Owner = $window

    $version = $about.FindName('TxtVersion')
    if ($version) {
        $module = Get-Module Screen4Screen
        if ($module) { $version.Text = 'Version ' + $module.Version.ToString() }
    }

    $github = $about.FindName('BtnGithub')
    if ($github) {
        $github.Add_Click({ Start-Process 'https://github.com/pmudry/screen4screen' })
    }

    $close = $about.FindName('BtnClose')
    if ($close) {
        # GetWindow($this) rather than the local $about: a handler resolves its
        # variables against the script scope when it runs, not over a closure.
        $close.Add_Click({ [System.Windows.Window]::GetWindow($this).Close() })
    }

    $about.ShowDialog() | Out-Null
}


#------------------------------------------------------------------------------
# Thumbnails
#------------------------------------------------------------------------------

# Decoding one sample webp takes about half a second whatever DecodePixelWidth
# asks for, because the codec expands the whole image before scaling. Done on
# the UI thread that is half a second of wait cursor per monitor, so it runs in
# a small runspace pool and comes back frozen, which is what makes a WPF image
# safe to hand to another thread.
#
# A C# helper was tried first and dropped: Add-Type -ReferencedAssemblies adds
# to the default reference set on Windows PowerShell but replaces it on
# PowerShell 7, and neither host accepted one list. Runspaces need no compiler.
$script:DecodeThumbnail = {
    param([string] $Path, [int] $Width)

    Add-Type -AssemblyName PresentationCore
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption      = 'OnLoad'
            $bitmap.DecodePixelWidth = $Width
            $bitmap.StreamSource     = $stream
            $bitmap.EndInit()
            $bitmap.Freeze()
            return $bitmap
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }   # no codec for this format, typically
}

function Request-Thumbnail {
    # Never blocks. Returns the image when it is already decoded, otherwise
    # starts a background decode and returns $null; the drain timer rebuilds
    # the list once results land.
    param([string] $Path)

    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $info = Get-Item -LiteralPath $Path
    $key  = '{0}|{1}|{2}' -f $info.FullName, $info.LastWriteTimeUtc.Ticks, $info.Length

    # A failed decode is cached as $null, so a missing codec is not retried on
    # every refresh.
    if ($script:State.Thumbs.ContainsKey($key)) { return $script:State.Thumbs[$key] }

    if (-not $script:State.Queued.ContainsKey($key)) {
        $script:State.Queued[$key]  = $true
        $script:State.KeyPath[$key] = $Path
        Start-ThumbnailDecode -Key $key -Path $info.FullName
    }

    return $null
}

function Start-ThumbnailDecode {
    param([string] $Key, [string] $Path)

    if (-not $script:State.Pool) {
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2)
        $pool.ApartmentState = 'STA'
        $pool.Open()
        $script:State.Pool = $pool
    }

    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.RunspacePool = $script:State.Pool
    [void] $shell.AddScript($script:DecodeThumbnail).AddArgument($Path).AddArgument(256)

    $script:State.Jobs += [pscustomobject]@{
        Key    = $Key
        Shell  = $shell
        Handle = $shell.BeginInvoke()
    }

    Start-ThumbnailDrain
}

function Start-ThumbnailDrain {
    if ($script:State.DrainTimer) { return }

    Set-Status 'S_LoadingPreviews'

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({ Invoke-Guarded { Invoke-ThumbnailDrain } })
    $script:State.DrainTimer = $timer
    $timer.Start()
}

function Invoke-ThumbnailDrain {
    $pending = @()
    $arrived = $false

    foreach ($job in $script:State.Jobs) {
        if (-not $job.Handle.IsCompleted) { $pending += $job; continue }

        $image = $null
        try   { $image = @($job.Shell.EndInvoke($job.Handle))[0] }
        catch { $image = $null }
        $job.Shell.Dispose()

        $script:State.Thumbs[$job.Key] = $image
        if ($null -eq $image -and $script:State.KeyPath.ContainsKey($job.Key)) {
            $script:State.Failed[$script:State.KeyPath[$job.Key]] = $true
        }
        $arrived = $true
    }

    $script:State.Jobs = $pending

    if ($arrived) { Update-DisplayList }

    if ($script:State.Jobs.Count -eq 0) {
        $script:State.DrainTimer.Stop()
        $script:State.DrainTimer = $null
        if ($script:Ui.TxtStatus.Text -eq (Get-Text 'S_LoadingPreviews')) {
            $script:Ui.TxtStatus.Text = ''
        }
    }
}


#------------------------------------------------------------------------------
# Monitor list
#------------------------------------------------------------------------------

function Update-DisplayList {
    # Never blocks: thumbnails that are not decoded yet come back as $null
    # and the drain timer rebuilds the list once they land.
    $root = $script:State.Root
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    $plan = @()
    if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
        $plan = @(Get-WallpaperPlan -Root $root)
    }
    else {
        $plan = @(Get-AttachedDisplay | ForEach-Object {
            [pscustomobject]@{
                Friendly = $_.Friendly; DevicePath = $_.DevicePath
                Width = $_.Width; Height = $_.Height; IsPrimary = $_.IsPrimary
                Image = $null; Source = 'None'; Matched = $false
            }
        })
    }

    foreach ($p in $plan) {
        $row = New-Object WallByResGui.DisplayRow
        $row.Friendly         = $p.Friendly
        $row.DevicePath       = $p.DevicePath
        $row.ResolutionText   = '{0} x {1}' -f $p.Width, $p.Height

        # The preview box carries the screen's own aspect ratio: a 16:9 panel
        # must look 16:9, not be cropped into an ultrawide slot. The box is
        # bounded by 150x54 and the ratio is never distorted to fit; for an
        # ultrawide the width hits the bound first and the height follows.
        $boxW = 96.0
        $boxH = 54.0
        if ($p.Width -gt 0 -and $p.Height -gt 0) {
            $boxW = 54.0 * $p.Width / $p.Height
            if ($boxW -gt 150.0) {
                $boxW = 150.0
                $boxH = 150.0 * $p.Height / $p.Width
            }
        }
        $row.ThumbWidth       = [Math]::Round($boxW)
        $row.ThumbHeight      = [Math]::Round($boxH)
        $row.BadgeVisibility  = if ($p.IsPrimary) { 'Visible' } else { 'Collapsed' }
        $row.ImagePath        = $p.Image
        $row.ProblemText      = ''
        $row.ProblemVisibility = 'Collapsed'

        $isManual = ($p.Source -eq 'Assignment')
        $row.AutoVisibility = if ($isManual) { 'Visible' } else { 'Collapsed' }
        $row.PickLabel      = if ($isManual) { Get-Text 'S_ChangeLabel' } else { Get-Text 'S_PickLabel' }

        if ($p.Image) {
            $row.ImageText  = (Split-Path $p.Image -Leaf) + '  '
            $row.SourceText = if ($isManual) { Get-Text 'S_SourceManual' } else { Get-Text 'S_SourceAuto' }
            $row.Thumbnail = Request-Thumbnail -Path $p.Image
            if ($null -eq $row.Thumbnail -and $script:State.Failed.ContainsKey($p.Image)) {
                $row.ProblemText       = Get-Text 'S_NoThumb'
                $row.ProblemVisibility = 'Visible'
            }
        }
        else {
            $row.ImageText         = ''
            $row.SourceText        = ''
            $row.ProblemText       = Get-Text 'S_NoImage'
            $row.ProblemVisibility = 'Visible'
        }

        if (-not $p.Matched -and $plan.Count -gt 1) {
            $row.ProblemText       = Get-Text 'S_NotMatched'
            $row.ProblemVisibility = 'Visible'
        }

        $rows.Add($row)
    }

    $script:State.Rows = $rows
    $script:Ui.LstDisplays.ItemsSource = $rows

    if ($rows.Count -eq 0) { $script:Ui.TxtStatus.Text = Get-Text 'S_NoDisplay' }
}


#------------------------------------------------------------------------------
# Scheduled task
#------------------------------------------------------------------------------

function Update-AutoState {
    $state = Get-WallpaperTaskState
    $script:Ui.TglAuto.IsChecked = $state.Installed

    if (-not $state.Installed)  { $script:Ui.TxtAutoState.Text = Get-Text 'S_AutoOff';    return }
    if ($state.Running)         { $script:Ui.TxtAutoState.Text = Get-Text 'S_AutoOn';     return }
    $script:Ui.TxtAutoState.Text = Get-Text 'S_AutoPaused'
}

function Set-AutoMode {
    param([bool] $Enabled)

    $launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'screen4screen.ps1'

    if ($Enabled) {
        Install-WallpaperTask -Root $script:State.Root `
                              -PositionName $script:State.Position `
                              -LauncherPath $launcher
        try { Start-ScheduledTask -TaskName 'screen4screen' -ErrorAction Stop } catch { }
    }
    else {
        Uninstall-WallpaperTask
    }

    Update-AutoState
}

function Sync-AutoTask {
    # The task bakes the folder and the fit mode into its command line, so a
    # settings change has to be pushed into it or the background pass would
    # keep using the old values.
    if ((Get-WallpaperTaskState).Installed) {
        Invoke-Guarded { Set-AutoMode -Enabled $true }
    }
}


#------------------------------------------------------------------------------
# Actions
#------------------------------------------------------------------------------

function Invoke-ApplyNow {
    $root = $script:State.Root
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        Set-Status 'S_FolderMissing'
        return
    }

    Set-Status 'S_Applying'
    $script:Ui.BtnApply.IsEnabled = $false

    try {
        $results = @(Set-WallpapersNow -Root $root -PositionName $script:State.Position)
        $done    = @($results | Where-Object { $_.Applied }).Count

        if ($done -eq $results.Count) { Set-Status 'S_Applied' @($done) }
        else { Set-Status 'S_AppliedPartial' @($done, $results.Count) }
    }
    finally {
        $script:Ui.BtnApply.IsEnabled = $true
    }

    Update-DisplayList
}

function Select-RowImage {
    param([object] $Row)

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title  = Get-Text 'S_PickTitle'
    $dialog.Filter = 'Images|*.jpg;*.jpeg;*.png;*.bmp;*.webp|*.*|*.*'
    if ($script:State.Root -and (Test-Path -LiteralPath $script:State.Root)) {
        $dialog.InitialDirectory = $script:State.Root
    }

    $owner = Get-DialogOwner
    try   { $result = $dialog.ShowDialog($owner) }
    finally { $owner.ReleaseHandle() }

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
    if (-not $Row.DevicePath) { return }

    Set-WallpaperAssignment -Root $script:State.Root `
                            -DevicePath $Row.DevicePath `
                            -Image $dialog.FileName `
                            -Friendly $Row.Friendly `
                            -Resolution ($Row.ResolutionText -replace ' ', '')

    Update-DisplayList
    Set-Status 'S_Saved'
}

function Invoke-RowCommand {
    param([object] $EventArgs)

    $source = $EventArgs.OriginalSource
    if ($source -isnot [System.Windows.Controls.Button]) { return }

    $row = $source.DataContext
    if ($null -eq $row) { return }

    switch ([string] $source.Tag) {
        'pick' { Select-RowImage -Row $row }
        'auto' {
            Remove-WallpaperAssignment -Root $script:State.Root -DevicePath $row.DevicePath
            Update-DisplayList
            Set-Status 'S_Saved'
        }
    }
}


#------------------------------------------------------------------------------
# Polling
#------------------------------------------------------------------------------

function Start-DeferredLoad {
    # Runs once the window is up. Deferring the list was tried and reverted:
    # it did not make the window appear sooner, it only made it appear empty
    # first. What is left here genuinely is not needed to paint anything.
    # Get-ScheduledTask is a CIM call costing close to a second, and the
    # thumbnails a few hundred milliseconds more. Both run once the window is
    # already on screen, so it appears immediately instead of after two
    # seconds of nothing.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(60)
    $timer.Add_Tick({
        $this.Stop()
        Invoke-Guarded {
            Update-AutoState

            try   { $script:State.Notifier = New-Object WallByRes.DisplayNotifier }
            catch { $script:State.Notifier = $null }   # fall back to polling
        }
    })
    $timer.Start()
}

function Invoke-Tick {
    # Enumerating the adapters costs about 50 ms, far too much to spend on
    # every beat. Ask the notifier instead, which is a zero-timeout wait on an
    # event handle, and only enumerate when Windows actually said something.
    # A slow full check still runs as a safety net in case the window sink
    # could not be created.
    $script:State.FallbackTick++
    $forced = ($script:State.FallbackTick % 15) -eq 0

    if ($script:State.Notifier) {
        if (-not $script:State.Notifier.Wait(0) -and -not $forced) { return }
    }

    $signature = Get-DisplaySignature

    if ($signature -eq $script:State.Signature) {
        $script:State.Pending     = $null
        $script:State.StableTicks = 0
        return
    }

    # Debounce: docking emits several intermediate topologies, and rebuilding
    # the list on each is visually chaotic.
    if ($signature -ne $script:State.Pending) {
        $script:State.Pending     = $signature
        $script:State.StableTicks = 1
        return
    }

    $script:State.StableTicks++
    if ($script:State.StableTicks -lt 2) { return }

    $script:State.Signature   = $signature
    $script:State.Pending     = $null
    $script:State.StableTicks = 0

    Update-DisplayList

    # The background task owns re-applying. Doing it here too would double
    # apply and flash.
    if ((Get-WallpaperTaskState).Installed) { Set-Status 'S_TopologyChanged' }
    else { Set-Status 'S_TopologyChangedIdle' }
}


#------------------------------------------------------------------------------
# Wiring
#------------------------------------------------------------------------------

Import-GuiSetting
Set-WindowIcon -Target $window
Set-Theme -Dark $script:State.Dark

$ui.TxtRoot.Text = $script:State.Root

foreach ($item in $ui.CmbPosition.Items) {
    if ([string] $item.Tag -eq $script:State.Position) { $ui.CmbPosition.SelectedItem = $item }
}
if ($null -eq $ui.CmbPosition.SelectedItem) { $ui.CmbPosition.SelectedIndex = 0 }

$ui.BtnBrowse.Add_Click({
    Invoke-Guarded {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = Get-Text 'S_BrowseTitle'
        if ($script:State.Root -and (Test-Path -LiteralPath $script:State.Root)) {
            $dialog.SelectedPath = $script:State.Root
        }
        $owner = Get-DialogOwner
        try   { $result = $dialog.ShowDialog($owner) }
        finally { $owner.ReleaseHandle() }

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:Ui.TxtRoot.Text = $dialog.SelectedPath
        }
    }
})

# WPF selects only the clicked line on a triple click, which on a one-line
# box leaves the selection looking arbitrary. Select the whole path.
$ui.TxtRoot.Add_PreviewMouseLeftButtonDown({
    if ($args[1].ClickCount -eq 3) {
        $script:Ui.TxtRoot.SelectAll()
        $args[1].Handled = $true
    }
})

$ui.TxtRoot.Add_LostFocus({
    Invoke-Guarded {
        $value = $script:Ui.TxtRoot.Text.Trim()
        if ($value -eq $script:State.Root) { return }
        $script:State.Root = $value
        Export-GuiSetting
        Update-DisplayList
        Sync-AutoTask
        Set-Status 'S_Saved'
    }
})

$ui.CmbPosition.Add_SelectionChanged({
    Invoke-Guarded {
        if (-not $script:State.Loaded) { return }
        $item = $script:Ui.CmbPosition.SelectedItem
        if ($null -eq $item) { return }
        $script:State.Position = [string] $item.Tag
        Export-GuiSetting
        Sync-AutoTask
        Set-Status 'S_Saved'
    }
})

$ui.BtnAbout.Add_Click({ Invoke-Guarded { Show-AboutWindow } })

$ui.BtnTheme.Add_Click({
    Invoke-Guarded {
        Set-Theme -Dark (-not $script:State.Dark)
        Export-GuiSetting
    }
})

$ui.BtnRefresh.Add_Click({ Invoke-Guarded { Update-DisplayList; Update-AutoState } })
$ui.BtnApply.Add_Click({
    Invoke-Guarded {
        $script:Ui.BtnApply.IsEnabled = $false
        Set-Status 'S_Applying'
        Invoke-Deferred { Invoke-ApplyNow }
    }
})

$ui.BtnLog.Add_Click({
    Invoke-Guarded {
        $log = Get-WallpaperLogPath
        if (Test-Path -LiteralPath $log) { Start-Process -FilePath $log }
    }
})

$ui.TglAuto.Add_Click({
    Invoke-Guarded {
        # Carried through $script:State, never a closure. GetNewClosure gives
        # the block its own script scope, so $script:Ui resolves to $null
        # inside it and every control access throws.
        $script:State.WantAuto = [bool] $script:Ui.TglAuto.IsChecked
        $script:Ui.TglAuto.IsEnabled = $false
        Set-Status 'S_Working'

        Invoke-Deferred {
            try { Set-AutoMode -Enabled $script:State.WantAuto }
            catch {
                Write-GuiLog ('Set-AutoMode({0}) failed: {1} | at {2}' -f $script:State.WantAuto,
                              $_.Exception.Message,
                              ($_.ScriptStackTrace -replace "`r?`n", ' <- '))
                # Re-read the truth first, then say it failed: calling
                # Update-AutoState afterwards would overwrite the message.
                Update-AutoState
                $script:Ui.TxtAutoState.Text = Get-Text 'S_AutoFailed'
            }
            finally {
                $script:Ui.TglAuto.IsEnabled = $true
                $script:Ui.TxtStatus.Text = ''
            }
        }
    }
})

# One class handler rather than per-row subscriptions, so rebuilding the list
# does not leak handlers.
$ui.LstDisplays.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler] {
        # $args belongs to the handler, not to the block Invoke-Guarded runs:
        # reading $args[1] in there indexes an empty array. Hand it over
        # through $script:State, as everything else does.
        $script:State.RowEvent = $args[1]
        Invoke-Guarded { Invoke-RowCommand -EventArgs $script:State.RowEvent }
    })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Invoke-Guarded { Invoke-Tick } })

$window.Add_Loaded({
    Invoke-Guarded {
        $script:State.Signature = Get-DisplaySignature
        Update-DisplayList
        $script:State.Loaded = $true
        $timer.Start()
        Start-DeferredLoad
    }
})

$window.Add_Closed({
    $timer.Stop()
    if ($script:State.Notifier) { $script:State.Notifier.Dispose() }
    if ($script:State.Pool) { $script:State.Pool.Close(); $script:State.Pool.Dispose() }
})

$window.ShowDialog() | Out-Null
