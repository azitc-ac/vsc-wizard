# Layout-Audit: lädt VscWizard.ps1 OHNE Anzeige, ersetzt ShowDialog durch eine Prüfung
# und meldet abgeschnittene Texte, Überlappungen und über den Rand ragende Controls -
# für alle Startseiten-/Plan-A-/Plan-B-Zustände (mit langen Worst-Case-Texten) und alle
# Dialoge. Findet die Klasse "Text abgeschnitten/überdeckt" ohne manuelles Durchklicken.
#
# Aufruf (Windows PowerShell 5.1, STA):
#   powershell.exe -STA -File .\tests\Test-Layout.ps1                 # Standardgröße
#   powershell.exe -STA -File .\tests\Test-Layout.ps1 -Width 900 -Height 780   # Mindestgröße
# Liest nur (Karten/Zertifikate/LDAP); keine UAC-/PIN-/CA-Aktionen.
param([string]$Repo, [int]$Width = 0, [int]$Height = 0)
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
$ErrorActionPreference = 'Continue'
$global:Findings = New-Object System.Collections.Generic.List[string]
$global:Audited = New-Object System.Collections.Generic.List[string]

$stateMethod = [System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance')
function Test-OwnVisible($c) { return [bool]$stateMethod.Invoke($c, @(2)) }

function Get-Path($c) {
    $parts = @()
    while ($c) { $n = if ($c.Name) { $c.Name } elseif ($c.Text -and $c.Text.Length -lt 30) { "'$($c.Text)'" } else { $c.GetType().Name }; $parts = ,$n + $parts; $c = $c.Parent }
    return ($parts -join ' > ')
}

function Initialize-Layout($ctl) {
    try { $null = $ctl.Handle } catch { }
    $ctl.PerformLayout()
    foreach ($ch in $ctl.Controls) { Initialize-Layout $ch }
}

function Find-VarName($ctl) {
    # Variablennamen des Controls ermitteln (für lesbare Meldungen)
    foreach ($v in (Get-Variable -Scope Script -ErrorAction SilentlyContinue)) {
        if ([object]::ReferenceEquals($v.Value, $ctl)) { return '$' + $v.Name }
    }
    return $null
}

function Test-Layout($root, [string]$Context) {
    $global:Audited.Add($Context)
    Initialize-Layout $root
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $p = $stack.Pop()
        $kids = @($p.Controls | Where-Object { Test-OwnVisible $_ })
        foreach ($c in $kids) {
            $stack.Push($c)
            $name = Find-VarName $c
            if (-not $name) { $name = Get-Path $c }
            $txt = "$($c.Text)"
            # 1) Abgeschnittener Text (Label/Button/CheckBox/RadioButton ohne AutoSize)
            if ($txt -and -not $c.AutoSize -and -not ($c -is [System.Windows.Forms.Label] -and $c.AutoEllipsis) -and ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.ButtonBase])) {
                # Buttons: flache Buttons brauchen gemessen ~10 px mehr als MeasureText ('Abbrechen' 71 px -> ab 81 px
                # vollständig; bei 80 px 'Abbreche'). 12 px = kleine Reserve.
                $isBtn = $c -is [System.Windows.Forms.Button]
                # Innenabstand (Hinweisboxen) abziehen - der Text hat nur die Innenfläche.
                $avail = $c.ClientSize.Width - $c.Padding.Horizontal - $(if ($isBtn) { 12 } elseif ($c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.RadioButton]) { 20 } else { 0 })
                $availH = $c.ClientSize.Height - $c.Padding.Vertical
                if ($avail -gt 0) {
                    $flags = if ($isBtn) { [System.Windows.Forms.TextFormatFlags]::SingleLine } else { [System.Windows.Forms.TextFormatFlags]::WordBreak }
                    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $c.Font, (New-Object System.Drawing.Size($avail, 10000)), $flags)
                    if ($sz.Height -gt $availH + 1 -or ($isBtn -and $sz.Width -gt $avail + 1)) {
                        $global:Findings.Add("[$Context] TEXT ABGESCHNITTEN: $name  (Platz ${avail}x$availH, braucht $($sz.Width)x$($sz.Height))  Text: '$($txt.Substring(0,[Math]::Min(90,$txt.Length)))...'")
                    }
                }
            }
            # 1a) Englische Oberfläche: kein deutscher Text übrig (Umlaute/typische Wörter).
            if ($txt -and (Get-WizardLanguage) -eq 'en' -and $c -isnot [System.Windows.Forms.TextBoxBase] -and $c -isnot [System.Windows.Forms.ComboBox] -and
                $txt -match '[äöüÄÖÜß]|\b(der|die|das|und|oder|nicht|wird|bitte|mit|für|auf|keine?|Starte|Weiter)\b|\b(Virtuell|Zertifikat|Smartcard|Karte|Antr[aä]g|Schl[üu]ssel|[Ee]rstell|abgebrochen|Fehler|wählen|laden|lesen|Einstellung|Zurück|Szenario|Schritt|Konto)') {
                $global:Findings.Add("[$Context] DEUTSCH IN EN: $name  Text: '$($txt.Substring(0,[Math]::Min(90,$txt.Length)))'")
            }
            # 1b) AutoSize-Label mit MaximumSize: gewachsene Höhe muss in den Container passen
            #     (wird über "Ragt über Rand" unten erfasst).
            # 2) Ragt über den Rand des Eltern-Containers (ohne Scrollen)
            if ($c.Dock -eq 'None' -and -not ($p -is [System.Windows.Forms.ScrollableControl] -and $p.AutoScroll)) {
                if ($c.Right -gt $p.ClientSize.Width + 1 -or $c.Bottom -gt $p.ClientSize.Height + 1) {
                    $global:Findings.Add("[$Context] RAGT ÜBER RAND: $name  bounds=$($c.Bounds)  parent=$($p.ClientSize)")
                }
            }
        }
        # 3) Überlappende Geschwister (absolut positionierte Controls)
        $abs = @($kids | Where-Object { $_.Dock -eq 'None' -and $_ -ne $script:BusyLabel })
        if (-not ($p -is [System.Windows.Forms.FlowLayoutPanel] -or $p -is [System.Windows.Forms.TableLayoutPanel])) {
            for ($i = 0; $i -lt $abs.Count; $i++) {
                for ($j = $i + 1; $j -lt $abs.Count; $j++) {
                    $r = [System.Drawing.Rectangle]::Intersect($abs[$i].Bounds, $abs[$j].Bounds)
                    if ($r.Width -gt 2 -and $r.Height -gt 2) {
                        $a = Find-VarName $abs[$i]; if (-not $a) { $a = Get-Path $abs[$i] }
                        $b = Find-VarName $abs[$j]; if (-not $b) { $b = Get-Path $abs[$j] }
                        $global:Findings.Add("[$Context] ÜBERLAPPUNG: $a $($abs[$i].Bounds) <-> $b $($abs[$j].Bounds)")
                    }
                }
            }
        }
    }
}

function global:Invoke-HarnessDialog($d) {
    if ($d -is [System.Windows.Forms.Form]) {
        $ctx = "Dialog '$($d.Text)'"
        Test-Layout $d $ctx
        $d.Dispose()
    }
    return [System.Windows.Forms.DialogResult]::Cancel
}

# --- Wizard-Quelltext präparieren ---
$src = [IO.File]::ReadAllText((Join-Path $Repo 'VscWizard.ps1'), [Text.Encoding]::UTF8)
$src = $src.Replace('$script:BaseDir = $PSScriptRoot', "`$script:BaseDir = '$Repo'")
$idx = $src.LastIndexOf('[void]$form.ShowDialog()')
$src = $src.Substring(0, $idx) + '# (Audit: kein ShowDialog)' + $src.Substring($idx + '[void]$form.ShowDialog()'.Length)
$src = [regex]::Replace($src, '\$dlg\.ShowDialog\([^)]*\)', '(Invoke-HarnessDialog $dlg)')

. ([scriptblock]::Create($src))
# Splash (läuft vor dem Modul-Import) mitprüfen, bevor er geschlossen wird.
# (der Wizard schliesst ihn selbst vor dem Hauptfenster - daher gezielt neu öffnen)
$null = Show-SplashScreen; Update-Splash -Text (L 'Kernmodul laden...' 'Loading core module...') -Percent 25; Test-Layout $script:Splash 'Splash'
Close-Splash
if ($Width -gt 0) { $form.Size = New-Object System.Drawing.Size($Width, $Height) }
"Fenstergröße: $($form.Size)  (Minimum $($form.MinimumSize))"

$long = 'VSC--administrator.langername'
$pcsc = 'Microsoft Virtual Smart Card 12'

# --- Hauptfenster: Startseite ---
Show-ScenarioStep
Test-Layout $form 'Startseite (Szenarien)'
# Nicht verfügbares Szenario mit der längsten echten Begründung
$worst = $null
foreach ($id in 2, 3, 5) {
    $av = Get-ScenarioAvailability -Caps ([pscustomobject]@{ HasOnPremTgt = $false; JoinMode = 'Workgroup'; EaCertCount = 0 }) -Id $id
    if ($av.Reason -and (-not $worst -or $av.Reason.Length -gt $worst.Reason.Length)) { $worst = [pscustomobject]@{ Id = $id; Reason = $av.Reason } }
}
$script:ScnAvailable[$worst.Id] = $false; $script:ScnReason[$worst.Id] = $worst.Reason
Select-ScenarioById -Id $worst.Id
Test-Layout $form "Startseite, Szenario $($worst.Id) nicht verfügbar"
$script:ScnAvailable[$worst.Id] = $true

# --- Plan A ---
foreach ($offline in $false, $true) {
    $script:PlanA_OfflineDirect = $offline
    $script:TargetAccount = if ($offline) { 'jdoe@contoso.com' } else { $null }
    Enter-Plan -Plan 'A'
    $mode = if ($offline) { 'Szenario 03/offline' } else { 'normal' }
    $txtCardNameA.Text = $long
    Show-PlanAStep -Index 0
    Test-Layout $form "Plan A Schritt 2 leer ($mode)"
    $lblVscResultA.Text = (T "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der Zertifikatsanforderung) heißt sie: '{0}'.") -f $pcsc
    Test-Layout $form "Plan A Schritt 2 Erfolg ($mode)"
    $lblVscResultA.Text = (T 'Fehler bei der Erstellung: {0} (Details siehe Log).') -f ((T "Nach dem tpmvscmgr-Lauf wurde keine Karte '{0}' gefunden (Abbruch, abweichende/zu kurze PIN oder Erstellung fehlgeschlagen).") -f $long)
    Test-Layout $form "Plan A Schritt 2 Fehler ($mode)"

    $script:PlanA_CardName = $long; $script:PlanA_PcscName = $pcsc
    Show-PlanAStep -Index 1
    Test-Layout $form "Plan A Schritt 3 ($mode)"
    $lblCertResultA.Text = (T 'Antrag wurde eingereicht und wartet auf Genehmigung (RequestId {0}). {1} Auch nach einem Neustart des Wizards möglich.') -f 123456, (Get-PendingApprovalHint -RequestId 123456)
    $btnRetrieveA.Visible = $true
    Test-Layout $form "Plan A Schritt 3 Pending ($mode)"
    $btnRetrieveA.Visible = $false

    Show-PlanAStep -Index 2
    $lblSummaryA.Text = (@(((T 'Kartenname: {0}') -f $long), ((T 'Auf der Karte liegen {0} Zertifikate:') -f 3)) + (1..3 | ForEach-Object { "  $_) CN=administrator.langername@contoso.onmicrosoft.com"; ((T '     gültig {0} bis {1}  (Thumbprint {2})') -f '2026-09-28', '2028-09-28', '0123456789ABCDEF0123456789ABCDEF01234567') }) + (T 'Hinweis: Beim Smartcard-Logon nutzt Windows i.d.R. das erste passende Zertifikat. Für "eine Karte = ein Zertifikat" die älteren entfernen (Aufräum-Abfrage nach dem Erneuern oder Szenario 04).')) -join "`r`n"
    Test-Layout $form "Plan A Schritt 4 Zusammenfassung 3 Zertifikate ($mode)"
}
$script:PlanA_OfflineDirect = $false; $script:TargetAccount = $null
$tabPlanA.Visible = $false

# --- Plan B ---
Enter-Plan -Plan 'B'
$script:PlanB_CardName = $long; $script:PlanB_PcscName = $pcsc
for ($i = 0; $i -le 6; $i++) {
    try { Show-PlanBStep -Index $i } catch { break }
    Test-Layout $form "Plan B Schritt-Index $i"
}
Show-PlanBStep -Index 4
$lblSubmitResultB.Text = (T 'Antrag wartet auf Genehmigung (RequestId {0}). {1} Auch nach einem Neustart des Wizards möglich.') -f 123456, (Get-PendingApprovalHint -RequestId 123456)
$btnRetrieveB.Visible = $true
Test-Layout $form 'Plan B Einreichen Pending'
$tabPlanB.Visible = $false

# --- Simple-Modus (Intune-App 2): Startseite in allen drei Zuständen ---
$script:SimpleCardResolved = $true
function Set-VscEnrollMarker { $true }   # Layout-Test: keinen echten HKCU-Marker setzen
$occEntry = [pscustomobject]@{ Container = 'x'; HasCertificate = $true; Subject = 'CN=administrator.langername'; Upn = 'administrator.langername@contoso.onmicrosoft.com'; NotAfter = (Get-Date).AddYears(2) }
foreach ($st in 'Own', 'Other', 'Started') {
    $script:SimpleCard = [pscustomobject]@{ FriendlyName = $long; PcscName = $pcsc; InstanceId = 'ROOT\SMARTCARDREADER\0001' }
    $script:SimpleCardState = [pscustomobject]@{ State = $st; Entry = $(if ($st -ne 'Started') { $occEntry }) }
    Show-SimpleStart
    Test-Layout $form "Simple-Startseite (Karte $st)"
}
$script:SimpleCardState = $null
# Per-Benutzer-Karte: neue Karte (Vorschau-Name) und längster Fehlerhinweis mit Ausweg.
$script:PerUserMode = $true; $script:SimpleCard = $null; $script:SimpleNewCardName = 'VSC-administrator.langerna'
Show-SimpleStart; Test-Layout $form 'Simple-Startseite (Per-Benutzer, neue Karte)'
$script:SimpleNotice = [pscustomobject]@{ Text = ((T 'Die Smartcard konnte nicht angelegt werden ({0}). Versuche es bitte erneut; bleibt der Fehler, hilft deine IT (Protokoll: {1}).') -f 'CreateVirtualSmartCardWithPinPolicy: HRESULT 0x80090030 (NTE_DEVICE_NOT_READY) - TpmVirtualSmartCardManager returned no instance id after 3 attempts', 'C:\ProgramData\VSC-Wizard\provision.log'); Color = $script:UI.Danger; CanRetry = $true }
Show-SimpleStart; Test-Layout $form 'Simple-Startseite (Per-Benutzer, Fehlerhinweis)'
$script:SimpleNotice = $null; $script:PerUserMode = $false
foreach ($case in 'Karte', 'Mehrere', 'Keine') {
    $script:SimpleCard = if ($case -eq 'Karte') { [pscustomobject]@{ FriendlyName = $long; PcscName = $pcsc; InstanceId = 'ROOT\SMARTCARDREADER\0001' } } else { $null }
    $script:SimpleReaderCount = if ($case -eq 'Mehrere') { 3 } else { 0 }
    Show-SimpleStart
    Test-Layout $form "Simple-Startseite ($case)"
}
$pnlSimple.Visible = $false
# --- Dialoge ---
try { Show-AboutDialog } catch { $global:Findings.Add("Show-AboutDialog Fehler: $($_.Exception.Message)") }
try { $null = Show-AccountInputDialog -Prefill 'administrator.langername@contoso.onmicrosoft.com' -Prompt (T 'Cloud-Zielkonto/UPN (Entra, z.B. gadmin@contoso.onmicrosoft.com):') } catch { $global:Findings.Add("Show-AccountInputDialog Fehler: $($_.Exception.Message)") }
$fakeReaders = @(1..3 | ForEach-Object { [pscustomobject]@{ FriendlyName = "$long$_"; InstanceId = "ROOT\SMARTCARDREADER\000$_"; Status = 'OK'; PcscName = "Microsoft Virtual Smart Card $_" } })
$fakeCerts = @(1..3 | ForEach-Object { [pscustomobject]@{ Subject = 'CN=administrator.langername@contoso.onmicrosoft.com'; Upn = 'administrator.langername@contoso.onmicrosoft.com'; Thumbprint = '0123456789ABCDEF0123456789ABCDEF0123456' + $_; NotBefore = (Get-Date); NotAfter = (Get-Date).AddYears(2); Provider = 'Microsoft Smart Card Key Storage Provider'; Reader = "Microsoft Virtual Smart Card $_"; KeyContainerName = 'x'; IsSmartCard = $true; DetectionError = $null } })
try { $null = Show-VscPickerDialog -Readers $fakeReaders -Certs $fakeCerts } catch { $global:Findings.Add("Show-VscPickerDialog Fehler: $($_.Exception.Message)") }
try { $null = Show-VscChoiceDialog } catch { $global:Findings.Add("Show-VscChoiceDialog Fehler: $($_.Exception.Message)") }
try { Show-VscPinChangeDialog -Reader $fakeReaders[0] -Owner $form } catch { $global:Findings.Add("Show-VscPinChangeDialog Fehler: $($_.Exception.Message)") }
try { Show-VscInventoryDialog -Owner $form } catch { $global:Findings.Add("Show-VscInventoryDialog Fehler: $($_.Exception.Message)") }
try { Show-SettingsDialog -Owner $form } catch { $global:Findings.Add("Show-SettingsDialog Fehler: $($_.Exception.Message)") }

"=== Geprüft ($($global:Audited.Count) Zustände) ==="
$global:Audited | Select-Object -Unique
""
"=== Befunde ($(@($global:Findings | Select-Object -Unique).Count)) ==="
$global:Findings | Select-Object -Unique
