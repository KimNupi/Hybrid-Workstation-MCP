@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Configure-Tunnel.ps1"
if errorlevel 1 pause
