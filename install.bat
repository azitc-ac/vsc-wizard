@echo off
REM Installs VSC-Wizard on this PC (same as "VscWizard.exe -Install"): program folder in
REM %%ProgramFiles%%\VSC-Wizard, scheduled tasks, Start menu entry. Asks for admin rights (UAC)
REM and reports the result in a window. Save the settings first (VscWizard.exe without
REM parameters, detect PKI) - the config.psd1 from this folder is installed along.
REM Keep this file ASCII-only: non-ASCII characters break cmd's batch parsing.
echo VSC-Wizard wird installiert - bitte die UAC-Abfrage mit Ja beantworten ...
echo Installing VSC-Wizard - please answer the UAC prompt with Yes ...
if exist "%~dp0VscWizard.exe" (
    start "" /wait "%~dp0VscWizard.exe" -Install
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VscWizard.ps1" -Install
)
exit /b %ERRORLEVEL%
