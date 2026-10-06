# Auslieferungs-Check: config.psd1 muss ohne org-spezifische Werte im Repo liegen
# (README: "config.psd1 wird leer ausgeliefert"). Speichern im Einstellungen-Dialog
# schreibt in genau diese Datei - so landen echte CA-/Server-Namen sonst im Commit.
#
# Prüft außerdem, dass der Wizard nur in %APPDATA% speichert (Get-VscUserConfigPath).
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

# Ebenen-Check: Speichern darf die Basisdatei NIE anfassen, sondern schreibt nur die
# abweichenden Schlüssel in die Benutzerdatei; Laden legt die Benutzerwerte darüber.
Import-Module (Join-Path $Repo 'modules\VscWizard.Core.psm1') -Force -ErrorAction Stop 3>$null
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("vscw-cfgtest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $basePath = Join-Path $tmp 'config.psd1'
    $userPath = Join-Path $tmp 'user\config.psd1'
    Set-Content -Path $basePath -Encoding UTF8 -Value "@{`r`n    CAConfig = 'base\CA'`r`n    Template = 'BaseTpl'`r`n    CspName = 'KSP'`r`n}"
    $before = Get-Content -Path $basePath -Raw

    $c = Import-VscWizardConfig -Path $basePath -UserPath $userPath
    if ($c.CAConfig -ne 'base\CA') { $errors += "EBENEN: Basiswert nicht geladen ('$($c.CAConfig)')" }
    $c['Template'] = 'UserTpl'; $c['Language'] = 'en'
    Save-VscWizardConfig -Config $c

    if ((Get-Content -Path $basePath -Raw) -ne $before) { $errors += 'EBENEN: Speichern hat die Basisdatei verändert' }
    if (-not (Test-Path $userPath)) { $errors += 'EBENEN: Benutzerdatei wurde nicht angelegt' }
    else {
        $u = Import-PowerShellDataFile -Path $userPath
        if (@($u.Keys | Sort-Object) -join ',' -ne 'Language,Template') { $errors += "EBENEN: Benutzerdatei enthält nicht nur die Abweichungen ($(@($u.Keys | Sort-Object) -join ','))" }
    }
    $c2 = Import-VscWizardConfig -Path $basePath -UserPath $userPath
    if ($c2.Template -ne 'UserTpl' -or $c2.CAConfig -ne 'base\CA' -or $c2.Language -ne 'en') { $errors += 'EBENEN: Zusammenführung Basis + Benutzer falsch' }
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($errors.Count) { $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }; exit 1 }
Write-Host 'config.psd1: keine org-spezifischen Werte, Speichern nur in die Benutzerdatei - OK' -ForegroundColor Green
exit 0
