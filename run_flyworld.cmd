@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0FLYWORLD.exe" (
  start "" "%~dp0FLYWORLD.exe" %*
  exit /b 0
)
echo FLYWORLD.exe was not found beside this script.
echo This source folder does not include the playable executable.
echo Download and extract the Windows release:
echo https://github.com/welkinhh/FLYWORLD-MaleCNS/releases/latest
echo Then run FLYWORLD.exe beside brain_service.exe.
echo Running from source requires Godot 4.7; launch run_flyworld.ps1 manually.
pause
exit /b 1
endlocal
