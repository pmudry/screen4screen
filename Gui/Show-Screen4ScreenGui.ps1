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

# The state-changing verbs in this file all belong to private helpers of this
# window -- Update-DisplayList, Start-ThumbnailDrain, Set-RootFolder and the
# rest. None is a cmdlet anyone calls, and none has anything for -WhatIf to
# describe; the functions that do are in the module, and they support it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Private helpers of this window, not cmdlets; the module owns every state change worth previewing.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Nothing here has a console to complain to: the launcher starts this with
# CreateNoWindow, so anything thrown before the window is up used to end as an
# exit code nobody saw. A script-scope trap catches whatever escapes, without
# wrapping the whole file in a try block. The log path is spelled out rather
# than asked of the module, which may be exactly what failed to import.
trap {
    $detail = "{0}`n{1}" -f $_, $_.ScriptStackTrace

    try {
        $dir = Join-Path $env:LOCALAPPDATA 'screen4screen'
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath (Join-Path $dir 'log.txt') -Encoding UTF8 -Value (
            '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), 'GUI',
            ($detail -replace "`r?`n", ' <- '))
    }
    catch { }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void] [System.Windows.Forms.MessageBox]::Show(
            $detail, 'screen4screen',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    catch { }

    exit 1
}

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
    Plan         = $null
    Loaded       = $false
    Dark         = $false
    Language     = 'en'
    LangEvent    = $null
}

# The four the window ships with. A dictionary per code under Gui\Lang, all
# carrying the same keys; anything else falls back to English.
$script:Languages = @('fr', 'en', 'de', 'it')

$script:SettingsPath = Join-Path (Split-Path (Get-WallpaperLogPath) -Parent) 'gui-settings.json'

function Get-DefaultRoot {
    # The folder shipped with the repository, holding the three sample
    # backgrounds, so a fresh clone opens on something real instead of an
    # empty folder. Same default as the CLI wrapper's -WallpaperRoot.
    $shipped = Join-Path (Split-Path $PSScriptRoot -Parent) 'wallpapers'
    if (Test-Path -LiteralPath $shipped -PathType Container) {
        return (Get-Item -LiteralPath $shipped).FullName
    }
    return (Join-Path $env:USERPROFILE 'Pictures\Wallpapers')
}

function Get-DefaultLanguage {
    # Only consulted on the very first launch; after that the user's own choice
    # is remembered. CurrentUICulture, not CurrentCulture: the first is the
    # language Windows shows its own interface in, the second only decides how
    # dates and numbers are written.
    try {
        $tag = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        if ($script:Languages -contains $tag) { return $tag }
    }
    catch { }
    return 'en'
}

function Import-GuiSetting {
    $root     = Get-DefaultRoot
    $position = 'Fill'
    $dark     = Get-WindowsDarkMode
    $language = Get-DefaultLanguage

    if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
        try {
            $d = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            $names = $d.PSObject.Properties.Name
            if ($names -contains 'root'     -and $d.root)     { $root     = $d.root }
            if ($names -contains 'position' -and $d.position) { $position = $d.position }
            if ($names -contains 'dark') { $dark = [bool] $d.dark }
            if ($names -contains 'language' -and $d.language -and
                ($script:Languages -contains [string] $d.language)) {
                $language = [string] $d.language
            }
        }
        catch { }   # a hand-mangled file must not stop the window opening
    }

    $script:State.Root     = $root
    $script:State.Position = $position
    $script:State.Dark     = $dark
    $script:State.Language = $language
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
            language = $script:State.Language
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
                    'BtnTheme', 'BtnAbout', 'IconSun', 'IconMoon',
                    'BtnLang', 'TxtLang', 'PopLang', 'BtnTask')) {
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

    # $Arg.Count, not $Arg: a lone argument of 0 makes @(0) falsy, the format
    # is skipped and the user is shown a literal "{0}".
    if ($null -ne $Arg -and $Arg.Count -gt 0) { $text = [string]::Format($text, $Arg) }

    $script:Ui.TxtStatus.Text = $text
}

function Invoke-Deferred {
    # A click that runs a second of work inline looks frozen: the status text
    # and the disabled button never get painted. Hand the work to a one-shot
    # timer so the UI renders first, then blocks.
    param([scriptblock] $Body)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(30)

    # Carried on the timer rather than in $script:State: two deferrals queued
    # inside the same 30 ms window shared the one slot, so the first body was
    # dropped and the second ran twice. $this is the timer, which is how the
    # handler reaches it without a closure.
    $timer.Tag = $Body
    $timer.Add_Tick({
        $this.Stop()
        Invoke-Guarded $this.Tag
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
# Language
#------------------------------------------------------------------------------

function Set-WindowLanguage {
    # Takes the window so the about box can be switched the same way. Swapping
    # a merged dictionary re-resolves every {DynamicResource} that refers into
    # it, so the window changes language where it stands, with nothing to
    # rebuild and no reopening.
    param([System.Windows.Window] $Target, [string] $Language)

    $path = Join-Path $PSScriptRoot ('Lang\{0}.xaml' -f $Language)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $path = Join-Path $PSScriptRoot 'Lang\en.xaml'
    }

    # XmlReader on the path, not [xml](Get-Content): the dictionaries are UTF-8
    # and Get-Content would guess the encoding under 5.1 and mangle the
    # accents, which is the same trap the window itself is loaded around.
    $reader = [System.Xml.XmlReader]::Create($path)
    try   { $dict = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }

    # Recognised by a key every dictionary must carry, so there is no
    # bookkeeping to keep in step with what was merged last.
    $old = @($Target.Resources.MergedDictionaries | Where-Object { $_.Contains('S_Applying') })
    foreach ($d in $old) { [void] $Target.Resources.MergedDictionaries.Remove($d) }

    [void] $Target.Resources.MergedDictionaries.Add($dict)
}

function Set-Language {
    param([string] $Language)

    if ($script:Languages -notcontains $Language) { $Language = 'en' }

    Set-WindowLanguage -Target $window -Language $Language
    $script:State.Language  = $Language
    $script:Ui.TxtLang.Text = $Language.ToUpperInvariant()

    # Two things the code owns rather than the markup, so they do not follow
    # the dictionary on their own: the theme tooltip, which depends on which
    # way the switch will go, and the rows, whose text was copied into
    # DisplayRow when the list was built.
    Set-Theme -Dark $script:State.Dark

    if ($script:State.Loaded) {
        Update-DisplayList
        Update-AutoState
        $script:Ui.TxtStatus.Text = ''
    }

    Export-GuiSetting
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

    Set-WindowLanguage -Target $about -Language $script:State.Language
    Set-WindowPalette  -Target $about -Dark $script:State.Dark
    Set-WindowIcon     -Target $about
    $about.Owner = $window

    # The same mark Explorer and the taskbar show. Set from here rather than
    # from the markup: XamlReader.Load leaves the tree without a BaseUri, so a
    # relative URI in the XAML would have nothing to resolve against.
    $logo = $about.FindName('ImgLogo')
    if ($logo) {
        $mark = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\screen4screen.png'
        if (Test-Path -LiteralPath $mark -PathType Leaf) {
            try { $logo.Source = New-Object System.Windows.Media.Imaging.BitmapImage ([Uri] $mark) }
            catch { }   # a missing mark is not worth failing the window over
        }
    }

    $version = $about.FindName('TxtVersion')
    if ($version) {
        $module = Get-Module Screen4Screen
        if ($module) {
            $version.Text = [string]::Format((Get-Text 'S_Version'), $module.Version.ToString())
        }
    }

    $github = $about.FindName('BtnGithub')
    if ($github) {
        $github.Add_Click({
            Invoke-Guarded { Start-Process 'https://github.com/pmudry/screen4screen' }
        })
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

    # Same plan, so the rows keep the images the thumbnails were decoded for.
    if ($arrived) { Update-DisplayList -Plan $script:State.Plan }

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
    #
    # -Plan rebuilds from a plan already in hand. Recomputing one picks a
    # fresh random image every time a candidate is a folder, so the drain used
    # to swap the picture out from under the thumbnail it had just decoded,
    # queue a decode for the new one, and show something other than what was
    # actually applied.
    param([object[]] $Plan)

    $root = $script:State.Root
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    # $entries, not $plan: variable names are case-insensitive here, so a
    # local $plan IS the $Plan parameter, and initialising it emptied the
    # argument before it could be read.
    $entries = @()
    if ($Plan) {
        $entries = @($Plan)
    }
    elseif ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
        $entries = @(Get-WallpaperPlan -Root $root)
    }
    else {
        $entries = @(Get-AttachedDisplay | ForEach-Object {
            [pscustomobject]@{
                Friendly = $_.Friendly; DevicePath = $_.DevicePath
                Width = $_.Width; Height = $_.Height; IsPrimary = $_.IsPrimary
                Image = $null; Source = 'None'; Matched = $false
            }
        })
    }

    foreach ($p in $entries) {
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

        # Only when there is an image to apply. Set-WallpapersNow reports the
        # missing image first, and telling the user the image will be applied
        # everywhere, about a monitor that gets nothing at all, is just wrong.
        if ($p.Image -and -not $p.Matched -and $entries.Count -gt 1) {
            $row.ProblemText       = Get-Text 'S_NotMatched'
            $row.ProblemVisibility = 'Visible'
        }

        $rows.Add($row)
    }

    $script:State.Plan = $entries
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

    # Nothing to show anyone while there is no task.
    $script:Ui.BtnTask.Visibility = if ($state.Installed) { 'Visible' } else { 'Collapsed' }

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
    # keep using the old values. The watcher already running holds the old
    # ones in its own arguments and MultipleInstances IgnoreNew means
    # Start-ScheduledTask is ignored while it is up, so it has to be stopped
    # first or the change would not take until the next logon.
    #
    # Returns whether it worked, because the callers used to write "saved"
    # over the error Invoke-Guarded had just put on the status line.
    if (-not (Get-WallpaperTaskState).Installed) { return $true }

    try {
        Stop-ScheduledTask -TaskName 'screen4screen' -ErrorAction SilentlyContinue | Out-Null
        Set-AutoMode -Enabled $true | Out-Null
        return $true
    }
    catch {
        Write-GuiLog ('Sync-AutoTask failed: {0} | at {1}' -f $_.Exception.Message,
                      ($_.ScriptStackTrace -replace "`r?`n", ' <- '))
        return $false
    }
}


#------------------------------------------------------------------------------
# Actions
#------------------------------------------------------------------------------

function Set-RootFolder {
    # The one place the folder is committed. It used to live in TxtRoot's
    # LostFocus alone, which the Browse button cannot reach: clicking it moves
    # focus away before the dialog opens, so LostFocus fired with the old text
    # and nothing fired again afterwards. Picking a folder and pressing Apply
    # then applied from the previous one.
    param([string] $Value)

    $value = ([string] $Value).Trim()
    if ($value -eq $script:State.Root) { return }

    $script:State.Root = $value
    $script:Ui.TxtRoot.Text = $value

    Export-GuiSetting
    Update-DisplayList

    if (Sync-AutoTask) { Set-Status 'S_Saved' } else { Set-Status 'S_Error' }
}

function Invoke-ApplyNow {
    try {
        # Enter on the text box raises Apply through IsDefault without ever
        # moving focus, so the typed folder has to be taken in here too.
        Set-RootFolder $script:Ui.TxtRoot.Text

        $root = $script:State.Root
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            Set-Status 'S_FolderMissing'
            return
        }

        Set-Status 'S_Applying'

        $results = @(Set-WallpapersNow -Root $root -PositionName $script:State.Position)
        $done    = @($results | Where-Object { $_.Applied }).Count

        # The list before the message: rebuilding it may start a thumbnail
        # decode, and the drain writes a status of its own that would land on
        # top of the count. Rebuilt from the results, so the rows say what was
        # actually applied rather than a fresh random pick.
        if ($results.Count -gt 0) { Update-DisplayList -Plan $results }
        else                      { Update-DisplayList }

        if ($done -eq $results.Count) { Set-Status 'S_Applied' @($done) }
        else { Set-Status 'S_AppliedPartial' @($done, $results.Count) }
    }
    finally {
        # Whatever happened, and however early we left: the early return above
        # used to leave the button greyed out for the rest of the session.
        $script:Ui.BtnApply.IsEnabled = $true
    }
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
    # Not $EventArgs: that is an automatic variable in an event scriptblock.
    param([object] $RowEvent)

    $source = $RowEvent.OriginalSource
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

    # Wait(0) clears the event, so a change seen on one tick is gone by the
    # next. While one is still settling the gate has to stay open, or the
    # debounce below can never reach its second tick and the list only
    # refreshes on the 15 s fallback -- which defeated the whole point of
    # listening for WM_DISPLAYCHANGE.
    if ($script:State.Notifier -and -not $script:State.Pending) {
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

# Before anything reads a string: Set-Theme picks its tooltip out of the
# dictionary, and every {DynamicResource} in the markup needs it merged.
Set-WindowLanguage -Target $window -Language $script:State.Language
$ui.TxtLang.Text = $script:State.Language.ToUpperInvariant()

Set-WindowIcon -Target $window
Set-Theme -Dark $script:State.Dark

$ui.TxtRoot.Text = $script:State.Root

foreach ($item in $ui.CmbPosition.Items) {
    if ([string] $item.Tag -eq $script:State.Position) { $ui.CmbPosition.SelectedItem = $item }
}
if ($null -eq $ui.CmbPosition.SelectedItem) {
    # A saved position outside the six (a hand-edited settings file) would
    # otherwise stay in State, show as something else in the window, and throw
    # at Set-MonitorWallpaper's ValidateSet the first time Apply was pressed.
    $ui.CmbPosition.SelectedIndex = 0
    $script:State.Position = [string] $ui.CmbPosition.SelectedItem.Tag
}

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
            Set-RootFolder $dialog.SelectedPath
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
    Invoke-Guarded { Set-RootFolder $script:Ui.TxtRoot.Text }
})

$ui.CmbPosition.Add_SelectionChanged({
    Invoke-Guarded {
        if (-not $script:State.Loaded) { return }
        $item = $script:Ui.CmbPosition.SelectedItem
        if ($null -eq $item) { return }
        $script:State.Position = [string] $item.Tag
        Export-GuiSetting
        if (Sync-AutoTask) { Set-Status 'S_Saved' } else { Set-Status 'S_Error' }
    }
})

$ui.BtnAbout.Add_Click({ Invoke-Guarded { Show-AboutWindow } })

# Opens, never toggles: StaysOpen="False" has already closed the popup by the
# time this click arrives, so toggling would reopen it and the button would
# look stuck. Clicking anywhere else closes it.
$ui.BtnLang.Add_Click({ Invoke-Guarded { $script:Ui.PopLang.IsOpen = $true } })

# One class handler on the popup rather than four subscriptions, the same way
# the monitor rows are wired.
$ui.PopLang.Child.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler] {
        $script:State.LangEvent = $args[1]
        Invoke-Guarded {
            $source = $script:State.LangEvent.OriginalSource
            if ($source -isnot [System.Windows.Controls.Button]) { return }
            $script:Ui.PopLang.IsOpen = $false
            Set-Language ([string] $source.Tag)
        }
    })

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

# Through mmc.exe with the full path rather than Start-Process 'taskschd.msc',
# which leans on the .msc file association; that is exactly the sort of thing
# a managed machine rewrites.
$ui.BtnTask.Add_Click({
    Invoke-Guarded {
        $console = Join-Path $env:SystemRoot 'System32\taskschd.msc'
        if (Test-Path -LiteralPath $console -PathType Leaf) {
            Start-Process -FilePath 'mmc.exe' -ArgumentList ('"{0}"' -f $console)
        }
        else {
            Start-Process -FilePath 'taskschd.msc'
        }
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
        Invoke-Guarded { Invoke-RowCommand -RowEvent $script:State.RowEvent }
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
    # Guarded like every other handler: with no Application object there is no
    # DispatcherUnhandledException, so anything thrown in here would take the
    # process down without a word.
    Invoke-Guarded {
        $timer.Stop()

        if ($script:State.DrainTimer) {
            $script:State.DrainTimer.Stop()
            $script:State.DrainTimer = $null
        }

        # Decodes still in flight. Stop rather than EndInvoke, which would
        # block the close for as long as a webp takes to expand; without
        # either, the PowerShell instances are never disposed at all.
        foreach ($job in $script:State.Jobs) {
            try { $job.Shell.Stop() }    catch { }
            try { $job.Shell.Dispose() } catch { }
        }
        $script:State.Jobs = @()

        if ($script:State.Notifier) {
            $script:State.Notifier.Dispose()
            $script:State.Notifier = $null
        }
        if ($script:State.Pool) {
            $script:State.Pool.Close()
            $script:State.Pool.Dispose()
            $script:State.Pool = $null
        }
    }
})

$window.ShowDialog() | Out-Null
