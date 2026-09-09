<#
.SYNOPSIS
    VSC-Wizard - Wizard zur Beantragung virtueller Smartcards (TPM Virtual Smart Card) fuer AD-Administratoren.
.DESCRIPTION
    Fuehrt Schritt fuer Schritt durch die Erstellung einer virtuellen Smartcard und die
    Zertifikatsbeantragung. Unterstuetzt zwei Szenarien als Tabs:

      - Plan A: Domaenen-gebundener Rechner mit direkter Sicht auf die Enterprise-CA
                (voll automatisiert, CSR-Erstellung und Einreichung in einem Schritt).
      - Plan B: Entra-joined- oder Workgroup-Rechner ohne direkte CA-Sicht
                (CSR wird lokal erzeugt, per RDP-Login als Zielbenutzer auf einen
                CA-nahen Server eingereicht, Zertifikat wird zurueckkopiert und
                lokal auf der virtuellen Smartcard hinterlegt).
.NOTES
    Erfordert Windows mit TPM (fuer tpmvscmgr.exe) sowie certreq.exe.
    Die Erstellung der virtuellen Smartcard erfordert lokale Administratorrechte
    (gezielte UAC-Elevation fuer diesen einen Schritt); alle uebrigen Schritte laufen
    im normalen Benutzerkontext, da Zertifikate im Benutzer-Zertifikatsspeicher liegen.
#>

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

Import-Module (Join-Path $PSScriptRoot 'modules\VscWizard.Core.psm1') -Force

$script:ConfigPath = Join-Path $PSScriptRoot 'config.psd1'
$config = Import-VscWizardConfig -Path $script:ConfigPath

function New-WizardLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 760,
        [int]$Height = 24,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($Width, $Height)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, $Style)
    return $lbl
}

# $script:TargetAccount ist $null (= aktuell angemeldeter Benutzer) oder ein auf dem
# Landing-Screen eingegebenes Zielkonto. VSC- und CSR-Erstellung laufen unabhaengig
# davon immer im aktuellen Benutzerkontext (die Smartcard-PIN ist kontounabhaengig
# und certreq verwaltet offene Antraege im Profil des aufrufenden Benutzers) - nur
# die Einreichung bei der CA muss aus Berechtigungsgruenden als Zielkonto erfolgen.
function Get-EnrollmentIdentity {
    if ($script:TargetAccount) {
        $upn = if ($script:TargetAccount -match '@') { $script:TargetAccount } else { $null }
        $cn = if ($script:TargetAccount -match '\\') { ($script:TargetAccount -split '\\')[-1] } else { $script:TargetAccount }
        return [pscustomobject]@{ Subject = "CN=$cn"; Upn = $upn; DisplayName = $script:TargetAccount; SearchTerm = $cn }
    }
    return [pscustomobject]@{ Subject = "CN=$env:USERNAME"; Upn = (Get-CurrentUpn); DisplayName = "$env:USERDOMAIN\$env:USERNAME"; SearchTerm = $env:USERNAME }
}

function Invoke-EnrollmentAgentRequest {
    # Beantragt ein Enrollment-Agent-Zertifikat fuer das EIGENE Konto - eine ganz
    # normale Direkt-Beantragung (kein separates Konto, kein RDP). Wahlweise mit dem
    # Schluessel auf einer eigenen VSC (TPM/PIN, empfohlen) oder als CNG-Software-
    # Schluessel. Das Template bestimmt die EKU (Certificate Request Agent).
    param(
        [Parameter(Mandatory)][string]$Template,
        [switch]$OnVsc
    )

    $identity = [pscustomobject]@{ Subject = "CN=$env:USERNAME"; Upn = (Get-CurrentUpn) }
    $enrollDir = Join-Path (Get-WizardWorkingDir) "EA-$([guid]::NewGuid().ToString('N'))"

    if ($OnVsc) {
        $cardName = "$($config.VscNamePrefix)EA-$env:USERNAME"
        Write-WizardLog -Message "Erstelle VSC fuer EA-Zertifikat ('$cardName')." -Level Command
        $vsc = New-VirtualSmartCard -CardName $cardName
        if (-not $vsc.Success) {
            return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $null; Message = 'VSC-Erstellung fuer EA-Zertifikat fehlgeschlagen.' }
        }
        $csp = $config.CspName
    } else {
        # CNG-Software-KSP: kein Smartcard-Provider, kein PIN.
        $csp = 'Microsoft Software Key Storage Provider'
    }

    $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $csp -OutputDirectory $enrollDir
    if (-not $csr.Success) {
        return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $null; Message = 'Antragserstellung fehlgeschlagen.' }
    }

    $submit = Submit-CertificateSigningRequest -CsrPath $csr.CsrPath -CAConfig $config.CAConfig -TemplateName $Template -OutputDirectory $enrollDir
    if ($submit.Pending) {
        return [pscustomobject]@{ Success = $false; Pending = $true; RequestId = $submit.RequestId; Message = 'Wartet auf Genehmigung.' }
    }
    if (-not $submit.Success) {
        return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $submit.RequestId; Message = 'Antrag bei der CA fehlgeschlagen.' }
    }

    $complete = Complete-CertificateEnrollment -CerPath $submit.CerPath
    if ($complete.Success) {
        return [pscustomobject]@{ Success = $true; Pending = $false; RequestId = $submit.RequestId; Message = '' }
    }
    return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $submit.RequestId; Message = 'Uebernahme des EA-Zertifikats fehlgeschlagen.' }
}

# Einfache Hint/Placeholder-Eingabe: zeigt grauen Beispieltext, solange kein echter
# Wert eingetragen ist; verschwindet beim Fokussieren, kehrt beim Verlassen eines
# leeren Feldes zurueck. Erkennung "ist gerade Placeholder" ueber ForeColor=Gray.
# Funktioniert fuer TextBox und ComboBox gleichermassen (beide haben Text/ForeColor
# sowie Enter/Leave von System.Windows.Forms.Control).
$script:PlaceholderMap = @{}

function Set-TextBoxPlaceholder {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$TextBox,
        [Parameter(Mandatory)][string]$Placeholder,
        [string]$Value
    )
    $script:PlaceholderMap[$TextBox] = $Placeholder
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $TextBox.Text = $Placeholder
        $TextBox.ForeColor = [System.Drawing.Color]::Gray
    } else {
        $TextBox.Text = $Value
        $TextBox.ForeColor = [System.Drawing.SystemColors]::WindowText
    }

    $TextBox.Add_Enter({
        if ($this.ForeColor -eq [System.Drawing.Color]::Gray) {
            $this.Text = ''
            $this.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    })
    $TextBox.Add_Leave({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text = $script:PlaceholderMap[$this]
            $this.ForeColor = [System.Drawing.Color]::Gray
        }
    })
}

function Set-TextBoxRealValue {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Control]$TextBox,
        [Parameter(Mandatory)][string]$Value
    )
    $TextBox.Text = $Value
    $TextBox.ForeColor = [System.Drawing.SystemColors]::WindowText
}

function Get-TextBoxRealValue {
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$TextBox)
    if ($TextBox.ForeColor -eq [System.Drawing.Color]::Gray) { return '' }
    return $TextBox.Text
}

function Set-TemplateComboItem {
    # Nur EIN Zertifikatstemplate wird konfiguriert (Einstellungen) - diese Comboboxen
    # in Plan A/Plan B zeigen es lediglich vorausgewaehlt an.
    param(
        [Parameter(Mandatory)][System.Windows.Forms.ComboBox]$ComboBox,
        [string]$Template
    )
    $ComboBox.Items.Clear()
    if ($Template) { [void]$ComboBox.Items.Add($Template) }
    if ($ComboBox.Items.Count -gt 0) { $ComboBox.SelectedIndex = 0 }
}

#region MAIN FORM

$form = New-Object System.Windows.Forms.Form
$form.Text = 'VSC-Wizard - Virtuelle Smartcard beantragen'
$form.Size = New-Object System.Drawing.Size(940, 780)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(840, 660)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = 'Fill'
$mainLayout.RowCount = 3
$mainLayout.ColumnCount = 1
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 68)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 32)))
$form.Controls.Add($mainLayout)

#endregion

#region TOP BAR (schrittunabhaengig - auf jedem Schritt sichtbar, u.a. fuer Einstellungen)

$topBar = New-Object System.Windows.Forms.TableLayoutPanel
$topBar.Dock = 'Fill'
$topBar.ColumnCount = 2
$topBar.BackColor = [System.Drawing.SystemColors]::ControlLight
[void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
$mainLayout.Controls.Add($topBar, 0, 0)

$lblGlobalStep = New-Object System.Windows.Forms.Label
$lblGlobalStep.Dock = 'Fill'
$lblGlobalStep.TextAlign = 'MiddleLeft'
$lblGlobalStep.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblGlobalStep.Margin = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$topBar.Controls.Add($lblGlobalStep, 0, 0)

$btnOpenSettings = New-Object System.Windows.Forms.Button
$btnOpenSettings.Text = 'Einstellungen'
$btnOpenSettings.Dock = 'Fill'
$btnOpenSettings.Margin = New-Object System.Windows.Forms.Padding(6, 6, 10, 6)
$topBar.Controls.Add($btnOpenSettings, 1, 0)
$btnOpenSettings.Add_Click({ Show-SettingsDialog -Owner $form })

#endregion

#region STEP HOST (Inhaltsbereich + gemeinsame Weiter/Zurueck-Navigation)

$pnlStepHost = New-Object System.Windows.Forms.TableLayoutPanel
$pnlStepHost.Dock = 'Fill'
$pnlStepHost.RowCount = 2
$pnlStepHost.ColumnCount = 1
[void]$pnlStepHost.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pnlStepHost.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
$mainLayout.Controls.Add($pnlStepHost, 0, 1)

$pnlContentArea = New-Object System.Windows.Forms.Panel
$pnlContentArea.Dock = 'Fill'
$pnlStepHost.Controls.Add($pnlContentArea, 0, 0)

$navShared = New-Object System.Windows.Forms.TableLayoutPanel
$navShared.Dock = 'Fill'
$navShared.ColumnCount = 3
[void]$navShared.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$navShared.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$navShared.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
$pnlStepHost.Controls.Add($navShared, 0, 1)

$lblStepShared = New-Object System.Windows.Forms.Label
$lblStepShared.Dock = 'Fill'
$lblStepShared.TextAlign = 'MiddleLeft'
$navShared.Controls.Add($lblStepShared, 0, 0)

$btnBackShared = New-Object System.Windows.Forms.Button
$btnBackShared.Text = '< Zurueck'
$btnBackShared.Dock = 'Fill'
$navShared.Controls.Add($btnBackShared, 1, 0)

$btnNextShared = New-Object System.Windows.Forms.Button
$btnNextShared.Text = 'Weiter >'
$btnNextShared.Dock = 'Fill'
$navShared.Controls.Add($btnNextShared, 2, 0)

# $script:ActivePlan: $null = Schritt 1 (Moduswahl) ist aktiv, 'A'/'B' = der jeweilige
# Schritt-Satz ist aktiv. Weiter/Zurueck werten dies aus, um an die richtige Stelle zu
# delegieren (siehe Invoke-SharedNext/Back weiter unten, definiert nach Plan A/B).
$script:ActivePlan = $null

$tabPlanA = New-Object System.Windows.Forms.Panel
$tabPlanA.Dock = 'Fill'
$tabPlanA.Visible = $false
$pnlContentArea.Controls.Add($tabPlanA)

$tabPlanB = New-Object System.Windows.Forms.Panel
$tabPlanB.Dock = 'Fill'
$tabPlanB.Visible = $false
$pnlContentArea.Controls.Add($tabPlanB)

#endregion

#region SCHRITT 1: MODUSWAHL (Kontoauswahl + Plan A/B)

$pnlModeSelect = New-Object System.Windows.Forms.Panel
$pnlModeSelect.Dock = 'Fill'
$pnlContentArea.Controls.Add($pnlModeSelect)

$lblLandingTitle = New-WizardLabel -Text 'Fuer wen soll die virtuelle Smartcard beantragt werden?' -X 20 -Y 20 -Width 780 -Style Bold

$radSelf = New-Object System.Windows.Forms.RadioButton
$radSelf.Text = "Fuer mich (aktuell angemeldet als $env:USERDOMAIN\$env:USERNAME)"
$radSelf.Location = New-Object System.Drawing.Point(20, 60)
$radSelf.Size = New-Object System.Drawing.Size(700, 24)
$radSelf.Checked = $true

$radOther = New-Object System.Windows.Forms.RadioButton
$radOther.Text = 'Fuer ein separates Konto (z.B. Admin-Konto)'
$radOther.Location = New-Object System.Drawing.Point(20, 90)
$radOther.Size = New-Object System.Drawing.Size(700, 24)

$lblOtherAccount = New-WizardLabel -Text 'Zielkonto (z.B. CONTOSO\adm.mustermann oder UPN):' -X 40 -Y 122 -Width 500
$txtOtherAccount = New-Object System.Windows.Forms.TextBox
$txtOtherAccount.Location = New-Object System.Drawing.Point(40, 148)
$txtOtherAccount.Size = New-Object System.Drawing.Size(400, 24)
$txtOtherAccount.Enabled = $false

$lblOtherExplain = New-WizardLabel -Text 'Karten- und CSR-Erstellung laufen ganz normal in deinem eigenen Benutzerkontext - dafuer ist keine gesonderte Anmeldung als Zielkonto noetig (die Smartcard-PIN ist unabhaengig vom Windows-Konto). Nur die spaetere Einreichung bei der CA muss aus Berechtigungsgruenden als Zielkonto erfolgen; Plan B fuehrt dich an der passenden Stelle dorthin (z.B. per RDP), die Uebernahme des fertigen Zertifikats erfolgt danach wieder hier.' -X 40 -Y 178 -Width 760 -Height 60

$lblPlanChoiceTitle = New-WizardLabel -Text 'Welcher Ablauf?' -X 20 -Y 250 -Width 780 -Style Bold

$radPlanA = New-Object System.Windows.Forms.RadioButton
$radPlanA.Text = 'Plan A: AD-Domaene (direkte CA-Sicht, automatisiert)'
$radPlanA.Location = New-Object System.Drawing.Point(20, 284)
$radPlanA.Size = New-Object System.Drawing.Size(760, 24)

$radPlanB = New-Object System.Windows.Forms.RadioButton
$radPlanB.Text = 'Plan B: Entra / Workgroup (CSR lokal, Einreichung per RDP-Zwischenschritt)'
$radPlanB.Location = New-Object System.Drawing.Point(20, 310)
$radPlanB.Size = New-Object System.Drawing.Size(760, 24)

$lblPlanChoiceHint = New-WizardLabel -Text '' -X 40 -Y 340 -Width 740
$lblPlanChoiceHint.ForeColor = [System.Drawing.Color]::DimGray

# Fähigkeitsbasierte Prüfung: misst, ob von HIER direkt eingereicht werden kann
# (Kerberos-TGT + DNS + certutil-ping), statt aus dem Join-Status zu raten. Ergebnis
# überschreibt die Heuristik-Vorauswahl mit der gemessenen Wahrheit.
$btnCheckDirect = New-Object System.Windows.Forms.Button
$btnCheckDirect.Text = 'Direkt-Einreichung pruefen'
$btnCheckDirect.Location = New-Object System.Drawing.Point(40, 372)
$btnCheckDirect.Size = New-Object System.Drawing.Size(230, 30)

$txtDirectResult = New-Object System.Windows.Forms.TextBox
$txtDirectResult.Location = New-Object System.Drawing.Point(40, 410)
$txtDirectResult.Size = New-Object System.Drawing.Size(760, 120)
$txtDirectResult.Multiline = $true
$txtDirectResult.ReadOnly = $true
$txtDirectResult.ScrollBars = 'Vertical'
$txtDirectResult.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtDirectResult.Visible = $false

$lblLandingValidation = New-WizardLabel -Text '' -X 20 -Y 540 -Width 760
$lblLandingValidation.ForeColor = [System.Drawing.Color]::Firebrick

$pnlModeSelect.Controls.AddRange(@($lblLandingTitle, $radSelf, $radOther, $lblOtherAccount, $txtOtherAccount, $lblOtherExplain, $lblPlanChoiceTitle, $radPlanA, $radPlanB, $lblPlanChoiceHint, $btnCheckDirect, $txtDirectResult, $lblLandingValidation))

function Update-ModeSelectPlanChoice {
    # Der Domain-Join-Status ist nur eine HEURISTIK-Vorauswahl (sofort, ohne Netz),
    # kein belastbares Kriterium: ein DJ-Client kann off-net scheitern, ein EJ-Client
    # mit Cloud Kerberos Trust + korrektem DNS direkt einreichen. Die gemessene Wahrheit
    # liefert "Direkt-Einreichung pruefen" (Test-DirectEnrollmentCapability), das diese
    # Vorauswahl anschliessend ueberschreibt. Vom Nutzer jederzeit ueberschreibbar.
    $joinState = Get-DomainJoinState
    if ($radOther.Checked) {
        # Separates Konto: Plan A ist moeglich, WENN ein Enrollment-Agent-Zertifikat
        # vorliegt (Enroll on Behalf Of - bruchfrei, ohne RDP). Sonst bleibt nur
        # Plan B, da die Einreichung als Zielkonto erfolgen muss.
        $eaCount = @(Get-EnrollmentAgentCertificates).Count
        if ($eaCount -gt 0) {
            $radPlanA.Enabled = $true
            $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = "EA-Zertifikat gefunden: Plan A moeglich (EOBO, ohne RDP). Beachte: EA-Cert ist admin-aequivalent (ESC3) - fuer Admin-Konten ist Plan B (Self-Enrollment) oft sicherer. Plan B bleibt als Alternative."
        } else {
            $radPlanA.Enabled = $false
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = 'Kein EA-Zertifikat gefunden - fuer ein separates Konto daher Plan B (RDP). Mit einem EA-Zertifikat (in den Einstellungen beantragbar) ginge auch Plan A ohne RDP.'
        }
    } else {
        $radPlanA.Enabled = $true
        if ($joinState.Mode -eq 'ADDomain') {
            $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = "Vorschlag (Heuristik: Domaenen-Status $($joinState.Mode)): Plan A. Fuer Gewissheit 'Direkt-Einreichung pruefen'."
        } else {
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = "Vorschlag (Heuristik: Domaenen-Status $($joinState.Mode)): Plan B. Bei funktionierendem Cloud Kerberos Trust ist evtl. doch Plan A moeglich - 'Direkt-Einreichung pruefen' misst es."
        }
    }
}

$radSelf.Add_CheckedChanged({
    if ($radSelf.Checked) { $txtOtherAccount.Enabled = $false; Update-ModeSelectPlanChoice }
})

$radOther.Add_CheckedChanged({
    if ($radOther.Checked) { $txtOtherAccount.Enabled = $true; Update-ModeSelectPlanChoice }
})

$btnCheckDirect.Add_Click({
    $btnCheckDirect.Enabled = $false
    $txtDirectResult.Visible = $true
    $txtDirectResult.ForeColor = [System.Drawing.SystemColors]::WindowText
    $txtDirectResult.Text = 'Pruefe Direkt-Einreichung (Kerberos-Ticket, DNS, certutil -ping - bis zu ca. 45 Sekunden)...'
    $form.Refresh()

    # In einem Start-Job, da DNS/RPC/certutil bei nicht erreichbaren Zielen haengen koennen.
    $modulePath = Join-Path $PSScriptRoot 'modules\VscWizard.Core.psm1'
    $job = Start-Job -ScriptBlock {
        param($ModulePath, $CAConfig, $Server, $Timeout)
        Import-Module $ModulePath -Force
        Test-DirectEnrollmentCapability -CAConfig $CAConfig -Server $Server -TimeoutSeconds $Timeout
    } -ArgumentList $modulePath, $config.CAConfig, $config.DiscoveryDomain, 8

    $completed = Wait-Job -Job $job -Timeout 45
    $cap = if ($completed) { Receive-Job -Job $job } else { Stop-Job -Job $job; $null }
    Remove-Job -Job $job -Force

    if (-not $completed -or -not $cap) {
        $txtDirectResult.ForeColor = [System.Drawing.Color]::Firebrick
        $txtDirectResult.Text = 'Zeitueberschreitung (>45s) - CA/DC vermutlich nicht erreichbar (Netz/DNS/VPN pruefen). Vorerst Plan B verwenden.'
        Write-WizardLog -Message 'Direkt-Einreichungspruefung: Zeitueberschreitung.' -Level Error
        $btnCheckDirect.Enabled = $true
        return
    }

    $txtDirectResult.ForeColor = if ($cap.DirectPossible) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkOrange }
    $txtDirectResult.Text = "$($cap.Reason)`r`n`r`n$($cap.Detail)"
    Write-WizardLog -Message "Direkt-Einreichung: DirectPossible=$($cap.DirectPossible), Join=$($cap.JoinMode), TGT=$($cap.HasKerberosTgt), Ping=$($cap.CaPingOk)." -Level Info

    # Gemessenes Ergebnis ueberschreibt die Heuristik-Vorauswahl.
    if ($radSelf.Checked) {
        if ($cap.DirectPossible) {
            $radPlanA.Enabled = $true; $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = 'Gemessen: Direkt-Einreichung moeglich - Plan A.'
        } else {
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = 'Gemessen: Direkt-Einreichung derzeit nicht moeglich - Plan B (CA-Schritt delegieren). Grund siehe oben.'
        }
    } else {
        # Separates Konto: Plan-A-Verfuegbarkeit haengt zusaetzlich am EA-Zertifikat
        # (Update-ModeSelectPlanChoice); der Check zeigt hier die CA-Erreichbarkeit, die
        # auch fuer EOBO noetig ist.
        if (-not $cap.DirectPossible) {
            $txtDirectResult.Text += "`r`n`r`nHinweis: Auch der EOBO-Weg (Plan A mit EA-Zertifikat) braucht diese CA-Erreichbarkeit. Ist sie nicht gegeben, bleibt Plan B."
        }
    }
    $btnCheckDirect.Enabled = $true
})

function Show-ModeSelectStep {
    $script:ActivePlan = $null
    $tabPlanA.Visible = $false
    $tabPlanB.Visible = $false
    $pnlModeSelect.Visible = $true
    Update-ModeSelectPlanChoice
    $lblGlobalStep.Text = 'Schritt 1: Modus'
    $btnBackShared.Enabled = $false
    $btnNextShared.Enabled = $true
}

function Invoke-ModeSelectNextClick {
    if ($radOther.Checked) {
        if ([string]::IsNullOrWhiteSpace($txtOtherAccount.Text)) {
            $lblLandingValidation.Text = 'Bitte ein Zielkonto angeben.'
            return
        }
        $script:TargetAccount = $txtOtherAccount.Text.Trim()
    } else {
        $script:TargetAccount = $null
    }
    $lblLandingValidation.Text = ''
    $pnlModeSelect.Visible = $false
    if ($radPlanA.Checked) {
        $script:ActivePlan = 'A'
        $tabPlanA.Visible = $true
        Show-PlanAStep -Index 0
    } else {
        $script:ActivePlan = 'B'
        $tabPlanB.Visible = $true
        Show-PlanBStep -Index 0
    }
}

#endregion

#region LOG PANEL

$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = 'Log / Diagnose'
$logGroup.Dock = 'Fill'
$mainLayout.Controls.Add($logGroup, 0, 2)

$logLayout = New-Object System.Windows.Forms.TableLayoutPanel
$logLayout.Dock = 'Fill'
$logLayout.RowCount = 2
$logLayout.ColumnCount = 1
[void]$logLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$logLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$logGroup.Controls.Add($logLayout)

$logToolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$logToolbar.Dock = 'Fill'
$logToolbar.FlowDirection = 'RightToLeft'
$logLayout.Controls.Add($logToolbar, 0, 0)

$btnExportLog = New-Object System.Windows.Forms.Button
$btnExportLog.Text = 'Log exportieren...'
$btnExportLog.Size = New-Object System.Drawing.Size(140, 26)
$logToolbar.Controls.Add($btnExportLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'
$rtbLog.ReadOnly = $true
$rtbLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$logLayout.Controls.Add($rtbLog, 0, 1)

$btnExportLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Textdatei (*.txt)|*.txt'
    $dlg.FileName = "vscwizard-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $rtbLog.SaveFile($dlg.FileName, [System.Windows.Forms.RichTextBoxStreamType]::PlainText)
    }
})

Initialize-WizardLog -LogBox $rtbLog
Write-WizardLog -Message 'VSC-Wizard gestartet.' -Level Info

#endregion

# ============================================================================
#region PLAN A TAB
# ============================================================================

$pnlStepsA = New-Object System.Windows.Forms.Panel
$pnlStepsA.Dock = 'Fill'
$tabPlanA.Controls.Add($pnlStepsA)

# --- Schritt A1: Status ---
$pnlA1 = New-Object System.Windows.Forms.Panel
$pnlA1.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA1)

$lblJoinStateA = New-WizardLabel -Text 'Domaenen-Status: ...' -X 20 -Y 20
$lblUserA = New-WizardLabel -Text 'Angemeldeter Benutzer: ...' -X 20 -Y 50
$lblTpmA = New-WizardLabel -Text 'TPM: ...' -X 20 -Y 80
$lblWarnA = New-WizardLabel -Text '' -X 20 -Y 120 -Style Bold
$pnlA1.Controls.AddRange(@($lblJoinStateA, $lblUserA, $lblTpmA, $lblWarnA))

# --- Schritt A2: VSC erstellen ---
$pnlA2 = New-Object System.Windows.Forms.Panel
$pnlA2.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA2)

$lblCardNameA = New-WizardLabel -Text 'Name der virtuellen Smartcard:' -X 20 -Y 20 -Width 300
$txtCardNameA = New-Object System.Windows.Forms.TextBox
$txtCardNameA.Location = New-Object System.Drawing.Point(20, 46)
$txtCardNameA.Size = New-Object System.Drawing.Size(300, 24)
$txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"

$lblVscInfoA = New-WizardLabel -Text 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur fuer diesen Schritt benoetigt). Danach oeffnet sich ein Dialog zur Eingabe der Karten-PIN (mindestens 6 Zeichen, mit Bestaetigung; der Dialog zeigt die geltende Mindestlaenge an). Die Karte wird anschliessend ueber die Windows-Smartcard-API erstellt.' -X 20 -Y 84 -Width 780 -Height 76

$btnCreateVscA = New-Object System.Windows.Forms.Button
$btnCreateVscA.Text = 'Virtuelle Smartcard erstellen'
$btnCreateVscA.Location = New-Object System.Drawing.Point(20, 172)
$btnCreateVscA.Size = New-Object System.Drawing.Size(240, 32)

$lblVscResultA = New-WizardLabel -Text '' -X 20 -Y 216 -Width 780

$pnlA2.Controls.AddRange(@($lblCardNameA, $txtCardNameA, $lblVscInfoA, $btnCreateVscA, $lblVscResultA))

$btnCreateVscA.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCardNameA.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte einen Kartennamen angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateVscA.Enabled = $false
    $lblVscResultA.ForeColor = [System.Drawing.Color]::Black
    $lblVscResultA.Text = 'Erstelle virtuelle Smartcard - bitte UAC bestaetigen, dann im Dialog die PIN festlegen...'
    $form.Refresh()

    try {
        $result = New-VirtualSmartCard -CardName $txtCardNameA.Text
    } catch {
        $result = [pscustomobject]@{ Success = $false; ExitCode = $null; Message = $_.Exception.Message }
        Write-WizardLog -Message "Unerwarteter Fehler bei der VSC-Erstellung: $($_.Exception.Message)" -Level Error
    }
    if ($result.Success) {
        $script:PlanA_VscCreated = $true
        $script:PlanA_CardName = $txtCardNameA.Text
        $script:PlanA_PcscName = $result.PcscName
        $lblVscResultA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblVscResultA.Text = if ($result.PcscName) {
            "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der Zertifikatsanforderung) heisst sie: '$($result.PcscName)'."
        } else {
            'Virtuelle Smartcard wurde erfolgreich erstellt.'
        }
    } else {
        $lblVscResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $detail = if ($result.Message) { $result.Message } else { "Exit-Code $($result.ExitCode)" }
        $lblVscResultA.Text = "Fehler bei der Erstellung: $detail (Details siehe Log)."
    }
    $btnCreateVscA.Enabled = $true
})

# --- Schritt A3: Zertifikat anfordern ---
$pnlA3 = New-Object System.Windows.Forms.Panel
$pnlA3.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA3)

$lblCardHintA = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 34
$lblCardHintA.ForeColor = [System.Drawing.Color]::SteelBlue

$lblTemplateA = New-WizardLabel -Text 'Zertifikatstemplate:' -X 20 -Y 58 -Width 300
$cboTemplateA = New-Object System.Windows.Forms.ComboBox
$cboTemplateA.Location = New-Object System.Drawing.Point(20, 84)
$cboTemplateA.Size = New-Object System.Drawing.Size(300, 24)
$cboTemplateA.DropDownStyle = 'DropDownList'
Set-TemplateComboItem -ComboBox $cboTemplateA -Template $config.Template

$btnRequestCertA = New-Object System.Windows.Forms.Button
$btnRequestCertA.Text = 'Zertifikat anfordern'
$btnRequestCertA.Location = New-Object System.Drawing.Point(20, 122)
$btnRequestCertA.Size = New-Object System.Drawing.Size(240, 32)

$lblCertResultA = New-WizardLabel -Text '' -X 20 -Y 166 -Width 780 -Height 50

$btnRetrieveA = New-Object System.Windows.Forms.Button
$btnRetrieveA.Text = 'Zertifikat abrufen (bei Genehmigung)'
$btnRetrieveA.Location = New-Object System.Drawing.Point(20, 228)
$btnRetrieveA.Size = New-Object System.Drawing.Size(260, 32)
$btnRetrieveA.Visible = $false

$pnlA3.Controls.AddRange(@($lblCardHintA, $lblTemplateA, $cboTemplateA, $btnRequestCertA, $lblCertResultA, $btnRetrieveA))

$btnRequestCertA.Add_Click({
    # Fuer ein separates Zielkonto ist die Direkt-Ausstellung nur ueber Enroll on
    # Behalf Of moeglich (die CA prueft die Enroll-Berechtigung sonst gegen die
    # EIGENE Identitaet). Dafuer braucht es ein Enrollment-Agent-Zertifikat im
    # eigenen Speicher; fehlt es, bleibt der Plan-B/RDP-Weg.
    $eoboThumbprint = $null
    if ($script:TargetAccount) {
        $eaCerts = @(Get-EnrollmentAgentCertificates)
        if ($eaCerts.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Fuer ein separates Konto ist hier ein Enrollment-Agent-Zertifikat noetig (Enroll on Behalf Of) - es wurde keins im Zertifikatsspeicher gefunden. Entweder in den Einstellungen ein EA-Zertifikat beantragen und diesen Schritt wiederholen, oder stattdessen Plan B (RDP) verwenden.', 'Separates Konto: EA-Zertifikat noetig', 'OK', 'Information') | Out-Null
            return
        }
        $eoboThumbprint = $eaCerts[0].Thumbprint
    }
    if (-not $cboTemplateA.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show('Bitte ein Zertifikatstemplate auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnRequestCertA.Enabled = $false
    $lblCertResultA.ForeColor = [System.Drawing.Color]::Black
    $lblCertResultA.Text = if ($eoboThumbprint) {
        'Erstelle Enroll-on-Behalf-Of-Antrag - ggf. erscheinen PIN-Dialoge (neue Karte und EA-Zertifikat)...'
    } else {
        'Erstelle Zertifikatsanforderung - ggf. erscheint ein PIN-Dialog der Smartcard...'
    }
    $form.Refresh()

    $script:PlanA_EnrollDir = Join-Path (Get-WizardWorkingDir) "PlanA-$($script:PlanA_CardName)"
    $identity = Get-EnrollmentIdentity

    if ($eoboThumbprint) {
        # EOBO: Zielkonto + Template gehoeren in den PKCS7-Antrag, der mit dem
        # EA-Zertifikat co-signiert wird. Das Template wird beim Submit dann NICHT
        # nochmal per -attrib gesetzt.
        $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $config.CspName -OutputDirectory $script:PlanA_EnrollDir -RequesterName $identity.DisplayName -TemplateName $cboTemplateA.SelectedItem -SigningCertThumbprint $eoboThumbprint
    } else {
        $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $config.CspName -OutputDirectory $script:PlanA_EnrollDir
    }
    if (-not $csr.Success) {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = 'Antragserstellung fehlgeschlagen. Details siehe Log.'
        $btnRequestCertA.Enabled = $true
        return
    }

    $submitTemplate = if ($eoboThumbprint) { $null } else { $cboTemplateA.SelectedItem }
    $submit = Submit-CertificateSigningRequest -CsrPath $csr.CsrPath -CAConfig $config.CAConfig -TemplateName $submitTemplate -OutputDirectory $script:PlanA_EnrollDir
    if ($submit.Pending) {
        $script:PlanA_PendingRequestId = $submit.RequestId
        # Zustand persistieren: der wartende Antrag kann nach einem Wizard-Neustart
        # ueber den Fortsetzen-Dialog beim Start wieder aufgenommen werden.
        Save-WizardResumeState -State @{
            Plan = 'A'; Stage = 'Pending'; RequestId = $submit.RequestId
            CardName = $script:PlanA_CardName; PcscName = "$($script:PlanA_PcscName)"
            EnrollDir = $script:PlanA_EnrollDir
        }
        $lblCertResultA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblCertResultA.Text = "Antrag wurde eingereicht und wartet auf Genehmigung (RequestId $($submit.RequestId)). Bitte spaeter erneut abrufen - auch nach einem Neustart des Wizards moeglich."
        $btnRetrieveA.Visible = $true
        $btnRequestCertA.Enabled = $true
        return
    }
    if (-not $submit.Success) {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = 'Antrag fehlgeschlagen. Details siehe Log.'
        $btnRequestCertA.Enabled = $true
        return
    }

    $complete = Complete-CertificateEnrollment -CerPath $submit.CerPath
    if ($complete.Success) {
        $script:PlanA_CertIssued = $true
        Clear-WizardResumeState
        $lblCertResultA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCertResultA.Text = 'Zertifikat wurde erfolgreich auf der virtuellen Smartcard hinterlegt.'
    } else {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = 'Uebernahme des Zertifikats fehlgeschlagen. Details siehe Log.'
    }
    $btnRequestCertA.Enabled = $true
})

$btnRetrieveA.Add_Click({
    if (-not $script:PlanA_PendingRequestId) { return }
    $recv = Receive-PendingCertificate -RequestId $script:PlanA_PendingRequestId -CAConfig $config.CAConfig -OutputDirectory $script:PlanA_EnrollDir
    if ($recv.Success) {
        $complete = Complete-CertificateEnrollment -CerPath $recv.CerPath
        if ($complete.Success) {
            $script:PlanA_CertIssued = $true
            Clear-WizardResumeState
            $btnRetrieveA.Visible = $false
            $lblCertResultA.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblCertResultA.Text = 'Zertifikat wurde erfolgreich abgerufen und auf der virtuellen Smartcard hinterlegt.'
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show('Zertifikat ist noch nicht ausgestellt.', 'Hinweis', 'OK', 'Information') | Out-Null
    }
})

# --- Schritt A4: Zusammenfassung ---
$pnlA4 = New-Object System.Windows.Forms.Panel
$pnlA4.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA4)

$lblSummaryA = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 140
$btnResetA = New-Object System.Windows.Forms.Button
$btnResetA.Text = 'Weitere Smartcard beantragen'
$btnResetA.Location = New-Object System.Drawing.Point(20, 170)
$btnResetA.Size = New-Object System.Drawing.Size(240, 32)

$pnlA4.Controls.AddRange(@($lblSummaryA, $btnResetA))

function Update-PlanASummary {
    $summary = Get-IssuedCertificateSummary -SubjectContains (Get-EnrollmentIdentity).SearchTerm
    if ($summary) {
        $lblSummaryA.Text = "Kartenname: $($script:PlanA_CardName)`r`nZertifikat: $($summary.Subject)`r`nThumbprint: $($summary.Thumbprint)`r`nGueltig ab: $($summary.NotBefore)`r`nGueltig bis: $($summary.NotAfter)"
    } else {
        $lblSummaryA.Text = 'Kein passendes Zertifikat gefunden.'
    }
}

$btnResetA.Add_Click({
    $script:PlanA_VscCreated = $false
    $script:PlanA_CertIssued = $false
    $script:PlanA_PendingRequestId = $null
    $txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"
    $lblVscResultA.Text = ''
    $lblCertResultA.Text = ''
    $btnRetrieveA.Visible = $false
    Show-PlanAStep -Index 1
})

# --- Navigation Plan A ---
$planAStepTitles = @('Status', 'Virtuelle Smartcard erstellen', 'Zertifikat anfordern', 'Zusammenfassung')

function Update-PlanAStatus {
    $joinState = Get-DomainJoinState
    $tpm = Test-TpmReadiness
    $upn = Get-CurrentUpn

    $lblJoinStateA.Text = "Domaenen-Status: $($joinState.Mode)" + $(if ($joinState.Domain) { " ($($joinState.Domain))" } else { '' })
    $lblUserA.Text = "Angemeldeter Benutzer: $env:USERDOMAIN\$env:USERNAME" + $(if ($upn) { " (UPN: $upn)" } else { '' })
    $lblTpmA.Text = "TPM: vorhanden=$($tpm.Present), bereit=$($tpm.Ready)"

    if ($script:TargetAccount) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblWarnA.Text = "Smartcard wird fuer ein separates Konto beantragt ($($script:TargetAccount)) - die Ausstellung in Schritt 3 erfolgt bruchfrei per Enroll on Behalf Of (Enrollment-Agent-Zertifikat), ohne RDP."
    } elseif ($joinState.Mode -ne 'ADDomain') {
        $lblWarnA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblWarnA.Text = 'Dieser Rechner scheint nicht domaenen-gebunden zu sein. Fuer diesen Fall ist "Plan B" vorgesehen.'
    } elseif (-not $tpm.Ready) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblWarnA.Text = 'Kein bereites TPM erkannt - die Erstellung einer virtuellen Smartcard ist eventuell nicht moeglich.'
    } else {
        $lblWarnA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblWarnA.Text = 'Voraussetzungen erfuellt.'
    }
}

function Show-PlanAStep {
    param([int]$Index)
    $panels = @($pnlA1, $pnlA2, $pnlA3, $pnlA4)
    for ($i = 0; $i -lt $panels.Count; $i++) {
        $panels[$i].Visible = ($i -eq $Index)
    }
    $script:PlanACurrentStep = $Index
    # Globale Schrittnummer: +1, da Schritt 1 (Moduswahl) davor liegt.
    $lblGlobalStep.Text = "Schritt $($Index + 2) von $($panels.Count + 1): $($planAStepTitles[$Index])"
    $btnBackShared.Enabled = $true
    $btnNextShared.Enabled = ($Index -lt $panels.Count - 1)

    switch ($Index) {
        0 { Update-PlanAStatus }
        2 {
            # Windows-Kartenauswahl-/PIN-Dialoge zeigen NICHT den vergebenen
            # Kartennamen, sondern den PC/SC-Namen "Microsoft Virtual Smart Card N".
            $lblCardHintA.Text = if ($script:PlanA_PcscName) {
                "Hinweis: im Windows-Kartenauswahl-Dialog die Karte '$($script:PlanA_PcscName)' waehlen (das ist '$($script:PlanA_CardName)')."
            } else { '' }
        }
        3 { Update-PlanASummary }
    }
}

function Invoke-PlanANextClick {
    switch ($script:PlanACurrentStep) {
        0 { Show-PlanAStep -Index 1 }
        1 {
            if (-not $script:PlanA_VscCreated) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst die virtuelle Smartcard erstellen.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanAStep -Index 2
        }
        2 {
            if (-not $script:PlanA_CertIssued) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst das Zertifikat erfolgreich anfordern.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanAStep -Index 3
        }
    }
}

function Invoke-PlanABackClick {
    if ($script:PlanACurrentStep -gt 0) {
        Show-PlanAStep -Index ($script:PlanACurrentStep - 1)
    } else {
        $tabPlanA.Visible = $false
        Show-ModeSelectStep
    }
}

#endregion

# ============================================================================
#region PLAN B TAB
# ============================================================================

$pnlStepsB = New-Object System.Windows.Forms.Panel
$pnlStepsB.Dock = 'Fill'
$tabPlanB.Controls.Add($pnlStepsB)

# --- Schritt B1: Status ---
$pnlB1 = New-Object System.Windows.Forms.Panel
$pnlB1.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB1)

$lblJoinStateB = New-WizardLabel -Text 'Domaenen-Status: ...' -X 20 -Y 20
$lblUserB = New-WizardLabel -Text 'Angemeldeter Benutzer: ...' -X 20 -Y 50
$lblTargetB = New-WizardLabel -Text '' -X 20 -Y 80
$lblJumpServerB = New-WizardLabel -Text '' -X 20 -Y 110
$lblExplainB = New-WizardLabel -Text 'Dieser Modus fuehrt eine virtuelle Smartcard und einen Zertifikatsantrag ueber einen Zwischenschritt per RDP durch, da entweder dieser Rechner keine direkte Sicht auf die Zertifizierungsstelle hat oder die Einreichung als separates Zielkonto erfolgen muss. CA-Konfiguration und automatische PKI-Erkennung finden sich im Tab "Einstellungen".' -X 20 -Y 146 -Width 780 -Height 60
$pnlB1.Controls.AddRange(@($lblJoinStateB, $lblUserB, $lblTargetB, $lblJumpServerB, $lblExplainB))

# --- Schritt B2: VSC erstellen ---
$pnlB2 = New-Object System.Windows.Forms.Panel
$pnlB2.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB2)

$lblCardNameB = New-WizardLabel -Text 'Name der virtuellen Smartcard:' -X 20 -Y 20 -Width 300
$txtCardNameB = New-Object System.Windows.Forms.TextBox
$txtCardNameB.Location = New-Object System.Drawing.Point(20, 46)
$txtCardNameB.Size = New-Object System.Drawing.Size(300, 24)
$txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"

$lblVscInfoB = New-WizardLabel -Text 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur fuer diesen Schritt benoetigt). Danach oeffnet sich ein Dialog zur Eingabe der Karten-PIN (mindestens 6 Zeichen, mit Bestaetigung; der Dialog zeigt die geltende Mindestlaenge an). Die Karte wird anschliessend ueber die Windows-Smartcard-API erstellt.' -X 20 -Y 84 -Width 780 -Height 76

$btnCreateVscB = New-Object System.Windows.Forms.Button
$btnCreateVscB.Text = 'Virtuelle Smartcard erstellen'
$btnCreateVscB.Location = New-Object System.Drawing.Point(20, 172)
$btnCreateVscB.Size = New-Object System.Drawing.Size(240, 32)

$lblVscResultB = New-WizardLabel -Text '' -X 20 -Y 216 -Width 780

$pnlB2.Controls.AddRange(@($lblCardNameB, $txtCardNameB, $lblVscInfoB, $btnCreateVscB, $lblVscResultB))

$btnCreateVscB.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCardNameB.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte einen Kartennamen angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateVscB.Enabled = $false
    $lblVscResultB.ForeColor = [System.Drawing.Color]::Black
    $lblVscResultB.Text = 'Erstelle virtuelle Smartcard - bitte UAC bestaetigen, dann im Dialog die PIN festlegen...'
    $form.Refresh()

    try {
        $result = New-VirtualSmartCard -CardName $txtCardNameB.Text
    } catch {
        $result = [pscustomobject]@{ Success = $false; ExitCode = $null; Message = $_.Exception.Message }
        Write-WizardLog -Message "Unerwarteter Fehler bei der VSC-Erstellung: $($_.Exception.Message)" -Level Error
    }
    if ($result.Success) {
        $script:PlanB_VscCreated = $true
        $script:PlanB_CardName = $txtCardNameB.Text
        $script:PlanB_PcscName = $result.PcscName
        $lblVscResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblVscResultB.Text = if ($result.PcscName) {
            "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der CSR-Erstellung) heisst sie: '$($result.PcscName)'."
        } else {
            'Virtuelle Smartcard wurde erfolgreich erstellt.'
        }
    } else {
        $lblVscResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $detail = if ($result.Message) { $result.Message } else { "Exit-Code $($result.ExitCode)" }
        $lblVscResultB.Text = "Fehler bei der Erstellung: $detail (Details siehe Log)."
    }
    $btnCreateVscB.Enabled = $true
})

# --- Schritt B3: CSR erstellen (lokal) ---
$pnlB3 = New-Object System.Windows.Forms.Panel
$pnlB3.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB3)

$lblCsrInfoB = New-WizardLabel -Text 'Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Es erscheint ggf. ein PIN-Dialog der Smartcard.' -X 20 -Y 20 -Width 780 -Height 40

$btnCreateCsrB = New-Object System.Windows.Forms.Button
$btnCreateCsrB.Text = 'CSR erstellen'
$btnCreateCsrB.Location = New-Object System.Drawing.Point(20, 66)
$btnCreateCsrB.Size = New-Object System.Drawing.Size(240, 32)

$lblCsrPathLabelB = New-WizardLabel -Text 'Pfad der CSR-Datei:' -X 20 -Y 110 -Width 300
$txtCsrPathB = New-Object System.Windows.Forms.TextBox
$txtCsrPathB.Location = New-Object System.Drawing.Point(20, 136)
$txtCsrPathB.Size = New-Object System.Drawing.Size(560, 24)
$txtCsrPathB.ReadOnly = $true

$btnCopyCsrPathB = New-Object System.Windows.Forms.Button
$btnCopyCsrPathB.Text = 'Pfad kopieren'
$btnCopyCsrPathB.Location = New-Object System.Drawing.Point(590, 134)
$btnCopyCsrPathB.Size = New-Object System.Drawing.Size(120, 28)

$btnOpenCsrFolderB = New-Object System.Windows.Forms.Button
$btnOpenCsrFolderB.Text = 'Ordner oeffnen'
$btnOpenCsrFolderB.Location = New-Object System.Drawing.Point(20, 172)
$btnOpenCsrFolderB.Size = New-Object System.Drawing.Size(160, 28)

$lblCsrTextLabelB = New-WizardLabel -Text 'CSR-Text (PEM) - Alternative zur Dateifreigabe: per RDP-Zwischenablage in den Einreichungshelfer (VscWizard.Submit.ps1) auf dem Zielserver einfuegen:' -X 20 -Y 216 -Width 780 -Height 34
$txtCsrTextB = New-Object System.Windows.Forms.TextBox
$txtCsrTextB.Location = New-Object System.Drawing.Point(20, 254)
$txtCsrTextB.Size = New-Object System.Drawing.Size(780, 120)
$txtCsrTextB.Multiline = $true
$txtCsrTextB.ReadOnly = $true
$txtCsrTextB.ScrollBars = 'Vertical'
$txtCsrTextB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnCopyCsrTextB = New-Object System.Windows.Forms.Button
$btnCopyCsrTextB.Text = 'CSR-Text kopieren'
$btnCopyCsrTextB.Location = New-Object System.Drawing.Point(20, 380)
$btnCopyCsrTextB.Size = New-Object System.Drawing.Size(160, 28)

$pnlB3.Controls.AddRange(@($lblCsrInfoB, $btnCreateCsrB, $lblCsrPathLabelB, $txtCsrPathB, $btnCopyCsrPathB, $btnOpenCsrFolderB, $lblCsrTextLabelB, $txtCsrTextB, $btnCopyCsrTextB))

$btnCreateCsrB.Add_Click({
    if (-not $script:PlanB_VscCreated) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst die virtuelle Smartcard erstellen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateCsrB.Enabled = $false
    $script:PlanB_EnrollDir = Join-Path (Get-WizardWorkingDir) "PlanB-$($script:PlanB_CardName)"
    $identity = Get-EnrollmentIdentity

    $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $config.CspName -OutputDirectory $script:PlanB_EnrollDir
    if ($csr.Success) {
        $script:PlanB_CsrPath = $csr.CsrPath
        $txtCsrPathB.Text = $csr.CsrPath
        try {
            $txtCsrTextB.Text = Get-Content -Path $csr.CsrPath -Raw
        } catch {
            $txtCsrTextB.Text = ''
        }
        # Zustand persistieren: CSR existiert, Einreichung steht noch aus - kann
        # nach einem Wizard-Neustart fortgesetzt werden.
        Save-WizardResumeState -State @{
            Plan = 'B'; Stage = 'Csr'; CsrPath = $csr.CsrPath
            CardName = $script:PlanB_CardName; PcscName = "$($script:PlanB_PcscName)"
            TargetAccount = "$($script:TargetAccount)"
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show('CSR-Erstellung fehlgeschlagen. Details siehe Log.', 'Fehler', 'OK', 'Error') | Out-Null
    }
    $btnCreateCsrB.Enabled = $true
})

$btnCopyCsrPathB.Add_Click({
    if ($txtCsrPathB.Text) { Set-WizardClipboard -Text $txtCsrPathB.Text }
})

$btnOpenCsrFolderB.Add_Click({
    if ($txtCsrPathB.Text) { Open-WizardFolder -Path $txtCsrPathB.Text }
})

$btnCopyCsrTextB.Add_Click({
    if ($txtCsrTextB.Text) { Set-WizardClipboard -Text $txtCsrTextB.Text }
})

# --- Schritt B4: Uebergabe per RDP ---
$pnlB4 = New-Object System.Windows.Forms.Panel
$pnlB4.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB4)

$lblHandoffB = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 220
$pnlB4.Controls.Add($lblHandoffB)

function Update-PlanBHandoff {
    $identity = Get-EnrollmentIdentity
    $reason = if ($script:TargetAccount) {
        "Die Einreichung bei der CA muss als $($identity.DisplayName) erfolgen (Berechtigungspruefung der CA basiert auf dem einreichenden Konto) - dieser Rechner reicht dafuer nicht, unabhaengig vom Domaenen-Status."
    } else {
        'Dieser Rechner hat vermutlich keine direkte Sicht auf die Zertifizierungsstelle.'
    }

    $lblHandoffB.Text = @"
Naechste Schritte:

$reason

1. Per RDP verbinden mit: $($config.RdpJumpServer)
2. Dort anmelden als: $($identity.DisplayName)
3. Die CSR-Datei auf den Server kopieren (z.B. ueber Zwischenablage/Laufwerksfreigabe):
   $($script:PlanB_CsrPath)
4. Diesen Wizard auf dem Server erneut starten, ebenfalls den Tab "Plan B" waehlen
   und bis zu Schritt "Antrag einreichen (auf dem Server)" weiterklicken.

Auf "Weiter" klicken, sobald du auf dem Server angemeldet bist. Die Uebernahme des
fertigen Zertifikats (Schritt 6) erfolgt danach wieder auf DIESEM Rechner in DEINEM
eigenen Konto - certreq verwaltet den offenen Antrag hier, nicht beim Zielkonto.
"@
}

# --- Schritt B5: Antrag einreichen (auf dem Server) ---
$pnlB5 = New-Object System.Windows.Forms.Panel
$pnlB5.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB5)

$lblSubmitInfoB = New-WizardLabel -Text 'Auf dem CA-nahen Server auszufuehren (angemeldet als Zielbenutzer). Standardweg: den per Zwischenablage mitgebrachten CSR-Text unten einfuegen. Wurde der Antrag bereits anderweitig eingereicht (z.B. mit dem Einreichungshelfer VscWizard.Submit.ps1), diesen Schritt einfach mit "Weiter" ueberspringen.' -X 20 -Y 20 -Width 780 -Height 50

$lblCsrPasteLabelB = New-WizardLabel -Text 'CSR-Text (PEM) einfuegen:' -X 20 -Y 74 -Width 300
$txtCsrPasteB = New-Object System.Windows.Forms.TextBox
$txtCsrPasteB.Location = New-Object System.Drawing.Point(20, 100)
$txtCsrPasteB.Size = New-Object System.Drawing.Size(780, 90)
$txtCsrPasteB.Multiline = $true
$txtCsrPasteB.ScrollBars = 'Vertical'
$txtCsrPasteB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnSelectCsrB = New-Object System.Windows.Forms.Button
$btnSelectCsrB.Text = '...oder CSR-Datei auswaehlen'
$btnSelectCsrB.Location = New-Object System.Drawing.Point(20, 198)
$btnSelectCsrB.Size = New-Object System.Drawing.Size(200, 28)

$txtSelectedCsrB = New-Object System.Windows.Forms.TextBox
$txtSelectedCsrB.Location = New-Object System.Drawing.Point(230, 200)
$txtSelectedCsrB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCsrB.ReadOnly = $true

$lblTemplateSubmitB = New-WizardLabel -Text 'Zertifikatstemplate:' -X 20 -Y 236 -Width 200
$cboTemplateSubmitB = New-Object System.Windows.Forms.ComboBox
$cboTemplateSubmitB.Location = New-Object System.Drawing.Point(230, 232)
$cboTemplateSubmitB.Size = New-Object System.Drawing.Size(300, 24)
$cboTemplateSubmitB.DropDownStyle = 'DropDownList'
Set-TemplateComboItem -ComboBox $cboTemplateSubmitB -Template $config.Template

$btnSubmitB = New-Object System.Windows.Forms.Button
$btnSubmitB.Text = 'Einreichen'
$btnSubmitB.Location = New-Object System.Drawing.Point(20, 270)
$btnSubmitB.Size = New-Object System.Drawing.Size(200, 32)

$btnRetrieveB = New-Object System.Windows.Forms.Button
$btnRetrieveB.Text = 'Zertifikat abrufen (bei Genehmigung)'
$btnRetrieveB.Location = New-Object System.Drawing.Point(230, 270)
$btnRetrieveB.Size = New-Object System.Drawing.Size(260, 32)
$btnRetrieveB.Visible = $false

$lblSubmitResultB = New-WizardLabel -Text '' -X 20 -Y 310 -Width 780 -Height 40

$lblCerPathLabelB = New-WizardLabel -Text 'Pfad der ausgestellten Zertifikatsdatei:' -X 20 -Y 354 -Width 400
$txtCerPathB = New-Object System.Windows.Forms.TextBox
$txtCerPathB.Location = New-Object System.Drawing.Point(20, 380)
$txtCerPathB.Size = New-Object System.Drawing.Size(560, 24)
$txtCerPathB.ReadOnly = $true

$btnCopyCerPathB = New-Object System.Windows.Forms.Button
$btnCopyCerPathB.Text = 'Pfad kopieren'
$btnCopyCerPathB.Location = New-Object System.Drawing.Point(590, 378)
$btnCopyCerPathB.Size = New-Object System.Drawing.Size(120, 28)

$btnOpenCerFolderB = New-Object System.Windows.Forms.Button
$btnOpenCerFolderB.Text = 'Ordner oeffnen'
$btnOpenCerFolderB.Location = New-Object System.Drawing.Point(20, 416)
$btnOpenCerFolderB.Size = New-Object System.Drawing.Size(160, 28)

$pnlB5.Controls.AddRange(@($lblSubmitInfoB, $lblCsrPasteLabelB, $txtCsrPasteB, $btnSelectCsrB, $txtSelectedCsrB, $lblTemplateSubmitB, $cboTemplateSubmitB, $btnSubmitB, $btnRetrieveB, $lblSubmitResultB, $lblCerPathLabelB, $txtCerPathB, $btnCopyCerPathB, $btnOpenCerFolderB))

$btnSelectCsrB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSR-Dateien (*.csr;*.req)|*.csr;*.req|Alle Dateien (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSelectedCsrB.Text = $dlg.FileName
    }
})

$btnSubmitB.Add_Click({
    # Standardweg: eingefuegter CSR-Text (der Text-Workflow erzeugt auf dieser
    # Maschine keine CSR-Datei); die Dateiauswahl bleibt als Alternative.
    $csrPath = $null
    if (-not [string]::IsNullOrWhiteSpace($txtCsrPasteB.Text)) {
        $csrPath = Join-Path (Get-WizardWorkingDir) "PlanB-pasted-$([guid]::NewGuid()).req"
        Set-Content -Path $csrPath -Value $txtCsrPasteB.Text -Encoding ASCII
    } elseif ($txtSelectedCsrB.Text) {
        $csrPath = $txtSelectedCsrB.Text
        # Manuell gespeicherte CSR-Dateien kommen je nach Editor als UTF-16 oder
        # UTF-8-mit-BOM daher - certreq erwartet ASCII/ANSI-PEM ohne BOM und
        # scheitert sonst mit CRYPT_E_ASN1_BADTAG (0x8009310b). Solche Dateien
        # werden vor dem Submit automatisch in eine ASCII-Arbeitskopie transkodiert.
        try {
            $csrBytes = [System.IO.File]::ReadAllBytes($csrPath)
            $hasBom = ($csrBytes.Length -ge 2 -and (
                ($csrBytes[0] -eq 0xFF -and $csrBytes[1] -eq 0xFE) -or
                ($csrBytes[0] -eq 0xFE -and $csrBytes[1] -eq 0xFF) -or
                ($csrBytes.Length -ge 3 -and $csrBytes[0] -eq 0xEF -and $csrBytes[1] -eq 0xBB -and $csrBytes[2] -eq 0xBF)))
            if ($hasBom) {
                $csrText = [System.IO.File]::ReadAllText($csrPath)  # erkennt BOM selbst
                $csrPath = Join-Path (Get-WizardWorkingDir) "PlanB-transcoded-$([guid]::NewGuid()).req"
                Set-Content -Path $csrPath -Value $csrText -Encoding ASCII
                Write-WizardLog -Message 'CSR-Datei enthielt ein BOM/UTF-16-Encoding - fuer certreq automatisch nach ASCII transkodiert.' -Level Info
            }
        } catch { }
    }
    if (-not $csrPath) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst den CSR-Text einfuegen (oder alternativ eine CSR-Datei auswaehlen).', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $cboTemplateSubmitB.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show('Bitte ein Zertifikatstemplate auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnSubmitB.Enabled = $false
    $script:PlanB_SubmitDir = Split-Path $csrPath -Parent

    $submit = Submit-CertificateSigningRequest -CsrPath $csrPath -CAConfig $config.CAConfig -TemplateName $cboTemplateSubmitB.SelectedItem -OutputDirectory $script:PlanB_SubmitDir
    if ($submit.Pending) {
        $script:PlanB_PendingRequestId = $submit.RequestId
        Save-WizardResumeState -State @{
            Plan = 'B'; Stage = 'Pending'; RequestId = $submit.RequestId
            SubmitDir = $script:PlanB_SubmitDir
            CardName = "$($script:PlanB_CardName)"; PcscName = "$($script:PlanB_PcscName)"
            TargetAccount = "$($script:TargetAccount)"
        }
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblSubmitResultB.Text = "Antrag wartet auf Genehmigung (RequestId $($submit.RequestId)) - Abruf auch nach einem Neustart des Wizards moeglich."
        $btnRetrieveB.Visible = $true
    } elseif ($submit.Success) {
        $txtCerPathB.Text = $submit.CerPath
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblSubmitResultB.Text = 'Zertifikat wurde ausgestellt.'
    } else {
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblSubmitResultB.Text = 'Antrag fehlgeschlagen. Details siehe Log.'
    }
    $btnSubmitB.Enabled = $true
})

$btnRetrieveB.Add_Click({
    if (-not $script:PlanB_PendingRequestId) { return }
    $recv = Receive-PendingCertificate -RequestId $script:PlanB_PendingRequestId -CAConfig $config.CAConfig -OutputDirectory $script:PlanB_SubmitDir
    if ($recv.Success) {
        $txtCerPathB.Text = $recv.CerPath
        $btnRetrieveB.Visible = $false
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblSubmitResultB.Text = 'Zertifikat wurde abgerufen.'
    } else {
        [System.Windows.Forms.MessageBox]::Show('Zertifikat ist noch nicht ausgestellt.', 'Hinweis', 'OK', 'Information') | Out-Null
    }
})

$btnCopyCerPathB.Add_Click({
    if ($txtCerPathB.Text) { Set-WizardClipboard -Text $txtCerPathB.Text }
})

$btnOpenCerFolderB.Add_Click({
    if ($txtCerPathB.Text) { Open-WizardFolder -Path $txtCerPathB.Text }
})

# --- Schritt B6: Zertifikat abschliessen (lokal) ---
$pnlB6 = New-Object System.Windows.Forms.Panel
$pnlB6.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB6)

$lblCompleteInfoB = New-WizardLabel -Text 'Zurueck auf dem lokalen Rechner (im eigenen Konto): entweder die vom Server zurueckkopierte Zertifikatsdatei (.cer) auswaehlen, oder den Text direkt einfuegen (z.B. Ergebnis des Einreichungshelfers VscWizard.Submit.ps1).' -X 20 -Y 20 -Width 780 -Height 40

$btnSelectCerB = New-Object System.Windows.Forms.Button
$btnSelectCerB.Text = 'CER-Datei auswaehlen...'
$btnSelectCerB.Location = New-Object System.Drawing.Point(20, 66)
$btnSelectCerB.Size = New-Object System.Drawing.Size(200, 30)

$txtSelectedCerB = New-Object System.Windows.Forms.TextBox
$txtSelectedCerB.Location = New-Object System.Drawing.Point(230, 70)
$txtSelectedCerB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCerB.ReadOnly = $true

$btnCompleteB = New-Object System.Windows.Forms.Button
$btnCompleteB.Text = 'Aus Datei uebernehmen'
$btnCompleteB.Location = New-Object System.Drawing.Point(20, 110)
$btnCompleteB.Size = New-Object System.Drawing.Size(200, 32)

$lblCerTextLabelB = New-WizardLabel -Text '...oder CER-Text hier einfuegen:' -X 20 -Y 156 -Width 780
$txtCerTextB = New-Object System.Windows.Forms.TextBox
$txtCerTextB.Location = New-Object System.Drawing.Point(20, 182)
$txtCerTextB.Size = New-Object System.Drawing.Size(780, 110)
$txtCerTextB.Multiline = $true
$txtCerTextB.ScrollBars = 'Vertical'
$txtCerTextB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnCompleteFromTextB = New-Object System.Windows.Forms.Button
$btnCompleteFromTextB.Text = 'Aus Text uebernehmen'
$btnCompleteFromTextB.Location = New-Object System.Drawing.Point(20, 300)
$btnCompleteFromTextB.Size = New-Object System.Drawing.Size(200, 32)

$lblCompleteResultB = New-WizardLabel -Text '' -X 20 -Y 344 -Width 780 -Height 40

$lblSummaryB = New-WizardLabel -Text '' -X 20 -Y 390 -Width 780 -Height 110

$btnResetB = New-Object System.Windows.Forms.Button
$btnResetB.Text = 'Weitere Smartcard beantragen'
$btnResetB.Location = New-Object System.Drawing.Point(20, 510)
$btnResetB.Size = New-Object System.Drawing.Size(240, 32)

$pnlB6.Controls.AddRange(@($lblCompleteInfoB, $btnSelectCerB, $txtSelectedCerB, $btnCompleteB, $lblCerTextLabelB, $txtCerTextB, $btnCompleteFromTextB, $lblCompleteResultB, $lblSummaryB, $btnResetB))

$btnSelectCerB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Zertifikatsdateien (*.cer)|*.cer|Alle Dateien (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSelectedCerB.Text = $dlg.FileName
    }
})

function Update-PlanBSummary {
    $summary = Get-IssuedCertificateSummary -SubjectContains (Get-EnrollmentIdentity).SearchTerm
    if ($summary) {
        $lblSummaryB.Text = "Kartenname: $($script:PlanB_CardName)`r`nZertifikat: $($summary.Subject)`r`nThumbprint: $($summary.Thumbprint)`r`nGueltig ab: $($summary.NotBefore)`r`nGueltig bis: $($summary.NotAfter)"
    } else {
        $lblSummaryB.Text = 'Kein passendes Zertifikat gefunden.'
    }
}

function Complete-PlanBEnrollment {
    param([Parameter(Mandatory)][string]$CerPath)

    $complete = Complete-CertificateEnrollment -CerPath $CerPath
    if ($complete.Success) {
        $script:PlanB_CertIssued = $true
        Clear-WizardResumeState
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCompleteResultB.Text = 'Zertifikat wurde erfolgreich auf der virtuellen Smartcard hinterlegt.'
        Update-PlanBSummary
    } else {
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCompleteResultB.Text = 'Uebernahme fehlgeschlagen. Details siehe Log.'
    }
}

$btnCompleteFromTextB.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCerTextB.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst den CER-Text einfuegen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCompleteFromTextB.Enabled = $false
    $pastedCerPath = Join-Path (Get-WizardWorkingDir) "PlanB-pasted-$([guid]::NewGuid()).cer"
    Set-Content -Path $pastedCerPath -Value $txtCerTextB.Text -Encoding ASCII
    Complete-PlanBEnrollment -CerPath $pastedCerPath
    Remove-Item -Path $pastedCerPath -ErrorAction SilentlyContinue
    $btnCompleteFromTextB.Enabled = $true
})

$btnCompleteB.Add_Click({
    if (-not $txtSelectedCerB.Text) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst eine CER-Datei auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCompleteB.Enabled = $false
    Complete-PlanBEnrollment -CerPath $txtSelectedCerB.Text
    $btnCompleteB.Enabled = $true
})

$btnResetB.Add_Click({
    $script:PlanB_VscCreated = $false
    $script:PlanB_CertIssued = $false
    $script:PlanB_PendingRequestId = $null
    $txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"
    $lblVscResultB.Text = ''
    $txtCsrPathB.Text = ''
    $txtCsrTextB.Text = ''
    $txtCsrPasteB.Text = ''
    $txtSelectedCsrB.Text = ''
    $txtCerPathB.Text = ''
    $txtSelectedCerB.Text = ''
    $txtCerTextB.Text = ''
    $lblSubmitResultB.Text = ''
    $lblCompleteResultB.Text = ''
    $btnRetrieveB.Visible = $false
    Show-PlanBStep -Index 1
})

# --- Navigation Plan B ---
$planBStepTitles = @('Status', 'Virtuelle Smartcard erstellen', 'CSR erstellen', 'Uebergabe per RDP', 'Antrag einreichen (auf dem Server)', 'Zertifikat abschliessen (lokal)')

function Update-PlanBStatus {
    $joinState = Get-DomainJoinState
    $upn = Get-CurrentUpn
    $lblJoinStateB.Text = "Domaenen-Status: $($joinState.Mode)"
    $lblUserB.Text = "Angemeldeter Benutzer: $env:USERDOMAIN\$env:USERNAME" + $(if ($upn) { " (UPN: $upn)" } else { '' })
    if ($script:TargetAccount) {
        $lblTargetB.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblTargetB.Text = "Smartcard wird beantragt fuer: $($script:TargetAccount) (VSC/CSR trotzdem in deinem eigenen Konto)"
    } else {
        $lblTargetB.Text = ''
    }
    $lblJumpServerB.Text = "CA-naher Server (RDP-Ziel): $($config.RdpJumpServer)"
}

function Show-PlanBStep {
    param([int]$Index)
    $panels = @($pnlB1, $pnlB2, $pnlB3, $pnlB4, $pnlB5, $pnlB6)
    for ($i = 0; $i -lt $panels.Count; $i++) {
        $panels[$i].Visible = ($i -eq $Index)
    }
    $script:PlanBCurrentStep = $Index
    # Globale Schrittnummer: +1, da Schritt 1 (Moduswahl) davor liegt.
    $lblGlobalStep.Text = "Schritt $($Index + 2) von $($panels.Count + 1): $($planBStepTitles[$Index])"
    $btnBackShared.Enabled = $true
    $btnNextShared.Enabled = ($Index -lt $panels.Count - 1)

    switch ($Index) {
        0 { Update-PlanBStatus }
        2 {
            # Windows-Kartenauswahl-/PIN-Dialoge zeigen NICHT den vergebenen
            # Kartennamen, sondern den PC/SC-Namen "Microsoft Virtual Smart Card N".
            $lblCsrInfoB.Text = if ($script:PlanB_PcscName) {
                "Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Im Windows-Kartenauswahl-Dialog die Karte '$($script:PlanB_PcscName)' waehlen (das ist '$($script:PlanB_CardName)'); es erscheint ggf. ein PIN-Dialog."
            } else {
                'Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Es erscheint ggf. ein PIN-Dialog der Smartcard.'
            }
        }
        3 { Update-PlanBHandoff }
    }
}

function Invoke-PlanBNextClick {
    switch ($script:PlanBCurrentStep) {
        0 { Show-PlanBStep -Index 1 }
        1 {
            if (-not $script:PlanB_VscCreated) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst die virtuelle Smartcard erstellen.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanBStep -Index 2
        }
        2 {
            if (-not $script:PlanB_CsrPath) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst die CSR erstellen.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanBStep -Index 3
        }
        3 { Show-PlanBStep -Index 4 }
        4 {
            # Kein hartes Gate: wurde der Antrag anderweitig eingereicht (z.B. per
            # Einreichungshelfer in der RDP-Sitzung), gibt es auf DIESER Maschine
            # kein ausgestelltes Zertifikat - der Abschluss in Schritt 7 nimmt den
            # CER-Text per Einfuegen entgegen.
            if (-not $txtCerPathB.Text) {
                $confirm = [System.Windows.Forms.MessageBox]::Show(
                    'In diesem Schritt wurde kein Zertifikat ausgestellt. Wurde der Antrag anderweitig eingereicht (z.B. mit dem Einreichungshelfer in der RDP-Sitzung) und liegt das Zertifikat als Datei oder Text vor?',
                    'Schritt ueberspringen', 'YesNo', 'Question')
                if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            Show-PlanBStep -Index 5
        }
    }
}

function Invoke-PlanBBackClick {
    if ($script:PlanBCurrentStep -gt 0) {
        Show-PlanBStep -Index ($script:PlanBCurrentStep - 1)
    } else {
        $tabPlanB.Visible = $false
        Show-ModeSelectStep
    }
}

#endregion

# ============================================================================
#region GEMEINSAME NAVIGATION (Weiter/Zurueck delegieren je nach $script:ActivePlan)
# ============================================================================

$btnNextShared.Add_Click({
    switch ($script:ActivePlan) {
        'A' { Invoke-PlanANextClick }
        'B' { Invoke-PlanBNextClick }
        default { Invoke-ModeSelectNextClick }
    }
})

$btnBackShared.Add_Click({
    switch ($script:ActivePlan) {
        'A' { Invoke-PlanABackClick }
        'B' { Invoke-PlanBBackClick }
        default { }
    }
})

#endregion

# ============================================================================
#region EINSTELLUNGEN-DIALOG (schrittunabhaengig ueber den Button in der Kopfleiste erreichbar)
# ============================================================================

function Show-VscInventoryDialog {
    param([System.Windows.Forms.Form]$Owner)

    # Die Zertifikatserkennung kann durch den Timeout-Schutz gegen haengende
    # CNG-Schluesselzugriffe (siehe Get-SmartCardCngProviderInfo in Core.psm1) je nach
    # Anzahl der Zertifikate und ggf. verwaisten VSC-Verweisen mehrere Sekunden bis
    # niedrige zweistellige Sekunden dauern - Wartecursor als sichtbares Feedback,
    # sonst wirkt die App in dieser Zeit eingefroren.
    if ($Owner) { $Owner.Cursor = 'WaitCursor'; $Owner.Refresh() }
    [System.Windows.Forms.Cursor]::Current = 'WaitCursor'
    $readers = Get-VirtualSmartCardReaders
    $certs = Get-SmartCardCertificates
    [System.Windows.Forms.Cursor]::Current = 'Default'
    if ($Owner) { $Owner.Cursor = 'Default' }
    Write-WizardLog -Message "Smartcard-Inventar: $($readers.Count) Lesegeraet(e), $($certs.Count) Zertifikat(e) mit privatem Schluessel, davon $(@($certs | Where-Object IsSmartCard).Count) als Smartcard erkannt." -Level Info
    foreach ($rd in $readers) { Write-WizardLog -Message "  Leser '$($rd.FriendlyName)' PcscName='$($rd.PcscName)'" -Level Info }
    foreach ($ct in @($certs | Where-Object IsSmartCard)) { Write-WizardLog -Message "  SC-Cert Reader='$($ct.Reader)' Subject='$($ct.Subject.Substring(0,[Math]::Min(40,$ct.Subject.Length)))'" -Level Info }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Vorhandene virtuelle Smartcards'
    $dlg.Size = New-Object System.Drawing.Size(920, 680)
    $dlg.MinimumSize = New-Object System.Drawing.Size(700, 500)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false

    $dlgLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $dlgLayout.Dock = 'Fill'
    $dlgLayout.RowCount = 6
    $dlgLayout.ColumnCount = 1
    $dlgLayout.Padding = New-Object System.Windows.Forms.Padding(10)
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35)))
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 65)))
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 46)))
    $dlg.Controls.Add($dlgLayout)

    $lblReadersHeader = New-Object System.Windows.Forms.Label
    $lblReadersHeader.Text = "Erkannte Smartcard-Lesegeraete (inkl. virtueller TPM-Smartcards): $($readers.Count)"
    $lblReadersHeader.AutoSize = $true
    $lblReadersHeader.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $dlgLayout.Controls.Add($lblReadersHeader, 0, 0)

    $lvReaders = New-Object System.Windows.Forms.ListView
    $lvReaders.Dock = 'Fill'
    $lvReaders.View = 'Details'
    $lvReaders.FullRowSelect = $true
    $lvReaders.MultiSelect = $false
    $lvReaders.GridLines = $true
    $lvReaders.HideSelection = $false
    [void]$lvReaders.Columns.Add('Lesegeraet', 340)
    [void]$lvReaders.Columns.Add('Status', 90)
    [void]$lvReaders.Columns.Add('Geraete-ID', 300)
    $dlgLayout.Controls.Add($lvReaders, 0, 1)

    $unmatchedSmartCardMarker = [pscustomobject]@{ IsMarker = $true; Kind = 'unmatched' }
    $nonSmartCardMarker = [pscustomobject]@{ IsMarker = $true; Kind = 'other' }

    foreach ($reader in $readers) {
        $readerItem = New-Object System.Windows.Forms.ListViewItem($reader.FriendlyName)
        [void]$readerItem.SubItems.Add([string]$reader.Status)
        [void]$readerItem.SubItems.Add($reader.InstanceId)
        $readerItem.Tag = $reader
        [void]$lvReaders.Items.Add($readerItem)
    }

    # Zuordnung Zertifikat -> Lesegeraet ueber den PC/SC-Namen ("Microsoft Virtual
    # Smart Card N"): das Zertifikat meldet ihn als .Reader, das Lesegeraet traegt ihn
    # als .PcscName (siehe Get-VirtualSmartCardReaders / Get-SmartCardCngProviderInfo).
    $readerPcscNames = @($readers | ForEach-Object { $_.PcscName } | Where-Object { $_ })
    $unmatchedSmartCardCerts = @($certs | Where-Object { $_.IsSmartCard -and (-not $_.Reader -or ($readerPcscNames -notcontains $_.Reader)) })
    if ($unmatchedSmartCardCerts.Count -gt 0) {
        $markerItem = New-Object System.Windows.Forms.ListViewItem("Weitere smartcard-gebundene Zertifikate (Lesegeraet nicht zuordenbar, $($unmatchedSmartCardCerts.Count))")
        $markerItem.Tag = $unmatchedSmartCardMarker
        [void]$lvReaders.Items.Add($markerItem)
    }

    $otherCerts = @($certs | Where-Object { -not $_.IsSmartCard })
    if ($otherCerts.Count -gt 0) {
        $markerItem = New-Object System.Windows.Forms.ListViewItem("Sonstige Zertifikate mit privatem Schluessel (nicht als Smartcard erkannt, $($otherCerts.Count))")
        $markerItem.Tag = $nonSmartCardMarker
        [void]$lvReaders.Items.Add($markerItem)
    }

    if ($lvReaders.Items.Count -eq 0) {
        [void]$lvReaders.Items.Add((New-Object System.Windows.Forms.ListViewItem('Keine Smartcard-Lesegeraete und keine smartcard-gebundenen Zertifikate gefunden.')))
    }

    $readerButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $readerButtonPanel.Dock = 'Fill'
    $readerButtonPanel.FlowDirection = 'LeftToRight'
    $dlgLayout.Controls.Add($readerButtonPanel, 0, 2)

    $btnDeleteReader = New-Object System.Windows.Forms.Button
    $btnDeleteReader.Text = 'Ausgewaehlte Smartcard loeschen...'
    $btnDeleteReader.Size = New-Object System.Drawing.Size(240, 30)
    $btnDeleteReader.Enabled = $false
    $readerButtonPanel.Controls.Add($btnDeleteReader)

    $lblCertsHeader = New-Object System.Windows.Forms.Label
    $lblCertsHeader.Text = 'Zertifikate: (Lesegeraet oben auswaehlen)'
    $lblCertsHeader.AutoSize = $true
    $lblCertsHeader.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
    $dlgLayout.Controls.Add($lblCertsHeader, 0, 3)

    $lvCerts = New-Object System.Windows.Forms.ListView
    $lvCerts.Dock = 'Fill'
    $lvCerts.View = 'Details'
    $lvCerts.FullRowSelect = $true
    $lvCerts.MultiSelect = $false
    $lvCerts.GridLines = $true
    $lvCerts.HideSelection = $false
    [void]$lvCerts.Columns.Add('Subject', 300)
    [void]$lvCerts.Columns.Add('Gueltig bis', 90)
    [void]$lvCerts.Columns.Add('Thumbprint', 220)
    [void]$lvCerts.Columns.Add('Provider', 200)
    $dlgLayout.Controls.Add($lvCerts, 0, 4)

    function Update-CertListForSelection {
        $lvCerts.Items.Clear()
        if ($lvReaders.SelectedItems.Count -eq 0) {
            $lblCertsHeader.Text = 'Zertifikate: (Lesegeraet oben auswaehlen)'
            $btnDeleteReader.Enabled = $false
            return
        }

        $selectedTag = $lvReaders.SelectedItems[0].Tag
        $matching = @()
        if ($selectedTag -and $selectedTag.PSObject.Properties['IsMarker']) {
            $btnDeleteReader.Enabled = $false
            if ($selectedTag.Kind -eq 'unmatched') {
                $lblCertsHeader.Text = 'Zertifikate: weitere smartcard-gebundene (Lesegeraet nicht zuordenbar)'
                $matching = $unmatchedSmartCardCerts
            } else {
                $lblCertsHeader.Text = 'Zertifikate: sonstige mit privatem Schluessel (nicht als Smartcard erkannt)'
                $matching = $otherCerts
            }
        } elseif ($selectedTag) {
            $btnDeleteReader.Enabled = $true
            $lblCertsHeader.Text = "Zertifikate auf: $($selectedTag.FriendlyName)"
            $matching = @($certs | Where-Object { $_.Reader -and $selectedTag.PcscName -and $_.Reader -eq $selectedTag.PcscName })
        } else {
            $btnDeleteReader.Enabled = $false
        }

        if ($matching.Count -eq 0) {
            [void]$lvCerts.Items.Add((New-Object System.Windows.Forms.ListViewItem('(keine Zertifikate gefunden)')))
            return
        }
        foreach ($c in $matching) {
            $certItem = New-Object System.Windows.Forms.ListViewItem($c.Subject)
            [void]$certItem.SubItems.Add($c.NotAfter.ToString('yyyy-MM-dd'))
            [void]$certItem.SubItems.Add($c.Thumbprint)
            $providerText = if ($c.Provider) { $c.Provider } elseif ($c.DetectionError) { "unbekannt (Fehler: $($c.DetectionError))" } else { 'unbekannt' }
            [void]$certItem.SubItems.Add($providerText)
            [void]$lvCerts.Items.Add($certItem)
        }
    }

    $lvReaders.Add_SelectedIndexChanged({ Update-CertListForSelection })

    $btnDeleteReader.Add_Click({
        if ($lvReaders.SelectedItems.Count -eq 0) { return }
        $selectedReader = $lvReaders.SelectedItems[0].Tag
        if (-not $selectedReader -or $selectedReader.PSObject.Properties['IsMarker']) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Virtuelle Smartcard '$($selectedReader.FriendlyName)' wirklich unwiderruflich loeschen?`r`n`r`nAlle darauf gespeicherten Schluessel gehen dabei verloren. Diese Aktion kann nicht rueckgaengig gemacht werden.",
            'Smartcard loeschen', 'YesNo', 'Warning')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnDeleteReader.Enabled = $false
        Write-WizardLog -Message "Loesche virtuelle Smartcard: $($selectedReader.FriendlyName) ($($selectedReader.InstanceId))" -Level Command
        $result = Remove-VirtualSmartCard -InstanceId $selectedReader.InstanceId
        if ($result.Success) {
            Write-WizardLog -Message "Virtuelle Smartcard geloescht: $($selectedReader.FriendlyName)" -Level Success
            [System.Windows.Forms.MessageBox]::Show('Smartcard geloescht.', 'Erledigt', 'OK', 'Information') | Out-Null
            $dlg.Close()
            Show-VscInventoryDialog -Owner $Owner
        } else {
            Write-WizardLog -Message "Loeschen fehlgeschlagen (Exit-Code $($result.ExitCode)): $($selectedReader.FriendlyName)" -Level Error
            [System.Windows.Forms.MessageBox]::Show("Loeschen fehlgeschlagen (Exit-Code $($result.ExitCode)). Details siehe Log.", 'Fehler', 'OK', 'Error') | Out-Null
            $btnDeleteReader.Enabled = $true
        }
    })

    $dlgBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $dlgBtnPanel.Dock = 'Fill'
    $dlgBtnPanel.FlowDirection = 'RightToLeft'
    $dlgLayout.Controls.Add($dlgBtnPanel, 0, 5)

    $btnCloseInventory = New-Object System.Windows.Forms.Button
    $btnCloseInventory.Text = 'Schliessen'
    $btnCloseInventory.Size = New-Object System.Drawing.Size(120, 30)
    $btnCloseInventory.Margin = New-Object System.Windows.Forms.Padding(10)
    $dlgBtnPanel.Controls.Add($btnCloseInventory)
    $btnCloseInventory.Add_Click({ $dlg.Close() })

    $btnRefreshInventory = New-Object System.Windows.Forms.Button
    $btnRefreshInventory.Text = 'Aktualisieren'
    $btnRefreshInventory.Size = New-Object System.Drawing.Size(120, 30)
    $btnRefreshInventory.Margin = New-Object System.Windows.Forms.Padding(10)
    $dlgBtnPanel.Controls.Add($btnRefreshInventory)
    $btnRefreshInventory.Add_Click({
        $dlg.Close()
        Show-VscInventoryDialog -Owner $Owner
    })

    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
}

function Show-SettingsDialog {
    param([System.Windows.Forms.Form]$Owner)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Einstellungen'
    $dlg.Size = New-Object System.Drawing.Size(760, 720)
    $dlg.MinimumSize = New-Object System.Drawing.Size(620, 480)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false

    $dlgLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $dlgLayout.Dock = 'Fill'
    $dlgLayout.RowCount = 2
    $dlgLayout.ColumnCount = 1
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
    $dlg.Controls.Add($dlgLayout)

    # Scrollbarer Inhaltsbereich fuer die Felder - dadurch bleibt die Speichern-Zeile
    # unten IMMER voll sichtbar (eigene, fixe Zeile ausserhalb des Scrollbereichs),
    # egal wie viele Felder/Hinweistexte oben Platz brauchen oder wie klein das
    # Dialogfenster gerade ist.
    $scrollPanel = New-Object System.Windows.Forms.Panel
    $scrollPanel.Dock = 'Fill'
    $scrollPanel.AutoScroll = $true
    $dlgLayout.Controls.Add($scrollPanel, 0, 0)

    $settingsLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $settingsLayout.Dock = 'Top'
    $settingsLayout.AutoSize = $true
    $settingsLayout.AutoSizeMode = 'GrowAndShrink'
    $settingsLayout.ColumnCount = 2
    $settingsLayout.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 16)
    [void]$settingsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 280)))
    [void]$settingsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $scrollPanel.Controls.Add($settingsLayout)

    function Add-SettingsRow {
        # Label in Spalte 0, Eingabefeld in Spalte 1, gleiche Zeile - spart gegenueber
        # "Label ueber Feld" rund die Haelfte an vertikalem Platz.
        param(
            [Parameter(Mandatory)][string]$LabelText,
            [Parameter(Mandatory)][System.Windows.Forms.Control]$InputControl
        )
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LabelText
        $lbl.Dock = 'Fill'
        $lbl.TextAlign = 'MiddleLeft'
        $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 6, 10, 6)

        $InputControl.Height = 24
        $InputControl.Dock = 'Fill'
        $InputControl.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)

        $rowIndex = $settingsLayout.RowCount
        $settingsLayout.RowCount = $rowIndex + 1
        [void]$settingsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $settingsLayout.Controls.Add($lbl, 0, $rowIndex)
        $settingsLayout.Controls.Add($InputControl, 1, $rowIndex)
    }

    function Add-SettingsFullRow {
        # Ein Control, das ueber beide Spalten der ganzen Zeilenbreite geht (Hinweistexte,
        # Buttons, Ergebnisboxen). -Fill fuer Controls ohne eigenes AutoSize (z.B. eine
        # Multiline-TextBox), damit sie die volle Zeilenbreite bekommen statt der
        # winzigen TextBox-Standardbreite.
        param(
            [Parameter(Mandatory)][System.Windows.Forms.Control]$Control,
            [switch]$Fill
        )
        $Control.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 10)
        if ($Fill) { $Control.Dock = 'Fill' }
        $rowIndex = $settingsLayout.RowCount
        $settingsLayout.RowCount = $rowIndex + 1
        [void]$settingsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $settingsLayout.Controls.Add($Control, 0, $rowIndex)
        $settingsLayout.SetColumnSpan($Control, 2)
    }

    $btnShowInventory = New-Object System.Windows.Forms.Button
    $btnShowInventory.Text = 'Vorhandene virtuelle Smartcards anzeigen...'
    $btnShowInventory.Size = New-Object System.Drawing.Size(280, 30)
    Add-SettingsFullRow -Control $btnShowInventory
    $btnShowInventory.Add_Click({ Show-VscInventoryDialog -Owner $dlg })

    $txtCfgCA = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgCA -Placeholder 'z.B. ca01.contoso.local\Contoso-Issuing-CA' -Value $config.CAConfig
    Add-SettingsRow -LabelText 'CA-Konfigurationsstring (Server\CA-Name):' -InputControl $txtCfgCA

    $cboCfgTemplate = New-Object System.Windows.Forms.ComboBox
    $cboCfgTemplate.DropDownStyle = 'DropDown'
    Set-TextBoxPlaceholder -TextBox $cboCfgTemplate -Placeholder 'z.B. SmartcardLogon' -Value $config.Template
    Add-SettingsRow -LabelText 'Zertifikatstemplate (fuer VSC-Anmeldung):' -InputControl $cboCfgTemplate

    $txtCfgPrefix = New-Object System.Windows.Forms.TextBox
    $txtCfgPrefix.Text = $config.VscNamePrefix
    Add-SettingsRow -LabelText 'Namenspraefix fuer virtuelle Smartcards:' -InputControl $txtCfgPrefix

    $txtCfgJump = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgJump -Placeholder 'z.B. pki-jump.contoso.local' -Value $config.RdpJumpServer
    Add-SettingsRow -LabelText 'RDP-Zielserver fuer Plan B:' -InputControl $txtCfgJump

    # Editierbares Dropdown mit den beiden Standard-Smartcard-Providern: der Legacy-CSP
    # (CAPI, fuer V1/V2-Templates) und der CNG-KSP (fuer V3/V4-Templates). Die
    # INF-Erzeugung (New-EnrollmentInfFile) erkennt den KSP am Namen und laesst dann
    # die CAPI-Direktiven ProviderType/KeySpec weg.
    $txtCfgCsp = New-Object System.Windows.Forms.ComboBox
    $txtCfgCsp.DropDownStyle = 'DropDown'
    [void]$txtCfgCsp.Items.AddRange(@(
        'Microsoft Base Smart Card Crypto Provider',
        'Microsoft Smart Card Key Storage Provider'
    ))
    $txtCfgCsp.Text = $config.CspName
    Add-SettingsRow -LabelText 'Provider (CSP/KSP, muss zum Template passen):' -InputControl $txtCfgCsp

    $txtCfgDomain = New-Object System.Windows.Forms.TextBox
    $discoveryDomainDefault = if ($config.DiscoveryDomain) { $config.DiscoveryDomain } else { Get-DiscoveryDomainGuess }
    Set-TextBoxPlaceholder -TextBox $txtCfgDomain -Placeholder 'z.B. contoso.local oder dc01.contoso.local' -Value $discoveryDomainDefault
    Add-SettingsRow -LabelText 'AD-Domaene / Domain Controller (PKI-Erkennung):' -InputControl $txtCfgDomain

    $lblCfgDomainHint = New-Object System.Windows.Forms.Label
    $lblCfgDomainHint.Text = 'Auf Entra-joined/Workgroup-Rechnern meist noetig, da "serverloses" LDAP-Binding ohne Domain-Join nicht funktioniert. Vorschlag aus UPN abgeleitet, ggf. abweichend vom echten AD-DNS-Namen - bei Bedarf korrigieren.'
    $lblCfgDomainHint.AutoSize = $true
    $lblCfgDomainHint.MaximumSize = New-Object System.Drawing.Size(760, 0)
    $lblCfgDomainHint.ForeColor = [System.Drawing.Color]::Gray
    $lblCfgDomainHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    Add-SettingsFullRow -Control $lblCfgDomainHint

    $discoverPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $discoverPanel.AutoSize = $true
    $discoverPanel.FlowDirection = 'LeftToRight'
    $discoverPanel.WrapContents = $false

    $lblCfgDiscover = New-Object System.Windows.Forms.Label
    $lblCfgDiscover.Text = 'Automatische PKI-Erkennung:'
    $lblCfgDiscover.AutoSize = $true
    $lblCfgDiscover.Margin = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $discoverPanel.Controls.Add($lblCfgDiscover)

    $btnDiscoverCfg = New-Object System.Windows.Forms.Button
    $btnDiscoverCfg.Text = 'PKI automatisch erkennen'
    $btnDiscoverCfg.Size = New-Object System.Drawing.Size(220, 30)
    $discoverPanel.Controls.Add($btnDiscoverCfg)
    Add-SettingsFullRow -Control $discoverPanel

    $txtDiscoverResultCfg = New-Object System.Windows.Forms.TextBox
    $txtDiscoverResultCfg.Multiline = $true
    $txtDiscoverResultCfg.ReadOnly = $true
    $txtDiscoverResultCfg.ScrollBars = 'Vertical'
    $txtDiscoverResultCfg.Height = 70
    $txtDiscoverResultCfg.Font = New-Object System.Drawing.Font('Consolas', 9)
    Add-SettingsFullRow -Control $txtDiscoverResultCfg -Fill

    # --- Enrollment Agent (bruchfreie Ausstellung fuer separate Konten, ohne RDP) ---
    $lblEaHeader = New-Object System.Windows.Forms.Label
    $lblEaHeader.Text = 'Enrollment Agent (Ausstellung fuer separate Konten ohne RDP)'
    $lblEaHeader.AutoSize = $true
    $lblEaHeader.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblEaHeader.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 2)
    Add-SettingsFullRow -Control $lblEaHeader

    # Sicherheitshinweis: ein EA-Zertifikat, das Logon-Certs fuer Admin-Konten
    # ausstellen kann, ist gleichbedeutend mit "sich als diese Admins anmelden
    # koennen" (AD-CS-Eskalationspfad ESC3). Wer es haelt, ist so privilegiert wie
    # die Zielkonten. Fuer Admin-Zielkonten ist Self-Enrollment als das Konto selbst
    # (Plan B) meist die sicherere Wahl; EA/EOBO nur als bewusste, moeglichst
    # eingeschraenkte (Restricted Enrollment Agent) und auditierte Ausnahme.
    $lblEaWarn = New-Object System.Windows.Forms.Label
    $lblEaWarn.Text = 'Achtung: Ein EA-Zertifikat, mit dem sich Logon-Certs fuer Admins ausstellen lassen, ist admin-aequivalent (Eskalationspfad ESC3) - wer es besitzt, kann sich als diese Konten anmelden. Fuer Admin-Zielkonten ist Self-Enrollment als das Konto selbst (Plan B) meist sicherer. EA/EOBO nur bewusst, eingeschraenkt (Restricted Enrollment Agent) und auditiert einsetzen; EA-Schluessel auf Hardware/VSC halten.'
    $lblEaWarn.AutoSize = $true
    $lblEaWarn.MaximumSize = New-Object System.Drawing.Size(760, 0)
    $lblEaWarn.ForeColor = [System.Drawing.Color]::Firebrick
    $lblEaWarn.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblEaWarn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    Add-SettingsFullRow -Control $lblEaWarn

    $eaCertsNow = @(Get-EnrollmentAgentCertificates)
    $lblEaStatus = New-Object System.Windows.Forms.Label
    $lblEaStatus.AutoSize = $true
    $lblEaStatus.MaximumSize = New-Object System.Drawing.Size(760, 0)
    if ($eaCertsNow.Count -gt 0) {
        $lblEaStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblEaStatus.Text = "EA-Zertifikat vorhanden: $($eaCertsNow[0].Subject) (gueltig bis $($eaCertsNow[0].NotAfter.ToString('yyyy-MM-dd'))). Damit kann fuer separate Konten bruchfrei per Plan A ausgestellt werden."
    } else {
        $lblEaStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblEaStatus.Text = 'Kein EA-Zertifikat gefunden. Ohne EA-Zertifikat muss fuer separate Konten der Plan-B/RDP-Weg genutzt werden.'
    }
    Add-SettingsFullRow -Control $lblEaStatus

    $txtCfgEaTemplate = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgEaTemplate -Placeholder 'z.B. EnrollmentAgent' -Value $config.EATemplate
    Add-SettingsRow -LabelText 'EA-Zertifikatstemplate:' -InputControl $txtCfgEaTemplate

    $chkEaOnVsc = New-Object System.Windows.Forms.CheckBox
    $chkEaOnVsc.Text = 'EA-Schluessel auf eigener VSC (TPM/PIN) statt Software-Schluessel'
    $chkEaOnVsc.Checked = $true
    $chkEaOnVsc.AutoSize = $true
    Add-SettingsFullRow -Control $chkEaOnVsc

    $eaPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $eaPanel.AutoSize = $true
    $eaPanel.FlowDirection = 'LeftToRight'
    $eaPanel.WrapContents = $false
    $btnRequestEa = New-Object System.Windows.Forms.Button
    $btnRequestEa.Text = 'EA-Zertifikat beantragen'
    $btnRequestEa.Size = New-Object System.Drawing.Size(220, 30)
    $eaPanel.Controls.Add($btnRequestEa)
    Add-SettingsFullRow -Control $eaPanel

    $lblEaResult = New-Object System.Windows.Forms.Label
    $lblEaResult.AutoSize = $true
    $lblEaResult.MaximumSize = New-Object System.Drawing.Size(760, 0)
    Add-SettingsFullRow -Control $lblEaResult

    $btnRequestEa.Add_Click({
        $eaTemplate = Get-TextBoxRealValue -TextBox $txtCfgEaTemplate
        if ([string]::IsNullOrWhiteSpace($eaTemplate)) {
            [System.Windows.Forms.MessageBox]::Show('Bitte zuerst das EA-Zertifikatstemplate eintragen (und ggf. speichern).', 'Hinweis', 'OK', 'Warning') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($config.CAConfig)) {
            [System.Windows.Forms.MessageBox]::Show('Bitte zuerst CA-Konfigurationsstring eintragen und speichern.', 'Hinweis', 'OK', 'Warning') | Out-Null
            return
        }
        $btnRequestEa.Enabled = $false
        $lblEaResult.ForeColor = [System.Drawing.SystemColors]::WindowText
        $lblEaResult.Text = 'Beantrage EA-Zertifikat fuer das eigene Konto...'
        $dlg.Refresh()

        $result = Invoke-EnrollmentAgentRequest -Template $eaTemplate -OnVsc:$chkEaOnVsc.Checked
        if ($result.Success) {
            $lblEaResult.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblEaResult.Text = 'EA-Zertifikat wurde ausgestellt. Es steht ab sofort fuer die Ausstellung an separate Konten (Plan A) zur Verfuegung.'
            $eaNow = @(Get-EnrollmentAgentCertificates)
            if ($eaNow.Count -gt 0) {
                $lblEaStatus.ForeColor = [System.Drawing.Color]::ForestGreen
                $lblEaStatus.Text = "EA-Zertifikat vorhanden: $($eaNow[0].Subject) (gueltig bis $($eaNow[0].NotAfter.ToString('yyyy-MM-dd')))."
            }
        } elseif ($result.Pending) {
            $lblEaResult.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblEaResult.Text = "EA-Antrag eingereicht, wartet auf Genehmigung (RequestId $($result.RequestId)). Nach Genehmigung erneut beantragen/abrufen."
        } else {
            $lblEaResult.ForeColor = [System.Drawing.Color]::Firebrick
            $lblEaResult.Text = "EA-Beantragung fehlgeschlagen: $($result.Message) Details siehe Log."
        }
        $btnRequestEa.Enabled = $true
    })

    $footerPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $footerPanel.Dock = 'Fill'
    $footerPanel.FlowDirection = 'RightToLeft'
    $dlgLayout.Controls.Add($footerPanel, 0, 1)

    $btnCloseSettings = New-Object System.Windows.Forms.Button
    $btnCloseSettings.Text = 'Schliessen'
    $btnCloseSettings.Size = New-Object System.Drawing.Size(120, 32)
    $btnCloseSettings.Margin = New-Object System.Windows.Forms.Padding(10)
    $footerPanel.Controls.Add($btnCloseSettings)
    $btnCloseSettings.Add_Click({ $dlg.Close() })

    $btnSaveConfig = New-Object System.Windows.Forms.Button
    $btnSaveConfig.Text = 'Speichern'
    $btnSaveConfig.Size = New-Object System.Drawing.Size(160, 32)
    $btnSaveConfig.Margin = New-Object System.Windows.Forms.Padding(10)
    $footerPanel.Controls.Add($btnSaveConfig)

    $lblCfgSaved = New-Object System.Windows.Forms.Label
    $lblCfgSaved.AutoSize = $true
    $lblCfgSaved.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblCfgSaved.TextAlign = 'MiddleRight'
    $lblCfgSaved.Margin = New-Object System.Windows.Forms.Padding(10, 18, 0, 0)
    $footerPanel.Controls.Add($lblCfgSaved)

    $btnDiscoverCfg.Add_Click({
        $btnDiscoverCfg.Enabled = $false
        $txtDiscoverResultCfg.Text = 'Pruefe PKI-Erreichbarkeit (bis zu ca. 40 Sekunden)...'
        $dlg.Refresh()

        $modulePath = Join-Path $PSScriptRoot 'modules\VscWizard.Core.psm1'
        $domainHint = Get-TextBoxRealValue -TextBox $txtCfgDomain
        $job = Start-Job -ScriptBlock {
            param($ModulePath, $DomainHint, $Timeout)
            Import-Module $ModulePath -Force
            Get-PkiReachability -Server $DomainHint -TimeoutSeconds $Timeout
        } -ArgumentList $modulePath, $domainHint, 8

        $completed = Wait-Job -Job $job -Timeout 40
        $reachData = $null
        if ($completed) {
            $reachData = Receive-Job -Job $job
        } else {
            Stop-Job -Job $job
        }
        Remove-Job -Job $job -Force

        if (-not $completed) {
            $txtDiscoverResultCfg.Text = 'Zeitueberschreitung (>40s). Domaene/DC-Feld pruefen oder Netzwerkverbindung (VPN/Private Access) sicherstellen.'
            Write-WizardLog -Message 'Automatische Erkennung: Zeitueberschreitung.' -Level Error
            $btnDiscoverCfg.Enabled = $true
            return
        }

        if ($reachData.ReachableCas.Count -gt 0) {
            $primary = $reachData.ReachableCas[0]
            Set-TextBoxRealValue -TextBox $txtCfgCA -Value $primary.ConfigString

            $allTemplates = @($reachData.ReachableCas | ForEach-Object { $_.Templates } | Where-Object { $_ } | Select-Object -Unique)
            if ($allTemplates.Count -gt 0) {
                $cboCfgTemplate.Items.Clear()
                [void]$cboCfgTemplate.Items.AddRange($allTemplates)
                Set-TextBoxRealValue -TextBox $cboCfgTemplate -Value $allTemplates[0]
            }

            $txtDiscoverResultCfg.Text = "$($reachData.ReachableCas.Count) erreichbare CA(s) gefunden und uebernommen - bitte Template pruefen (Dropdown-Pfeil zeigt alle $($allTemplates.Count) auf der CA verfuegbaren Templates) und Speichern:`r`n" + (($reachData.ReachableCas | ForEach-Object { "- $($_.Name) ($($_.ConfigString))" }) -join "`r`n")
            Write-WizardLog -Message "Automatische Erkennung: $($reachData.ReachableCas.Count) erreichbare CA(s) gefunden." -Level Success
        } elseif ($reachData.AllCas.Count -gt 0) {
            $txtDiscoverResultCfg.Text = "$($reachData.AllCas.Count) CA(s) in AD gefunden, aber per RPC nicht erreichbar (Firewall/Netzwerksegmentierung?):`r`n" + ($reachData.UnreachableCas -join "`r`n")
            Write-WizardLog -Message "Automatische Erkennung: $($reachData.AllCas.Count) CA(s) gefunden, keine per RPC erreichbar." -Level Info
        } elseif ($reachData.DiscoveryError) {
            $txtDiscoverResultCfg.Text = "LDAP-Erkennung fehlgeschlagen: $($reachData.DiscoveryError)`r`n`r`nTipp: Domaene/DC-Feld oben pruefen (z.B. expliziten DC-Namen statt DNS-Domaene versuchen) und Netzwerkverbindung (VPN/Private Access) sicherstellen."
            Write-WizardLog -Message "Automatische Erkennung fehlgeschlagen: $($reachData.DiscoveryError)" -Level Error
        } else {
            $txtDiscoverResultCfg.Text = 'Keine erreichbare CA gefunden.'
            Write-WizardLog -Message 'Automatische Erkennung: keine erreichbare CA gefunden.' -Level Info
        }
        $btnDiscoverCfg.Enabled = $true
    })

    $btnSaveConfig.Add_Click({
        $newConfig = @{
            CAConfig      = Get-TextBoxRealValue -TextBox $txtCfgCA
            Template      = Get-TextBoxRealValue -TextBox $cboCfgTemplate
            VscNamePrefix = $txtCfgPrefix.Text
            RdpJumpServer = Get-TextBoxRealValue -TextBox $txtCfgJump
            CspName       = $txtCfgCsp.Text
            DiscoveryDomain = Get-TextBoxRealValue -TextBox $txtCfgDomain
            EATemplate    = Get-TextBoxRealValue -TextBox $txtCfgEaTemplate
            WorkingDir    = $config.WorkingDir
        }
        Save-VscWizardConfig -Config $newConfig -Path $script:ConfigPath
        $script:config = $newConfig

        Set-TemplateComboItem -ComboBox $cboTemplateA -Template $newConfig.Template
        Set-TemplateComboItem -ComboBox $cboTemplateSubmitB -Template $newConfig.Template

        $lblCfgSaved.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCfgSaved.Text = 'Gespeichert.'
    })

    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
}

#endregion

# ============================================================================
#region STARTUP
# ============================================================================

Show-ModeSelectStep

function Invoke-WizardResume {
    # Begonnenen Antrag aus einer frueheren Sitzung wieder aufnehmen (siehe
    # Save-WizardResumeState in Core.psm1): stellt die Wizard-Variablen wieder her
    # und springt direkt zum passenden Schritt.
    $state = Get-WizardResumeState
    if (-not $state) { return }

    $stageText = if ($state['Stage'] -eq 'Pending') { "Antrag eingereicht, wartet auf Genehmigung (RequestId $($state['RequestId']))" } else { 'CSR erstellt, noch nicht eingereicht' }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Ein begonnener Antrag vom $($state['SavedAt']) wurde gefunden:`r`n`r`nKarte: $($state['CardName'])`r`nStand: $stageText`r`n`r`nFortsetzen? (Bei 'Nein' wird der gespeicherte Stand verworfen - der offene Antrag im Zertifikatsspeicher bleibt davon unberuehrt.)",
        'Begonnenen Antrag fortsetzen', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Clear-WizardResumeState
        Write-WizardLog -Message 'Gespeicherter Antrags-Stand verworfen.' -Level Info
        return
    }

    if ($state['TargetAccount']) { $script:TargetAccount = $state['TargetAccount'] } else { $script:TargetAccount = $null }
    $pnlModeSelect.Visible = $false

    if ($state['Plan'] -eq 'A') {
        $script:ActivePlan = 'A'
        $script:PlanA_VscCreated = $true
        $script:PlanA_CardName = $state['CardName']
        $script:PlanA_PcscName = $state['PcscName']
        $script:PlanA_EnrollDir = $state['EnrollDir']
        $script:PlanA_PendingRequestId = $state['RequestId']
        $tabPlanA.Visible = $true
        Show-PlanAStep -Index 2
        $btnRetrieveA.Visible = $true
        $lblCertResultA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblCertResultA.Text = "Fortgesetzter Antrag (RequestId $($state['RequestId'])) - ueber 'Zertifikat abrufen' pruefen, ob er inzwischen genehmigt wurde."
    } else {
        $script:ActivePlan = 'B'
        $script:PlanB_VscCreated = $true
        $script:PlanB_CardName = $state['CardName']
        $script:PlanB_PcscName = $state['PcscName']
        $tabPlanB.Visible = $true
        if ($state['Stage'] -eq 'Pending') {
            $script:PlanB_PendingRequestId = $state['RequestId']
            $script:PlanB_SubmitDir = $state['SubmitDir']
            Show-PlanBStep -Index 4
            $btnRetrieveB.Visible = $true
            $lblSubmitResultB.ForeColor = [System.Drawing.Color]::DarkOrange
            $lblSubmitResultB.Text = "Fortgesetzter Antrag (RequestId $($state['RequestId'])) - ueber 'Zertifikat abrufen' pruefen, ob er inzwischen genehmigt wurde."
        } else {
            $script:PlanB_CsrPath = $state['CsrPath']
            $txtCsrPathB.Text = $state['CsrPath']
            try { $txtCsrTextB.Text = Get-Content -Path $state['CsrPath'] -Raw -ErrorAction Stop } catch { $txtCsrTextB.Text = '' }
            Show-PlanBStep -Index 3
        }
    }
    Write-WizardLog -Message "Begonnener Antrag fortgesetzt (Plan $($state['Plan']), Stand: $stageText)." -Level Info
}

$configIncomplete = [string]::IsNullOrWhiteSpace($config.CAConfig) -or [string]::IsNullOrWhiteSpace($config.Template)
if ($configIncomplete) {
    # Erst oeffnen, sobald das Hauptfenster tatsaechlich angezeigt wird (Shown-Event) -
    # ein modaler Dialog mit -Owner vor dem ersten Show() des Owners fuehrt sonst zu
    # unzuverlaessigem Fensterverhalten.
    $form.Add_Shown({ Show-SettingsDialog -Owner $form })
} else {
    # Fortsetzen-Angebot nur, wenn nicht ohnehin zuerst die Einstellungen zu
    # pflegen sind; ebenfalls erst nach dem Shown-Event (modaler Dialog).
    $form.Add_Shown({ Invoke-WizardResume })
}

[void]$form.ShowDialog()

#endregion
