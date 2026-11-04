@echo off
rem Removes the "downloaded from the internet" flag from these files, then starts the installer window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' | Unblock-File" >nul 2>&1
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0NightCityInstaller.ps1"
