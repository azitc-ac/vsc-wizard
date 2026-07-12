@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VscWizard.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo VSC-Wizard wurde mit Fehlercode %ERRORLEVEL% beendet.
    pause
)
