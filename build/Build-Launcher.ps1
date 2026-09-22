<#
.SYNOPSIS
    Builds screen4screen.exe, the launcher that carries the program icon and
    opens the window without a console.

.DESCRIPTION
    Uses the C# compiler that ships with the .NET Framework, so nothing needs
    installing. The resulting .exe is not tracked in git; run this once after
    cloning if you want the icon in Explorer.
#>

[CmdletBinding()]
param()

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

# /target:winexe is what keeps a console from ever being created.
& $csc /nologo /target:winexe /platform:anycpu `
       ('/win32icon:' + $icon) `
       ('/out:' + $out) `
       /r:System.dll /r:System.Windows.Forms.dll `
       $source

if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }

Write-Host ("Built {0}" -f $out) -ForegroundColor Green
