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
# Batch-Dateien (install.bat, VscWizard.bat): nur ASCII. Umlaute (zusammen mit chcp 65001)
# verschieben cmds Leseposition - Befehle werden dann zerstueckelt ("REM" -> "M").
foreach ($bat in Get-ChildItem -Path $Repo -Filter *.bat) {
    if (@([IO.File]::ReadAllBytes($bat.FullName) | Where-Object { $_ -gt 127 }).Count) { $errors += "NICHT-ASCII: $($bat.Name) (cmd zerlegt die Zeilen)" }
}
# Einreichungshelfer (eigenständig, ohne Kernmodul): die Template-Auswahl ist eine 1:1-Kopie
# aus VscWizard.Core.psm1 und muss identisch bleiben.
foreach ($fn in 'Get-CertificateTemplateDetails', 'Select-SmartCardTemplates') {
    $texts = foreach ($f in 'modules\VscWizard.Core.psm1', 'VscWizard.Submit.ps1') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo $f), [ref]$null, [ref]$null)
        $d = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $fn }, $true)
        if ($d) { $d.Extent.Text -replace '\r\n', "`n" } else { $null }
    }
    if (-not $texts[0] -or -not $texts[1]) { $errors += "FEHLT: $fn in Kernmodul oder Einreichungshelfer" }
    elseif ($texts[0] -ne $texts[1]) { $errors += "ABWEICHUNG: $fn unterscheidet sich zwischen VscWizard.Core.psm1 und VscWizard.Submit.ps1" }
}
if ($errors.Count) { $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }; exit 1 }
Write-Host 'config.psd1: keine org-spezifischen Werte - OK' -ForegroundColor Green
exit 0
