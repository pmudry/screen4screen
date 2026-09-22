<#
.SYNOPSIS
    Builds screen4screen.exe, the launcher that carries the program icon and
    opens the window without a console.

.DESCRIPTION
    Uses the C# compiler that ships with the .NET Framework, so nothing needs
    installing. The resulting .exe is not tracked in git; run this once after
    cloning if you want the icon in Explorer.

    The .exe only starts PowerShell on screen4screen.ps1: it does not carry a
    copy of the window or the module, which are read at launch. So editing
    the Gui or Screen4Screen files needs no rebuild, and only a change to
    Launcher.cs or to the icon does. This script checks that for you and does
    nothing when the .exe is already newer than both.

.PARAMETER Force
    Rebuild even when the .exe is already up to date.
#>

[CmdletBinding()]
param([switch] $Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
    throw 'The .NET Framework C# compiler was not found under C:\Windows\Microsoft.NET.'
}

$source = Join-Path $PSScriptRoot 'Launcher.cs'
$icon   = Join-Path $root 'assets\screen4screen.ico'
$out    = Join-Path $root 'screen4screen.exe'

if (-not $Force -and (Test-Path -LiteralPath $out -PathType Leaf)) {
    $built  = (Get-Item -LiteralPath $out).LastWriteTimeUtc
    # No @() around this: it would make $newest an array and the
    # comparison below would fail to convert it to a date.
    $newest = $source, $icon |
              Where-Object { Test-Path -LiteralPath $_ } |
              ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } |
              Sort-Object -Descending |
              Select-Object -First 1

    if ($newest -and $built -gt $newest) {
        Write-Host ("Already up to date: {0}" -f $out) -ForegroundColor Green
        Write-Host 'The window and the module are read at launch, so changes there need no rebuild.'
        Write-Host 'Use -Force to rebuild anyway.'
        return
    }
}

# /target:winexe is what keeps a console from ever being created.
& $csc /nologo /target:winexe /platform:anycpu `
       ('/win32icon:' + $icon) `
       ('/out:' + $out) `
       /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
       $source

if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }

Write-Host ("Built {0}" -f $out) -ForegroundColor Green
