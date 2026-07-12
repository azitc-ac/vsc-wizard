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
$mainLayout.RowCount = 2
$mainLayout.ColumnCount = 1
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 68)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 32)))
$form.Controls.Add($mainLayout)

$pnlTabHost = New-Object System.Windows.Forms.Panel
$pnlTabHost.Dock = 'Fill'
$mainLayout.Controls.Add($pnlTabHost, 0, 0)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$pnlTabHost.Controls.Add($tabs)
$tabs.Visible = $false

$tabPlanA = New-Object System.Windows.Forms.TabPage
$tabPlanA.Text = 'Plan A: AD-Domaene'
$tabPlanB = New-Object System.Windows.Forms.TabPage
$tabPlanB.Text = 'Plan B: Entra / Workgroup'
$tabSettings = New-Object System.Windows.Forms.TabPage
$tabSettings.Text = 'Einstellungen'
$tabSettings.AutoScroll = $true
$tabs.TabPages.AddRange(@($tabPlanA, $tabPlanB, $tabSettings))

#endregion

#region LANDING (Kontoauswahl: angemeldeter Benutzer oder separates Konto)

$pnlLanding = New-Object System.Windows.Forms.Panel
$pnlLanding.Dock = 'Fill'
$pnlTabHost.Controls.Add($pnlLanding)

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

$btnContinueSelf = New-Object System.Windows.Forms.Button
$btnContinueSelf.Text = "Los geht's"
$btnContinueSelf.Location = New-Object System.Drawing.Point(20, 186)
$btnContinueSelf.Size = New-Object System.Drawing.Size(160, 32)

$lblOtherExplain = New-WizardLabel -Text 'Fuer ein separates Konto muessen PIN-Vergabe und Zertifikatsbindung im Sicherheitskontext dieses Kontos erfolgen - dafuer ist eine eigene interaktive Anmeldung noetig (dieselbe Einschraenkung wie beim RDP-Schritt in Plan B, hier aber unabhaengig vom Domaenen-Status). Danach diesen Wizard in der neuen Sitzung erneut starten und dort "Fuer mich" waehlen.' -X 40 -Y 228 -Width 760 -Height 60

$btnRunasCommand = New-Object System.Windows.Forms.Button
$btnRunasCommand.Text = 'runas-Befehl anzeigen && kopieren'
$btnRunasCommand.Location = New-Object System.Drawing.Point(40, 296)
$btnRunasCommand.Size = New-Object System.Drawing.Size(280, 32)
$btnRunasCommand.Enabled = $false

$btnRdpInstructions = New-Object System.Windows.Forms.Button
$btnRdpInstructions.Text = 'RDP-Anleitung anzeigen'
$btnRdpInstructions.Location = New-Object System.Drawing.Point(330, 296)
$btnRdpInstructions.Size = New-Object System.Drawing.Size(220, 32)
$btnRdpInstructions.Enabled = $false

$txtHandoffResult = New-Object System.Windows.Forms.TextBox
$txtHandoffResult.Location = New-Object System.Drawing.Point(40, 340)
$txtHandoffResult.Size = New-Object System.Drawing.Size(760, 140)
$txtHandoffResult.Multiline = $true
$txtHandoffResult.ReadOnly = $true
$txtHandoffResult.ScrollBars = 'Vertical'
$txtHandoffResult.Font = New-Object System.Drawing.Font('Consolas', 9)

$pnlLanding.Controls.AddRange(@($lblLandingTitle, $radSelf, $radOther, $lblOtherAccount, $txtOtherAccount, $btnContinueSelf, $lblOtherExplain, $btnRunasCommand, $btnRdpInstructions, $txtHandoffResult))

$radSelf.Add_CheckedChanged({
    if ($radSelf.Checked) {
        $txtOtherAccount.Enabled = $false
        $btnContinueSelf.Enabled = $true
        $btnRunasCommand.Enabled = $false
        $btnRdpInstructions.Enabled = $false
    }
})

$radOther.Add_CheckedChanged({
    if ($radOther.Checked) {
        $txtOtherAccount.Enabled = $true
        $btnContinueSelf.Enabled = $false
        $btnRunasCommand.Enabled = $true
        $btnRdpInstructions.Enabled = $true
    }
})

$btnContinueSelf.Add_Click({
    $pnlLanding.Visible = $false
    $tabs.Visible = $true
    $tabs.BringToFront()
})

$btnRunasCommand.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtOtherAccount.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst ein Zielkonto angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $scriptPath = Join-Path $PSScriptRoot 'VscWizard.ps1'
    $innerQuoted = '\"' + $scriptPath + '\"'
    $cmd = "runas /user:$($txtOtherAccount.Text) `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File $innerQuoted`""

    $txtHandoffResult.Text = @"
Folgenden Befehl in einer Eingabeaufforderung ausfuehren (fragt nach dem Passwort von $($txtOtherAccount.Text)):

$cmd

Es oeffnet sich eine neue Instanz dieses Wizards, angemeldet als $($txtOtherAccount.Text).
Dort "Fuer mich" waehlen und normal weitermachen (eigene VSC, eigene PIN, eigenes Zertifikat).

Hinweis: runas funktioniert nur, wenn das Zielkonto sich interaktiv lokal anmelden darf.
Falls nicht (z.B. GPO-Einschraenkung), stattdessen die RDP-Anleitung verwenden.
"@
    Set-WizardClipboard -Text $cmd
})

$btnRdpInstructions.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtOtherAccount.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst ein Zielkonto angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $txtHandoffResult.Text = @"
Per RDP als $($txtOtherAccount.Text) anmelden - entweder:

- Lokal per Loopback-RDP auf diesem Rechner (mstsc /v:localhost), oder
- Auf einem anderen (idealerweise domaenen-gebundenen bzw. CA-erreichbaren) Rechner/Server.

Danach diesen Wizard in der neuen Sitzung erneut starten und dort "Fuer mich" waehlen.
Diese Sitzung kann parallel offen bleiben.
"@
})

#endregion

#region LOG PANEL

$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = 'Log / Diagnose'
$logGroup.Dock = 'Fill'
$mainLayout.Controls.Add($logGroup, 0, 1)

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

$layoutA = New-Object System.Windows.Forms.TableLayoutPanel
$layoutA.Dock = 'Fill'
$layoutA.RowCount = 2
$layoutA.ColumnCount = 1
[void]$layoutA.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$layoutA.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
$tabPlanA.Controls.Add($layoutA)

$pnlStepsA = New-Object System.Windows.Forms.Panel
$pnlStepsA.Dock = 'Fill'
$layoutA.Controls.Add($pnlStepsA, 0, 0)

$navA = New-Object System.Windows.Forms.TableLayoutPanel
$navA.Dock = 'Fill'
$navA.ColumnCount = 3
[void]$navA.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$navA.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$navA.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
$layoutA.Controls.Add($navA, 0, 1)

$lblStepA = New-Object System.Windows.Forms.Label
$lblStepA.Dock = 'Fill'
$lblStepA.TextAlign = 'MiddleLeft'
$navA.Controls.Add($lblStepA, 0, 0)

$btnBackA = New-Object System.Windows.Forms.Button
$btnBackA.Text = '< Zurueck'
$btnBackA.Dock = 'Fill'
$navA.Controls.Add($btnBackA, 1, 0)

$btnNextA = New-Object System.Windows.Forms.Button
$btnNextA.Text = 'Weiter >'
$btnNextA.Dock = 'Fill'
$navA.Controls.Add($btnNextA, 2, 0)

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

$lblVscInfoA = New-WizardLabel -Text 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur fuer diesen Schritt benoetigt) sowie ein PIN-Dialog von Windows zur Vergabe der Karten-PIN.' -X 20 -Y 84 -Width 780 -Height 50

$btnCreateVscA = New-Object System.Windows.Forms.Button
$btnCreateVscA.Text = 'Virtuelle Smartcard erstellen'
$btnCreateVscA.Location = New-Object System.Drawing.Point(20, 146)
$btnCreateVscA.Size = New-Object System.Drawing.Size(240, 32)

$lblVscResultA = New-WizardLabel -Text '' -X 20 -Y 190 -Width 780

$pnlA2.Controls.AddRange(@($lblCardNameA, $txtCardNameA, $lblVscInfoA, $btnCreateVscA, $lblVscResultA))

$btnCreateVscA.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCardNameA.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte einen Kartennamen angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateVscA.Enabled = $false
    $lblVscResultA.ForeColor = [System.Drawing.Color]::Black
    $lblVscResultA.Text = 'Erstelle virtuelle Smartcard - bitte UAC- und PIN-Dialog bestaetigen...'
    $form.Refresh()

    $result = New-VirtualSmartCard -CardName $txtCardNameA.Text
    if ($result.Success) {
        $script:PlanA_VscCreated = $true
        $script:PlanA_CardName = $txtCardNameA.Text
        $lblVscResultA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblVscResultA.Text = 'Virtuelle Smartcard wurde erfolgreich erstellt.'
    } else {
        $lblVscResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblVscResultA.Text = "Fehler bei der Erstellung (Exit-Code $($result.ExitCode)). Details siehe Log."
    }
    $btnCreateVscA.Enabled = $true
})

# --- Schritt A3: Zertifikat anfordern ---
$pnlA3 = New-Object System.Windows.Forms.Panel
$pnlA3.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA3)

$lblTemplateA = New-WizardLabel -Text 'Zertifikatstemplate:' -X 20 -Y 20 -Width 300
$cboTemplateA = New-Object System.Windows.Forms.ComboBox
$cboTemplateA.Location = New-Object System.Drawing.Point(20, 46)
$cboTemplateA.Size = New-Object System.Drawing.Size(300, 24)
$cboTemplateA.DropDownStyle = 'DropDownList'
Set-TemplateComboItem -ComboBox $cboTemplateA -Template $config.Template

$btnRequestCertA = New-Object System.Windows.Forms.Button
$btnRequestCertA.Text = 'Zertifikat anfordern'
$btnRequestCertA.Location = New-Object System.Drawing.Point(20, 84)
$btnRequestCertA.Size = New-Object System.Drawing.Size(240, 32)

$lblCertResultA = New-WizardLabel -Text '' -X 20 -Y 128 -Width 780 -Height 50

$btnRetrieveA = New-Object System.Windows.Forms.Button
$btnRetrieveA.Text = 'Zertifikat abrufen (bei Genehmigung)'
$btnRetrieveA.Location = New-Object System.Drawing.Point(20, 190)
$btnRetrieveA.Size = New-Object System.Drawing.Size(260, 32)
$btnRetrieveA.Visible = $false

$pnlA3.Controls.AddRange(@($lblTemplateA, $cboTemplateA, $btnRequestCertA, $lblCertResultA, $btnRetrieveA))

$btnRequestCertA.Add_Click({
    if (-not $cboTemplateA.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show('Bitte ein Zertifikatstemplate auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnRequestCertA.Enabled = $false
    $lblCertResultA.ForeColor = [System.Drawing.Color]::Black
    $lblCertResultA.Text = 'Erstelle Zertifikatsanforderung - ggf. erscheint ein PIN-Dialog der Smartcard...'
    $form.Refresh()

    $script:PlanA_EnrollDir = Join-Path (Get-WizardWorkingDir) "PlanA-$($script:PlanA_CardName)"
    $upn = Get-CurrentUpn
    $subject = "CN=$env:USERNAME"

    $csr = New-CertificateSigningRequest -Subject $subject -Upn $upn -CspName $config.CspName -OutputDirectory $script:PlanA_EnrollDir
    if (-not $csr.Success) {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = 'CSR-Erstellung fehlgeschlagen. Details siehe Log.'
        $btnRequestCertA.Enabled = $true
        return
    }

    $submit = Submit-CertificateSigningRequest -CsrPath $csr.CsrPath -CAConfig $config.CAConfig -TemplateName $cboTemplateA.SelectedItem -OutputDirectory $script:PlanA_EnrollDir
    if ($submit.Pending) {
        $script:PlanA_PendingRequestId = $submit.RequestId
        $lblCertResultA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblCertResultA.Text = "Antrag wurde eingereicht und wartet auf Genehmigung (RequestId $($submit.RequestId)). Bitte spaeter erneut abrufen."
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
    $summary = Get-IssuedCertificateSummary -SubjectContains $env:USERNAME
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

    if ($joinState.Mode -ne 'ADDomain') {
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
    $lblStepA.Text = "Schritt $($Index + 1) von $($panels.Count): $($planAStepTitles[$Index])"
    $btnBackA.Enabled = ($Index -gt 0)
    $btnNextA.Enabled = ($Index -lt $panels.Count - 1)

    switch ($Index) {
        0 { Update-PlanAStatus }
        3 { Update-PlanASummary }
    }
}

$btnNextA.Add_Click({
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
})

$btnBackA.Add_Click({
    if ($script:PlanACurrentStep -gt 0) {
        Show-PlanAStep -Index ($script:PlanACurrentStep - 1)
    }
})

#endregion

# ============================================================================
#region PLAN B TAB
# ============================================================================

$layoutB = New-Object System.Windows.Forms.TableLayoutPanel
$layoutB.Dock = 'Fill'
$layoutB.RowCount = 2
$layoutB.ColumnCount = 1
[void]$layoutB.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$layoutB.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
$tabPlanB.Controls.Add($layoutB)

$pnlStepsB = New-Object System.Windows.Forms.Panel
$pnlStepsB.Dock = 'Fill'
$layoutB.Controls.Add($pnlStepsB, 0, 0)

$navB = New-Object System.Windows.Forms.TableLayoutPanel
$navB.Dock = 'Fill'
$navB.ColumnCount = 3
[void]$navB.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$navB.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$navB.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
$layoutB.Controls.Add($navB, 0, 1)

$lblStepB = New-Object System.Windows.Forms.Label
$lblStepB.Dock = 'Fill'
$lblStepB.TextAlign = 'MiddleLeft'
$navB.Controls.Add($lblStepB, 0, 0)

$btnBackB = New-Object System.Windows.Forms.Button
$btnBackB.Text = '< Zurueck'
$btnBackB.Dock = 'Fill'
$navB.Controls.Add($btnBackB, 1, 0)

$btnNextB = New-Object System.Windows.Forms.Button
$btnNextB.Text = 'Weiter >'
$btnNextB.Dock = 'Fill'
$navB.Controls.Add($btnNextB, 2, 0)

# --- Schritt B1: Status ---
$pnlB1 = New-Object System.Windows.Forms.Panel
$pnlB1.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB1)

$lblJoinStateB = New-WizardLabel -Text 'Domaenen-Status: ...' -X 20 -Y 20
$lblUserB = New-WizardLabel -Text 'Angemeldeter Benutzer: ...' -X 20 -Y 50
$lblJumpServerB = New-WizardLabel -Text '' -X 20 -Y 80
$lblExplainB = New-WizardLabel -Text 'Dieser Modus fuehrt eine virtuelle Smartcard und einen Zertifikatsantrag ueber einen Zwischenschritt per RDP durch, da dieser Rechner voraussichtlich keine direkte Sicht auf die Zertifizierungsstelle hat. CA-Konfiguration und automatische PKI-Erkennung finden sich im Tab "Einstellungen".' -X 20 -Y 116 -Width 780 -Height 60
$pnlB1.Controls.AddRange(@($lblJoinStateB, $lblUserB, $lblJumpServerB, $lblExplainB))

# --- Schritt B2: VSC erstellen ---
$pnlB2 = New-Object System.Windows.Forms.Panel
$pnlB2.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB2)

$lblCardNameB = New-WizardLabel -Text 'Name der virtuellen Smartcard:' -X 20 -Y 20 -Width 300
$txtCardNameB = New-Object System.Windows.Forms.TextBox
$txtCardNameB.Location = New-Object System.Drawing.Point(20, 46)
$txtCardNameB.Size = New-Object System.Drawing.Size(300, 24)
$txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"

$lblVscInfoB = New-WizardLabel -Text 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur fuer diesen Schritt benoetigt) sowie ein PIN-Dialog von Windows zur Vergabe der Karten-PIN.' -X 20 -Y 84 -Width 780 -Height 50

$btnCreateVscB = New-Object System.Windows.Forms.Button
$btnCreateVscB.Text = 'Virtuelle Smartcard erstellen'
$btnCreateVscB.Location = New-Object System.Drawing.Point(20, 146)
$btnCreateVscB.Size = New-Object System.Drawing.Size(240, 32)

$lblVscResultB = New-WizardLabel -Text '' -X 20 -Y 190 -Width 780

$pnlB2.Controls.AddRange(@($lblCardNameB, $txtCardNameB, $lblVscInfoB, $btnCreateVscB, $lblVscResultB))

$btnCreateVscB.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCardNameB.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte einen Kartennamen angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateVscB.Enabled = $false
    $lblVscResultB.ForeColor = [System.Drawing.Color]::Black
    $lblVscResultB.Text = 'Erstelle virtuelle Smartcard - bitte UAC- und PIN-Dialog bestaetigen...'
    $form.Refresh()

    $result = New-VirtualSmartCard -CardName $txtCardNameB.Text
    if ($result.Success) {
        $script:PlanB_VscCreated = $true
        $script:PlanB_CardName = $txtCardNameB.Text
        $lblVscResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblVscResultB.Text = 'Virtuelle Smartcard wurde erfolgreich erstellt.'
    } else {
        $lblVscResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblVscResultB.Text = "Fehler bei der Erstellung (Exit-Code $($result.ExitCode)). Details siehe Log."
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

$pnlB3.Controls.AddRange(@($lblCsrInfoB, $btnCreateCsrB, $lblCsrPathLabelB, $txtCsrPathB, $btnCopyCsrPathB, $btnOpenCsrFolderB))

$btnCreateCsrB.Add_Click({
    if (-not $script:PlanB_VscCreated) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst die virtuelle Smartcard erstellen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateCsrB.Enabled = $false
    $script:PlanB_EnrollDir = Join-Path (Get-WizardWorkingDir) "PlanB-$($script:PlanB_CardName)"
    $upn = Get-CurrentUpn
    $subject = "CN=$env:USERNAME"

    $csr = New-CertificateSigningRequest -Subject $subject -Upn $upn -CspName $config.CspName -OutputDirectory $script:PlanB_EnrollDir
    if ($csr.Success) {
        $script:PlanB_CsrPath = $csr.CsrPath
        $txtCsrPathB.Text = $csr.CsrPath
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

# --- Schritt B4: Uebergabe per RDP ---
$pnlB4 = New-Object System.Windows.Forms.Panel
$pnlB4.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB4)

$lblHandoffB = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 220
$pnlB4.Controls.Add($lblHandoffB)

function Update-PlanBHandoff {
    $lblHandoffB.Text = @"
Naechste Schritte:

1. Per RDP verbinden mit: $($config.RdpJumpServer)
2. Dort als derselbe Benutzer anmelden: $env:USERDOMAIN\$env:USERNAME
3. Die CSR-Datei auf den Server kopieren (z.B. ueber Zwischenablage/Laufwerksfreigabe):
   $($script:PlanB_CsrPath)
4. Diesen Wizard auf dem Server erneut starten, ebenfalls den Tab "Plan B" waehlen
   und bis zu Schritt "Antrag einreichen (auf dem Server)" weiterklicken.

Auf "Weiter" klicken, sobald du auf dem Server angemeldet bist.
"@
}

# --- Schritt B5: Antrag einreichen (auf dem Server) ---
$pnlB5 = New-Object System.Windows.Forms.Panel
$pnlB5.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB5)

$lblSubmitInfoB = New-WizardLabel -Text 'Auf dem CA-nahen Server auszufuehren (angemeldet als Zielbenutzer):' -X 20 -Y 20 -Width 780

$btnSelectCsrB = New-Object System.Windows.Forms.Button
$btnSelectCsrB.Text = 'CSR-Datei auswaehlen...'
$btnSelectCsrB.Location = New-Object System.Drawing.Point(20, 54)
$btnSelectCsrB.Size = New-Object System.Drawing.Size(200, 30)

$txtSelectedCsrB = New-Object System.Windows.Forms.TextBox
$txtSelectedCsrB.Location = New-Object System.Drawing.Point(230, 58)
$txtSelectedCsrB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCsrB.ReadOnly = $true

$lblTemplateSubmitB = New-WizardLabel -Text 'Zertifikatstemplate:' -X 20 -Y 96 -Width 200
$cboTemplateSubmitB = New-Object System.Windows.Forms.ComboBox
$cboTemplateSubmitB.Location = New-Object System.Drawing.Point(230, 92)
$cboTemplateSubmitB.Size = New-Object System.Drawing.Size(300, 24)
$cboTemplateSubmitB.DropDownStyle = 'DropDownList'
Set-TemplateComboItem -ComboBox $cboTemplateSubmitB -Template $config.Template

$btnSubmitB = New-Object System.Windows.Forms.Button
$btnSubmitB.Text = 'Einreichen'
$btnSubmitB.Location = New-Object System.Drawing.Point(20, 130)
$btnSubmitB.Size = New-Object System.Drawing.Size(200, 32)

$btnRetrieveB = New-Object System.Windows.Forms.Button
$btnRetrieveB.Text = 'Zertifikat abrufen (bei Genehmigung)'
$btnRetrieveB.Location = New-Object System.Drawing.Point(230, 130)
$btnRetrieveB.Size = New-Object System.Drawing.Size(260, 32)
$btnRetrieveB.Visible = $false

$lblSubmitResultB = New-WizardLabel -Text '' -X 20 -Y 174 -Width 780 -Height 40

$lblCerPathLabelB = New-WizardLabel -Text 'Pfad der ausgestellten Zertifikatsdatei:' -X 20 -Y 218 -Width 400
$txtCerPathB = New-Object System.Windows.Forms.TextBox
$txtCerPathB.Location = New-Object System.Drawing.Point(20, 244)
$txtCerPathB.Size = New-Object System.Drawing.Size(560, 24)
$txtCerPathB.ReadOnly = $true

$btnCopyCerPathB = New-Object System.Windows.Forms.Button
$btnCopyCerPathB.Text = 'Pfad kopieren'
$btnCopyCerPathB.Location = New-Object System.Drawing.Point(590, 242)
$btnCopyCerPathB.Size = New-Object System.Drawing.Size(120, 28)

$btnOpenCerFolderB = New-Object System.Windows.Forms.Button
$btnOpenCerFolderB.Text = 'Ordner oeffnen'
$btnOpenCerFolderB.Location = New-Object System.Drawing.Point(20, 280)
$btnOpenCerFolderB.Size = New-Object System.Drawing.Size(160, 28)

$pnlB5.Controls.AddRange(@($lblSubmitInfoB, $btnSelectCsrB, $txtSelectedCsrB, $lblTemplateSubmitB, $cboTemplateSubmitB, $btnSubmitB, $btnRetrieveB, $lblSubmitResultB, $lblCerPathLabelB, $txtCerPathB, $btnCopyCerPathB, $btnOpenCerFolderB))

$btnSelectCsrB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSR-Dateien (*.csr;*.req)|*.csr;*.req|Alle Dateien (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSelectedCsrB.Text = $dlg.FileName
    }
})

$btnSubmitB.Add_Click({
    if (-not $txtSelectedCsrB.Text) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst eine CSR-Datei auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $cboTemplateSubmitB.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show('Bitte ein Zertifikatstemplate auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnSubmitB.Enabled = $false
    $script:PlanB_SubmitDir = Split-Path $txtSelectedCsrB.Text -Parent

    $submit = Submit-CertificateSigningRequest -CsrPath $txtSelectedCsrB.Text -CAConfig $config.CAConfig -TemplateName $cboTemplateSubmitB.SelectedItem -OutputDirectory $script:PlanB_SubmitDir
    if ($submit.Pending) {
        $script:PlanB_PendingRequestId = $submit.RequestId
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblSubmitResultB.Text = "Antrag wartet auf Genehmigung (RequestId $($submit.RequestId))."
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

$lblCompleteInfoB = New-WizardLabel -Text 'Zurueck auf dem lokalen Rechner: die vom Server zurueckkopierte Zertifikatsdatei (.cer) auswaehlen.' -X 20 -Y 20 -Width 780 -Height 40

$btnSelectCerB = New-Object System.Windows.Forms.Button
$btnSelectCerB.Text = 'CER-Datei auswaehlen...'
$btnSelectCerB.Location = New-Object System.Drawing.Point(20, 66)
$btnSelectCerB.Size = New-Object System.Drawing.Size(200, 30)

$txtSelectedCerB = New-Object System.Windows.Forms.TextBox
$txtSelectedCerB.Location = New-Object System.Drawing.Point(230, 70)
$txtSelectedCerB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCerB.ReadOnly = $true

$btnCompleteB = New-Object System.Windows.Forms.Button
$btnCompleteB.Text = 'Zertifikat abschliessen'
$btnCompleteB.Location = New-Object System.Drawing.Point(20, 110)
$btnCompleteB.Size = New-Object System.Drawing.Size(200, 32)

$lblCompleteResultB = New-WizardLabel -Text '' -X 20 -Y 154 -Width 780 -Height 40

$lblSummaryB = New-WizardLabel -Text '' -X 20 -Y 200 -Width 780 -Height 110

$btnResetB = New-Object System.Windows.Forms.Button
$btnResetB.Text = 'Weitere Smartcard beantragen'
$btnResetB.Location = New-Object System.Drawing.Point(20, 320)
$btnResetB.Size = New-Object System.Drawing.Size(240, 32)

$pnlB6.Controls.AddRange(@($lblCompleteInfoB, $btnSelectCerB, $txtSelectedCerB, $btnCompleteB, $lblCompleteResultB, $lblSummaryB, $btnResetB))

$btnSelectCerB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Zertifikatsdateien (*.cer)|*.cer|Alle Dateien (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSelectedCerB.Text = $dlg.FileName
    }
})

function Update-PlanBSummary {
    $summary = Get-IssuedCertificateSummary -SubjectContains $env:USERNAME
    if ($summary) {
        $lblSummaryB.Text = "Kartenname: $($script:PlanB_CardName)`r`nZertifikat: $($summary.Subject)`r`nThumbprint: $($summary.Thumbprint)`r`nGueltig ab: $($summary.NotBefore)`r`nGueltig bis: $($summary.NotAfter)"
    } else {
        $lblSummaryB.Text = 'Kein passendes Zertifikat gefunden.'
    }
}

$btnCompleteB.Add_Click({
    if (-not $txtSelectedCerB.Text) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst eine CER-Datei auswaehlen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCompleteB.Enabled = $false
    $complete = Complete-CertificateEnrollment -CerPath $txtSelectedCerB.Text
    if ($complete.Success) {
        $script:PlanB_CertIssued = $true
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCompleteResultB.Text = 'Zertifikat wurde erfolgreich auf der virtuellen Smartcard hinterlegt.'
        Update-PlanBSummary
    } else {
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCompleteResultB.Text = 'Uebernahme fehlgeschlagen. Details siehe Log.'
    }
    $btnCompleteB.Enabled = $true
})

$btnResetB.Add_Click({
    $script:PlanB_VscCreated = $false
    $script:PlanB_CertIssued = $false
    $script:PlanB_PendingRequestId = $null
    $txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"
    $lblVscResultB.Text = ''
    $txtCsrPathB.Text = ''
    $txtSelectedCsrB.Text = ''
    $txtCerPathB.Text = ''
    $txtSelectedCerB.Text = ''
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
    $lblJumpServerB.Text = "CA-naher Server (RDP-Ziel): $($config.RdpJumpServer)"
}

function Show-PlanBStep {
    param([int]$Index)
    $panels = @($pnlB1, $pnlB2, $pnlB3, $pnlB4, $pnlB5, $pnlB6)
    for ($i = 0; $i -lt $panels.Count; $i++) {
        $panels[$i].Visible = ($i -eq $Index)
    }
    $script:PlanBCurrentStep = $Index
    $lblStepB.Text = "Schritt $($Index + 1) von $($panels.Count): $($planBStepTitles[$Index])"
    $btnBackB.Enabled = ($Index -gt 0)
    $btnNextB.Enabled = ($Index -lt $panels.Count - 1)

    switch ($Index) {
        0 { Update-PlanBStatus }
        3 { Update-PlanBHandoff }
    }
}

$btnNextB.Add_Click({
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
            if (-not $txtCerPathB.Text) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst den Antrag einreichen und das Zertifikat erhalten.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanBStep -Index 5
        }
    }
})

$btnBackB.Add_Click({
    if ($script:PlanBCurrentStep -gt 0) {
        Show-PlanBStep -Index ($script:PlanBCurrentStep - 1)
    }
})

#endregion

# ============================================================================
#region EINSTELLUNGEN TAB
# ============================================================================

$settingsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$settingsLayout.Dock = 'Top'
$settingsLayout.AutoSize = $true
$settingsLayout.AutoSizeMode = 'GrowAndShrink'
$settingsLayout.ColumnCount = 2
$settingsLayout.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 16)
[void]$settingsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 280)))
[void]$settingsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$tabSettings.Controls.Add($settingsLayout)

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

$txtCfgCsp = New-Object System.Windows.Forms.TextBox
$txtCfgCsp.Text = $config.CspName
Add-SettingsRow -LabelText 'Crypto Service Provider (CSP):' -InputControl $txtCfgCsp

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

$savePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$savePanel.AutoSize = $true
$savePanel.FlowDirection = 'LeftToRight'
$savePanel.WrapContents = $false

$btnSaveConfig = New-Object System.Windows.Forms.Button
$btnSaveConfig.Text = 'Speichern'
$btnSaveConfig.Size = New-Object System.Drawing.Size(160, 32)
$savePanel.Controls.Add($btnSaveConfig)

$lblCfgSaved = New-Object System.Windows.Forms.Label
$lblCfgSaved.AutoSize = $true
$lblCfgSaved.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblCfgSaved.Margin = New-Object System.Windows.Forms.Padding(10, 8, 0, 0)
$savePanel.Controls.Add($lblCfgSaved)

Add-SettingsFullRow -Control $savePanel

$btnDiscoverCfg.Add_Click({
    $btnDiscoverCfg.Enabled = $false
    $txtDiscoverResultCfg.Text = 'Pruefe PKI-Erreichbarkeit (bis zu ca. 40 Sekunden)...'
    $form.Refresh()

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
        WorkingDir    = $config.WorkingDir
    }
    Save-VscWizardConfig -Config $newConfig -Path $script:ConfigPath
    $script:config = $newConfig

    Set-TemplateComboItem -ComboBox $cboTemplateA -Template $newConfig.Template
    Set-TemplateComboItem -ComboBox $cboTemplateSubmitB -Template $newConfig.Template

    $lblCfgSaved.ForeColor = [System.Drawing.Color]::ForestGreen
    $lblCfgSaved.Text = 'Gespeichert.'
})

#endregion

# ============================================================================
#region STARTUP
# ============================================================================

Show-PlanAStep -Index 0
Show-PlanBStep -Index 0

$configIncomplete = [string]::IsNullOrWhiteSpace($config.CAConfig) -or [string]::IsNullOrWhiteSpace($config.Template)
if ($configIncomplete) {
    $tabs.SelectedTab = $tabSettings
} else {
    $joinStateStartup = Get-DomainJoinState
    if ($joinStateStartup.Mode -eq 'ADDomain') {
        $tabs.SelectedTab = $tabPlanA
    } else {
        $tabs.SelectedTab = $tabPlanB
    }
}

[void]$form.ShowDialog()

#endregion
