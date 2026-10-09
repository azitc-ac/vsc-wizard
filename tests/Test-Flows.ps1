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
# Tests unabhängig von der (im Repo bewusst leeren) config.psd1: feste Test-Konfiguration.
foreach ($kv in @(@('CAConfig', 'CA01.contoso.local\Contoso Issuing CA'), @('Template', 'ContosoSmartcardLogon'))) { if ($config -is [hashtable]) { $config[$kv[0]] = $kv[1] } else { $config | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force } }

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
# --- Simple-Modus: eingerichtete Karte -> nur "verwalten"/"Schließen"; Ende -> "Fertig" schließt ---
$global:Log.Add('=== Simple: Ende + eingerichtet ===')
Reset-Run
$script:SimpleCardResolved = $true; $script:PerUserMode = $true; $script:SimpleNotice = $null
$script:SimpleCard = [pscustomobject]@{ FriendlyName = 'VSC-alex'; PcscName = 'Microsoft Virtual Smart Card 7'; InstanceId = 'ROOT\SMARTCARDREADER\0007' }
$script:SimpleCardState = [pscustomobject]@{ State = 'Own'; Entry = [pscustomobject]@{ Upn = 'me@contoso.com'; Subject = 'CN=me'; NotAfter = (Get-Date).AddYears(1) } }
Step 'Simple eingerichtet' { Show-SimpleStart }
if ((OwnVisible $btnSimpleStart) -or -not (OwnVisible $btnSimpleManage) -or -not (OwnVisible $btnSimpleClose)) { $global:Errors.Add('[Simple eingerichtet] erwartet nur "Smartcard verwalten" + "Schließen"') }
$script:SimpleCardState = [pscustomobject]@{ State = 'Free'; Entry = $null }
Step 'Simple frei' { Show-SimpleStart }
if (-not (OwnVisible $btnSimpleStart) -or (OwnVisible $btnSimpleManage)) { $global:Errors.Add('[Simple frei] "Einrichtung starten" fehlt bzw. "verwalten" sichtbar') }
# Zusammenfassung: "Fertig" schließt (Schließen hier abfangen, damit der Test weiterläuft).
$global:FormClosing = $false
function Close-WizardWindow { $global:FormClosing = $true }   # Fenster ist im Test nie angezeigt - Close() würde es verwerfen
$script:SimpleMode = $true
Step 'Simple Ende' { Enter-PlanARenewal -Reader $script:SimpleCard -TargetAccount $null; $script:PlanA_CertIssued = $true; Invoke-PlanANextClick }
if ($btnNextShared.Text -ne (T 'Fertig') -or -not $btnNextShared.Enabled) { $global:Errors.Add("[Simple Ende] Knopf '$($btnNextShared.Text)' aktiv=$($btnNextShared.Enabled), erwartet 'Fertig' aktiv") }
if ((OwnVisible $btnResetA) -or (OwnVisible $btnStartA) -or $btnBackShared.Enabled) { $global:Errors.Add('[Simple Ende] "Weitere Smartcard"/"Zum Startbildschirm"/"Zurück" noch angeboten') }
Step 'Simple Fertig' { Invoke-PlanANextClick }
if (-not $global:FormClosing) { $global:Errors.Add('[Simple Ende] "Fertig" schließt den Wizard nicht') }
$script:SimpleMode = $false
Step 'normaler Modus Ende' { Show-PlanAStep -Index 2 }
if (-not (OwnVisible $btnStartA) -or $btnNextShared.Text -ne (T 'Weiter')) { $global:Errors.Add('[normaler Modus Ende] Startbildschirm-Knopf/Weiter fehlt') }
# Verwaltung in der Benutzeransicht: nur die eigene Karte, ohne Löschen.
$global:ClickInDialog = $null
function global:Invoke-HarnessDialogInv($d) { $global:InvDlg = $d; return [System.Windows.Forms.DialogResult]::Cancel }
# --- Nach erfolgreicher Ausstellung kein zweiter Antrag (Plan A "Anfordern", Plan B "Übernehmen") ---
$global:Log.Add('=== Ausstellung: Knöpfe nach Erfolg gesperrt ===')
Reset-Run
$script:SimpleMode = $false
$card = [pscustomobject]@{ FriendlyName = 'VSC-T'; PcscName = 'Microsoft Virtual Smart Card 2'; InstanceId = 'ROOT\SMARTCARDREADER\0002' }
Step 'A: Anfordern vor Ausstellung' { Enter-PlanARenewal -Reader $card -TargetAccount $null }
if (-not $btnRequestCertA.Enabled) { $global:Errors.Add('[Ausstellung A] "Zertifikat anfordern" vor der Ausstellung gesperrt') }
$script:PlanA_CertIssued = $true
Step 'A: nach Ausstellung' { Show-PlanAStep -Index 1 }
if ($btnRequestCertA.Enabled) { $global:Errors.Add('[Ausstellung A] "Zertifikat anfordern" nach erfolgreicher Ausstellung noch aktiv') }
Step 'A: neuer Durchlauf' { Enter-PlanARenewal -Reader $card -TargetAccount $null }
if (-not $btnRequestCertA.Enabled) { $global:Errors.Add('[Ausstellung A] neuer Durchlauf: "Zertifikat anfordern" bleibt gesperrt') }
$script:PlanB_CertIssued = $true
Step 'B: nach Übernahme' { Enter-PlanBRenewal -Reader $card -TargetAccount 'jdoe@contoso.com'; $script:PlanB_CertIssued = $true; Show-PlanBStep -Index 5 }
if ($btnCompleteB.Enabled -or $btnCompleteFromTextB.Enabled) { $global:Errors.Add('[Ausstellung B] "Übernehmen" nach erfolgreicher Übernahme noch aktiv') }
Step 'B: neuer Durchlauf' { Enter-PlanBRenewal -Reader $card -TargetAccount 'jdoe@contoso.com'; Show-PlanBStep -Index 5 }
if (-not $btnCompleteB.Enabled) { $global:Errors.Add('[Ausstellung B] neuer Durchlauf: "Übernehmen" bleibt gesperrt (Zustand des vorigen Durchlaufs)') }
# --- Plan B fremdes Konto: zuerst Direktantrag in der RDP-Sitzung, CSR nur als Ausweichweg ---
$global:Log.Add('=== Plan B fremdes Konto: Direktweg per RDP ===')
$nonPublic = [Reflection.BindingFlags]'NonPublic,Instance'
function Invoke-Ctl($Control, [string]$Method, $Arg) { [void]$Control.GetType().GetMethod($Method, $nonPublic).Invoke($Control, [object[]]@($Arg.PSObject.BaseObject)) }
Reset-Run
$script:SimpleMode = $false
$script:TargetAccount = 'jdoe@contoso.com'
Step 'B fremd: Start' { Enter-Plan -Plan 'B'; Show-PlanBStep -Index 1 }
$script:PlanB_VscCreated = $true; $script:PlanB_PcscName = 'Microsoft Virtual Smart Card 2'; $script:PlanB_CardName = 'VSC--jdoe'
Step 'B fremd: Weiter nach Karte' { Invoke-PlanBNextClick }
if ($script:PlanBCurrentStep -ne 6) { $global:Errors.Add("[RDP-Direktweg] nach der Karte erwartet Schritt 6 (RDP), ist $($script:PlanBCurrentStep)") }
if ($btnNextShared.Enabled) { $global:Errors.Add('[RDP-Direktweg] "Weiter" im letzten Schritt aktiv') }
if ($lblRdpStepsB.Text -notmatch 'certmgr\.msc' -or $lblRdpStepsB.Text -notmatch 'jdoe@contoso\.com') { $global:Errors.Add("[RDP-Direktweg] Anleitung ohne certmgr/Zielkonto: $($lblRdpStepsB.Text)") }
Step 'B fremd: Ausweichweg' { Invoke-Ctl $lnkRdpFallbackB 'OnLinkClicked' (New-Object System.Windows.Forms.LinkLabelLinkClickedEventArgs($lnkRdpFallbackB.Links[0])) }
if ($script:PlanBCurrentStep -ne 2) { $global:Errors.Add("[RDP-Direktweg] Ausweichweg führt nicht zur CSR (Schritt $($script:PlanBCurrentStep))") }
Step 'B fremd: Zurück aus CSR' { Invoke-PlanBBackClick }
if ($script:PlanBCurrentStep -ne 6 -or $script:PlanB_Fallback) { $global:Errors.Add("[RDP-Direktweg] Zurück aus der CSR führt nicht zum Direktweg (Schritt $($script:PlanBCurrentStep))") }
Step 'B fremd: Zurück aus RDP' { Invoke-PlanBBackClick }
if ($script:PlanBCurrentStep -ne 1) { $global:Errors.Add("[RDP-Direktweg] Zurück aus dem Direktweg führt nicht zur Karte (Schritt $($script:PlanBCurrentStep))") }
# .rdp-Datei: Smartcard-Umleitung + Zielkonto (mstsc selbst nicht starten)
function Start-Process { param($FilePath, $ArgumentList) $global:StartedProc = "$FilePath $($ArgumentList -join ' ')" }
$origJump = $config['RdpJumpServer']; $config['RdpJumpServer'] = 'pki-jump.contoso.local'
$global:StartedProc = $null
Step 'B fremd: RDP starten' { Invoke-Ctl $btnRdpConnectB 'OnClick' ([EventArgs]::Empty) }
$rdp = Get-Content (Join-Path (Get-WizardWorkingDir) 'VSC-Wizard-Antrag.rdp') -Raw -ErrorAction SilentlyContinue
if ($rdp -notmatch 'redirectsmartcards:i:1' -or $rdp -notmatch 'username:s:jdoe@contoso\.com' -or $rdp -notmatch 'full address:s:pki-jump\.contoso\.local') { $global:Errors.Add("[RDP-Direktweg] .rdp-Datei unvollständig: $rdp") }
if ($global:StartedProc -notmatch '^mstsc\.exe') { $global:Errors.Add("[RDP-Direktweg] mstsc nicht gestartet ($($global:StartedProc))") }
Remove-Item function:Start-Process
# "Karte prüfen": Gegenprobe zuerst (fremdes Konto bzw. altes Zertifikat -> nicht fertig)
Step 'B fremd: Weiter zu RDP' { Invoke-PlanBNextClick }
$global:FakeCerts = @(
    [pscustomobject]@{ Reader = 'Microsoft Virtual Smart Card 2'; Subject = 'CN=jdoe'; Upn = 'jdoe@contoso.com'; NotBefore = (Get-Date).AddDays(-200); NotAfter = (Get-Date).AddDays(165); Thumbprint = 'OLD' }
    [pscustomobject]@{ Reader = 'Microsoft Virtual Smart Card 2'; Subject = 'CN=other'; Upn = 'other@contoso.com'; NotBefore = (Get-Date); NotAfter = (Get-Date).AddDays(365); Thumbprint = 'OTHER' })
function Get-SmartCardCertificates { $global:FakeCerts }
Step 'B fremd: Karte prüfen (nichts Neues)' { Invoke-Ctl $btnRdpCheckB 'OnClick' ([EventArgs]::Empty) }
if ($script:PlanB_CertIssued) { $global:Errors.Add('[RDP-Direktweg] altes/fremdes Zertifikat als neu erkannt') }
if (-not $btnRdpCheckB.Enabled) { $global:Errors.Add('[RDP-Direktweg] "Karte prüfen" nach Fehlschlag gesperrt') }
$global:FakeCerts += [pscustomobject]@{ Reader = 'Microsoft Virtual Smart Card 2'; Subject = 'CN=jdoe, OU=Admins'; Upn = 'jdoe@contoso.com'; NotBefore = (Get-Date).AddMinutes(-10); NotAfter = (Get-Date).AddDays(365); Thumbprint = 'NEW' }
Step 'B fremd: Karte prüfen (neu)' { Invoke-Ctl $btnRdpCheckB 'OnClick' ([EventArgs]::Empty) }
if (-not $script:PlanB_CertIssued) { $global:Errors.Add('[RDP-Direktweg] neues Zertifikat auf der Karte nicht erkannt') }
if ($btnRdpCheckB.Enabled -or -not (Test-OwnVisible $btnRdpStartB)) { $global:Errors.Add('[RDP-Direktweg] nach Erfolg: "Karte prüfen" noch aktiv bzw. "Zum Startbildschirm" fehlt') }
Remove-Item function:Get-SmartCardCertificates
# Verlängerung eines fremden Kontos: direkt in den Direktweg, Zurück -> Startseite
$card = [pscustomobject]@{ FriendlyName = 'VSC-T'; PcscName = 'Microsoft Virtual Smart Card 2'; InstanceId = 'ROOT\SMARTCARDREADER\0002' }
Step 'B fremd: Verlängerung' { Enter-PlanBRenewal -Reader $card -TargetAccount 'jdoe@contoso.com' }
if ($script:PlanBCurrentStep -ne 6 -or $script:PlanB_CertIssued) { $global:Errors.Add("[RDP-Direktweg] Verlängerung: erwartet frischer Schritt 6, ist $($script:PlanBCurrentStep) (CertIssued=$($script:PlanB_CertIssued))") }
Step 'B fremd: Verlängerung Zurück' { Invoke-PlanBBackClick }
if ((OwnVisible $tabPlanB)) { $global:Errors.Add('[RDP-Direktweg] Verlängerung: Zurück führt nicht zur Startseite') }
# Gegenprobe: eigenes Konto (kein Zielkonto) -> wie bisher CSR
Reset-Run
$script:TargetAccount = $null
Step 'B eigen: Start' { Enter-Plan -Plan 'B'; Show-PlanBStep -Index 1 }
$script:PlanB_VscCreated = $true
Step 'B eigen: Weiter nach Karte' { Invoke-PlanBNextClick }
if ($script:PlanBCurrentStep -ne 2) { $global:Errors.Add("[RDP-Direktweg] eigenes Konto: erwartet CSR (Schritt 2), ist $($script:PlanBCurrentStep)") }
$config['RdpJumpServer'] = $origJump

# --- Andere Smartcards (Einstellung AllowPhysicalCards) ---
$global:Log.Add('=== Andere Smartcards ===')
foreach ($case in @(@(@{ AllowPhysicalCards = 'True' }, $true), @(@{ AllowPhysicalCards = 'False' }, $false), @(@{}, $false))) {
    if ((Test-PhysicalCardsAllowed -Config $case[0]) -ne $case[1]) { $global:Errors.Add("[Andere Karten] Test-PhysicalCardsAllowed '$($case[0].AllowPhysicalCards)' -> nicht $($case[1])") }
}
# Kernfunktion Get-SmartCardTargets mit gestellter Prüfung (im Modul-Bereich ersetzt, danach zurück).
$coreMod = Get-Module VscWizard.Core
$origPhys = & $coreMod { ${function:Get-PhysicalSmartCards} }
$origVsc = & $coreMod { ${function:Get-VirtualSmartCardReaders} }
& $coreMod {
    ${function:script:Get-VirtualSmartCardReaders} = { @([pscustomobject]@{ FriendlyName = 'VSC-T'; PcscName = 'Microsoft Virtual Smart Card 0'; InstanceId = 'ROOT\SMARTCARDREADER\0000'; Status = 'OK' }) }
    ${function:script:Get-PhysicalSmartCards} = { @(
        [pscustomobject]@{ Reader = 'Yubico YubiKey OTP+FIDO+CCID 0'; CardName = 'YubiKey Smart Card Minidriver'; Module = 'ykmd.dll'; State = 'Usable'; Usable = $true }
        [pscustomobject]@{ Reader = 'Generic USB Reader 0'; CardName = $null; Module = $null; State = 'UnknownCard'; Usable = $false }
        [pscustomobject]@{ Reader = 'Generic USB Reader 1'; CardName = $null; Module = $null; State = 'NoCard'; Usable = $false }) }
}
try {
    $t = @(Get-SmartCardTargets -Config @{ AllowPhysicalCards = 'True' })
    if ($t.Count -ne 2 -or @($t | Where-Object Kind -eq 'Physical')[0].PcscName -ne 'Yubico YubiKey OTP+FIDO+CCID 0') { $global:Errors.Add("[Andere Karten] erlaubt: erwartet VSC + YubiKey, erhalten $($t.Count): $(($t | ForEach-Object FriendlyName) -join ', ')") }
    $t = @(Get-SmartCardTargets -Config @{ AllowPhysicalCards = 'True' } -IncludeUnusable)
    if ($t.Count -ne 3) { $global:Errors.Add("[Andere Karten] -IncludeUnusable: erwartet 3 (ohne leeren Leser), erhalten $($t.Count)") }
    # Gegenprobe: nicht erlaubt -> nur VSCs
    $t = @(Get-SmartCardTargets -Config @{ AllowPhysicalCards = 'False' })
    if ($t.Count -ne 1 -or $t[0].Kind -ne 'Virtual') { $global:Errors.Add("[Andere Karten] nicht erlaubt: erwartet nur die VSC, erhalten $($t.Count)") }
} finally {
    & $coreMod { param($p, $v) ${function:script:Get-PhysicalSmartCards} = $p; ${function:script:Get-VirtualSmartCardReaders} = $v } $origPhys $origVsc
}
# Echte Select-ExistingVsc (oben für die Abläufe ersetzt) aus dem Quelltext holen.
$fnAst = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null).Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Select-ExistingVsc' }, $true)
. ([scriptblock]::Create(($fnAst.Extent.Text -replace '^function Select-ExistingVsc', 'function Select-ExistingVscReal')))
function Show-VscPickerDialog { param($Readers, $Certs) $global:PickerCount = @($Readers).Count; return @($Readers)[0] }
function Get-SmartCardCertificates { @() }
$config['AllowPhysicalCards'] = 'True'
function Get-SmartCardTargets { param($Config, [switch]$IncludeUnusable) @(
    [pscustomobject]@{ FriendlyName = 'VSC-T'; PcscName = 'Microsoft Virtual Smart Card 0'; Kind = 'Virtual'; Usable = $true; State = 'Usable' }
    [pscustomobject]@{ FriendlyName = 'YubiKey  (Yubico 0)'; PcscName = 'Yubico 0'; Kind = 'Physical'; Usable = $true; State = 'Usable'; CardName = 'YubiKey' }) }
$global:PickerCount = 0
$r = Select-ExistingVscReal
if ($global:PickerCount -ne 2) { $global:Errors.Add("[Andere Karten] Auswahl: Picker sollte VSC + YubiKey zeigen, zeigte $($global:PickerCount)") }
function Get-SmartCardTargets { param($Config, [switch]$IncludeUnusable) @(
    [pscustomobject]@{ FriendlyName = 'Generic USB Reader 0'; PcscName = 'Generic USB Reader 0'; Kind = 'Physical'; Usable = $false; State = 'NoMinidriver' }) | Where-Object { $IncludeUnusable -or $_.Usable } }
$before = $global:Msgs.Count
$r = Select-ExistingVscReal
if ($r) { $global:Errors.Add('[Andere Karten] ungeeignete Karte wurde ausgewählt') }
if (-not @($global:Msgs | Select-Object -Skip $before | Where-Object { $_ -like '*Keine Smartcard vorhanden*Minidriver*' })) { $global:Errors.Add('[Andere Karten] keine Meldung mit Grund (kein Kartentreiber) bei nur ungeeigneter Karte') }
# Gegenprobe: Einstellung aus -> bisherige VSC-Meldung
$config['AllowPhysicalCards'] = 'False'
function Get-SmartCardTargets { param($Config, [switch]$IncludeUnusable) @() }
$before = $global:Msgs.Count
$r = Select-ExistingVscReal
if (-not @($global:Msgs | Select-Object -Skip $before | Where-Object { $_ -like '*Keine VSC vorhanden*' })) { $global:Errors.Add('[Andere Karten] Einstellung aus: bisherige Meldung "Keine VSC vorhanden" fehlt') }
$config.Remove('AllowPhysicalCards')

# --- Zertifikate nur auf der Karte (CertPropSvc hat sie noch nicht in den Speicher kopiert) ---
$global:Log.Add('=== Kartenzertifikate: Speicher + Karte zusammenführen ===')
$rd7 = 'Microsoft Virtual Smart Card 7'
$stA = [pscustomobject]@{ Subject = 'CN=a'; Upn = 'a@contoso.com'; Thumbprint = 'AAAA'; NotBefore = (Get-Date).AddDays(-30); NotAfter = (Get-Date).AddYears(1); Provider = 'Microsoft Smart Card Key Storage Provider'; Reader = $rd7; KeyContainerName = 'tq-a'; IsSmartCard = $true; DetectionError = $null }
$stB = [pscustomobject]@{ Subject = 'CN=b'; Upn = $null; Thumbprint = 'BBBB'; NotBefore = (Get-Date).AddDays(-60); NotAfter = (Get-Date).AddYears(1); Provider = $null; Reader = $null; KeyContainerName = $null; IsSmartCard = $false; DetectionError = 'x' }
$cdA = [pscustomobject]@{ Reader = $rd7; Container = 'tq-a'; Thumbprint = 'AAAA'; Subject = 'CN=a'; Upn = 'a@contoso.com'; NotBefore = $stA.NotBefore; NotAfter = $stA.NotAfter; RawData = [byte[]](1, 2) }
$cdB = [pscustomobject]@{ Reader = $rd7; Container = 'tq-b'; Thumbprint = 'BBBB'; Subject = 'CN=b'; Upn = $null; NotBefore = $stB.NotBefore; NotAfter = $stB.NotAfter; RawData = [byte[]](3) }
$cdD = [pscustomobject]@{ Reader = $rd7; Container = 'tq-d'; Thumbprint = 'DDDD'; Subject = 'CN=d'; Upn = 'd@contoso.com'; NotBefore = (Get-Date); NotAfter = (Get-Date).AddYears(2); RawData = [byte[]](4, 5, 6) }
$cdW = [pscustomobject]@{ Reader = 'Windows Hello for Business 1'; Container = '{x}'; Thumbprint = 'EEEE'; Subject = 'CN=w'; Upn = $null; NotBefore = (Get-Date); NotAfter = (Get-Date).AddYears(30); RawData = [byte[]](7) }
$m = @(Merge-SmartCardCertificateSources -StoreEntries @($stA, $stB) -CardEntries @($cdA, $cdB, $cdD, $cdD, $cdW))
if ($m.Count -ne 3) { $global:Errors.Add("[Kartenzertifikate] erwartet 3 Einträge (A, B, D), erhalten $($m.Count): $(($m | ForEach-Object Thumbprint) -join ',')") }
$mD = @($m | Where-Object Thumbprint -eq 'DDDD')
if ($mD.Count -ne 1 -or $mD[0].InStore -ne $false -or $mD[0].Reader -ne $rd7 -or $mD[0].KeyContainerName -ne 'tq-d' -or -not $mD[0].IsSmartCard -or $mD[0].RawData.Length -ne 3) { $global:Errors.Add('[Kartenzertifikate] nur auf der Karte liegendes Zertifikat fehlt oder ist falsch markiert') }
if (@($m | Where-Object { $_.Thumbprint -in 'AAAA', 'BBBB' -and $_.InStore -ne $true }).Count) { $global:Errors.Add('[Kartenzertifikate] Speicher-Zertifikat als "nicht im Speicher" markiert bzw. doppelt') }
$mB = $m | Where-Object Thumbprint -eq 'BBBB'
if ($mB.Reader -ne $rd7 -or $mB.KeyContainerName -ne 'tq-b' -or -not $mB.IsSmartCard) { $global:Errors.Add('[Kartenzertifikate] Speicher-Zertifikat ohne Leser wurde nicht über die Karte zugeordnet') }
if (@($m | Where-Object Thumbprint -eq 'EEEE').Count) { $global:Errors.Add('[Kartenzertifikate] Windows-Hello-Zertifikat als Smartcard-Zertifikat übernommen') }
# Gegenprobe: ohne Kartenfunde bleibt alles wie bisher (kein Eintrag "nur auf der Karte", nichts zugeordnet).
$g = @(Merge-SmartCardCertificateSources -StoreEntries @($stA, $stB) -CardEntries @())
if ($g.Count -ne 2 -or @($g | Where-Object { $_.InStore -ne $true }).Count -or ($g | Where-Object Thumbprint -eq 'BBBB').Reader) { $global:Errors.Add('[Kartenzertifikate Gegenprobe] ohne Kartenfunde verändert die Zusammenführung den Speicherbestand') }
if ($stB.Reader) { $global:Errors.Add('[Kartenzertifikate] Eingabeobjekt verändert (Speicher-Eintrag B)') }
# Lookup-Zeilen -> Objekte: leerer Container übersprungen, Müll ignoriert.
$conv = @(ConvertFrom-SmartCardCertificateLines -Line @("Card=$rd7|tq-leer|", "Card=$rd7|tq-kaputt|@@@", 'Begin=AAAA'))
if ($conv.Count -ne 0) { $global:Errors.Add("[Kartenzertifikate] Zeilen ohne gültiges Zertifikat ergeben $($conv.Count) Einträge") }

# Inventar: "nur auf der Karte" -> Hinweis + "In Speicher übernehmen"; danach (Gegenprobe) gesperrt.
$global:Log.Add('=== Kartenzertifikate: Inventar ===')
$cardOnlyCert = (Merge-SmartCardCertificateSources -StoreEntries @($stA) -CardEntries @($cdD))
$stD = [pscustomobject]@{ Subject = 'CN=d'; Upn = 'd@contoso.com'; Thumbprint = 'DDDD'; NotBefore = $cdD.NotBefore; NotAfter = $cdD.NotAfter; Provider = 'Microsoft Smart Card Key Storage Provider'; Reader = $rd7; KeyContainerName = 'tq-d'; IsSmartCard = $true; DetectionError = $null }
$afterImport = Merge-SmartCardCertificateSources -StoreEntries @($stA, $stD) -CardEntries @($cdD)
function Get-SmartCardCertificates { param([string]$StoreLocation) if ($global:ImportedRaw) { $afterImport } else { $cardOnlyCert } }
function Import-SmartCardCertificateToStore { param([byte[]]$RawData, [string]$ContainerName, [string]$Provider) $global:ImportedRaw = $RawData; $global:ImportedContainer = $ContainerName; return [pscustomobject]@{ Success = $true; Message = '' } }
$global:ImportedRaw = $null; $global:InvRounds = @()
$origHarness = ${function:global:Invoke-HarnessDialog}
function global:Invoke-HarnessDialog($d) {
    $ctl = @(); $stack = New-Object System.Collections.Stack; $stack.Push($d)
    while ($stack.Count) { $c = $stack.Pop(); $ctl += $c; foreach ($k in $c.Controls) { $stack.Push($k) } }
    $btn = $ctl | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq (T 'In Speicher übernehmen') } | Select-Object -First 1
    $lbl = $ctl | Where-Object { $_ -is [System.Windows.Forms.Label] -and $_.Text -eq (T 'Liegt auf der Karte, fehlt im Zertifikatsspeicher.') } | Select-Object -First 1
    $lv = @($ctl | Where-Object { $_ -is [System.Windows.Forms.ListView] })
    # Ohne Fenster-Handle feuert die Auswahl nicht: Handles anlegen, Karte wie ein Benutzer wählen.
    foreach ($x in $lv) { $null = $x.Handle }
    $cardItem = @($lv[0].Items) | Select-Object -First 1
    if ($cardItem) { $cardItem.Selected = $false; $cardItem.Selected = $true }
    $status = @($lv | ForEach-Object { $_.Items } | Where-Object { $_.SubItems.Count -gt 2 } | ForEach-Object { $_.SubItems[2].Text })
    $global:InvRounds += [pscustomobject]@{ Enabled = [bool]($btn -and $btn.Enabled); Hint = [bool]($lbl -and (OwnVisible $lbl)); Status = $status }
    if ($btn -and $btn.Enabled -and $global:InvRounds.Count -eq 1) { $onClick.Invoke($btn, @([EventArgs]::Empty)) }
    $d.Dispose(); return [System.Windows.Forms.DialogResult]::Cancel
}
Step 'Inventar mit Zertifikat nur auf der Karte' { Show-VscInventoryDialog -Owner $form }
Set-Item -Path function:global:Invoke-HarnessDialog -Value $origHarness
if ($global:InvRounds.Count -ne 2) { $global:Errors.Add("[Kartenzertifikate Inventar] erwartet Übernahme + Neuaufbau (2 Durchläufe), erhalten $($global:InvRounds.Count): $(($global:InvRounds | ForEach-Object { "Knopf=$($_.Enabled) Hinweis=$($_.Hint) Status=$($_.Status -join '/')" }) -join '; ')") }
elseif (-not $global:InvRounds[0].Enabled -or -not $global:InvRounds[0].Hint -or $global:InvRounds[0].Status -notcontains (T 'nicht im Speicher')) { $global:Errors.Add("[Kartenzertifikate Inventar] Hinweis/Knopf fehlt: $($global:InvRounds[0] | Out-String)") }
elseif ($global:InvRounds[1].Enabled -or $global:InvRounds[1].Hint -or $global:InvRounds[1].Status -contains (T 'nicht im Speicher')) { $global:Errors.Add('[Kartenzertifikate Inventar Gegenprobe] nach der Übernahme noch als "nicht im Speicher" angeboten') }
if (-not $global:ImportedRaw -or $global:ImportedRaw.Length -ne 3 -or $global:ImportedContainer -ne 'tq-d') { $global:Errors.Add('[Kartenzertifikate Inventar] Übernahme nicht mit Zertifikat/Container der Karte aufgerufen') }

# Aufräumen: ein ÄLTERES Zertifikat nur auf der Karte wird mit angeboten (früher erst, nachdem
# CertPropSvc es kopiert hatte); Gegenprobe nur mit dem Speicher-Zertifikat -> keine Abfrage.
$global:Log.Add('=== Kartenzertifikate: Aufräumen ===')
$cdOld = [pscustomobject]@{ Reader = $rd7; Container = 'tq-old'; Thumbprint = 'CCCC'; Subject = 'CN=alt'; Upn = $null; NotBefore = (Get-Date).AddDays(-400); NotAfter = (Get-Date).AddDays(-35); RawData = [byte[]](9) }
$cleanupCerts = Merge-SmartCardCertificateSources -StoreEntries @($stA) -CardEntries @($cdOld)
function Get-SmartCardCertificates { param([string]$StoreLocation) $cleanupCerts }
$global:Msgs.Clear(); $global:MsgAnswer = [System.Windows.Forms.DialogResult]::No
Step 'Aufräumen mit Zertifikat nur auf der Karte' { Invoke-RenewalCleanup -PcscName $rd7 -UpnOrTerm 'x' }
$cleanMsg = "$($global:Msgs)"
if ($cleanMsg -notmatch 'CCCC' -or $cleanMsg -notmatch [regex]::Escape((T 'liegt auf der Karte, fehlt im Zertifikatsspeicher')) -or $cleanMsg -match 'Thumbprint AAAA') { $global:Errors.Add("[Kartenzertifikate Aufräumen] altes Zertifikat nur auf der Karte nicht (richtig) angeboten: '$cleanMsg'") }
function Get-SmartCardCertificates { param([string]$StoreLocation) @($stA) }
$global:Msgs.Clear()
Step 'Aufräumen Gegenprobe (nur Speicher, ein Zertifikat)' { Invoke-RenewalCleanup -PcscName $rd7 -UpnOrTerm 'x' }
if ($global:Msgs.Count) { $global:Errors.Add('[Kartenzertifikate Aufräumen Gegenprobe] Abfrage trotz nur einem Zertifikat') }
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
