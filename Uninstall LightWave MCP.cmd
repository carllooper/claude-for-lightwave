@echo off
rem Double-click to remove LightWave MCP. Close LightWave first.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\uninstall.ps1" %*
echo.
pause
