# Ablauftest: lädt VscWizard.ps1 ohne Anzeige, spielt alle Szenarien mit Skript-Antworten
# durch (Weiter/Zurück) und meldet jeden PowerShell-Laufzeitfehler. Keine UAC/PIN/CA-
# Aktionen: Erstellen/Anfordern werden über die Zustands-Flags simuliert. Die Resume-
# Datei des Benutzers wird gesichert und wiederhergestellt.
#
# Aufruf (Windows PowerShell 5.1, STA):  powershell.exe -STA -File .\tests\Test-Flows.ps1
param([string]$Repo)
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
$global:Log = New-Object System.Collections.Generic.List[string]
$global:Errors = New-Object System.Collections.Generic.List[string]
$global:Msgs = New-Object System.Collections.Generic.List[string]

$global:ClickInDialog = $null   # Button-Text, der im nächsten Dialog geklickt werden soll
function global:Invoke-HarnessDialog($d) {
    if ($d -is [System.Windows.Forms.Form]) {
        if ($global:ClickInDialog) {
            $onClick = [System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance')
            $stack = New-Object System.Collections.Stack; $stack.Push($d)
            while ($stack.Count) {
                $c = $stack.Pop(); foreach ($k in $c.Controls) { $stack.Push($k) }
                if ($c -is [System.Windows.Forms.Button] -and $c.Text -eq $global:ClickInDialog) {
                    $global:Log.Add("    (Dialog '$($d.Text)': Klick '$($c.Text)')")
                    $onClick.Invoke($c, @([EventArgs]::Empty))
                }
            }
            $global:ClickInDialog = $null
        }
        $global:Log.Add("    (Dialog '$($d.Text)' -> Abbrechen)"); $d.Dispose()
    }
    return [System.Windows.Forms.DialogResult]::Cancel
}
function global:Invoke-HarnessMsgBox {
    $a = @($args[0])
    if ($a.Count -gt 0 -and $a[0] -is [System.Windows.Forms.IWin32Window]) { $a = @($a | Select-Object -Skip 1) }
    $text = "$($a[0])"; $title = "$($a[1])"; $buttons = "$($a[2])"
    $global:Msgs.Add("[$title] $($text -replace '\s+', ' ')")
    $global:Log.Add("    (MessageBox '$title' [$buttons])")
    if ($buttons -match 'YesNo') { return $global:MsgAnswer }
    return [System.Windows.Forms.DialogResult]::OK
}
function global:Invoke-HarnessInputBox { $global:Log.Add('    (InputBox -> leer)'); return '' }
$global:MsgAnswer = [System.Windows.Forms.DialogResult]::No

$src = [IO.File]::ReadAllText((Join-Path $Repo 'VscWizard.ps1'), [Text.Encoding]::UTF8)
$src = $src.Replace('$script:BaseDir = $PSScriptRoot', "`$script:BaseDir = '$Repo'")
$idx = $src.LastIndexOf('[void]$form.ShowDialog()')
$src = $src.Substring(0, $idx) + '# (Test: kein ShowDialog)' + $src.Substring($idx + '[void]$form.ShowDialog()'.Length)
$src = [regex]::Replace($src, '\$dlg\.ShowDialog\([^)]*\)', '(Invoke-HarnessDialog $dlg)')
$src = $src.Replace('[System.Windows.Forms.MessageBox]::Show(', 'Invoke-HarnessMsgBox(')
$src = $src.Replace('[Microsoft.VisualBasic.Interaction]::InputBox(', 'Invoke-HarnessInputBox(')

$stateMethod = [System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance')
function OwnVisible($c) { return [bool]$stateMethod.Invoke($c, @(2)) }
$onClick = [System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'NonPublic,Instance')
function Click($b) { $onClick.Invoke($b, @([EventArgs]::Empty)) }
. ([scriptblock]::Create($src))
Close-Splash

# Resume-Datei des Benutzers sichern (Tests dürfen sie nicht verändern)
$resumePath = Get-WizardResumeStatePath
$resumeBackup = if (Test-Path $resumePath) { [IO.File]::ReadAllBytes($resumePath) } else { $null }
# Auch bei Abbruch (Strg+C/Fehler) wiederherstellen.
$restoreResume = {
    if ($resumeBackup) { [IO.File]::WriteAllBytes($resumePath, $resumeBackup) } else { Remove-Item $resumePath -ErrorAction SilentlyContinue }
}
trap { & $restoreResume; break }

# Dialog-Antworten per Skript
$global:NextChoice = 'new'
function Show-AccountInputDialog { param([string]$Prefill, [string]$Prompt) $global:Log.Add("    (Konto-Dialog -> jdoe@contoso.com)"); return 'jdoe@contoso.com' }
function Show-VscChoiceDialog { $global:Log.Add("    (VSC-Wahl -> $($global:NextChoice))"); return $global:NextChoice }
function Show-VscPickerDialog { param($Readers, $Certs) $r = @($Readers)[0]; $global:Log.Add("    (VSC-Picker -> $($r.FriendlyName))"); return $r }

function Step([string]$Name, [scriptblock]$Action) {
    $before = $Error.Count
    $Error.Clear()
    $global:Log.Add("  > $Name")
    try { & $Action } catch { $global:Errors.Add("[$Name] AUSNAHME: $($_.Exception.Message)  @ $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())") }
    foreach ($e in @($Error)) {
        $ln = if ($e.InvocationInfo) { "$($e.InvocationInfo.ScriptLineNumber): $($e.InvocationInfo.Line.Trim())" } else { '' }
        $global:Errors.Add("[$Name] FEHLER: $($e.Exception.Message)  @ $ln")
    }
    $Error.Clear()
}

function Walk-PlanA([string]$Label) {
    for ($k = 0; $k -lt 4; $k++) {
        Step "$Label A-Schritt $($script:PlanACurrentStep): Weiter (Gate zu)" { Invoke-PlanANextClick }
        $script:PlanA_VscCreated = $true; $script:PlanA_CertIssued = $true
        if (-not $script:PlanA_PcscName) { $script:PlanA_PcscName = 'Microsoft Virtual Smart Card 2'; $script:PlanA_CardName = 'VSC--jdoe' }
        Step "$Label A-Schritt $($script:PlanACurrentStep): Weiter (Gate offen)" { Invoke-PlanANextClick }
    }
    for ($k = 0; $k -lt 4 -and (OwnVisible $tabPlanA); $k++) { Step "$Label A: Zurück" { Invoke-PlanABackClick } }
}
function Walk-PlanB([string]$Label) {
    for ($k = 0; $k -lt 7; $k++) {
        Step "$Label B-Schritt $($script:PlanBCurrentStep): Weiter (Gate zu)" { Invoke-PlanBNextClick }
        $script:PlanB_VscCreated = $true; $script:PlanB_CsrPath = 'C:\x\request.req'
        if (-not $script:PlanB_PcscName) { $script:PlanB_PcscName = 'Microsoft Virtual Smart Card 2'; $script:PlanB_CardName = 'VSC--jdoe' }
        $global:MsgAnswer = [System.Windows.Forms.DialogResult]::Yes
        Step "$Label B-Schritt $($script:PlanBCurrentStep): Weiter (Gate offen)" { Invoke-PlanBNextClick }
        $global:MsgAnswer = [System.Windows.Forms.DialogResult]::No
    }
    for ($k = 0; $k -lt 8 -and (OwnVisible $tabPlanB); $k++) { Step "$Label B: Zurück" { Invoke-PlanBBackClick } }
}

function Reset-Run {
    $tabPlanA.Visible = $false; $tabPlanB.Visible = $false
    $script:PlanA_VscCreated = $false; $script:PlanA_CertIssued = $false; $script:PlanA_PcscName = $null
    $script:PlanB_VscCreated = $false; $script:PlanB_CsrPath = $null; $script:PlanB_PcscName = $null
    Show-ScenarioStep
}

Step 'Startseite anzeigen' { Show-ScenarioStep }
Step 'Weiter ohne Auswahl' { $script:SelectedScenario = $null; Invoke-ScenarioNextClick }

foreach ($scn in 1, 2, 3, 5) {
    foreach ($choice in 'new', 'existing') {
        if ($scn -eq 5 -and $choice -eq 'existing') { continue }
        $label = "Szenario $scn/$choice"
        $global:Log.Add("=== $label ===")
        $global:NextChoice = $choice
        Reset-Run
        Step "$label wählen" { Select-ScenarioById -Id $scn }
        $script:ScnAvailable[$scn] = $true
        Step "$label Weiter" { Invoke-ScenarioNextClick }
        if ((OwnVisible $tabPlanA)) { Walk-PlanA $label }
        elseif ((OwnVisible $tabPlanB)) { Walk-PlanB $label }
        else { $global:Log.Add("    (kein Plan geöffnet)") }
    }
}
$global:Log.Add('=== Szenario 4 ===')
Reset-Run
Step 'Szenario 4 wählen+Weiter' { Select-ScenarioById -Id 4; Invoke-ScenarioNextClick }

# Plan B für das eigene Konto (ohne Zielkonto) direkt
$global:Log.Add('=== Plan B eigenes Konto ===')
Reset-Run; $script:TargetAccount = $null
Step 'Enter-Plan B' { Enter-Plan -Plan 'B' }
Walk-PlanB 'PlanB-eigen'

# Zusammenfassungen mit ECHTEN Karten/Zertifikaten dieses Rechners
$global:Log.Add('=== Zusammenfassungen (echte Daten) ===')
foreach ($r in @(Get-VirtualSmartCardReaders | Where-Object PcscName)) {
    Step "Zusammenfassung $($r.FriendlyName)" { $null = Get-CardValiditySummaryText -CardName $r.FriendlyName -PcscName $r.PcscName -MatchTerm 'x' }
}

# Einstellungen: wartenden EA-Antrag abrufen ohne bekannte ID (InputBox leer -> Abbruch)
$global:Log.Add('=== Einstellungen ===')
$global:ClickInDialog = 'Wartenden EA-Antrag abrufen...'
Step 'EA-Abruf ohne ID' { Show-SettingsDialog -Owner $form }

# Fortsetzen-Dialog (Resume) mit simuliertem wartendem Antrag ohne ID (wie Antrag 932)
$global:Log.Add('=== Resume ===')
Save-WizardResumeState -State @{ Plan = 'A'; Stage = 'Pending'; RequestId = ''; CardName = 'VSC--jdoe'; PcscName = 'Microsoft Virtual Smart Card 2'; EnrollDir = "$env:TEMP\VscWizard\x" }
$global:MsgAnswer = [System.Windows.Forms.DialogResult]::Yes
Reset-Run
Step 'Resume (Ja)' { Invoke-WizardResume }
# Wartender Antrag: 'Zertifikat anfordern' muss gesperrt sein (sonst zweiter Antrag mit neuem Schlüssel).
if ($btnRequestCertA.Enabled) { $global:Errors.Add('[Resume] Zertifikat anfordern ist trotz wartendem Antrag aktiv') }
if (-not (OwnVisible $btnRetrieveA)) { $global:Errors.Add('[Resume] Zertifikat abrufen ist nicht sichtbar') }
# Was auf der CA zu tun ist, muss auch nach dem Fortsetzen dastehen (fehlte dort früher).
if ($lblCertResultA.Text -notmatch 'certutil -resubmit') { $global:Errors.Add("[Resume] Genehmigungs-Hinweis (certutil -resubmit) fehlt: '$($lblCertResultA.Text)'") }
Step 'Abrufen ohne ID (InputBox leer)' { Click $btnRetrieveA }

# Resume-Datei des Benutzers wiederherstellen
& $restoreResume

"=== Ablauf ==="
$global:Log
""
"=== Meldungsboxen ($($global:Msgs.Count)) ==="
$global:Msgs | Select-Object -Unique
""
"=== FEHLER ($($global:Errors.Count)) ==="
$global:Errors | Select-Object -Unique
