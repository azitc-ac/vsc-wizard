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
# Hybrid-Prüfung (Szenario 03) unabhängig vom erreichbaren AD: Standard "AD nicht erreichbar".
$global:OnPremAnswer = $null
function Find-OnPremAccountByUpn { param([string]$Upn, [string]$Domain) $global:Log.Add("    (AD-Suche $Upn -> $(if ($global:OnPremAnswer) { 'gefunden' } else { 'nicht erreichbar' }))"); return $global:OnPremAnswer }

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

# Szenario 03 mit Hybrid-Konto: "Ja" muss zu Szenario 01 wechseln (Zielkonto bleibt,
# kein Offline-Template), "Nein" bleibt bei 03 (Offline-Template).
$global:OnPremAnswer = [pscustomobject]@{ Found = $true; Domain = 'contoso.local'; DistinguishedName = 'CN=jdoe,OU=Tier2,DC=contoso,DC=local'; SamAccountName = 'jdoe' }
foreach ($ans in 'Yes', 'No') {
    $global:Log.Add("=== Szenario 3 Hybrid -> $ans ===")
    $global:NextChoice = 'new'
    Reset-Run
    Select-ScenarioById -Id 3; $script:ScnAvailable[1] = $true; $script:ScnAvailable[3] = $true
    $global:MsgAnswer = [System.Windows.Forms.DialogResult]::$ans
    Step "Szenario 3 Hybrid ($ans)" { Invoke-ScenarioNextClick }
    $global:MsgAnswer = [System.Windows.Forms.DialogResult]::No
    $planOpen = (OwnVisible $tabPlanA) -or (OwnVisible $tabPlanB)
    if ($ans -eq 'Yes') {
        if ($script:SelectedScenario -ne 1) { $global:Errors.Add("[Hybrid Ja] nicht zu Szenario 01 gewechselt (SelectedScenario=$($script:SelectedScenario))") }
        if ($script:PlanA_OfflineDirect) { $global:Errors.Add('[Hybrid Ja] Offline-Template (Szenario 03) noch aktiv') }
    } else {
        if ($script:SelectedScenario -ne 3 -or -not $script:PlanA_OfflineDirect) { $global:Errors.Add("[Hybrid Nein] nicht bei Szenario 03 geblieben (SelectedScenario=$($script:SelectedScenario), OfflineDirect=$($script:PlanA_OfflineDirect))") }
    }
    if (-not $planOpen) { $global:Errors.Add("[Hybrid $ans] kein Plan geöffnet") }
    if ($script:TargetAccount -ne 'jdoe@contoso.com') { $global:Errors.Add("[Hybrid $ans] Zielkonto verloren: '$($script:TargetAccount)'") }
}
$global:OnPremAnswer = $null

# -Simple (Intune-App 2): ohne PIN-Änderung KEINE Ausstellung; mit Änderung Szenario 02
# (eigenes Konto, kein Offline-Template) auf der vorhandenen VSC.
function Select-ExistingVsc { $global:Log.Add('    (VSC-Auswahl -> VSC-TEST)'); return [pscustomobject]@{ FriendlyName = 'VSC-TEST'; PcscName = 'Microsoft Virtual Smart Card 2'; InstanceId = 'ROOT\SMARTCARDREADER\0002' } }
function Show-VscPinChangeDialog { param($Reader, $Owner, [string]$PrefillCurrentPin, [switch]$NumericOnly, [int]$MinNewLength = 4) $global:PinDialogArgs = @{ Prefill = [bool]$PrefillCurrentPin; Numeric = [bool]$NumericOnly; Min = $MinNewLength }; return $global:PinChangedAnswer }
# Kartenerkennung für den Simple-Modus (Find-ProvisionedVsc): Name, einzige Karte, mehrdeutig.
$fr = { param($n, $i) [pscustomobject]@{ FriendlyName = $n; PcscName = "Microsoft Virtual Smart Card $i"; InstanceId = "ROOT\SMARTCARDREADER\TEST$i" } }
$exp = 'VSC-TESTPC'
$r1 = Find-ProvisionedVsc -Readers @((& $fr 'VSC--alex' 1), (& $fr $exp 2), (& $fr 'GAVSC' 3)) -ExpectedName $exp
if (-not $r1 -or $r1.Reader.FriendlyName -ne $exp) { $global:Errors.Add("[Kartenerkennung] Provisionierte Karte unter mehreren nicht per Name gefunden") }
$r2 = Find-ProvisionedVsc -Readers @((& $fr 'VSC--alex' 1), (& $fr 'GAVSC' 3)) -ExpectedName $exp
if ($r2) { $global:Errors.Add("[Kartenerkennung] mehrdeutig, aber '$($r2.Reader.FriendlyName)' gewählt ($($r2.Reason))") }
$r3 = Find-ProvisionedVsc -Readers @((& $fr 'Irgendwas' 1)) -ExpectedName $exp
if (-not $r3) { $global:Errors.Add('[Kartenerkennung] einzige Karte nicht gewählt') }
if (Find-ProvisionedVsc -Readers @() -ExpectedName $exp) { $global:Errors.Add('[Kartenerkennung] ohne Karten etwas gewählt') }

# Variante 1: Kartenzustand (eigenes Zertifikat / fremdes / nur Schlüssel / leer / unbekannt).
$occMe = [pscustomobject]@{ Container = 'a'; HasCertificate = $true; Subject = 'CN=me'; Upn = 'me@contoso.com'; NotAfter = (Get-Date).AddYears(1) }
$occOther = [pscustomobject]@{ Container = 'b'; HasCertificate = $true; Subject = 'CN=other'; Upn = 'other@contoso.com'; NotAfter = (Get-Date).AddYears(1) }
$occKey = [pscustomobject]@{ Container = 'c'; HasCertificate = $false; Subject = $null; Upn = $null; NotAfter = $null }
foreach ($case in @(
    @{ Occ = @($occMe, $occKey); Want = 'Own' }, @{ Occ = @($occOther); Want = 'Other' }, @{ Occ = @($occOther, $occMe); Want = 'Own' },
    @{ Occ = @($occKey); Want = 'Started' }, @{ Occ = @(); Want = 'Free' }, @{ Occ = $null; Want = 'Unknown' })) {
    $got = (Get-SimpleCardState -Occupancy $case.Occ -CurrentUpn 'me@contoso.com').State
    if ($got -ne $case.Want) { $global:Errors.Add("[Kartenzustand] erwartet $($case.Want), bekommen $got") }
}
# Startseite: bei fremder Belegung gesperrt, bei eigener gesperrt (erledigt), bei 'Started' frei.
# Platzhalter bleibt bis Testende: der Test soll den echten HKCU-Marker NICHT schreiben.
$script:SimpleCardResolved = $true
$script:SimpleCard = [pscustomobject]@{ FriendlyName = 'VSC-TEST'; PcscName = 'Microsoft Virtual Smart Card 2'; InstanceId = 'ROOT\SMARTCARDREADER\0002' }
function Set-VscEnrollMarker { $global:Log.Add('    (HKCU-Marker gesetzt)'); $true }
foreach ($case in @(@{ S = 'Other'; E = $occOther; Enabled = $false }, @{ S = 'Own'; E = $occMe; Enabled = $false }, @{ S = 'Started'; E = $null; Enabled = $true }, @{ S = 'Free'; E = $null; Enabled = $true })) {
    $script:SimpleCardState = [pscustomobject]@{ State = $case.S; Entry = $case.E }
    Step "Simple-Startseite ($($case.S))" { Show-SimpleStart }
    if ($btnSimpleStart.Enabled -ne $case.Enabled) { $global:Errors.Add("[Simple-Start $($case.S)] Start-Knopf aktiv=$($btnSimpleStart.Enabled), erwartet $($case.Enabled)") }
}
$script:SimpleCardState = $null
# Startseite mit ECHTER Erkennung (ohne Vorbelegung): was immer gefunden wird, muss ein
# Kartenleser sein. (Fand die Kollision $simpleCard-Panel == $script:SimpleCard.)
# Bewusst NICHT $script:SimpleCard leeren: der Test soll den echten Startzustand sehen.
$script:SimpleCardResolved = $false
Step 'Simple-Startseite (echte Erkennung)' { Show-SimpleStart }
if ($script:SimpleCard -and -not $script:SimpleCard.PSObject.Properties['PcscName']) { $global:Errors.Add("[Simple-Start] erkannte 'Karte' ist kein Kartenleser: $($script:SimpleCard.GetType().FullName)") }
if (-not $script:SimpleCard -and $lblSimpleCard.Text -match '\(\S*:\s*\)') { $global:Errors.Add("[Simple-Start] Kartenzeile ohne Karte: '$($lblSimpleCard.Text)'") }
$global:Log.Add("    (echte Erkennung: $($lblSimpleCard.Text))")
# Startseite: Simple-Karte gesetzt -> Start möglich; keine Karte -> Start gesperrt.
$script:SimpleCardResolved = $true
$script:SimpleCard = [pscustomobject]@{ FriendlyName = 'VSC-TEST'; PcscName = 'Microsoft Virtual Smart Card 2'; InstanceId = 'ROOT\SMARTCARDREADER\0002' }
Step 'Simple-Startseite (Karte erkannt)' { Show-SimpleStart }
if (-not $btnSimpleStart.Enabled) { $global:Errors.Add('[Simple-Start] trotz erkannter Karte gesperrt') }
if ((OwnVisible $pnlScenario) -or -not (OwnVisible $pnlSimple)) { $global:Errors.Add('[Simple-Start] Szenario-Übersicht statt Simple-Startseite sichtbar') }
$script:SimpleCard = $null; $script:SimpleReaderCount = 0
Step 'Simple-Startseite (keine Karte)' { Show-SimpleStart }
if ($btnSimpleStart.Enabled) { $global:Errors.Add('[Simple-Start] ohne Karte nicht gesperrt') }
$script:SimpleCard = [pscustomobject]@{ FriendlyName = 'VSC-TEST'; PcscName = 'Microsoft Virtual Smart Card 2'; InstanceId = 'ROOT\SMARTCARDREADER\0002' }
foreach ($pinChanged in $false, $true) {
    $global:Log.Add("=== Simple-Modus, PIN geändert: $pinChanged ===")
    Reset-Run
    $global:PinDialogArgs = $null
    $global:PinChangedAnswer = $pinChanged
    Step "Simple (PIN geändert=$pinChanged)" { Enter-SimpleFlow }
    $planOpen = (OwnVisible $tabPlanA) -or (OwnVisible $tabPlanB)
    if (-not $global:PinDialogArgs) { $global:Errors.Add('[Simple] PIN-Dialog wurde nicht gezeigt') }
    elseif (-not ($global:PinDialogArgs.Prefill -and $global:PinDialogArgs.Numeric -and $global:PinDialogArgs.Min -ge 6)) { $global:Errors.Add("[Simple] PIN-Dialog ohne Vorbelegung/numerisch/min 6: $(($global:PinDialogArgs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')") }
    if ($pinChanged) {
        if (-not (OwnVisible $tabPlanA)) { $global:Errors.Add('[Simple] nach PIN-Änderung kein Plan A (Ausstellung) geöffnet') }
        if ($script:TargetAccount -or $script:PlanA_OfflineDirect) { $global:Errors.Add("[Simple] nicht Szenario 02 (TargetAccount='$($script:TargetAccount)', OfflineDirect=$($script:PlanA_OfflineDirect))") }
    } elseif ($planOpen) { $global:Errors.Add('[Simple] Ausstellung gestartet, obwohl die PIN NICHT geändert wurde') }
}

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

# --- Per-Benutzer-Karten (Variante 2): jede Antwort der SYSTEM-Aufgabe muss weiterführen ---
$global:Log.Add('=== Per-Benutzer-Karte ===')
$global:PU = @{ Result = $null; StartErr = $null; SubmitThrows = $false; Submitted = @() }
function Submit-VscCardRequest { param([string]$Type = 'Create', [string]$RequestDir) if ($global:PU.SubmitThrows) { throw 'Zugriff verweigert' }; $global:PU.Submitted += $Type; return 'testreq' }
function Start-VscCardService { param([string]$TaskName) return $global:PU.StartErr }
function Read-VscCardResult { param([string]$Id, [string]$RequestDir) return $global:PU.Result }
function Get-VirtualSmartCardReaders { @([pscustomobject]@{ FriendlyName = 'VSC-alex'; PcscName = 'Microsoft Virtual Smart Card 7'; InstanceId = 'ROOT\SMARTCARDREADER\0007'; Status = 'OK' }) }
function Show-VscPinChangeDialog { param($Reader, $Owner, [string]$PrefillCurrentPin, [switch]$NumericOnly, [int]$MinNewLength = 4) $global:PinDialogArgs = @{ Prefill = $PrefillCurrentPin }; return $global:PinChangedAnswer }
$okCard = @{ Status = 'Created'; CardName = 'VSC-alex'; PcscName = 'Microsoft Virtual Smart Card 7'; InstanceId = 'ROOT\SMARTCARDREADER\0007'; StartPin = '123456789012' }
$cases = @(
    @{ N = 'angelegt + Start-PIN, PIN geändert'; R = $okCard; Pin = $true; WantPlan = $true; WantPinDialog = $true; WantReport = $true }
    @{ N = 'vorhanden, PIN schon eigene'; R = @{ Status = 'Existing'; CardName = 'VSC-alex'; PcscName = 'Microsoft Virtual Smart Card 7'; InstanceId = 'ROOT\SMARTCARDREADER\0007'; StartPin = '' }; Pin = $true; WantPlan = $true; WantPinDialog = $false }
    @{ N = 'PIN-Änderung abgebrochen'; R = $okCard; Pin = $false; WantPlan = $false; WantPinDialog = $true; WantRetry = $true }
    @{ N = 'TPM voll'; R = @{ Status = 'Error'; Code = 'Limit'; Count = '10'; Max = '10' }; WantPlan = $false; WantRetry = $true; WantText = '10' }
    @{ N = 'TPM nicht bereit'; R = @{ Status = 'Error'; Code = 'TpmNotReady' }; WantPlan = $false; WantRetry = $true; WantText = 'TPM' }
    @{ N = 'Erstellung fehlgeschlagen'; R = @{ Status = 'Error'; Code = 'CreateFailed'; Message = 'HRESULT 0x80090030' }; WantPlan = $false; WantRetry = $true; WantText = '0x80090030' }
    @{ N = 'Aufgabe nicht startbar'; StartErr = 'Das System kann die angegebene Datei nicht finden.'; WantPlan = $false; WantRetry = $true; WantText = 'VSC-Wizard CreateCard' }
    @{ N = 'Auftragsordner fehlt'; SubmitThrows = $true; WantPlan = $false; WantRetry = $true; WantText = 'Zugriff verweigert' }
)
foreach ($c in $cases) {
    Reset-Run
    $script:SimpleCardResolved = $true; $script:PerUserMode = $true; $script:SimpleCard = $null; $script:SimpleCardState = $null; $script:SimpleNotice = $null; $script:SimpleNewCardName = 'VSC-alex'
    $global:PU.Result = $c.R; $global:PU.StartErr = $c.StartErr; $global:PU.SubmitThrows = [bool]$c.SubmitThrows; $global:PU.Submitted = @()
    $global:PinChangedAnswer = [bool]$c.Pin; $global:PinDialogArgs = $null
    if ($c.SubmitThrows) {
        # Absichtlich geworfener Fehler des Platzhalters: erwartet, nicht als Befund werten.
        try { Show-SimpleStart; Enter-SimpleFlow } catch { $global:Errors.Add("[Per-User $($c.N)] AUSNAHME $($_.Exception.Message)") }
        $Error.Clear()
    } else {
        Step "Per-User: $($c.N)" { Show-SimpleStart; Enter-SimpleFlow; if ($script:SimpleReqTimer.Enabled) { Invoke-SimpleCardPoll } }
    }
    $script:SimpleReqTimer.Stop()
    $plan = OwnVisible $tabPlanA
    if ($plan -ne $c.WantPlan) { $global:Errors.Add("[Per-User $($c.N)] Ausstellung geöffnet=$plan, erwartet $($c.WantPlan)") }
    if ($c.ContainsKey('WantPinDialog') -and ([bool]$global:PinDialogArgs -ne $c.WantPinDialog)) { $global:Errors.Add("[Per-User $($c.N)] PIN-Dialog gezeigt=$([bool]$global:PinDialogArgs), erwartet $($c.WantPinDialog)") }
    if ($c.WantPinDialog -and $global:PinDialogArgs -and $global:PinDialogArgs.Prefill -ne $c.R.StartPin) { $global:Errors.Add("[Per-User $($c.N)] Start-PIN nicht vorbelegt") }
    if ($c.WantReport -and ($global:PU.Submitted -notcontains 'PinChanged')) { $global:Errors.Add("[Per-User $($c.N)] PIN-Änderung nicht an SYSTEM gemeldet") }
    if ($c.WantRetry) {
        if (-not (OwnVisible $pnlSimple) -or -not $btnSimpleStart.Enabled) { $global:Errors.Add("[Per-User $($c.N)] Sackgasse: Startseite nicht sichtbar oder 'Einrichtung starten' gesperrt") }
        if ($c.WantText -and $lblSimpleCard.Text -notmatch [regex]::Escape($c.WantText)) { $global:Errors.Add("[Per-User $($c.N)] Hinweis ohne '$($c.WantText)': '$($lblSimpleCard.Text)'") }
    }
    if (Get-Variable -Name BusyDepth -Scope Script -ErrorAction SilentlyContinue) { if ($script:BusyDepth -ne 0) { $global:Errors.Add("[Per-User $($c.N)] Warte-Anzeige hängt (BusyDepth=$($script:BusyDepth))") } }
}
# Zeitüberschreitung: "Weiter warten" (Ja) startet erneut, "Nein" führt zur Startseite mit Ausweg.
foreach ($ans in 'Yes', 'No') {
    Reset-Run
    $script:SimpleCardResolved = $true; $script:PerUserMode = $true; $script:SimpleCard = $null; $script:SimpleNotice = $null
    $global:PU.Result = $null; $global:PU.StartErr = $null; $global:PU.SubmitThrows = $false
    $global:MsgAnswer = [System.Windows.Forms.DialogResult]::$ans
    Step "Per-User: Zeitüberschreitung ($ans)" { Show-SimpleStart; Enter-SimpleFlow; $script:SimpleReqStart = (Get-Date).AddSeconds(-100); Invoke-SimpleCardPoll }
    $global:MsgAnswer = [System.Windows.Forms.DialogResult]::No
    if ($ans -eq 'Yes' -and -not $script:SimpleReqTimer.Enabled) { $global:Errors.Add('[Per-User Timeout Ja] wartet nicht weiter') }
    if ($ans -eq 'No' -and (-not $btnSimpleStart.Enabled -or $lblSimpleCard.Text -notmatch 'provision.log')) { $global:Errors.Add("[Per-User Timeout Nein] kein Ausweg: '$($lblSimpleCard.Text)'") }
    $script:SimpleReqTimer.Stop(); while ($script:BusyDepth -gt 0) { Clear-Busy }
}
$script:PerUserMode = $false
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
