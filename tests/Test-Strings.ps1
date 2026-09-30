# Übersetzungs-Check: sammelt per AST alle Texte in (T '...')-Aufrufen aus Oberfläche und
# Kernmodul und vergleicht sie mit modules\VscWizard.Strings.en.psd1.
#   FEHLT     = Text ohne englische Übersetzung (erscheint auf Englisch deutsch)
#   UNBENUTZT = Übersetzung ohne Verwendung (z.B. nach Textänderung - Eintrag nachziehen)
#   PLATZHALTER = {0}/{1}... in Übersetzung und Original verschieden
#
# Aufruf:  powershell.exe -File .\tests\Test-Strings.ps1 [-ListMissing]
param([string]$Repo, [switch]$ListMissing)
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

$keys = @{}
foreach ($rel in 'VscWizard.ps1', 'modules\VscWizard.Core.psm1') {
    $path = Join-Path $Repo $rel
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'T' }, $true)) {
        $arg = $c.CommandElements | Select-Object -Skip 1 -First 1
        if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            if (-not $keys.ContainsKey($arg.Value)) { $keys[$arg.Value] = "$rel`:$($arg.Extent.StartLineNumber)" }
        }
    }
    # Enter-WizardBusy übersetzt seinen -Text selbst (T $Text).
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Enter-WizardBusy' }, $true)) {
        $els = $c.CommandElements
        for ($i = 1; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Text' -and $els[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $v = $els[$i + 1].Value; if (-not $keys.ContainsKey($v)) { $keys[$v] = "$rel`:$($els[$i + 1].Extent.StartLineNumber)" }
            }
        }
    }
}
# Zur Laufzeit übersetzte Werte (T $variable): Rollen im Szenario-Ablauf.
foreach ($d in 'Du', 'Tool', 'Prüfung') { if (-not $keys.ContainsKey($d)) { $keys[$d] = 'dynamisch (Szenario-Ablauf)' } }

$dictPath = Join-Path $Repo 'modules\VscWizard.Strings.en.psd1'
$dict = if (Test-Path $dictPath) { Import-PowerShellDataFile -Path $dictPath } else { @{} }

$missing = @($keys.Keys | Where-Object { -not $dict.ContainsKey($_) } | Sort-Object)
$unused = @($dict.Keys | Where-Object { -not $keys.ContainsKey($_) } | Sort-Object)
$placeholder = @($keys.Keys | Where-Object { $dict.ContainsKey($_) } | Where-Object {
    $a = @([regex]::Matches($_, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
    $b = @([regex]::Matches($dict[$_], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
    $a -ne $b
})

# Unübersetzte deutsche Texte im GANZEN Oberflächen-Code (auch vor dem Modul-Import,
# z.B. Splash): Zeichenketten mit deutschen Merkmalen, die weder in T/L noch im
# Protokoll (Write-WizardLog) stehen. Fand z.B. den Splash-Untertitel.
$germanRe = '[äöüÄÖÜß]|\b(der|die|das|und|oder|nicht|wird|bitte|mit|für|auf|keine?|Starte|Weiter)\b|\b(Virtuell|Zertifikat|Smartcard|Karte|Antr[aä]g|Schl[üu]ssel|[Ee]rstell|abgebrochen|Fehler|wählen|laden|lesen|Einstellung|Zurück|Szenario|Schritt|Konto)'
$skipCmds = @('T', 'L', 'Write-WizardLog', 'Write-Host', 'Write-Verbose', 'Join-Path', 'Get-Item', 'New-Object', 'Add-Type', 'Import-Module', 'Get-CimInstance', 'Set-Content', 'Get-Content', 'Select-String')
$untranslated = New-Object System.Collections.Generic.List[string]
foreach ($rel in 'VscWizard.ps1') {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo $rel), [ref]$tokens, [ref]$errs)
    foreach ($n in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $x -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        if ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'BareWord') { continue }
        if ($n.Extent.Text -notmatch $germanRe) { continue }
        # Technische Bezeichner in Großbuchstaben (z.B. 'ROOT\SMARTCARDREADER\*') sind kein UI-Text.
        if ($n.Value -cmatch '^[A-Z0-9_\\*]+$') { continue }
        # Rollen im Szenario-Ablauf sind Nachschlage-Schlüssel und werden bei der Anzeige übersetzt (T $st.T).
        if ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -in @('Du', 'Tool', 'Prüfung')) { continue }
        $p = $n.Parent; $skip = $false
        while ($p) {
            if ($p -is [System.Management.Automation.Language.CommandAst] -and ($skipCmds -contains $p.GetCommandName())) { $skip = $true; break }
            # Provisionierungs-Protokoll (& $plog '...'): bewusst deutsch wie Write-WizardLog.
            if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $p.CommandElements[0].VariablePath.UserPath -eq 'plog') { $skip = $true; break }
            if ($p -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $p -ne $n) { $skip = $true; break }
            # Bewusst deutsch/zweisprachig: Sprachwechsel-Rückfrage, Protokoll-Variablen ($msg für Log)
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $p.Name -in @('Switch-WizardLanguage', 'L')) { $skip = $true; break }
            $p = $p.Parent
        }
        if ($skip) { continue }
        $untranslated.Add("$rel`:$($n.Extent.StartLineNumber)  $(($n.Extent.Text -replace "`r?`n", ' | ').Substring(0, [Math]::Min(110, $n.Extent.Text.Length)))")
    }
}

"Texte im Code: $($keys.Count)  |  Übersetzungen: $($dict.Count)"
"UNÜBERSETZT (deutscher Text ohne T/L): $($untranslated.Count)"
foreach ($u in $untranslated) { "  UNÜBERSETZT  $u" }
"FEHLT: $($missing.Count)  UNBENUTZT: $($unused.Count)  PLATZHALTER: $($placeholder.Count)"
if ($ListMissing) { foreach ($m in $missing) { "  FEHLT  [$($keys[$m])]  $m" } }
foreach ($u in $unused) { "  UNBENUTZT  $u" }
foreach ($p in $placeholder) { "  PLATZHALTER  $p" }
