@echo off
setlocal
if exist "%~dp0BDArchive.exe" (
  start "" "%~dp0BDArchive.exe" %*
  exit /b
)
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  set "BD_PS=powershell.exe"
) else (
  set "BD_PS=pwsh.exe"
)
"%BD_PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\archive-ui.ps1" %*
if errorlevel 1 pause
