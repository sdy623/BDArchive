@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  set "BD_PS=powershell.exe"
) else (
  set "BD_PS=pwsh.exe"
)
"%BD_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\list-drives.ps1" %*
set "BD_EXIT=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %BD_EXIT%
