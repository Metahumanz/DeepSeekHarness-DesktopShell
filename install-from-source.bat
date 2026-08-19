@echo off
setlocal
where pwsh >nul 2>nul
if not errorlevel 1 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Desktop.ps1" %*
  goto :done
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Desktop.ps1" %*
:done
pause
