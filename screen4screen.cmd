@echo off
rem Double-clickable launcher. -ExecutionPolicy Bypass because the machine
rem policy may be AllSigned and this script is not signed; Process scope wins.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0screen4screen.ps1" -Gui
