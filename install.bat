@echo off
chcp 65001 >nul
REM Installiert den VSC-Wizard auf diesem PC (wie "VscWizard.exe -Install"):
REM Programm nach %%ProgramFiles%%\VSC-Wizard, Aufgaben, Startmenü. Fragt per UAC nach
REM Adminrechten und meldet das Ergebnis in einem Fenster.
REM Vorher die Einstellungen speichern (VscWizard.exe ohne Parameter, PKI erkennen) -
REM die config.psd1 aus diesem Ordner wird mitinstalliert.
echo VSC-Wizard wird installiert - bitte die Abfrage der Benutzerkontensteuerung bestätigen ...
if exist "%~dp0VscWizard.exe" (
    start "" /wait "%~dp0VscWizard.exe" -Install
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VscWizard.ps1" -Install
)
exit /b %ERRORLEVEL%