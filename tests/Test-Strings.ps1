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

"Texte im Code: $($keys.Count)  |  Übersetzungen: $($dict.Count)"
"FEHLT: $($missing.Count)  UNBENUTZT: $($unused.Count)  PLATZHALTER: $($placeholder.Count)"
if ($ListMissing) { foreach ($m in $missing) { "  FEHLT  [$($keys[$m])]  $m" } }
foreach ($u in $unused) { "  UNBENUTZT  $u" }
foreach ($p in $placeholder) { "  PLATZHALTER  $p" }
