@echo off
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
  echo [DSH Desktop] PowerShell 7 is required.
  echo Download: https://github.com/PowerShell/PowerShell/releases
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-FromGitHub.ps1" %*
pause
