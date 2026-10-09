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

# Automatisierungs-/Rollout-Schalter (siehe docs/intune-rollout.md). Ohne Schalter
# startet der normale interaktive Wizard - das Verhalten ist unverändert.
param(
    [switch]$Provision,   # nur VSC anlegen (Systemkontext / Intune-App 1), KEINE GUI
    [switch]$Silent,      # zusammen mit -Provision: bewusst ohne Fenster (Default für Provision)
    [switch]$Simple,      # schlanker Assistent (Benutzerkontext / Intune-App 2): PIN ändern -> ausstellen
    [string]$CardName,    # optionaler VSC-Name (Default: VscNamePrefix + Computername)
    [string]$Pin,         # optionale Start-PIN (Default: aus Computername abgeleitet); nur mit -Provision
    # Per-Benutzer-Karten (Variante 2, docs/intune-rollout.md):
    [switch]$Install,         # Intune-App (SYSTEM): Wizard nach %ProgramFiles%, Aufgaben + Auftragsordner anlegen
    [switch]$Uninstall,       # Gegenstück (Karten bleiben erhalten)
    [switch]$ProcessRequests, # SYSTEM-Aufgabe "VSC-Wizard CreateCard": Aufträge abarbeiten
    [switch]$AutoStart        # Anmelde-Aufgabe: -Simple, aber still beenden, wenn nichts zu tun ist
)

$script:SimpleMode = [bool]($Simple -or $AutoStart)
$script:HeadlessMode = [bool]($Provision -or $Install -or $Uninstall -or $ProcessRequests)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

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

# Programm-Icon für alle Fenster: als EXE das eingebettete Symbol (build.ps1), als Skript
# assets\VscWizard.ico aus dem Repo. Fehlt beides, bleibt das Standard-Symbol.
$script:AppIcon = $null
try {
    $selfExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($selfExe -notmatch '\\(powershell|pwsh)\.exe$') { $script:AppIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($selfExe) }
    elseif (Test-Path (Join-Path $script:BaseDir 'assets\VscWizard.ico')) { $script:AppIcon = New-Object System.Drawing.Icon((Join-Path $script:BaseDir 'assets\VscWizard.ico')) }
} catch { }
# Großes Kartenbild (256-px-PNG, build.ps1 legt es neben die EXE) für die Schritt-Seiten;
# sonst das Programm-Icon.
$script:CardImage = $null
foreach ($img in @((Join-Path $script:BaseDir 'VscWizard.png'), (Join-Path $script:BaseDir 'assets\VscWizard.png'))) {
    if (-not $script:CardImage -and (Test-Path $img)) { try { $script:CardImage = [System.Drawing.Image]::FromFile($img) } catch { } }
}
if (-not $script:CardImage -and $script:AppIcon) { try { $script:CardImage = $script:AppIcon.ToBitmap() } catch { } }

# --- Sprache GANZ AM ANFANG festlegen (einzige Entscheidung, gilt für alles) ---------
# Der Splash läuft vor dem Laden des Kernmoduls (wo T/Übersetzungen leben) - daher hier:
#   1. VSCWIZARD_LANG (Tests)  2. 'Language' aus config.psd1 (Wahl über den Umschalter)
#   3. Windows-Anzeigesprache: Deutsch -> de, sonst en.
$script:StartLang = $env:VSCWIZARD_LANG
if (-not $script:StartLang) {
    try { $script:StartLang = (Import-PowerShellDataFile -Path (Join-Path $script:BaseDir 'config.psd1') -ErrorAction Stop).Language } catch { }
}
if (-not $script:StartLang) {
    $script:StartLang = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'de') { 'de' } else { 'en' }
}
$script:StartLang = if ("$script:StartLang" -match '^en') { 'en' } else { 'de' }
# Texte VOR dem Modul-Import (Splash, Startfehler): zweisprachig direkt.
function L([string]$De, [string]$En) { if ($script:StartLang -eq 'en') { $En } else { $De } }

# --- Splash / Start-Fortschritt ---------------------------------------------------
# Der Start dauert mehrere Sekunden (Modul laden, Fenster bauen, Umgebung erkennen via
# TPM/Kerberos/PnP/Zertifikatsspeicher). Ohne Rueckmeldung wirkt das wie eine Blackbox.
# Deshalb sofort einen kleinen Splash zeigen und an den Meilensteinen aktualisieren.
function Show-SplashScreen {
    $sp = New-Object System.Windows.Forms.Form
    if ($script:AppIcon) { $sp.Icon = $script:AppIcon }
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
    $sub.UseMnemonic = $false   # sonst verschluckt WinForms das "&"
    $sub.Text = L 'Virtuelle Smartcards & Zertifikate' 'Virtual smart cards & certificates'
    $sub.ForeColor = [System.Drawing.Color]::FromArgb(150, 170, 190)
    $sub.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $sub.Location = New-Object System.Drawing.Point(26, 58)
    $sub.Size = New-Object System.Drawing.Size(392, 20)
    $sp.Controls.Add($sub)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = L 'Starte...' 'Starting...'
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

# Kein Splash für die fensterlosen Modi und den Anmelde-Autostart (der sich oft still beendet).
if (-not ($script:HeadlessMode -or $AutoStart)) { $null = Show-SplashScreen }

Update-Splash -Text (L 'Kernmodul laden...' 'Loading core module...') -Percent 25
# Ausführungsrichtlinie NUR für diesen Prozess (Bereich "Process") freigeben: Die EXE lädt
# ihr Kernmodul als .psm1 nach - unter der Windows-Standardrichtlinie "Restricted"
# (frische Clients) wird das sonst blockiert. Über die Umgebungsvariable gilt das auch für
# Start-Job-Hintergrundaufträge und Kindprozesse. Systemweit ändert sich nichts.
# (Unter Intune/PSADT fiel es nicht auf: dort erben Kindprozesse bereits "Bypass".)
$env:PSExecutionPolicyPreference = 'Bypass'
$script:ModulePath = Join-Path $script:BaseDir 'modules\VscWizard.Core.psm1'
if (-not (Test-Path $script:ModulePath)) {
    Close-Splash
    [System.Windows.Forms.MessageBox]::Show(
        ((L "Das Kernmodul wurde nicht gefunden:`r`n{0}`r`n`r`nDie Datei/EXE braucht den Ordner 'modules\' UND 'config.psd1' DIREKT DANEBEN.`r`n`r`nSo startest du richtig:`r`n - Aus dem geklonten Repo: VscWizard.bat doppelklicken (nicht eine einzelne .exe kopieren).`r`n - Als EXE: '.\build.ps1' ausführen und die EXE aus 'dist\' zusammen mit dem dort erzeugten Ordner 'modules\' und 'config.psd1' verwenden." "The core module was not found:`r`n{0}`r`n`r`nThe file/EXE needs the folder 'modules\' AND 'config.psd1' RIGHT NEXT TO IT.`r`n`r`nHow to start it correctly:`r`n - From the cloned repo: double-click VscWizard.bat (do not copy a single .exe).`r`n - As EXE: run '.\build.ps1' and use the EXE from 'dist\' together with the 'modules\' folder and 'config.psd1' created there.") -f $script:ModulePath),
        (L 'VSC-Wizard - Start fehlgeschlagen' 'VSC Wizard - start failed'), 'OK', 'Error') | Out-Null
    exit 1
}
$script:ModuleLoadError = $null
try {
    Import-Module $script:ModulePath -Force -ErrorAction Stop
} catch [System.Management.Automation.PSSecurityException] {
    # Gruppenrichtlinie erzwingt eine strengere Richtlinie (z.B. AllSigned) - der Bereich
    # "Process" greift dann nicht. Rückfall: Modul aus dem Dateiinhalt laden.
    try {
        $env:VSCWIZARD_MODULEDIR = Split-Path -Parent $script:ModulePath
        $coreText = [IO.File]::ReadAllText($script:ModulePath, [Text.Encoding]::UTF8)
        New-Module -Name 'VscWizard.Core' -ScriptBlock ([scriptblock]::Create($coreText)) | Import-Module -Force -ErrorAction Stop
    } catch { $script:ModuleLoadError = $_ }
} catch { $script:ModuleLoadError = $_ }
if ($script:ModuleLoadError) {
    $_ = $script:ModuleLoadError
    Close-Splash
    [System.Windows.Forms.MessageBox]::Show(
        ((L "Das Kernmodul konnte nicht geladen werden:`r`n{0}`r`n`r`nPfad: {1}" "The core module could not be loaded:`r`n{0}`r`n`r`nPath: {1}") -f $_.Exception.Message, $script:ModulePath),
        (L 'VSC-Wizard - Start fehlgeschlagen' 'VSC Wizard - start failed'), 'OK', 'Error') | Out-Null
    exit 1
}

Update-Splash -Text (L 'Konfiguration lesen...' 'Reading configuration...') -Percent 40
$script:ConfigPath = Join-Path $script:BaseDir 'config.psd1'
# Fehlt config.psd1 (z.B. nur die EXE ohne Beiwerk kopiert), NICHT abstürzen: mit
# leerer Konfiguration starten - der Wizard öffnet dann den Einstellungen-Tab.
try {
    $config = Import-VscWizardConfig -Path $script:ConfigPath
} catch {
    $config = @{}
}
# Einstellung "Auch andere Smartcards" auch für Kernfunktionen ohne $config.
Set-VscPhysicalCardsAllowed -Allowed (Test-PhysicalCardsAllowed -Config $config)
# Sprache der Oberfläche: die EINE Entscheidung vom Skriptanfang ($script:StartLang).
Set-WizardLanguage -Language $script:StartLang

# --- Provisionierungs-Modus (Intune-App 1, Systemkontext): still eine leere VSC anlegen
#     und beenden - OHNE die GUI zu bauen. Muss VOR dem Fensteraufbau stehen. ------------
function Invoke-VscProvision {
    # Legt eine leere VSC mit einer aus dem Computernamen abgeleiteten Start-PIN an.
    # Exit-Codes: 0 ok, 1 Erstellung fehlgeschlagen, 3 nicht eleviert. Log zusätzlich in
    # C:\ProgramData\VSC-Wizard\provision.log (für die Intune-Diagnose).
    $logDir = Join-Path $env:ProgramData 'VSC-Wizard'
    try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch { }
    $logFile = Join-Path $logDir 'provision.log'
    $plog = { param($m) try { Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m) -Encoding UTF8 } catch { } }
    try { Initialize-WizardLog -LogBox $null } catch { }   # Kernmodul-Logs in die Tagesdatei

    $name = if ($CardName) { $CardName } else { Get-VscProvisionCardName -Config $config }
    $minLen = 6
    if ($config.PinMinLength) { $minLen = [int]$config.PinMinLength }
    if ($minLen -lt 4) { $minLen = 4 }; if ($minLen -gt 20) { $minLen = 20 }
    $startPin = if ($Pin) { $Pin } else { Get-VscBootstrapPin -MinLength $minLen }

    & $plog "Provision start: Karte='$name', MinPinLen=$minLen, Simple-Folgeschritt via App 2."
    if (-not (Test-IsElevated)) {
        & $plog 'FEHLER: nicht eleviert - Provisionierung muss als Admin/SYSTEM laufen (Intune-Device-App).'
        return 3
    }
    try {
        $res = New-VirtualSmartCard -CardName $name -PinPolicyMinLength $minLen -Pin $startPin
    } catch {
        & $plog "AUSNAHME: $($_.Exception.Message)"
        return 1
    }
    if ($res -and $res.Success) {
        Set-VscProvisionMarker -InstanceId "$($res.InstanceId)" | Out-Null
        & $plog "OK: VSC '$name' erstellt (InstanceId $($res.InstanceId), PC/SC '$($res.PcscName)'). Marker HKLM gesetzt."
        return 0
    }
    & $plog "FEHLER: VSC-Erstellung fehlgeschlagen: $(if ($res) { $res.Message } else { 'kein Ergebnis' })"
    return 1
}

if ($Provision) {
    exit (Invoke-VscProvision)
}
# Per-Benutzer-Karten (Variante 2): fensterlose Modi für Intune und die SYSTEM-Aufgabe.
if ($Install) { exit (Install-VscCardService -SourceDir $script:BaseDir -ShortcutName (L 'Smartcard einrichten' 'Set up smart card')) }   # Startmenü in Konfigurations-/Gerätesprache
if ($Uninstall) { exit (Uninstall-VscCardService) }
if ($ProcessRequests) {
    try { Initialize-WizardLog -LogBox $null } catch { }
    $maxCards = if ($config.MaxVscPerDevice) { [int]$config.MaxVscPerDevice } else { 10 }
    [void](Invoke-VscCardRequests -Config $config -MaxCards $maxCards)
    exit 0
}
if ($AutoStart) {
    # Anmelde-Aufgabe: nur öffnen, wenn es etwas zu tun gibt (sonst still beenden).
    try { Initialize-WizardLog -LogBox $null } catch { }
    $need = Test-VscAutoStartNeeded -Config $config
    if (-not $need.Needed) { Write-WizardLog -Message "Autostart: nichts zu tun - $($need.Reason)." -Level Info; exit 0 }
    Write-WizardLog -Message 'Autostart: Einrichtung nötig - Assistent wird geöffnet.' -Level Info
}

Update-Splash -Text (T 'Oberfläche wird aufgebaut...') -Percent 55

function New-CardPicture {
    # Großes Kartensymbol (96 px) für die Schritt-Seiten mit Kartenbezug.
    param([int]$X, [int]$Y, [int]$Size = 96)
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Location = New-Object System.Drawing.Point($X, $Y); $pb.Size = New-Object System.Drawing.Size($Size, $Size)
    $pb.SizeMode = 'Zoom'; $pb.BackColor = [System.Drawing.Color]::Transparent
    if ($script:CardImage) { $pb.Image = $script:CardImage }
    return $pb
}

function Get-VscCardCount {
    # Anzahl virtueller Smartcards: erst ab ZWEI zeigt Windows einen Kartenauswahl-Dialog -
    # nur dann ist der Hinweis "Karte ... wählen" sinnvoll (bei einer Karte verwirrt er).
    # Mit "andere Smartcards" zählen eingesteckte geeignete Karten mit.
    try { return @(Get-SmartCardTargets -Config $config).Count } catch { return 0 }
}

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
    $lbl.Font = if ($Style -eq [System.Drawing.FontStyle]::Bold) { New-UiFont 9.5 -Semibold } else { New-UiFont 9.5 }
    $lbl.ForeColor = $script:UI.Text
    $lbl.UseMnemonic = $false
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
function Resolve-PendingRequestId {
    # "Zertifikat abrufen" ohne bekannte Request-ID (z.B. Antrag von einer älteren
    # Wizard-Version, deren ID nicht erkannt wurde, oder außerhalb eingereicht): statt
    # stumm nichts zu tun, die ID abfragen. Liefert die ID oder $null (abgebrochen).
    param(
        [string]$RequestId,
        # Für Anträge, die NICHT zum Plan-A/B-Fortsetzungsstand gehören (EA-Zertifikat).
        [switch]$NoResumeState
    )
    if ($RequestId) { return $RequestId }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $entered = [Microsoft.VisualBasic.Interaction]::InputBox((T 'Die Request-ID des wartenden Antrags ist nicht bekannt. Bitte die ID eingeben (steht im Log bzw. in der CA-Konsole unter "Ausstehende Anforderungen"):'), (T 'Request-ID eingeben'), '')
    if ("$entered".Trim() -match '^\d+$') {
        $id = "$entered".Trim()
        # Im gespeicherten Fortsetzungs-Stand nachtragen - sonst fragt der nächste Start erneut.
        $state = if ($NoResumeState) { $null } else { Get-WizardResumeState }
        if ($state -and $state['Stage'] -eq 'Pending' -and -not $state['RequestId']) {
            $state['RequestId'] = $id
            Save-WizardResumeState -State $state
        }
        return $id
    }
    if ("$entered".Trim()) {
        [System.Windows.Forms.MessageBox]::Show((T 'Die Request-ID ist eine Zahl (z.B. 932).'), (T 'Ungültige Eingabe'), 'OK', 'Warning') | Out-Null
    }
    return $null
}

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
            $vscMsg = if ($vsc.Cancelled) { (T 'VSC-Erstellung für EA-Zertifikat abgebrochen.') } else { (T 'VSC-Erstellung für EA-Zertifikat fehlgeschlagen.') }
            return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $null; Message = $vscMsg }
        }
        $csp = $config.CspName
    } else {
        # CNG-Software-KSP: kein Smartcard-Provider, kein PIN.
        $csp = 'Microsoft Software Key Storage Provider'
    }

    $csr = New-CertificateSigningRequest -Subject $identity.Subject -Upn $identity.Upn -CspName $csp -OutputDirectory $enrollDir
    if (-not $csr.Success) {
        return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $null; Message = (T 'Antragserstellung fehlgeschlagen.') }
    }

    $submit = Submit-CertificateSigningRequest -CsrPath $csr.CsrPath -CAConfig $config.CAConfig -TemplateName $Template -OutputDirectory $enrollDir
    if ($submit.Pending) {
        return [pscustomobject]@{ Success = $false; Pending = $true; RequestId = $submit.RequestId; Message = (T 'Wartet auf Genehmigung.') }
    }
    if (-not $submit.Success) {
        return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $submit.RequestId; Message = (T 'Antrag bei der CA fehlgeschlagen.') }
    }

    $complete = Complete-CertificateEnrollment -CerPath $submit.CerPath
    if ($complete.Success) {
        return [pscustomobject]@{ Success = $true; Pending = $false; RequestId = $submit.RequestId; Message = '' }
    }
    return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $submit.RequestId; Message = (T 'Übernahme des EA-Zertifikats fehlgeschlagen.') }
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

function Update-OfflineTemplateChoices {
    # Szenario 03 ohne konfiguriertes OfflineTemplate: die auf der CA veröffentlichten
    # Templates aus AD lesen (wie "PKI automatisch erkennen") und die Supply-in-request-
    # fähigen in die (weiterhin editierbare) Combo legen. Ergebnis pro Sitzung gecacht;
    # Abfrage im Hintergrund-Job mit Timeout (max. 15 s mit Banner), damit ein nicht
    # erreichbarer DC die GUI nicht unbegrenzt blockiert.
    if (-not $script:PlanA_OfflineDirect -or $config.OfflineTemplate) { return }

    $c = $script:OfflineTemplateCandidates
    # Ein Fehlschlag (DC nicht erreichbar) wird 2 Minuten gemerkt: Zurück/Weiter soll nicht
    # jedes Mal erneut bis zum Timeout blockieren (der Job-Wait läuft im UI-Thread).
    if (-not $c -and $script:OfflineTemplateFailure -and ((Get-Date) - $script:OfflineTemplateFailure.At).TotalSeconds -lt 120) {
        $c = $script:OfflineTemplateFailure.Result
    }
    if (-not $c) {
        $modulePath = $script:ModulePath
        $c = Invoke-Busy -Text (T 'Lese Zertifikatstemplates der CA...') -Action {
            $job = Start-Job -ScriptBlock {
                param($ModulePath, $Server, $CAConfig)
                Import-Module $ModulePath -Force
                Get-OfflineTemplateCandidates -Server $Server -CAConfig $CAConfig -TimeoutSeconds 8
            } -ArgumentList $modulePath, $config.DiscoveryDomain, $config.CAConfig
            $data = $null; $jobErr = $null
            if (Wait-Job -Job $job -Timeout 15) {
                $data = Receive-Job -Job $job -ErrorVariable jobErr -ErrorAction SilentlyContinue
                if (-not $data) { $data = [pscustomobject]@{ Templates = @(); CaName = $null; Error = "AD-Abfrage fehlgeschlagen: $(@($jobErr)[0])" } }
            } else {
                Stop-Job -Job $job
                $data = [pscustomobject]@{ Templates = @(); CaName = $null; Error = (T 'Zeitüberschreitung bei der AD-Abfrage (DC erreichbar? VPN?).') }
            }
            Remove-Job -Job $job -Force
            $data
        }
        # Erfolg für die Sitzung cachen; Fehlschlag nur kurz (s.o.) - nach VPN-Aufbau o.ä.
        # soll ein späteres Betreten des Schritts es noch einmal versuchen.
        if (@($c.Templates).Count -gt 0) { $script:OfflineTemplateCandidates = $c }
        else { $script:OfflineTemplateFailure = [pscustomobject]@{ At = Get-Date; Result = $c } }
        $supplyNames = @($c.Templates | Where-Object { $_.SuppliesSubject -and ($_.SmartCardLogon -or $_.ClientAuth) -and -not $_.KdcAuth } | ForEach-Object { $_.Name })
        Write-WizardLog -Message "Offline-Templates: $(@($c.Templates).Count) auf der CA ($($c.CaName)) veröffentlicht, davon Supply-in-request: $(if ($supplyNames) { $supplyNames -join ', ' } else { 'keines' })$(if ($c.Error) { " - $($c.Error)" })." -Level Info
    }

    # Bevorzugt Supply-in-request + Smartcard-Anmeldung; gibt es keins, dann
    # Supply-in-request + Client-Authentifizierung (reicht für Entra CBA).
    # DC-Templates (KDC-Authentifizierung) nie anbieten.
    $supply = @($c.Templates | Where-Object { $_.SuppliesSubject -and $_.SmartCardLogon -and -not $_.KdcAuth })
    if ($supply.Count -eq 0) { $supply = @($c.Templates | Where-Object { $_.SuppliesSubject -and $_.ClientAuth -and -not $_.KdcAuth }) }
    $typed = $cboTemplateA.Text
    $cboTemplateA.Items.Clear()
    foreach ($t in $supply) { [void]$cboTemplateA.Items.Add($t.Name) }
    if ($typed) {
        $cboTemplateA.Text = $typed
    } elseif ($supply.Count -eq 1) {
        $cboTemplateA.SelectedIndex = 0
    }

    $lblTemplateHintA.ForeColor = [System.Drawing.Color]::DimGray
    if ($supply.Count -ge 1) {
        $lblTemplateHintA.Text = ((T '{0} Supply-in-request-Template(s) auf der CA gefunden - bitte auswählen (dauerhaft: Einstellungen > Offline-Template).') -f $supply.Count)
    } elseif (@($c.Templates).Count -gt 0) {
        $lblTemplateHintA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblTemplateHintA.Text = (T 'Auf der CA ist kein Anmelde-Template mit "Informationen im Antrag angeben" veröffentlicht - Namen bitte eintippen (dauerhaft: Einstellungen > Offline-Template).')
    } else {
        $lblTemplateHintA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblTemplateHintA.Text = ((T 'Templates nicht ermittelbar{0} - Namen bitte eintippen (dauerhaft: Einstellungen > Offline-Template).') -f $(if ($c.Error) { " ($($c.Error))" } else { '' }))
    }
    $lblTemplateHintA.Visible = $true
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
        $lblTemplateHintA.Visible = -not $config.OfflineTemplate
    } else {
        $cboTemplateA.DropDownStyle = 'DropDownList'
        Set-TemplateComboItem -ComboBox $cboTemplateA -Template $config.Template
        $lblTemplateHintA.Visible = $false
    }
}

#region MAIN FORM

# --- Gestaltung (Redesign 2026-09): eine Palette, wenige Helfer -------------------
# Alle Farben/Schriften an EINER Stelle - Controls greifen nur über $script:UI bzw.
# die Helfer darauf zu, damit das Erscheinungsbild konsistent bleibt.
function New-UiColor([int]$R, [int]$G, [int]$B) { [System.Drawing.Color]::FromArgb($R, $G, $B) }
$script:UI = @{
    Ground      = New-UiColor 245 246 248   # Fensterhintergrund
    Surface     = [System.Drawing.Color]::White
    Sidebar     = New-UiColor 236 239 243
    Border      = New-UiColor 216 221 227
    Control     = New-UiColor 174 182 191   # Rahmen von Buttons/Eingaben
    Text        = New-UiColor 27 31 36
    Muted       = New-UiColor 87 96 106
    Accent      = New-UiColor 11 92 173
    AccentHover = New-UiColor 8 70 127
    AccentWeak  = New-UiColor 232 241 251
    AccentText  = New-UiColor 11 58 107
    Success     = New-UiColor 30 107 58
    SuccessWeak = New-UiColor 230 244 234
    Warn        = New-UiColor 122 75 0
    WarnWeak    = New-UiColor 255 243 214
    Danger      = New-UiColor 165 38 27
    DangerWeak  = New-UiColor 253 236 234
    Disabled    = New-UiColor 201 214 228
}
function New-UiFont {
    param([float]$Size = 9, [switch]$Semibold, [switch]$Mono)
    $family = if ($Mono) { 'Consolas' } elseif ($Semibold) { 'Segoe UI Semibold' } else { 'Segoe UI' }
    New-Object System.Drawing.Font($family, $Size)
}
function Set-ButtonStyle {
    # Primary = gefüllte Akzentfarbe (Hauptaktion), Secondary = weiß mit Rahmen,
    # Link = randlos/transparent (z.B. "Protokoll anzeigen").
    param([Parameter(Mandatory)][System.Windows.Forms.Button]$Button, [ValidateSet('Primary', 'Secondary', 'Link')][string]$Kind = 'Secondary')
    $Button.FlatStyle = 'Flat'
    $Button.UseVisualStyleBackColor = $false
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Tag = if ($Button.Tag -is [hashtable]) { $Button.Tag } else { @{} }
    $Button.Tag['Kind'] = $Kind
    switch ($Kind) {
        'Primary' {
            $Button.BackColor = $script:UI.Accent; $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderSize = 0
            $Button.FlatAppearance.MouseOverBackColor = $script:UI.AccentHover
            $Button.Font = New-UiFont 9.5 -Semibold
        }
        'Secondary' {
            $Button.BackColor = $script:UI.Surface; $Button.ForeColor = $script:UI.Text
            $Button.FlatAppearance.BorderSize = 1; $Button.FlatAppearance.BorderColor = $script:UI.Control
            $Button.FlatAppearance.MouseOverBackColor = $script:UI.Ground
            $Button.Font = New-UiFont 9.5
        }
        'Link' {
            $Button.BackColor = [System.Drawing.Color]::Transparent; $Button.ForeColor = $script:UI.Muted
            $Button.FlatAppearance.BorderSize = 0
            $Button.FlatAppearance.MouseOverBackColor = $script:UI.Ground
            $Button.Font = New-UiFont 9
        }
    }
}
# Deaktivierte Flat-Buttons zeichnet WinForms grau auf grau - Primärbuttons bekommen
# deshalb beim Deaktivieren eine eigene, lesbare Farbe.
function Update-PrimaryEnabledLook([System.Windows.Forms.Button]$Button) {
    if ($Button.Tag -is [hashtable] -and $Button.Tag['Kind'] -eq 'Primary') {
        $Button.BackColor = if ($Button.Enabled) { $script:UI.Accent } else { $script:UI.Disabled }
    }
}
function Set-DialogStyle {
    # Dialoge an das Hauptfenster angleichen (vor ShowDialog aufrufen): Schrift, und alle
    # Buttons im neuen Stil - die Standard-Schaltfläche (AcceptButton) als Primary.
    param([Parameter(Mandatory)][System.Windows.Forms.Form]$Dialog)
    if ($script:AppIcon) { $Dialog.Icon = $script:AppIcon }   # Programm-Icon auch in Dialogen
    $walk = {
        param($root)
        foreach ($c in $root.Controls) {
            if ($c -is [System.Windows.Forms.Button] -and -not ($c.Tag -is [hashtable] -and $c.Tag['Kind'])) {
                $kind = if ($Dialog.AcceptButton -and [object]::ReferenceEquals($Dialog.AcceptButton, $c)) { 'Primary' } else { 'Secondary' }
                Set-ButtonStyle -Button $c -Kind $kind
            }
            if ($c.HasChildren) { & $walk $c }
        }
    }
    & $walk $Dialog
}

function Add-BorderPaint {
    # 1-px-Rahmen in Palettenfarbe (BorderStyle kann keine Farbe) - für "Karten".
    param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control, [System.Drawing.Color]$Color = $script:UI.Border, [switch]$TopOnly)
    $Control.Tag = if ($Control.Tag -is [hashtable]) { $Control.Tag } else { @{ Value = $Control.Tag } }
    $Control.Tag['BorderColor'] = $Color
    $Control.Tag['BorderTopOnly'] = [bool]$TopOnly
    $Control.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($s.Tag['BorderColor'])
        if ($s.Tag['BorderTopOnly']) { $e.Graphics.DrawLine($pen, 0, 0, $s.Width, 0) }
        else { $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1) }
        $pen.Dispose()
    })
}

$form = New-Object System.Windows.Forms.Form
if ($script:AppIcon) { $form.Icon = $script:AppIcon }
$form.Text = (T 'VSC-Wizard - Virtuelle Smartcard beantragen - https://blog.zarenko.net')
$form.Size = New-Object System.Drawing.Size(1120, 820)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(980, 720)
$form.BackColor = $script:UI.Ground
$form.Font = New-UiFont 9

# Grundaufteilung: Seitenleiste links (Schritte, Gerät, Einstellungen, Sprache) und
# rechts der Arbeitsbereich: Kopf (Seitentitel), Inhalt, einklappbares Protokoll,
# Fußleiste (Protokoll-Schalter, Zurück/Weiter). Die Dock-Reihenfolge wird am Ende
# des LOG-Bereichs festgezogen (siehe dort).
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = 'Left'
$sidebar.Width = 240
$sidebar.BackColor = $script:UI.Sidebar
$sidebar.Padding = New-Object System.Windows.Forms.Padding(18, 22, 18, 18)
$form.Controls.Add($sidebar)
# Trennlinie am rechten Rand (gezeichnet - ein Dock-Panel läge innerhalb des Paddings).
$sidebar.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen($script:UI.Border)
    $e.Graphics.DrawLine($pen, $s.Width - 1, 0, $s.Width - 1, $s.Height)
    $pen.Dispose()
})

$mainArea = New-Object System.Windows.Forms.Panel
$mainArea.Dock = 'Fill'
$mainArea.BackColor = $script:UI.Ground
$form.Controls.Add($mainArea)
$mainArea.BringToFront()

# --- Busy-/Warte-Anzeige -----------------------------------------------------------
# Viele Aktionen (VSCs auslesen, Umgebung erkennen, certreq/certutil) laufen SYNCHRON
# im UI-Thread und blockieren die Oberflaeche. Ohne Rueckmeldung wirkt das eingefroren.
# Zwei Signale: (1) der OS-Wartecursor via Application.UseWaitCursor - die drehende
# Scheibe wird vom BETRIEBSSYSTEM animiert, auch wenn unser Thread blockiert; (2) ein
# sichtbarer gelber Hinweis mit Klartext, was gerade laeuft.
# Kompakte, fast quadratische Karte MITTIG über dem Inhaltsbereich (vorher ein breiter
# Streifen oben, der z.B. den Karten-Hinweis "Microsoft Virtual Smart Card N" verdeckte):
# große Sanduhr oben, darunter der Text mit Zeilenumbruch. Name $script:BusyLabel
# historisch (jetzt ein Panel).
$script:BusyLabel = New-Object System.Windows.Forms.Panel
$script:BusyLabel.Size = New-Object System.Drawing.Size(280, 140)
# Zurückhaltend (weiß, dezenter Rahmen) - mittig ist sie ohnehin gut sichtbar.
$script:BusyLabel.BackColor = $script:UI.Surface
$script:BusyLabel.Visible = $false
Add-BorderPaint -Control $script:BusyLabel -Color $script:UI.Control
$busyIcon = New-Object System.Windows.Forms.Label
$busyIcon.Text = [string][char]0x231B   # Sanduhr
$busyIcon.Font = New-UiFont 22
$busyIcon.ForeColor = $script:UI.Accent
$busyIcon.TextAlign = 'MiddleCenter'
$busyIcon.Location = New-Object System.Drawing.Point(1, 16); $busyIcon.Size = New-Object System.Drawing.Size(278, 44)
$script:BusyTextLabel = New-Object System.Windows.Forms.Label
$script:BusyTextLabel.UseMnemonic = $false
$script:BusyTextLabel.Font = New-UiFont 10 -Semibold
$script:BusyTextLabel.ForeColor = $script:UI.Text
$script:BusyTextLabel.TextAlign = 'TopCenter'
$script:BusyTextLabel.AutoEllipsis = $true
$script:BusyTextLabel.Location = New-Object System.Drawing.Point(16, 66); $script:BusyTextLabel.Size = New-Object System.Drawing.Size(248, 62)
$script:BusyLabel.Controls.AddRange(@($busyIcon, $script:BusyTextLabel))
$form.Controls.Add($script:BusyLabel)

# Verschachtelungstiefe: ein innerer Set-/Clear-Busy (z.B. Zertifikate lesen innerhalb
# einer laufenden Übernahme) darf das äußere Banner nicht vorzeitig ausblenden.
$script:BusyDepth = 0

function Set-Busy {
    param([string]$Text)
    $script:BusyDepth++
    # Verschachtelt (z.B. Kernfunktion innerhalb einer GUI-Aktion): der äußere,
    # spezifischere Text bleibt stehen.
    if ($script:BusyDepth -gt 1) { return }
    $script:BusyText = $Text
    $script:BusyWatch = [System.Diagnostics.Stopwatch]::StartNew()
    [System.Windows.Forms.Application]::UseWaitCursor = $true
    if ($script:BusyLabel -and $form) {
        $script:BusyTextLabel.Text = $Text
        # Mittig über dem Arbeitsbereich (rechts der Seitenleiste), horizontal UND vertikal.
        $x = [int]($sidebar.Width + ($form.ClientSize.Width - $sidebar.Width - $script:BusyLabel.Width) / 2)
        $y = [int](($form.ClientSize.Height - $script:BusyLabel.Height) / 2)
        $script:BusyLabel.Location = New-Object System.Drawing.Point([Math]::Max(0, $x), [Math]::Max(0, $y))
        $script:BusyLabel.Visible = $true
        $script:BusyLabel.BringToFront()
    }
    # Refresh zeichnet das Banner synchron - bewusst KEIN Application.DoEvents(): seit die
    # Kernfunktionen über den Busy-Hook bei jedem externen Aufruf hierher kommen, würde
    # DoEvents zwischengepufferte Klicks MITTEN in einer laufenden Aktion ausführen
    # (z.B. Doppelklick auf "Zertifikat abrufen" -> verschachtelt zweimal installieren).
    try { $form.Refresh() } catch { }
}

function Clear-Busy {
    if ($script:BusyDepth -gt 0) { $script:BusyDepth-- }
    if ($script:BusyDepth -gt 0) { return }
    # Laufzeit-Protokoll: jede Warte-Phase über 1 s landet im Log - so lassen sich
    # langsame Stellen gezielt aus dem Logfile finden, statt sie beim Durchklicken zu suchen.
    if ($script:BusyWatch -and $script:BusyWatch.Elapsed.TotalSeconds -ge 1) {
        Write-WizardLog -Message ("Dauer {0:0.0} s: {1}" -f $script:BusyWatch.Elapsed.TotalSeconds, $script:BusyText) -Level Info
    }
    $script:BusyWatch = $null
    [System.Windows.Forms.Application]::UseWaitCursor = $false
    if ($script:BusyLabel) { $script:BusyLabel.Visible = $false }
    try { $form.Refresh() } catch { }   # kein DoEvents - siehe Set-Busy
}

# Kernfunktionen (Core.psm1) melden langsame Arbeit selbst über diesen Hook - Banner und
# Wartecursor erscheinen damit automatisch, auch an GUI-Stellen ohne eigenes Set-Busy.
Register-WizardBusyHook -Enter { param($Text) Set-Busy -Text $Text } -Exit { Clear-Busy }

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
    $dlg.Text = (T 'Über VSC-Wizard')
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(430, 214)

    $lblApp = New-Object System.Windows.Forms.Label
    $lblApp.Text = (T 'VSC-Wizard')
    $lblApp.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $lblApp.Location = New-Object System.Drawing.Point(20, 18); $lblApp.Size = New-Object System.Drawing.Size(390, 30)
    $dlg.Controls.Add($lblApp)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = (T 'Virtuelle Smartcards & Zertifikate für AD-Administratoren')
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
    $lblDate.Text = ((T 'Release-Datum: {0}') -f $v.Date)
    $lblDate.Location = New-Object System.Drawing.Point(22, 108); $lblDate.Size = New-Object System.Drawing.Size(390, 20)
    $dlg.Controls.Add($lblDate)

    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = (T 'https://blog.zarenko.net')
    $link.Location = New-Object System.Drawing.Point(22, 138); $link.Size = New-Object System.Drawing.Size(390, 20)
    $link.Add_LinkClicked({ try { Start-Process 'https://blog.zarenko.net' } catch { } })
    $dlg.Controls.Add($link)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = (T 'Schließen'); $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(316, 172); $ok.Size = New-Object System.Drawing.Size(94, 28)
    $dlg.Controls.Add($ok)
    $dlg.AcceptButton = $ok

    Set-DialogStyle -Dialog $dlg
    [void]$dlg.ShowDialog($form)
}

#endregion

#region TOP BAR (schrittunabhängig - auf jedem Schritt sichtbar, u.a. für Einstellungen)

# Seitenleiste (von oben): App-Name, Schrittanzeige, "Dieses Gerät", unten Links +
# Sprachumschalter. Dock-Reihenfolge: zuletzt hinzugefügte Top-Controls liegen oben -
# daher werden die Blöcke unten per SendToBack/BringToFront sortiert.
$pnlBrand = New-Object System.Windows.Forms.Panel
$pnlBrand.Dock = 'Top'; $pnlBrand.Height = 58
$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Text = (T 'VSC-Wizard'); $lblBrand.Font = New-UiFont 13 -Semibold; $lblBrand.ForeColor = $script:UI.Text
$lblBrand.AutoSize = $true; $lblBrand.Location = New-Object System.Drawing.Point(2, 0)
$lblBrandSub = New-Object System.Windows.Forms.Label
$lblBrandSub.UseMnemonic = $false   # sonst verschluckt WinForms das "&"
$lblBrandSub.Text = (T 'Smartcards & Anmeldezertifikate'); $lblBrandSub.Font = New-UiFont 8.5; $lblBrandSub.ForeColor = $script:UI.Muted
$lblBrandSub.AutoSize = $false; $lblBrandSub.AutoEllipsis = $true; $lblBrandSub.Size = New-Object System.Drawing.Size(200, 18); $lblBrandSub.Location = New-Object System.Drawing.Point(3, 28)
$pnlBrand.Controls.AddRange(@($lblBrand, $lblBrandSub))

# Schrittanzeige: wird per Update-Stepper je Seite neu aufgebaut.
$pnlStepper = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlStepper.Dock = 'Top'; $pnlStepper.FlowDirection = 'TopDown'; $pnlStepper.WrapContents = $false
$pnlStepper.AutoSize = $true; $pnlStepper.AutoSizeMode = 'GrowAndShrink'
$pnlStepper.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 18)

# "Dieses Gerät": Schlüssel/Wert-Zeilen aus der Umgebungserkennung (Update-DeviceInfo).
$pnlDevice = New-Object System.Windows.Forms.TableLayoutPanel
$pnlDevice.Dock = 'Top'; $pnlDevice.ColumnCount = 2; $pnlDevice.AutoSize = $true; $pnlDevice.AutoSizeMode = 'GrowAndShrink'
[void]$pnlDevice.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$pnlDevice.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

# Unten: Links (Einstellungen, Über).
$pnlSideBottom = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlSideBottom.Dock = 'Bottom'; $pnlSideBottom.Height = 34; $pnlSideBottom.FlowDirection = 'LeftToRight'; $pnlSideBottom.WrapContents = $false
function New-SideLink([string]$Text) {
    $l = New-Object System.Windows.Forms.LinkLabel
    $l.Text = $Text; $l.AutoSize = $true; $l.Font = New-UiFont 9
    $l.LinkColor = $script:UI.Accent; $l.ActiveLinkColor = $script:UI.AccentHover; $l.LinkBehavior = 'HoverUnderline'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 18, 0)
    return $l
}
$btnOpenSettings = New-SideLink (T 'Einstellungen')
$btnOpenSettings.Add_LinkClicked({ Show-SettingsDialog -Owner $form })
$btnAbout = New-SideLink (T 'Über')
$btnAbout.Add_LinkClicked({ Show-AboutDialog })
$pnlSideBottom.Controls.AddRange(@($btnOpenSettings, $btnAbout))

# Sprachumschalter (Deutsch | English). Wechsel = Sprache speichern + Wizard neu starten
# (die Texte werden an sehr vielen Stellen gesetzt - ein Neustart ist robuster als ein
# Umschalten zur Laufzeit). Mitten im Ablauf wird vorher gefragt.
$pnlLang = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlLang.Dock = 'Bottom'; $pnlLang.Height = 40; $pnlLang.FlowDirection = 'LeftToRight'; $pnlLang.WrapContents = $false
function New-LangButton([string]$Text, [string]$Code) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size(82, 28); $b.Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 0)
    $active = (Get-WizardLanguage) -eq $Code
    Set-ButtonStyle -Button $b -Kind $(if ($active) { 'Primary' } else { 'Secondary' })
    $b.Font = New-UiFont 8.5 -Semibold:$active
    $b.Tag['Lang'] = $Code
    $b.Add_Click({ Switch-WizardLanguage -Language $this.Tag['Lang'] })
    return $b
}
function Switch-WizardLanguage {
    param([string]$Language)
    if ($Language -eq (Get-WizardLanguage)) { return }
    if ($script:ActivePlan -in @('A', 'B')) {
        $msg = if ($Language -eq 'en') { "Switching the language restarts the wizard - the current progress is lost (a pending request stays available via 'Continue').`r`n`r`nRestart in English now?" }
               else { "Der Sprachwechsel startet den Wizard neu - der aktuelle Stand geht verloren (ein wartender Antrag bleibt über 'Fortsetzen' erreichbar).`r`n`r`nJetzt auf Deutsch neu starten?" }
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'VSC-Wizard', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    # Konfiguration mit neuer Sprache speichern (übrige Schlüssel bleiben erhalten).
    $newConfig = @{}
    if ($config) { foreach ($k in @($config.Keys)) { $newConfig[$k] = $config[$k] } }
    $newConfig['Language'] = $Language
    try { Save-VscWizardConfig -Config $newConfig -Path $script:ConfigPath } catch { }
    # Neu starten: als PS2EXE-Exe dieselbe Exe, sonst das Skript über powershell.exe.
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $env:VSCWIZARD_UILANG = $null
    # Simple-Modus beibehalten (sonst landete der Benutzer nach dem Wechsel im vollen Wizard).
    $modeArgs = @(); if ($script:SimpleMode) { $modeArgs = @('-Simple') }
    if ($exe -notmatch '\\(powershell|pwsh)\.exe$') {
        if ($modeArgs) { Start-Process -FilePath $exe -ArgumentList $modeArgs } else { Start-Process -FilePath $exe }
    } else {
        $scriptPath = Join-Path $script:BaseDir 'VscWizard.ps1'
        Start-Process -FilePath $exe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") + $modeArgs)
    }
    $form.Close()
}
$pnlLang.Controls.AddRange(@((New-LangButton 'Deutsch' 'de'), (New-LangButton 'English' 'en')))

$sidebar.Controls.Add($pnlLang)
$sidebar.Controls.Add($pnlSideBottom)
$sidebar.Controls.Add($pnlDevice)
$sidebar.Controls.Add($pnlStepper)
$sidebar.Controls.Add($pnlBrand)
# Top-Dock: zuletzt hinzugefügt = zuoberst -> Brand, Stepper, Gerät.
$pnlDevice.SendToBack(); $pnlStepper.SendToBack(); $pnlBrand.SendToBack()

function Update-Stepper {
    # Schrittanzeige neu aufbauen. $Current = Index des aktiven Schritts; davor liegende
    # gelten als erledigt (Haken), danach als offen. $Subs: optionale zweite Zeile je
    # erledigtem Schritt (z.B. Konto, Kartenname).
    param([Parameter(Mandatory)][string[]]$Labels, [int]$Current = 0, [hashtable]$Subs = @{})
    $pnlStepper.SuspendLayout()
    foreach ($old in @($pnlStepper.Controls)) { $pnlStepper.Controls.Remove($old); $old.Dispose() }
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $state = if ($i -lt $Current) { 'done' } elseif ($i -eq $Current) { 'current' } else { 'todo' }
        $sub = if ($state -eq 'done' -and $Subs.ContainsKey($i)) { "$($Subs[$i])" } else { '' }
        $row = New-Object System.Windows.Forms.Panel
        $row.Size = New-Object System.Drawing.Size(202, $(if ($sub) { 46 } else { 38 }))
        $row.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 2)
        $row.BackColor = if ($state -eq 'current') { $script:UI.Surface } else { $script:UI.Sidebar }
        $dot = New-Object System.Windows.Forms.Label
        $dot.Size = New-Object System.Drawing.Size(24, 24)
        $dot.Location = New-Object System.Drawing.Point(10, [int](($row.Height - 24) / 2))
        $dot.Tag = @{ State = $state; N = "$($i + 1)" }
        $dot.Add_Paint({
            param($s, $e)
            $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
            $st = $s.Tag['State']; $r = New-Object System.Drawing.Rectangle(0, 0, 23, 23)
            if ($st -eq 'done') {
                $b = New-Object System.Drawing.SolidBrush($script:UI.Success); $g.FillEllipse($b, $r); $b.Dispose()
                $p = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.2)
                $g.DrawLines($p, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(7, 12)), (New-Object System.Drawing.Point(10, 15)), (New-Object System.Drawing.Point(16, 8))))
                $p.Dispose()
            } else {
                if ($st -eq 'current') { $b = New-Object System.Drawing.SolidBrush($script:UI.Accent); $g.FillEllipse($b, $r); $b.Dispose(); $fg = [System.Drawing.Color]::White }
                else { $p = New-Object System.Drawing.Pen($script:UI.Control); $g.DrawEllipse($p, $r); $p.Dispose(); $fg = $script:UI.Muted }
                $f = New-UiFont 8 -Semibold
                $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
                $b2 = New-Object System.Drawing.SolidBrush($fg)
                $g.DrawString($s.Tag['N'], $f, $b2, (New-Object System.Drawing.RectangleF(0, 0, 24, 24)), $sf)
                $b2.Dispose(); $f.Dispose()
            }
        })
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.UseMnemonic = $false
        $lbl.Text = $Labels[$i]; $lbl.AutoSize = $false; $lbl.AutoEllipsis = $true
        $lbl.Font = if ($state -eq 'current') { New-UiFont 9.5 -Semibold } else { New-UiFont 9.5 }
        $lbl.ForeColor = if ($state -eq 'current') { $script:UI.Text } else { $script:UI.Muted }
        $lbl.Location = New-Object System.Drawing.Point(44, $(if ($sub) { 5 } else { 9 })); $lbl.Size = New-Object System.Drawing.Size(154, 20)
        $row.Controls.AddRange(@($dot, $lbl))
        if ($sub) {
            $lblSub = New-Object System.Windows.Forms.Label
            $lblSub.Text = $sub; $lblSub.AutoSize = $false; $lblSub.AutoEllipsis = $true; $lblSub.Font = New-UiFont 8.5
            $lblSub.ForeColor = $script:UI.Muted; $lblSub.Location = New-Object System.Drawing.Point(44, 24); $lblSub.Size = New-Object System.Drawing.Size(154, 18)
            $row.Controls.Add($lblSub)
        }
        $pnlStepper.Controls.Add($row)
    }
    $pnlStepper.ResumeLayout()
}

function Update-DeviceInfo {
    # "Dieses Gerät" in der Seitenleiste: Liste aus [pscustomobject]@{ K; V }.
    param([object[]]$Pairs)
    $pnlDevice.SuspendLayout()
    foreach ($old in @($pnlDevice.Controls)) { $pnlDevice.Controls.Remove($old); $old.Dispose() }
    $pnlDevice.RowStyles.Clear(); $pnlDevice.RowCount = 0
    $head = New-Object System.Windows.Forms.Label
    $head.Text = (T 'DIESES GERÄT'); $head.AutoSize = $true; $head.Font = New-UiFont 7.5 -Semibold; $head.ForeColor = $script:UI.Muted
    $head.Margin = New-Object System.Windows.Forms.Padding(2, 0, 0, 6)
    $pnlDevice.Controls.Add($head, 0, 0); $pnlDevice.SetColumnSpan($head, 2)
    $r = 1
    foreach ($p in @($Pairs)) {
        $k = New-Object System.Windows.Forms.Label; $k.Text = $p.K; $k.AutoSize = $true; $k.ForeColor = $script:UI.Muted; $k.Font = New-UiFont 9
        $k.Margin = New-Object System.Windows.Forms.Padding(2, 2, 6, 2)
        $v = New-Object System.Windows.Forms.Label; $v.Text = $p.V; $v.AutoSize = $true; $v.ForeColor = $script:UI.Text; $v.Font = New-UiFont 9 -Semibold
        $v.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2); $v.Anchor = 'Right'
        $pnlDevice.Controls.Add($k, 0, $r); $pnlDevice.Controls.Add($v, 1, $r); $r++
    }
    $pnlDevice.ResumeLayout()
}

# Seitentitel oben im Arbeitsbereich (vorher: "Schritt n von m: ..." in der Kopfleiste -
# die Schrittposition zeigt jetzt die Seitenleiste).
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = 'Top'; $pnlHeader.Height = 70
$pnlHeader.Padding = New-Object System.Windows.Forms.Padding(40, 26, 40, 0)
$lblGlobalStep = New-Object System.Windows.Forms.Label
$lblGlobalStep.Dock = 'Fill'
$lblGlobalStep.Font = New-UiFont 17 -Semibold
$lblGlobalStep.ForeColor = $script:UI.Text
$lblGlobalStep.AutoEllipsis = $true
$lblGlobalStep.UseMnemonic = $false
$pnlHeader.Controls.Add($lblGlobalStep)
$mainArea.Controls.Add($pnlHeader)

#endregion

#region STEP HOST (Inhaltsbereich + gemeinsame Weiter/Zurück-Navigation)

$pnlContentArea = New-Object System.Windows.Forms.Panel
$pnlContentArea.Dock = 'Fill'
$pnlContentArea.Padding = New-Object System.Windows.Forms.Padding(24, 0, 24, 8)
$mainArea.Controls.Add($pnlContentArea)

# Fußleiste: links der Protokoll-Schalter, rechts Zurück/Weiter - immer an derselben Stelle.
$pnlFooter = New-Object System.Windows.Forms.Panel
$pnlFooter.Dock = 'Bottom'; $pnlFooter.Height = 64
$pnlFooter.BackColor = $script:UI.Surface
Add-BorderPaint -Control $pnlFooter -TopOnly
$mainArea.Controls.Add($pnlFooter)

$btnLogToggle = New-Object System.Windows.Forms.Button
$btnLogToggle.Text = (T 'Protokoll anzeigen')
$btnLogToggle.Size = New-Object System.Drawing.Size(190, 34)
$btnLogToggle.Location = New-Object System.Drawing.Point(28, 15)
$btnLogToggle.TextAlign = 'MiddleLeft'
Set-ButtonStyle -Button $btnLogToggle -Kind Link
$pnlFooter.Controls.Add($btnLogToggle)

$btnNextShared = New-Object System.Windows.Forms.Button
$btnNextShared.Text = (T 'Weiter')
$btnNextShared.Size = New-Object System.Drawing.Size(128, 38)
Set-ButtonStyle -Button $btnNextShared -Kind Primary
$btnNextShared.Add_EnabledChanged({ Update-PrimaryEnabledLook $this })
$pnlFooter.Controls.Add($btnNextShared)

$btnBackShared = New-Object System.Windows.Forms.Button
$btnBackShared.Text = (T 'Zurück')
$btnBackShared.Size = New-Object System.Drawing.Size(112, 38)
Set-ButtonStyle -Button $btnBackShared -Kind Secondary
$pnlFooter.Controls.Add($btnBackShared)
# Ein deaktiviertes "Zurück" (Startseite) ist nur Rauschen - dann ausblenden.
$btnBackShared.Add_EnabledChanged({ $btnBackShared.Visible = $btnBackShared.Enabled })

# Rechtsbündig bei jedem Layout positionieren (kein Anchor: der merkt sich die
# Startbreite des noch nicht angezeigten Panels - siehe $scnHeader).
$pnlFooter.Add_Layout({
    $btnNextShared.Location = New-Object System.Drawing.Point(($pnlFooter.ClientSize.Width - 40 - $btnNextShared.Width), 13)
    $btnBackShared.Location = New-Object System.Drawing.Point(($btnNextShared.Left - 10 - $btnBackShared.Width), 13)
})

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

$lblLandingTitle = New-WizardLabel -Text (T 'Für wen soll die virtuelle Smartcard beantragt werden?') -X 20 -Y 20 -Width 780 -Style Bold

# "Für wen" und "Welcher Ablauf" muessen in GETRENNTEN Containern liegen - sonst
# bilden alle vier RadioButtons (als Kinder desselben Panels) EINE gemeinsame,
# faelschlich geteilte Auswahlgruppe. Je ein Panel => zwei unabhängige Gruppen.
$pnlAccountRadios = New-Object System.Windows.Forms.Panel
$pnlAccountRadios.Location = New-Object System.Drawing.Point(16, 52)
$pnlAccountRadios.Size = New-Object System.Drawing.Size(772, 60)

$radSelf = New-Object System.Windows.Forms.RadioButton
$radSelf.Text = ((T 'Für mich (aktuell angemeldet als {0})') -f "$env:USERDOMAIN\$env:USERNAME")
$radSelf.Location = New-Object System.Drawing.Point(4, 2)
$radSelf.Size = New-Object System.Drawing.Size(744, 24)
$radSelf.Checked = $true

$radOther = New-Object System.Windows.Forms.RadioButton
$radOther.Text = (T 'Für ein separates Konto (z.B. Admin-Konto)')
$radOther.Location = New-Object System.Drawing.Point(4, 30)
$radOther.Size = New-Object System.Drawing.Size(744, 24)
$pnlAccountRadios.Controls.AddRange(@($radSelf, $radOther))

$lblOtherAccount = New-WizardLabel -Text (T 'Zielkonto (z.B. CONTOSO\adm.mustermann oder UPN):') -X 40 -Y 122 -Width 500
$txtOtherAccount = New-Object System.Windows.Forms.TextBox
$txtOtherAccount.Location = New-Object System.Drawing.Point(40, 148)
$txtOtherAccount.Size = New-Object System.Drawing.Size(400, 24)
$txtOtherAccount.Enabled = $false

$lblOtherExplain = New-WizardLabel -Text (T 'Karten- und CSR-Erstellung laufen ganz normal in deinem eigenen Benutzerkontext - dafür ist keine gesonderte Anmeldung als Zielkonto nötig (die Smartcard-PIN ist unabhängig vom Windows-Konto). Nur die spätere Einreichung bei der CA muss aus Berechtigungsgründen als Zielkonto erfolgen; Plan B führt dich an der passenden Stelle dorthin (z.B. per RDP), die Übernahme des fertigen Zertifikats erfolgt danach wieder hier.') -X 40 -Y 178 -Width 760 -Height 60

$lblPlanChoiceTitle = New-WizardLabel -Text (T 'Welcher Ablauf?') -X 20 -Y 250 -Width 780 -Style Bold

$pnlPlanRadios = New-Object System.Windows.Forms.Panel
$pnlPlanRadios.Location = New-Object System.Drawing.Point(16, 280)
$pnlPlanRadios.Size = New-Object System.Drawing.Size(772, 54)

$radPlanA = New-Object System.Windows.Forms.RadioButton
$radPlanA.Text = (T 'Plan A: AD-Domäne (direkte CA-Sicht, automatisiert)')
$radPlanA.Location = New-Object System.Drawing.Point(4, 0)
$radPlanA.Size = New-Object System.Drawing.Size(760, 24)

$radPlanB = New-Object System.Windows.Forms.RadioButton
$radPlanB.Text = (T 'Plan B: Entra / Workgroup (CSR lokal, Einreichung per RDP-Zwischenschritt)')
$radPlanB.Location = New-Object System.Drawing.Point(4, 26)
$radPlanB.Size = New-Object System.Drawing.Size(760, 24)
$pnlPlanRadios.Controls.AddRange(@($radPlanA, $radPlanB))

$lblPlanChoiceHint = New-WizardLabel -Text '' -X 40 -Y 340 -Width 740
$lblPlanChoiceHint.ForeColor = [System.Drawing.Color]::DimGray

# Fähigkeitsbasierte Prüfung: misst, ob von HIER direkt eingereicht werden kann
# (Kerberos-TGT + DNS + certutil-ping), statt aus dem Join-Status zu raten. Ergebnis
# überschreibt die Heuristik-Vorauswahl mit der gemessenen Wahrheit.
$btnCheckDirect = New-Object System.Windows.Forms.Button
$btnCheckDirect.Text = (T 'Direkt-Einreichung prüfen')
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
            $lblPlanChoiceHint.Text = (T "EA-Zertifikat gefunden: Plan A möglich (EOBO, ohne RDP). Beachte: EA-Cert ist admin-äquivalent (ESC3) - für Admin-Konten ist Plan B (Self-Enrollment) oft sicherer. Plan B bleibt als Alternative.")
        } else {
            $radPlanA.Enabled = $false
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = (T 'Kein EA-Zertifikat gefunden - für ein separates Konto daher Plan B (RDP). Mit einem EA-Zertifikat (in den Einstellungen beantragbar) ginge auch Plan A ohne RDP.')
        }
    } else {
        $radPlanA.Enabled = $true
        if ($joinState.Mode -eq 'ADDomain') {
            $radPlanA.Checked = $true
            $lblPlanChoiceHint.Text = ((T "Vorschlag (Heuristik: Domänen-Status {0}): Plan A. Für Gewissheit 'Direkt-Einreichung prüfen'.") -f $joinState.Mode)
        } else {
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = ((T "Vorschlag (Heuristik: Domänen-Status {0}): Plan B. Bei funktionierendem Cloud Kerberos Trust ist evtl. doch Plan A möglich - 'Direkt-Einreichung prüfen' misst es.") -f $joinState.Mode)
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
    $txtDirectResult.Text = (T 'Prüfe Direkt-Einreichung (Kerberos-Ticket, DNS, certutil -ping - bis zu ca. 45 Sekunden)...')
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
        $txtDirectResult.Text = (T 'Zeitüberschreitung (>45s) - CA/DC vermutlich nicht erreichbar (Netz/DNS/VPN prüfen). Vorerst Plan B verwenden.')
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
            $lblPlanChoiceHint.Text = (T 'Gemessen: Direkt-Einreichung möglich - Plan A.')
        } else {
            $radPlanB.Checked = $true
            $lblPlanChoiceHint.Text = (T 'Gemessen: Direkt-Einreichung derzeit nicht möglich - Plan B (CA-Schritt delegieren). Grund siehe oben.')
        }
    } else {
        # Separates Konto: Plan-A-Verfügbarkeit hängt zusätzlich am EA-Zertifikat
        # (Update-ModeSelectPlanChoice); der Check zeigt hier die CA-Erreichbarkeit, die
        # auch für EOBO nötig ist.
        if (-not $cap.DirectPossible) {
            $txtDirectResult.Text += (T "`r`n`r`nHinweis: Auch der EOBO-Weg (Plan A mit EA-Zertifikat) braucht diese CA-Erreichbarkeit. Ist sie nicht gegeben, bleibt Plan B.")
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
    $lblGlobalStep.Text = (T 'Konto & Weg')
    Update-Stepper -Labels @((T 'Szenario'), (T 'Konto & Weg')) -Current 1
    # Zurück führt jetzt auf die Szenario-Auswahl (Schritt 1).
    $btnBackShared.Enabled = $true
    $btnNextShared.Enabled = $true
}

function Invoke-ModeSelectNextClick {
    if ($radOther.Checked) {
        if ([string]::IsNullOrWhiteSpace($txtOtherAccount.Text)) {
            $lblLandingValidation.Text = (T 'Bitte ein Zielkonto angeben.')
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


# Szenario-Definitionen (Reihenfolge wie im Runbook). Steps: T = Tag, X = Text.
$script:Scenarios = @(
    [pscustomobject]@{
        Id = 1; Title = (T 'VSC für fremdes onprem-/hybrid-Konto'); Sub = (T 'GEFÜHRT   Fremdes On-Prem- oder Hybrid-Konto (nicht dein angemeldetes, z.B. Admin-Konto): EOBO (mit EA-Zertifikat) oder Bootstrap/RDP.'); Stripe = 'blue'
        Steps = @(
            [pscustomobject]@{ T = 'Du';       X = (T 'Separates Admin-Konto angeben (nicht dein angemeldetes).') }
            [pscustomobject]@{ T = 'Du';       X = (T 'Neue VSC erstellen ODER eine bestehende verwenden.') }
            [pscustomobject]@{ T = 'Prüfung'; X = (T 'Mit EA-Zertifikat: EOBO (ohne RDP). Sonst: Plan B - Einreichung ALS das Zielkonto per RDP (ggf. einmalig Passwort-Anmeldung erlauben).') }
            [pscustomobject]@{ T = 'Tool';     X = (T 'CSR erzeugen, einreichen, Zertifikat auf die VSC übernehmen.') }
        )
        Guard = [pscustomobject]@{ Kind = 'warn'; Text = (T 'Bootstrap-Passwort (falls nötig) ist einmalig; danach Konto wieder auf "Smartcard erforderlich". VSC dort erstellen, wo sie genutzt wird.') }
    }
    [pscustomobject]@{
        Id = 2; Title = (T 'VSC für eigenes onprem-/hybrid-Konto'); Sub = (T 'AUTOMATISIERT   Dein eigenes (on-prem oder hybrid synchronisiertes) Konto - Direkt-Ausstellung, wenn die CA erreichbar ist.'); Stripe = 'green'
        Steps = @(
            [pscustomobject]@{ T = 'Du';       X = (T 'Neue VSC erstellen ODER eine bestehende verwenden.') }
            [pscustomobject]@{ T = 'Prüfung'; X = (T 'Direkt-Einreichung prüfen (Kerberos, DNS, certutil -ping).') }
            [pscustomobject]@{ T = 'Tool';     X = (T 'CSR -> direkt einreichen (als du) -> Zertifikat auf die VSC übernehmen.') }
        )
        Guard = $null
    }
    [pscustomobject]@{
        Id = 3; Title = (T 'VSC für fremdes Cloud-only-Konto'); Sub = (T 'NUR CLOUD   Fremdes Cloud-only-Konto (Entra CBA, nicht im lokalen AD): als DU einreichen, Ziel-UPN im CSR (Offline-Template). NICHT für On-Prem-Logon.'); Stripe = 'blue'
        Steps = @(
            [pscustomobject]@{ T = 'Du';       X = (T 'Cloud-Zielkonto/UPN angeben (Entra, z.B. gadmin@contoso.onmicrosoft.com).') }
            [pscustomobject]@{ T = 'Du';       X = (T 'Neue VSC erstellen ODER eine bestehende verwenden.') }
            [pscustomobject]@{ T = 'Tool';     X = (T 'CSR mit Ziel-UPN im SAN erzeugen (Supply-in-request/Offline-Template).') }
            [pscustomobject]@{ T = 'Prüfung'; X = (T 'Als DU direkt bei der CA einreichen (Enroll-Recht auf dem Offline-Template).') }
            [pscustomobject]@{ T = 'Tool';     X = (T 'Ausgestelltes Zertifikat auf die VSC übernehmen.') }
            [pscustomobject]@{ T = 'Du';       X = (T 'In Entra: ausstellende CA importieren + CBA-Binding auf UPN, CRL öffentlich erreichbar (RUNBOOK).') }
            [pscustomobject]@{ T = 'Du';       X = (T 'Alternative ganz ohne PKI: FIDO2/Passkey (Sicherheitsschlüssel oder Passkey).') }
        )
        Guard = [pscustomobject]@{ Kind = 'danger'; Text = (T 'NUR Entra CBA/Cloud - NICHT für On-Prem-Smartcard-Logon! Das Offline-Template bettet keine Konto-SID ein (starke Zuordnung, KB5014754) -> der KDC lehnt den On-Prem-Logon ab. Für On-Prem- oder Hybrid-Konten: Szenario 01 (fremdes Konto) bzw. 02 (eigenes Konto). Zusaetzlich ESC1: SAN frei praegbar -> Template zusperren (enge Enroll-ACL, ggf. Manager-Approval).') }
    }
    [pscustomobject]@{
        Id = 4; Title = (T 'VSCs verwalten'); Sub = (T 'WERKZEUG   Karten und Zertifikate ansehen, PIN ändern, löschen.'); Stripe = 'teal'
        # Keine Ablaufschritte: der Verwaltungsdialog erklärt sich selbst.
        Steps = @()
        Guard = $null
    }
    [pscustomobject]@{
        Id = 5; Title = (T 'Für ein anderes Konto ausstellen (EOBO)'); Sub = (T 'FORTGESCHRITTEN   Enroll on Behalf Of mit Enrollment-Agent-Zertifikat.'); Stripe = 'red'
        Steps = @(
            [pscustomobject]@{ T = 'Tool'; X = (T 'EA-Zertifikat erkennen; EOBO-Antrag (RequesterName=Ziel, Build-from-AD).') }
            [pscustomobject]@{ T = 'Tool'; X = (T 'Antrag co-signieren, einreichen, auf VSC übernehmen.') }
        )
        Guard = [pscustomobject]@{ Kind = 'danger'; Text = (T 'ESC3 - EA-Cert admin-äquivalent. Für Admin-Ziele ist Self-Enrollment (Szenario 01/02) sicherer.') }
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

# Startseite (Redesign): EINE Spalte mit Karten statt Liste + Detailbereich. Die
# gewählte Karte klappt auf (Ablauf + Warnhinweis); nicht mögliche Szenarien zeigen
# ihre Begründung direkt in der Karte. Gruppen: "Smartcard ausstellen" und "Werkzeuge".
$scnScroll = New-Object System.Windows.Forms.Panel
$scnScroll.Dock = 'Fill'; $scnScroll.AutoScroll = $true
$scnScroll.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 12)
$pnlScenario.Controls.Add($scnScroll)

$scnStack = New-Object System.Windows.Forms.FlowLayoutPanel
$scnStack.FlowDirection = 'TopDown'; $scnStack.WrapContents = $false
$scnStack.AutoSize = $true; $scnStack.AutoSizeMode = 'GrowAndShrink'
$scnStack.Location = New-Object System.Drawing.Point(16, 0)
$scnScroll.Controls.Add($scnStack)

$lblScnSub = New-Object System.Windows.Forms.Label
$lblScnSub.Text = (T 'Wähle, für wen die Smartcard ist - der Wizard richtet Karte, Antrag und Einreichungsweg passend ein.')
$lblScnSub.AutoSize = $true; $lblScnSub.Font = New-UiFont 10; $lblScnSub.ForeColor = $script:UI.Muted
$lblScnSub.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
# Nur noch für "Bitte ein Szenario auswählen." (Begründungen stehen in den Karten).
$lblScnValidation = New-Object System.Windows.Forms.Label
$lblScnValidation.AutoSize = $true; $lblScnValidation.Font = New-UiFont 9.5; $lblScnValidation.ForeColor = $script:UI.Danger
$lblScnValidation.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14); $lblScnValidation.Visible = $false

function New-ScnSection([string]$Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text.ToUpper(); $l.AutoSize = $true; $l.Font = New-UiFont 8 -Semibold; $l.ForeColor = $script:UI.Muted
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 8)
    return $l
}

# Farben der Kategorie-Chips und der Ablauf-Rollen.
$scnTagColors = @{
    1 = @((New-UiColor 232 241 251), (New-UiColor 11 74 139))
    2 = @((New-UiColor 230 244 234), (New-UiColor 30 107 58))
    3 = @((New-UiColor 241 236 251), (New-UiColor 90 58 154))
    4 = @((New-UiColor 227 244 244), (New-UiColor 29 99 99))
    5 = @((New-UiColor 236 239 243), (New-UiColor 58 66 75))
}
$scnWhoColors = @{
    'Tool'    = @($script:UI.AccentWeak, $script:UI.AccentText)
    'Prüfung' = @($script:UI.WarnWeak, $script:UI.Warn)
    'Du'      = @($script:UI.Sidebar, (New-UiColor 58 66 75))
}
$script:ScnCards = @{}   # Id -> Karten-Panel

# Klick auf Karte oder eines ihrer Elemente: Id aus dem Tag (Karte: Hashtable, Kinder: int).
$scnRowClick = {
    param($s, $e)
    $id = if ($s.Tag -is [hashtable]) { $s.Tag['Id'] } else { $s.Tag }
    if ($null -ne $id) { Select-ScenarioById -Id ([int]$id) }
}

function New-ScenarioCard {
    param($Scenario)
    $parts = "$($Scenario.Sub)" -split '\s{3,}', 2
    $tagText = if ($parts.Count -gt 1) { (Get-Culture).TextInfo.ToTitleCase($parts[0].ToLower()) } else { '' }
    $desc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }

    $card = New-Object System.Windows.Forms.Panel
    $card.BackColor = $script:UI.Surface
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Tag = @{ Id = $Scenario.Id; Selected = $false; Available = $true }
    $card.Add_Paint({
        param($s, $e)
        $sel = $s.Tag['Selected']
        $pen = New-Object System.Drawing.Pen($(if ($sel) { $script:UI.Accent } else { $script:UI.Border }), $(if ($sel) { 2 } else { 1 }))
        $o = if ($sel) { 1 } else { 0 }
        $e.Graphics.DrawRectangle($pen, $o, $o, $s.Width - 1 - $o, $s.Height - 1 - $o)
        $pen.Dispose()
    })

    $num = New-Object System.Windows.Forms.Label
    $num.Text = ('{0:D2}' -f $Scenario.Id); $num.AutoSize = $true; $num.Font = New-UiFont 9.5 -Semibold; $num.ForeColor = $script:UI.Muted
    $num.Location = New-Object System.Drawing.Point(18, 16)
    $title = New-Object System.Windows.Forms.Label
    $title.UseMnemonic = $false; $title.Text = $Scenario.Title; $title.AutoSize = $true; $title.Font = New-UiFont 11 -Semibold; $title.ForeColor = $script:UI.Text
    $title.Location = New-Object System.Drawing.Point(54, 12)
    $chip = New-Object System.Windows.Forms.Label
    $chip.Text = $tagText; $chip.AutoSize = $true; $chip.Font = New-UiFont 7.5 -Semibold
    $chip.Padding = New-Object System.Windows.Forms.Padding(6, 1, 6, 1)
    $tc = $scnTagColors[[int]$Scenario.Id]; if ($tc) { $chip.BackColor = $tc[0]; $chip.ForeColor = $tc[1] }
    $chip.Visible = [bool]$tagText
    $descLbl = New-Object System.Windows.Forms.Label
    $descLbl.UseMnemonic = $false; $descLbl.Text = $desc; $descLbl.AutoSize = $false; $descLbl.AutoEllipsis = $true
    $descLbl.Font = New-UiFont 9.5; $descLbl.ForeColor = $script:UI.Muted
    $descLbl.Location = New-Object System.Drawing.Point(54, 38); $descLbl.Height = 20
    $chev = New-Object System.Windows.Forms.Label
    $chev.Text = [char]0xE76C; $chev.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 10); $chev.ForeColor = $script:UI.Muted
    $chev.AutoSize = $true

    # Begründung (nicht möglich) - mehrzeilig.
    $reason = New-Object System.Windows.Forms.Label
    $reason.UseMnemonic = $false; $reason.AutoSize = $true; $reason.Font = New-UiFont 9.5; $reason.ForeColor = $script:UI.Danger
    $reason.Visible = $false

    # Aufgeklappter Teil: Ablauf-Schritte + Warnhinweis.
    $details = New-Object System.Windows.Forms.Panel
    $details.BackColor = $script:UI.Surface; $details.Visible = $false
    $y = 0
    $stepRows = New-Object System.Collections.ArrayList
    foreach ($st in $Scenario.Steps) {
        $who = New-Object System.Windows.Forms.Label
        $who.Text = (T $st.T); $who.AutoSize = $false; $who.Size = New-Object System.Drawing.Size(64, 20); $who.TextAlign = 'MiddleCenter'
        $who.Font = New-UiFont 8 -Semibold
        $wc = $scnWhoColors[$st.T]; if ($wc) { $who.BackColor = $wc[0]; $who.ForeColor = $wc[1] }
        $txt = New-Object System.Windows.Forms.Label
        $txt.UseMnemonic = $false; $txt.Text = $st.X; $txt.AutoSize = $true; $txt.Font = New-UiFont 9.5; $txt.ForeColor = $script:UI.Text
        $details.Controls.AddRange(@($who, $txt))
        [void]$stepRows.Add(@($who, $txt))
    }
    $guard = $null
    if ($Scenario.Guard) {
        $guard = New-Object System.Windows.Forms.Label
        $guard.UseMnemonic = $false; $guard.Text = $Scenario.Guard.Text; $guard.AutoSize = $true; $guard.Font = New-UiFont 9
        $danger = $Scenario.Guard.Kind -eq 'danger'
        $guard.BackColor = if ($danger) { $script:UI.DangerWeak } else { $script:UI.WarnWeak }
        $guard.ForeColor = if ($danger) { New-UiColor 125 28 20 } else { $script:UI.Warn }
        $guard.Padding = New-Object System.Windows.Forms.Padding(12, 9, 12, 9)
        $details.Controls.Add($guard)
    }

    $card.Controls.AddRange(@($num, $title, $chip, $descLbl, $chev, $reason, $details))
    $card.Tag['Parts'] = @{ Title = $title; Chip = $chip; Desc = $descLbl; Chev = $chev; Reason = $reason; Details = $details; Steps = $stepRows; Guard = $guard; Num = $num }
    foreach ($c in @($num, $title, $chip, $descLbl, $chev, $reason, $details)) { $c.Tag = if ($c.Tag) { $c.Tag } else { $Scenario.Id }; $c.Add_Click($scnRowClick) }
    $card.Add_Click($scnRowClick)
    return $card
}

function Update-ScenarioCardLayout {
    # Positionen/Höhe einer Karte aus Breite + Zustand (ausgewählt/verfügbar) berechnen.
    param([System.Windows.Forms.Panel]$Card)
    $p = $Card.Tag['Parts']; $w = $Card.Width
    $p.Chip.Location = New-Object System.Drawing.Point(($p.Title.Right + 10), 16)
    $p.Chev.Location = New-Object System.Drawing.Point(($w - 34), 22)
    $p.Desc.Width = [Math]::Max(60, $w - 54 - 48)
    $y = 64
    # Eigene Zustands-Flags statt .Visible: .Visible liefert bei (noch) nicht angezeigtem
    # Fenster immer $false - dann liefe dieses Layout nie.
    if ($Card.Tag['ShowReason']) {
        $p.Reason.MaximumSize = New-Object System.Drawing.Size(($w - 54 - 24), 0)
        $p.Reason.Location = New-Object System.Drawing.Point(54, ($y - 2)); $y = $p.Reason.Bottom + 12
    }
    if ($Card.Tag['Selected']) {
        $dw = $w - 54 - 24
        $p.Details.Location = New-Object System.Drawing.Point(54, ($y - 2)); $p.Details.Width = $dw
        $dy = 2
        foreach ($row in $p.Steps) {
            $row[0].Location = New-Object System.Drawing.Point(0, $dy)
            $row[1].MaximumSize = New-Object System.Drawing.Size(($dw - 76), 0)
            $row[1].Location = New-Object System.Drawing.Point(76, ($dy + 1))
            $dy = [Math]::Max($row[0].Bottom, $row[1].Bottom) + 8
        }
        if ($p.Guard) {
            $p.Guard.MaximumSize = New-Object System.Drawing.Size($dw, 0)
            $p.Guard.MinimumSize = New-Object System.Drawing.Size($dw, 0)
            $p.Guard.Location = New-Object System.Drawing.Point(0, ($dy + 4)); $dy = $p.Guard.Bottom + 4
        }
        $p.Details.Height = $dy
        $y = $p.Details.Bottom + 14
    }
    $Card.Height = [Math]::Max(66, $y)
    $Card.Invalidate()
}

function Update-ScenarioCard {
    # Zustand (Auswahl/Verfügbarkeit) einer Karte auf ihre Darstellung übertragen.
    param([System.Windows.Forms.Panel]$Card)
    $id = [int]$Card.Tag['Id']; $p = $Card.Tag['Parts']
    $ok = $true; if ($script:ScnAvailable.ContainsKey($id)) { $ok = [bool]$script:ScnAvailable[$id] }
    $sel = $ok -and ($id -eq $script:SelectedScenario)
    $Card.Tag['Selected'] = $sel; $Card.Tag['Available'] = $ok; $Card.Tag['ShowReason'] = -not $ok
    $Card.BackColor = if ($ok) { $script:UI.Surface } else { New-UiColor 240 242 244 }
    $Card.Cursor = if ($ok) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    $p.Title.ForeColor = if ($ok) { $script:UI.Text } else { $script:UI.Muted }
    $p.Reason.Visible = -not $ok
    $p.Reason.Text = if ($ok) { '' } else { ((T 'Hier nicht möglich: {0}') -f $script:ScnReason[$id]) }
    $p.Details.Visible = $sel
    $p.Chev.Text = if ($sel) { [char]0xE70D } else { [char]0xE76C }
    $p.Chev.Visible = $ok
    Update-ScenarioCardLayout -Card $Card
}

$scnStack.Controls.AddRange(@($lblScnSub, $lblScnValidation))
$scnStack.Controls.Add((New-ScnSection (T 'Smartcard ausstellen')))
foreach ($scn in @($script:Scenarios | Where-Object { $_.Id -ne 4 })) {
    $card = New-ScenarioCard -Scenario $scn
    $script:ScnCards[[int]$scn.Id] = $card
    $scnStack.Controls.Add($card)
}
$scnStack.Controls.Add((New-ScnSection (T 'Werkzeuge')))
foreach ($scn in @($script:Scenarios | Where-Object { $_.Id -eq 4 })) {
    $card = New-ScenarioCard -Scenario $scn
    $script:ScnCards[[int]$scn.Id] = $card
    $scnStack.Controls.Add($card)
}

# Kartenbreite an die Fensterbreite koppeln (Layout-Ereignis, kein Anchor - siehe Fußleiste).
$scnScroll.Add_Layout({
    # Breite der senkrechten Scrollleiste immer abziehen - sonst erscheint, sobald sie
    # auftaucht, zusätzlich eine waagrechte.
    $w = [Math]::Max(420, [Math]::Min(900, $scnScroll.ClientSize.Width - 32 - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth))
    $lblScnSub.MaximumSize = New-Object System.Drawing.Size($w, 0)
    $lblScnValidation.MaximumSize = New-Object System.Drawing.Size($w, 0)
    foreach ($c in $script:ScnCards.Values) {
        if ($c.Width -ne $w) { $c.Width = $w; Update-ScenarioCardLayout -Card $c }
    }
})

function Select-ScenarioById {
    param([int]$Id)
    $available = $true
    if ($script:ScnAvailable.ContainsKey($Id)) { $available = [bool]$script:ScnAvailable[$Id] }
    # Nicht mögliche Szenarien sind nicht wählbar - die Begründung steht in der Karte.
    if (-not $available) { return }
    $script:SelectedScenario = $Id
    $lblScnValidation.Visible = $false
    $scnStack.SuspendLayout()
    foreach ($c in $script:ScnCards.Values) { Update-ScenarioCard -Card $c }
    $scnStack.ResumeLayout()
    $btnNextShared.Enabled = $true
}

function Update-ScenarioRowColors {
    # Name historisch (früher Zeilenfarben): alle Karten an Auswahl/Verfügbarkeit angleichen.
    $scnStack.SuspendLayout()
    foreach ($c in $script:ScnCards.Values) { Update-ScenarioCard -Card $c }
    $scnStack.ResumeLayout()
}

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
                return [pscustomobject]@{ Available = $false; Reason = (T 'Kein On-Prem-Kerberos-Ticket (TGT) und kein AD-Domain-Join - ohne authentifizierbare AD-Identität kann von hier NICHT direkt bei der CA eingereicht werden. Auf einem Entra-joined Client setzt das funktionierendes Cloud Kerberos Trust voraus. Ohne das: von einem Rechner mit CA-Sicht bzw. Szenario 01 (per RDP).') }
            }
        }
        3 {
            # Cloud-Konto/Entra CBA: DU reichst direkt bei der On-Prem-CA ein - dafür
            # braucht DEIN Konto eine authentifizierbare On-Prem-AD-Identität (wie 02).
            # (Das ZIEL ist ein Cloud-Konto; der EINREICHER bist du und musst die CA
            # erreichen.)
            if (-not $Caps.HasOnPremTgt -and $Caps.JoinMode -ne 'ADDomain') {
                return [pscustomobject]@{ Available = $false; Reason = (T 'Kein On-Prem-Kerberos-Ticket (TGT) und kein AD-Domain-Join - du musst als du selbst bei der On-Prem-CA einreichen können. Entra-joined mit Cloud Kerberos Trust hat ein TGT. Ohne das: von einem Rechner mit CA-Sicht ausstellen.') }
            }
        }
        5 {
            if ($Caps.EaCertCount -lt 1) {
                return [pscustomobject]@{ Available = $false; Reason = (T 'Kein Enrollment-Agent-Zertifikat vorhanden - Enroll on Behalf Of ist ohne EA-Zertifikat nicht möglich (in den Einstellungen beantragbar). Für ein separates Konto sonst Szenario 01 (fremdes onprem-/hybrid-Konto, per RDP als Zielkonto).') }
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
    Set-Busy -Text (T 'Umgebung erkennen (TPM, Kerberos, Karten)...')
    try { $caps = Get-EnvironmentCapabilities } finally { Clear-Busy }
    $script:EnvCaps = $caps

    foreach ($scn in $script:Scenarios) {
        $av = Get-ScenarioAvailability -Caps $caps -Id $scn.Id
        $script:ScnAvailable[$scn.Id] = $av.Available
        $script:ScnReason[$scn.Id]    = $av.Reason
    }

    # Gewähltes, aber hier nicht (mehr) mögliches Szenario abwählen.
    if ($script:SelectedScenario -and $script:ScnAvailable.ContainsKey([int]$script:SelectedScenario) -and -not $script:ScnAvailable[[int]$script:SelectedScenario]) {
        $script:SelectedScenario = $null
    }
    Update-ScenarioRowColors

    # Seitenleiste "Dieses Gerät" (kompakt, ersetzt die frühere lange Umgebungszeile).
    Update-DeviceInfo -Pairs @(
        [pscustomobject]@{ K = (T 'Anmeldung'); V = "$($caps.JoinMode)" }
        [pscustomobject]@{ K = (T 'TPM'); V = $(if ($caps.TpmPresent) { if ($caps.TpmReady) { (T 'bereit') } else { (T 'nicht bereit') } } else { (T 'keins') }) }
        [pscustomobject]@{ K = (T 'Kerberos'); V = $(if ($caps.HasOnPremTgt) { if ($caps.Realm) { "$($caps.Realm)" } else { (T 'ja') } } else { (T 'kein Ticket') }) }
        [pscustomobject]@{ K = (T 'Smartcards'); V = "$($caps.VscCount)" }
        [pscustomobject]@{ K = (T 'EA-Zertifikat'); V = $(if ($caps.EaCertCount -gt 0) { "$($caps.EaCertCount)" } else { (T 'keins') }) }
    )
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
    $lblGlobalStep.Text = (T 'Was möchtest du tun?')
    Update-Stepper -Labels @((T 'Szenario'), (T 'Smartcard'), (T 'Zertifikat'), (T 'Fertig')) -Current 0
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
        $script:PlanA_RenewMode = $false
        $txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"
        $lblVscResultA.Text = ''
        Reset-PlanARequestUi
        $tabPlanA.Visible = $true
        Set-PlanATemplateForMode
        Show-PlanAStep -Index 0
    } else {
        $script:ActivePlan = 'B'
        $script:PlanB_VscCreated = $false
        $script:PlanB_CertIssued = $false
        $script:PlanB_RenewMode = $false
        $txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"
        $lblVscResultB.Text = ''
        $lblCompleteResultB.Text = ''
        Reset-PlanBSubmitUi
        Reset-PlanBRdpUi
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
    $dlg.Text = (T 'Zielkonto')
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(440, 120)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if ($Prompt) { $Prompt } else { (T 'Zielkonto (z.B. CONTOSO\adm.mustermann - DOMAIN\Konto bevorzugt):') }
    $lbl.Location = New-Object System.Drawing.Point(12, 14)
    $lbl.Size = New-Object System.Drawing.Size(416, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(12, 38)
    $txt.Size = New-Object System.Drawing.Size(416, 24)
    if ($Prefill) { $txt.Text = $Prefill }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = (T 'Weiter'); $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(256, 80); $ok.Size = New-Object System.Drawing.Size(80, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = (T 'Abbrechen'); $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(344, 80); $cancel.Size = New-Object System.Drawing.Size(84, 28)

    $dlg.Controls.AddRange(@($lbl, $txt, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    Set-DialogStyle -Dialog $dlg
    $res = $dlg.ShowDialog($form)
    if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $txt.Text.Trim()) { return $txt.Text.Trim() }
    return $null
}

function Get-PhysicalCardStateText {
    # Klartext zum Prüfergebnis einer anderen Smartcard (Get-PhysicalSmartCards).
    param([string]$State)
    switch ($State) {
        'Usable'       { T 'geeignet' }
        'UnknownCard'  { T 'Kartentyp unbekannt - kein passender Kartentreiber (Minidriver) installiert' }
        'NoMinidriver' { T 'kein Kartentreiber (Minidriver) installiert' }
        'ReadOnly'     { T 'der Kartentreiber kann keine Schlüssel erzeugen' }
        'Full'         { T 'kein freier Schlüsselplatz mehr auf der Karte' }
        'DriverError'  { T 'der Kartentreiber meldet einen Fehler' }
        default        { "$State" }
    }
}

function Show-VscPickerDialog {
    # Auswahl der zu verlängernden Karte aus den vorhandenen VSCs, mit Restlaufzeit
    # des (frühesten) Zertifikats auf der jeweiligen Karte.
    param($Readers, $Certs)
    $dlg = New-Object System.Windows.Forms.Form
    $anyPhysical = [bool]@($Readers | Where-Object { $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'Physical' })
    $dlg.Text = if ($anyPhysical) { T 'Vorhandene Smartcard wählen' } else { T 'Vorhandene virtuelle Smartcard wählen' }
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 320)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if ($anyPhysical) { T 'Welche vorhandene Smartcard verwenden?' } else { T 'Welche vorhandene virtuelle Smartcard verwenden?' }
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
            ((T 'gültig bis {0}') -f $soonest.ToString('yyyy-MM-dd'))
        } else { (T 'kein Zertifikat gefunden') }
        # Zertifikate nur auf der Karte (noch nicht im Speicher) zählen für die Restlaufzeit mit.
        $cardOnly = @($cardCerts | Where-Object { $_.InStore -eq $false }).Count
        if ($cardOnly -gt 0) { $expiryNote += '  ' + ((T '({0} nur auf der Karte)') -f $cardOnly) }
        $pcsc = if ($r.PcscName) { $r.PcscName } else { '?' }
        if ($r.PSObject.Properties['Kind'] -and $r.Kind -eq 'Physical') {
            # Physische Karte: Lesegerät steht schon im Namen; ungeeignete mit Grund.
            $line = if ($r.Usable) { "$($r.FriendlyName)  -  $expiryNote" } else { "$($r.FriendlyName)  -  " + ((T 'nicht verwendbar: {0}') -f (Get-PhysicalCardStateText $r.State)) }
            [void]$list.Items.Add($line)
        } else {
            [void]$list.Items.Add("$($r.FriendlyName)  [$pcsc]  -  $expiryNote")
        }
    }
    $firstUsable = 0
    for ($i = 0; $i -lt $Readers.Count; $i++) { if (-not $Readers[$i].PSObject.Properties['Usable'] -or $Readers[$i].Usable) { $firstUsable = $i; break } }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = $firstUsable }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = (T 'Verwenden'); $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(344, 276); $ok.Size = New-Object System.Drawing.Size(100, 30)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = (T 'Abbrechen'); $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(452, 276); $cancel.Size = New-Object System.Drawing.Size(96, 30)

    $dlg.Controls.AddRange(@($lbl, $list, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    Set-DialogStyle -Dialog $dlg
    $res = $dlg.ShowDialog($form)
    if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedIndex -ge 0) {
        $sel = $Readers[$list.SelectedIndex]
        if ($sel.PSObject.Properties['Usable'] -and -not $sel.Usable) {
            [System.Windows.Forms.MessageBox]::Show(((T "Diese Karte kann nicht verwendet werden:`r`n{0}") -f (Get-PhysicalCardStateText $sel.State)), (T 'Smartcard nicht verwendbar'), 'OK', 'Information') | Out-Null
            return $null
        }
        return $sel
    }
    return $null
}

# Zustand "Antrag wartet auf Genehmigung" an EINER Stelle je Plan: solange ein Antrag
# offen ist, ist "Anfordern"/"Einreichen" gesperrt (ein zweiter Klick erzeugte einen
# weiteren Antrag mit neuem Schlüssel); nur "Zertifikat abrufen" ist sinnvoll. Wieder
# frei nach Ablehnung durch die CA oder beim Neustart eines Ablaufs.
function Update-IssueButtons {
    # EINE Stelle für "darf jetzt (noch) ausgestellt/übernommen werden?": nach erfolgreicher
    # Ausstellung sind "Zertifikat anfordern" (Plan A) bzw. "Übernehmen" (Plan B) gesperrt -
    # ein zweiter Klick erzeugte einen weiteren Antrag mit neuem Schlüssel auf derselben
    # Karte. Bei wartendem Antrag bleibt "Anfordern" ebenfalls gesperrt (nur "Abrufen").
    $btnRequestCertA.Enabled = -not $script:PlanA_CertIssued -and -not $script:PlanA_PendingRequestId
    $btnCompleteB.Enabled = -not $script:PlanB_CertIssued
    $btnCompleteFromTextB.Enabled = -not $script:PlanB_CertIssued
}

function Reset-PlanBRdpUi {
    # Direktweg (Antrag in der RDP-Sitzung) für einen neuen Durchlauf zurücksetzen.
    $script:PlanB_Fallback = $false
    $script:PlanB_RdpEntered = $null
    $lblRdpResultB.Text = ''; $lblRdpSummaryB.Text = ''
}

function Reset-PlanARequestUi {
    $script:PlanA_PendingRequestId = $null
    $lblCertResultA.Text = ''
    $btnRetrieveA.Visible = $false
    $btnRequestCertA.Enabled = $true
}
function Set-PlanAPendingUi {
    param([string]$RequestId, [string]$Text)
    $script:PlanA_PendingRequestId = $RequestId
    $lblCertResultA.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblCertResultA.Text = $Text
    $btnRetrieveA.Visible = $true
    $btnRequestCertA.Enabled = $false
}
function Reset-PlanBSubmitUi {
    $script:PlanB_PendingRequestId = $null
    $lblSubmitResultB.Text = ''
    $btnRetrieveB.Visible = $false
    $btnSubmitB.Enabled = $true
}
function Set-PlanBPendingUi {
    param([string]$RequestId, [string]$Text)
    $script:PlanB_PendingRequestId = $RequestId
    $lblSubmitResultB.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblSubmitResultB.Text = $Text
    $btnRetrieveB.Visible = $true
    $btnSubmitB.Enabled = $false
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
    Reset-PlanARequestUi
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
    $script:PlanB_CertIssued = $false   # vorher fehlte das: Zustand des vorigen Durchlaufs
    Reset-PlanBSubmitUi
    Reset-PlanBRdpUi
    $script:PlanB_RenewMode = $true
    $script:PlanEntryFrom = 'Scenario'
    $pnlScenario.Visible = $false
    $pnlModeSelect.Visible = $false
    $script:ActivePlan = 'B'
    $tabPlanB.Visible = $true
    # Fremdes Konto: Direktweg (RDP) zuerst, sonst wie bisher die CSR.
    Show-PlanBStep -Index $(if (Test-PlanBDirect) { 6 } else { 2 })
}

function Show-VscChoiceDialog {
    # Fragt, ob eine NEUE virtuelle Smartcard erstellt oder eine BESTEHENDE verwendet
    # werden soll. Gibt 'new', 'existing' oder $null (abgebrochen) zurueck.
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if (Test-PhysicalCardsAllowed -Config $config) { T 'Smartcard' } else { T 'Virtuelle Smartcard' }
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 150)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if (Test-PhysicalCardsAllowed -Config $config) { T 'Neue virtuelle Smartcard erstellen oder eine vorhandene Karte verwenden (virtuell oder z.B. YubiKey)?' } else { T 'Neue virtuelle Smartcard erstellen oder eine vorhandene verwenden?' }
    $lbl.Location = New-Object System.Drawing.Point(16, 16)
    $lbl.Size = New-Object System.Drawing.Size(428, 40)
    $dlg.Controls.Add($lbl)

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = (T 'Neue VSC erstellen')
    $btnNew.Location = New-Object System.Drawing.Point(16, 68); $btnNew.Size = New-Object System.Drawing.Size(200, 34)
    $btnExisting = New-Object System.Windows.Forms.Button
    $btnExisting.Text = (T 'Bestehende verwenden')
    $btnExisting.Location = New-Object System.Drawing.Point(228, 68); $btnExisting.Size = New-Object System.Drawing.Size(200, 34)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = (T 'Abbrechen'); $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.Location = New-Object System.Drawing.Point(344, 112); $btnCancel.Size = New-Object System.Drawing.Size(100, 26)

    $script:VscChoice = $null
    $btnNew.Add_Click({ $script:VscChoice = 'new'; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $btnExisting.Add_Click({ $script:VscChoice = 'existing'; $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })

    $dlg.Controls.AddRange(@($btnNew, $btnExisting, $btnCancel))
    $dlg.CancelButton = $btnCancel
    Set-DialogStyle -Dialog $dlg
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $script:VscChoice }
    return $null
}

function Select-ExistingVsc {
    # Waehlt eine vorhandene VSC als Schluesseltraeger (fuer "bestehende verwenden").
    # Gibt den gewaehlten Reader zurueck oder $null (keine vorhanden / abgebrochen).
    # Mit "andere Smartcards" (Einstellung) auch eingesteckte physische Karten; ungeeignete
    # erscheinen im Auswahldialog mit Grund, sind aber nicht wählbar.
    $physical = Test-PhysicalCardsAllowed -Config $config
    $all = @(Invoke-Busy -Text (T 'Suche Smartcards...') -Action { Get-SmartCardTargets -Config $config -IncludeUnusable })
    $readers = @($all | Where-Object { $_.Usable })
    if ($readers.Count -eq 0) {
        if ($physical) {
            $msg = T 'Auf diesem Gerät wurde keine geeignete Smartcard gefunden (virtuell oder eingesteckt). Bitte stattdessen "Neue VSC erstellen" wählen oder eine Karte einstecken.'
            $why = @($all | Where-Object { -not $_.Usable } | ForEach-Object { "- $($_.FriendlyName): $(Get-PhysicalCardStateText $_.State)" })
            if ($why) { $msg += "`r`n`r`n" + ($why -join "`r`n") }
            [System.Windows.Forms.MessageBox]::Show($msg, (T 'Keine Smartcard vorhanden'), 'OK', 'Information') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show((T 'Auf diesem Gerät wurde keine virtuelle Smartcard gefunden. Bitte stattdessen "Neue VSC erstellen" wählen.'), (T 'Keine VSC vorhanden'), 'OK', 'Information') | Out-Null
        }
        return $null
    }
    if ($readers.Count -eq 1 -and $all.Count -eq 1) { return $readers[0] }
    $certs = @(Invoke-Busy -Text (T 'Lese vorhandene Smartcards und Zertifikate...') -Action { Get-SmartCardCertificates })
    return (Show-VscPickerDialog -Readers $all -Certs $certs)
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

    $cardCerts = @(Invoke-Busy -Text (T 'Prüfe Zertifikate auf der Smartcard...') -Action { Get-SmartCardCertificates } | Where-Object { $_.Reader -and ($_.Reader -eq $PcscName) })
    Write-WizardLog -Message "Aufräumen: $($cardCerts.Count) Zertifikat(e) auf Karte '$PcscName' gefunden." -Level Info
    if ($cardCerts.Count -le 1) {
        Write-WizardLog -Message 'Aufräumen: nur ein Zertifikat auf der Karte - nichts zu entfernen.' -Level Info
        return
    }

    $sorted = @($cardCerts | Sort-Object NotBefore -Descending)
    $keep = $sorted[0]
    $old  = @($sorted | Select-Object -Skip 1)   # das neueste (gerade ausgestellte) behalten
    Write-WizardLog -Message "Aufräumen: behalte '$($keep.Subject)' (gültig bis $($keep.NotAfter.ToString('yyyy-MM-dd'))), $($old.Count) ältere(s) zum Entfernen." -Level Info

    # Auch Zertifikate, die nur auf der Karte liegen (noch nicht im Speicher), zählen mit -
    # sonst tauchten sie erst beim nächsten Aufräumen auf, wenn CertPropSvc sie kopiert hat.
    $list = ($old | ForEach-Object {
        $line = (T "- {0}`r`n   gültig bis {1}, Thumbprint {2}") -f $_.Subject, $_.NotAfter.ToString('yyyy-MM-dd'), $_.Thumbprint
        if ($_.InStore -eq $false) { $line += "`r`n   " + (T 'liegt auf der Karte, fehlt im Zertifikatsspeicher') }
        $line
    }) -join "`r`n"
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        ((T "Auf der Karte liegen nach der Verlängerung noch {0} ältere(s) Zertifikat(e). Jetzt entfernen, damit nur das neue bleibt?`r`n`r`nBEHALTEN (neu):`r`n- {1}`r`n   gültig bis {2}`r`n`r`nENTFERNEN:`r`n{3}`r`n`r`nJe Entfernung erscheint ggf. eine UAC-/PIN-Abfrage.") -f $old.Count, $keep.Subject, $keep.NotAfter.ToString('yyyy-MM-dd'), $list),
        (T 'Karte aufräumen - altes Zertifikat entfernen'), 'YesNo', 'Question')
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

function Start-ForeignOnPremScenario {
    # Szenario 01 - VSC für ein FREMDES on-prem- oder Hybrid-Konto (nicht das angemeldete):
    # mit EA-Zertifikat per EOBO (Plan A), sonst Plan B/Bootstrap (Einreichung ALS das
    # Zielkonto per RDP). Identität = das eingegebene Zielkonto (NICHT von der Karte).
    # -Prefill: Wechsel aus Szenario 03, wenn das Konto dort als Hybrid-Konto erkannt wurde.
    param([string]$Prefill)
    $acct = if ($Prefill) { Show-AccountInputDialog -Prefill $Prefill } else { Show-AccountInputDialog }
    if (-not $acct) { return }
    $script:TargetAccount = $acct
    $script:PlanA_OfflineDirect = $false
    $plan = Get-ScenarioPlanForSeparateAccount   # 'A' (EOBO) / 'B'
    if ($plan -eq 'B') {
        [System.Windows.Forms.MessageBox]::Show(((T "Für {0} wird per Plan B ausgestellt:`r`n`r`nKein EA-Zertifikat vorhanden - beantragt wird ALS das Zielkonto in einer RDP-Sitzung, in die diese Smartcard durchgereicht wird (Ausweichweg: Antrag + Einreicher). Für eine ERSTausstellung muss das Konto ggf. kurz Passwort-Anmeldung erlauben (Smartcard-Zwang kurz aus), danach wieder auf 'Smartcard erforderlich'.") -f $acct), (T 'Fremdes Konto - Plan B'), 'OK', 'Information') | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show(((T "Für {0} wird per Enroll on Behalf Of (Plan A) ausgestellt:`r`n`r`nEin EA-Zertifikat wurde gefunden - die Karte wird im Auftrag des Zielkontos ausgestellt, ohne RDP und ohne temporäres Passwort.") -f $acct), (T 'Fremdes Konto - EOBO'), 'OK', 'Information') | Out-Null
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

function Invoke-ScenarioNextClick {
    if (-not $script:SelectedScenario) {
        $lblScnSub.Visible = $false
        $lblScnValidation.Text = (T 'Bitte ein Szenario auswählen.')
        $lblScnValidation.Visible = $true
        return
    }
    # Sicherheitsnetz: ausgegraute (hier nicht mögliche) Szenarien nicht starten.
    if ($script:ScnAvailable.ContainsKey($script:SelectedScenario) -and -not $script:ScnAvailable[$script:SelectedScenario]) {
        $lblScnSub.Visible = $false
        $lblScnValidation.Text = ((T 'Hier nicht möglich: {0}') -f $script:ScnReason[$script:SelectedScenario])
        $lblScnValidation.Visible = $true
        return
    }
    switch ($script:SelectedScenario) {
        1 { Start-ForeignOnPremScenario }
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
            $acct = Show-AccountInputDialog -Prompt (T 'Cloud-Zielkonto/UPN (Entra, z.B. gadmin@contoso.onmicrosoft.com):')
            if (-not $acct) { return }
            # Hybrid-Falle: gibt es das Konto AUCH im lokalen AD, ist Szenario 01 richtig
            # (Zertifikat mit SID: Entra CBA UND lokales Kerberos). Das Offline-Template
            # hier hat keine SID -> Smartcard-Anmeldung am lokalen DC scheitert, kein SSO.
            # AD nicht erreichbar -> keine Aussage möglich, kein Hinweis.
            if ($acct -match '@') {
                $onPrem = Find-OnPremAccountByUpn -Upn $acct
                if ($onPrem -and $onPrem.Found) {
                    $ans = [System.Windows.Forms.MessageBox]::Show(
                        ((T "Das Konto {0} existiert auch im lokalen AD:`r`n{1}`r`n`r`nEs ist also ein HYBRID-Konto, kein reines Cloud-Konto. Dafür ist Szenario 01 vorgesehen: dessen Zertifikat enthält die Konto-SID und funktioniert für die Entra-Anmeldung UND für das lokale AD (Kerberos, SSO auf lokale Ressourcen, starke Zuordnung KB5014754). Das Zertifikat aus Szenario 03 hat keine SID - die Smartcard-Anmeldung am lokalen DC wird abgelehnt.`r`n`r`nJa = zu Szenario 01 wechseln (empfohlen)`r`nNein = trotzdem mit Szenario 03 fortfahren`r`nAbbrechen = zurück") -f $acct, $onPrem.DistinguishedName),
                        (T 'Hybrid-Konto erkannt'), 'YesNoCancel', 'Warning')
                    if ($ans -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
                    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                        if ($script:ScnAvailable.ContainsKey(1) -and -not $script:ScnAvailable[1]) {
                            [System.Windows.Forms.MessageBox]::Show(((T 'Szenario 01 ist hier nicht möglich: {0}') -f $script:ScnReason[1]), (T 'Hybrid-Konto erkannt'), 'OK', 'Information') | Out-Null
                            return
                        }
                        Write-WizardLog -Message "Szenario 03 -> 01: '$acct' ist ein Hybrid-Konto ($($onPrem.DistinguishedName))." -Level Info
                        Select-ScenarioById -Id 1
                        Start-ForeignOnPremScenario -Prefill $acct
                        return
                    }
                    Write-WizardLog -Message "Szenario 03 trotz Hybrid-Konto '$acct' fortgesetzt (Benutzerwahl)." -Level Info
                }
            }
            $script:TargetAccount = $acct
            $script:PlanA_OfflineDirect = $true
            [System.Windows.Forms.MessageBox]::Show(((T "Zertifikat für {0} über das Offline-Template (NUR Entra CBA / Cloud):`r`n`r`n- Du reichst als DU ein (dein Konto braucht Enroll-Recht auf dem Supply-in-request-Template).`r`n- Die Ziel-UPN steht im CSR-SAN; Entra mappt darüber (Binding) und vertraut der hochgeladenen CA-Kette.`r`n- Danach in Entra: ausstellende CA importieren + CBA-Binding auf UPN (siehe RUNBOOK). Alternative ganz ohne PKI: FIDO2/Passkey.`r`n`r`nWICHTIG: Das taugt NICHT für On-Prem-AD-Smartcard-Logon - dafür fehlt die Konto-SID (starke Zuordnung, KB5014754). Für On-Prem- oder Hybrid-Konten stattdessen Szenario 01 (fremdes Konto) bzw. 02 (eigenes Konto).") -f $acct), (T 'Cloud-Konto / Entra CBA'), 'OK', 'Information') | Out-Null
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

# Einklappbares Protokoll über der Fußleiste (vorher dauerhaft ~1/5 des Fensters).
$logDrawer = New-Object System.Windows.Forms.Panel
$logDrawer.Dock = 'Bottom'; $logDrawer.Height = 200
$logDrawer.BackColor = $script:UI.Surface
$logDrawer.Visible = $false
Add-BorderPaint -Control $logDrawer -TopOnly
$mainArea.Controls.Add($logDrawer)

$logToolbar = New-Object System.Windows.Forms.Panel
$logToolbar.Dock = 'Top'; $logToolbar.Height = 36
$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = (T 'Protokoll'); $lblLogTitle.Font = New-UiFont 9 -Semibold; $lblLogTitle.ForeColor = $script:UI.Text
$lblLogTitle.AutoSize = $true; $lblLogTitle.Location = New-Object System.Drawing.Point(40, 10)
$btnExportLog = New-Object System.Windows.Forms.LinkLabel
$btnExportLog.Text = (T 'Protokoll exportieren...'); $btnExportLog.AutoSize = $true; $btnExportLog.Font = New-UiFont 9
$btnExportLog.LinkColor = $script:UI.Accent; $btnExportLog.LinkBehavior = 'HoverUnderline'
$logToolbar.Controls.AddRange(@($lblLogTitle, $btnExportLog))
$logToolbar.Add_Layout({ $btnExportLog.Location = New-Object System.Drawing.Point(($logToolbar.ClientSize.Width - 40 - $btnExportLog.Width), 10) })

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'
$rtbLog.ReadOnly = $true
$rtbLog.BorderStyle = 'None'
$rtbLog.BackColor = $script:UI.Surface
$rtbLog.Font = New-UiFont 9 -Mono
$logInner = New-Object System.Windows.Forms.Panel
$logInner.Dock = 'Fill'; $logInner.Padding = New-Object System.Windows.Forms.Padding(40, 0, 24, 8)
$logInner.Controls.Add($rtbLog)
$logDrawer.Controls.Add($logInner)
$logDrawer.Controls.Add($logToolbar)
$logInner.BringToFront()

$btnLogToggle.Add_Click({
    $logDrawer.Visible = -not $logDrawer.Visible
    $btnLogToggle.Text = if ($logDrawer.Visible) { (T 'Protokoll ausblenden') } else { (T 'Protokoll anzeigen') }
    if ($logDrawer.Visible) { $rtbLog.SelectionStart = $rtbLog.TextLength; $rtbLog.ScrollToCaret() }
})

# Dock-Reihenfolge im Arbeitsbereich festziehen: zuerst (außen) Kopf und Fußleiste,
# dann das Protokoll über der Fußleiste, zuletzt der Inhalt als Füllung.
$pnlHeader.SendToBack(); $pnlFooter.SendToBack()
$logDrawer.BringToFront(); $pnlContentArea.BringToFront()

$btnExportLog.Add_LinkClicked({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = (T 'Textdatei (*.txt)|*.txt')
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
Update-Splash -Text (T 'Plan A vorbereiten...') -Percent 62

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

$lblJoinStateA = New-WizardLabel -Text (T 'Domänen-Status: ...') -X 20 -Y 20
$lblUserA = New-WizardLabel -Text (T 'Angemeldeter Benutzer: ...') -X 20 -Y 50
$lblTpmA = New-WizardLabel -Text (T 'TPM: ...') -X 20 -Y 80
$lblWarnA = New-WizardLabel -Text '' -X 20 -Y 120 -Style Bold
$pnlA1.Controls.AddRange(@($lblJoinStateA, $lblUserA, $lblTpmA, $lblWarnA))

# --- Schritt A2: VSC erstellen ---
$pnlA2 = New-Object System.Windows.Forms.Panel
$pnlA2.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA2)

$lblCardNameA = New-WizardLabel -Text (T 'Name der virtuellen Smartcard:') -X 20 -Y 20 -Width 300
$txtCardNameA = New-Object System.Windows.Forms.TextBox
$txtCardNameA.Location = New-Object System.Drawing.Point(20, 46)
$txtCardNameA.Size = New-Object System.Drawing.Size(300, 24)
$txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"

$lblVscInfoA = New-WizardLabel -Text (T 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur für diesen Schritt benötigt). Danach öffnet sich ein Dialog zur Eingabe der Karten-PIN (mindestens 6 Zeichen, mit Bestätigung; der Dialog zeigt die geltende Mindestlänge an). Die Karte wird anschließend über die Windows-Smartcard-API erstellt.') -X 20 -Y 84 -Width 780 -Height 76

$btnCreateVscA = New-Object System.Windows.Forms.Button
$btnCreateVscA.Text = (T 'Virtuelle Smartcard erstellen')
$btnCreateVscA.Location = New-Object System.Drawing.Point(20, 172)
$btnCreateVscA.Size = New-Object System.Drawing.Size(240, 32)

$lblVscResultA = New-WizardLabel -Text '' -X 20 -Y 216 -Width 780 -Height 44

$pnlA2.Controls.AddRange(@($lblCardNameA, $txtCardNameA, $lblVscInfoA, $btnCreateVscA, $lblVscResultA))

$btnCreateVscA.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCardNameA.Text)) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte einen Kartennamen angeben.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateVscA.Enabled = $false
    $lblVscResultA.ForeColor = [System.Drawing.Color]::Black
    $lblVscResultA.Text = (T 'Erstelle virtuelle Smartcard - bitte UAC bestätigen, dann im Dialog die PIN festlegen...')
    Set-Busy -Text (T 'Erstelle virtuelle Smartcard...')
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
            ((T "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der Zertifikatsanforderung) heißt sie: '{0}'.") -f $result.PcscName)
        } else {
            (T 'Virtuelle Smartcard wurde erfolgreich erstellt.')
        }
    } elseif ($result.Cancelled) {
        $lblVscResultA.ForeColor = [System.Drawing.Color]::Black
        $lblVscResultA.Text = (T 'Abgebrochen - es wurde keine Karte erstellt.')
    } else {
        $lblVscResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $detail = if ($result.Message) { $result.Message } else { "Exit-Code $($result.ExitCode)" }
        $lblVscResultA.Text = ((T 'Fehler bei der Erstellung: {0} (Details siehe Log).') -f $detail)
    }
    $btnCreateVscA.Enabled = $true
})

# --- Schritt A3: Zertifikat anfordern ---
$pnlA3 = New-Object System.Windows.Forms.Panel
$pnlA3.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA3)

# Großes Kartensymbol links; rechts daneben der Kartenhinweis (nur bei mehreren VSCs,
# siehe Show-PlanAStep). Die Zeilenhöhe bestimmt das Symbol - mit und ohne Hinweis gleich.
$picCardA = New-CardPicture -X 20 -Y 16
$lblCardHintA = New-WizardLabel -Text '' -X 136 -Y 40 -Width 664 -Height 44
$lblCardHintA.ForeColor = [System.Drawing.Color]::ForestGreen
$lblCardHintA.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

# Alles unterhalb des (bis zu zweizeiligen, fetten) Karten-Hinweises beginnt erst bei
# Y 68 - vorher überdeckte das 44 px hohe Hinweislabel die Oberkante von
# "Zertifikatstemplate:".
$lblTemplateA = New-WizardLabel -Text (T 'Zertifikatstemplate:') -X 20 -Y 68 -Width 300
$cboTemplateA = New-Object System.Windows.Forms.ComboBox
$cboTemplateA.Location = New-Object System.Drawing.Point(20, 94)
$cboTemplateA.Size = New-Object System.Drawing.Size(300, 24)
$cboTemplateA.DropDownStyle = 'DropDownList'
Set-TemplateComboItem -ComboBox $cboTemplateA -Template $config.Template

# Nur im Offline-Direkt-Modus (Szenario 03) ohne konfiguriertes OfflineTemplate sichtbar:
# die Combo ist dann ein leeres, editierbares Feld - ohne Erklärung wirkt das wie
# "kein Template wählbar".
$lblTemplateHintA = New-WizardLabel -Text (T 'Kein Offline-Template konfiguriert: bitte den Namen des Supply-in-request-Templates eintippen (dauerhaft: Einstellungen > Offline-Template).') -X 332 -Y 90 -Width 468 -Height 36
$lblTemplateHintA.ForeColor = [System.Drawing.Color]::DarkOrange
$lblTemplateHintA.Visible = $false

$btnRequestCertA = New-Object System.Windows.Forms.Button
$btnRequestCertA.Text = (T 'Zertifikat anfordern')
$btnRequestCertA.Location = New-Object System.Drawing.Point(20, 132)
$btnRequestCertA.Size = New-Object System.Drawing.Size(240, 32)

# Hinweis: Windows fragt bei der Anforderung/Installation mehrfach nach der Karten-PIN -
# ohne Vorwarnung wirkt das wie ein Fehler/eine Schleife.
$lblPinHintA = New-WizardLabel -Text (T 'Hinweis: Windows fragt dabei mehrmals nach der PIN der virtuellen Smartcard (typisch 2-3 Mal) - das ist normal.') -X 276 -Y 128 -Width 524 -Height 40
$lblPinHintA.ForeColor = [System.Drawing.Color]::DimGray

# Höhe 64: der Wartet-auf-Genehmigung-Text samt Genehmigungs-Hinweis braucht bis zu 4 Zeilen.
$lblCertResultA = New-WizardLabel -Text '' -X 20 -Y 176 -Width 780 -Height 64

$btnRetrieveA = New-Object System.Windows.Forms.Button
$btnRetrieveA.Text = (T 'Zertifikat abrufen (bei Genehmigung)')
$btnRetrieveA.Location = New-Object System.Drawing.Point(20, 248)
$btnRetrieveA.Size = New-Object System.Drawing.Size(260, 32)
$btnRetrieveA.Visible = $false

$pnlA3.Controls.AddRange(@($picCardA, $lblCardHintA, $lblTemplateA, $cboTemplateA, $lblTemplateHintA, $btnRequestCertA, $lblPinHintA, $lblCertResultA, $btnRetrieveA))

$btnRequestCertA.Add_Click({
    # Fuer ein separates Zielkonto gibt es zwei direkte Wege:
    #  - EOBO (Enroll on Behalf Of): braucht ein EA-Zertifikat, Build-from-AD.
    #  - Offline-Direkt (Szenario 03, Cloud/Entra CBA): KEIN EA - du reichst als DU ein,
    #    Subject/SAN des Ziels stehen im CSR (Supply-in-request). NUR Cloud, kein On-Prem.
    $eoboThumbprint = $null
    if ($script:TargetAccount -and -not $script:PlanA_OfflineDirect) {
        $eaCerts = @(Get-EnrollmentAgentCertificates)
        if ($eaCerts.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show((T 'Für ein separates On-Prem-Konto ist hier ein Enrollment-Agent-Zertifikat nötig (Enroll on Behalf Of) - es wurde keins im Zertifikatsspeicher gefunden. Entweder in den Einstellungen ein EA-Zertifikat beantragen und diesen Schritt wiederholen, oder Plan B (RDP als Zielkonto) verwenden. (Der Offline-Template-Weg aus Szenario 03 taugt nur für Cloud/Entra CBA, NICHT für On-Prem-Logon.)'), (T 'Separates Konto: EA-Zertifikat nötig'), 'OK', 'Information') | Out-Null
            return
        }
        $eoboThumbprint = $eaCerts[0].Thumbprint
    }
    # Template: im Offline-Direkt-Modus ist die Combo editierbar (SelectedItem kann leer
    # sein, wenn getippt) - deshalb .Text als Rueckfall.
    $selectedTemplate = if ($cboTemplateA.SelectedItem) { "$($cboTemplateA.SelectedItem)" } else { $cboTemplateA.Text.Trim() }
    if (-not $selectedTemplate) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte ein Zertifikatstemplate auswählen bzw. eintragen (im Offline-Modus das Supply-in-request-Template).'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
        return
    }
    $btnRequestCertA.Enabled = $false
    $lblCertResultA.ForeColor = [System.Drawing.Color]::Black
    $lblCertResultA.Text = if ($eoboThumbprint) {
        (T 'Erstelle Enroll-on-Behalf-Of-Antrag - ggf. erscheinen PIN-Dialoge (neue Karte und EA-Zertifikat)...')
    } else {
        (T 'Erstelle Zertifikatsanforderung - ggf. erscheint ein PIN-Dialog der Smartcard...')
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
        $lblCertResultA.Text = (T 'Antragserstellung fehlgeschlagen. Details siehe Log.')
        $btnRequestCertA.Enabled = $true
        return
    }

    $submitTemplate = if ($eoboThumbprint) { $null } else { $selectedTemplate }
    $submit = Submit-CertificateSigningRequest -CsrPath $csr.CsrPath -CAConfig $config.CAConfig -TemplateName $submitTemplate -OutputDirectory $script:PlanA_EnrollDir
    if ($submit.Pending) {
        # Zustand persistieren: der wartende Antrag kann nach einem Wizard-Neustart
        # über den Fortsetzen-Dialog beim Start wieder aufgenommen werden - inkl.
        # Zielkonto und Offline-Modus (sonst zeigte das Fortsetzen das eigene Konto
        # und das Standard-Template).
        Save-WizardResumeState -State @{
            Plan = 'A'; Stage = 'Pending'; RequestId = $submit.RequestId
            CardName = $script:PlanA_CardName; PcscName = "$($script:PlanA_PcscName)"
            EnrollDir = $script:PlanA_EnrollDir
            TargetAccount = "$($script:TargetAccount)"; OfflineDirect = "$([bool]$script:PlanA_OfflineDirect)"
            Template = "$selectedTemplate"
        }
        Set-PlanAPendingUi -RequestId $submit.RequestId -Text ((T 'Antrag wurde eingereicht und wartet auf Genehmigung (RequestId {0}). {1} Auch nach einem Neustart des Wizards möglich.') -f $submit.RequestId, (Get-PendingApprovalHint -RequestId $submit.RequestId))
        return
    }
    if (-not $submit.Success) {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = (T 'Antrag fehlgeschlagen. Details siehe Log.')
        $btnRequestCertA.Enabled = $true
        return
    }

    $complete = Complete-CertificateEnrollment -CerPath $submit.CerPath
    if ($complete.Success) {
        $script:PlanA_CertIssued = $true
        if ($script:SimpleMode) { Set-VscEnrollMarker | Out-Null }   # Intune-Erkennung App 2
        Clear-WizardResumeState
        $lblCertResultA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCertResultA.Text = (T 'Zertifikat wurde erfolgreich auf der virtuellen Smartcard hinterlegt.')
        if ($script:PlanA_RenewMode) {
            $idA = Get-EnrollmentIdentity
            Invoke-RenewalCleanup -PcscName $script:PlanA_PcscName -UpnOrTerm $(if ($idA.Upn) { $idA.Upn } else { $idA.SearchTerm })
            Update-PlanASummary
        }
    } else {
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = (T 'Übernahme des Zertifikats fehlgeschlagen. Details siehe Log.')
    }
    Update-IssueButtons   # nach Erfolg gesperrt, nach Fehler wieder frei
})

$btnRetrieveA.Add_Click({
    $script:PlanA_PendingRequestId = Resolve-PendingRequestId -RequestId $script:PlanA_PendingRequestId
    if (-not $script:PlanA_PendingRequestId) { return }
    # Während des Abrufs gesperrt: ein zweiter Klick darf den Abruf/die Installation
    # (mit erneuter PIN-Abfrage) nicht ein weiteres Mal auslösen.
    $btnRetrieveA.Enabled = $false
    try {
        Invoke-PlanARetrieve
    } finally {
        [System.Windows.Forms.Application]::DoEvents()   # gepufferte Klicks am gesperrten Button verwerfen
        $btnRetrieveA.Enabled = $true
    }
})

function Invoke-PlanARetrieve {
    $recv = Receive-PendingCertificate -RequestId $script:PlanA_PendingRequestId -CAConfig $config.CAConfig -OutputDirectory $script:PlanA_EnrollDir
    if ($recv.Success) {
        $complete = Complete-CertificateEnrollment -CerPath $recv.CerPath
        if ($complete.Success) {
            $script:PlanA_CertIssued = $true
            if ($script:SimpleMode) { Set-VscEnrollMarker | Out-Null }   # Intune-Erkennung App 2
            Clear-WizardResumeState
            $btnRetrieveA.Visible = $false
            $lblCertResultA.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblCertResultA.Text = (T 'Zertifikat wurde erfolgreich abgerufen und auf der virtuellen Smartcard hinterlegt.')
            if ($script:PlanA_RenewMode) {
                $idA = Get-EnrollmentIdentity
                Invoke-RenewalCleanup -PcscName $script:PlanA_PcscName -UpnOrTerm $(if ($idA.Upn) { $idA.Upn } else { $idA.SearchTerm })
                Update-PlanASummary
            }
        } else {
            # Vorher ohne jede Anzeige: abgerufen, aber nicht auf die Karte übernommen
            # (z.B. PIN-Abfrage abgebrochen). Erneutes "Zertifikat abrufen" wiederholt es.
            $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
            $lblCertResultA.Text = ((T "Zertifikat wurde abgerufen ({0}), aber nicht auf die Smartcard übernommen (z.B. PIN-Abfrage abgebrochen) - 'Zertifikat abrufen' erneut klicken. Details siehe Log.") -f $recv.CerPath)
        }
    } elseif ($recv.Status -eq 'Denied') {
        # Abgelehnt: der Antrag ist erledigt - "Anfordern" wieder frei für einen neuen.
        Clear-WizardResumeState
        Reset-PlanARequestUi
        $lblCertResultA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCertResultA.Text = $recv.Message
    } else {
        $lblCertResultA.ForeColor = if ($recv.Status -eq 'Pending') { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::Firebrick }
        $lblCertResultA.Text = $recv.Message
    }
}

# --- Schritt A4: Zusammenfassung ---
$pnlA4 = New-Object System.Windows.Forms.Panel
$pnlA4.Dock = 'Fill'
$pnlStepsA.Controls.Add($pnlA4)

$lblSummaryA = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 190
$btnResetA = New-Object System.Windows.Forms.Button
$btnResetA.Text = (T 'Weitere Smartcard beantragen')
$btnResetA.Location = New-Object System.Drawing.Point(20, 220)
$btnResetA.Size = New-Object System.Drawing.Size(240, 32)

$btnStartA = New-Object System.Windows.Forms.Button
$btnStartA.Text = (T 'Zum Startbildschirm')
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
        $certs = @(Invoke-Busy -Text (T 'Lese Zertifikate der Smartcard...') -Action { Get-SmartCardCertificates } |
            Where-Object { $_.Reader -and ($_.Reader -eq $PcscName) } |
            Sort-Object NotAfter)
    }

    if ($certs.Count -eq 0) {
        $summary = Get-IssuedCertificateSummary -Match $MatchTerm
        if ($summary) {
            return (T "Kartenname: {0}`r`nZertifikat: {1}`r`nThumbprint: {2}`r`nGültig ab: {3}`r`nGültig bis: {4}") -f $CardName, $summary.Subject, $summary.Thumbprint, $summary.NotBefore, $summary.NotAfter
        }
        return (T "Kartenname: {0}`r`nKein passendes Zertifikat gefunden.") -f $CardName
    }

    if ($certs.Count -eq 1) {
        $c = $certs[0]
        return (T "Kartenname: {0}`r`nZertifikat: {1}`r`nThumbprint: {2}`r`nGültig ab: {3}`r`nGültig bis: {4}") -f $CardName, $c.Subject, $c.Thumbprint, $c.NotBefore, $c.NotAfter
    }

    # Mehrere Zertifikate auf der Karte -> je Zertifikat die Gültigkeit einzeln.
    $lines = @(((T 'Kartenname: {0}') -f $CardName), ((T 'Auf der Karte liegen {0} Zertifikate:') -f $certs.Count))
    $i = 0
    foreach ($c in $certs) {
        $i++
        $lines += "  $i) $($c.Subject)"
        $lines += (T '     gültig {0} bis {1}  (Thumbprint {2})') -f $c.NotBefore.ToString('yyyy-MM-dd'), $c.NotAfter.ToString('yyyy-MM-dd'), $c.Thumbprint
    }
    $lines += (T 'Hinweis: Beim Smartcard-Logon nutzt Windows i.d.R. das erste passende Zertifikat. Für "eine Karte = ein Zertifikat" die älteren entfernen (Aufräum-Abfrage nach dem Erneuern oder Szenario 04).')
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
    $txtCardNameA.Text = "$($config.VscNamePrefix)-$env:USERNAME"
    $lblVscResultA.Text = ''
    Reset-PlanARequestUi
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
$planAStepTitles = @((T 'Virtuelle Smartcard erstellen'), (T 'Zertifikat anfordern'), (T 'Zusammenfassung'))
$planAStepperLabels = @((T 'Smartcard'), (T 'Zertifikat'), (T 'Fertig'))   # kurz, für die Seitenleiste

function Update-PlanAStatus {
    $joinState = Get-DomainJoinState
    $tpm = Test-TpmReadiness
    $upn = Get-CurrentUpn

    $lblJoinStateA.Text = ((T 'Domänen-Status: {0}') -f $joinState.Mode) + $(if ($joinState.Domain) { " ($($joinState.Domain))" } else { '' })
    $lblUserA.Text = ((T 'Angemeldeter Benutzer: {0}') -f "$env:USERDOMAIN\$env:USERNAME") + $(if ($upn) { " (UPN: $upn)" } else { '' })
    $lblTpmA.Text = (T 'TPM: vorhanden={0}, bereit={1}') -f $tpm.Present, $tpm.Ready

    if ($script:TargetAccount -and $script:PlanA_OfflineDirect) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblWarnA.Text = ((T 'Direkt-Ausstellung für ein separates Konto ({0}) über das Offline-Template: du reichst als DU ein (Enroll-Recht auf dem Supply-in-request-Template nötig), Ziel-Subject/UPN stehen im CSR. Kein EA, kein RDP. In Schritt 3 das Offline-Template wählen/eintragen.') -f $script:TargetAccount)
    } elseif ($script:TargetAccount) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblWarnA.Text = ((T 'Smartcard wird für ein separates Konto beantragt ({0}) - die Ausstellung in Schritt 3 erfolgt bruchfrei per Enroll on Behalf Of (Enrollment-Agent-Zertifikat), ohne RDP.') -f $script:TargetAccount)
    } elseif ($joinState.Mode -ne 'ADDomain') {
        $lblWarnA.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblWarnA.Text = (T 'Dieser Rechner scheint nicht domänen-gebunden zu sein. Für diesen Fall ist "Plan B" vorgesehen.')
    } elseif (-not $tpm.Ready) {
        $lblWarnA.ForeColor = [System.Drawing.Color]::Firebrick
        $lblWarnA.Text = (T 'Kein bereites TPM erkannt - die Erstellung einer virtuellen Smartcard ist eventuell nicht möglich.')
    } else {
        $lblWarnA.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblWarnA.Text = (T 'Voraussetzungen erfüllt.')
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
    Update-IssueButtons
    # Globale Schrittnummer: +2, da Schritt 1 (Szenario) davor liegt.
    $lblGlobalStep.Text = $planAStepTitles[$Index]
    if ($script:SimpleMode) {
        # Simple-Modus: Start / Eigene PIN (erledigt) / Zertifikat / Fertig.
        Update-Stepper -Labels @((T 'Start'), (T 'Eigene PIN'), (T 'Zertifikat'), (T 'Fertig')) -Current ([Math]::Min(3, $Index + 1)) -Subs @{ 0 = (Get-EnrollmentIdentity).DisplayName; 1 = "$($script:PlanA_CardName)" }
    } else {
        Update-Stepper -Labels (@((T 'Szenario')) + $planAStepperLabels) -Current ($Index + 1) -Subs @{ 0 = (Get-EnrollmentIdentity).DisplayName; 1 = "$($script:PlanA_CardName)" }
    }
    $btnBackShared.Enabled = $true
    $btnNextShared.Enabled = ($Index -lt $panels.Count - 1)
    # Simple-Modus: auf der Zusammenfassung schließt "Fertig" den Wizard; "Weitere
    # Smartcard"/"Zum Startbildschirm" und "Zurück" sind dort nichts für normale Benutzer.
    $simpleEnd = $script:SimpleMode -and $Index -eq $panels.Count - 1
    $btnResetA.Visible = -not $simpleEnd; $btnStartA.Visible = -not $simpleEnd
    $btnNextShared.Text = if ($simpleEnd) { T 'Fertig' } else { T 'Weiter' }
    if ($simpleEnd) { $btnNextShared.Enabled = $true; $btnBackShared.Enabled = $false }

    switch ($Index) {
        1 {
            # Windows-Kartenauswahl-/PIN-Dialoge zeigen NICHT den vergebenen
            # Kartennamen, sondern den PC/SC-Namen "Microsoft Virtual Smart Card N".
            $lblCardHintA.Text = if ($script:PlanA_PcscName -and (Get-VscCardCount) -gt 1) {
                ((T "➜ Im Windows-Kartenauswahl-Dialog die Karte `"{0}`" wählen  (= '{1}').") -f $script:PlanA_PcscName, $script:PlanA_CardName)
            } else { '' }
            Update-OfflineTemplateChoices
        }
        2 { Update-PlanASummary }
    }
}

function Invoke-PlanANextClick {
    switch ($script:PlanACurrentStep) {
        0 {
            if (-not $script:PlanA_VscCreated) {
                [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst die virtuelle Smartcard erstellen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanAStep -Index 1
        }
        1 {
            if (-not $script:PlanA_CertIssued) {
                [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst das Zertifikat erfolgreich anfordern.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
                return
            }
            Show-PlanAStep -Index 2
        }
        2 {
            # Simple-Modus: "Fertig" auf der Zusammenfassung schließt den Wizard (normale
            # Benutzer sollen nicht zur Startseite zurück).
            if ($script:SimpleMode) { Close-WizardWindow }
        }
    }
}

function Invoke-PlanABackClick {
    # Im Verlängern-Modus wurde direkt bei "Anfordern" (jetzt Index 1) eingestiegen -
    # "Zurück" führt dort zur Szenario-Auswahl, nicht zum (übersprungenen) Erstellen.
    if ($script:PlanA_RenewMode -and $script:PlanACurrentStep -eq 1) {
        $tabPlanA.Visible = $false
        if ($script:SimpleMode) { Show-SimpleStart; return }   # nie zur Szenario-Auswahl
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
Update-Splash -Text (T 'Plan B vorbereiten...') -Percent 70

$pnlStepsB = New-Object System.Windows.Forms.Panel
$pnlStepsB.Dock = 'Fill'
$tabPlanB.Controls.Add($pnlStepsB)

# --- Schritt B1: Status ---
$pnlB1 = New-Object System.Windows.Forms.Panel
$pnlB1.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB1)

$lblJoinStateB = New-WizardLabel -Text (T 'Domänen-Status: ...') -X 20 -Y 20
$lblUserB = New-WizardLabel -Text (T 'Angemeldeter Benutzer: ...') -X 20 -Y 50
$lblTargetB = New-WizardLabel -Text '' -X 20 -Y 80
$lblJumpServerB = New-WizardLabel -Text '' -X 20 -Y 110
$lblExplainB = New-WizardLabel -Text (T 'Dieser Modus führt eine virtuelle Smartcard und einen Zertifikatsantrag über einen Zwischenschritt per RDP durch, da entweder dieser Rechner keine direkte Sicht auf die Zertifizierungsstelle hat oder die Einreichung als separates Zielkonto erfolgen muss. CA-Konfiguration und automatische PKI-Erkennung finden sich im Tab "Einstellungen".') -X 20 -Y 146 -Width 780 -Height 60
$pnlB1.Controls.AddRange(@($lblJoinStateB, $lblUserB, $lblTargetB, $lblJumpServerB, $lblExplainB))

# --- Schritt B2: VSC erstellen ---
$pnlB2 = New-Object System.Windows.Forms.Panel
$pnlB2.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB2)

$lblCardNameB = New-WizardLabel -Text (T 'Name der virtuellen Smartcard:') -X 20 -Y 20 -Width 300
$txtCardNameB = New-Object System.Windows.Forms.TextBox
$txtCardNameB.Location = New-Object System.Drawing.Point(20, 46)
$txtCardNameB.Size = New-Object System.Drawing.Size(300, 24)
$txtCardNameB.Text = "$($config.VscNamePrefix)-$env:USERNAME"

$lblVscInfoB = New-WizardLabel -Text (T 'Beim Klick auf "Erstellen" erscheint eine UAC-Abfrage (lokale Adminrechte werden nur für diesen Schritt benötigt). Danach öffnet sich ein Dialog zur Eingabe der Karten-PIN (mindestens 6 Zeichen, mit Bestätigung; der Dialog zeigt die geltende Mindestlänge an). Die Karte wird anschließend über die Windows-Smartcard-API erstellt.') -X 20 -Y 84 -Width 780 -Height 76

$btnCreateVscB = New-Object System.Windows.Forms.Button
$btnCreateVscB.Text = (T 'Virtuelle Smartcard erstellen')
$btnCreateVscB.Location = New-Object System.Drawing.Point(20, 172)
$btnCreateVscB.Size = New-Object System.Drawing.Size(240, 32)

$lblVscResultB = New-WizardLabel -Text '' -X 20 -Y 216 -Width 780 -Height 44

$pnlB2.Controls.AddRange(@($lblCardNameB, $txtCardNameB, $lblVscInfoB, $btnCreateVscB, $lblVscResultB))

$btnCreateVscB.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCardNameB.Text)) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte einen Kartennamen angeben.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
        return
    }
    $btnCreateVscB.Enabled = $false
    $lblVscResultB.ForeColor = [System.Drawing.Color]::Black
    $lblVscResultB.Text = (T 'Erstelle virtuelle Smartcard - bitte UAC bestätigen, dann im Dialog die PIN festlegen...')
    Set-Busy -Text (T 'Erstelle virtuelle Smartcard...')
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
            ((T "Virtuelle Smartcard wurde erfolgreich erstellt. In Windows-Kartendialogen (z.B. bei der CSR-Erstellung) heißt sie: '{0}'.") -f $result.PcscName)
        } else {
            (T 'Virtuelle Smartcard wurde erfolgreich erstellt.')
        }
    } elseif ($result.Cancelled) {
        $lblVscResultB.ForeColor = [System.Drawing.Color]::Black
        $lblVscResultB.Text = (T 'Abgebrochen - es wurde keine Karte erstellt.')
    } else {
        $lblVscResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $detail = if ($result.Message) { $result.Message } else { "Exit-Code $($result.ExitCode)" }
        $lblVscResultB.Text = ((T 'Fehler bei der Erstellung: {0} (Details siehe Log).') -f $detail)
    }
    $btnCreateVscB.Enabled = $true
})

# --- Schritt B3: CSR erstellen (lokal) ---
$pnlB3 = New-Object System.Windows.Forms.Panel
$pnlB3.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB3)

$picCardB = New-CardPicture -X 20 -Y 16
$lblCsrInfoB = New-WizardLabel -Text (T 'Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Windows fragt dabei ggf. mehrmals nach der PIN der Smartcard - das ist normal.') -X 136 -Y 40 -Width 664 -Height 48

$btnCreateCsrB = New-Object System.Windows.Forms.Button
$btnCreateCsrB.Text = (T 'CSR erstellen')
$btnCreateCsrB.Location = New-Object System.Drawing.Point(20, 66)
$btnCreateCsrB.Size = New-Object System.Drawing.Size(240, 32)

$lblCsrPathLabelB = New-WizardLabel -Text (T 'Pfad der CSR-Datei:') -X 20 -Y 110 -Width 300
$txtCsrPathB = New-Object System.Windows.Forms.TextBox
$txtCsrPathB.Location = New-Object System.Drawing.Point(20, 136)
$txtCsrPathB.Size = New-Object System.Drawing.Size(560, 24)
$txtCsrPathB.ReadOnly = $true

$btnCopyCsrPathB = New-Object System.Windows.Forms.Button
$btnCopyCsrPathB.Text = (T 'Pfad kopieren')
$btnCopyCsrPathB.Location = New-Object System.Drawing.Point(590, 134)
$btnCopyCsrPathB.Size = New-Object System.Drawing.Size(120, 28)

$btnOpenCsrFolderB = New-Object System.Windows.Forms.Button
$btnOpenCsrFolderB.Text = (T 'Ordner öffnen')
$btnOpenCsrFolderB.Location = New-Object System.Drawing.Point(20, 172)
$btnOpenCsrFolderB.Size = New-Object System.Drawing.Size(160, 28)

$lblCsrTextLabelB = New-WizardLabel -Text (T 'CSR-Text (PEM) - Alternative zur Dateifreigabe: per RDP-Zwischenablage in den Einreichungshelfer (VscWizard.Submit.ps1) auf dem Zielserver einfügen:') -X 20 -Y 216 -Width 780 -Height 34
$txtCsrTextB = New-Object System.Windows.Forms.TextBox
$txtCsrTextB.Location = New-Object System.Drawing.Point(20, 254)
$txtCsrTextB.Size = New-Object System.Drawing.Size(780, 120)
$txtCsrTextB.Multiline = $true
$txtCsrTextB.ReadOnly = $true
$txtCsrTextB.ScrollBars = 'Vertical'
$txtCsrTextB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnCopyCsrTextB = New-Object System.Windows.Forms.Button
$btnCopyCsrTextB.Text = (T 'CSR-Text kopieren')
$btnCopyCsrTextB.Location = New-Object System.Drawing.Point(20, 380)
$btnCopyCsrTextB.Size = New-Object System.Drawing.Size(160, 28)

$pnlB3.Controls.AddRange(@($picCardB, $lblCsrInfoB, $btnCreateCsrB, $lblCsrPathLabelB, $txtCsrPathB, $btnCopyCsrPathB, $btnOpenCsrFolderB, $lblCsrTextLabelB, $txtCsrTextB, $btnCopyCsrTextB))

$btnCreateCsrB.Add_Click({
    if (-not $script:PlanB_VscCreated) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst die virtuelle Smartcard erstellen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
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
        [System.Windows.Forms.MessageBox]::Show((T 'CSR-Erstellung fehlgeschlagen. Details siehe Log.'), (T 'Fehler'), 'OK', 'Error') | Out-Null
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
        (T 'Die Einreichung bei der CA muss als {0} erfolgen (Berechtigungsprüfung der CA basiert auf dem einreichenden Konto) - dieser Rechner reicht dafür nicht, unabhängig vom Domänen-Status.') -f $identity.DisplayName
    } else {
        (T 'Dieser Rechner hat vermutlich keine direkte Sicht auf die Zertifizierungsstelle.')
    }

    # Mehrzeiliger Übergabetext als eine übersetzbare Vorlage ({0}..{3} = Werte).
    $lblHandoffB.Text = (T "Nächste Schritte:`r`n`r`n{0}`r`n`r`n1. Die CSR ist bereits in der Zwischenablage (auch als Datei: {1}).`r`n2. Per RDP verbinden mit: {2} - dort anmelden als: {3}`r`n3. Auf dem Server den Einreichungshelfer 'VscWizard.Submit.ps1' (bzw. VscWizard.Submit.exe) starten, die CSR einfügen, CA/Template wählen und `"Antrag einreichen`".`r`n4. Das ausgestellte Zertifikat dort mit `"Kopieren`" in die Zwischenablage holen.`r`n`r`nDann hier auf `"Weiter`" klicken: du gelangst direkt zum Schritt `"Zertifikat abschließen`", wo du das kopierte Zertifikat einfügst und übernimmst. Die Übernahme erfolgt auf DIESEM Rechner in DEINEM Konto - die Karte (und der offene Antrag) liegen hier, nicht beim Zielkonto.") -f $reason, $script:PlanB_CsrPath, $config.RdpJumpServer, $identity.DisplayName
}

# --- Schritt B5: Antrag einreichen (auf dem Server) ---
$pnlB5 = New-Object System.Windows.Forms.Panel
$pnlB5.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB5)

$lblSubmitInfoB = New-WizardLabel -Text (T 'Auf dem CA-nahen Server auszuführen (angemeldet als Zielbenutzer). Standardweg: den per Zwischenablage mitgebrachten CSR-Text unten einfügen. Wurde der Antrag bereits anderweitig eingereicht (z.B. mit dem Einreichungshelfer VscWizard.Submit.ps1), diesen Schritt einfach mit "Weiter" überspringen.') -X 20 -Y 20 -Width 780 -Height 50

$lblCsrPasteLabelB = New-WizardLabel -Text (T 'CSR-Text (PEM) einfügen:') -X 20 -Y 74 -Width 300
$txtCsrPasteB = New-Object System.Windows.Forms.TextBox
$txtCsrPasteB.Location = New-Object System.Drawing.Point(20, 100)
$txtCsrPasteB.Size = New-Object System.Drawing.Size(780, 90)
$txtCsrPasteB.Multiline = $true
$txtCsrPasteB.ScrollBars = 'Vertical'
$txtCsrPasteB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnSelectCsrB = New-Object System.Windows.Forms.Button
$btnSelectCsrB.Text = (T '...oder CSR-Datei auswählen')
$btnSelectCsrB.Location = New-Object System.Drawing.Point(20, 198)
$btnSelectCsrB.Size = New-Object System.Drawing.Size(200, 28)

$txtSelectedCsrB = New-Object System.Windows.Forms.TextBox
$txtSelectedCsrB.Location = New-Object System.Drawing.Point(230, 200)
$txtSelectedCsrB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCsrB.ReadOnly = $true

$lblTemplateSubmitB = New-WizardLabel -Text (T 'Zertifikatstemplate:') -X 20 -Y 236 -Width 200
$cboTemplateSubmitB = New-Object System.Windows.Forms.ComboBox
$cboTemplateSubmitB.Location = New-Object System.Drawing.Point(230, 232)
$cboTemplateSubmitB.Size = New-Object System.Drawing.Size(300, 24)
$cboTemplateSubmitB.DropDownStyle = 'DropDownList'
Set-TemplateComboItem -ComboBox $cboTemplateSubmitB -Template $config.Template

$btnSubmitB = New-Object System.Windows.Forms.Button
$btnSubmitB.Text = (T 'Einreichen')
$btnSubmitB.Location = New-Object System.Drawing.Point(20, 270)
$btnSubmitB.Size = New-Object System.Drawing.Size(200, 32)

$btnRetrieveB = New-Object System.Windows.Forms.Button
$btnRetrieveB.Text = (T 'Zertifikat abrufen (bei Genehmigung)')
$btnRetrieveB.Location = New-Object System.Drawing.Point(230, 270)
$btnRetrieveB.Size = New-Object System.Drawing.Size(260, 32)
$btnRetrieveB.Visible = $false

# Höhe 64: der Wartet-auf-Genehmigung-Text samt Genehmigungs-Hinweis braucht bis zu 4 Zeilen.
$lblSubmitResultB = New-WizardLabel -Text '' -X 20 -Y 310 -Width 780 -Height 64

$lblCerPathLabelB = New-WizardLabel -Text (T 'Pfad der ausgestellten Zertifikatsdatei:') -X 20 -Y 378 -Width 400
$txtCerPathB = New-Object System.Windows.Forms.TextBox
$txtCerPathB.Location = New-Object System.Drawing.Point(20, 404)
$txtCerPathB.Size = New-Object System.Drawing.Size(560, 24)
$txtCerPathB.ReadOnly = $true

$btnCopyCerPathB = New-Object System.Windows.Forms.Button
$btnCopyCerPathB.Text = (T 'Pfad kopieren')
$btnCopyCerPathB.Location = New-Object System.Drawing.Point(590, 402)
$btnCopyCerPathB.Size = New-Object System.Drawing.Size(120, 28)

$btnOpenCerFolderB = New-Object System.Windows.Forms.Button
$btnOpenCerFolderB.Text = (T 'Ordner öffnen')
$btnOpenCerFolderB.Location = New-Object System.Drawing.Point(20, 440)
$btnOpenCerFolderB.Size = New-Object System.Drawing.Size(160, 28)

$pnlB5.Controls.AddRange(@($lblSubmitInfoB, $lblCsrPasteLabelB, $txtCsrPasteB, $btnSelectCsrB, $txtSelectedCsrB, $lblTemplateSubmitB, $cboTemplateSubmitB, $btnSubmitB, $btnRetrieveB, $lblSubmitResultB, $lblCerPathLabelB, $txtCerPathB, $btnCopyCerPathB, $btnOpenCerFolderB))

$btnSelectCsrB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = (T 'CSR-Dateien (*.csr;*.req)|*.csr;*.req|Alle Dateien (*.*)|*.*')
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
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst den CSR-Text einfügen (oder alternativ eine CSR-Datei auswählen).'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
        return
    }
    $csrClean = ConvertTo-CleanPemRequest -Text $csrRaw
    if (-not $csrClean) {
        [System.Windows.Forms.MessageBox]::Show((T 'Der eingefügte/geladene Text ist keine gültige Zertifikatsanforderung (kein gültiges Base64-PEM). Bitte die CSR aus Schritt 3 erneut kopieren und einfügen.'), (T 'Ungültige CSR'), 'OK', 'Warning') | Out-Null
        return
    }
    $csrPath = Join-Path (Get-WizardWorkingDir) "PlanB-pasted-$([guid]::NewGuid()).req"
    Set-Content -Path $csrPath -Value $csrClean -Encoding ASCII -NoNewline
    if (-not $cboTemplateSubmitB.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte ein Zertifikatstemplate auswählen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
        return
    }
    $btnSubmitB.Enabled = $false
    $script:PlanB_SubmitDir = Split-Path $csrPath -Parent

    $submit = Submit-CertificateSigningRequest -CsrPath $csrPath -CAConfig $config.CAConfig -TemplateName $cboTemplateSubmitB.SelectedItem -OutputDirectory $script:PlanB_SubmitDir
    if ($submit.Pending) {
        Save-WizardResumeState -State @{
            Plan = 'B'; Stage = 'Pending'; RequestId = $submit.RequestId
            SubmitDir = $script:PlanB_SubmitDir
            CardName = "$($script:PlanB_CardName)"; PcscName = "$($script:PlanB_PcscName)"
            TargetAccount = "$($script:TargetAccount)"
        }
        # Wartet: "Einreichen" bleibt gesperrt (siehe Set-PlanBPendingUi).
        Set-PlanBPendingUi -RequestId $submit.RequestId -Text ((T 'Antrag wartet auf Genehmigung (RequestId {0}). {1} Auch nach einem Neustart des Wizards möglich.') -f $submit.RequestId, (Get-PendingApprovalHint -RequestId $submit.RequestId))
        return
    } elseif ($submit.Success) {
        $txtCerPathB.Text = $submit.CerPath
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblSubmitResultB.Text = (T 'Zertifikat wurde ausgestellt.')
    } else {
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblSubmitResultB.Text = (T 'Antrag fehlgeschlagen. Details siehe Log.')
    }
    $btnSubmitB.Enabled = $true
})

$btnRetrieveB.Add_Click({
    $script:PlanB_PendingRequestId = Resolve-PendingRequestId -RequestId $script:PlanB_PendingRequestId
    if (-not $script:PlanB_PendingRequestId) { return }
    $btnRetrieveB.Enabled = $false   # siehe btnRetrieveA: kein doppelter Abruf
    try {
        $recv = Receive-PendingCertificate -RequestId $script:PlanB_PendingRequestId -CAConfig $config.CAConfig -OutputDirectory $script:PlanB_SubmitDir
    } finally {
        [System.Windows.Forms.Application]::DoEvents()
        $btnRetrieveB.Enabled = $true
    }
    if ($recv.Success) {
        $txtCerPathB.Text = $recv.CerPath
        $btnRetrieveB.Visible = $false
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblSubmitResultB.Text = (T 'Zertifikat wurde abgerufen.')
    } elseif ($recv.Status -eq 'Denied') {
        # Abgelehnt: Antrag erledigt - "Einreichen" wieder frei für einen neuen.
        Clear-WizardResumeState
        Reset-PlanBSubmitUi
        $lblSubmitResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblSubmitResultB.Text = $recv.Message
    } else {
        $lblSubmitResultB.ForeColor = if ($recv.Status -eq 'Pending') { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::Firebrick }
        $lblSubmitResultB.Text = $recv.Message
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

$lblCompleteInfoB = New-WizardLabel -Text (T 'Zurück auf dem lokalen Rechner (im eigenen Konto): entweder die vom Server zurückkopierte Zertifikatsdatei (.cer) auswählen, oder den Text direkt einfügen (z.B. Ergebnis des Einreichungshelfers VscWizard.Submit.ps1).') -X 20 -Y 20 -Width 780 -Height 40

$btnSelectCerB = New-Object System.Windows.Forms.Button
$btnSelectCerB.Text = (T 'CER-Datei auswählen...')
$btnSelectCerB.Location = New-Object System.Drawing.Point(20, 66)
$btnSelectCerB.Size = New-Object System.Drawing.Size(200, 30)

$txtSelectedCerB = New-Object System.Windows.Forms.TextBox
$txtSelectedCerB.Location = New-Object System.Drawing.Point(230, 70)
$txtSelectedCerB.Size = New-Object System.Drawing.Size(500, 24)
$txtSelectedCerB.ReadOnly = $true

$btnCompleteB = New-Object System.Windows.Forms.Button
$btnCompleteB.Text = (T 'Aus Datei übernehmen')
$btnCompleteB.Location = New-Object System.Drawing.Point(20, 110)
$btnCompleteB.Size = New-Object System.Drawing.Size(200, 32)

$lblCerTextLabelB = New-WizardLabel -Text (T '...oder CER-Text hier einfügen:') -X 20 -Y 156 -Width 780
$txtCerTextB = New-Object System.Windows.Forms.TextBox
$txtCerTextB.Location = New-Object System.Drawing.Point(20, 182)
$txtCerTextB.Size = New-Object System.Drawing.Size(780, 110)
$txtCerTextB.Multiline = $true
$txtCerTextB.ScrollBars = 'Vertical'
$txtCerTextB.Font = New-Object System.Drawing.Font('Consolas', 9)

$btnCompleteFromTextB = New-Object System.Windows.Forms.Button
$btnCompleteFromTextB.Text = (T 'Aus Text übernehmen')
$btnCompleteFromTextB.Location = New-Object System.Drawing.Point(20, 300)
$btnCompleteFromTextB.Size = New-Object System.Drawing.Size(200, 32)

$lblCompleteResultB = New-WizardLabel -Text '' -X 20 -Y 344 -Width 780 -Height 40

$lblSummaryB = New-WizardLabel -Text '' -X 20 -Y 390 -Width 780 -Height 190

$btnResetB = New-Object System.Windows.Forms.Button
$btnResetB.Text = (T 'Weitere Smartcard beantragen')
$btnResetB.Location = New-Object System.Drawing.Point(20, 590)
$btnResetB.Size = New-Object System.Drawing.Size(240, 32)

$btnStartB = New-Object System.Windows.Forms.Button
$btnStartB.Text = (T 'Zum Startbildschirm')
$btnStartB.Location = New-Object System.Drawing.Point(280, 590)
$btnStartB.Size = New-Object System.Drawing.Size(200, 32)

$pnlB6.Controls.AddRange(@($lblCompleteInfoB, $btnSelectCerB, $txtSelectedCerB, $btnCompleteB, $lblCerTextLabelB, $txtCerTextB, $btnCompleteFromTextB, $lblCompleteResultB, $lblSummaryB, $btnResetB, $btnStartB))

$btnSelectCerB.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = (T 'Zertifikatsdateien (*.cer)|*.cer|Alle Dateien (*.*)|*.*')
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
        $lblCompleteResultB.Text = (T 'Das ist kein vollständiges, gültiges Zertifikat (evtl. beim Kopieren über RDP abgeschnitten). Tipp: im Einreicher-Helfer mit "Speichern unter..." als Datei sichern, per RDP-Laufwerk übertragen und hier "Aus Datei übernehmen".')
        return
    }

    $complete = Complete-CertificateEnrollment -CerPath $CerPath
    if ($complete.Success) {
        $script:PlanB_CertIssued = $true
        Clear-WizardResumeState
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCompleteResultB.Text = (T 'Zertifikat wurde erfolgreich auf der virtuellen Smartcard hinterlegt.')
        Update-PlanBSummary
        if ($script:PlanB_RenewMode) {
            $idB = Get-EnrollmentIdentity
            Invoke-RenewalCleanup -PcscName $script:PlanB_PcscName -UpnOrTerm $(if ($idB.Upn) { $idB.Upn } else { $idB.SearchTerm })
            Update-PlanBSummary   # nach dem Aufräumen den finalen Kartenstand zeigen
        }
    } else {
        $lblCompleteResultB.ForeColor = [System.Drawing.Color]::Firebrick
        $lblCompleteResultB.Text = (T 'Übernahme fehlgeschlagen. Details siehe Log.')
    }
}

$btnCompleteFromTextB.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtCerTextB.Text)) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst den CER-Text einfügen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
        return
    }
    # Das eingefügte CER genauso kanonisch säubern wie die CSR - sonst scheitert
    # 'certreq -accept' mit demselben CRYPT_E_ASN1_BADTAG durch BOM/Whitespace aus
    # dem Copy&Paste-/RDP-Round-trip. ConvertTo-CleanPemRequest erhält den PEM-Header
    # (hier CERTIFICATE) und validiert das Base64.
    $cerClean = ConvertTo-CleanPemRequest -Text $txtCerTextB.Text
    if (-not $cerClean) {
        [System.Windows.Forms.MessageBox]::Show((T 'Der eingefügte Text ist kein gültiges Zertifikat (kein gültiges Base64-PEM). Bitte das CER aus dem Einreicher-Helfer erneut kopieren und einfügen.'), (T 'Ungültiges Zertifikat'), 'OK', 'Warning') | Out-Null
        return
    }
    $btnCompleteFromTextB.Enabled = $false
    $pastedCerPath = Join-Path (Get-WizardWorkingDir) "PlanB-pasted-$([guid]::NewGuid()).cer"
    Set-Content -Path $pastedCerPath -Value $cerClean -Encoding ASCII -NoNewline
    Complete-PlanBEnrollment -CerPath $pastedCerPath
    Remove-Item -Path $pastedCerPath -ErrorAction SilentlyContinue
    Update-IssueButtons   # nach Erfolg gesperrt, nach Fehler wieder frei
})

$btnCompleteB.Add_Click({
    if (-not $txtSelectedCerB.Text) {
        [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst eine CER-Datei auswählen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
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
    Update-IssueButtons   # nach Erfolg gesperrt, nach Fehler wieder frei
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
    $lblCompleteResultB.Text = ''
    Reset-PlanBSubmitUi
    Reset-PlanBRdpUi
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

# --- Schritt B7 (Index 6): direkt in der RDP-Sitzung beantragen (fremdes Konto) ---
# Empfohlener Weg für Szenario 01 ohne EA-Zertifikat: die hier erstellte Karte per RDP
# zum Server durchreichen, dort ALS Zielkonto mit certmgr.msc beantragen - Schlüssel und
# Zertifikat landen direkt auf DIESER Karte. CSR + Einreicher (Schritte 2-5) bleiben der
# Ausweichweg, wenn die Karte nicht durchgereicht werden kann.
$pnlB7 = New-Object System.Windows.Forms.Panel
$pnlB7.Dock = 'Fill'
$pnlStepsB.Controls.Add($pnlB7)

$picCardRdpB = New-CardPicture -X 20 -Y 16
$lblRdpHintB = New-WizardLabel -Text '' -X 136 -Y 40 -Width 664 -Height 48
$lblRdpStepsB = New-WizardLabel -Text '' -X 20 -Y 20 -Width 780 -Height 190

$btnRdpConnectB = New-Object System.Windows.Forms.Button
$btnRdpConnectB.Text = (T 'RDP-Verbindung starten')
$btnRdpConnectB.Location = New-Object System.Drawing.Point(20, 220)
$btnRdpConnectB.Size = New-Object System.Drawing.Size(240, 32)

$btnRdpCheckB = New-Object System.Windows.Forms.Button
$btnRdpCheckB.Text = (T 'Karte prüfen')
$btnRdpCheckB.Location = New-Object System.Drawing.Point(280, 220)
$btnRdpCheckB.Size = New-Object System.Drawing.Size(200, 32)

$lblRdpResultB = New-WizardLabel -Text '' -X 20 -Y 266 -Width 780 -Height 44
$lblRdpSummaryB = New-WizardLabel -Text '' -X 20 -Y 318 -Width 780 -Height 60

$lnkRdpFallbackB = New-Object System.Windows.Forms.LinkLabel
$lnkRdpFallbackB.Text = (T 'Karte lässt sich nicht durchreichen? Stattdessen Antrag (CSR) hier erstellen und auf dem Server mit dem Einreicher einreichen')
$lnkRdpFallbackB.Location = New-Object System.Drawing.Point(20, 390)
$lnkRdpFallbackB.Size = New-Object System.Drawing.Size(780, 22)

$btnRdpStartB = New-Object System.Windows.Forms.Button
$btnRdpStartB.Text = (T 'Zum Startbildschirm')
$btnRdpStartB.Location = New-Object System.Drawing.Point(20, 424)
$btnRdpStartB.Size = New-Object System.Drawing.Size(200, 32)
$btnRdpStartB.Visible = $false

$pnlB7.Controls.AddRange(@($picCardRdpB, $lblRdpHintB, $lblRdpStepsB, $btnRdpConnectB, $btnRdpCheckB, $lblRdpResultB, $lblRdpSummaryB, $lnkRdpFallbackB, $btnRdpStartB))

function Update-PlanBRdpPage {
    $identity = Get-EnrollmentIdentity
    $server = if ($config.RdpJumpServer) { $config.RdpJumpServer } else { T '(Server mit Sicht auf die CA)' }
    $template = if ($config.Template) { $config.Template } else { T '(Smartcard-Template)' }
    $cardLabel = if ($script:PlanB_PcscName) { $script:PlanB_PcscName } else { $script:PlanB_CardName }
    if ($script:PlanB_PcscName -and (Get-VscCardCount) -gt 1) {
        Set-CardHintLook -Label $lblRdpHintB -Active $true
        $lblRdpHintB.Text = ((T "➜ Im Windows-Kartenauswahl-Dialog auf dem Server die Karte `"{0}`" wählen  (= '{1}').") -f $script:PlanB_PcscName, $script:PlanB_CardName)
    } else {
        Set-CardHintLook -Label $lblRdpHintB -Active $false
        $lblRdpHintB.Text = (T 'Empfohlener Weg: Die Karte wird per RDP zum Server durchgereicht und dort direkt als Zielkonto beschriftet - ohne Antragsdatei und ohne Einreicher.')
    }
    $lblRdpStepsB.Text = ((T "1. `"RDP-Verbindung starten`" - verbindet mit {0} und reicht diese Smartcard durch. Dort anmelden als {1}.`r`n2. Auf dem Server certmgr.msc öffnen: Eigene Zertifikate > Rechtsklick > Alle Aufgaben > Neues Zertifikat anfordern.`r`n3. Active Directory-Registrierungsrichtlinie, Template `"{2}`" ankreuzen, `"Registrieren`".`r`n4. Bei der Kartenauswahl `"{3}`" wählen und die PIN DIESER Karte eingeben.`r`n5. RDP-Sitzung abmelden, dann hier `"Karte prüfen`".") -f $server, $identity.DisplayName, $template, $cardLabel)
    $done = [bool]$script:PlanB_CertIssued
    $btnRdpStartB.Visible = $done
    $btnRdpConnectB.Enabled = -not $done; $btnRdpCheckB.Enabled = -not $done; $lnkRdpFallbackB.Visible = -not $done
}

function Start-PlanBRdpSession {
    # .rdp-Datei mit Smartcard-Umleitung erzeugen und mstsc damit starten. Ohne
    # konfigurierten Server öffnet mstsc den Bearbeiten-Dialog zum Eintragen.
    $identity = Get-EnrollmentIdentity
    $rdpPath = Join-Path (Get-WizardWorkingDir) 'VSC-Wizard-Antrag.rdp'
    $lines = @("full address:s:$($config.RdpJumpServer)", 'redirectsmartcards:i:1', 'prompt for credentials:i:1', 'authentication level:i:2', 'screen mode id:i:1')
    if ($identity.Upn) { $lines += "username:s:$($identity.Upn)" } elseif ($script:TargetAccount) { $lines += "username:s:$($script:TargetAccount)" }
    Set-Content -Path $rdpPath -Value $lines -Encoding Unicode
    $mstscArgs = if ($config.RdpJumpServer) { @("`"$rdpPath`"") } else { @('/edit', "`"$rdpPath`"") }
    Write-WizardLog -Message "RDP mit Smartcard-Umleitung: mstsc.exe $($mstscArgs -join ' ')" -Level Command
    $script:PlanB_RdpStarted = Get-Date
    try { Start-Process -FilePath 'mstsc.exe' -ArgumentList $mstscArgs } catch { Write-WizardLog -Message "mstsc konnte nicht gestartet werden: $($_.Exception.Message)" -Level Error }
}

function Find-PlanBRdpCertificate {
    # Neu ausgestelltes Zertifikat des Zielkontos auf DIESER Karte: passendes Konto (UPN
    # bzw. Name im Subject) und ausgestellt seit Betreten des Schritts (15 min Spielraum:
    # die CA datiert NotBefore um ihre Uhrzeittoleranz zurück).
    $identity = Get-EnrollmentIdentity
    $since = $script:PlanB_RdpEntered.AddMinutes(-15)
    return @(Invoke-Busy -Text (T 'Prüfe Zertifikate auf der Smartcard...') -Action { Get-SmartCardCertificates } | Where-Object {
        $_.Reader -and $_.Reader -eq $script:PlanB_PcscName -and $_.NotBefore -ge $since -and
        (($identity.Upn -and $_.Upn -and $_.Upn -eq $identity.Upn) -or ($_.Subject -match ('CN=' + [regex]::Escape($identity.SearchTerm) + '(,|$)')))
    } | Sort-Object NotBefore -Descending)
}

$btnRdpConnectB.Add_Click({ Start-PlanBRdpSession })

$btnRdpCheckB.Add_Click({
    $btnRdpCheckB.Enabled = $false
    $found = @(Find-PlanBRdpCertificate)
    if ($found.Count -gt 0) {
        $script:PlanB_CertIssued = $true
        Clear-WizardResumeState
        Write-WizardLog -Message "Direktantrag per RDP: Zertifikat auf Karte '$($found[0].Reader)' gefunden ($($found[0].Subject), gültig bis $($found[0].NotAfter.ToString('yyyy-MM-dd')))." -Level Success
        # Nur auf der Karte (Zertifikatverteilung noch nicht gelaufen): gleich in den
        # Benutzerspeicher übernehmen, mit dem Kartenschlüssel verknüpft.
        if ($found[0].PSObject.Properties['InStore'] -and -not $found[0].InStore -and $found[0].RawData -and $found[0].KeyContainerName) {
            $null = Import-SmartCardCertificateToStore -RawData ([byte[]]$found[0].RawData) -ContainerName $found[0].KeyContainerName -Provider $found[0].Provider
        }
        $lblRdpResultB.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblRdpResultB.Text = ((T 'Zertifikat für {0} liegt auf der Karte (gültig bis {1}). Fertig.') -f (Get-EnrollmentIdentity).DisplayName, $found[0].NotAfter.ToString('yyyy-MM-dd'))
        if ($script:PlanB_RenewMode) {
            $idB = Get-EnrollmentIdentity
            Invoke-RenewalCleanup -PcscName $script:PlanB_PcscName -UpnOrTerm $(if ($idB.Upn) { $idB.Upn } else { $idB.SearchTerm })
        }
        $idS = Get-EnrollmentIdentity
        $lblRdpSummaryB.Text = Get-CardValiditySummaryText -CardName $script:PlanB_CardName -PcscName $script:PlanB_PcscName -MatchTerm $(if ($idS.Upn) { $idS.Upn } else { $idS.SearchTerm })
        Update-PlanBRdpPage
    } else {
        Write-WizardLog -Message "Direktantrag per RDP: noch kein neues Zertifikat für '$((Get-EnrollmentIdentity).DisplayName)' auf Karte '$($script:PlanB_PcscName)'." -Level Warn
        $lblRdpResultB.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblRdpResultB.Text = (T 'Noch kein neues Zertifikat für dieses Konto auf der Karte gefunden. Wurde der Antrag in der RDP-Sitzung abgeschlossen und dabei diese Karte gewählt? Danach erneut prüfen.')
        $btnRdpCheckB.Enabled = $true
    }
})

$lnkRdpFallbackB.Add_LinkClicked({
    Write-WizardLog -Message 'Direktantrag per RDP: Ausweichweg Antrag (CSR) + Einreicher gewählt.' -Level Info
    $script:PlanB_Fallback = $true
    Show-PlanBStep -Index 2
})

$btnRdpStartB.Add_Click({
    $script:PlanB_RenewMode = $false
    $tabPlanB.Visible = $false
    Show-ScenarioStep
})

# --- Navigation Plan B ---
# Schritt-Panels scrollbar machen, damit bei kleinerem Fenster keine Buttons
# (z.B. unten im Uebernehmen-Schritt) abgeschnitten werden - die Controls sind
# absolut positioniert, AutoScroll blendet dann bei Bedarf einen Scrollbalken ein.
@($pnlModeSelect, $pnlA1, $pnlA2, $pnlA3, $pnlA4, $pnlB1, $pnlB2, $pnlB3, $pnlB4, $pnlB5, $pnlB6, $pnlB7) |
    ForEach-Object { $_.AutoScroll = $true }

$planBStepTitles = @((T 'Status'), (T 'Virtuelle Smartcard erstellen'), (T 'CSR erstellen'), (T 'Übergabe per RDP'), (T 'Antrag einreichen (auf dem Server)'), (T 'Zertifikat abschließen (lokal)'))
$planBStepperLabels = @((T 'Status'), (T 'Smartcard'), (T 'Antrag (CSR)'), (T 'Übergabe RDP'), (T 'Einreichen'), (T 'Abschluss'))
$planBStepTitles += (T 'In der RDP-Sitzung beantragen')
# Fremdes Konto, Direktweg: Status -> Smartcard -> Beantragen per RDP (Index 0, 1, 6).
$planBDirectStepperLabels = @((T 'Status'), (T 'Smartcard'), (T 'Beantragen per RDP'))

function Test-PlanBDirect {
    # Direktweg (Antrag in der RDP-Sitzung) für fremde Konten - außer der Ausweichweg
    # CSR + Einreicher wurde gewählt.
    return [bool]($script:TargetAccount -and -not $script:PlanB_Fallback)
}

function Update-PlanBStatus {
    $joinState = Get-DomainJoinState
    $upn = Get-CurrentUpn
    $lblJoinStateB.Text = (T 'Domänen-Status: {0}') -f $joinState.Mode
    $lblUserB.Text = ((T 'Angemeldeter Benutzer: {0}') -f "$env:USERDOMAIN\$env:USERNAME") + $(if ($upn) { " (UPN: $upn)" } else { '' })
    if ($script:TargetAccount) {
        $lblTargetB.ForeColor = [System.Drawing.Color]::SteelBlue
        $lblTargetB.Text = ((T 'Smartcard wird beantragt für: {0} (VSC/CSR trotzdem in deinem eigenen Konto)') -f $script:TargetAccount)
    } else {
        $lblTargetB.Text = ''
    }
    $lblJumpServerB.Text = ((T 'CA-naher Server (RDP-Ziel): {0}') -f $config.RdpJumpServer)
}

function Show-PlanBStep {
    param([int]$Index)
    $panels = @($pnlB1, $pnlB2, $pnlB3, $pnlB4, $pnlB5, $pnlB6, $pnlB7)
    for ($i = 0; $i -lt $panels.Count; $i++) {
        $panels[$i].Visible = ($i -eq $Index)
    }
    $script:PlanBCurrentStep = $Index
    Update-IssueButtons
    # Globale Schrittnummer: +1, da Schritt 1 (Moduswahl) davor liegt.
    $lblGlobalStep.Text = $planBStepTitles[$Index]
    if ((Test-PlanBDirect) -and $Index -in 0, 1, 6) {
        $pos = if ($Index -eq 6) { 2 } else { $Index }
        Update-Stepper -Labels (@((T 'Szenario')) + $planBDirectStepperLabels) -Current ($pos + 1) -Subs @{ 0 = (Get-EnrollmentIdentity).DisplayName; 2 = "$($script:PlanB_CardName)" }
    } else {
        Update-Stepper -Labels (@((T 'Szenario')) + $planBStepperLabels) -Current ($Index + 1) -Subs @{ 0 = (Get-EnrollmentIdentity).DisplayName; 2 = "$($script:PlanB_CardName)" }
    }
    $btnBackShared.Enabled = $true
    # Letzte Schritte: Abschluss (5) bzw. Direktantrag per RDP (6).
    $btnNextShared.Enabled = ($Index -lt 5)

    switch ($Index) {
        0 { Update-PlanBStatus }
        2 {
            # Windows-Kartenauswahl-/PIN-Dialoge zeigen NICHT den vergebenen
            # Kartennamen, sondern den PC/SC-Namen "Microsoft Virtual Smart Card N" -
            # deshalb auffällig hervorheben (gemeinsamer Stil, siehe Set-CardHintLook).
            if ($script:PlanB_PcscName -and (Get-VscCardCount) -gt 1) {
                Set-CardHintLook -Label $lblCsrInfoB -Active $true
                $lblCsrInfoB.Text = ((T "➜ Im Windows-Kartenauswahl-Dialog die Karte `"{0}`" wählen  (= '{1}'). Danach ggf. PIN-Dialog.") -f $script:PlanB_PcscName, $script:PlanB_CardName)
            } else {
                Set-CardHintLook -Label $lblCsrInfoB -Active $false
                $lblCsrInfoB.Text = (T 'Erstellt eine an die virtuelle Smartcard gebundene Zertifikatsanforderung (CSR). Es erscheint ggf. ein PIN-Dialog der Smartcard.')
            }
        }
        3 { Update-PlanBHandoff }
        6 {
            if (-not $script:PlanB_RdpEntered -or -not $script:PlanB_CertIssued) { $script:PlanB_RdpEntered = Get-Date }
            Update-PlanBRdpPage
        }
    }
}

function Invoke-PlanBNextClick {
    switch ($script:PlanBCurrentStep) {
        0 { Show-PlanBStep -Index 1 }
        1 {
            if (-not $script:PlanB_VscCreated) {
                [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst die virtuelle Smartcard erstellen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
                return
            }
            # Fremdes Konto: zuerst der Direktweg (Antrag in der RDP-Sitzung).
            if (Test-PlanBDirect) { Show-PlanBStep -Index 6 } else { Show-PlanBStep -Index 2 }
        }
        2 {
            if (-not $script:PlanB_CsrPath) {
                [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst die CSR erstellen.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
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
                    (T 'In diesem Schritt wurde kein Zertifikat ausgestellt. Wurde der Antrag anderweitig eingereicht (z.B. mit dem Einreichungshelfer in der RDP-Sitzung) und liegt das Zertifikat als Datei oder Text vor?'),
                    (T 'Schritt überspringen'), 'YesNo', 'Question')
                if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
            Show-PlanBStep -Index 5
        }
    }
}

function Invoke-PlanBBackClick {
    # Ausweichweg (CSR) für ein fremdes Konto: "Zurück" aus der CSR führt zum Direktweg.
    if ($script:TargetAccount -and $script:PlanB_Fallback -and $script:PlanBCurrentStep -eq 2) {
        $script:PlanB_Fallback = $false
        Show-PlanBStep -Index 6
        return
    }
    # Direktweg: zurück zur Karte bzw. (Verlängerung, Karte übersprungen) zur Szenario-Auswahl.
    if ($script:PlanBCurrentStep -eq 6) {
        if ($script:PlanB_RenewMode) { $tabPlanB.Visible = $false; Show-ScenarioStep } else { Show-PlanBStep -Index 1 }
        return
    }
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
        'SIMPLE' { Enter-SimpleFlow }
        default { Invoke-ModeSelectNextClick }
    }
})

$btnBackShared.Add_Click({
    switch ($script:ActivePlan) {
        'A'    { Invoke-PlanABackClick }
        'B'    { Invoke-PlanBBackClick }
        'SCEN' { }
        'SIMPLE' { }
        default { Show-ScenarioStep }  # Mode-Select (Schritt 2) -> zurück zur Szenario-Auswahl
    }
})

#endregion

# ============================================================================
#region EINSTELLUNGEN-DIALOG (schrittunabhängig über den Button in der Kopfleiste erreichbar)
# ============================================================================
Update-Splash -Text (T 'Dialoge vorbereiten...') -Percent 76

function Show-VscPinChangeDialog {
    # Alte PIN, neue PIN, Wiederholung - Änderung über den Kartentreiber (Set-VscPin).
    # Bei falscher alter PIN bzw. abgelehnter neuer PIN bleibt der Dialog offen.
    # -PrefillCurrentPin: die aktuelle PIN vorbelegen (Intune-/Simple-Modus, wo die
    #   Start-PIN aus der Seriennummer abgeleitet und daher bekannt ist). Gibt $true
    #   zurueck, wenn die PIN tatsaechlich geaendert wurde, sonst $false (Abbruch/Sperre).
    # -NumericOnly / -MinNewLength: die NEUE PIN muss nur aus Ziffern bestehen bzw. eine
    #   Mindestlaenge erfuellen (Simple-/Intune-Ziel-PIN: numerisch, min. 6).
    param([Parameter(Mandatory)]$Reader, [System.Windows.Forms.Form]$Owner, [string]$PrefillCurrentPin,
        [switch]$NumericOnly, [int]$MinNewLength = 4)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = (T 'PIN ändern')
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 300)
    $dlg.BackColor = $script:UI.Surface; $dlg.Font = New-UiFont 9.5

    $head = New-Object System.Windows.Forms.Label
    $head.UseMnemonic = $false; $head.Font = New-UiFont 10.5 -Semibold
    $head.Text = ((T 'Karte {0}  ({1})') -f $Reader.FriendlyName, $Reader.PcscName)
    $head.Location = New-Object System.Drawing.Point(18, 16); $head.Size = New-Object System.Drawing.Size(424, 22); $head.AutoEllipsis = $true
    $dlg.Controls.Add($head)

    $boxes = @()
    $y = 54
    foreach ($cap in @((T 'Aktuelle PIN:'), (T 'Neue PIN:'), (T 'Neue PIN wiederholen:'))) {
        $lb = New-Object System.Windows.Forms.Label
        $lb.Text = $cap; $lb.Location = New-Object System.Drawing.Point(18, ($y + 4)); $lb.Size = New-Object System.Drawing.Size(170, 22)
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.UseSystemPasswordChar = $true; $tb.Location = New-Object System.Drawing.Point(192, $y); $tb.Size = New-Object System.Drawing.Size(250, 26)
        $dlg.Controls.AddRange(@($lb, $tb)); $boxes += $tb
        $y += 38
    }
    # Simple-/Intune-Modus: die bekannte Start-PIN vorbelegen, damit der Benutzer nur
    # noch die neue (private) PIN vergeben muss.
    if ($PrefillCurrentPin) { $boxes[0].Text = $PrefillCurrentPin }
    $msg = New-Object System.Windows.Forms.Label
    $msg.UseMnemonic = $false; $msg.ForeColor = $script:UI.Muted
    $msg.Text = if ($PrefillCurrentPin) {
        (T 'Die aktuelle PIN ist schon eingetragen (Start-PIN der Einrichtung). Vergib jetzt eine eigene, nur dir bekannte PIN.')
    } else {
        (T 'Die neue PIN muss die PIN-Richtlinie der Karte erfüllen (Mindestlänge). Eine falsche aktuelle PIN zählt als Fehlversuch.')
    }
    if ($NumericOnly) { $msg.Text += ' ' + ((T 'Die neue PIN muss aus mindestens {0} Ziffern bestehen (nur Zahlen).') -f $MinNewLength) }
    $msg.Location = New-Object System.Drawing.Point(18, 172); $msg.Size = New-Object System.Drawing.Size(424, 64)
    $dlg.Controls.Add($msg)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = (T 'PIN ändern'); $ok.Location = New-Object System.Drawing.Point(222, 252); $ok.Size = New-Object System.Drawing.Size(116, 32)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = (T 'Abbrechen'); $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object System.Drawing.Point(346, 252); $cancel.Size = New-Object System.Drawing.Size(96, 32)
    $dlg.Controls.AddRange(@($ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    $showMsg = { param($Text, $Color) $msg.ForeColor = $Color; $msg.Text = $Text }
    $ok.Add_Click({
        $cur = $boxes[0].Text; $new = $boxes[1].Text
        if (-not $cur -or -not $new) { & $showMsg (T 'Bitte alle Felder ausfüllen.') $script:UI.Danger; return }
        if ($new -ne $boxes[2].Text) { & $showMsg (T 'Die neuen PINs stimmen nicht überein.') $script:UI.Danger; $boxes[2].Text = ''; $boxes[2].Focus(); return }
        # Karten-PINs sind druckbare ASCII-Zeichen - Umlaute o.ä. würden anders kodiert ankommen.
        # Die aktuelle (alte) PIN ist immer druckbares ASCII (Quell-PIN alphanumerisch).
        if ($cur -notmatch '^[\x20-\x7E]+$') { & $showMsg (T 'Die PIN darf nur Buchstaben ohne Umlaute, Ziffern und gängige Sonderzeichen enthalten.') $script:UI.Danger; return }
        if ($NumericOnly) {
            if ($new -notmatch '^[0-9]+$') { & $showMsg (T 'Die neue PIN darf nur aus Ziffern bestehen.') $script:UI.Danger; $boxes[1].Text = ''; $boxes[2].Text = ''; $boxes[1].Focus(); return }
        } elseif ($new -notmatch '^[\x20-\x7E]+$') {
            & $showMsg (T 'Die PIN darf nur Buchstaben ohne Umlaute, Ziffern und gängige Sonderzeichen enthalten.') $script:UI.Danger; return
        }
        if ($new.Length -lt $MinNewLength) {
            $tooShort = if ($NumericOnly) { (T 'Die neue PIN ist zu kurz (mindestens {0} Ziffern).') -f $MinNewLength } else { (T 'Die neue PIN ist zu kurz (mindestens {0} Zeichen, die Karte kann mehr verlangen).') -f $MinNewLength }
            & $showMsg $tooShort $script:UI.Danger; return
        }
        $ok.Enabled = $false; $dlg.Cursor = 'WaitCursor'; $dlg.Refresh()
        try {
            $res = Set-VscPin -PcscName $Reader.PcscName -CurrentPin ([Text.Encoding]::ASCII.GetBytes($cur)) -NewPin ([Text.Encoding]::ASCII.GetBytes($new))
        } finally { $cur = $null; $new = $null; $dlg.Cursor = 'Default'; $ok.Enabled = $true }
        switch ($res.Status) {
            'Changed' {
                foreach ($b in $boxes) { $b.Text = '' }
                [System.Windows.Forms.MessageBox]::Show(((T 'Die PIN von {0} wurde geändert.') -f $Reader.FriendlyName), (T 'PIN ändern'), 'OK', 'Information') | Out-Null
                $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            }
            'WrongPin' {
                $boxes[0].Text = ''; $boxes[0].Focus()
                $t = if ($null -ne $res.Attempts) { (T 'Die aktuelle PIN ist falsch - noch {0} Versuch(e), danach ist die Karte gesperrt.') -f $res.Attempts } else { T 'Die aktuelle PIN ist falsch.' }
                & $showMsg $t $script:UI.Danger
            }
            'InvalidNewPin' {
                $boxes[1].Text = ''; $boxes[2].Text = ''; $boxes[1].Focus()
                & $showMsg (T 'Die Karte hat die neue PIN abgelehnt - sie erfüllt die PIN-Richtlinie der Karte nicht (z.B. zu kurz). Die bisherige PIN gilt weiter.') $script:UI.Danger
            }
            'Blocked' {
                [System.Windows.Forms.MessageBox]::Show((T 'Die Karte ist gesperrt (zu viele falsche PIN-Eingaben). Eine virtuelle Smartcard ohne bekannten Administratorschlüssel lässt sich nicht entsperren - Karte löschen und neu anlegen.'), (T 'Fehler'), 'OK', 'Error') | Out-Null
                $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            }
            default {
                [System.Windows.Forms.MessageBox]::Show(((T 'PIN ändern fehlgeschlagen ({0}). Details siehe Log.') -f $res.Message) + "`r`n`r`n" +
                    ((T "Die PIN einer Smartcard ändert Windows über den Sicherheitsbildschirm:`r`n`r`n1. Strg+Alt+Entf drücken (in einer Remotedesktop-Sitzung: Strg+Alt+Ende).`r`n2. 'Kennwort ändern' wählen.`r`n3. Unter 'Anmeldeoptionen' das Smartcard-Symbol wählen.`r`n4. Die Karte `"{0}`" wählen (= '{1}').`r`n5. Alte PIN und zweimal die neue PIN eingeben.`r`n`r`nDie neue PIN muss die PIN-Richtlinie der Karte erfüllen (Mindestlänge). Der Wizard sieht die PIN dabei nie.") -f $Reader.PcscName, $Reader.FriendlyName),
                    (T 'Fehler'), 'OK', 'Error') | Out-Null
            }
        }
    })
    # Bei vorbelegter aktueller PIN direkt in das Feld "Neue PIN" springen.
    if ($PrefillCurrentPin) { $dlg.Add_Shown({ $boxes[1].Focus() }) } else { $dlg.Add_Shown({ $boxes[0].Focus() }) }
    Set-DialogStyle -Dialog $dlg
    $result = if ($Owner) { $dlg.ShowDialog($Owner) } else { $dlg.ShowDialog() }
    foreach ($b in $boxes) { $b.Text = '' }
    $dlg.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-VscInventoryDialog {
    # "VSCs verwalten" (Szenario 04): oben die Karten, unten die Zertifikate der
    # gewählten Karte; Aktionen jeweils direkt darunter. Selbsterklärend - die frühere
    # Ablaufbeschreibung ("Tool: Inventar ... / Du: Auswählen und löschen") entfällt.
    # -UserView -OnlyInstanceId: Benutzeransicht im Simple-Modus - nur die EIGENE Karte,
    # nur PIN ändern + Zertifikat anzeigen (kein Löschen, keine Diagnosezeilen).
    param([System.Windows.Forms.Form]$Owner, [switch]$UserView, [string]$OnlyInstanceId)

    # Die Zertifikatserkennung kann (Hänger-Schutz, siehe Get-SmartCardCngProviderInfoBatch)
    # einige Sekunden dauern - die Kernfunktionen zeigen dafür selbst den Warte-Hinweis.
    Set-Busy -Text (T 'Lese virtuelle Smartcards und Zertifikate...')
    try {
        $readers = @(Get-VirtualSmartCardReaders)
        # Andere Smartcards (Einstellung): eingesteckte Karten mit Kartentreiber dazu.
        if (-not $UserView -and (Test-PhysicalCardsAllowed -Config $config)) {
            $readers += @(Get-SmartCardTargets -Config $config -IncludeUnusable | Where-Object { $_.Kind -eq 'Physical' })
        }
        if ($OnlyInstanceId) { $readers = @($readers | Where-Object { "$($_.InstanceId)" -eq $OnlyInstanceId }) }
        $certs = @(Get-SmartCardCertificates)
    } finally { Clear-Busy }
    Write-WizardLog -Message "Smartcard-Inventar: $($readers.Count) Lesegerät(e), $($certs.Count) Zertifikat(e) mit privatem Schlüssel, davon $(@($certs | Where-Object IsSmartCard).Count) als Smartcard erkannt, $(@($certs | Where-Object { $_.InStore -eq $false }).Count) nur auf der Karte." -Level Info

    $now = Get-Date
    function Get-ExpiryState([datetime]$NotAfter) {
        if ($NotAfter -lt $now) { return 'expired' }
        if ($NotAfter -lt $now.AddDays(30)) { return 'soon' }
        return 'ok'
    }
    function Get-ExpiryColor([string]$State) {
        switch ($State) { 'expired' { $script:UI.Danger } 'soon' { $script:UI.Warn } default { $script:UI.Text } }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($UserView) { T 'Meine Smartcard' } else { T 'Virtuelle Smartcards verwalten' }
    $dlg.Size = New-Object System.Drawing.Size(940, 700)
    $dlg.MinimumSize = New-Object System.Drawing.Size(760, 540)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $script:UI.Ground
    $dlg.Font = New-UiFont 9.5

    $dlgLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $dlgLayout.Dock = 'Fill'; $dlgLayout.ColumnCount = 1; $dlgLayout.RowCount = 7
    $dlgLayout.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 10)
    foreach ($rs in @(@('AutoSize', 0), @('Percent', 42), @('AutoSize', 0), @('AutoSize', 0), @('Percent', 58), @('AutoSize', 0), @('AutoSize', 0))) {
        [void]$dlgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::($rs[0]), $rs[1])))
    }
    $dlg.Controls.Add($dlgLayout)

    function New-InvHeader([string]$Text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true; $l.UseMnemonic = $false
        $l.Font = New-UiFont 10.5 -Semibold; $l.ForeColor = $script:UI.Text
        $l.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 6)
        return $l
    }
    function New-InvList {
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
        $lv.HideSelection = $false; $lv.GridLines = $false; $lv.BorderStyle = 'FixedSingle'
        $lv.Font = New-UiFont 9.5
        $lv.ShowItemToolTips = $true   # abgeschnittene Namen (z.B. lange Leser-Namen) per Tooltip
        # Letzte Spalte füllt die Restbreite (sonst bleibt rechts ein leerer Streifen).
        $lv.Add_Resize({
            param($s, $e)
            if ($s.Columns.Count -lt 2) { return }
            $used = 0; for ($i = 0; $i -lt $s.Columns.Count - 1; $i++) { $used += $s.Columns[$i].Width }
            $s.Columns[$s.Columns.Count - 1].Width = [Math]::Max(120, $s.ClientSize.Width - $used - 2)
        })
        return $lv
    }
    function New-InvActionBar {
        $f = New-Object System.Windows.Forms.FlowLayoutPanel
        $f.AutoSize = $true; $f.Dock = 'Fill'; $f.FlowDirection = 'LeftToRight'; $f.WrapContents = $false
        $f.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 8)
        return $f
    }
    function New-InvButton([string]$Text, [int]$Width = 190) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text; $b.Size = New-Object System.Drawing.Size($Width, 32)
        $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
        return $b
    }

    # --- Karten ---------------------------------------------------------------------
    $dlgLayout.Controls.Add((New-InvHeader $(if ($UserView) { T 'Meine Smartcard' } else { (T 'Smartcards auf diesem Gerät ({0})') -f $readers.Count })), 0, 0)
    $lvReaders = New-InvList
    [void]$lvReaders.Columns.Add((T 'Karte'), 250)
    [void]$lvReaders.Columns.Add((T 'In Windows-Dialogen'), 250)
    [void]$lvReaders.Columns.Add((T 'Zertifikate'), 100)
    [void]$lvReaders.Columns.Add((T 'Nächster Ablauf'), 150)
    $dlgLayout.Controls.Add($lvReaders, 0, 1)

    $unmatchedSmartCardMarker = [pscustomobject]@{ IsMarker = $true; Kind = 'unmatched' }
    $nonSmartCardMarker = [pscustomobject]@{ IsMarker = $true; Kind = 'other' }

    foreach ($reader in $readers) {
        $cardCerts = @($certs | Where-Object { $_.Reader -and $reader.PcscName -and $_.Reader -eq $reader.PcscName })
        $item = New-Object System.Windows.Forms.ListViewItem($reader.FriendlyName)
        $item.UseItemStyleForSubItems = $false
        [void]$item.SubItems.Add($(if ($reader.PcscName) { $reader.PcscName } else { '-' }))
        [void]$item.SubItems.Add("$($cardCerts.Count)")
        if ($cardCerts.Count -gt 0) {
            $soonest = ($cardCerts | Sort-Object NotAfter | Select-Object -First 1).NotAfter
            $sub = $item.SubItems.Add($soonest.ToString('yyyy-MM-dd'))
            $sub.ForeColor = Get-ExpiryColor (Get-ExpiryState $soonest)
        } else { [void]$item.SubItems.Add('-') }
        $item.Tag = $reader
        [void]$lvReaders.Items.Add($item)
    }

    # Zertifikate ohne zuordenbare Karte bzw. ohne Smartcard-Schlüssel: als gedämpfte
    # Zusatzzeilen (zur Diagnose), ohne Karten-Aktionen.
    $readerPcscNames = @($readers | ForEach-Object { $_.PcscName } | Where-Object { $_ })
    $unmatchedSmartCardCerts = @($certs | Where-Object { $_.IsSmartCard -and (-not $_.Reader -or ($readerPcscNames -notcontains $_.Reader)) })
    $otherCerts = @($certs | Where-Object { -not $_.IsSmartCard })
    foreach ($m in @(@($unmatchedSmartCardCerts, $unmatchedSmartCardMarker, (T 'Smartcard-Zertifikate ohne Karte')), @($otherCerts, $nonSmartCardMarker, (T 'Sonstige Zertifikate (keine Smartcard)')))) {
        if ($m[0].Count -eq 0 -or $UserView) { continue }   # Benutzeransicht: nur die eigene Karte
        $item = New-Object System.Windows.Forms.ListViewItem($m[2])
        $item.ForeColor = $script:UI.Muted
        [void]$item.SubItems.Add('-'); [void]$item.SubItems.Add("$($m[0].Count)"); [void]$item.SubItems.Add('')
        $item.Tag = $m[1]
        [void]$lvReaders.Items.Add($item)
    }
    if ($lvReaders.Items.Count -eq 0) {
        [void]$lvReaders.Items.Add((New-Object System.Windows.Forms.ListViewItem((T 'Keine Smartcards gefunden.'))))
    }

    $cardBar = New-InvActionBar
    $btnChangePin = New-InvButton (T 'PIN ändern...')
    $btnDeleteReader = New-InvButton (T 'Karte löschen...')
    $btnChangePin.Enabled = $false; $btnDeleteReader.Enabled = $false
    $cardBar.Controls.AddRange(@($btnChangePin, $btnDeleteReader))
    if ($UserView) { $btnDeleteReader.Visible = $false }
    $dlgLayout.Controls.Add($cardBar, 0, 2)

    # --- Zertifikate der gewählten Karte --------------------------------------------
    $lblCertsHeader = New-InvHeader (T 'Zertifikate')
    $dlgLayout.Controls.Add($lblCertsHeader, 0, 3)
    $lvCerts = New-InvList
    [void]$lvCerts.Columns.Add((T 'Ausgestellt für'), 330)
    [void]$lvCerts.Columns.Add((T 'Gültig bis'), 110)
    [void]$lvCerts.Columns.Add((T 'Status'), 130)
    [void]$lvCerts.Columns.Add((T 'Fingerabdruck'), 300)
    $dlgLayout.Controls.Add($lvCerts, 0, 4)

    $certBar = New-InvActionBar
    $btnShowCert = New-InvButton (T 'Anzeigen...') 150
    $btnDeleteCert = New-InvButton (T 'Von Karte entfernen...')
    # Zertifikat nur auf der Karte (noch nicht vom Zertifikatverteilungsdienst kopiert):
    # Hinweis + in den Benutzerspeicher übernehmen.
    $btnImportCert = New-InvButton (T 'In Speicher übernehmen')
    $lblCardOnly = New-Object System.Windows.Forms.Label
    $lblCardOnly.Text = T 'Liegt auf der Karte, fehlt im Zertifikatsspeicher.'
    $lblCardOnly.AutoSize = $true; $lblCardOnly.UseMnemonic = $false
    $lblCardOnly.ForeColor = $script:UI.Warn
    $lblCardOnly.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $btnShowCert.Enabled = $false; $btnDeleteCert.Enabled = $false; $btnImportCert.Enabled = $false; $lblCardOnly.Visible = $false
    $certBar.Controls.AddRange(@($btnShowCert, $btnDeleteCert, $btnImportCert, $lblCardOnly))
    if ($UserView) { $btnDeleteCert.Visible = $false; $btnImportCert.Visible = $false }
    $dlgLayout.Controls.Add($certBar, 0, 5)

    $dlgBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $dlgBtnPanel.AutoSize = $true; $dlgBtnPanel.Dock = 'Fill'; $dlgBtnPanel.FlowDirection = 'RightToLeft'
    $btnCloseInventory = New-InvButton (T 'Schließen') 120
    $btnRefreshInventory = New-InvButton (T 'Aktualisieren') 120
    $dlgBtnPanel.Controls.AddRange(@($btnCloseInventory, $btnRefreshInventory))
    $dlgLayout.Controls.Add($dlgBtnPanel, 0, 6)
    $dlg.CancelButton = $btnCloseInventory

    function Test-IsVirtualCard($Reader) {
        return [bool]($Reader -and -not $Reader.PSObject.Properties['IsMarker'] -and $Reader.PcscName -and "$($Reader.InstanceId)" -like 'ROOT\SMARTCARDREADER\*')
    }
    function Test-IsPhysicalCard($Reader) {
        return [bool]($Reader -and $Reader.PSObject.Properties['Kind'] -and $Reader.Kind -eq 'Physical' -and $Reader.CardName)
    }

    function Update-CertListForSelection {
        $lvCerts.Items.Clear()
        $btnShowCert.Enabled = $false; $btnDeleteCert.Enabled = $false; $btnImportCert.Enabled = $false; $lblCardOnly.Visible = $false
        $sel =if ($lvReaders.SelectedItems.Count -gt 0) { $lvReaders.SelectedItems[0].Tag } else { $null }
        # PIN ändern geht über jeden Kartentreiber (auch YubiKey); löschen nur bei VSCs.
        $btnChangePin.Enabled = (Test-IsVirtualCard $sel) -or (Test-IsPhysicalCard $sel)
        $btnDeleteReader.Enabled = Test-IsVirtualCard $sel
        if (-not $sel) { $lblCertsHeader.Text = (T 'Zertifikate (oben eine Karte auswählen)'); return }
        $matching = @()
        if ($sel.PSObject.Properties['IsMarker']) {
            $matching = if ($sel.Kind -eq 'unmatched') { $unmatchedSmartCardCerts } else { $otherCerts }
            $lblCertsHeader.Text = $lvReaders.SelectedItems[0].Text
        } else {
            $lblCertsHeader.Text = (T 'Zertifikate auf {0}') -f $sel.FriendlyName
            $matching = @($certs | Where-Object { $_.Reader -and $sel.PcscName -and $_.Reader -eq $sel.PcscName } | Sort-Object NotAfter -Descending)
        }
        if ($matching.Count -eq 0) {
            $empty = New-Object System.Windows.Forms.ListViewItem((T '(keine Zertifikate auf dieser Karte)'))
            $empty.ForeColor = $script:UI.Muted
            [void]$lvCerts.Items.Add($empty)
            return
        }
        foreach ($c in $matching) {
            $who = if ($c.Upn) { $c.Upn } else { ($c.Subject -replace '^CN=', '') }
            $item = New-Object System.Windows.Forms.ListViewItem($who)
            $item.UseItemStyleForSubItems = $false
            [void]$item.SubItems.Add($c.NotAfter.ToString('yyyy-MM-dd'))
            $state = Get-ExpiryState $c.NotAfter
            $stateText = switch ($state) { 'expired' { T 'abgelaufen' } 'soon' { T 'läuft bald ab' } default { T 'gültig' } }
            $sub = $item.SubItems.Add($stateText); $sub.ForeColor = Get-ExpiryColor $state
            if ($c.InStore -eq $false) {
                # Liegt nur auf der Karte (CertPropSvc hat es noch nicht kopiert).
                $sub.Text = T 'nicht im Speicher'; $sub.ForeColor = $script:UI.Warn
                $item.ToolTipText = T 'Liegt auf der Karte, fehlt im Zertifikatsspeicher.'
            }
            [void]$item.SubItems.Add($c.Thumbprint)
            $item.Tag = $c
            [void]$lvCerts.Items.Add($item)
        }
        # Erstes (neuestes) Zertifikat vorauswählen - "Anzeigen..." ist damit sofort nutzbar.
        $lvCerts.Items[0].Selected = $true
        Update-CertButtons   # SelectedIndexChanged feuert vor dem Anzeigen (ohne Handle) nicht
    }
    function Update-CertButtons {
        $c = if ($lvCerts.SelectedItems.Count -gt 0) { $lvCerts.SelectedItems[0].Tag } else { $null }
        $btnShowCert.Enabled = [bool]($c -and $c.Thumbprint)
        # Entfernen nur für echte Smartcard-Zertifikate mit bekanntem Schlüssel-Container.
        $btnDeleteCert.Enabled = [bool]($c -and $c.KeyContainerName -and $c.Provider -and $c.IsSmartCard)
        $cardOnly = [bool]($c -and $c.InStore -eq $false)
        $btnImportCert.Enabled = [bool]($cardOnly -and $c.RawData -and $c.KeyContainerName)
        $lblCardOnly.Visible = $cardOnly
    }
    $lvReaders.Add_SelectedIndexChanged({ Update-CertListForSelection })

    $lvCerts.Add_SelectedIndexChanged({ Update-CertButtons })

    # Zertifikat anzeigen: Windows-Zertifikatsdialog (Details, Pfad, Gültigkeit).
    $showCert = {
        if ($lvCerts.SelectedItems.Count -eq 0) { return }
        $c = $lvCerts.SelectedItems[0].Tag
        if (-not ($c -and $c.Thumbprint)) { return }
        try {
            Add-Type -AssemblyName System.Security
            # Nur auf der Karte: aus den von der Karte gelesenen Daten anzeigen.
            $x = if ($c.InStore -eq $false -and $c.RawData) { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$c.RawData) }
                 else { Get-Item -Path "Cert:\CurrentUser\My\$($c.Thumbprint)" -ErrorAction Stop }
            [System.Security.Cryptography.X509Certificates.X509Certificate2UI]::DisplayCertificate($x, $dlg.Handle)
        } catch {
            Write-WizardLog -Message "Zertifikat anzeigen fehlgeschlagen: $($_.Exception.Message)" -Level Error
        }
    }
    $btnShowCert.Add_Click($showCert)
    $lvCerts.Add_DoubleClick($showCert)

    # PIN ändern über den Kartentreiber (Set-VscPin, Core) - eigener Dialog, siehe
    # Show-VscPinChangeDialog. (Der WinRT-Weg RequestPinChangeAsync ist nur für UWP frei.)
    $btnChangePin.Add_Click({
        if ($lvReaders.SelectedItems.Count -eq 0) { return }
        $r = $lvReaders.SelectedItems[0].Tag
        if (-not ((Test-IsVirtualCard $r) -or (Test-IsPhysicalCard $r))) { return }
        Show-VscPinChangeDialog -Reader $r -Owner $dlg | Out-Null
    })

    $btnDeleteReader.Add_Click({
        if ($lvReaders.SelectedItems.Count -eq 0) { return }
        $selectedReader = $lvReaders.SelectedItems[0].Tag
        if (-not (Test-IsVirtualCard $selectedReader)) { return }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            ((T "Virtuelle Smartcard '{0}' wirklich unwiderruflich löschen?`r`n`r`nAlle darauf gespeicherten Schlüssel gehen dabei verloren. Diese Aktion kann nicht rückgängig gemacht werden.") -f $selectedReader.FriendlyName),
            (T 'Smartcard löschen'), 'YesNo', 'Warning')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $btnDeleteReader.Enabled = $false
        Write-WizardLog -Message "Lösche virtuelle Smartcard: $($selectedReader.FriendlyName) ($($selectedReader.InstanceId))" -Level Command
        $result = Remove-VirtualSmartCard -InstanceId $selectedReader.InstanceId
        if ($result.Success) {
            Write-WizardLog -Message "Virtuelle Smartcard gelöscht: $($selectedReader.FriendlyName)" -Level Success
            [System.Windows.Forms.MessageBox]::Show((T 'Smartcard gelöscht.'), (T 'Erledigt'), 'OK', 'Information') | Out-Null
            $script:InventoryReopen = $true
            $dlg.Close()
        } else {
            Write-WizardLog -Message "Löschen fehlgeschlagen (Exit-Code $($result.ExitCode)): $($selectedReader.FriendlyName)" -Level Error
            [System.Windows.Forms.MessageBox]::Show(((T 'Löschen fehlgeschlagen (Exit-Code {0}). Details siehe Log.') -f $result.ExitCode), (T 'Fehler'), 'OK', 'Error') | Out-Null
            $btnDeleteReader.Enabled = $true
        }
    })

    $btnDeleteCert.Add_Click({
        if ($lvCerts.SelectedItems.Count -eq 0) { return }
        $c = $lvCerts.SelectedItems[0].Tag
        if (-not ($c -and $c.KeyContainerName -and $c.Provider)) {
            [System.Windows.Forms.MessageBox]::Show((T 'Für dieses Zertifikat ist kein Schlüssel-Container/Provider bekannt - Entfernen von der Karte nicht möglich.'), (T 'Nicht möglich'), 'OK', 'Warning') | Out-Null
            return
        }
        $idLine = if ($c.Upn) { (T 'Konto (UPN): {0}') -f $c.Upn } else { "Subject: $($c.Subject)" }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            ((T "Dieses Zertifikat samt Schlüssel UNWIDERRUFLICH von der Karte entfernen?`r`n`r`n{0}`r`nGültig bis: {1}`r`nThumbprint: {2}`r`nLesegerät: {3}`r`n`r`nNur den zu entfernenden Eintrag bestätigen - andere Zertifikate auf der Karte bleiben unberührt. Ggf. erscheint der PIN-Dialog der Karte.") -f $idLine, $c.NotAfter.ToString('yyyy-MM-dd'), $c.Thumbprint, $c.Reader),
            (T 'Zertifikat von Karte entfernen'), 'YesNo', 'Warning')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $btnDeleteCert.Enabled = $false
        $dlg.Cursor = 'WaitCursor'; $dlg.Refresh()
        try { $res = Remove-SmartCardCertificateFromCard -Provider $c.Provider -ContainerName $c.KeyContainerName -Thumbprint $c.Thumbprint }
        finally { $dlg.Cursor = 'Default' }
        if ($res.Success) {
            [System.Windows.Forms.MessageBox]::Show((T 'Zertifikat wurde von der Karte entfernt.'), (T 'Erledigt'), 'OK', 'Information') | Out-Null
            $script:InventoryReopen = $true
            $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show(((T 'Entfernen fehlgeschlagen: {0} Details siehe Log.') -f $res.Message), (T 'Fehler'), 'OK', 'Error') | Out-Null
            $btnDeleteCert.Enabled = $true
        }
    })

    $btnImportCert.Add_Click({
        if ($lvCerts.SelectedItems.Count -eq 0) { return }
        $c = $lvCerts.SelectedItems[0].Tag
        if (-not ($c -and $c.InStore -eq $false -and $c.RawData -and $c.KeyContainerName)) { return }
        $res = Import-SmartCardCertificateToStore -RawData ([byte[]]$c.RawData) -ContainerName $c.KeyContainerName -Provider $c.Provider
        if ($res.Success) {
            [System.Windows.Forms.MessageBox]::Show((T 'Zertifikat wurde in den Zertifikatsspeicher übernommen.'), (T 'Erledigt'), 'OK', 'Information') | Out-Null
            $script:InventoryReopen = $true
            $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show(((T 'Übernahme fehlgeschlagen: {0} Details siehe Log.') -f $res.Message), (T 'Fehler'), 'OK', 'Error') | Out-Null
        }
    })

    $btnCloseInventory.Add_Click({ $dlg.Close() })
    $btnRefreshInventory.Add_Click({ $script:InventoryReopen = $true; $dlg.Close() })

    # Erste echte Karte vorauswählen (dann sind die Zertifikate sofort sichtbar).
    $first = @($lvReaders.Items | Where-Object { Test-IsVirtualCard $_.Tag }) | Select-Object -First 1
    if ($first) { $first.Selected = $true } else { Update-CertListForSelection }

    # Aktualisieren/Löschen schließen den Dialog und öffnen ihn NACH Rückkehr aus
    # ShowDialog neu - sonst stapelt sich ein zweites Fenster ueber dem alten.
    $script:InventoryReopen = $false
    Set-DialogStyle -Dialog $dlg
    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
    if ($script:InventoryReopen) {
        $script:InventoryReopen = $false
        Show-VscInventoryDialog -Owner $Owner -UserView:$UserView -OnlyInstanceId $OnlyInstanceId
    }
}

function Show-SettingsDialog {
    param([System.Windows.Forms.Form]$Owner)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = (T 'Einstellungen')
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
        # AutoSize + MaximumSize (Spaltenbreite 280 minus Rand): lange Beschriftungen
        # brechen um und die (AutoSize-)Zeile wächst mit, statt die zweite Zeile
        # abzuschneiden.
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LabelText
        $lbl.AutoSize = $true
        $lbl.MaximumSize = New-Object System.Drawing.Size(270, 0)
        $lbl.Anchor = 'Left'
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

    $txtCfgCA = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgCA -Placeholder (T 'z.B. ca01.contoso.local\Contoso-Issuing-CA') -Value $config.CAConfig
    Add-SettingsRow -LabelText (T 'CA-Konfigurationsstring (Server\CA-Name):') -InputControl $txtCfgCA

    $cboCfgTemplate = New-Object System.Windows.Forms.ComboBox
    $cboCfgTemplate.DropDownStyle = 'DropDown'
    Set-TextBoxPlaceholder -TextBox $cboCfgTemplate -Placeholder (T 'z.B. SmartcardLogon') -Value $config.Template
    Add-SettingsRow -LabelText (T 'Zertifikatstemplate (für VSC-Anmeldung):') -InputControl $cboCfgTemplate

    # Szenario 03 (Cloud/Entra CBA): Supply-in-request-Template. Leer = der Wizard liest
    # die passenden Templates der CA im Ablauf selbst aus AD und bietet sie zur Wahl an.
    $cboCfgOfflineTemplate = New-Object System.Windows.Forms.ComboBox
    $cboCfgOfflineTemplate.DropDownStyle = 'DropDown'
    Set-TextBoxPlaceholder -TextBox $cboCfgOfflineTemplate -Placeholder (T 'leer = im Ablauf aus der CA wählen') -Value $config.OfflineTemplate
    Add-SettingsRow -LabelText (T 'Offline-Template (Szenario 03, Supply-in-request):') -InputControl $cboCfgOfflineTemplate

    $txtCfgPrefix = New-Object System.Windows.Forms.TextBox
    $txtCfgPrefix.Text = $config.VscNamePrefix
    Add-SettingsRow -LabelText (T 'Namenspräfix für virtuelle Smartcards:') -InputControl $txtCfgPrefix

    $numCfgPinMin = New-Object System.Windows.Forms.NumericUpDown
    $numCfgPinMin.Minimum = 4
    $numCfgPinMin.Maximum = 20
    $numCfgPinMin.Value = (Get-ConfiguredPinMinLength)
    Add-SettingsRow -LabelText (T 'PIN-Mindestlänge (COM: ab 6; tpmvscmgr/ARM64: /PINPOLICY):') -InputControl $numCfgPinMin

    # Andere Smartcards (z.B. YubiKey): nur Karten, deren Kartentreiber (Minidriver)
    # installiert ist und Schlüssel erzeugen kann - geprüft bei jeder Kartenauswahl.
    $chkCfgPhysical = New-Object System.Windows.Forms.CheckBox
    $chkCfgPhysical.Text = (T 'Auch andere Smartcards beschreiben (z.B. YubiKey) - sofern ihr Kartentreiber installiert ist und Schlüssel erzeugen kann')
    $chkCfgPhysical.Checked = (Test-PhysicalCardsAllowed -Config $config)
    $chkCfgPhysical.AutoSize = $true
    $chkCfgPhysical.MaximumSize = New-Object System.Drawing.Size(640, 0)
    Add-SettingsFullRow -Control $chkCfgPhysical

    $txtCfgJump = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgJump -Placeholder (T 'z.B. pki-jump.contoso.local') -Value $config.RdpJumpServer
    Add-SettingsRow -LabelText (T 'RDP-Zielserver für Plan B:') -InputControl $txtCfgJump

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
    Add-SettingsRow -LabelText (T 'Provider (CSP/KSP, muss zum Template passen):') -InputControl $txtCfgCsp

    $txtCfgDomain = New-Object System.Windows.Forms.TextBox
    $discoveryDomainDefault = if ($config.DiscoveryDomain) { $config.DiscoveryDomain } else { Get-DiscoveryDomainGuess }
    Set-TextBoxPlaceholder -TextBox $txtCfgDomain -Placeholder (T 'z.B. contoso.local oder dc01.contoso.local') -Value $discoveryDomainDefault
    Add-SettingsRow -LabelText (T 'AD-Domäne / Domain Controller (PKI-Erkennung):') -InputControl $txtCfgDomain

    $lblCfgDomainHint = New-Object System.Windows.Forms.Label
    $lblCfgDomainHint.Text = (T 'Auf Entra-joined/Workgroup-Rechnern meist nötig, da "serverloses" LDAP-Binding ohne Domain-Join nicht funktioniert. Vorschlag aus UPN abgeleitet, ggf. abweichend vom echten AD-DNS-Namen - bei Bedarf korrigieren.')
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
    $lblCfgDiscover.Text = (T 'Automatische PKI-Erkennung:')
    $lblCfgDiscover.AutoSize = $true
    $lblCfgDiscover.Margin = New-Object System.Windows.Forms.Padding(0, 8, 10, 0)
    $discoverPanel.Controls.Add($lblCfgDiscover)

    $btnDiscoverCfg = New-Object System.Windows.Forms.Button
    $btnDiscoverCfg.Text = (T 'PKI automatisch erkennen')
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
    $lblEaHeader.Text = (T 'Enrollment Agent (Ausstellung für separate Konten ohne RDP)')
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
    $lblEaWarn.Text = (T 'Achtung: Ein EA-Zertifikat, mit dem sich Logon-Certs für Admins ausstellen lassen, ist admin-äquivalent (Eskalationspfad ESC3) - wer es besitzt, kann sich als diese Konten anmelden. Für Admin-Zielkonten ist Self-Enrollment als das Konto selbst (Plan B) meist sicherer. EA/EOBO nur bewusst, eingeschränkt (Restricted Enrollment Agent) und auditiert einsetzen; EA-Schlüssel auf Hardware/VSC halten.')
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
        $lblEaStatus.Text = ((T 'EA-Zertifikat vorhanden: {0} (gültig bis {1}). Damit kann für separate Konten bruchfrei per Plan A ausgestellt werden.') -f $eaCertsNow[0].Subject, $eaCertsNow[0].NotAfter.ToString('yyyy-MM-dd'))
    } else {
        $lblEaStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $lblEaStatus.Text = (T 'Kein EA-Zertifikat gefunden. Ohne EA-Zertifikat muss für separate Konten der Plan-B/RDP-Weg genutzt werden.')
    }
    Add-SettingsFullRow -Control $lblEaStatus

    $txtCfgEaTemplate = New-Object System.Windows.Forms.TextBox
    Set-TextBoxPlaceholder -TextBox $txtCfgEaTemplate -Placeholder (T 'z.B. EnrollmentAgent') -Value $config.EATemplate
    Add-SettingsRow -LabelText (T 'EA-Zertifikatstemplate:') -InputControl $txtCfgEaTemplate

    $chkEaOnVsc = New-Object System.Windows.Forms.CheckBox
    $chkEaOnVsc.Text = (T 'EA-Schlüssel auf eigener VSC (TPM/PIN) statt Software-Schlüssel')
    $chkEaOnVsc.Checked = $true
    $chkEaOnVsc.AutoSize = $true
    Add-SettingsFullRow -Control $chkEaOnVsc

    $eaPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $eaPanel.AutoSize = $true
    $eaPanel.FlowDirection = 'LeftToRight'
    $eaPanel.WrapContents = $false
    $btnRequestEa = New-Object System.Windows.Forms.Button
    $btnRequestEa.Text = (T 'EA-Zertifikat beantragen')
    $btnRequestEa.Size = New-Object System.Drawing.Size(220, 30)
    $eaPanel.Controls.Add($btnRequestEa)
    # Wartende EA-Anträge (Manager-Genehmigung) abrufen - geht auch nach einem Neustart
    # des Wizards (der offene Antrag liegt im Windows-Antragsspeicher; die ID wird dann
    # abgefragt). Vorher gab es hier nur "erneut beantragen" (= neuer Antrag).
    $btnRetrieveEa = New-Object System.Windows.Forms.Button
    $btnRetrieveEa.Text = (T 'Wartenden EA-Antrag abrufen...')
    $btnRetrieveEa.Size = New-Object System.Drawing.Size(240, 30)
    $eaPanel.Controls.Add($btnRetrieveEa)
    Add-SettingsFullRow -Control $eaPanel

    $lblEaResult = New-Object System.Windows.Forms.Label
    $lblEaResult.AutoSize = $true
    $lblEaResult.MaximumSize = New-Object System.Drawing.Size(760, 0)
    Add-SettingsFullRow -Control $lblEaResult

    $btnRequestEa.Add_Click({
        $eaTemplate = Get-TextBoxRealValue -TextBox $txtCfgEaTemplate
        if ([string]::IsNullOrWhiteSpace($eaTemplate)) {
            [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst das EA-Zertifikatstemplate eintragen (und ggf. speichern).'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($config.CAConfig)) {
            [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst CA-Konfigurationsstring eintragen und speichern.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
            return
        }
        $btnRequestEa.Enabled = $false
        $lblEaResult.ForeColor = [System.Drawing.SystemColors]::WindowText
        $lblEaResult.Text = (T 'Beantrage EA-Zertifikat für das eigene Konto...')
        $dlg.Refresh()

        $result = Invoke-EnrollmentAgentRequest -Template $eaTemplate -OnVsc:$chkEaOnVsc.Checked
        if ($result.Success) {
            $lblEaResult.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblEaResult.Text = (T 'EA-Zertifikat wurde ausgestellt. Es steht ab sofort für die Ausstellung an separate Konten (Plan A) zur Verfügung.')
            $eaNow = @(Get-EnrollmentAgentCertificates)
            if ($eaNow.Count -gt 0) {
                $lblEaStatus.ForeColor = [System.Drawing.Color]::ForestGreen
                $lblEaStatus.Text = ((T 'EA-Zertifikat vorhanden: {0} (gültig bis {1}).') -f $eaNow[0].Subject, $eaNow[0].NotAfter.ToString('yyyy-MM-dd'))
            }
        } elseif ($result.Pending) {
            $lblEaResult.ForeColor = [System.Drawing.Color]::DarkOrange
            $script:EaPendingRequestId = $result.RequestId
            $lblEaResult.Text = ((T 'EA-Antrag eingereicht, wartet auf Genehmigung (RequestId {0}). {1}') -f $result.RequestId, (Get-PendingApprovalHint -RequestId $result.RequestId -NextStep (T "Danach hier 'Wartenden EA-Antrag abrufen...'.")))
        } else {
            $lblEaResult.ForeColor = [System.Drawing.Color]::Firebrick
            $lblEaResult.Text = ((T 'EA-Beantragung fehlgeschlagen: {0} Details siehe Log.') -f $result.Message)
        }
        $btnRequestEa.Enabled = $true
    })

    $btnRetrieveEa.Add_Click({
        if ([string]::IsNullOrWhiteSpace($config.CAConfig)) {
            [System.Windows.Forms.MessageBox]::Show((T 'Bitte zuerst CA-Konfigurationsstring eintragen und speichern.'), (T 'Hinweis'), 'OK', 'Warning') | Out-Null
            return
        }
        $script:EaPendingRequestId = Resolve-PendingRequestId -RequestId $script:EaPendingRequestId -NoResumeState
        if (-not $script:EaPendingRequestId) { return }
        $btnRetrieveEa.Enabled = $false
        try {
            $recv = Receive-PendingCertificate -RequestId $script:EaPendingRequestId -CAConfig $config.CAConfig -OutputDirectory (Join-Path (Get-WizardWorkingDir) 'EA-Abruf')
            if (-not $recv.Success) {
                $lblEaResult.ForeColor = if ($recv.Status -eq 'Pending') { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::Firebrick }
                $lblEaResult.Text = $recv.Message
                return
            }
            $complete = Complete-CertificateEnrollment -CerPath $recv.CerPath
            if (-not $complete.Success) {
                $lblEaResult.ForeColor = [System.Drawing.Color]::Firebrick
                $lblEaResult.Text = ((T 'EA-Zertifikat abgerufen ({0}), aber nicht installiert (z.B. PIN-Abfrage abgebrochen) - erneut abrufen. Details siehe Log.') -f $recv.CerPath)
                return
            }
            $script:EaPendingRequestId = $null
            $lblEaResult.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblEaResult.Text = (T 'EA-Zertifikat wurde abgerufen und installiert. Es steht ab sofort für die Ausstellung an separate Konten (Plan A) zur Verfügung.')
            $eaNow = @(Get-EnrollmentAgentCertificates)
            if ($eaNow.Count -gt 0) {
                $lblEaStatus.ForeColor = [System.Drawing.Color]::ForestGreen
                $lblEaStatus.Text = ((T 'EA-Zertifikat vorhanden: {0} (gültig bis {1}).') -f $eaNow[0].Subject, $eaNow[0].NotAfter.ToString('yyyy-MM-dd'))
            }
        } finally {
            [System.Windows.Forms.Application]::DoEvents()   # gepufferte Klicks am gesperrten Button verwerfen
            $btnRetrieveEa.Enabled = $true
        }
    })

    $footerPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $footerPanel.Dock = 'Fill'
    $footerPanel.FlowDirection = 'RightToLeft'
    $dlgLayout.Controls.Add($footerPanel, 0, 1)

    $btnCloseSettings = New-Object System.Windows.Forms.Button
    $btnCloseSettings.Text = (T 'Schließen')
    $btnCloseSettings.Size = New-Object System.Drawing.Size(120, 32)
    $btnCloseSettings.Margin = New-Object System.Windows.Forms.Padding(10)
    $footerPanel.Controls.Add($btnCloseSettings)
    $btnCloseSettings.Add_Click({ $dlg.Close() })

    $btnSaveConfig = New-Object System.Windows.Forms.Button
    $btnSaveConfig.Text = (T 'Speichern')
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
        $txtDiscoverResultCfg.Text = (T 'Prüfe PKI-Erreichbarkeit (bis zu ca. 40 Sekunden)...')
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
            $txtDiscoverResultCfg.Text = (T 'Zeitüberschreitung (>40s). Domäne/DC-Feld prüfen oder Netzwerkverbindung (VPN/Private Access) sicherstellen.')
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
                # Offline-Template: nur Auswahlliste füllen, Wert NICHT überschreiben
                # (leer ist ein gültiger, bewusster Zustand).
                $cboCfgOfflineTemplate.Items.Clear()
                [void]$cboCfgOfflineTemplate.Items.AddRange($allTemplates)
            }

            $txtDiscoverResultCfg.Text = ((T "{0} erreichbare CA(s) gefunden und übernommen - bitte Template prüfen (Dropdown-Pfeil zeigt alle {1} auf der CA verfügbaren Templates) und Speichern:`r`n") -f $reachData.ReachableCas.Count, $allTemplates.Count) +(($reachData.ReachableCas | ForEach-Object { "- $($_.Name) ($($_.ConfigString))" }) -join "`r`n")
            Write-WizardLog -Message "Automatische Erkennung: $($reachData.ReachableCas.Count) erreichbare CA(s) gefunden." -Level Success
        } elseif ($reachData.AllCas.Count -gt 0) {
            $txtDiscoverResultCfg.Text = ((T "{0} CA(s) in AD gefunden, aber per RPC nicht erreichbar (Firewall/Netzwerksegmentierung?):`r`n") -f $reachData.AllCas.Count) +($reachData.UnreachableCas -join "`r`n")
            Write-WizardLog -Message "Automatische Erkennung: $($reachData.AllCas.Count) CA(s) gefunden, keine per RPC erreichbar." -Level Info
        } elseif ($reachData.DiscoveryError) {
            $txtDiscoverResultCfg.Text = ((T "LDAP-Erkennung fehlgeschlagen: {0}`r`n`r`nTipp: Domäne/DC-Feld oben prüfen (z.B. expliziten DC-Namen statt DNS-Domäne versuchen) und Netzwerkverbindung (VPN/Private Access) sicherstellen.") -f $reachData.DiscoveryError)
            Write-WizardLog -Message "Automatische Erkennung fehlgeschlagen: $($reachData.DiscoveryError)" -Level Error
        } else {
            $txtDiscoverResultCfg.Text = (T 'Keine erreichbare CA gefunden.')
            Write-WizardLog -Message 'Automatische Erkennung: keine erreichbare CA gefunden.' -Level Info
        }
        $btnDiscoverCfg.Enabled = $true
    })

    $btnSaveConfig.Add_Click({
        # Vom bestehenden Stand ausgehen: Schlüssel, die dieser Dialog nicht kennt, bleiben
        # erhalten (früher ging dabei z.B. OfflineTemplate verloren).
        $newConfig = @{}
        if ($config) { foreach ($k in @($config.Keys)) { $newConfig[$k] = $config[$k] } }
        $newConfig['CAConfig']        = Get-TextBoxRealValue -TextBox $txtCfgCA
        $newConfig['Template']        = Get-TextBoxRealValue -TextBox $cboCfgTemplate
        $newConfig['OfflineTemplate'] = Get-TextBoxRealValue -TextBox $cboCfgOfflineTemplate
        $newConfig['VscNamePrefix']   = $txtCfgPrefix.Text
        $newConfig['RdpJumpServer']   = Get-TextBoxRealValue -TextBox $txtCfgJump
        $newConfig['CspName']         = $txtCfgCsp.Text
        $newConfig['DiscoveryDomain'] = Get-TextBoxRealValue -TextBox $txtCfgDomain
        $newConfig['EATemplate']      = Get-TextBoxRealValue -TextBox $txtCfgEaTemplate
        $newConfig['PinMinLength']    = [int]$numCfgPinMin.Value
        $newConfig['AllowPhysicalCards'] = "$($chkCfgPhysical.Checked)"
        $newConfig['WorkingDir']      = $config.WorkingDir
        Save-VscWizardConfig -Config $newConfig -Path $script:ConfigPath
        $script:config = $newConfig
        Set-VscPhysicalCardsAllowed -Allowed $chkCfgPhysical.Checked

        Set-TemplateComboItem -ComboBox $cboTemplateA -Template $newConfig.Template
        Set-TemplateComboItem -ComboBox $cboTemplateSubmitB -Template $newConfig.Template

        $lblCfgSaved.ForeColor = [System.Drawing.Color]::ForestGreen
        $lblCfgSaved.Text = (T 'Gespeichert.')
    })

    Set-ButtonStyle -Button $btnSaveConfig -Kind Primary   # Hauptaktion des Dialogs
    Set-DialogStyle -Dialog $dlg
    if ($Owner) { [void]$dlg.ShowDialog($Owner) } else { [void]$dlg.ShowDialog() }
}

#endregion

# ============================================================================
#region GESTALTUNG DER SCHRITT-SEITEN (Redesign: Karten, Hinweisboxen, Buttons)
# ============================================================================
# Zentral statt in jeder Seite: läuft einmal, nachdem alle Seiten gebaut sind.

# Farbige Ergebnismeldungen -> getönte Hinweisboxen. Der bestehende Code setzt weiterhin
# nur ForeColor (ForestGreen/Firebrick/DarkOrange/Black) + Text; hier wird daraus die
# passende Box (Hintergrund, Textfarbe, Innenabstand). Leerer Text = keine Box.
function Update-StatusLook {
    param([System.Windows.Forms.Label]$Label)
    if (-not $Label.Text) { $Label.BackColor = [System.Drawing.Color]::Transparent; $Label.Padding = New-Object System.Windows.Forms.Padding(0); return }
    $argb = $Label.ForeColor.ToArgb()
    $map = @{
        ([System.Drawing.Color]::ForestGreen.ToArgb()) = @($script:UI.SuccessWeak, $script:UI.Success)
        ($script:UI.Success.ToArgb())                  = @($script:UI.SuccessWeak, $script:UI.Success)
        ([System.Drawing.Color]::Firebrick.ToArgb())   = @($script:UI.DangerWeak, $script:UI.Danger)
        ($script:UI.Danger.ToArgb())                   = @($script:UI.DangerWeak, $script:UI.Danger)
        ([System.Drawing.Color]::DarkOrange.ToArgb())  = @($script:UI.WarnWeak, $script:UI.Warn)
        ($script:UI.Warn.ToArgb())                     = @($script:UI.WarnWeak, $script:UI.Warn)
    }
    $look = $map[$argb]
    if (-not $look) { $look = @($script:UI.Ground, $script:UI.Text) }   # neutral (z.B. "läuft..."/Abgebrochen)
    $Label.BackColor = $look[0]
    if ($Label.ForeColor.ToArgb() -ne $look[1].ToArgb()) { $Label.ForeColor = $look[1] }   # löst das Ereignis erneut aus, dann stabil
    $Label.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)
}
function Register-StatusLabel {
    param([System.Windows.Forms.Label]$Label)
    $Label.Add_TextChanged({ Update-StatusLook $this })
    $Label.Add_ForeColorChanged({ Update-StatusLook $this })
    Update-StatusLook $Label
}
foreach ($l in @($lblVscResultA, $lblVscResultB, $lblCertResultA, $lblSubmitResultB, $lblCompleteResultB, $lblRdpResultB)) { Register-StatusLabel $l }

# Karten-Hinweis "im Kartenauswahl-Dialog ... wählen" (Plan A und Plan B, EIN Stil):
# Die falsche Karte zu wählen landet das Zertifikat auf der falschen VSC - deshalb
# auffällig als bernsteinfarbene Warnbox mit kräftigem Balken links, größer und fett.
$script:CardHintActive = New-Object 'System.Collections.Generic.HashSet[object]'
function Set-CardHintLook {
    param([Parameter(Mandatory)][System.Windows.Forms.Label]$Label, [bool]$Active)
    if ($Active) {
        [void]$script:CardHintActive.Add($Label)
        $Label.BackColor = $script:UI.WarnWeak
        $Label.ForeColor = $script:UI.Warn
        $Label.Font = New-UiFont 11 -Semibold
        $Label.Padding = New-Object System.Windows.Forms.Padding(16, 9, 12, 9)
    } else {
        [void]$script:CardHintActive.Remove($Label)
        $Label.BackColor = [System.Drawing.Color]::Transparent
        $Label.ForeColor = $script:UI.Text
        $Label.Font = New-UiFont 9
        $Label.Padding = New-Object System.Windows.Forms.Padding(0)
    }
    $Label.Invalidate()
}
foreach ($l in @($lblCardHintA, $lblCsrInfoB, $lblRdpHintB)) {
    $l.Add_Paint({
        param($s, $e)
        if (-not $script:CardHintActive.Contains($s)) { return }
        $brush = New-Object System.Drawing.SolidBrush($script:UI.Warn)
        $e.Graphics.FillRectangle($brush, 0, 0, 5, $s.Height)
        $brush.Dispose()
    })
}
$lblCardHintA.Add_TextChanged({ Set-CardHintLook -Label $lblCardHintA -Active ([bool]$lblCardHintA.Text) })

# Jede Schritt-Seite wird eine weiße Karte in Inhaltsgröße mit FLIESSLAYOUT:
# Die Seiten sind historisch mit festen Pixel-Positionen gebaut (Breite 780 usw.) - das
# schnitt bei schmalerem Fenster Text ab und liess große Leerflächen. Statt jede Seite
# neu zu bauen, liest Initialize-PageReflow aus den ursprünglichen Positionen die ZEILEN
# (was nebeneinander steht, bleibt nebeneinander; Abstände zwischen Zeilen bleiben) und
# Invoke-PageReflow ordnet sie bei jeder Größen-/Text-/Sichtbarkeitsänderung neu an:
# Texte brechen in der verfügbaren Breite um und wachsen in die Höhe, breite Felder
# passen sich an, ausgeblendete/leere Elemente hinterlassen keine Lücke.
$script:StateMethod = [System.Windows.Forms.Control].GetMethod('GetState', [Reflection.BindingFlags]'NonPublic,Instance')
function Test-OwnVisible([System.Windows.Forms.Control]$Control) {
    # Eigener Sichtbarkeits-Zustand (Visible liefert bei verborgenem Elternteil immer $false).
    return [bool]$script:StateMethod.Invoke($Control, @(2))
}
$script:Reflow = @{}   # Seite -> @{ Rows; Orig; Busy }
# Control -> Anker: das Control wird in seiner Zeile vertikal mittig zum Anker gesetzt
# (Kartenhinweis neben dem großen Kartensymbol, ein- oder zweizeilig).
$script:ReflowVCenter = @{}
function Initialize-PageReflow {
    param([System.Windows.Forms.Panel]$Page)
    $orig = @{}
    $rows = New-Object System.Collections.ArrayList
    foreach ($c in @($Page.Controls | Sort-Object Top, Left)) {
        $orig[$c] = @{ Left = $c.Left; Top = $c.Top; Width = $c.Width; Height = $c.Height }
        $row = if ($rows.Count) { $rows[$rows.Count - 1] } else { $null }
        if (-not $row -or $c.Top -ge ($row.Bottom - 4)) {
            $row = @{ Top = $c.Top; Bottom = $c.Bottom; Items = (New-Object System.Collections.ArrayList); Gap = 0 }
            if ($rows.Count) { $row.Gap = [Math]::Max(6, $c.Top - $rows[$rows.Count - 1].Bottom) }
            [void]$rows.Add($row)
        }
        [void]$row.Items.Add($c)
        if ($c.Bottom -gt $row.Bottom) { $row.Bottom = $c.Bottom }
        if ($c -is [System.Windows.Forms.Label]) { $c.AutoSize = $true }
    }
    $script:Reflow[$Page] = @{ Rows = $rows; Orig = $orig; Busy = $false }
    $Page.Add_Layout({ Invoke-PageReflow -Page $this })
}
function Invoke-PageReflow {
    param([System.Windows.Forms.Panel]$Page)
    $info = $script:Reflow[$Page]
    if (-not $info -or $info.Busy) { return }
    $info.Busy = $true
    try {
        $W = $Page.ClientSize.Width - 24
        if ($W -lt 200) { return }
        $prevBottom = $null
        foreach ($row in $info.Rows) {
            $items = @($row.Items | Where-Object { (Test-OwnVisible $_) -and -not ($_ -is [System.Windows.Forms.Label] -and -not $_.Text) })
            if (-not $items) { continue }
            $top = if ($null -eq $prevBottom) { $row.Top } else { $prevBottom + $row.Gap }
            $bottom = $top
            foreach ($c in $items) {
                $o = $info.Orig[$c]
                if ($c -is [System.Windows.Forms.Label]) {
                    $c.MaximumSize = New-Object System.Drawing.Size([Math]::Max(80, $W - $o.Left), 0)
                } elseif ($o.Width -ge 480 -and $c -isnot [System.Windows.Forms.ButtonBase]) {
                    # Nur strecken, wenn rechts daneben nichts steht (z.B. "Pfad kopieren").
                    $rightOf = @($items | Where-Object { $_ -ne $c -and $info.Orig[$_].Left -gt $o.Left })
                    if (-not $rightOf) { $c.Width = [Math]::Max(120, $W - $o.Left) }
                }
                $c.Top = $top + ($o.Top - $row.Top)
                if ($c.Bottom -gt $bottom) { $bottom = $c.Bottom }
            }
            foreach ($c in $items) {
                $anchor = $script:ReflowVCenter[$c]
                if ($anchor -and ($items -contains $anchor)) { $c.Top = [int]($anchor.Top + ($anchor.Height - $c.Height) / 2) }
            }
            $prevBottom = $bottom
        }
        $h = if ($null -eq $prevBottom) { 40 } else { $prevBottom + 20 }
        if ($Page.Height -ne $h) { $Page.Height = $h }
    } finally { $info.Busy = $false }
}
$script:ReflowVCenter[$lblCardHintA] = $picCardA
$script:ReflowVCenter[$lblCsrInfoB] = $picCardB
$script:ReflowVCenter[$lblRdpHintB] = $picCardRdpB
# Kartensymbol-Zeile (96 px) oben: alle übrigen Elemente dieser Seiten darunter einreihen,
# sonst zöge die Zeilenbildung (nach ursprünglicher Höhe) sie in dieselbe Zeile.
foreach ($pg in @(@($pnlA3, $picCardA, $lblCardHintA), @($pnlB3, $picCardB, $lblCsrInfoB), @($pnlB7, $picCardRdpB, $lblRdpHintB))) {
    $minTop = @($pg[0].Controls | Where-Object { $_ -ne $pg[1] -and $_ -ne $pg[2] } | ForEach-Object { $_.Top } | Measure-Object -Minimum).Minimum
    $shift = ($pg[1].Bottom + 16) - $minTop
    if ($shift -gt 0) { foreach ($c in @($pg[0].Controls | Where-Object { $_ -ne $pg[1] -and $_ -ne $pg[2] })) { $c.Top += $shift } }
}
foreach ($stepHost in @($pnlStepsA, $pnlStepsB)) {
    $stepHost.AutoScroll = $true
    $stepHost.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 12)
    foreach ($page in @($stepHost.Controls)) {
        if ($page -isnot [System.Windows.Forms.Panel]) { continue }
        $page.Dock = 'Top'
        $page.BackColor = $script:UI.Surface
        Add-BorderPaint -Control $page
        Initialize-PageReflow -Page $page
    }
}

# Buttons: Hauptaktionen gefüllt (Primary), alle übrigen mit Rahmen (Secondary).
$primaryButtons = @($btnCreateVscA, $btnRequestCertA, $btnRetrieveA, $btnCreateVscB, $btnCreateCsrB, $btnSubmitB, $btnRetrieveB, $btnCompleteB, $btnCompleteFromTextB, $btnRdpConnectB)
function Set-ButtonStyleTree {
    param([System.Windows.Forms.Control]$Root)
    foreach ($c in $Root.Controls) {
        if ($c -is [System.Windows.Forms.Button] -and -not ($c.Tag -is [hashtable] -and $c.Tag['Kind'])) {
            $kind = if ($primaryButtons -contains $c) { 'Primary' } else { 'Secondary' }
            Set-ButtonStyle -Button $c -Kind $kind
            if ($kind -eq 'Primary') { $c.Add_EnabledChanged({ Update-PrimaryEnabledLook $this }); Update-PrimaryEnabledLook $c }
        }
        if ($c.HasChildren) { Set-ButtonStyleTree -Root $c }
    }
}
Set-ButtonStyleTree -Root $pnlContentArea

#endregion

# ============================================================================
#region STARTUP
# ============================================================================

Update-Splash -Text (T 'Umgebung erkennen (TPM, Kerberos, Karten)...') -Percent 80
if (-not $script:SimpleMode) { Show-ScenarioStep }   # Simple-Modus: eigene Startseite (Show-SimpleStart)
Update-Splash -Text (T 'Fertig.') -Percent 100

function Invoke-WizardResume {
    # Begonnenen Antrag aus einer frueheren Sitzung wieder aufnehmen (siehe
    # Save-WizardResumeState in Core.psm1): stellt die Wizard-Variablen wieder her
    # und springt direkt zum passenden Schritt.
    $state = Get-WizardResumeState
    if (-not $state) { return }

    $stageText = if ($state['Stage'] -eq 'Pending') { (T 'Antrag eingereicht, wartet auf Genehmigung (RequestId {0})') -f $state['RequestId'] } else { (T 'CSR erstellt, noch nicht eingereicht') }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        ((T "Ein begonnener Antrag vom {0} wurde gefunden:`r`n`r`nKarte: {1}`r`nStand: {2}`r`n`r`nFortsetzen? (Bei 'Nein' wird der gespeicherte Stand verworfen - der offene Antrag im Zertifikatsspeicher bleibt davon unberührt.)") -f $state['SavedAt'], $state['CardName'], $stageText),
        (T 'Begonnenen Antrag fortsetzen'), 'YesNo', 'Question')
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
        # Szenario-03-Modus mit wiederherstellen (ältere Stände ohne den Schlüssel: aus).
        $script:PlanA_OfflineDirect = ($state['OfflineDirect'] -eq 'True')
        $tabPlanA.Visible = $true
        Set-PlanATemplateForMode
        if ($state['Template']) { $cboTemplateA.Text = $state['Template'] }
        Show-PlanAStep -Index 1   # "Zertifikat anfordern" (Retrieve-Button dort)
        Set-PlanAPendingUi -RequestId $state['RequestId'] -Text ((T "Fortgesetzter Antrag (RequestId {0}), wartet auf Genehmigung. {1}") -f $(if ($state['RequestId']) { $state['RequestId'] } else { T 'unbekannt' }), (Get-PendingApprovalHint -RequestId $state['RequestId']))
    } else {
        $script:ActivePlan = 'B'
        $script:PlanB_VscCreated = $true
        $script:PlanB_CardName = $state['CardName']
        $script:PlanB_PcscName = $state['PcscName']
        $tabPlanB.Visible = $true
        if ($state['Stage'] -eq 'Pending') {
            $script:PlanB_SubmitDir = $state['SubmitDir']
            Show-PlanBStep -Index 4
            Set-PlanBPendingUi -RequestId $state['RequestId'] -Text ((T "Fortgesetzter Antrag (RequestId {0}), wartet auf Genehmigung. {1}") -f $(if ($state['RequestId']) { $state['RequestId'] } else { T 'unbekannt' }), (Get-PendingApprovalHint -RequestId $state['RequestId']))
        } else {
            $script:PlanB_CsrPath = $state['CsrPath']
            $txtCsrPathB.Text = $state['CsrPath']
            try { $txtCsrTextB.Text = Get-Content -Path $state['CsrPath'] -Raw -ErrorAction Stop } catch { $txtCsrTextB.Text = '' }
            Show-PlanBStep -Index 3
        }
    }
    Write-WizardLog -Message "Begonnener Antrag fortgesetzt (Plan $($state['Plan']), Stand: $stageText)." -Level Info
}

function Get-SimpleTargetPinMin {
    # Ziel-PIN im Simple-Modus: numerisch, mindestens 6 Stellen bzw. die Karten-
    # Mindestlänge aus der Konfiguration, falls höher. EINE Quelle für Startseite + Dialog.
    $minLen = 6
    if ($config.PinMinLength) { $minLen = [int]$config.PinMinLength }
    if ($minLen -lt 4) { $minLen = 4 }; if ($minLen -gt 20) { $minLen = 20 }
    return [pscustomobject]@{ CardMin = $minLen; TargetMin = [Math]::Max(6, $minLen) }
}

function Get-SimpleCardState {
    # Variante 1 (eine vorbereitete Karte pro Gerät, siehe docs/intune-rollout.md): ist die
    # Karte schon eingerichtet - von mir oder von jemand anderem? Grundlage ist die
    # Belegung AUF der Karte (Get-SmartCardOccupancy), denn Zertifikate anderer Benutzer
    # stehen nicht im eigenen Speicher. State: Free | Own | Other | Started | Unknown.
    param($Occupancy, [string]$CurrentUpn)
    if ($null -eq $Occupancy) { return [pscustomobject]@{ State = 'Unknown'; Entry = $null } }
    $withCert = @($Occupancy | Where-Object { $_.HasCertificate })
    if ($CurrentUpn) {
        $own = @($withCert | Where-Object { $_.Upn -and $_.Upn -eq $CurrentUpn }) | Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($own) { return [pscustomobject]@{ State = 'Own'; Entry = $own } }
    }
    if ($withCert.Count -gt 0) {
        $other = $withCert | Sort-Object NotAfter -Descending | Select-Object -First 1
        return [pscustomobject]@{ State = 'Other'; Entry = $other }
    }
    if (@($Occupancy).Count -gt 0) { return [pscustomobject]@{ State = 'Started'; Entry = $null } }
    return [pscustomobject]@{ State = 'Free'; Entry = $null }
}

function Close-WizardWindow {
    # Wizard beenden (Simple-Modus: "Fertig", "Schließen", "Später erinnern").
    $form.Close()
}

function Show-SimpleStart {
    # Startseite des Simple-Modus (VscWizard.exe -Simple / -AutoStart) statt der
    # Szenario-Übersicht. Zwei Wege:
    #  - Per-Benutzer-Karte (Variante 2): Einrichtung per -Install vorbereitet -> die
    #    eigene Karte "VSC-<Benutzer>" wird beim Start von der SYSTEM-Aufgabe angelegt
    #    (bzw. die vorhandene wiederverwendet).
    #  - Vorbereitete Karte (Variante 1, -Provision): per Find-ProvisionedVsc erkannt.
    $script:ActivePlan = 'SIMPLE'
    $tabPlanA.Visible = $false; $tabPlanB.Visible = $false
    $pnlScenario.Visible = $false; $pnlModeSelect.Visible = $false
    $pnlSimple.Visible = $true; $pnlSimple.BringToFront()
    $lblGlobalStep.Text = (T 'Smartcard einrichten')
    Update-Stepper -Labels @((T 'Start'), (T 'Eigene PIN'), (T 'Zertifikat'), (T 'Fertig')) -Current 0
    $btnBackShared.Enabled = $false

    $ready = $true
    if (-not $script:SimpleCardResolved) {
        $script:SimpleCardResolved = $true
        $script:SimpleCard = $null; $script:SimpleCardState = $null
        $readers = @(Invoke-Busy -Text (T 'Suche die vorbereitete Smartcard...') -Action { Get-VirtualSmartCardReaders } | Where-Object { $_.PcscName })
        $script:SimpleReaderCount = $readers.Count
        $script:PerUserMode = Test-VscCardServiceInstalled
        $found = $null
        if ($script:PerUserMode) {
            $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $rec = Get-VscUserCardRecord -Sid $mySid
            $mine = if ($rec) { $readers | Where-Object { "$($_.InstanceId)" -eq "$($rec.InstanceId)" } | Select-Object -First 1 }
            if ($mine) { $found = [pscustomobject]@{ Reader = $mine; Reason = 'SID-Zuordnung (HKLM)' } }
            $script:SimpleNewCardName = Get-VscUserCardName -Sid $mySid -Config $config -ExistingNames @($readers | ForEach-Object { $_.FriendlyName })
            Write-WizardLog -Message "Simple-Modus: Per-Benutzer-Einrichtung vorbereitet; eigene Karte $(if ($found) { "'$($found.Reader.FriendlyName)'" } else { "noch nicht vorhanden (wird '$($script:SimpleNewCardName)')" })." -Level Info
        } else {
            $found = Find-ProvisionedVsc -Readers $readers -ExpectedName (Get-VscProvisionCardName -Config $config)
        }
        if ($found) {
            $script:SimpleCard = $found.Reader
            Write-WizardLog -Message "Simple-Modus: Karte '$($found.Reader.FriendlyName)' ($($found.Reader.PcscName)) - $($found.Reason)." -Level Info
            # Schon eingerichtet (von mir / jemand anderem)? Still auf der Karte nachsehen.
            $occ = Invoke-Busy -Text (T 'Prüfe, ob die Smartcard schon eingerichtet ist...') -Action { Get-SmartCardOccupancy -PcscName $found.Reader.PcscName }
            $script:SimpleCardState = Get-SimpleCardState -Occupancy $occ -CurrentUpn (Get-CurrentUpn)
            Write-WizardLog -Message "Simple-Modus: Kartenzustand $($script:SimpleCardState.State)$(if ($script:SimpleCardState.Entry) { " (Zertifikat für $($script:SimpleCardState.Entry.Upn))" })." -Level Info
        } elseif (-not $script:PerUserMode) {
            Write-WizardLog -Message "Simple-Modus: keine eindeutige vorbereitete Karte ($($readers.Count) VSC vorhanden) - Auswahl beim Start." -Level Info
        }
    }
    if ([string]::IsNullOrWhiteSpace($config.CAConfig) -or [string]::IsNullOrWhiteSpace($config.Template)) {
        $lblSimpleCard.Text = (T 'Die Konfiguration (Zertifizierungsstelle/Vorlage) ist unvollständig. Der Einrichtungsassistent kann so kein Zertifikat ausstellen. Bitte die Einstellungen prüfen oder den Administrator kontaktieren.')
        $lblSimpleCard.ForeColor = $script:UI.Danger; $ready = $false
    } elseif ($script:SimpleNotice) {
        # Ergebnis/Hinweis des letzten Versuchs (z.B. Fehler beim Anlegen) - mit Ausweg.
        $lblSimpleCard.Text = $script:SimpleNotice.Text
        $lblSimpleCard.ForeColor = $script:SimpleNotice.Color
        $ready = $script:SimpleNotice.CanRetry
    } elseif ($script:SimpleCard -and $script:SimpleCardState -and $script:SimpleCardState.State -eq 'Own') {
        $e = $script:SimpleCardState.Entry
        $lblSimpleCard.Text = ((T 'Deine Smartcard ist bereits eingerichtet (Zertifikat für {0}, gültig bis {1}). Es ist nichts weiter zu tun.') -f $e.Upn, $(if ($e.NotAfter) { $e.NotAfter.ToString('yyyy-MM-dd') } else { '?' }))
        $lblSimpleCard.ForeColor = $script:UI.Success; $ready = $false
        Set-VscEnrollMarker | Out-Null   # Intune-Erkennung: für diesen Benutzer erledigt
    } elseif ($script:SimpleCard -and $script:SimpleCardState -and $script:SimpleCardState.State -eq 'Other') {
        $e = $script:SimpleCardState.Entry
        $who = if ($e.Upn) { $e.Upn } else { ($e.Subject -replace '^CN=', '') }
        $lblSimpleCard.Text = ((T 'Die Smartcard dieses Geräts ({0}) ist bereits für {1} eingerichtet. Für ein weiteres Benutzerkonto wende dich bitte an deine IT.') -f $script:SimpleCard.FriendlyName, $who)
        $lblSimpleCard.ForeColor = $script:UI.Danger; $ready = $false
    } elseif ($script:SimpleCard) {
        $lblSimpleCard.Text = ((T 'Deine Smartcard: {0}  (in Windows-Dialogen: {1})') -f $script:SimpleCard.FriendlyName, $script:SimpleCard.PcscName)
        $lblSimpleCard.ForeColor = $script:UI.Text
        if ($script:SimpleCardState -and $script:SimpleCardState.State -eq 'Started' -and -not $script:PerUserMode) {
            $lblSimpleCard.Text += "`r`n" + (T 'Auf der Karte liegt schon ein Schlüssel ohne Zertifikat. Falls du die Einrichtung schon begonnen und deine PIN geändert hast, trage im nächsten Schritt deine eigene PIN als aktuelle PIN ein.')
            $lblSimpleCard.ForeColor = $script:UI.Warn
        }
    } elseif ($script:PerUserMode) {
        $lblSimpleCard.Text = ((T 'Beim Start wird deine persönliche Smartcard "{0}" angelegt (dauert meist 5-15 Sekunden).') -f $script:SimpleNewCardName)
        $lblSimpleCard.ForeColor = $script:UI.Text
    } elseif ($script:SimpleReaderCount -gt 0) {
        $lblSimpleCard.Text = (T 'Auf diesem Gerät gibt es mehrere Smartcards - beim Start wählst du die richtige aus.')
        $lblSimpleCard.ForeColor = $script:UI.Warn
    } else {
        $lblSimpleCard.Text = (T 'Auf diesem Gerät ist noch keine vorbereitete Smartcard vorhanden. Bitte wende dich an deine IT.')
        $lblSimpleCard.ForeColor = $script:UI.Danger; $ready = $false
    }
    $btnSimpleStart.Enabled = $ready; Update-PrimaryEnabledLook $btnSimpleStart
    $btnNextShared.Enabled = $ready
    # Eingerichtet: nur noch "Smartcard verwalten" (eigene Karte: PIN ändern, Zertifikat
    # anzeigen) + "Schließen". Bewusst NICHT vor Abschluss der Einrichtung - eine dort
    # selbst geänderte PIN würde die gemerkte Start-PIN entwerten.
    $own = [bool]($script:SimpleCard -and $script:SimpleCardState -and $script:SimpleCardState.State -eq 'Own' -and -not $script:SimpleNotice)
    $btnSimpleStart.Visible = -not $own; $btnSimpleLater.Visible = -not $own
    $btnSimpleManage.Visible = $own; $btnSimpleClose.Visible = $own
}

function Set-SimpleNotice {
    # Hinweis auf der Startseite nach einem Versuch. -CanRetry: "Einrichtung starten" bleibt
    # aktiv (erneut versuchen) - so wird ein erwarteter Fehler keine Sackgasse.
    param([string]$Text, [ValidateSet('Info', 'Warn', 'Error')][string]$Kind = 'Warn', [bool]$CanRetry = $true)
    $color = switch ($Kind) { 'Info' { $script:UI.Text } 'Warn' { $script:UI.Warn } default { $script:UI.Danger } }
    $script:SimpleNotice = [pscustomobject]@{ Text = $Text; Color = $color; CanRetry = $CanRetry }
    Show-SimpleStart
}

function Enter-SimpleFlow {
    # "Einrichtung starten". Per-Benutzer-Karte: Auftrag an die SYSTEM-Aufgabe (Anlegen
    # bzw. vorhandene Karte + offene Start-PIN) -> Warten per Timer (Fenster bleibt
    # bedienbar) -> Complete-SimpleCardRequest. Vorbereitete Karte (Variante 1): direkt
    # PIN ändern -> ausstellen.
    if ([string]::IsNullOrWhiteSpace($config.CAConfig) -or [string]::IsNullOrWhiteSpace($config.Template)) {
        Write-WizardLog -Message 'Simple-Modus: Konfiguration unvollständig (CAConfig/Template).' -Level Warn
        return
    }
    $script:SimpleNotice = $null
    if ($script:PerUserMode) { Start-SimpleCardRequest; return }

    $card = $script:SimpleCard
    if (-not $card) { $card = Select-ExistingVsc }
    if (-not $card) { Write-WizardLog -Message 'Simple-Modus: keine VSC gewählt.' -Level Warn; return }
    $startPin = ''
    try { $startPin = Get-VscBootstrapPin -MinLength (Get-SimpleTargetPinMin).CardMin } catch {
        Write-WizardLog -Message "Simple-Modus: Start-PIN konnte nicht abgeleitet werden: $($_.Exception.Message)" -Level Warn
    }
    Invoke-SimplePinAndIssue -Card $card -StartPin $startPin
}

function Invoke-SimplePinAndIssue {
    # PIN-Änderung ERZWINGEN (Start-PIN vorbelegt), dann Zertifikat für das eigene Konto
    # ausstellen (Szenario 02). Ohne -StartPin: der Benutzer hat seine PIN schon vergeben
    # (z.B. Einrichtung vorher nach der PIN abgebrochen) -> direkt ausstellen.
    param([Parameter(Mandatory)]$Card, [string]$StartPin, [switch]$ReportPinChange)
    if ($StartPin) {
        $pinMin = Get-SimpleTargetPinMin
        Update-Stepper -Labels @((T 'Start'), (T 'Eigene PIN'), (T 'Zertifikat'), (T 'Fertig')) -Current 1
        $changed = Show-VscPinChangeDialog -Reader $Card -Owner $form -PrefillCurrentPin $StartPin -NumericOnly -MinNewLength $pinMin.TargetMin
        if (-not $changed) {
            Write-WizardLog -Message 'Simple-Modus: PIN-Änderung abgebrochen - Zertifikatsausstellung wird nicht gestartet.' -Level Warn
            Set-SimpleNotice -Text (T 'Die Einrichtung geht erst weiter, wenn du eine eigene PIN vergeben hast. Klicke dazu erneut auf "Einrichtung starten" - deine Karte bleibt erhalten.') -Kind Warn
            return
        }
        if ($ReportPinChange) {
            # SYSTEM-Aufgabe: gemerkte Start-PIN verwerfen (sonst würde sie später veraltet
            # vorbelegt und kostete einen Fehlversuch). Fehler hier sind unkritisch.
            try { [void](Submit-VscCardRequest -Type PinChanged); [void](Start-VscCardService) } catch { Write-WizardLog -Message "PIN-Änderung nicht gemeldet: $($_.Exception.Message)" -Level Warn }
        }
    } else {
        Write-WizardLog -Message "Simple-Modus: eigene PIN für '$($Card.FriendlyName)' bereits vergeben - direkt zur Ausstellung." -Level Info
    }
    Write-WizardLog -Message "Simple-Modus: starte Zertifikatsausstellung für die Karte '$($Card.FriendlyName)'." -Level Info
    $pnlSimple.Visible = $false
    Enter-PlanARenewal -Reader $Card -TargetAccount $null
}

function Start-SimpleCardRequest {
    # Auftrag ablegen + SYSTEM-Aufgabe starten; Antwort per Timer abwarten.
    $btnSimpleStart.Enabled = $false; Update-PrimaryEnabledLook $btnSimpleStart; $btnNextShared.Enabled = $false
    try {
        $script:SimpleReqId = Submit-VscCardRequest -Type Create
    } catch {
        Write-WizardLog -Message "Simple-Modus: Auftrag nicht ablegbar: $($_.Exception.Message)" -Level Error
        Set-SimpleNotice -Text ((T 'Die Einrichtung ist auf diesem Gerät nicht vollständig vorbereitet (Auftragsordner fehlt oder ist gesperrt: {0}). Bitte wende dich an deine IT.') -f $_.Exception.Message) -Kind Error -CanRetry $true
        return
    }
    $err = Start-VscCardService
    if ($err) {
        Write-WizardLog -Message "Simple-Modus: SYSTEM-Aufgabe nicht startbar: $err" -Level Error
        Set-SimpleNotice -Text ((T 'Die Einrichtung ist auf diesem Gerät nicht vollständig vorbereitet (Aufgabe "{0}" nicht startbar). Bitte wende dich an deine IT.') -f (Get-VscServicePaths).CreateTask) -Kind Error -CanRetry $true
        return
    }
    Write-WizardLog -Message "Simple-Modus: Auftrag $($script:SimpleReqId) abgelegt, SYSTEM-Aufgabe gestartet." -Level Info
    $script:SimpleReqStart = Get-Date; $script:SimpleReqKicked = $false
    Set-Busy -Text (T 'Deine Smartcard wird angelegt... (dauert meist 5-15 Sekunden)')
    $script:SimpleReqTimer.Start()
}

function Invoke-SimpleCardPoll {
    # Timer-Takt (1 s): Antwort da? Nach 20 s die Aufgabe einmal erneut anstoßen (evtl. lief
    # gerade eine andere Instanz), nach 90 s fragen: weiter warten oder abbrechen.
    $r = Read-VscCardResult -Id $script:SimpleReqId
    if (-not $r) {
        $el = ((Get-Date) - $script:SimpleReqStart).TotalSeconds
        if ($el -gt 20 -and -not $script:SimpleReqKicked) { $script:SimpleReqKicked = $true; [void](Start-VscCardService) }
        if ($el -gt 90) {
            $script:SimpleReqTimer.Stop(); Clear-Busy
            Write-WizardLog -Message "Simple-Modus: keine Antwort der SYSTEM-Aufgabe nach 90 s (Auftrag $($script:SimpleReqId))." -Level Warn
            $ans = [System.Windows.Forms.MessageBox]::Show((T "Das Anlegen der Smartcard dauert ungewöhnlich lange.`r`n`r`nWeiter warten?"), (T 'Einrichtung'), 'YesNo', 'Question')
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
                $script:SimpleReqStart = Get-Date; $script:SimpleReqKicked = $false
                [void](Start-VscCardService)
                Set-Busy -Text (T 'Deine Smartcard wird angelegt... (dauert meist 5-15 Sekunden)')
                $script:SimpleReqTimer.Start()
            } else {
                Set-SimpleNotice -Text ((T 'Die Smartcard wurde (noch) nicht angelegt. Versuche es gleich erneut; bleibt es dabei, hilft deine IT (Protokoll: {0}).') -f (Get-VscServicePaths).LogFile) -Kind Warn
            }
        }
        return
    }
    $script:SimpleReqTimer.Stop(); Clear-Busy
    Complete-SimpleCardRequest -Result $r
}

function Complete-SimpleCardRequest {
    # Antwort der SYSTEM-Aufgabe umsetzen. Jeder erwartete Fehler endet mit einem Ausweg
    # (erneut versuchen / konkreter Hinweis an die IT) statt in einer Sackgasse.
    param([Parameter(Mandatory)][hashtable]$Result)
    Write-WizardLog -Message "Simple-Modus: Antwort $($Result.Status) $(if ($Result.Code) { "($($Result.Code))" }) für '$($Result.CardName)'." -Level Info
    switch ($Result.Status) {
        { $_ -in 'Created', 'Existing' } {
            # Karte suchen (nach dem Anlegen braucht Windows einen Moment für das Gerät).
            $card = $null
            for ($i = 0; $i -lt 10 -and -not $card; $i++) {
                $card = @(Get-VirtualSmartCardReaders | Where-Object { "$($_.InstanceId)" -eq "$($Result.InstanceId)" -and $_.PcscName }) | Select-Object -First 1
                if (-not $card) { Start-Sleep -Milliseconds 500 }
            }
            if (-not $card) { $card = [pscustomobject]@{ FriendlyName = $Result.CardName; PcscName = $Result.PcscName; InstanceId = $Result.InstanceId } }
            $script:SimpleCard = $card
            Invoke-SimplePinAndIssue -Card $card -StartPin $Result.StartPin -ReportPinChange
        }
        default {
            $code = "$($Result.Code)"
            switch ($code) {
                'Limit' { Set-SimpleNotice -Text ((T 'Auf diesem Gerät ist kein Platz für eine weitere Smartcard ({0} von maximal {1}). Bitte wende dich an deine IT - nicht mehr benötigte Karten lassen sich dort entfernen.') -f $Result.Count, $Result.Max) -Kind Error -CanRetry $true }
                'TpmNotReady' { Set-SimpleNotice -Text (T 'Der Sicherheitschip (TPM) dieses Geräts ist gerade nicht bereit. Starte das Gerät neu und versuche es dann erneut; hilft das nicht, wende dich an deine IT.') -Kind Error -CanRetry $true }
                default { Set-SimpleNotice -Text ((T 'Die Smartcard konnte nicht angelegt werden ({0}). Versuche es bitte erneut; bleibt der Fehler, hilft deine IT (Protokoll: {1}).') -f $(if ($Result.Message) { $Result.Message } else { $code }), (Get-VscServicePaths).LogFile) -Kind Error -CanRetry $true }
            }
        }
    }
}

# --- Startseite des Simple-Modus -----------------------------------------------------
$pnlSimple = New-Object System.Windows.Forms.Panel
$pnlSimple.Dock = 'Fill'; $pnlSimple.Visible = $false; $pnlSimple.BackColor = $script:UI.Ground
$pnlSimple.Padding = New-Object System.Windows.Forms.Padding(24, 8, 24, 16)
$pnlContentArea.Controls.Add($pnlSimple)
$simpleBox = New-Object System.Windows.Forms.FlowLayoutPanel
$simpleBox.Dock = 'Top'; $simpleBox.AutoSize = $true; $simpleBox.AutoSizeMode = 'GrowAndShrink'
$simpleBox.FlowDirection = 'TopDown'; $simpleBox.WrapContents = $false
$simpleBox.BackColor = $script:UI.Surface; $simpleBox.Padding = New-Object System.Windows.Forms.Padding(24, 20, 24, 22)
Add-BorderPaint -Control $simpleBox
$pnlSimple.Controls.Add($simpleBox)
function New-SimpleLabel([string]$Text, [float]$Size = 10, [switch]$Semibold, [int]$Top = 0, [int]$Bottom = 10) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.UseMnemonic = $false
    $l.Font = New-UiFont $Size -Semibold:$Semibold; $l.ForeColor = $script:UI.Text
    $l.Margin = New-Object System.Windows.Forms.Padding(0, $Top, 0, $Bottom)
    return $l
}
$pinMinInfo = Get-SimpleTargetPinMin
$lblSimpleTitle = New-SimpleLabel (T 'Der folgende Assistent führt dich durch die Einrichtung deiner virtuellen Smartcard.') 12 -Semibold -Bottom 16
$lblSimpleStep1 = New-SimpleLabel ((T '1.  Eigene PIN vergeben - die Start-PIN ist schon eingetragen, du wählst eine neue, nur dir bekannte PIN aus mindestens {0} Ziffern.') -f $pinMinInfo.TargetMin)
$lblSimpleStep2 = New-SimpleLabel (T '2.  Anmeldezertifikat ausstellen - der Assistent beantragt dein Zertifikat und legt es auf die Smartcard. Windows fragt dabei nach deiner neuen PIN.') -Bottom 16
$lblSimpleCard = New-SimpleLabel '' 9.5 -Bottom 18
$btnSimpleStart = New-Object System.Windows.Forms.Button
$btnSimpleStart.Text = (T 'Einrichtung starten'); $btnSimpleStart.Size = New-Object System.Drawing.Size(200, 36)
$btnSimpleStart.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
Set-ButtonStyle -Button $btnSimpleStart -Kind Primary
$btnSimpleStart.Add_Click({ Enter-SimpleFlow })
# "Später": Anmelde-Autostart einen Tag zurückstellen (über das Startmenü jederzeit).
$btnSimpleLater = New-Object System.Windows.Forms.Button
$btnSimpleLater.Text = (T 'Später erinnern'); $btnSimpleLater.Size = New-Object System.Drawing.Size(160, 36)
$btnSimpleLater.Margin = New-Object System.Windows.Forms.Padding(0)
Set-ButtonStyle -Button $btnSimpleLater -Kind Secondary
$btnSimpleLater.Add_Click({
    try { Set-VscSnooze -Hours 24 } catch { }
    Write-WizardLog -Message 'Simple-Modus: auf später zurückgestellt (24 h).' -Level Info
    Close-WizardWindow
})
$simpleButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$simpleButtons.AutoSize = $true; $simpleButtons.AutoSizeMode = 'GrowAndShrink'; $simpleButtons.WrapContents = $false
$simpleButtons.Margin = New-Object System.Windows.Forms.Padding(0)
$btnSimpleManage = New-Object System.Windows.Forms.Button
$btnSimpleManage.Text = (T 'Smartcard verwalten'); $btnSimpleManage.Size = New-Object System.Drawing.Size(200, 36)
$btnSimpleManage.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0); $btnSimpleManage.Visible = $false
Set-ButtonStyle -Button $btnSimpleManage -Kind Primary
$btnSimpleManage.Add_Click({ if ($script:SimpleCard) { Show-VscInventoryDialog -Owner $form -UserView -OnlyInstanceId "$($script:SimpleCard.InstanceId)" } })
$btnSimpleClose = New-Object System.Windows.Forms.Button
$btnSimpleClose.Text = (T 'Schließen'); $btnSimpleClose.Size = New-Object System.Drawing.Size(140, 36)
$btnSimpleClose.Margin = New-Object System.Windows.Forms.Padding(0); $btnSimpleClose.Visible = $false
Set-ButtonStyle -Button $btnSimpleClose -Kind Secondary
$btnSimpleClose.Add_Click({ Close-WizardWindow })
$simpleButtons.Controls.AddRange(@($btnSimpleStart, $btnSimpleLater, $btnSimpleManage, $btnSimpleClose))
$simpleBox.Controls.AddRange(@($lblSimpleTitle, $lblSimpleStep1, $lblSimpleStep2, $lblSimpleCard, $simpleButtons))
# Texte in der verfügbaren Breite umbrechen.
$pnlSimple.Add_Resize({
    $w = [Math]::Max(200, $pnlSimple.ClientSize.Width - $pnlSimple.Padding.Horizontal - $simpleBox.Padding.Horizontal - 4)
    foreach ($l in @($lblSimpleTitle, $lblSimpleStep1, $lblSimpleStep2, $lblSimpleCard)) { $l.MaximumSize = New-Object System.Drawing.Size($w, 0) }
})
# Warten auf die SYSTEM-Aufgabe ohne das Fenster zu blockieren.
$script:SimpleReqTimer = New-Object System.Windows.Forms.Timer
$script:SimpleReqTimer.Interval = 1000
$script:SimpleReqTimer.Add_Tick({ Invoke-SimpleCardPoll })
$configIncomplete = [string]::IsNullOrWhiteSpace($config.CAConfig) -or [string]::IsNullOrWhiteSpace($config.Template)
if ($script:SimpleMode) {
    # Intune-Benutzer-App (-Simple): eigene Startseite statt Szenario-Übersicht; der
    # Ablauf beginnt mit "Einrichtung starten". Einstellungen und Geräte-Details sind
    # hier nur Ballast.
    $btnOpenSettings.Visible = $false
    $pnlDevice.Visible = $false
    $form.Add_Shown({ Show-SimpleStart })
} elseif ($configIncomplete) {
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
