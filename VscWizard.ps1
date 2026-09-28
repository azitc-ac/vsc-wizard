<#
.SYNOPSIS
    VSC-Wizard - Wizard zur Beantragung virtueller Smartcards (TPM Virtual Smart Card) für AD-Administratoren.
.DESCRIPTION
    Fuehrt Schritt für Schritt durch die Erstellung einer virtuellen Smartcard und die
    Zertifikatsbeantragung. Unterstuetzt zwei Szenarien als Tabs:

      - Plan A: Domänen-gebundener Rechner mit direkter Sicht auf die Enterprise-CA
                (voll automatisiert, CSR-Erstellung und Einreichung in einem Schritt).
      - Plan B: Entra-joined- oder Workgroup-Rechner ohne direkte CA-Sicht
                (CSR wird lokal erzeugt, per RDP-Login als Zielbenutzer auf einen
                CA-nahen Server eingereicht, Zertifikat wird zurückkopiert und
                lokal auf der virtuellen Smartcard hinterlegt).
.NOTES
    Erfordert Windows mit TPM (für tpmvscmgr.exe) sowie certreq.exe.
    Die Erstellung der virtuellen Smartcard erfordert lokale Administratorrechte
    (gezielte UAC-Elevation für diesen einen Schritt); alle uebrigen Schritte laufen
    im normalen Benutzerkontext, da Zertifikate im Benutzer-Zertifikatsspeicher liegen.
#>

#Requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# --- Splash / Start-Fortschritt ---------------------------------------------------
# Der Start dauert mehrere Sekunden (Modul laden, Fenster bauen, Umgebung erkennen via
# TPM/Kerberos/PnP/Zertifikatsspeicher). Ohne Rueckmeldung wirkt das wie eine Blackbox.
# Deshalb sofort einen kleinen Splash zeigen und an den Meilensteinen aktualisieren.
function Show-SplashScreen {
    $sp = New-Object System.Windows.Forms.Form
    $sp.FormBorderStyle = 'None'
    $sp.StartPosition = 'CenterScreen'
    $sp.Size = New-Object System.Drawing.Size(440, 168)
    $sp.BackColor = [System.Drawing.Color]::FromArgb(30, 40, 55)
    $sp.TopMost = $true
    $sp.ShowInTaskbar = $false

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'VSC-Wizard'
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.Size = New-Object System.Drawing.Size(392, 34)
    $sp.Controls.Add($title)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = 'Virtuelle Smartcards & Zertifikate'
    $sub.ForeColor = [System.Drawing.Color]::FromArgb(150, 170, 190)
    $sub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $sub.Location = New-Object System.Drawing.Point(26, 58)
    $sub.Size = New-Object System.Drawing.Size(392, 20)
    $sp.Controls.Add($sub)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'Starte...'
    $status.ForeColor = [System.Drawing.Color]::FromArgb(210, 220, 230)
    $status.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $status.Location = New-Object System.Drawing.Point(26, 96)
    $status.Size = New-Object System.Drawing.Size(392, 20)
    $sp.Controls.Add($status)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(26, 124)
    $bar.Size = New-Object System.Drawing.Size(388, 14)
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = 5
    $sp.Controls.Add($bar)

    $script:Splash = $sp
    $script:SplashStatus = $status
    $script:SplashBar = $bar
    $sp.Show()
    $sp.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    return $sp
}

function Update-Splash {
    param([string]$Text, [int]$Percent = -1)
    if (-not $script:Splash -or $script:Splash.IsDisposed) { return }
    if ($Text) { $script:SplashStatus.Text = $Text }
    if ($Percent -ge 0) {
        $p = [Math]::Min(100, [Math]::Max(0, $Percent))
        $b = $script:SplashBar
        # Der Standard-Progressbar ANIMIERT das Hochzaehlen (die Fuellung kriecht dem
        # Zielwert langsam hinterher) - dadurch wirkte es "haengt bei 40, dann zack 100".
        # Trick: kurz auf p+1 (bzw. p) und dann exakt auf p; das VERRINGERN laeuft ohne
        # Animation und snappt die Anzeige sofort auf den echten Wert.
        if ($p -lt 100) { $b.Value = $p + 1 } else { $b.Value = $p }
        $b.Value = $p
    }
    $script:Splash.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-Splash {
    if ($script:Splash -and -not $script:Splash.IsDisposed) {
        $script:Splash.Close(); $script:Splash.Dispose()
    }
    $script:Splash = $null
}

$null = Show-SplashScreen

# Basisverzeichnis robust bestimmen - MUSS sowohl als .ps1 (dann $PSScriptRoot) als
# auch als PS2EXE-.exe funktionieren. In einer PS2EXE-Exe ist $PSScriptRoot je nach
# Version LEER; dann liefert der Prozesspfad (die .exe selbst) das richtige Verzeichnis.
# Ohne das schlägt der Modul-Import still fehl und man sieht nur eine Kaskade von
# "... ist nicht erkannt"-Fehlern (u.a. Import-VscWizardConfig).
$script:BaseDir = $PSScriptRoot
if (-not $script:BaseDir -and $MyInvocation.MyCommand.Path) {
    $script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:BaseDir) {
    try { $script:BaseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
}
if (-not $script:BaseDir) { $script:BaseDir = (Get-Location).Path }

Update-Splash -Text 'Kernmodul laden...' -Percent 25
$script:ModulePath = Join-Path $script:BaseDir 'modules\VscWizard.Core.psm1'
if (-not (Test-Path $script:ModulePath)) {
    Close-Splash
    [System.Windows.Forms.MessageBox]::Show(
        "Das Kernmodul wurde nicht gefunden:`r`n$script:ModulePath`r`n`r`nDie Datei/EXE braucht den Ordner 'modules\' UND 'config.psd1' DIREKT DANEBEN.`r`n`r`nSo startest du richtig:`r`n - Aus dem geklonten Repo: VscWizard.bat doppelklicken (nicht eine einzelne .exe kopieren).`r`n - Als EXE: '.\build.ps1' ausführen und die EXE aus 'dist\' zusammen mit dem dort erzeugten Ordner 'modules\' und 'config.psd1' verwenden.",
        'VSC-Wizard - Start fehlgeschlagen', 'OK', 'Error') | Out-Null
    exit 1
}
try {
    Import-Module $script:ModulePath -Force -ErrorAction Stop
} catch {
    Close-Splash
    [System.Windows.Forms.MessageBox]::Show(
        "Das Kernmodul konnte nicht geladen werden:`r`n$($_.Exception.Message)`r`n`r`nPfad: $script:ModulePath",
        'VSC-Wizard - Start fehlgeschlagen', 'OK', 'Error') | Out-Null
    exit 1
}

Update-Splash -Text 'Konfiguration lesen...' -Percent 40
$script:ConfigPath = Join-Path $script:BaseDir 'config.psd1'
# Fehlt config.psd1 (z.B. nur die EXE ohne Beiwerk kopiert), NICHT abstürzen: mit
# leerer Konfiguration starten - der Wizard öffnet dann den Einstellungen-Tab.
try {
    $config = Import-VscWizardConfig -Path $script:ConfigPath
} catch {
    $config = @{}
}
Update-Splash -Text 'Oberfläche wird aufgebaut...' -Percent 55

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

function Get-ConfiguredPinMinLength {
    # PIN-Mindestlänge aus der Konfiguration (Default 6), auf einen sinnvollen
    # Bereich geklemmt. Gilt für COM- (Manager2-PIN-Policy) und tpmvscmgr-Weg.
    $min = 6
    if ($config.PinMinLength) { $min = [int]$config.PinMinLength }
    if ($min -lt 4) { $min = 4 }
    if ($min -gt 20) { $min = 20 }
    return $min
}

# $script:TargetAccount ist $null (= aktuell angemeldeter Benutzer) oder ein auf dem
# Landing-Screen eingegebenes Zielkonto. VSC- und CSR-Erstellung laufen unabhängig
# davon immer im aktuellen Benutzerkontext (die Smartcard-PIN ist kontounabhängig
# und certreq verwaltet offene Anträge im Profil des aufrufenden Benutzers) - nur
# die Einreichung bei der CA muss aus Berechtigungsgründen als Zielkonto erfolgen.
function Get-EnrollmentIdentity {
    if ($script:TargetAccount) {
        $upn = if ($script:TargetAccount -match '@') { $script:TargetAccount } else { $null }
        $cn = if ($script:TargetAccount -match '\\') { ($script:TargetAccount -split '\\')[-1] } else { $script:TargetAccount }
        return [pscustomobject]@{ Subject = "CN=$cn"; Upn = $upn; DisplayName = $script:TargetAccount; SearchTerm = $cn }
    }
    return [pscustomobject]@{ Subject = "CN=$env:USERNAME"; Upn = (Get-CurrentUpn); DisplayName = "$env:USERDOMAIN\$env:USERNAME"; SearchTerm = $env:USERNAME }
}

function Invoke-EnrollmentAgentRequest {
    # Beantragt ein Enrollment-Agent-Zertifikat für das EIGENE Konto - eine ganz
    # normale Direkt-Beantragung (kein separates Konto, kein RDP). Wahlweise mit dem
    # Schlüssel auf einer eigenen VSC (TPM/PIN, empfohlen) oder als CNG-Software-
    # Schlüssel. Das Template bestimmt die EKU (Certificate Request Agent).
    param(
        [Parameter(Mandatory)][string]$Template,
        [switch]$OnVsc
    )

    $identity = [pscustomobject]@{ Subject = "CN=$env:USERNAME"; Upn = (Get-CurrentUpn) }
    $enrollDir = Join-Path (Get-WizardWorkingDir) "EA-$([guid]::NewGuid().ToString('N'))"

    if ($OnVsc) {
        $cardName = "$($config.VscNamePrefix)EA-$env:USERNAME"
        Write-WizardLog -Message "Erstelle VSC für EA-Zertifikat ('$cardName')." -Level Command
        $vsc = New-VirtualSmartCard -CardName $cardName -PinPolicyMinLength (Get-ConfiguredPinMinLength)
        if (-not $vsc.Success) {
            return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $null; Message = 'VSC-Erstellung für EA-Zertifikat fehlgeschlagen.' }
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
    return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $submit.RequestId; Message = 'Übernahme des EA-Zertifikats fehlgeschlagen.' }
}

# Einfache Hint/Placeholder-Eingabe: zeigt grauen Beispieltext, solange kein echter
# Wert eingetragen ist; verschwindet beim Fokussieren, kehrt beim Verlassen eines
# leeren Feldes zurück. Erkennung "ist gerade Placeholder" über ForeColor=Gray.
# Funktioniert für TextBox und ComboBox gleichermassen (beide haben Text/ForeColor
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
    # in Plan A/Plan B zeigen es lediglich vorausgewählt an.
    param(
        [Parameter(Mandatory)][System.Windows.Forms.ComboBox]$ComboBox,
        [string]$Template
    )
    $ComboBox.Items.Clear()
    if ($Template) { [void]$ComboBox.Items.Add($Template) }
    if ($ComboBox.Items.Count -gt 0) { $ComboBox.SelectedIndex = 0 }
}

function Set-PlanATemplateForMode {
    # Bereitet die Template-Auswahl in Plan A auf den aktuellen Modus vor.
    #  - Normal/EOBO/Verlängern: fest vorausgewähltes Standard-Template ($config.Template).
    #  - Offline-Direkt (Szenario 03, Cloud/Entra CBA): das OFFLINE-/Supply-in-request-Template. Ist in der
    #    Konfiguration keins hinterlegt, wird die Combo editierbar, damit der Name getippt
    #    werden kann (das Standard-Template waere hier das falsche - Build-from-AD).
    if ($script:PlanA_OfflineDirect) {
        $cboTemplateA.DropDownStyle = 'DropDown'   # editierbar
        $cboTemplateA.Items.Clear()
        if ($config.OfflineTemplate) {
            [void]$cboTemplateA.Items.Add($config.OfflineTemplate)
            $cboTemplateA.SelectedIndex = 0
        } else {
            $cboTemplateA.Text = ''
        }
    } else {
        $cboTemplateA.DropDownStyle = 'DropDownList'
        Set-TemplateComboItem -ComboBox $cboTemplateA -Template $config.Template
    }
}

#region MAIN FORM

$form = New-Object System.Windows.Forms.Form
$form.Text = 'VSC-Wizard - Virtuelle Smartcard beantragen - https://blog.zarenko.net'
$form.Size = New-Object System.Drawing.Size(1000, 900)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(900, 780)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = 'Fill'
$mainLayout.RowCount = 3
$mainLayout.ColumnCount = 1
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 76)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 24)))
$form.Controls.Add($mainLayout)

# --- Busy-/Warte-Anzeige -----------------------------------------------------------
# Viele Aktionen (VSCs auslesen, Umgebung erkennen, certreq/certutil) laufen SYNCHRON
# im UI-Thread und blockieren die Oberflaeche. Ohne Rueckmeldung wirkt das eingefroren.
# Zwei Signale: (1) der OS-Wartecursor via Application.UseWaitCursor - die drehende
# Scheibe wird vom BETRIEBSSYSTEM animiert, auch wenn unser Thread blockiert; (2) ein
# sichtbares gelbes Banner mit Klartext, was gerade laeuft.
$script:BusyLabel = New-Object System.Windows.Forms.Label
$script:BusyLabel.AutoSize = $false
$script:BusyLabel.TextAlign = 'MiddleCenter'
$script:BusyLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$script:BusyLabel.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 196)
$script:BusyLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 70, 0)
$script:BusyLabel.BorderStyle = 'FixedSingle'
$script:BusyLabel.Size = New-Object System.Drawing.Size(560, 40)
$script:BusyLabel.Visible = $false
$form.Controls.Add($script:BusyLabel)

function Set-Busy {
    param([string]$Text)
    [System.Windows.Forms.Application]::UseWaitCursor = $true
    if ($script:BusyLabel -and $form) {
        $script:BusyLabel.Text = "$([char]0x231B)  $Text"   # Sanduhr-Symbol + Text
        $x = [int](($form.ClientSize.Width - $script:BusyLabel.Width) / 2)
        if ($x -lt 0) { $x = 0 }
        $script:BusyLabel.Location = New-Object System.Drawing.Point($x, 52)
        $script:BusyLabel.Visible = $true
        $script:BusyLabel.BringToFront()
    }
    try { $form.Refresh() } catch { }
    [System.Windows.Forms.Application]::DoEvents()
}

function Clear-Busy {
    [System.Windows.Forms.Application]::UseWaitCursor = $false
    if ($script:BusyLabel) { $script:BusyLabel.Visible = $false }
    try { $form.Refresh() } catch { }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Busy {
    # Fuehrt $Action aus, waehrend Wartecursor + Banner sichtbar sind; raeumt IMMER auf.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][scriptblock]$Action)
    Set-Busy -Text $Text
    try { & $Action } finally { Clear-Busy }
}

function Get-AppVersion {
    # Die Version REIST MIT DEM REPO: sie wird aus der GIT-Historie abgeleitet
    # (Anzahl Commits = hochzaehlende Build-Nummer). KEIN lokaler Hook noetig - das
    # funktioniert in jedem Checkout und auf jedem Rechner gleich (auch in der
    # Windows-Claude-Session). Reihenfolge:
    #   1) live aus git, wenn das Skript in einem Checkout laeuft (Dev via VscWizard.ps1)
    #   2) version.txt neben Skript/EXE (von build.ps1 aus git erzeugt - fuer die EXE)
    #   3) Fallback
    $ver = $null; $date = $null; $commit = $null
    try {
        if (Test-Path (Join-Path $script:BaseDir '.git')) {
            $count = (& git -C "$script:BaseDir" rev-list --count HEAD 2>$null | Select-Object -First 1)
            if ($count) {
                $ver    = "1.0.$($count.ToString().Trim())"
                $date   = (& git -C "$script:BaseDir" log -1 --format=%cd --date=short 2>$null | Select-Object -First 1)
                $commit = (& git -C "$script:BaseDir" rev-parse --short HEAD 2>$null | Select-Object -First 1)
            }
        }
    } catch { }
    if (-not $ver) {
        $vfile = Join-Path $script:BaseDir 'version.txt'
        if (Test-Path $vfile) {
            try {
                foreach ($line in (Get-Content $vfile -ErrorAction Stop)) {
                    if     ($line -match '^\s*Version\s*=\s*(.+?)\s*$') { $ver = $Matches[1] }
                    elseif ($line -match '^\s*Date\s*=\s*(.+?)\s*$')    { $date = $Matches[1] }
                    elseif ($line -match '^\s*Commit\s*=\s*(.+?)\s*$')  { $commit = $Matches[1] }
                }
            } catch { }
        }
    }
    if (-not $ver)  { $ver = '1.0.0-dev' }
    if (-not $date) { $date = 'unbekannt' }
    return [pscustomobject]@{ Version = "$ver"; Date = "$date"; Commit = "$commit" }
}

function Show-AboutDialog {
    $v = Get-AppVersion
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Über VSC-Wizard'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(430, 214)

    $lblApp = New-Object System.Windows.Forms.Label
    $lblApp.Text = 'VSC-Wizard'
    $lblApp.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblApp.Location = New-Object System.Drawing.Point(20, 18); $lblApp.Size = New-Object System.Drawing.Size(390, 30)
    $dlg.Controls.Add($lblApp)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = 'Virtuelle Smartcards & Zertifikate für AD-Administratoren'
    $lblSub.ForeColor = [System.Drawing.Color]::DimGray
    $lblSub.Location = New-Object System.Drawing.Point(22, 50); $lblSub.Size = New-Object System.Drawing.Size(390, 20)
    $dlg.Controls.Add($lblSub)

    $lblVer = New-Object System.Windows.Forms.Label
    $verText = "Version $($v.Version)"
    if ($v.Commit) { $verText += "  ($($v.Commit))" }
    $lblVer.Text = $verText
    $lblVer.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblVer.Location = New-Object System.Drawing.Point(22, 86); $lblVer.Size = New-Object System.Drawing.Size(390, 20)
    $dlg.Controls.Add($lblVer)

    $lblDate = New-Object System.Windows.Forms.Label
    $lblDate.Text = "Release-Datum: $($v.Date)"
    $lblDate.Location = New-Object System.Drawing.Point(22, 108); $lblDate.Size = New-Object System.Drawing.Size(390, 20)
    $dlg.Controls.Add($lblDate)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = 'https://blog.zarenko.net'
    $link.Location = New-Object System.Drawing.Point(22, 138); $link.Size = New-Object System.Drawing.Size(390, 20)
    $link.Add_LinkClicked({ try { Start-Process 'https://blog.zarenko.net' } catch { } })
    $dlg.Controls.Add($link)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Schließen'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(316, 172); $ok.Size = New-Object System.Drawing.Size(94, 28)
    $dlg.Controls.Add($ok)
    $dlg.AcceptButton = $ok

    [void]$dlg.ShowDialog($form)
}

#endregion

#region TOP BAR (schrittunabhängig - auf jedem Schritt sichtbar, u.a. für Einstellungen)

$topBar = New-Object System.Windows.Forms.TableLayoutPanel
$topBar.Dock = 'Fill'
$topBar.ColumnCount = 3
$topBar.BackColor = [System.Drawing.SystemColors]::ControlLight
[void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 80)))
[void]$topBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 160)))
$mainLayout.Controls.Add($topBar, 0, 0)

$lblGlobalStep = New-Object System.Windows.Forms.Label
$lblGlobalStep.Dock = 'Fill'
$lblGlobalStep.TextAlign = 'MiddleLeft'
$lblGlobalStep.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblGlobalStep.Margin = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$topBar.Controls.Add($lblGlobalStep, 0, 0)

$btnAbout = New-Object System.Windows.Forms.Button
$btnAbout.Text = 'Über'
$btnAbout.Dock = 'Fill'
$btnAbout.Margin = New-Object System.Windows.Forms.Padding(6, 6, 0, 6)
$topBar.Controls.Add($btnAbout, 1, 0)
$btnAbout.Add_Click({ Show-AboutDialog })

$btnOpenSettings = New-Object System.Windows.Forms.Button
$btnOpenSettings.Text = 'Einstellungen'
$btnOpenSettings.Dock = 'Fill'
$btnOpenSettings.Margin = New-Object System.Windows.Forms.Padding(6, 6, 10, 6)
$topBar.Controls.Add($btnOpenSettings, 2, 0)
$btnOpenSettings.Add_Click({ Show-SettingsDialog -Owner $form })

#endregion

#region STEP HOST (Inhaltsbereich + gemeinsame Weiter/Zurück-Navigation)

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
$btnBackShared.Text = '< Zurück'
$btnBackShared.Dock = 'Fill'
$navShared.Controls.Add($btnBackShared, 1, 0)

$btnNextShared = New-Object System.Windows.Forms.Button
$btnNextShared.Text = 'Weiter >'
$btnNextShared.Dock = 'Fill'
$navShared.Controls.Add($btnNextShared, 2, 0)

# $script:ActivePlan: $null = Schritt 1 (Moduswahl) ist aktiv, 'A'/'B' = der jeweilige
# Schritt-Satz ist aktiv. Weiter/Zurück werten dies aus, um an die richtige Stelle zu
# delegieren (siehe Invoke-SharedNext/Back weiter unten, definiert nach Plan A/B).
$script:ActivePlan = $null
# Woher der Plan-A/B-Ablauf betreten wurde - steuert, wohin "Zurück" aus dessen
# Schritt 0 fuehrt: 'Scenario' (direkt aus einem Szenario) oder 'Mode' (klassische Moduswahl).
$script:PlanEntryFrom = 'Scenario'
# "Bestehende VSC verwenden": Re-Enroll auf eine BESTEHENDE Karte - der Plan-A-
# "Anfordern"- bzw. Plan-B-"CSR"-Schritt wird wiederverwendet, das Erstellen uebersprungen.
$script:PlanA_RenewMode = $false
$script:PlanB_RenewMode = $false
# Szenario 03 (Cloud-Konto / Entra CBA): Direkt-Ausstellung über ein Offline-/Supply-in-
# request-Template (als DU einreichen, Ziel-UPN im CSR, kein EA/RDP). NUR Cloud/CBA.
$script:PlanA_OfflineDirect = $false

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

$lblLandingTitle = New-WizardLabel -Text 'Für wen soll die virtuelle Smartcard beantragt werden?' -X 20 -Y 20 -Width 780 -Style Bold

# "Für wen" und "Welcher Ablauf" muessen in GETRENNTEN Containern liegen - sonst
# bilden alle vier RadioButtons (als Kinder desselben Panels) EINE gemeinsame,
# faelschlich geteilte Auswahlgruppe. Je ein Panel => zwei unabhängige Gruppen.
$pnlAccountRadios = New-Object System.Windows.Forms.Panel
$pnlAccountRadios.Location = New-Object System.Drawing.Point(16, 52)
$pnlAccountRadios.Size = New-Object System.Drawing.Size(772, 60)

$radSelf = New-Object System.Windows.Forms.RadioButton
$radSelf.Text = "Für mich (aktuell angemeldet als $env:USERDOMAIN\$env:USERNAME)"
$radSelf.Location = New-Object System.Drawing.Point(4, 2)
$radSelf.Size = New-Object System.Drawing.Size(744, 24)
$radSelf.Checked = $true

$radOther = New-Object System.Windows.Forms.RadioButton
$radOther.Text = 'Für ein separates Konto (z.B. Admin-Konto)'
$radOther.Location = New-Object System.Drawing.Point(4, 30)
$radOther.Size = New-Object System.Drawing.Size(744, 24)
$pnlAccountRadios.Controls.AddRange(@($radSelf, $radOther))

$lblOtherAccount = New-WizardLabel -Text 'Zielkonto (z.B. CONTOSO\adm.mustermann oder UPN):' -X 40 -Y 122 -Width 500
$txtOtherAccount = New-Object System.Windows.Forms.TextBox
$txtOtherAccount.Location = New-Object System.Drawing.Point(40, 148)
$txtOtherAccount.Size = New-Object System.Drawing.Size(400, 24)
$txtOtherAccount.Enabled = $false

$lblOtherExplain = New-WizardLabel -Text 'Karten- und CSR-Erstellung laufen ganz normal in deinem eigenen Benutzerkontext - dafür ist keine gesonderte Anmeldung als Zielkonto nötig (die Smartcard-PIN ist unabhängig vom Windows-Konto). Nur die spätere Einreichung bei der CA muss aus Berechtigungsgründen als Zielkonto erfolgen; Plan B führt dich an der passenden Stelle dorthin (z.B. per RDP), die Übernahme des fertigen Zertifikats erfolgt danach wieder hier.' -X 40 -Y 178 -Width 760 -Height 60

$lblPlanChoiceTitle = New-WizardLabel -Text 'Welcher Ablauf?' -X 20 -Y 250 -Width 780 -Style Bold

$pnlPlanRadios = New-Object System.Windows.Forms.Panel
$pnlPlanRadios.Location = New-Object System.Drawing.Point(16, 280)
$pnlPlanRadios.Size = New-Object System.Drawing.Size(772, 54)

$radPlanA = New-Object System.Windows.Forms.RadioButton
$radPlanA.Text = 'Plan A: AD-Domäne (direkte CA-Sicht, automatisiert)'
$radPlanA.Location = New-Object System.Drawing.Point(4, 0)
$radPlanA.Size = New-Object System.Drawing.Size(760, 24)

$radPlanB = New-Object System.Windows.Forms.RadioButton
$radPlanB.Text = 'Plan B: Entra / Workgroup (CSR lokal, Einreichung per RDP-Zwischenschritt)'
$radPlanB.Location = New-Object System.Drawing.Point(4, 26)
$radPlanB.Size = New-Object System.Drawing.Size(760, 24)
$pnlPlanRadios.Controls.AddRange(@($radPlanA, $radPlanB))

$lblPlanChoiceHint = New-WizardLabel -Text '' -X 40 -Y 340 -Width 740
$lblPlanChoiceHint.ForeColor = [System.Drawing.Color]::DimGray

# Fähigkeitsbasierte Prüfung: misst, ob von HIER direkt eingereicht werden kann
# (Kerberos-TGT + DNS + certutil-ping), statt aus dem Join-Status zu raten. Ergebnis
# überschreibt die Heuristik-Vorauswahl mit der gemessenen Wahrheit.
$btnCheckDirect = New-Object System.Windows.Forms.Button
$btnCheckDirect.Text = 'Direkt-Einreichung prüfen'
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

$pnlModeSelect.Controls.AddRange(@($lblLandingTitle, $pnlAccountRadios, $lblOtherAccount, $txtOtherAccount, $lblOtherExplain, $lblPlanChoiceTitle, $pnlPlanRadios, $lblPlanChoiceHint, $btnCheckDirect, $txtDirectResult, $lblLandingValidation))

function Update-ModeSelectPlanChoice {
    # Der Domain-Join-Status ist nur eine HEURISTIK-Vorauswahl (sofort, ohne Netz),
    # kein belastbares Kriterium: ein DJ-Client kann off-net scheitern, ein EJ-Client
    # mit Cloud Kerberos Trust + korrektem DNS direkt einreichen. Die gemessene Wahrheit
    # liefert "Direkt-Einreichung prüfen" (Test-DirectEnrollmentCapability), das diese
    # Vorauswahl anschließend überschreibt. Vom Nutzer jederzeit überschreibbar.
    $joinState = Get-DomainJoinState
    if ($radOther.Checked) {
        # Separates Konto: Plan A ist möglich, WENN ein Enrollment-Agent-Zertifikat
        # vorliegt (Enroll on Behalf Of - bruchfrei, ohne RDP). Sonst bleibt nur
        # Plan B, da die Einreichung als Zielkonto erfolgen muss.
        $eaCount = @(Get-EnrollmentAgentCertificates).Count
        if ($eaCount -gt 0) {
            $radPlanA.Enabled = $true
            $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = "EA-Zertifikat gefunden: Plan A möglich (EOBO, ohne RDP). Beachte: EA-Cert ist admin-äquivalent (ESC3) - für Admin-Konten ist Plan B (Self-Enrollment) oft sicherer. Plan B bleibt als Alternative."
        } else {
            $radPlanA.Enabled = $false
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = 'Kein EA-Zertifikat gefunden - für ein separates Konto daher Plan B (RDP). Mit einem EA-Zertifikat (in den Einstellungen beantragbar) ginge auch Plan A ohne RDP.'
        }
    } else {
        $radPlanA.Enabled = $true
        if ($joinState.Mode -eq 'ADDomain') {
            $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = "Vorschlag (Heuristik: Domänen-Status $($joinState.Mode)): Plan A. Für Gewissheit 'Direkt-Einreichung prüfen'."
        } else {
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = "Vorschlag (Heuristik: Domänen-Status $($joinState.Mode)): Plan B. Bei funktionierendem Cloud Kerberos Trust ist evtl. doch Plan A möglich - 'Direkt-Einreichung prüfen' misst es."
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
    $txtDirectResult.Text = 'Prüfe Direkt-Einreichung (Kerberos-Ticket, DNS, certutil -ping - bis zu ca. 45 Sekunden)...'
    $form.Refresh()

    # In einem Start-Job, da DNS/RPC/certutil bei nicht erreichbaren Zielen hängen können.
    $modulePath = $script:ModulePath
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
        $txtDirectResult.Text = 'Zeitüberschreitung (>45s) - CA/DC vermutlich nicht erreichbar (Netz/DNS/VPN prüfen). Vorerst Plan B verwenden.'
        Write-WizardLog -Message 'Direkt-Einreichungsprüfung: Zeitüberschreitung.' -Level Error
        $btnCheckDirect.Enabled = $true
        return
    }

    $txtDirectResult.ForeColor = if ($cap.DirectPossible) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DarkOrange }
    $txtDirectResult.Text = "$($cap.Reason)`r`n`r`n$($cap.Detail)"
    Write-WizardLog -Message "Direkt-Einreichung: DirectPossible=$($cap.DirectPossible), Join=$($cap.JoinMode), TGT=$($cap.HasKerberosTgt), Ping=$($cap.CaPingOk)." -Level Info

    # Gemessenes Ergebnis überschreibt die Heuristik-Vorauswahl.
    if ($radSelf.Checked) {
        if ($cap.DirectPossible) {
            $radPlanA.Enabled = $true; $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = 'Gemessen: Direkt-Einreichung möglich - Plan A.'
        } else {
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = 'Gemessen: Direkt-Einreichung derzeit nicht möglich - Plan B (CA-Schritt delegieren). Grund siehe oben.'
        }
    } else {
        # Separates Konto: Plan-A-Verfügbarkeit hängt zusätzlich am EA-Zertifikat
        # (Update-ModeSelectPlanChoice); der Check zeigt hier die CA-Erreichbarkeit, die
        # auch für EOBO nötig ist.
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
    if ($pnlScenario) { $pnlScenario.Visible = $false }
    $pnlModeSelect.Visible = $true
    Update-ModeSelectPlanChoice
    $lblGlobalStep.Text = 'Schritt 2: Konto & Weg'
    # Zurück führt jetzt auf die Szenario-Auswahl (Schritt 1).
    $btnBackShared.Enabled = $true
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
    $script:PlanEntryFrom = 'Mode'
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

# ============================================================================
#region SCHRITT 1: SZENARIO-AUSWAHL (neue Startseite, routet in die bestehenden Abläufe)
# ============================================================================

# Farbpalette (klassisch, passend zum WinForms-Look aus dem Design-Mockup).
$scnStripe = @{
    blue  = [System.Drawing.Color]::FromArgb(47, 111, 176)
    green = [System.Drawing.Color]::FromArgb(46, 125, 82)
    teal  = [System.Drawing.Color]::FromArgb(42, 128, 145)
    red   = [System.Drawing.Color]::FromArgb(181, 52, 42)
}
$scnSelColor  = [System.Drawing.Color]::FromArgb(229, 241, 251)
$scnTagTool   = [System.Drawing.Color]::FromArgb(46, 125, 82)
$scnTagYou    = [System.Drawing.Color]::FromArgb(176, 110, 20)
$scnTagGate   = [System.Drawing.Color]::FromArgb(42, 128, 145)
$scnTagDanger = [System.Drawing.Color]::FromArgb(181, 52, 42)

# Szenario-Definitionen (Reihenfolge wie im Runbook). Steps: T = Tag, X = Text.
$script:Scenarios = @(
    [pscustomobject]@{
        Id = 1; Title = 'VSC für onprem-Adminkonto'; Sub = 'GEFÜHRT   Separates On-Prem-Admin-Konto (nicht dein angemeldetes): EOBO (mit EA-Zertifikat) oder Bootstrap/RDP.'; Stripe = 'blue'
        Steps = @(
            [pscustomobject]@{ T = 'Du';       X = 'Separates Admin-Konto angeben (nicht dein angemeldetes).' }
            [pscustomobject]@{ T = 'Du';       X = 'Neue VSC erstellen ODER eine bestehende verwenden.' }
            [pscustomobject]@{ T = 'Prüfung'; X = 'Mit EA-Zertifikat: EOBO (ohne RDP). Sonst: Plan B - Einreichung ALS das Zielkonto per RDP (ggf. einmalig Passwort-Anmeldung erlauben).' }
            [pscustomobject]@{ T = 'Tool';     X = 'CSR erzeugen, einreichen, Zertifikat auf die VSC übernehmen.' }
        )
        Guard = [pscustomobject]@{ Kind = 'warn'; Text = 'Bootstrap-Passwort (falls nötig) ist einmalig; danach Konto wieder auf "Smartcard erforderlich". VSC dort erstellen, wo sie genutzt wird.' }
    }
    [pscustomobject]@{
        Id = 2; Title = 'VSC für onprem- oder hybrid-Konto'; Sub = 'AUTOMATISIERT   Dein eigenes (on-prem oder hybrid synchronisiertes) Konto - Direkt-Ausstellung, wenn die CA erreichbar ist.'; Stripe = 'green'
        Steps = @(
            [pscustomobject]@{ T = 'Du';       X = 'Neue VSC erstellen ODER eine bestehende verwenden.' }
            [pscustomobject]@{ T = 'Prüfung'; X = 'Direkt-Einreichung prüfen (Kerberos, DNS, certutil -ping).' }
            [pscustomobject]@{ T = 'Tool';     X = 'CSR -> direkt einreichen (als du) -> Zertifikat auf die VSC übernehmen.' }
        )
        Guard = $null
    }
    [pscustomobject]@{
        Id = 3; Title = 'VSC für Cloudonly-Adminkonto'; Sub = 'NUR CLOUD   Cloud-only-Konto (Entra CBA): als DU einreichen, Ziel-UPN im CSR (Offline-Template). NICHT für On-Prem-Logon.'; Stripe = 'blue'
        Steps = @(
            [pscustomobject]@{ T = 'Du';       X = 'Cloud-Zielkonto/UPN angeben (Entra, z.B. gadmin@contoso.onmicrosoft.com).' }
            [pscustomobject]@{ T = 'Du';       X = 'Neue VSC erstellen ODER eine bestehende verwenden.' }
            [pscustomobject]@{ T = 'Tool';     X = 'CSR mit Ziel-UPN im SAN erzeugen (Supply-in-request/Offline-Template).' }
            [pscustomobject]@{ T = 'Prüfung'; X = 'Als DU direkt bei der CA einreichen (Enroll-Recht auf dem Offline-Template).' }
            [pscustomobject]@{ T = 'Tool';     X = 'Ausgestelltes Zertifikat auf die VSC übernehmen.' }
            [pscustomobject]@{ T = 'Du';       X = 'In Entra: ausstellende CA importieren + CBA-Binding auf UPN, CRL öffentlich erreichbar (RUNBOOK).' }
            [pscustomobject]@{ T = 'Du';       X = 'Alternative ganz ohne PKI: FIDO2/Passkey (Sicherheitsschlüssel oder Passkey).' }
        )
        Guard = [pscustomobject]@{ Kind = 'danger'; Text = 'NUR Entra CBA/Cloud - NICHT für On-Prem-Smartcard-Logon! Das Offline-Template bettet keine Konto-SID ein (starke Zuordnung, KB5014754) -> der KDC lehnt den On-Prem-Logon ab. Für On-Prem-Konten: onprem-Adminkonto (Szenario 01) bzw. EOBO (Szenario 05). Zusaetzlich ESC1: SAN frei praegbar -> Template zusperren (enge Enroll-ACL, ggf. Manager-Approval).' }
    }
    [pscustomobject]@{
        Id = 4; Title = 'VSCs verwalten'; Sub = 'WERKZEUG   Vorhandene Karten und Zertifikate ansehen und löschen.'; Stripe = 'teal'
        Steps = @(
            [pscustomobject]@{ T = 'Tool'; X = 'Inventar: Reader, Karten, Zertifikate mit Ablaufdatum.' }
            [pscustomobject]@{ T = 'Du';   X = 'Auswählen und löschen (tpmvscmgr destroy).' }
        )
        Guard = $null
    }
    [pscustomobject]@{
        Id = 5; Title = 'Für ein anderes Konto ausstellen (EOBO)'; Sub = 'FORTGESCHRITTEN   Enroll on Behalf Of mit Enrollment-Agent-Zertifikat.'; Stripe = 'red'
        Steps = @(
            [pscustomobject]@{ T = 'Tool'; X = 'EA-Zertifikat erkennen; EOBO-Antrag (RequesterName=Ziel, Build-from-AD).' }
            [pscustomobject]@{ T = 'Tool'; X = 'Antrag co-signieren, einreichen, auf VSC übernehmen.' }
        )
        Guard = [pscustomobject]@{ Kind = 'danger'; Text = 'ESC3 - EA-Cert admin-äquivalent. Für Admin-Ziele ist Self-Enrollment (Szenario 01/02) sicherer.' }
    }
)
$script:SelectedScenario = $null
$script:EnvCaps = $null
$script:ScnAvailable = @{}   # Id -> [bool] ob HIER moeglich
$script:ScnReason    = @{}   # Id -> Klartext, warum nicht

$pnlScenario = New-Object System.Windows.Forms.Panel
$pnlScenario.Dock = 'Fill'
$pnlScenario.Visible = $false
$pnlContentArea.Controls.Add($pnlScenario)

$scnRoot = New-Object System.Windows.Forms.TableLayoutPanel
$scnRoot.Dock = 'Fill'; $scnRoot.ColumnCount = 1; $scnRoot.RowCount = 2
[void]$scnRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 100)))
[void]$scnRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$pnlScenario.Controls.Add($scnRoot)

$scnHeader = New-Object System.Windows.Forms.Panel
$scnHeader.Dock = 'Fill'
$scnRoot.Controls.Add($scnHeader, 0, 0)
$lblScnTitle = New-WizardLabel -Text 'Was möchtest du tun?' -X 16 -Y 12 -Width 760 -Style Bold
$lblScnTitle.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$lblScnTitle.Height = 26
$lblScnSub = New-WizardLabel -Text 'Szenario wählen - der Wizard richtet Karte, Antrag und Einreichungsweg passend ein.' -X 16 -Y 42 -Width 760
$lblScnSub.ForeColor = [System.Drawing.Color]::DimGray
$lblScnValidation = New-WizardLabel -Text '' -X 16 -Y 42 -Width 760
$lblScnValidation.ForeColor = [System.Drawing.Color]::Firebrick
$lblScnValidation.Visible = $false
# Umgebungs-Banner: was der Wizard HIER erkannt hat (Join, TPM, On-Prem-TGT, VSCs, EA).
$lblScnEnv = New-WizardLabel -Text '' -X 16 -Y 68 -Width 900 -Height 22
$lblScnEnv.ForeColor = [System.Drawing.Color]::FromArgb(42, 128, 145)
$scnHeader.Controls.AddRange(@($lblScnTitle, $lblScnSub, $lblScnValidation, $lblScnEnv))

$scnSplit = New-Object System.Windows.Forms.TableLayoutPanel
$scnSplit.Dock = 'Fill'; $scnSplit.ColumnCount = 2; $scnSplit.RowCount = 1
[void]$scnSplit.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 56)))
[void]$scnSplit.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 44)))
$scnRoot.Controls.Add($scnSplit, 0, 1)

$scnList = New-Object System.Windows.Forms.FlowLayoutPanel
$scnList.Dock = 'Fill'; $scnList.FlowDirection = 'TopDown'; $scnList.WrapContents = $false; $scnList.AutoScroll = $true
$scnList.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
$scnSplit.Controls.Add($scnList, 0, 0)

$scnDetailsGroup = New-Object System.Windows.Forms.GroupBox
$scnDetailsGroup.Text = 'Ablauf'; $scnDetailsGroup.Dock = 'Fill'
$scnDetailsGroup.Margin = New-Object System.Windows.Forms.Padding(6, 6, 10, 10)
$scnSplit.Controls.Add($scnDetailsGroup, 1, 0)

$scnDetails = New-Object System.Windows.Forms.RichTextBox
$scnDetails.Dock = 'Fill'; $scnDetails.ReadOnly = $true; $scnDetails.BorderStyle = 'None'
$scnDetails.BackColor = [System.Drawing.SystemColors]::Window
$scnDetails.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$scnDetailsGroup.Controls.Add($scnDetails)

function Add-ScnColoredText {
    param($Rtb, [string]$Text, [System.Drawing.Color]$Color, [switch]$Bold)
    $Rtb.SelectionStart = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $Rtb.SelectionColor = $Color
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $Rtb.SelectionFont = New-Object System.Drawing.Font('Segoe UI', 9, $style)
    $Rtb.AppendText($Text)
}

function Set-ScenarioDetails {
    param($Scenario)
    $scnDetails.Clear()
    if (-not $Scenario) { return }
    $ink = [System.Drawing.SystemColors]::WindowText
    Add-ScnColoredText -Rtb $scnDetails -Text ("{0:D2}  {1}`r`n`r`n" -f $Scenario.Id, $Scenario.Title) -Color $ink -Bold
    foreach ($s in $Scenario.Steps) {
        $tagColor = switch ($s.T) { 'Tool' { $scnTagTool } 'Du' { $scnTagYou } 'Prüfung' { $scnTagGate } default { $ink } }
        Add-ScnColoredText -Rtb $scnDetails -Text ("[{0}] " -f $s.T) -Color $tagColor -Bold
        Add-ScnColoredText -Rtb $scnDetails -Text ("{0}`r`n" -f $s.X) -Color $ink
    }
    if ($Scenario.Guard) {
        $gColor = if ($Scenario.Guard.Kind -eq 'danger') { $scnTagDanger } else { $scnTagYou }
        Add-ScnColoredText -Rtb $scnDetails -Text "`r`n! " -Color $gColor -Bold
        Add-ScnColoredText -Rtb $scnDetails -Text $Scenario.Guard.Text -Color $gColor
    }
    $scnDetails.SelectionStart = 0
    $scnDetails.ScrollToCaret()
}

function Select-ScenarioById {
    param([int]$Id)
    $script:SelectedScenario = $Id
    foreach ($row in $scnList.Controls) {
        if ([int]$row.Tag -eq $Id) { $row.BackColor = $scnSelColor } else { $row.BackColor = [System.Drawing.SystemColors]::Window }
    }
    # Ausgegraute (unpassende) Kacheln wieder in Control-Grau statt Window-Weiss.
    Update-ScenarioRowColors
    Set-ScenarioDetails -Scenario ($script:Scenarios | Where-Object { $_.Id -eq $Id })

    $available = $true
    if ($script:ScnAvailable.ContainsKey($Id)) { $available = [bool]$script:ScnAvailable[$Id] }
    if ($available) {
        $lblScnValidation.Visible = $false
        $lblScnSub.Visible = $true
        $btnNextShared.Enabled = $true
    } else {
        $lblScnSub.Visible = $false
        $lblScnValidation.Text = "Hier nicht möglich: $($script:ScnReason[$Id])"
        $lblScnValidation.Visible = $true
        $btnNextShared.Enabled = $false   # Weiter blockiert, Begruendung steht oben
    }
}

function Update-ScenarioRowColors {
    # Nur die Hintergrundfarbe der NICHT ausgewaehlten Kacheln setzen: unpassende grau,
    # passende weiss. Die ausgewaehlte Kachel behaelt ihre Auswahlfarbe.
    foreach ($row in $scnList.Controls) {
        $id = [int]$row.Tag
        if ($id -eq $script:SelectedScenario) { continue }
        $ok = $true
        if ($script:ScnAvailable.ContainsKey($id)) { $ok = [bool]$script:ScnAvailable[$id] }
        $row.BackColor = if ($ok) { [System.Drawing.SystemColors]::Window } else { [System.Drawing.SystemColors]::Control }
    }
}

# Gemeinsamer Klick-Handler: liest die Szenario-Id aus .Tag des angeklickten Controls.
$scnRowClick = { param($s, $e) $id = $s.Tag; if ($null -ne $id) { Select-ScenarioById -Id ([int]$id) } }

foreach ($scn in $script:Scenarios) {
    $row = New-Object System.Windows.Forms.Panel
    $row.Height = 62; $row.Width = 380
    $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $row.BackColor = [System.Drawing.SystemColors]::Window
    $row.BorderStyle = 'FixedSingle'
    $row.Tag = $scn.Id
    $row.Cursor = [System.Windows.Forms.Cursors]::Hand

    $stripe = New-Object System.Windows.Forms.Panel
    $stripe.Dock = 'Left'; $stripe.Width = 5; $stripe.BackColor = $scnStripe[$scn.Stripe]
    $row.Controls.Add($stripe)

    $lblT = New-Object System.Windows.Forms.Label
    $lblT.Text = ("{0:D2}   {1}" -f $scn.Id, $scn.Title)
    $lblT.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lblT.Location = New-Object System.Drawing.Point(14, 8); $lblT.AutoSize = $true
    $lblT.Tag = $scn.Id
    $row.Controls.Add($lblT)

    $lblS = New-Object System.Windows.Forms.Label
    $lblS.Text = $scn.Sub
    $lblS.ForeColor = [System.Drawing.Color]::DimGray
    $lblS.Location = New-Object System.Drawing.Point(14, 32); $lblS.AutoSize = $true
    $lblS.Tag = $scn.Id
    $row.Controls.Add($lblS)

    $row.Add_Click($scnRowClick)
    $lblT.Add_Click($scnRowClick)
    $lblS.Add_Click($scnRowClick)
    $stripe.Add_Click($scnRowClick)

    [void]$scnList.Controls.Add($row)
}

# Zeilenbreite an die (variable) Listenbreite anpassen.
$scnResize = {
    $w = $scnList.ClientSize.Width - 24
    if ($w -lt 200) { $w = 200 }
    foreach ($row in $scnList.Controls) { $row.Width = $w }
}
$scnList.Add_SizeChanged($scnResize)

function Get-ScenarioAvailability {
    # Entscheidet KAPAZITAETSBASIERT (nicht per Join-Heuristik), ob ein Szenario HIER
    # ueberhaupt funktionieren kann. Nur SICHERE, lokal messbare Ausschluesse grauen aus -
    # im Zweifel bleibt ein Szenario aktiv (die Feinpruefung passiert dann im Ablauf).
    param($Caps, [int]$Id)
    switch ($Id) {
        2 {
            # onprem/hybrid-Konto (du selbst), Direkt-Einreichung: braucht eine
            # authentifizierbare On-Prem-AD-Identität - ein TGT (klist) ODER ein
            # AD-Domain-Join. Reiner Entra-ohne-CKT / Workgroup: nein.
            if (-not $Caps.HasOnPremTgt -and $Caps.JoinMode -ne 'ADDomain') {
                return [pscustomobject]@{ Available = $false; Reason = 'Kein On-Prem-Kerberos-Ticket (TGT) und kein AD-Domain-Join - ohne authentifizierbare AD-Identität kann von hier NICHT direkt bei der CA eingereicht werden. Auf einem Entra-joined Client setzt das funktionierendes Cloud Kerberos Trust voraus. Ohne das: von einem Rechner mit CA-Sicht bzw. Szenario 01 (per RDP).' }
            }
        }
        3 {
            # Cloud-Konto/Entra CBA: DU reichst direkt bei der On-Prem-CA ein - dafür
            # braucht DEIN Konto eine authentifizierbare On-Prem-AD-Identität (wie 02).
            # (Das ZIEL ist ein Cloud-Konto; der EINREICHER bist du und musst die CA
            # erreichen.)
            if (-not $Caps.HasOnPremTgt -and $Caps.JoinMode -ne 'ADDomain') {
                return [pscustomobject]@{ Available = $false; Reason = 'Kein On-Prem-Kerberos-Ticket (TGT) und kein AD-Domain-Join - du musst als du selbst bei der On-Prem-CA einreichen können. Entra-joined mit Cloud Kerberos Trust hat ein TGT. Ohne das: von einem Rechner mit CA-Sicht ausstellen.' }
            }
        }
        5 {
            if ($Caps.EaCertCount -lt 1) {
                return [pscustomobject]@{ Available = $false; Reason = 'Kein Enrollment-Agent-Zertifikat vorhanden - Enroll on Behalf Of ist ohne EA-Zertifikat nicht möglich (in den Einstellungen beantragbar). Für ein separates Konto sonst Szenario 01 (onprem-Adminkonto, per RDP als Zielkonto).' }
            }
        }
    }
    return [pscustomobject]@{ Available = $true; Reason = $null }
}

function Update-ScenarioAvailability {
    # Frische Umgebungs-Momentaufnahme holen, Banner setzen und die Kacheln entsprechend
    # aktivieren/ausgrauen. Wird bei jedem Anzeigen der Startseite aufgerufen, damit z.B.
    # eine neu erstellte VSC oder ein frisch geholtes TGT sofort beruecksichtigt wird.
    # Die Erkennung (dsregcmd/klist/PnP/Zertifikatsspeicher) dauert - Busy-Anzeige.
    Set-Busy -Text 'Umgebung erkennen (TPM, Kerberos, Karten)...'
    try { $caps = Get-EnvironmentCapabilities } finally { Clear-Busy }
    $script:EnvCaps = $caps

    foreach ($scn in $script:Scenarios) {
        $av = Get-ScenarioAvailability -Caps $caps -Id $scn.Id
        $script:ScnAvailable[$scn.Id] = $av.Available
        $script:ScnReason[$scn.Id]    = $av.Reason
    }

    foreach ($row in $scnList.Controls) {
        $id = [int]$row.Tag
        $ok = $true
        if ($script:ScnAvailable.ContainsKey($id)) { $ok = [bool]$script:ScnAvailable[$id] }
        foreach ($c in $row.Controls) {
            if ($c -is [System.Windows.Forms.Label]) {
                if ($ok) {
                    $c.ForeColor = if ($c.Font.Bold) { [System.Drawing.SystemColors]::WindowText } else { [System.Drawing.Color]::DimGray }
                } else {
                    $c.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
                }
            }
        }
        if (-not $ok -and $id -ne $script:SelectedScenario) { $row.BackColor = [System.Drawing.SystemColors]::Control }
        elseif ($id -ne $script:SelectedScenario) { $row.BackColor = [System.Drawing.SystemColors]::Window }
    }

    $tpmText = if ($caps.TpmPresent) { if ($caps.TpmReady) { 'TPM bereit' } else { 'TPM vorhanden (nicht bereit)' } } else { 'kein TPM' }
    $tgtText = if ($caps.HasOnPremTgt) { "On-Prem-TGT: ja$(if ($caps.Realm) { " ($($caps.Realm))" })" } else { 'On-Prem-TGT: nein' }
    $lblScnEnv.Text = "Hier erkannt:  $($caps.JoinMode)  ·  $tpmText  ·  $tgtText  ·  VSCs: $($caps.VscCount)  ·  EA-Zert: $($caps.EaCertCount)  (ausgegraute Punkte sind hier nicht möglich)"
}

function Show-ScenarioStep {
    $script:ActivePlan = 'SCEN'
    $script:PlanA_RenewMode = $false
    $script:PlanB_RenewMode = $false
    $script:PlanA_OfflineDirect = $false
    $tabPlanA.Visible = $false
    $tabPlanB.Visible = $false
    $pnlModeSelect.Visible = $false
    $pnlScenario.Visible = $true
    & $scnResize
    $lblGlobalStep.Text = 'Schritt 1: Szenario'
    $btnBackShared.Enabled = $false
    Update-ScenarioAvailability   # Umgebung neu erkennen + unpassende Punkte ausgrauen
    if ($script:SelectedScenario) {
        # War ein (jetzt evtl. nicht mehr passendes) Szenario gewaehlt: Auswahlzustand
        # inkl. Weiter-Button/Begruendung konsistent neu setzen.
        Select-ScenarioById -Id $script:SelectedScenario
    } else {
        $btnNextShared.Enabled = $true
    }
}

function Enter-Plan {
    # Direkt aus einem Szenario in den Plan-A/B-Ablauf springen - OHNE die Moduswahl
    # (für wen / welcher Ablauf), denn das Szenario hat diese Fragen bereits
    # beantwortet. $script:PlanEntryFrom='Scenario' sorgt dafuer, dass "Zurück" aus
    # Schritt 0 wieder zur Szenario-Auswahl fuehrt.
    param([ValidateSet('A', 'B')][string]$Plan)
    $script:PlanEntryFrom = 'Scenario'
    $pnlScenario.Visible = $false
    $pnlModeSelect.Visible = $false
    # NEUER Ablauf -> sauberer Zustand. Sonst bleibt z.B. $PlanA_VscCreated von einem
    # vorherigen Durchlauf (oder vom "bestehende VSC verwenden"-Weg) auf $true, und der
    # "Weiter"-Check im Erstellen-Schritt greift nicht (man käme ohne Karte weiter).
    # $PlanA_OfflineDirect wird bewusst NICHT angefasst - das setzt das Szenario davor.
    if ($Plan -eq 'A') {
        $script:ActivePlan = 'A'
        $script:PlanA_VscCreated = $false
        $script:PlanA_CertIssued = $false
        $script:PlanA_PendingRequestId = $null
        $script:PlanA_RenewMode = $false
        $txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"
        $lblVscResultA.Text = ''
        $lblCertResultA.Text = ''
        $btnRetrieveA.Visible = $false
        $tabPlanA.Visible = $true
        Set-PlanATemplateForMode
        Show-PlanAStep -Index 0
    } else {
        $script:ActivePlan = 'B'
        $script:PlanB_VscCreated = $false
        $script:PlanB_CertIssued = $false
        $script:PlanB_PendingRequestId = $null
        $script:PlanB_RenewMode = $false
        $txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"
        $lblVscResultB.Text = ''
        $lblSubmitResultB.Text = ''
        $lblCompleteResultB.Text = ''
        $btnRetrieveB.Visible = $false
        $tabPlanB.Visible = $true
        Show-PlanBStep -Index 0
    }
}

function Get-ScenarioPlanForSeparateAccount {
    # Separates Konto: mit Enrollment-Agent-Zertifikat bruchfrei per Plan A (EOBO),
    # sonst Plan B (Einreichung als Zielkonto, z.B. per RDP).
    if ((@(Get-EnrollmentAgentCertificates)).Count -gt 0) { 'A' } else { 'B' }
}

function Show-AccountInputDialog {
    # Schlanke Abfrage NUR des Zielkontos (statt der kompletten Moduswahl).
    param([string]$Prefill, [string]$Prompt)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Zielkonto'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(440, 120)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if ($Prompt) { $Prompt } else { 'Zielkonto (z.B. CONTOSO\adm.mustermann - DOMAIN\Konto bevorzugt):' }
    $lbl.Location = New-Object System.Drawing.Point(12, 14)
    $lbl.Size = New-Object System.Drawing.Size(416, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(12, 38)
    $txt.Size = New-Object System.Drawing.Size(416, 24)
    if ($Prefill) { $txt.Text = $Prefill }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Weiter'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(256, 80); $ok.Size = New-Object System.Drawing.Size(80, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(344, 80); $cancel.Size = New-Object System.Drawing.Size(84, 28)

    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = $dlg.ShowDialog($form)
    if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $txt.Text.Trim()) { return $txt.Text.Trim() }
    return $null
}

function Show-VscPickerDialog {
    # Auswahl der zu verlängernden Karte aus den vorhandenen VSCs, mit Restlaufzeit
    # des (frühesten) Zertifikats auf der jeweiligen Karte.
    param($Readers, $Certs)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Vorhandene virtuelle Smartcard wählen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 320)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Welche vorhandene virtuelle Smartcard verwenden?'
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(536, 20)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(12, 38)
    $list.Size = New-Object System.Drawing.Size(536, 220)
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    foreach ($r in $Readers) {
        $cardCerts = @($Certs | Where-Object { $_.Reader -and $r.PcscName -and $_.Reader -eq $r.PcscName })
        $expiryNote = if ($cardCerts.Count -gt 0) {
            $soonest = ($cardCerts | Sort-Object NotAfter | Select-Object -First 1).NotAfter
            "gültig bis $($soonest.ToString('yyyy-MM-dd'))"
        } else { 'kein Zertifikat gefunden' }
        $pcsc = if ($r.PcscName) { $r.PcscName } else { '?' }
        [void]$list.Items.Add("$($r.FriendlyName)  [$pcsc]  -  $expiryNote")
    }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Verwenden'; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(372, 276); $ok.Size = New-Object System.Drawing.Size(90, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(468, 276); $cancel.Size = New-Object System.Drawing.Size(80, 28)

    $dlg.Controls.AddRange(@($lbl, $list, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = $dlg.ShowDialog($form)
    if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedIndex -ge 0) {
        return $Readers[$list.SelectedIndex]
    }
    return $null
}

function Enter-PlanARenewal {
    # Sprung in den Plan-A-"Anfordern"-Schritt fuer eine BESTEHENDE Karte - ohne
    # Neuerstellung. Wird für "bestehende VSC verwenden" genutzt (Konto kommt vom
    # Szenario, NICHT von der Karte). -OfflineDirect fuer den Cloud/CBA-Weg.
    param($Reader, [string]$TargetAccount, [switch]$OfflineDirect)
    $script:TargetAccount = $TargetAccount   # $null = aktueller Benutzer
    $script:PlanA_VscCreated = $true
    $script:PlanA_CardName = $Reader.FriendlyName
    $script:PlanA_PcscName = $Reader.PcscName
    $script:PlanA_CertIssued = $false
    $script:PlanA_PendingRequestId = $null
    $script:PlanA_RenewMode = $true
    $script:PlanA_OfflineDirect = [bool]$OfflineDirect
    $script:PlanEntryFrom = 'Scenario'
    $pnlScenario.Visible = $false
    $pnlModeSelect.Visible = $false
    $script:ActivePlan = 'A'
    $tabPlanA.Visible = $true
    Set-PlanATemplateForMode
    Show-PlanAStep -Index 1   # "Zertifikat anfordern" (Status/Erstellen übersprungen)
}

function Enter-PlanBRenewal {
    # Verlängern eines Fremdkonto-Certs OHNE EA-Zertifikat: Sprung in den Plan-B-
    # "CSR"-Schritt (Index 2) fuer die bestehende Karte, das Erstellen wird
    # uebersprungen. Die Einreichung erfolgt danach als das Zielkonto (RDP-Schritt).
    param($Reader, [string]$TargetAccount)
    $script:TargetAccount = $TargetAccount
    $script:PlanB_VscCreated = $true
    $script:PlanB_CardName = $Reader.FriendlyName
    $script:PlanB_PcscName = $Reader.PcscName
    $script:PlanB_CsrPath = $null
    $script:PlanB_PendingRequestId = $null
    $script:PlanB_RenewMode = $true
    $script:PlanEntryFrom = 'Scenario'
    $pnlScenario.Visible = $false
    $pnlModeSelect.Visible = $false
    $script:ActivePlan = 'B'
    $tabPlanB.Visible = $true
    Show-PlanBStep -Index 2
}

function Show-VscChoiceDialog {
    # Fragt, ob eine NEUE virtuelle Smartcard erstellt oder eine BESTEHENDE verwendet
    # werden soll. Gibt 'new', 'existing' oder $null (abgebrochen) zurueck.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Virtuelle Smartcard'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 150)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Neue virtuelle Smartcard erstellen oder eine vorhandene verwenden?'
    $lbl.Location = New-Object System.Drawing.Point(16, 16)
    $lbl.Size = New-Object System.Drawing.Size(428, 40)
    $dlg.Controls.Add($lbl)

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = 'Neue VSC erstellen'
    $btnNew.Location = New-Object System.Drawing.Point(16, 68); $btnNew.Size = New-Object System.Drawing.Size(200, 34)
    $btnExisting = New-Object System.Windows.Forms.Button
    $btnExisting.Text = 'Bestehende verwenden'
    $btnExisting.Location = New-Object System.Drawing.Point(228, 68); $btnExisting.Size = New-Object System.Drawing.Size(200, 34)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Abbrechen'; $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(344, 112); $btnCancel.Size = New-Object System.Drawing.Size(100, 26)

    $script:VscChoice = $null
    $btnNew.Add_Click({ $script:VscChoice = 'new'; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $btnExisting.Add_Click({ $script:VscChoice = 'existing'; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })

    $dlg.Controls.AddRange(@($btnNew, $btnExisting, $btnCancel))
    $dlg.CancelButton = $btnCancel
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $script:VscChoice }
    return $null
}

function Select-ExistingVsc {
    # Waehlt eine vorhandene VSC als Schluesseltraeger (fuer "bestehende verwenden").
    # Gibt den gewaehlten Reader zurueck oder $null (keine vorhanden / abgebrochen).
    $readers = @(Get-VirtualSmartCardReaders | Where-Object { $_.PcscName })
    if ($readers.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Auf diesem Gerät wurde keine virtuelle Smartcard gefunden. Bitte stattdessen "Neue VSC erstellen" wählen.', 'Keine VSC vorhanden', 'OK', 'Information') | Out-Null
        return $null
    }
    if ($readers.Count -eq 1) { return $readers[0] }
    $certs = @(Get-SmartCardCertificates)
    return (Show-VscPickerDialog -Readers $readers -Certs $certs)
}

function Invoke-RenewalCleanup {
    # Nach einer Verlängerung liegt (weil certreq -new einen NEUEN Schlüssel erzeugt)
    # zusätzlich das ALTE Zertifikat/der alte Container auf der Karte. Diese Funktion
    # behält das NEUESTE Zertifikat der KARTE (grösstes NotBefore = gerade ausgestellt)
    # und bietet an, die älteren auf DERSELBEN Karte zu entfernen - damit "Verlängern"
    # effektiv ein Ersetzen wird.
    #
    # WICHTIG (das war der stille Aussteiger): früher wurde zusätzlich nach dem KONTO
    # gefiltert (UPN/Subject aus Get-EnrollmentIdentity). Bei Fremdkonto-Verlängerung
    # baut die CA aber aus dem AD (Build-from-AD): das ausgestellte Zertifikat trägt die
    # AD-UPN (z.B. adm-t1@contoso.com), NICHT den beim Antrag genutzten Term
    # (adm-t1@contoso.local). Der UPN-Vergleich schlug fehl -> nichts gefunden -> keine
    # Abfrage. Deshalb jetzt KARTEN-bezogen (Reader), ohne fragilen Konto-Term. Die zu
    # entfernenden Zertifikate werden im Dialog explizit aufgelistet - der Nutzer
    # entscheidet. $UpnOrTerm bleibt nur fuer Logging/Rueckwaertskompatibilitaet.
    param([string]$PcscName, [string]$UpnOrTerm)
    if (-not $PcscName) {
        Write-WizardLog -Message 'Aufräumen übersprungen: kein PC/SC-Kartenname bekannt (PcscName leer).' -Level Warn
        return
    }

    $cardCerts = @(Get-SmartCardCertificates | Where-Object { $_.Reader -and ($_.Reader -eq $PcscName) })
    Write-WizardLog -Message "Aufräumen: $($cardCerts.Count) Zertifikat(e) auf Karte '$PcscName' gefunden." -Level Info
    if ($cardCerts.Count -le 1) {
        Write-WizardLog -Message 'Aufräumen: nur ein Zertifikat auf der Karte - nichts zu entfernen.' -Level Info
        return
    }

    $sorted = @($cardCerts | Sort-Object NotBefore -Descending)
    $keep = $sorted[0]
    $old  = @($sorted | Select-Object -Skip 1)   # das neueste (gerade ausgestellte) behalten
    Write-WizardLog -Message "Aufräumen: behalte '$($keep.Subject)' (gültig bis $($keep.NotAfter.ToString('yyyy-MM-dd'))), $($old.Count) ältere(s) zum Entfernen." -Level Info

    $list = ($old | ForEach-Object { "- $($_.Subject)`r`n   gültig bis $($_.NotAfter.ToString('yyyy-MM-dd')), Thumbprint $($_.Thumbprint)" }) -join "`r`n"
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Auf der Karte liegen nach der Verlängerung noch $($old.Count) ältere(s) Zertifikat(e). Jetzt entfernen, damit nur das neue bleibt?`r`n`r`nBEHALTEN (neu):`r`n- $($keep.Subject)`r`n   gültig bis $($keep.NotAfter.ToString('yyyy-MM-dd'))`r`n`r`nENTFERNEN:`r`n$list`r`n`r`nJe Entfernung erscheint ggf. eine UAC-/PIN-Abfrage.",
        'Karte aufräumen - altes Zertifikat entfernen', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-WizardLog -Message 'Aufräumen: vom Benutzer abgelehnt - ältere Zertifikate bleiben auf der Karte.' -Level Info
        return
    }

    foreach ($c in $old) {
        if ($c.Provider -and $c.KeyContainerName) {
            $res = Remove-SmartCardCertificateFromCard -Provider $c.Provider -ContainerName $c.KeyContainerName -Thumbprint $c.Thumbprint
            if ($res.Success) {
                Write-WizardLog -Message "Altes Zertifikat entfernt ($($c.Thumbprint))." -Level Success
            } else {
                Write-WizardLog -Message "Altes Zertifikat konnte nicht entfernt werden ($($c.Thumbprint)): $($res.Message)" -Level Error
            }
        } else {
            # Kein Container/Provider ermittelbar: wenigstens aus dem Zertifikatsspeicher
            # entfernen (der Schlüsselcontainer auf der Karte bleibt dann evtl. zurück).
            Write-WizardLog -Message "Altes Zertifikat ohne ermittelbaren Schlüsselcontainer ($($c.Thumbprint)) - entferne nur aus dem Zertifikatsspeicher." -Level Warn
            try {
                Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $c.Thumbprint } | Remove-Item -Force -ErrorAction Stop
                Write-WizardLog -Message "Altes Zertifikat aus dem Speicher entfernt ($($c.Thumbprint)); Container auf der Karte ggf. manuell prüfen (certutil -scinfo)." -Level Success
            } catch {
                Write-WizardLog -Message "Entfernen aus dem Speicher fehlgeschlagen ($($c.Thumbprint)): $($_.Exception.Message)" -Level Error
            }
        }
    }
}

function Invoke-ScenarioNextClick {
    if (-not $script:SelectedScenario) {
        $lblScnSub.Visible = $false
        $lblScnValidation.Text = 'Bitte ein Szenario auswählen.'
        $lblScnValidation.Visible = $true
        return
    }
    # Sicherheitsnetz: ausgegraute (hier nicht mögliche) Szenarien nicht starten.
    if ($script:ScnAvailable.ContainsKey($script:SelectedScenario) -and -not $script:ScnAvailable[$script:SelectedScenario]) {
        $lblScnSub.Visible = $false
        $lblScnValidation.Text = "Hier nicht möglich: $($script:ScnReason[$script:SelectedScenario])"
        $lblScnValidation.Visible = $true
        return
    }
    switch ($script:SelectedScenario) {
        1 {
            # VSC für onprem-Adminkonto (separates Konto): mit EA-Zertifikat per EOBO
            # (Plan A), sonst Plan B/Bootstrap (Einreichung ALS das Zielkonto per RDP).
            # Identität = das eingegebene Zielkonto (NICHT von der Karte abgeleitet).
            $acct = Show-AccountInputDialog
            if (-not $acct) { return }
            $script:TargetAccount = $acct
            $script:PlanA_OfflineDirect = $false
            $plan = Get-ScenarioPlanForSeparateAccount   # 'A' (EOBO) / 'B'
            if ($plan -eq 'B') {
                [System.Windows.Forms.MessageBox]::Show("Für $acct wird per Plan B ausgestellt:`r`n`r`nKein EA-Zertifikat vorhanden - die Einreichung erfolgt ALS das Zielkonto (RDP). Für eine ERSTausstellung muss das Konto ggf. kurz Passwort-Anmeldung erlauben (Smartcard-Zwang kurz aus), danach wieder auf 'Smartcard erforderlich'.", 'Onprem-Adminkonto - Plan B', 'OK', 'Information') | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show("Für $acct wird per Enroll on Behalf Of (Plan A) ausgestellt:`r`n`r`nEin EA-Zertifikat wurde gefunden - die Karte wird im Auftrag des Zielkontos ausgestellt, ohne RDP und ohne temporäres Passwort.", 'Onprem-Adminkonto - EOBO', 'OK', 'Information') | Out-Null
            }
            $choice = Show-VscChoiceDialog
            if (-not $choice) { return }
            if ($choice -eq 'existing') {
                $card = Select-ExistingVsc
                if (-not $card) { return }
                if ($plan -eq 'A') { Enter-PlanARenewal -Reader $card -TargetAccount $acct }
                else { Enter-PlanBRenewal -Reader $card -TargetAccount $acct }
            } else {
                Enter-Plan -Plan $plan
            }
        }
        2 {
            # VSC für onprem- oder hybrid-Konto: DEIN eigenes Konto, Direkt-Ausstellung.
            $script:TargetAccount = $null
            $script:PlanA_OfflineDirect = $false
            $choice = Show-VscChoiceDialog
            if (-not $choice) { return }
            if ($choice -eq 'existing') {
                $card = Select-ExistingVsc
                if (-not $card) { return }
                Enter-PlanARenewal -Reader $card -TargetAccount $null
            } else {
                Enter-Plan -Plan 'A'
            }
        }
        3 {
            # VSC für Cloudonly-Adminkonto (Entra CBA): Offline-/Supply-in-request-Template,
            # als DU einreichen, Ziel-UPN im CSR. NUR Cloud/CBA (kein On-Prem-Logon).
            $acct = Show-AccountInputDialog -Prompt 'Cloud-Zielkonto/UPN (Entra, z.B. gadmin@contoso.onmicrosoft.com):'
            if (-not $acct) { return }
            $script:TargetAccount = $acct
            $script:PlanA_OfflineDirect = $true
            [System.Windows.Forms.MessageBox]::Show("Zertifikat für $acct über das Offline-Template (NUR Entra CBA / Cloud):`r`n`r`n- Du reichst als DU ein (dein Konto braucht Enroll-Recht auf dem Supply-in-request-Template).`r`n- Die Ziel-UPN steht im CSR-SAN; Entra mappt darüber (Binding) und vertraut der hochgeladenen CA-Kette.`r`n- Danach in Entra: ausstellende CA importieren + CBA-Binding auf UPN (siehe RUNBOOK). Alternative ganz ohne PKI: FIDO2/Passkey.`r`n`r`nWICHTIG: Das taugt NICHT für On-Prem-AD-Smartcard-Logon - dafür fehlt die Konto-SID (starke Zuordnung, KB5014754). Für On-Prem-Konten stattdessen Szenario 01 (onprem-Adminkonto) oder 05 (EOBO).", 'Cloud-Konto / Entra CBA', 'OK', 'Information') | Out-Null
            $choice = Show-VscChoiceDialog
            if (-not $choice) { return }
            if ($choice -eq 'existing') {
                $card = Select-ExistingVsc
                if (-not $card) { return }
                Enter-PlanARenewal -Reader $card -TargetAccount $acct -OfflineDirect
            } else {
                Enter-Plan -Plan 'A'
            }
        }
        4 { Show-VscInventoryDialog -Owner $form }
        5 {
            # EOBO für ein anderes Konto: Zielkonto abfragen, dann Plan A (EA) bzw. Plan B.
            $acct = Show-AccountInputDialog
            if (-not $acct) { return }
            $script:TargetAccount = $acct
            $script:PlanA_OfflineDirect = $false
            Enter-Plan -Plan (Get-ScenarioPlanForSeparateAccount)
        }
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
Update-Splash -Text 'Plan A vorbereiten...' -Percent 62

$pnlStepsA = New-Object System.Windows.Forms.Panel
$pnlStepsA.Dock = 'Fill'
$tabPlanA.Controls.Add($pnlStepsA)

# --- Schritt A1: Status ---
# Frueherer "Status/Prüfung"-Schritt (pnlA1). Bewusst NICHT mehr im Ablauf: die
# Umgebung wird bereits beim Start erkannt (Get-EnvironmentCapabilities), und dass das
# Szenario auf der Startseite nicht ausgegraut ist, IST der Nachweis der Eignung - eine
# zweite Prüfung hier waere redundant (und zeigte frueher sogar eine falsche
# "Plan B"-Heuristikwarnung). Panel bleibt definiert, wird aber nie angezeigt.
$pnlA1 = New-Object System.Windows.Forms.Panel
$pnlA1.Dock = 'Fill'
$pnlA1.Visible = $false
$pnlStepsA.Controls.Add($pnlA1)

$lblJoinStateA = New-WizardLabel -Text 'Domänen-Status: ...' -X 20 -Y 20
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

$lblVscInfoA = New-WizardLabel -Text 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur für diesen Schritt benötigt). Danach öffnet sich ein Dialog zur Eingabe der Karten-PIN (mindestens 6 Zeichen, mit Bestätigung; der Dialog zeigt die geltende Mindestlänge an). Die Karte wird anschließend über die Windows-Smartcard-API erstellt.' -X 20 -Y 84 -Width 780 -Height 76

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
    $lblVscResultA.Text = 'Erstelle virtuelle Smartcard - bitte UAC bestätigen, dann im Dialog die PIN festlegen...'
    Set-Busy -Text 'Erstelle virtuelle Smartcard...'
    try {
        $result = New-VirtualSmartCard -CardName $txtCardNameA.Text -PinPolicyMinLength (Get-ConfiguredPinMinLength)
    } catch {
        $result = [pscustomobject]@{ Success = $false; ExitCode = $null; Message = $_.Exception.Message }
        Write-WizardLog -Message "Unerwarteter Fehler bei der VSC-Erstellung: $($_.Exception.Message)" -Level Error
    } finally { Clear-Busy }
    if ($result.Success) {
        $script:PlanA_VscCreated = $true
        $script:PlanA_CardName = $txtCardNameA.Text
        $script:PlanA_PcscName = $result.PcscName
        $lblVscResultA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblVscResultA.Text = if ($result.PcscName) {
            "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der Zertifikatsanforderung) heißt sie: '$($result.PcscName)'."
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

$lblCardHintA = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 44
$lblCardHintA.ForeColor = [System.Drawing.Color]::ForestGreen
$lblCardHintA.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

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
    # Fuer ein separates Zielkonto gibt es zwei direkte Wege:
    #  - EOBO (Enroll on Behalf Of): braucht ein EA-Zertifikat, Build-from-AD.
    #  - Offline-Direkt (Szenario 03, Cloud/Entra CBA): KEIN EA - du reichst als DU ein,
    #    Subject/SAN des Ziels stehen im CSR (Supply-in-request). NUR Cloud, kein On-Prem.
    $eoboThumbprint = $null
    if ($script:TargetAccount -and -not $script:PlanA_OfflineDirect) {
        $eaCerts = @(Get-EnrollmentAgentCertificates)
        if ($eaCerts.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Für ein separates On-Prem-Konto ist hier ein Enrollment-Agent-Zertifikat nötig (Enroll on Behalf Of) - es wurde keins im Zertifikatsspeicher gefunden. Entweder in den Einstellungen ein EA-Zertifikat beantragen und diesen Schritt wiederholen, oder Plan B (RDP als Zielkonto) verwenden. (Der Offline-Template-Weg aus Szenario 03 taugt nur für Cloud/Entra CBA, NICHT für On-Prem-Logon.)', 'Separates Konto: EA-Zertifikat nötig', 'OK', 'Information') | Out-Null
            return
        }
        $eoboThumbprint = $eaCerts[0].Thumbprint
    }
    # Template: im Offline-Direkt-Modus ist die Combo editierbar (SelectedItem kann leer
    # sein, wenn getippt) - deshalb .Text als Rueckfall.
    $selectedTemplate = if ($cboTemplateA.SelectedItem) { "$($cboTemplateA.SelectedItem)" } else { $cboTemplateA.Text.Trim() }
    if (-not $selectedTemplate) {
        [System.Windows.Forms.MessageBox]::Show('Bitte ein Zertifikatstemplate auswählen bzw. eintragen (im Offline-Modus das Supply-in-request-Template).', 'Hinweis', 'OK', 'Warning') | Out-Null
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
        # EOBO: Zielkonto + Template gehören in den PKCS7-Antrag, der mit dem
        # EA-Zertifikat co-signiert wird. Das Template wird beim Submit dann NICHT
        # nochmal per -attrib gesetzt.
        $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $config.CspName -OutputDirectory $script:PlanA_EnrollDir -RequesterName $identity.DisplayName -TemplateName $selectedTemplate -SigningCertThumbprint $eoboThumbprint
    } else {
        # Normale PKCS10-Anforderung: Subject + SAN-UPN kommen aus der Identität. Im
        # Offline-Direkt-Modus ist das die ZIEL-Identität (Supply-in-request) - der
        # Submit als DU liefert das passende Zertifikat, ohne EA und ohne RDP.
        $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $config.CspName -OutputDirectory $script:PlanA_EnrollDir
    }
    if (-not $csr.Success) {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = 'Antragserstellung fehlgeschlagen. Details siehe Log.'
        $btnRequestCertA.Enabled = $true
        return
    }

    $submitTemplate = if ($eoboThumbprint) { $null } else { $selectedTemplate }
    $submit = Submit-CertificateSigningRequest -CsrPath $csr.CsrPath -CAConfig $config.CAConfig -TemplateName $submitTemplate -OutputDirectory $script:PlanA_EnrollDir
    if ($submit.Pending) {
        $script:PlanA_PendingRequestId = $submit.RequestId
        # Zustand persistieren: der wartende Antrag kann nach einem Wizard-Neustart
        # über den Fortsetzen-Dialog beim Start wieder aufgenommen werden.
        Save-WizardResumeState -State @{
            Plan = 'A'; Stage = 'Pending'; RequestId = $submit.RequestId
            CardName = $script:PlanA_CardName; PcscName = "$($script:PlanA_PcscName)"
            EnrollDir = $script:PlanA_EnrollDir
        }
        $lblCertResultA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblCertResultA.Text = "Antrag wurde eingereicht und wartet auf Genehmigung (RequestId $($submit.RequestId)). Bitte später erneut abrufen - auch nach einem Neustart des Wizards möglich."
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
        if ($script:PlanA_RenewMode) {
            $idA = Get-EnrollmentIdentity
            Invoke-RenewalCleanup -PcscName $script:PlanA_PcscName -UpnOrTerm $(if ($idA.Upn) { $idA.Upn } else { $idA.SearchTerm })
            Update-PlanASummary
        }
    } else {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = 'Übernahme des Zertifikats fehlgeschlagen. Details siehe Log.'
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
            if ($script:PlanA_RenewMode) {
                $idA = Get-EnrollmentIdentity
                Invoke-RenewalCleanup -PcscName $script:PlanA_PcscName -UpnOrTerm $(if ($idA.Upn) { $idA.Upn } else { $idA.SearchTerm })
                Update-PlanASummary
            }
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show('Zertifikat ist noch nicht ausgestellt.', 'Hinweis', 'OK', 'Information') | Out-Null
    }
})

# --- Schritt A4: Zusammenfassung ---
$pnlA4 = New-Object System.Windows.Forms.Panel
$pnlA4.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA4)

$lblSummaryA = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 190
$btnResetA = New-Object System.Windows.Forms.Button
$btnResetA.Text = 'Weitere Smartcard beantragen'
$btnResetA.Location = New-Object System.Drawing.Point(20, 220)
$btnResetA.Size = New-Object System.Drawing.Size(240, 32)

$btnStartA = New-Object System.Windows.Forms.Button
$btnStartA.Text = 'Zum Startbildschirm'
$btnStartA.Location = New-Object System.Drawing.Point(280, 220)
$btnStartA.Size = New-Object System.Drawing.Size(200, 32)

$pnlA4.Controls.AddRange(@($lblSummaryA, $btnResetA, $btnStartA))

function Get-CardValiditySummaryText {
    # Baut den Zusammenfassungstext für die Abschluss-Seite. Wenn der PC/SC-Kartenname
    # bekannt ist, werden ALLE Zertifikate DIESER Karte einzeln mit ihrer jeweiligen
    # Gültigkeit gelistet (die Karte selbst hat kein Ablaufdatum - die Zertifikate
    # darauf schon, und ggf. mehrere mit unterschiedlichen Daten). Fallback: die
    # bisherige term-basierte Suche im Zertifikatsspeicher.
    param([string]$CardName, [string]$PcscName, [string]$MatchTerm)

    $certs = @()
    if ($PcscName) {
        $certs = @(Get-SmartCardCertificates |
            Where-Object { $_.Reader -and ($_.Reader -eq $PcscName) } |
            Sort-Object NotAfter)
    }

    if ($certs.Count -eq 0) {
        $summary = Get-IssuedCertificateSummary -Match $MatchTerm
        if ($summary) {
            return "Kartenname: $CardName`r`nZertifikat: $($summary.Subject)`r`nThumbprint: $($summary.Thumbprint)`r`nGültig ab: $($summary.NotBefore)`r`nGültig bis: $($summary.NotAfter)"
        }
        return "Kartenname: $CardName`r`nKein passendes Zertifikat gefunden."
    }

    if ($certs.Count -eq 1) {
        $c = $certs[0]
        return "Kartenname: $CardName`r`nZertifikat: $($c.Subject)`r`nThumbprint: $($c.Thumbprint)`r`nGültig ab: $($c.NotBefore)`r`nGültig bis: $($c.NotAfter)"
    }

    # Mehrere Zertifikate auf der Karte -> je Zertifikat die Gültigkeit einzeln.
    $lines = @("Kartenname: $CardName", "Auf der Karte liegen $($certs.Count) Zertifikate:")
    $i = 0
    foreach ($c in $certs) {
        $i++
        $lines += "  $i) $($c.Subject)"
        $lines += "     gültig $($c.NotBefore.ToString('yyyy-MM-dd')) bis $($c.NotAfter.ToString('yyyy-MM-dd'))  (Thumbprint $($c.Thumbprint))"
    }
    $lines += 'Hinweis: Beim Smartcard-Logon nutzt Windows i.d.R. das erste passende Zertifikat. Für "eine Karte = ein Zertifikat" die älteren entfernen (Aufräum-Abfrage nach dem Erneuern oder Szenario 04).'
    return ($lines -join "`r`n")
}

function Update-PlanASummary {
    $id = Get-EnrollmentIdentity
    $matchTerm = if ($id.Upn) { $id.Upn } else { $id.SearchTerm }
    $lblSummaryA.Text = Get-CardValiditySummaryText -CardName $script:PlanA_CardName -PcscName $script:PlanA_PcscName -MatchTerm $matchTerm
}

$btnResetA.Add_Click({
    $script:PlanA_VscCreated = $false
    $script:PlanA_CertIssued = $false
    $script:PlanA_PendingRequestId = $null
    $txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"
    $lblVscResultA.Text = ''
    $lblCertResultA.Text = ''
    $btnRetrieveA.Visible = $false
    $script:PlanA_RenewMode = $false
    $script:PlanA_OfflineDirect = $false
    if ($script:PlanEntryFrom -eq 'Scenario') {
        $tabPlanA.Visible = $false
        Show-ScenarioStep
    } else {
        Show-PlanAStep -Index 0   # "VSC erstellen" (erster Schritt nach Entfall von Status)
    }
})

# Immer zurück zum Startbildschirm - unabhängig vom Einstieg (Szenario oder Verlängerung).
$btnStartA.Add_Click({
    $script:PlanA_RenewMode = $false
    $script:PlanA_OfflineDirect = $false
    $tabPlanA.Visible = $false
    Show-ScenarioStep
})

# --- Navigation Plan A ---
$planAStepTitles = @('Virtuelle Smartcard erstellen', 'Zertifikat anfordern', 'Zusammenfassung')

function Update-PlanAStatus {
    $joinState = Get-DomainJoinState
    $tpm = Test-TpmReadiness
    $upn = Get-CurrentUpn

    $lblJoinStateA.Text = "Domänen-Status: $($joinState.Mode)" + $(if ($joinState.Domain) { " ($($joinState.Domain))" } else { '' })
    $lblUserA.Text = "Angemeldeter Benutzer: $env:USERDOMAIN\$env:USERNAME" + $(if ($upn) { " (UPN: $upn)" } else { '' })
    $lblTpmA.Text = "TPM: vorhanden=$($tpm.Present), bereit=$($tpm.Ready)"

    if ($script:TargetAccount -and $script:PlanA_OfflineDirect) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblWarnA.Text = "Direkt-Ausstellung für ein separates Konto ($($script:TargetAccount)) über das Offline-Template: du reichst als DU ein (Enroll-Recht auf dem Supply-in-request-Template nötig), Ziel-Subject/UPN stehen im CSR. Kein EA, kein RDP. In Schritt 3 das Offline-Template wählen/eintragen."
    } elseif ($script:TargetAccount) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblWarnA.Text = "Smartcard wird für ein separates Konto beantragt ($($script:TargetAccount)) - die Ausstellung in Schritt 3 erfolgt bruchfrei per Enroll on Behalf Of (Enrollment-Agent-Zertifikat), ohne RDP."
    } elseif ($joinState.Mode -ne 'ADDomain') {
        $lblWarnA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblWarnA.Text = 'Dieser Rechner scheint nicht domänen-gebunden zu sein. Für diesen Fall ist "Plan B" vorgesehen.'
    } elseif (-not $tpm.Ready) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblWarnA.Text = 'Kein bereites TPM erkannt - die Erstellung einer virtuellen Smartcard ist eventuell nicht möglich.'
    } else {
        $lblWarnA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblWarnA.Text = 'Voraussetzungen erfüllt.'
    }
}

function Show-PlanAStep {
    # Schritte (Status-/Prüfungsschritt entfernt - siehe Kommentar bei $pnlA1):
    #   0 = VSC erstellen, 1 = Zertifikat anfordern, 2 = Zusammenfassung.
    param([int]$Index)
    $panels = @($pnlA2, $pnlA3, $pnlA4)
    for ($i = 0; $i -lt $panels.Count; $i++) {
        $panels[$i].Visible = ($i -eq $Index)
    }
    $script:PlanACurrentStep = $Index
    # Globale Schrittnummer: +2, da Schritt 1 (Szenario) davor liegt.
    $lblGlobalStep.Text = "Schritt $($Index + 2) von $($panels.Count + 1): $($planAStepTitles[$Index])"
    $btnBackShared.Enabled = $true
    $btnNextShared.Enabled = ($Index -lt $panels.Count - 1)

    switch ($Index) {
        1 {
            # Windows-Kartenauswahl-/PIN-Dialoge zeigen NICHT den vergebenen
            # Kartennamen, sondern den PC/SC-Namen "Microsoft Virtual Smart Card N".
            $lblCardHintA.Text = if ($script:PlanA_PcscName) {
                "➜ Im Windows-Kartenauswahl-Dialog die Karte `"$($script:PlanA_PcscName)`" wählen  (= '$($script:PlanA_CardName)')."
            } else { '' }
        }
        2 { Update-PlanASummary }
    }
}

function Invoke-PlanANextClick {
    switch ($script:PlanACurrentStep) {
        0 {
            if (-not $script:PlanA_VscCreated) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst die virtuelle Smartcard erstellen.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanAStep -Index 1
        }
        1 {
            if (-not $script:PlanA_CertIssued) {
                [System.Windows.Forms.MessageBox]::Show('Bitte zuerst das Zertifikat erfolgreich anfordern.', 'Hinweis', 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanAStep -Index 2
        }
    }
}

function Invoke-PlanABackClick {
    # Im Verlängern-Modus wurde direkt bei "Anfordern" (jetzt Index 1) eingestiegen -
    # "Zurück" führt dort zur Szenario-Auswahl, nicht zum (übersprungenen) Erstellen.
    if ($script:PlanA_RenewMode -and $script:PlanACurrentStep -eq 1) {
        $tabPlanA.Visible = $false
        Show-ScenarioStep
        return
    }
    if ($script:PlanACurrentStep -gt 0) {
        Show-PlanAStep -Index ($script:PlanACurrentStep - 1)
    } else {
        $tabPlanA.Visible = $false
        if ($script:PlanEntryFrom -eq 'Scenario') { Show-ScenarioStep } else { Show-ModeSelectStep }
    }
}

#endregion

# ============================================================================
#region PLAN B TAB
# ============================================================================
Update-Splash -Text 'Plan B vorbereiten...' -Percent 70

$pnlStepsB = New-Object System.Windows.Forms.Panel
$pnlStepsB.Dock = 'Fill'
$tabPlanB.Controls.Add($pnlStepsB)

# --- Schritt B1: Status ---
$pnlB1 = New-Object System.Windows.Forms.Panel
$pnlB1.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB1)

$lblJoinStateB = New-WizardLabel -Text 'Domänen-Status: ...' -X 20 -Y 20
$lblUserB = New-WizardLabel -Text 'Angemeldeter Benutzer: ...' -X 20 -Y 50
$lblTargetB = New-WizardLabel -Text '' -X 20 -Y 80
$lblJumpServerB = New-WizardLabel -Text '' -X 20 -Y 110
$lblExplainB = New-WizardLabel -Text 'Dieser Modus führt eine virtuelle Smartcard und einen Zertifikatsantrag über einen Zwischenschritt per RDP durch, da entweder dieser Rechner keine direkte Sicht auf die Zertifizierungsstelle hat oder die Einreichung als separates Zielkonto erfolgen muss. CA-Konfiguration und automatische PKI-Erkennung finden sich im Tab "Einstellungen".' -X 20 -Y 146 -Width 780 -Height 60
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

$lblVscInfoB = New-WizardLabel -Text 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur für diesen Schritt benötigt). Danach öffnet sich ein Dialog zur Eingabe der Karten-PIN (mindestens 6 Zeichen, mit Bestätigung; der Dialog zeigt die geltende Mindestlänge an). Die Karte wird anschließend über die Windows-Smartcard-API erstellt.' -X 20 -Y 84 -Width 780 -Height 76

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
    $lblVscResultB.Text = 'Erstelle virtuelle Smartcard - bitte UAC bestätigen, dann im Dialog die PIN festlegen...'
    Set-Busy -Text 'Erstelle virtuelle Smartcard...'
    try {
        $result = New-VirtualSmartCard -CardName $txtCardNameB.Text -PinPolicyMinLength (Get-ConfiguredPinMinLength)
    } catch {
        $result = [pscustomobject]@{ Success = $false; ExitCode = $null; Message = $_.Exception.Message }
        Write-WizardLog -Message "Unerwarteter Fehler bei der VSC-Erstellung: $($_.Exception.Message)" -Level Error
    } finally { Clear-Busy }
    if ($result.Success) {
        $script:PlanB_VscCreated = $true
        $script:PlanB_CardName = $txtCardNameB.Text
        $script:PlanB_PcscName = $result.PcscName
        $lblVscResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblVscResultB.Text = if ($result.PcscName) {
            "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der CSR-Erstellung) heißt sie: '$($result.PcscName)'."
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

$lblCsrInfoB = New-WizardLabel -Text 'Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Es erscheint ggf. ein PIN-Dialog der Smartcard.' -X 20 -Y 20 -Width 780 -Height 48

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
$btnOpenCsrFolderB.Text = 'Ordner öffnen'
$btnOpenCsrFolderB.Location = New-Object System.Drawing.Point(20, 172)
$btnOpenCsrFolderB.Size = New-Object System.Drawing.Size(160, 28)

$lblCsrTextLabelB = New-WizardLabel -Text 'CSR-Text (PEM) - Alternative zur Dateifreigabe: per RDP-Zwischenablage in den Einreichungshelfer (VscWizard.Submit.ps1) auf dem Zielserver einfügen:' -X 20 -Y 216 -Width 780 -Height 34
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

# --- Schritt B4: Übergabe per RDP ---
$pnlB4 = New-Object System.Windows.Forms.Panel
$pnlB4.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB4)

$lblHandoffB = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 220
$pnlB4.Controls.Add($lblHandoffB)

function Update-PlanBHandoff {
    $identity = Get-EnrollmentIdentity
    $reason = if ($script:TargetAccount) {
        "Die Einreichung bei der CA muss als $($identity.DisplayName) erfolgen (Berechtigungsprüfung der CA basiert auf dem einreichenden Konto) - dieser Rechner reicht dafür nicht, unabhängig vom Domänen-Status."
    } else {
        'Dieser Rechner hat vermutlich keine direkte Sicht auf die Zertifizierungsstelle.'
    }

    $lblHandoffB.Text = @"
Nächste Schritte:

$reason

1. Die CSR ist bereits in der Zwischenablage (auch als Datei: $($script:PlanB_CsrPath)).
2. Per RDP verbinden mit: $($config.RdpJumpServer) - dort anmelden als: $($identity.DisplayName)
3. Auf dem Server den Einreichungshelfer 'VscWizard.Submit.ps1' (bzw. VscWizard.Submit.exe)
   starten, die CSR einfügen, CA/Template wählen und "Antrag einreichen".
4. Das ausgestellte Zertifikat dort mit "Kopieren" in die Zwischenablage holen.

Dann hier auf "Weiter" klicken: du gelangst direkt zum Schritt "Zertifikat abschließen",
wo du das kopierte Zertifikat einfügst und übernimmst. Die Übernahme erfolgt auf DIESEM
Rechner in DEINEM Konto - die Karte (und der offene Antrag) liegen hier, nicht beim Zielkonto.
"@
}

# --- Schritt B5: Antrag einreichen (auf dem Server) ---
$pnlB5 = New-Object System.Windows.Forms.Panel
$pnlB5.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB5)

$lblSubmitInfoB = New-WizardLabel -Text 'Auf dem CA-nahen Server auszuführen (angemeldet als Zielbenutzer). Standardweg: den per Zwischenablage mitgebrachten CSR-Text unten einfügen. Wurde der Antrag bereits anderweitig eingereicht (z.B. mit dem Einreichungshelfer VscWizard.Submit.ps1), diesen Schritt einfach mit "Weiter" überspringen.' -X 20 -Y 20 -Width 780 -Height 50

$lblCsrPasteLabelB = New-WizardLabel -Text 'CSR-Text (PEM) einfügen:' -X 20 -Y 74 -Width 300
$txtCsrPasteB = New-Object System.Windows.Forms.TextBox
$txtCsrPasteB.Location = New-Object System.Drawing.Point(20, 100)
$txtCsrPasteB.Size = New-Object System.Drawing.Size(780, 90)
$txtCsrPasteB.Multiline = $true
$txtCsrPasteB.ScrollBars = 'Vertical'
$txtCsrPasteB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnSelectCsrB = New-Object System.Windows.Forms.Button
$btnSelectCsrB.Text = '...oder CSR-Datei auswählen'
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
$btnOpenCerFolderB.Text = 'Ordner öffnen'
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
    # Standardweg: eingefügter CSR-Text (der Text-Workflow erzeugt auf dieser
    # Maschine keine CSR-Datei); die Dateiauswahl bleibt als Alternative.
    # CSR-Rohtext aus Paste ODER Datei holen und dann kanonisch säubern - das
    # verhindert CRYPT_E_ASN1_BADTAG (0x8009310b) durch BOM/UTF-16/Fremd-Whitespace/
    # kaputte Zeilenumbrüche aus dem Copy&Paste-/RDP-Round-trip.
    $csrRaw = $null
    if (-not [string]::IsNullOrWhiteSpace($txtCsrPasteB.Text)) {
        $csrRaw = $txtCsrPasteB.Text
    } elseif ($txtSelectedCsrB.Text) {
        try { $csrRaw = [System.IO.File]::ReadAllText($txtSelectedCsrB.Text) } catch { $csrRaw = $null }
    }
    if ([string]::IsNullOrWhiteSpace($csrRaw)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst den CSR-Text einfügen (oder alternativ eine CSR-Datei auswählen).', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    $csrClean = ConvertTo-CleanPemRequest -Text $csrRaw
    if (-not $csrClean) {
        [System.Windows.Forms.MessageBox]::Show('Der eingefügte/geladene Text ist keine gültige Zertifikatsanforderung (kein gültiges Base64-PEM). Bitte die CSR aus Schritt 3 erneut kopieren und einfügen.', 'Ungültige CSR', 'OK', 'Warning') | Out-Null
        return
    }
    $csrPath = Join-Path (Get-WizardWorkingDir) "PlanB-pasted-$([guid]::NewGuid()).req"
    Set-Content -Path $csrPath -Value $csrClean -Encoding ASCII -NoNewline
    if (-not $cboTemplateSubmitB.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show('Bitte ein Zertifikatstemplate auswählen.', 'Hinweis', 'OK', 'Warning') | Out-Null
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
        $lblSubmitResultB.Text = "Antrag wartet auf Genehmigung (RequestId $($submit.RequestId)) - Abruf auch nach einem Neustart des Wizards möglich."
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

# --- Schritt B6: Zertifikat abschließen (lokal) ---
$pnlB6 = New-Object System.Windows.Forms.Panel
$pnlB6.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB6)

$lblCompleteInfoB = New-WizardLabel -Text 'Zurück auf dem lokalen Rechner (im eigenen Konto): entweder die vom Server zurückkopierte Zertifikatsdatei (.cer) auswählen, oder den Text direkt einfügen (z.B. Ergebnis des Einreichungshelfers VscWizard.Submit.ps1).' -X 20 -Y 20 -Width 780 -Height 40

$btnSelectCerB = New-Object System.Windows.Forms.Button
$btnSelectCerB.Text = 'CER-Datei auswählen...'
$btnSelectCerB.Location = New-Object System.Drawing.Point(20, 66)
$btnSelectCerB.Size = New-Object System.Drawing.Size(200, 30)

$txtSelectedCerB = New-Object System.Windows.Forms.TextBox
$txtSelectedCerB.Location = New-Object System.Drawing.Point(230, 70)
$txtSelectedCerB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCerB.ReadOnly = $true

$btnCompleteB = New-Object System.Windows.Forms.Button
$btnCompleteB.Text = 'Aus Datei übernehmen'
$btnCompleteB.Location = New-Object System.Drawing.Point(20, 110)
$btnCompleteB.Size = New-Object System.Drawing.Size(200, 32)

$lblCerTextLabelB = New-WizardLabel -Text '...oder CER-Text hier einfügen:' -X 20 -Y 156 -Width 780
$txtCerTextB = New-Object System.Windows.Forms.TextBox
$txtCerTextB.Location = New-Object System.Drawing.Point(20, 182)
$txtCerTextB.Size = New-Object System.Drawing.Size(780, 110)
$txtCerTextB.Multiline = $true
$txtCerTextB.ScrollBars = 'Vertical'
$txtCerTextB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnCompleteFromTextB = New-Object System.Windows.Forms.Button
$btnCompleteFromTextB.Text = 'Aus Text übernehmen'
$btnCompleteFromTextB.Location = New-Object System.Drawing.Point(20, 300)
$btnCompleteFromTextB.Size = New-Object System.Drawing.Size(200, 32)

$lblCompleteResultB = New-WizardLabel -Text '' -X 20 -Y 344 -Width 780 -Height 40

$lblSummaryB = New-WizardLabel -Text '' -X 20 -Y 390 -Width 780 -Height 190

$btnResetB = New-Object System.Windows.Forms.Button
$btnResetB.Text = 'Weitere Smartcard beantragen'
$btnResetB.Location = New-Object System.Drawing.Point(20, 590)
$btnResetB.Size = New-Object System.Drawing.Size(240, 32)

$btnStartB = New-Object System.Windows.Forms.Button
$btnStartB.Text = 'Zum Startbildschirm'
$btnStartB.Location = New-Object System.Drawing.Point(280, 590)
$btnStartB.Size = New-Object System.Drawing.Size(200, 32)

$pnlB6.Controls.AddRange(@($lblCompleteInfoB, $btnSelectCerB, $txtSelectedCerB, $btnCompleteB, $lblCerTextLabelB, $txtCerTextB, $btnCompleteFromTextB, $lblCompleteResultB, $lblSummaryB, $btnResetB, $btnStartB))

$btnSelectCerB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Zertifikatsdateien (*.cer)|*.cer|Alle Dateien (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSelectedCerB.Text = $dlg.FileName
    }
})

function Update-PlanBSummary {
    $id = Get-EnrollmentIdentity
    $matchTerm = if ($id.Upn) { $id.Upn } else { $id.SearchTerm }
    $lblSummaryB.Text = Get-CardValiditySummaryText -CardName $script:PlanB_CardName -PcscName $script:PlanB_PcscName -MatchTerm $matchTerm
}

function Complete-PlanBEnrollment {
    param([Parameter(Mandatory)][string]$CerPath)

    # Vorab prüfen, ob die Datei wirklich ein vollständiges, parsbares Zertifikat ist -
    # so gibt es bei abgeschnittenem/verunreinigtem CER (z.B. RDP-Zwischenablage) eine
    # klare Meldung statt des kryptischen CRYPT_E_ASN1_BADTAG von certreq -accept.
    try {
        $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CerPath
    } catch {
        Write-WizardLog -Message "CER-Vorprüfung fehlgeschlagen: $($_.Exception.Message)" -Level Error
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCompleteResultB.Text = 'Das ist kein vollständiges, gültiges Zertifikat (evtl. beim Kopieren über RDP abgeschnitten). Tipp: im Einreicher-Helfer mit "Speichern unter..." als Datei sichern, per RDP-Laufwerk übertragen und hier "Aus Datei übernehmen".'
        return
    }

    $complete = Complete-CertificateEnrollment -CerPath $CerPath
    if ($complete.Success) {
        $script:PlanB_CertIssued = $true
        Clear-WizardResumeState
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCompleteResultB.Text = 'Zertifikat wurde erfolgreich auf der virtuellen Smartcard hinterlegt.'
        Update-PlanBSummary
        if ($script:PlanB_RenewMode) {
            $idB = Get-EnrollmentIdentity
            Invoke-RenewalCleanup -PcscName $script:PlanB_PcscName -UpnOrTerm $(if ($idB.Upn) { $idB.Upn } else { $idB.SearchTerm })
            Update-PlanBSummary   # nach dem Aufräumen den finalen Kartenstand zeigen
        }
    } else {
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCompleteResultB.Text = 'Übernahme fehlgeschlagen. Details siehe Log.'
    }
}

$btnCompleteFromTextB.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCerTextB.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst den CER-Text einfügen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    # Das eingefügte CER genauso kanonisch säubern wie die CSR - sonst scheitert
    # 'certreq -accept' mit demselben CRYPT_E_ASN1_BADTAG durch BOM/Whitespace aus
    # dem Copy&Paste-/RDP-Round-trip. ConvertTo-CleanPemRequest erhält den PEM-Header
    # (hier CERTIFICATE) und validiert das Base64.
    $cerClean = ConvertTo-CleanPemRequest -Text $txtCerTextB.Text
    if (-not $cerClean) {
        [System.Windows.Forms.MessageBox]::Show('Der eingefügte Text ist kein gültiges Zertifikat (kein gültiges Base64-PEM). Bitte das CER aus dem Einreicher-Helfer erneut kopieren und einfügen.', 'Ungültiges Zertifikat', 'OK', 'Warning') | Out-Null
        return
    }
    $btnCompleteFromTextB.Enabled = $false
    $pastedCerPath = Join-Path (Get-WizardWorkingDir) "PlanB-pasted-$([guid]::NewGuid()).cer"
    Set-Content -Path $pastedCerPath -Value $cerClean -Encoding ASCII -NoNewline
    Complete-PlanBEnrollment -CerPath $pastedCerPath
    Remove-Item -Path $pastedCerPath -ErrorAction SilentlyContinue
    $btnCompleteFromTextB.Enabled = $true
})

$btnCompleteB.Add_Click({
    if (-not $txtSelectedCerB.Text) {
        [System.Windows.Forms.MessageBox]::Show('Bitte zuerst eine CER-Datei auswählen.', 'Hinweis', 'OK', 'Warning') | Out-Null
        return
    }
    # Auch den Datei-Weg säubern: eine als Text (PEM) gespeicherte CER-Datei kann ein
    # BOM/Encoding tragen. Reine DER-Dateien enthalten kein "BEGIN" - dann direkt nehmen.
    $cerPathToUse = $txtSelectedCerB.Text
    try {
        $rawFile = [System.IO.File]::ReadAllText($txtSelectedCerB.Text)
        if ($rawFile -match '-----BEGIN') {
            $clean = ConvertTo-CleanPemRequest -Text $rawFile
            if ($clean) {
                $cerPathToUse = Join-Path (Get-WizardWorkingDir) "PlanB-fileclean-$([guid]::NewGuid()).cer"
                Set-Content -Path $cerPathToUse -Value $clean -Encoding ASCII -NoNewline
            }
        }
    } catch { }
    $btnCompleteB.Enabled = $false
    Complete-PlanBEnrollment -CerPath $cerPathToUse
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
    $script:PlanB_RenewMode = $false
    # Aus einem Szenario gekommen -> zurück zur Startseite; sonst neuer Plan-B-Durchlauf.
    if ($script:PlanEntryFrom -eq 'Scenario') {
        $tabPlanB.Visible = $false
        Show-ScenarioStep
    } else {
        Show-PlanBStep -Index 1
    }
})

# Immer zurück zum Startbildschirm (Szenario-Auswahl) - unabhängig davon, wie der
# Ablauf betreten wurde (Szenario ODER Verlängerung aus der Inventar-/Renewal-Sicht).
$btnStartB.Add_Click({
    $script:PlanB_RenewMode = $false
    $tabPlanB.Visible = $false
    Show-ScenarioStep
})

# --- Navigation Plan B ---
# Schritt-Panels scrollbar machen, damit bei kleinerem Fenster keine Buttons
# (z.B. unten im Uebernehmen-Schritt) abgeschnitten werden - die Controls sind
# absolut positioniert, AutoScroll blendet dann bei Bedarf einen Scrollbalken ein.
@($pnlModeSelect, $pnlA1, $pnlA2, $pnlA3, $pnlA4, $pnlB1, $pnlB2, $pnlB3, $pnlB4, $pnlB5, $pnlB6) |
    ForEach-Object { $_.AutoScroll = $true }

$planBStepTitles = @('Status', 'Virtuelle Smartcard erstellen', 'CSR erstellen', 'Übergabe per RDP', 'Antrag einreichen (auf dem Server)', 'Zertifikat abschließen (lokal)')

function Update-PlanBStatus {
    $joinState = Get-DomainJoinState
    $upn = Get-CurrentUpn
    $lblJoinStateB.Text = "Domänen-Status: $($joinState.Mode)"
    $lblUserB.Text = "Angemeldeter Benutzer: $env:USERDOMAIN\$env:USERNAME" + $(if ($upn) { " (UPN: $upn)" } else { '' })
    if ($script:TargetAccount) {
        $lblTargetB.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblTargetB.Text = "Smartcard wird beantragt für: $($script:TargetAccount) (VSC/CSR trotzdem in deinem eigenen Konto)"
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
            # Kartennamen, sondern den PC/SC-Namen "Microsoft Virtual Smart Card N" -
            # deshalb prominent (fett/grün) hervorheben.
            if ($script:PlanB_PcscName) {
                $lblCsrInfoB.ForeColor = [System.Drawing.Color]::ForestGreen
                $lblCsrInfoB.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
                $lblCsrInfoB.Text = "➜ Im Windows-Kartenauswahl-Dialog die Karte `"$($script:PlanB_PcscName)`" wählen  (= '$($script:PlanB_CardName)'). Danach ggf. PIN-Dialog."
            } else {
                $lblCsrInfoB.ForeColor = [System.Drawing.SystemColors]::ControlText
                $lblCsrInfoB.Font = New-Object System.Drawing.Font('Segoe UI', 9)
                $lblCsrInfoB.Text = 'Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Es erscheint ggf. ein PIN-Dialog der Smartcard.'
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
        3 {
            # Fuer ein separates Konto wird NICHT lokal eingereicht (das liefe als
            # angemeldeter Benutzer). Der lokale Submit-Schritt (Index 4) wird daher
            # uebersprungen - eingereicht wird als das Zielkonto per Helfer auf dem
            # Server; hier geht es direkt zum "Zertifikat uebernehmen".
            if ($script:TargetAccount) { Show-PlanBStep -Index 5 } else { Show-PlanBStep -Index 4 }
        }
        4 {
            # Kein hartes Gate: wurde der Antrag anderweitig eingereicht (z.B. per
            # Einreichungshelfer in der RDP-Sitzung), gibt es auf DIESER Maschine
            # kein ausgestelltes Zertifikat - der Abschluss in Schritt 7 nimmt den
            # CER-Text per Einfügen entgegen.
            if (-not $txtCerPathB.Text) {
                $confirm = [System.Windows.Forms.MessageBox]::Show(
                    'In diesem Schritt wurde kein Zertifikat ausgestellt. Wurde der Antrag anderweitig eingereicht (z.B. mit dem Einreichungshelfer in der RDP-Sitzung) und liegt das Zertifikat als Datei oder Text vor?',
                    'Schritt überspringen', 'YesNo', 'Question')
                if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            Show-PlanBStep -Index 5
        }
    }
}

function Invoke-PlanBBackClick {
    # Verlängern-Modus (Einstieg direkt bei "CSR", Index 2): "Zurück" fuehrt zur
    # Szenario-Auswahl, nicht zum uebersprungenen Erstellen-Schritt.
    if ($script:PlanB_RenewMode -and $script:PlanBCurrentStep -eq 2) {
        $tabPlanB.Visible = $false
        Show-ScenarioStep
        return
    }
    # Separates Konto: der lokale Submit (Index 4) wird uebersprungen - "Zurück" aus
    # dem Uebernehmen-Schritt (5) fuehrt daher zurueck zur RDP-Uebergabe (3).
    if ($script:TargetAccount -and $script:PlanBCurrentStep -eq 5) {
        Show-PlanBStep -Index 3
        return
    }
    if ($script:PlanBCurrentStep -gt 0) {
        Show-PlanBStep -Index ($script:PlanBCurrentStep - 1)
    } else {
        $tabPlanB.Visible = $false
        if ($script:PlanEntryFrom -eq 'Scenario') { Show-ScenarioStep } else { Show-ModeSelectStep }
    }
}

#endregion

# ============================================================================
#region GEMEINSAME NAVIGATION (Weiter/Zurück delegieren je nach $script:ActivePlan)
# ============================================================================

$btnNextShared.Add_Click({
    switch ($script:ActivePlan) {
        'A'    { Invoke-PlanANextClick }
        'B'    { Invoke-PlanBNextClick }
        'SCEN' { Invoke-ScenarioNextClick }
        default { Invoke-ModeSelectNextClick }
    }
})

$btnBackShared.Add_Click({
    switch ($script:ActivePlan) {
        'A'    { Invoke-PlanABackClick }
        'B'    { Invoke-PlanBBackClick }
        'SCEN' { }
        default { Show-ScenarioStep }  # Mode-Select (Schritt 2) -> zurück zur Szenario-Auswahl
    }
})

#endregion

# ============================================================================
#region EINSTELLUNGEN-DIALOG (schrittunabhängig über den Button in der Kopfleiste erreichbar)
# ============================================================================
Update-Splash -Text 'Dialoge vorbereiten...' -Percent 76

function Show-VscInventoryDialog {
    param([System.Windows.Forms.Form]$Owner)

    # Die Zertifikatserkennung kann durch den Timeout-Schutz gegen hängende
    # CNG-Schlüsselzugriffe (siehe Get-SmartCardCngProviderInfo in Core.psm1) je nach
    # Anzahl der Zertifikate und ggf. verwaisten VSC-Verweisen mehrere Sekunden bis
    # niedrige zweistellige Sekunden dauern - Wartecursor als sichtbares Feedback,
    # sonst wirkt die App in dieser Zeit eingefroren.
    Set-Busy -Text 'Lese virtuelle Smartcards und Zertifikate...'
    try {
        $readers = Get-VirtualSmartCardReaders
        $certs = Get-SmartCardCertificates
    } finally { Clear-Busy }
    Write-WizardLog -Message "Smartcard-Inventar: $($readers.Count) Lesegerät(e), $($certs.Count) Zertifikat(e) mit privatem Schlüssel, davon $(@($certs | Where-Object IsSmartCard).Count) als Smartcard erkannt." -Level Info
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
    $lblReadersHeader.Text = "Erkannte Smartcard-Lesegeräte (inkl. virtueller TPM-Smartcards): $($readers.Count)"
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
    [void]$lvReaders.Columns.Add('Lesegerät', 340)
    [void]$lvReaders.Columns.Add('Status', 90)
    [void]$lvReaders.Columns.Add('Geräte-ID', 300)
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

    # Zuordnung Zertifikat -> Lesegerät über den PC/SC-Namen ("Microsoft Virtual
    # Smart Card N"): das Zertifikat meldet ihn als .Reader, das Lesegerät trägt ihn
    # als .PcscName (siehe Get-VirtualSmartCardReaders / Get-SmartCardCngProviderInfo).
    $readerPcscNames = @($readers | ForEach-Object { $_.PcscName } | Where-Object { $_ })
    $unmatchedSmartCardCerts = @($certs | Where-Object { $_.IsSmartCard -and (-not $_.Reader -or ($readerPcscNames -notcontains $_.Reader)) })
    if ($unmatchedSmartCardCerts.Count -gt 0) {
        $markerItem = New-Object System.Windows.Forms.ListViewItem("Weitere smartcard-gebundene Zertifikate (Lesegerät nicht zuordenbar, $($unmatchedSmartCardCerts.Count))")
        $markerItem.Tag = $unmatchedSmartCardMarker
        [void]$lvReaders.Items.Add($markerItem)
    }

    $otherCerts = @($certs | Where-Object { -not $_.IsSmartCard })
    if ($otherCerts.Count -gt 0) {
        $markerItem = New-Object System.Windows.Forms.ListViewItem("Sonstige Zertifikate mit privatem Schlüssel (nicht als Smartcard erkannt, $($otherCerts.Count))")
        $markerItem.Tag = $nonSmartCardMarker
        [void]$lvReaders.Items.Add($markerItem)
    }

    if ($lvReaders.Items.Count -eq 0) {
        [void]$lvReaders.Items.Add((New-Object System.Windows.Forms.ListViewItem('Keine Smartcard-Lesegeräte und keine smartcard-gebundenen Zertifikate gefunden.')))
    }

    $readerButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $readerButtonPanel.Dock = 'Fill'
    $readerButtonPanel.FlowDirection = 'LeftToRight'
    $dlgLayout.Controls.Add($readerButtonPanel, 0, 2)

    $btnDeleteReader = New-Object System.Windows.Forms.Button
    $btnDeleteReader.Text = 'Ausgewählte Smartcard löschen...'
    $btnDeleteReader.Size = New-Object System.Drawing.Size(240, 30)
    $btnDeleteReader.Enabled = $false
    $readerButtonPanel.Controls.Add($btnDeleteReader)

    $lblCertsHeader = New-Object System.Windows.Forms.Label
    $lblCertsHeader.Text = 'Zertifikate: (Lesegerät oben auswählen)'
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
    [void]$lvCerts.Columns.Add('Gültig bis', 90)
    [void]$lvCerts.Columns.Add('Thumbprint', 220)
    [void]$lvCerts.Columns.Add('Provider', 200)
    $dlgLayout.Controls.Add($lvCerts, 0, 4)

    function Update-CertListForSelection {
        $lvCerts.Items.Clear()
        if ($lvReaders.SelectedItems.Count -eq 0) {
            $lblCertsHeader.Text = 'Zertifikate: (Lesegerät oben auswählen)'
            $btnDeleteReader.Enabled = $false
            return
        }

        $selectedTag = $lvReaders.SelectedItems[0].Tag
        $matching = @()
        if ($selectedTag -and $selectedTag.PSObject.Properties['IsMarker']) {
            $btnDeleteReader.Enabled = $false
            if ($selectedTag.Kind -eq 'unmatched') {
                $lblCertsHeader.Text = 'Zertifikate: weitere smartcard-gebundene (Lesegerät nicht zuordenbar)'
                $matching = $unmatchedSmartCardCerts
            } else {
                $lblCertsHeader.Text = 'Zertifikate: sonstige mit privatem Schlüssel (nicht als Smartcard erkannt)'
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
            $certItem.Tag = $c   # Cert-Objekt fuer das gezielte Entfernen
            [void]$lvCerts.Items.Add($certItem)
        }
        if ($btnDeleteCert) { $btnDeleteCert.Enabled = $false }
    }

    $lvReaders.Add_SelectedIndexChanged({ Update-CertListForSelection })

    $btnDeleteReader.Add_Click({
        if ($lvReaders.SelectedItems.Count -eq 0) { return }
        $selectedReader = $lvReaders.SelectedItems[0].Tag
        if (-not $selectedReader -or $selectedReader.PSObject.Properties['IsMarker']) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Virtuelle Smartcard '$($selectedReader.FriendlyName)' wirklich unwiderruflich löschen?`r`n`r`nAlle darauf gespeicherten Schlüssel gehen dabei verloren. Diese Aktion kann nicht rückgängig gemacht werden.",
            'Smartcard löschen', 'YesNo', 'Warning')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnDeleteReader.Enabled = $false
        Write-WizardLog -Message "Lösche virtuelle Smartcard: $($selectedReader.FriendlyName) ($($selectedReader.InstanceId))" -Level Command
        $result = Remove-VirtualSmartCard -InstanceId $selectedReader.InstanceId
        if ($result.Success) {
            Write-WizardLog -Message "Virtuelle Smartcard gelöscht: $($selectedReader.FriendlyName)" -Level Success
            [System.Windows.Forms.MessageBox]::Show('Smartcard gelöscht.', 'Erledigt', 'OK', 'Information') | Out-Null
            $script:InventoryReopen = $true
            $dlg.Close()
        } else {
            Write-WizardLog -Message "Löschen fehlgeschlagen (Exit-Code $($result.ExitCode)): $($selectedReader.FriendlyName)" -Level Error
            [System.Windows.Forms.MessageBox]::Show("Löschen fehlgeschlagen (Exit-Code $($result.ExitCode)). Details siehe Log.", 'Fehler', 'OK', 'Error') | Out-Null
            $btnDeleteReader.Enabled = $true
        }
    })

    $dlgBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $dlgBtnPanel.Dock = 'Fill'
    $dlgBtnPanel.FlowDirection = 'RightToLeft'
    $dlgLayout.Controls.Add($dlgBtnPanel, 0, 5)

    $btnCloseInventory = New-Object System.Windows.Forms.Button
    $btnCloseInventory.Text = 'Schließen'
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
        $script:InventoryReopen = $true
        $dlg.Close()
    })

    # Einzelnes Zertifikat (Schlüssel-Container) gezielt von einer Karte entfernen.
    $btnDeleteCert = New-Object System.Windows.Forms.Button
    $btnDeleteCert.Text = 'Zertifikat von Karte entfernen...'
    $btnDeleteCert.Size = New-Object System.Drawing.Size(240, 30)
    $btnDeleteCert.Margin = New-Object System.Windows.Forms.Padding(10)
    $btnDeleteCert.Enabled = $false
    $dlgBtnPanel.Controls.Add($btnDeleteCert)

    $lvCerts.Add_SelectedIndexChanged({
        $c = if ($lvCerts.SelectedItems.Count -gt 0) { $lvCerts.SelectedItems[0].Tag } else { $null }
        # Nur aktivieren, wenn ein echtes Smartcard-Cert mit bekanntem Container gewählt ist.
        $btnDeleteCert.Enabled = [bool]($c -and $c.KeyContainerName -and $c.Provider -and $c.IsSmartCard)
    })

    $btnDeleteCert.Add_Click({
        if ($lvCerts.SelectedItems.Count -eq 0) { return }
        $c = $lvCerts.SelectedItems[0].Tag
        if (-not ($c -and $c.KeyContainerName -and $c.Provider)) {
            [System.Windows.Forms.MessageBox]::Show('Für dieses Zertifikat ist kein Schlüssel-Container/Provider bekannt - Entfernen von der Karte nicht möglich.', 'Nicht möglich', 'OK', 'Warning') | Out-Null
            return
        }
        $idLine = if ($c.Upn) { "Konto (UPN): $($c.Upn)" } else { "Subject: $($c.Subject)" }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Dieses Zertifikat samt Schlüssel UNWIDERRUFLICH von der Karte entfernen?`r`n`r`n$idLine`r`nGültig bis: $($c.NotAfter.ToString('yyyy-MM-dd'))`r`nThumbprint: $($c.Thumbprint)`r`nLesegerät: $($c.Reader)`r`n`r`nNur den zu entfernenden Eintrag bestätigen - andere Zertifikate auf der Karte bleiben unberührt. Ggf. erscheint der PIN-Dialog der Karte.",
            'Zertifikat von Karte entfernen', 'YesNo', 'Warning')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnDeleteCert.Enabled = $false
        $dlg.Cursor = 'WaitCursor'; $dlg.Refresh()
        $res = Remove-SmartCardCertificateFromCard -Provider $c.Provider -ContainerName $c.KeyContainerName -Thumbprint $c.Thumbprint
        $dlg.Cursor = 'Default'
        if ($res.Success) {
            [System.Windows.Forms.MessageBox]::Show('Zertifikat wurde von der Karte entfernt.', 'Erledigt', 'OK', 'Information') | Out-Null
            $script:InventoryReopen = $true
            $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("Entfernen fehlgeschlagen: $($res.Message) Details siehe Log.", 'Fehler', 'OK', 'Error') | Out-Null
            $btnDeleteCert.Enabled = $true
        }
    })

    # Aktualisieren/Löschen schließen den Dialog und öffnen ihn NACH Rückkehr aus
    # ShowDialog neu - sonst stapelt sich ein zweites Fenster ueber dem alten.
    $script:InventoryReopen = $false
    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    if ($script:InventoryReopen) {
        $script:InventoryReopen = $false
        Show-VscInventoryDialog -Owner $Owner
    }
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

    # Scrollbarer Inhaltsbereich für die Felder - dadurch bleibt die Speichern-Zeile
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
        # Label in Spalte 0, Eingabefeld in Spalte 1, gleiche Zeile - spart gegenüber
        # "Label über Feld" rund die Hälfte an vertikalem Platz.
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
        # Ein Control, das über beide Spalten der ganzen Zeilenbreite geht (Hinweistexte,
        # Buttons, Ergebnisboxen). -Fill für Controls ohne eigenes AutoSize (z.B. eine
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
    Add-SettingsRow -LabelText 'Zertifikatstemplate (für VSC-Anmeldung):' -InputControl $cboCfgTemplate

    $txtCfgPrefix = New-Object System.Windows.Forms.TextBox
    $txtCfgPrefix.Text = $config.VscNamePrefix
    Add-SettingsRow -LabelText 'Namenspräfix für virtuelle Smartcards:' -InputControl $txtCfgPrefix

    $numCfgPinMin = New-Object System.Windows.Forms.NumericUpDown
    $numCfgPinMin.Minimum = 4
    $numCfgPinMin.Maximum = 20
    $numCfgPinMin.Value = (Get-ConfiguredPinMinLength)
    Add-SettingsRow -LabelText 'PIN-Mindestlänge (COM: ab 6; tpmvscmgr/ARM64: /PINPOLICY):' -InputControl $numCfgPinMin

    $txtCfgJump = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgJump -Placeholder 'z.B. pki-jump.contoso.local' -Value $config.RdpJumpServer
    Add-SettingsRow -LabelText 'RDP-Zielserver für Plan B:' -InputControl $txtCfgJump

    # Editierbares Dropdown mit den beiden Standard-Smartcard-Providern: der Legacy-CSP
    # (CAPI, für V1/V2-Templates) und der CNG-KSP (für V3/V4-Templates). Die
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
    Add-SettingsRow -LabelText 'AD-Domäne / Domain Controller (PKI-Erkennung):' -InputControl $txtCfgDomain

    $lblCfgDomainHint = New-Object System.Windows.Forms.Label
    $lblCfgDomainHint.Text = 'Auf Entra-joined/Workgroup-Rechnern meist nötig, da "serverloses" LDAP-Binding ohne Domain-Join nicht funktioniert. Vorschlag aus UPN abgeleitet, ggf. abweichend vom echten AD-DNS-Namen - bei Bedarf korrigieren.'
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

    # --- Enrollment Agent (bruchfreie Ausstellung für separate Konten, ohne RDP) ---
    $lblEaHeader = New-Object System.Windows.Forms.Label
    $lblEaHeader.Text = 'Enrollment Agent (Ausstellung für separate Konten ohne RDP)'
    $lblEaHeader.AutoSize = $true
    $lblEaHeader.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblEaHeader.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 2)
    Add-SettingsFullRow -Control $lblEaHeader

    # Sicherheitshinweis: ein EA-Zertifikat, das Logon-Certs für Admin-Konten
    # ausstellen kann, ist gleichbedeutend mit "sich als diese Admins anmelden
    # können" (AD-CS-Eskalationspfad ESC3). Wer es hält, ist so privilegiert wie
    # die Zielkonten. Für Admin-Zielkonten ist Self-Enrollment als das Konto selbst
    # (Plan B) meist die sicherere Wahl; EA/EOBO nur als bewusste, möglichst
    # eingeschränkte (Restricted Enrollment Agent) und auditierte Ausnahme.
    $lblEaWarn = New-Object System.Windows.Forms.Label
    $lblEaWarn.Text = 'Achtung: Ein EA-Zertifikat, mit dem sich Logon-Certs für Admins ausstellen lassen, ist admin-äquivalent (Eskalationspfad ESC3) - wer es besitzt, kann sich als diese Konten anmelden. Für Admin-Zielkonten ist Self-Enrollment als das Konto selbst (Plan B) meist sicherer. EA/EOBO nur bewusst, eingeschränkt (Restricted Enrollment Agent) und auditiert einsetzen; EA-Schlüssel auf Hardware/VSC halten.'
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
        $lblEaStatus.Text = "EA-Zertifikat vorhanden: $($eaCertsNow[0].Subject) (gültig bis $($eaCertsNow[0].NotAfter.ToString('yyyy-MM-dd'))). Damit kann für separate Konten bruchfrei per Plan A ausgestellt werden."
    } else {
        $lblEaStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblEaStatus.Text = 'Kein EA-Zertifikat gefunden. Ohne EA-Zertifikat muss für separate Konten der Plan-B/RDP-Weg genutzt werden.'
    }
    Add-SettingsFullRow -Control $lblEaStatus

    $txtCfgEaTemplate = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgEaTemplate -Placeholder 'z.B. EnrollmentAgent' -Value $config.EATemplate
    Add-SettingsRow -LabelText 'EA-Zertifikatstemplate:' -InputControl $txtCfgEaTemplate

    $chkEaOnVsc = New-Object System.Windows.Forms.CheckBox
    $chkEaOnVsc.Text = 'EA-Schlüssel auf eigener VSC (TPM/PIN) statt Software-Schlüssel'
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
        $lblEaResult.Text = 'Beantrage EA-Zertifikat für das eigene Konto...'
        $dlg.Refresh()

        $result = Invoke-EnrollmentAgentRequest -Template $eaTemplate -OnVsc:$chkEaOnVsc.Checked
        if ($result.Success) {
            $lblEaResult.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblEaResult.Text = 'EA-Zertifikat wurde ausgestellt. Es steht ab sofort für die Ausstellung an separate Konten (Plan A) zur Verfügung.'
            $eaNow = @(Get-EnrollmentAgentCertificates)
            if ($eaNow.Count -gt 0) {
                $lblEaStatus.ForeColor = [System.Drawing.Color]::ForestGreen
                $lblEaStatus.Text = "EA-Zertifikat vorhanden: $($eaNow[0].Subject) (gültig bis $($eaNow[0].NotAfter.ToString('yyyy-MM-dd')))."
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
    $btnCloseSettings.Text = 'Schließen'
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
        $txtDiscoverResultCfg.Text = 'Prüfe PKI-Erreichbarkeit (bis zu ca. 40 Sekunden)...'
        $dlg.Refresh()

        $modulePath = $script:ModulePath
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
            $txtDiscoverResultCfg.Text = 'Zeitüberschreitung (>40s). Domäne/DC-Feld prüfen oder Netzwerkverbindung (VPN/Private Access) sicherstellen.'
            Write-WizardLog -Message 'Automatische Erkennung: Zeitüberschreitung.' -Level Error
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

            $txtDiscoverResultCfg.Text = "$($reachData.ReachableCas.Count) erreichbare CA(s) gefunden und übernommen - bitte Template prüfen (Dropdown-Pfeil zeigt alle $($allTemplates.Count) auf der CA verfügbaren Templates) und Speichern:`r`n" + (($reachData.ReachableCas | ForEach-Object { "- $($_.Name) ($($_.ConfigString))" }) -join "`r`n")
            Write-WizardLog -Message "Automatische Erkennung: $($reachData.ReachableCas.Count) erreichbare CA(s) gefunden." -Level Success
        } elseif ($reachData.AllCas.Count -gt 0) {
            $txtDiscoverResultCfg.Text = "$($reachData.AllCas.Count) CA(s) in AD gefunden, aber per RPC nicht erreichbar (Firewall/Netzwerksegmentierung?):`r`n" + ($reachData.UnreachableCas -join "`r`n")
            Write-WizardLog -Message "Automatische Erkennung: $($reachData.AllCas.Count) CA(s) gefunden, keine per RPC erreichbar." -Level Info
        } elseif ($reachData.DiscoveryError) {
            $txtDiscoverResultCfg.Text = "LDAP-Erkennung fehlgeschlagen: $($reachData.DiscoveryError)`r`n`r`nTipp: Domäne/DC-Feld oben prüfen (z.B. expliziten DC-Namen statt DNS-Domäne versuchen) und Netzwerkverbindung (VPN/Private Access) sicherstellen."
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
            PinMinLength  = [int]$numCfgPinMin.Value
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

Update-Splash -Text 'Umgebung erkennen (TPM, Kerberos, Karten)...' -Percent 80
Show-ScenarioStep
Update-Splash -Text 'Fertig.' -Percent 100

function Invoke-WizardResume {
    # Begonnenen Antrag aus einer frueheren Sitzung wieder aufnehmen (siehe
    # Save-WizardResumeState in Core.psm1): stellt die Wizard-Variablen wieder her
    # und springt direkt zum passenden Schritt.
    $state = Get-WizardResumeState
    if (-not $state) { return }

    $stageText = if ($state['Stage'] -eq 'Pending') { "Antrag eingereicht, wartet auf Genehmigung (RequestId $($state['RequestId']))" } else { 'CSR erstellt, noch nicht eingereicht' }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Ein begonnener Antrag vom $($state['SavedAt']) wurde gefunden:`r`n`r`nKarte: $($state['CardName'])`r`nStand: $stageText`r`n`r`nFortsetzen? (Bei 'Nein' wird der gespeicherte Stand verworfen - der offene Antrag im Zertifikatsspeicher bleibt davon unberührt.)",
        'Begonnenen Antrag fortsetzen', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Clear-WizardResumeState
        Write-WizardLog -Message 'Gespeicherter Antrags-Stand verworfen.' -Level Info
        return
    }

    if ($state['TargetAccount']) { $script:TargetAccount = $state['TargetAccount'] } else { $script:TargetAccount = $null }
    $pnlScenario.Visible = $false
    $pnlModeSelect.Visible = $false

    if ($state['Plan'] -eq 'A') {
        $script:ActivePlan = 'A'
        $script:PlanA_VscCreated = $true
        $script:PlanA_CardName = $state['CardName']
        $script:PlanA_PcscName = $state['PcscName']
        $script:PlanA_EnrollDir = $state['EnrollDir']
        $script:PlanA_PendingRequestId = $state['RequestId']
        $tabPlanA.Visible = $true
        Show-PlanAStep -Index 1   # "Zertifikat anfordern" (Retrieve-Button dort)
        $btnRetrieveA.Visible = $true
        $lblCertResultA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblCertResultA.Text = "Fortgesetzter Antrag (RequestId $($state['RequestId'])) - über 'Zertifikat abrufen' prüfen, ob er inzwischen genehmigt wurde."
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
            $lblSubmitResultB.Text = "Fortgesetzter Antrag (RequestId $($state['RequestId'])) - über 'Zertifikat abrufen' prüfen, ob er inzwischen genehmigt wurde."
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
    # Erst öffnen, sobald das Hauptfenster tatsächlich angezeigt wird (Shown-Event) -
    # ein modaler Dialog mit -Owner vor dem ersten Show() des Owners führt sonst zu
    # unzuverlässigem Fensterverhalten.
    $form.Add_Shown({ Show-SettingsDialog -Owner $form })
} else {
    # Fortsetzen-Angebot nur, wenn nicht ohnehin zuerst die Einstellungen zu
    # pflegen sind; ebenfalls erst nach dem Shown-Event (modaler Dialog).
    $form.Add_Shown({ Invoke-WizardResume })
}

# Splash SICHER schliessen, BEVOR das Hauptfenster modal geoeffnet wird. NICHT aus dem
# Shown-Event heraus schliessen: ein noch offenes TopMost-Fenster, das man mitten im
# Shown disposed, kann die Aktivierung des Hauptfensters/der Folgedialoge stoeren
# ("kein Dialog danach"). Die Luecke bis ShowDialog ist minimal.
Close-Splash

[void]$form.ShowDialog()

#endregion
