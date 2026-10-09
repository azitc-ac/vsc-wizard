# Intune-Erkennungsskript für die VSC-Wizard-Geräte-App (VscWizard.exe -Install).
# Intune wertet eine App als installiert, wenn das Skript mit 0 endet UND etwas ausgibt.
# Bewusst unabhängig von der Bitbreite: Intune führt Erkennungsskripte standardmäßig als
# 32-Bit-Prozess aus - dann würden HKLM\SOFTWARE und $env:ProgramFiles umgeleitet.
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$key = $hklm.OpenSubKey('SOFTWARE\VSC-Wizard')
$version = if ($key) { $key.GetValue('ServiceVersion') } else { $null }
$programFiles = if (${env:ProgramW6432}) { ${env:ProgramW6432} } else { $env:ProgramFiles }
$exe = Join-Path $programFiles 'VSC-Wizard\VscWizard.exe'
$task = Get-ScheduledTask -TaskName 'VSC-Wizard CreateCard' -ErrorAction SilentlyContinue

if ($version -and (Test-Path $exe) -and $task) {
    Write-Output "VSC-Wizard $version installiert"
}
exit 0
