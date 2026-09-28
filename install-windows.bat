@echo off
REM Double-click launcher for install-windows.ps1
REM Runs the PowerShell installer with the execution policy bypassed for this run only.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1"
pause
