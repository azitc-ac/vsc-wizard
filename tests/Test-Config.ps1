# Auslieferungs-Check: config.psd1 muss ohne org-spezifische Werte im Repo liegen
# (README: "config.psd1 wird leer ausgeliefert"). Speichern im Einstellungen-Dialog
# schreibt in genau diese Datei - so landen echte CA-/Server-Namen sonst im Commit.
#
# Aufruf:  powershell.exe -File .\tests\Test-Config.ps1
param([string]$Repo)
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

$cfg = Import-PowerShellDataFile -Path (Join-Path $Repo 'config.psd1')
$errors = @()
foreach ($k in 'Template', 'OfflineTemplate', 'CAConfig', 'DiscoveryDomain', 'RdpJumpServer', 'WorkingDir') {
    if (-not $cfg.ContainsKey($k)) { $errors += "FEHLT: Schluessel '$k' nicht in config.psd1"; continue }
    if ("$($cfg[$k])" -ne '') { $errors += "BEFUELLT: $k = '$($cfg[$k])' (vor dem Commit leeren)" }
}
if ($errors.Count) { $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }; exit 1 }
Write-Host 'config.psd1: keine org-spezifischen Werte - OK' -ForegroundColor Green
exit 0
