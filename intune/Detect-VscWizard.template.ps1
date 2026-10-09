# Intune-Erkennungsskript für die VSC-Wizard-Geräte-App (VscWizard.exe -Install).
# Intune wertet eine App als installiert, wenn das Skript mit 0 endet UND etwas ausgibt.
#
# VORLAGE - nicht direkt hochladen! build.ps1 schreibt eine Kopie mit der gebauten Version nach
# dist\intune\Detect-VscWizard.ps1 - DIESE Kopie zum jeweiligen Paket in Intune
# hochladen. Erkannt wird nur "installierte Version >= erwartete Version": ein neues Paket
# erkennt die ältere Installation als fehlend, Intune installiert drüber (Update ohne
# Deinstallation/Ersatzkette); eine neuere Installation bleibt unangetastet.
# Steht unten noch der Platzhalter, wird nur das Vorhandensein geprüft.
$ExpectedVersion = '__VSCWIZARD_VERSION__'

# Bewusst unabhängig von der Bitbreite: Intune führt Erkennungsskripte standardmäßig als
# 32-Bit-Prozess aus - dann würden HKLM\SOFTWARE und $env:ProgramFiles umgeleitet.
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$key = $hklm.OpenSubKey('SOFTWARE\VSC-Wizard')
$installed = if ($key) { "$($key.GetValue('ServiceVersion'))" } else { '' }
$programFiles = if (${env:ProgramW6432}) { ${env:ProgramW6432} } else { $env:ProgramFiles }
$exe = Join-Path $programFiles 'VSC-Wizard\VscWizard.exe'
$task = Get-ScheduledTask -TaskName 'VSC-Wizard CreateCard' -ErrorAction SilentlyContinue
if (-not ($installed -and (Test-Path $exe) -and $task)) { exit 0 }   # nicht (vollständig) installiert

if ($ExpectedVersion -notlike '__*__') {
    $have = $null; $want = $null
    if (-not ([version]::TryParse($installed, [ref]$have)) -or -not ([version]::TryParse($ExpectedVersion, [ref]$want))) { exit 0 }
    if ($have -lt $want) { exit 0 }   # ältere Version -> Intune installiert das Update
}
Write-Output "VSC-Wizard $installed installiert"
exit 0
