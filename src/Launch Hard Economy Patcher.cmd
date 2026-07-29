@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0HardModePatcher.ps1" -Action Gui
if errorlevel 1 (
  echo.
  echo Hard Economy Patcher could not start.
  echo Press any key to close this window.
  pause >nul
)
endlocal
