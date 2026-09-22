@echo off
rem Double-clickable launcher. -ExecutionPolicy Bypass because the machine
rem policy may be AllSigned and this script is not signed; Process scope beats
rem the LocalMachine setting, though not one pushed by Group Policy.
rem
rem No arguments means a double click, which wants the window. Anything else is
rem passed straight through, so this file works from a prompt too:
rem   screen4screen.cmd -Once -Verbose
if "%~1"=="" (
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0screen4screen.ps1" -Gui
) else (
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0screen4screen.ps1" %*
)
