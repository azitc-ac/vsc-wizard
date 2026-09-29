@echo off
REM Argumente (z.B. -Simple, -Provision -Silent) werden mit %* an das Skript
REM weitergereicht, damit der Intune-/Silent-Modus auch ueber die .bat funktioniert.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VscWizard.ps1" %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo VSC-Wizard wurde mit Fehlercode %ERRORLEVEL% beendet.
    pause
)
