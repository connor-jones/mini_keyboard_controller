@echo off
REM Double-click launcher for the configurator.
REM -STA is required for WPF; -WindowStyle Hidden keeps the console out of the way.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0macropad-gui.ps1" %*
