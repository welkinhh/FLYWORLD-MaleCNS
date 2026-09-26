@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0FLYWORLD.exe" (
  start "" "%~dp0FLYWORLD.exe" %*
  exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_flyworld.ps1"
if errorlevel 1 (
  echo FLYWORLD failed to start. See the error above.
  pause
)
endlocal
