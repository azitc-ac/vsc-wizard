<#
.SYNOPSIS
    VSC-Wizard Einreichungshelfer - eigenstaendiges Begleitwerkzeug fuer die
    RDP-Sitzung auf einem CA-nahen Server (Plan B, Schritt 5).
.DESCRIPTION
    Nimmt eine per Zwischenablage eingefuegte Zertifikatsanforderung (CSR, PEM-Text)
    entgegen, reicht sie bei der Zertifizierungsstelle ein und gibt das ausgestellte
    Zertifikat wieder als kopierbaren PEM-Text zurueck - damit fuer die Uebergabe
    zwischen der lokalen Sitzung (Entra-joined/Workgroup-Rechner oder separates
    Zielkonto) und der RDP-Sitzung weder Laufwerksfreigabe noch Dateitransfer noetig
    ist, nur RDP-Zwischenablage (Text).

    Bewusst als EIGENSTAENDIGE Einzeldatei ohne Abhaengigkeit zu VscWizard.Core.psm1
    gehalten: laesst sich im Notfall als reiner Text per RDP-Zwischenablage in die
    Zielsitzung kopieren, dort in eine neue .ps1-Datei einfuegen und direkt starten -
    ganz ohne den Rest des Projekts mit rueberzukopieren.
.NOTES
    Gegenstueck im Hauptwizard: VscWizard.ps1, Plan B Schritt 3 ("CSR erstellen")
    zeigt den CSR-Inhalt ebenfalls als kopierbaren Text an, Schritt 6
    ("Zertifikat abschliessen") akzeptiert das Ergebnis dieses Tools per Text-Einfuegen
    als Alternative zur Dateiauswahl.
#>

#Requires -Version 5.1

# Siehe VscWizard.Core.psm1 fuer den Hintergrund: in einer PowerShell-7-gepraegten
# Umgebung kann Windows PowerShell 5.1 beim Autoloading versehentlich die falsche
# Microsoft.PowerShell.Utility-Modulvariante laden. Fuer dieses Skript nicht
# zwingend relevant (kein Import-PowerShellDataFile), aber schadet nicht.
$nativeUtilityModule = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1'
if (Test-Path $nativeUtilityModule) {
    Import-Module $nativeUtilityModule -Force -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:WorkDir = Join-Path $env:TEMP "VscWizardSubmit-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null

function Write-Status {
    param([Parameter(Mandatory)][string]$Message)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $txtLog.AppendText("[$timestamp] $Message`r`n")
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 0
    )
    $quotedArgs = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $quotedArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    Write-Status "$FilePath $quotedArgs"

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    if ($TimeoutSeconds -gt 0) {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            Write-Status 'Zeitueberschreitung.'
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'Timeout'; Success = $false }
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
    } else {
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
    }

    if ($stdout.Trim()) { Write-Status $stdout.Trim() }
    if ($stderr.Trim()) { Write-Status $stderr.Trim() }

    [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr; Success = ($proc.ExitCode -eq 0) }
}

function Find-ReachableCA {
    # Vereinfachte, eigenstaendige Variante der Discovery aus VscWizard.Core.psm1
    # (LDAP-Discovery der Enterprise-CAs + RPC-Erreichbarkeitstest). Auf einem
    # CA-nahen Server (der Zweck dieses Tools) sollte serverloses LDAP-Binding i.d.R.
    # ohne expliziten Domain-Hint funktionieren; das Feld ist trotzdem editierbar,
    # falls nicht.
    param([string]$Server, [int]$TimeoutSeconds = 8)

    try {
        $rootPath = if ($Server) { "LDAP://$Server/RootDSE" } else { 'LDAP://RootDSE' }
        $rootDse = New-Object System.DirectoryServices.DirectoryEntry($rootPath)
        $configNC = $rootDse.Properties['configurationNamingContext'].Value
        if (-not $configNC) { return , @() }

        $casDn = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configNC"
        $casPath = if ($Server) { "LDAP://$Server/$casDn" } else { "LDAP://$casDn" }
        $searcher = New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry($casPath)))
        $searcher.Filter = '(objectClass=pKIEnrollmentService)'
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        [void]$searcher.PropertiesToLoad.AddRange(@('cn', 'dNSHostName', 'certificateTemplates'))

        # Attribute defensiv lesen: je nach Bind-Ziel koennen Ergebnisse ohne die
        # erwarteten Attribute auftauchen (z.B. bei versehentlichem Bind gegen eine
        # fremde/oeffentliche Domaene) - ungeschuetztes ['cn'][0] wirft dann
        # "Cannot index into a null array".
        $cas = foreach ($r in $searcher.FindAll()) {
            if (-not $r.Properties['cn'] -or $r.Properties['cn'].Count -eq 0) { continue }
            if (-not $r.Properties['dNSHostName'] -or $r.Properties['dNSHostName'].Count -eq 0) { continue }
            $name = $r.Properties['cn'][0]
            $srv = $r.Properties['dNSHostName'][0]
            [pscustomobject]@{ Name = $name; ConfigString = "$srv\$name"; Templates = @($r.Properties['certificateTemplates']) }
        }

        $reachable = foreach ($ca in $cas) {
            $ping = Invoke-Tool -FilePath 'certutil.exe' -ArgumentList @('-ping', '-config', $ca.ConfigString) -TimeoutSeconds $TimeoutSeconds
            if ($ping.Success) { $ca }
        }
        # Als Array-Objekt (Komma-Operator) zurueckgeben: PowerShell packt ein
        # einelementiges @(...) beim Funktionsreturn wieder aus, und ein einzelnes
        # PSCustomObject hat in Windows PowerShell 5.1 KEINE synthetische
        # .Count-Eigenschaft (erst ab PowerShell 6.1) - der Aufrufer saehe dann
        # trotz erfolgreichem Fund "Count = null" und wuerfe das Ergebnis weg.
        return , @($reachable)
    } catch {
        Write-Status "LDAP-Erkennung fehlgeschlagen: $($_.Exception.Message)"
        return , @()
    }
}

#region MAIN FORM

$form = New-Object System.Windows.Forms.Form
$form.Text = 'VSC-Wizard Einreichungshelfer (RDP-Sitzung)'
$form.Size = New-Object System.Drawing.Size(760, 760)
$form.MinimumSize = New-Object System.Drawing.Size(680, 640)
$form.StartPosition = 'CenterScreen'

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 10
$layout.Padding = New-Object System.Windows.Forms.Padding(14)
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 0: CSR-Label
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 32))) # 1: CSR-Box
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 2: CA-Panel
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 3: Discover-Button
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 4: Submit-Button
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 5: Retrieve-Button
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 6: Ergebnis-Label
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 28))) # 7: Ergebnis-Box
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))    # 8: Log-Label
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 25))) # 9: Log-Box
$form.Controls.Add($layout)

function New-FormLabel {
    param([string]$Text, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.AutoSize = $true
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, $Style)
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 2)
    return $lbl
}

$layout.Controls.Add((New-FormLabel -Text 'CSR aus der lokalen Sitzung hier einfuegen (PEM-Text, aus VscWizard Plan B Schritt 3 kopiert):' -Style Bold), 0, 0)

$txtCsr = New-Object System.Windows.Forms.TextBox
$txtCsr.Multiline = $true
$txtCsr.ScrollBars = 'Vertical'
$txtCsr.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtCsr.Dock = 'Fill'
$layout.Controls.Add($txtCsr, 0, 1)

$caPanel = New-Object System.Windows.Forms.TableLayoutPanel
$caPanel.AutoSize = $true
$caPanel.ColumnCount = 2
[void]$caPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 200)))
[void]$caPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$layout.Controls.Add($caPanel, 0, 2)

function Add-CaRow {
    param([string]$LabelText, [System.Windows.Forms.Control]$Control)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText
    $lbl.AutoSize = $true
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
    $Control.Dock = 'Fill'
    $Control.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
    $rowIndex = $caPanel.RowCount
    $caPanel.RowCount = $rowIndex + 1
    [void]$caPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $caPanel.Controls.Add($lbl, 0, $rowIndex)
    $caPanel.Controls.Add($Control, 1, $rowIndex)
}

$txtDomain = New-Object System.Windows.Forms.TextBox
try {
    $upn = (& whoami /upn) 2>$null
    if ($upn -and $upn -notmatch 'ERROR' -and $upn.Contains('@')) { $txtDomain.Text = $upn.Split('@')[1] }
} catch { }
Add-CaRow -LabelText 'AD-Domaene/DC (optional):' -Control $txtDomain

$txtCA = New-Object System.Windows.Forms.TextBox
Add-CaRow -LabelText 'CA-Konfigurationsstring:' -Control $txtCA

$cboTemplate = New-Object System.Windows.Forms.ComboBox
$cboTemplate.DropDownStyle = 'DropDown'
Add-CaRow -LabelText 'Zertifikatstemplate:' -Control $cboTemplate

$btnDiscover = New-Object System.Windows.Forms.Button
$btnDiscover.Text = 'CA automatisch erkennen'
$btnDiscover.Size = New-Object System.Drawing.Size(220, 30)
$btnDiscover.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 8)
$layout.Controls.Add($btnDiscover, 0, 3)

$btnSubmit = New-Object System.Windows.Forms.Button
$btnSubmit.Text = 'Antrag einreichen'
$btnSubmit.Size = New-Object System.Drawing.Size(220, 34)
$btnSubmit.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
$layout.Controls.Add($btnSubmit, 0, 4)

$btnRetrieve = New-Object System.Windows.Forms.Button
$btnRetrieve.Text = 'Zertifikat abrufen (bei Genehmigung)'
$btnRetrieve.Size = New-Object System.Drawing.Size(260, 30)
$btnRetrieve.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$btnRetrieve.Visible = $false
$layout.Controls.Add($btnRetrieve, 0, 5)

$layout.Controls.Add((New-FormLabel -Text 'Ergebnis (PEM-Text - zum Kopieren zurueck in die lokale Sitzung markiert/kopiert):' -Style Bold), 0, 6)

$txtResult = New-Object System.Windows.Forms.TextBox
$txtResult.Multiline = $true
$txtResult.ReadOnly = $true
$txtResult.ScrollBars = 'Vertical'
$txtResult.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtResult.Dock = 'Fill'
$layout.Controls.Add($txtResult, 0, 7)

$layout.Controls.Add((New-FormLabel -Text 'Log:'), 0, 8)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8)
$txtLog.Dock = 'Fill'
$layout.Controls.Add($txtLog, 0, 9)

#endregion

$script:PendingRequestId = $null

$btnDiscover.Add_Click({
    $btnDiscover.Enabled = $false
    Write-Status 'Suche erreichbare CA...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()

    # @() am Aufrufer als zweite Absicherung gegen das Array-Unwrapping (s. Kommentar
    # in Find-ReachableCA).
    $cas = @(Find-ReachableCA -Server $txtDomain.Text.Trim())
    if ($cas.Count -gt 0) {
        $txtCA.Text = $cas[0].ConfigString
        $allTemplates = @($cas | ForEach-Object { $_.Templates } | Where-Object { $_ } | Select-Object -Unique)
        if ($allTemplates.Count -gt 0) {
            $cboTemplate.Items.Clear()
            [void]$cboTemplate.Items.AddRange($allTemplates)
            $cboTemplate.Text = $allTemplates[0]
        }
        Write-Status "$($cas.Count) erreichbare CA(s) gefunden, erste uebernommen."
    } else {
        Write-Status 'Keine erreichbare CA gefunden - bitte CA-Konfigurationsstring manuell eintragen.'
    }
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    $btnDiscover.Enabled = $true
})

function Complete-Submission {
    param([string]$CerPath)
    try {
        $b64Path = Join-Path $script:WorkDir 'issued.b64.cer'
        $encodeResult = Invoke-Tool -FilePath 'certutil.exe' -ArgumentList @('-encode', $CerPath, $b64Path)
        if ($encodeResult.Success -and (Test-Path $b64Path)) {
            $txtResult.Text = (Get-Content -Path $b64Path -Raw)
        } else {
            $txtResult.Text = (Get-Content -Path $CerPath -Raw)
            Write-Status 'certutil -encode fehlgeschlagen, zeige Rohinhalt der Zertifikatsdatei stattdessen.'
        }
        $txtResult.SelectAll()
        $txtResult.Focus()
        Set-Clipboard -Value $txtResult.Text
        Write-Status 'Ergebnis in die Zwischenablage kopiert. Auf der lokalen Sitzung in Plan B Schritt 6 einfuegen.'
    } catch {
        Write-Status "Fehler beim Aufbereiten des Ergebnisses: $($_.Exception.Message)"
    }
}

$btnSubmit.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCsr.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst den CSR-Text einfuegen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($txtCA.Text) -or [string]::IsNullOrWhiteSpace($cboTemplate.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte CA-Konfigurationsstring und Zertifikatstemplate angeben.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }

    $btnSubmit.Enabled = $false
    $btnRetrieve.Visible = $false
    $txtResult.Text = ''

    $csrPath = Join-Path $script:WorkDir 'request.req'
    Set-Content -Path $csrPath -Value $txtCsr.Text -Encoding ASCII
    $cerPath = Join-Path $script:WorkDir 'certnew.cer'

    $submit = Invoke-Tool -FilePath 'certreq.exe' -ArgumentList @('-submit', '-config', $txtCA.Text, '-attrib', "CertificateTemplate:$($cboTemplate.Text)", $csrPath, $cerPath)

    $requestId = $null
    if ($submit.StdOut -match 'RequestId:\s*(\d+)') { $requestId = $Matches[1] }

    if ($submit.StdOut -match 'Certificate Pending' -or $submit.StdOut -match 'Taken Under Submission') {
        $script:PendingRequestId = $requestId
        Write-Status "Antrag wartet auf Genehmigung (RequestId $requestId)."
        $btnRetrieve.Visible = $true
    } elseif ($submit.Success -and (Test-Path $cerPath)) {
        Write-Status 'Zertifikat ausgestellt.'
        Complete-Submission -CerPath $cerPath
    } else {
        Write-Status 'Antrag fehlgeschlagen - Details siehe Log oben.'
        [System.Windows.Forms.MessageBox]::Show('Antrag fehlgeschlagen. Details siehe Log.', 'Fehler', 'OK', 'Error') | Out-Null
    }
    $btnSubmit.Enabled = $true
})

$btnRetrieve.Add_Click({
    if (-not $script:PendingRequestId) { return }
    $cerPath = Join-Path $script:WorkDir 'certnew.cer'
    $retrieve = Invoke-Tool -FilePath 'certreq.exe' -ArgumentList @('-retrieve', '-config', $txtCA.Text, $script:PendingRequestId, $cerPath)
    if ($retrieve.Success -and (Test-Path $cerPath)) {
        Write-Status 'Zertifikat abgerufen.'
        $btnRetrieve.Visible = $false
        Complete-Submission -CerPath $cerPath
    } else {
        [System.Windows.Forms.MessageBox]::Show('Zertifikat ist noch nicht ausgestellt.', 'Hinweis', 'OK', 'Information') | Out-Null
    }
})

$form.Add_FormClosed({
    Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
})

[void]$form.ShowDialog()
