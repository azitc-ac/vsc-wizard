<#
    VscWizard.Core.psm1

    Nicht-GUI-Logik für den VSC-Wizard: Konfiguration, Logging, Prozessausführung,
    Erkennung von Domänen-/TPM-Status sowie die eigentlichen Schritte zur Erstellung
    einer virtuellen Smartcard (tpmvscmgr) und zur Zertifikatsbeantragung (certreq).
#>

#Requires -Version 5.1

# Wenn dieses Skript aus einer PowerShell-7(pwsh)-Umgebung heraus gestartet wird (z.B.
# aus einem pwsh-Terminal oder von einem Prozess, der pwsh's PSModulePath-Einträge
# geerbt hat), steht "C:\Program Files\PowerShell\7\Modules" VOR dem nativen
# Windows-PowerShell-5.1-Modulpfad in $env:PSModulePath. Windows PowerShell 5.1 lädt
# dann beim Autoloading eingebauter Module die dortige, für PowerShell 7 gebaute
# Variante statt der eigenen - betroffen sind nicht nur Microsoft.PowerShell.Utility
# (Import-PowerShellDataFile fehlt dann, config.psd1 wird nie geladen), sondern auch
# Microsoft.PowerShell.Security: dessen falsch geladene Variante registriert das
# "Cert:"-Laufwerk nicht, wodurch Get-ChildItem Cert:\CurrentUser\My mit "Ein Laufwerk
# mit dem Namen 'Cert' ist nicht vorhanden" fehlschlägt - auf echter Hardware
# reproduziert, dadurch zeigte das Smartcard-Inventar trotz vorhandener Zertifikate
# konsequent 0 Einträge. Fix: die nativen Module explizit über den vollen Pfad laden
# (umgeht die PSModulePath-Suche) - für jedes eingebaute Modul, von dem dieses Skript
# abhängt.
foreach ($nativeModuleName in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Management')) {
    $nativeModulePath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\Modules\$nativeModuleName\$nativeModuleName.psd1"
    if (Test-Path $nativeModulePath) {
        Import-Module $nativeModulePath -Force -ErrorAction SilentlyContinue
    }
}

$script:Config = $null
$script:ConfigPath = $null
$script:LogBox = $null
$script:LogFilePath = $null

#region Konfiguration

function Import-VscWizardConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Konfigurationsdatei nicht gefunden: $Path"
    }
    try {
        $data = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    } catch {
        # Nicht erneut werfen: ein leeres $data führt dazu, dass der Wizard die Werte
        # als fehlend behandelt und automatisch den Einstellungen-Tab öffnet (siehe
        # STARTUP-Region in VscWizard.ps1) - das ist nachvollziehbarer als ein
        # uncaught Fehler vor dem eigentlichen GUI-Start.
        $data = @{}
    }
    $script:Config = $data
    $script:ConfigPath = $Path
    return $data
}

function Save-VscWizardConfig {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Path = $script:ConfigPath
    )

    $lines = @('@{')
    foreach ($key in $Config.Keys) {
        $value = $Config[$key]
        # Apostrophe verdoppeln (PSD1-Stringliteral) - sonst wäre die Datei danach unlesbar
        # und der Wizard startete mit leerer Konfiguration.
        if ($value -is [array]) {
            $items = ($value | ForEach-Object { "'$("$_".Replace("'", "''"))'" }) -join ', '
            $lines += "    $key = @($items)"
        } else {
            $lines += "    $key = '$("$value".Replace("'", "''"))'"
        }
    }
    $lines += '}'
    Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding UTF8
    $script:Config = $Config
}

function Get-WizardWorkingDir {
    $dir = $script:Config.WorkingDir
    if (-not $dir) { $dir = Join-Path $env:TEMP 'VscWizard' }
    $dir = [Environment]::ExpandEnvironmentVariables($dir)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

#endregion

#region Fortsetzbarer Antrag (Resume-Zustand)

# Ein begonnener Antrag überlebt einen Wizard-Neustart als key=value-Datei im
# Arbeitsverzeichnis: nach jedem Meilenstein (CSR erstellt, Antrag eingereicht/
# wartet auf Genehmigung) gespeichert, nach erfolgreicher Zertifikatsübernahme
# gelöscht. Windows hält den offenen certreq-Antrag ohnehin im REQUEST-Store
# des Benutzers - hier geht es nur um den Wizard-Kontext (RequestId, Kartenname,
# Pfade), der sonst beim Schließen verloren ginge.

function Get-WizardResumeStatePath {
    Join-Path (Get-WizardWorkingDir) 'resume-state.txt'
}

function Save-WizardResumeState {
    param([Parameter(Mandatory)][hashtable]$State)
    $State['SavedAt'] = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $lines = foreach ($key in $State.Keys) { "$key=$($State[$key])" }
    Set-Content -Path (Get-WizardResumeStatePath) -Value $lines -Encoding UTF8
}

function Get-WizardResumeState {
    $path = Get-WizardResumeStatePath
    if (-not (Test-Path $path)) { return $null }
    $state = @{}
    foreach ($line in (Get-Content -Path $path -ErrorAction SilentlyContinue)) {
        $idx = $line.IndexOf('=')
        if ($idx -gt 0) { $state[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
    }
    if ($state.Count -eq 0) { return $null }
    return $state
}

function Clear-WizardResumeState {
    Remove-Item -Path (Get-WizardResumeStatePath) -ErrorAction SilentlyContinue
}

#endregion

#region Logging

function Initialize-WizardLog {
    param([System.Windows.Forms.RichTextBox]$LogBox)

    $script:LogBox = $LogBox
    $dir = Get-WizardWorkingDir
    $script:LogFilePath = Join-Path $dir "vscwizard-$(Get-Date -Format 'yyyyMMdd').log"
}

function Write-WizardLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Command', 'Output', 'Error', 'Success', 'Warn')][string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
    }
    if ($script:LogBox) {
        $color = switch ($Level) {
            'Error' { [System.Drawing.Color]::Firebrick }
            'Success' { [System.Drawing.Color]::ForestGreen }
            'Command' { [System.Drawing.Color]::SteelBlue }
            'Warn' { [System.Drawing.Color]::DarkOrange }
            default { [System.Drawing.Color]::Black }
        }
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.SelectionLength = 0
        $script:LogBox.SelectionColor = $color
        $script:LogBox.AppendText("$line`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

#endregion

#region Sprache (DE/EN)

# Der DEUTSCHE Text ist zugleich der Schlüssel: (T 'Zertifikat anfordern') liefert auf
# Deutsch den Text unverändert, auf Englisch die Übersetzung aus
# VscWizard.Strings.en.psd1 (Deutsch -> Englisch). Fehlt eine Übersetzung, erscheint
# der deutsche Text (nie eine Lücke); tests\Test-Strings.ps1 findet fehlende Einträge.
# Texte mit Werten: Platzhalter {0}, {1} ... -> (T 'Antrag {0} ...') -f $id.
# Das Protokoll (Write-WizardLog) bleibt bewusst deutsch (Diagnose).
$script:Lang = 'de'
$script:EnStrings = @{}

function Set-WizardLanguage {
    param([string]$Language)
    $script:Lang = if ("$Language" -match '^en') { 'en' } else { 'de' }
    # Für Hintergrund-Jobs (Start-Job = eigener Prozess, erbt die Umgebung): das Modul
    # übernimmt diese Sprache beim Laden automatisch (siehe Ende dieses Abschnitts).
    $env:VSCWIZARD_UILANG = $script:Lang
    $script:EnStrings = @{}
    if ($script:Lang -eq 'en') {
        $path = Join-Path $PSScriptRoot 'VscWizard.Strings.en.psd1'
        if (Test-Path $path) {
            try { $script:EnStrings = Import-PowerShellDataFile -Path $path -ErrorAction Stop } catch { $script:EnStrings = @{} }
        }
    }
}

function Get-WizardLanguage { return $script:Lang }

function T {
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)
    if ($script:Lang -eq 'en' -and $script:EnStrings.ContainsKey($Text)) { return $script:EnStrings[$Text] }
    return $Text
}

# In einem Hintergrund-Job: Sprache des GUI-Prozesses übernehmen.
if ($env:VSCWIZARD_UILANG) { Set-WizardLanguage -Language $env:VSCWIZARD_UILANG }

#endregion

#region Busy-Anzeige (GUI-Hook)

# Alle potenziell langsamen Kernfunktionen (PnP/WMI, Zertifikate, LDAP, externe
# Prozesse) melden sich hier selbst als "beschäftigt". Die GUI registriert einmalig
# ihre Banner-Funktionen (Register-WizardBusyHook) - dadurch erscheint Wartecursor +
# Banner AUTOMATISCH, egal von welcher GUI-Stelle aus eine langsame Funktion aufgerufen
# wird (vorher musste jede Aufrufstelle selbst daran denken, und einige fehlten). In
# Hintergrund-Jobs ist kein Hook registriert -> reine No-ops.
function Register-WizardBusyHook {
    param([scriptblock]$Enter, [scriptblock]$Exit)
    $script:BusyEnterHook = $Enter
    $script:BusyExitHook = $Exit
}

function Enter-WizardBusy {
    param([Parameter(Mandatory)][string]$Text)
    # Übersetzung hier zentral - Aufrufer übergeben den deutschen Text.
    if ($script:BusyEnterHook) { try { & $script:BusyEnterHook (T $Text) } catch { } }
}

function Exit-WizardBusy {
    if ($script:BusyExitHook) { try { & $script:BusyExitHook } catch { } }
}

#endregion

#region Prozessausführung

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

$script:ForegroundHelperReady = $false
function Initialize-ForegroundHelper {
    # Einmalig kompiliert; schlägt das fehl, laufen externe Aufrufe wie bisher (ohne Hilfe).
    if ($script:ForegroundHelperReady -or $script:ForegroundHelperFailed) { return }
    try {
        if (-not ('VscWizardForeground' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// PIN-/Sicherheitsdialoge externer Programme (certreq, tpmvscmgr, ...) nach vorn holen.
// Sie gehören dem Kindprozess oder CredentialUIBroker ("Credential Dialog Xaml Host") -
// wegen der Windows-Fokussperre erschienen sie je nach Timing HINTER dem Wizard.
public static class VscWizardForeground {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

    static readonly uint Self = (uint)Process.GetCurrentProcess().Id;

    public static void AllowAny() { AllowSetForegroundWindow(-1); }   // ASFW_ANY

    // Holt ein sichtbares Fenster des Kindprozesses bzw. einen Windows-Sicherheitsdialog
    // nach vorn - NUR solange der Wizard selbst vorn ist (wer zu einer anderen App
    // gewechselt hat, bekommt den Fokus nicht weggenommen). Rückgabe: Beschreibung des
    // nach vorn geholten Fensters, sonst null.
    public static string PromoteDialogs(int childPid) {
        uint fgPid;
        GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
        if (fgPid != Self) return null;
        IntPtr target = IntPtr.Zero; string desc = null;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            var cls = new StringBuilder(256); GetClassNameW(h, cls, 256);
            if (pid == (uint)childPid || cls.ToString() == "Credential Dialog Xaml Host") {
                var title = new StringBuilder(256); GetWindowTextW(h, title, 256);
                target = h; desc = "'" + title + "' (" + cls + ")";
                return false;
            }
            return true;
        }, IntPtr.Zero);
        if (target == IntPtr.Zero) return null;
        if (IsIconic(target)) ShowWindow(target, 9 /*SW_RESTORE*/);
        return SetForegroundWindow(target) ? desc : null;
    }
}
'@
        }
        $script:ForegroundHelperReady = $true
    } catch {
        $script:ForegroundHelperFailed = $true
        Write-WizardLog -Message "Vordergrund-Hilfe nicht verfügbar: $($_.Exception.Message)" -Level Info
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location),
        # 0 = kein Timeout (Standardverhalten). Bei Überschreitung wird der Prozess beendet
        # und Success=$false zurückgegeben - wichtig für Netzwerkaufrufe (z.B. certutil -ping)
        # gegen eventuell nicht erreichbare Server.
        [int]$TimeoutSeconds = 0,
        # Für häufige interne Hintergrund-Aufrufe (z.B. ein Lookup pro Zertifikat), die für
        # den Nutzer kein sinnvolles Log-Ereignis darstellen und das Log/Diagnose-Panel sonst
        # mit vielen kleinen Einträgen zumüllen würden.
        [switch]$Silent
    )

    $quotedArgs = ($ArgumentList | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $quotedArgs
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    if (-not $Silent) { Write-WizardLog -Message "$FilePath $quotedArgs" -Level Command }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    Initialize-ForegroundHelper
    Enter-WizardBusy -Text ((T '{0} läuft...') -f [System.IO.Path]::GetFileNameWithoutExtension($FilePath))
    try {
        # PIN-/Sicherheitsdialoge gehören dem Kindprozess bzw. CredentialUIBroker - die
        # Windows-Fokussperre ließ sie je nach Timing HINTER dem Wizard erscheinen. Der
        # Wizard (nach dem Klick im Vordergrund) gibt den Vordergrund frei und holt solche
        # Dialoge beim Warten aktiv nach vorn (siehe VscWizardForeground).
        if ($script:ForegroundHelperReady) { [VscWizardForeground]::AllowAny() }
        [void]$proc.Start()

        # Asynchrones Lesen startet VOR dem Warten, damit die Pipes laufend geleert werden
        # und ein volles Output-Puffer nicht zum Deadlock mit dem Kindprozess führt.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $exited = $false
        while (-not $exited) {
            $exited = $proc.WaitForExit(250)
            if ($exited) { break }
            if ($script:ForegroundHelperReady) {
                try {
                    $promoted = [VscWizardForeground]::PromoteDialogs($proc.Id)
                    if ($promoted) { Write-WizardLog -Message "Dialog in den Vordergrund geholt: $promoted" -Level Info }
                } catch { }
            }
            if ($TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        }
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            if (-not $Silent) { Write-WizardLog -Message "$FilePath $quotedArgs (Zeitüberschreitung nach $TimeoutSeconds s)" -Level Error }
            # Bis zum Kill bereits geschriebene Ausgabe separat mitgeben (StdOut bleibt
            # leer wie bisher) - z.B. für Sammel-Lookups, die abgeschlossene Teile nutzen.
            $partial = ''
            try { if ($stdoutTask.Wait(2000)) { $partial = $stdoutTask.Result } } catch { }
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'Timeout'; Success = $false; PartialStdOut = $partial }
        }
        $proc.WaitForExit()   # nach WaitForExit(ms) sicherstellen, dass die Ausgabe-Pipes fertig sind
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
    } finally { Exit-WizardBusy }

    if (-not $Silent) {
        if ($stdout.Trim()) { Write-WizardLog -Message $stdout.Trim() -Level Output }
        if ($stderr.Trim()) { Write-WizardLog -Message $stderr.Trim() -Level Error }
    }

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Success  = ($proc.ExitCode -eq 0)
    }
}

#endregion

#region Umgebungserkennung

function Test-TpmReadiness {
    # EINZIGE Quelle der TPM-Wahrheit fuer den ganzen Wizard (Startseiten-Banner UND
    # Plan-A-Status greifen hierauf zu) - damit die Erkennung NICHT nur an einer Stelle
    # korrekt ist. Ergebnis pro Sitzung gecacht (das TPM ändert sich zur Laufzeit nicht;
    # die Erkennung kostete ohne Elevation bis zu ~10 s).
    if (-not $script:TpmReadinessCache) {
        Enter-WizardBusy -Text 'Prüfe TPM...'
        try { $script:TpmReadinessCache = Get-TpmReadinessUncached } finally { Exit-WizardBusy }
    }
    return $script:TpmReadinessCache
}

function Get-TpmReadinessUncached {
    # Die eigentliche Erkennung (nur über Test-TpmReadiness aufrufen). Signale, in Reihenfolge:
    $present = $false; $ready = $false; $enabled = $false

    # 1) Get-Tpm (Modul TrustedPlatformModule). Kann auf manchen Systemen werfen oder
    #    Teilwerte liefern - u.a. auf ARM64, bei fehlendem Modul oder ohne Elevation.
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($null -ne $tpm.TpmPresent) {
            $present = [bool]$tpm.TpmPresent
            $ready   = [bool]$tpm.TpmReady
            $enabled = [bool]$tpm.TpmEnabled
        }
    } catch { }

    # 2) Fallback: WMI-Klasse Win32_Tpm im Security-Namespace. Existiert ein Objekt,
    #    ist ein TPM physisch vorhanden (Get-Tpm kann trotzdem versagt haben). Damit
    #    verschwindet die falsche "kein TPM"-Anzeige auf Systemen wie ARM64.
    #    NUR eleviert: ohne Adminrechte scheitert Win32_Tpm IMMER mit "Zugriff verweigert"
    #    - und braucht dafür ~5 s.
    if (-not $present -and (Test-IsElevated)) {
        try {
            $w = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop | Select-Object -First 1
            if ($w) {
                $enabled = [bool]$w.IsEnabled_InitialValue
                $ready   = ($enabled -and [bool]$w.IsActivated_InitialValue)
                $present = $true
            }
        } catch { }
    }

    # 2b) Ohne Elevation: das TPM als PnP-Gerät (schnell, ohne Adminrechte). Status OK =
    #     Treiber läuft; das ist das beste ohne Admin verfügbare Signal für "bereit".
    if (-not $present) {
        try {
            $dev = Get-CimInstance -ClassName Win32_PnPEntity -Filter "Name LIKE '%Trusted Platform Module%'" -ErrorAction Stop | Select-Object -First 1
            if ($dev) {
                $present = $true
                $enabled = $ready = ($dev.Status -eq 'OK')
            }
        } catch { }
    }

    # 3) Ground Truth: existiert bereits eine VSC, MUSS ein nutzbares TPM vorhanden sein
    #    (eine TPM Virtual Smart Card kann sonst gar nicht angelegt worden sein). Das
    #    ueberschreibt jede falsch-negative Erkennung aus 1)/2) - egal welcher Aufrufer.
    if (-not $present -or -not $ready) {
        try {
            if (@(Get-VirtualSmartCardReaders | Where-Object { $_.PcscName }).Count -gt 0) {
                $present = $true; $ready = $true; $enabled = $true
            }
        } catch { }
    }

    return [pscustomobject]@{ Present = [bool]$present; Ready = [bool]$ready; Enabled = [bool]$enabled }
}

function Get-DomainJoinState {
    # Gecacht wie Test-TpmReadiness: der Join-Status ändert sich zur Laufzeit nicht, und
    # dsregcmd kostet bei jedem Aufruf fast eine Sekunde.
    if (-not $script:DomainJoinStateCache) {
        Enter-WizardBusy -Text 'Prüfe Domänen-Status...'
        try { $script:DomainJoinStateCache = Get-DomainJoinStateUncached } finally { Exit-WizardBusy }
    }
    return $script:DomainJoinStateCache
}

function Get-DomainJoinStateUncached {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($cs.PartOfDomain) {
        return [pscustomobject]@{ Mode = 'ADDomain'; Domain = $cs.Domain }
    }

    $entraJoined = $false
    try {
        $dsreg = & dsregcmd /status 2>$null
        $entraJoined = [bool]($dsreg -match 'AzureAdJoined\s*:\s*YES')
    } catch { }

    if ($entraJoined) {
        return [pscustomobject]@{ Mode = 'EntraJoined'; Domain = $null }
    }
    return [pscustomobject]@{ Mode = 'Workgroup'; Domain = $null }
}

function Get-CurrentUpn {
    try {
        $upn = (& whoami /upn) 2>$null
        if ($upn -and ($upn -notmatch 'ERROR')) { return $upn.Trim() }
    } catch { }
    return $null
}

function Get-DiscoveryDomainGuess {
    # Bestes-Effort-Vorschlag für die LDAP-Ziel-Domäne der PKI-Discovery.
    # $env:USERDNSDOMAIN ist bei echten Domain-Logons gesetzt, bei Entra-joined/
    # Workgroup-Rechnern i.d.R. NICHT (kein klassischer Domain-Logon). Fallback:
    # Domänenanteil der UPN - Achtung, kann vom tatsächlichen AD-DNS-Namen
    # abweichen, wenn ein abweichender UPN-Suffix konfiguriert ist; deshalb nur
    # ein Vorschlag, manuell in den Einstellungen überschreibbar.
    if ($env:USERDNSDOMAIN) { return $env:USERDNSDOMAIN }
    $upn = Get-CurrentUpn
    if ($upn -and $upn.Contains('@')) { return $upn.Split('@')[1] }
    return ''
}

#endregion

#region PKI-Erreichbarkeit (für Entra-joined/Workgroup-Rechner mit Netzwerkpfad ins Firmennetz,
# z.B. per Cloud Kerberos Trust + VPN/Private Access - Kerberos allein ersetzt keine Netzwerksicht)

function Find-EnterpriseCAs {
    # Fragt die Enterprise-CAs direkt aus der AD-Konfigurationspartition ab
    # (CN=Enrollment Services,CN=Public Key Services,CN=Services,CN=Configuration,...),
    # genau der Mechanismus, den auch die Windows-Zertifikatsanforderung intern nutzt.
    #
    # WICHTIG: Ohne -Server versucht .NET ein "serverless" LDAP-Binding, das auf lokal
    # zwischengespeicherten Domain-Join-Informationen beruht (DsGetDcName). Ein
    # Entra-joined/Workgroup-Rechner ist NICHT domänen-gebunden und hat diese
    # Informationen i.d.R. nicht - selbst mit gültigem Kerberos-Ticket (Cloud
    # Kerberos Trust) schlägt serverless Binding dann fehl. Für diesen Fall
    # -Server auf eine DNS-Domäne oder einen konkreten DC/Servernamen setzen.
    #
    # Absichtlich ohne Write-WizardLog: wird typischerweise aus einem Start-Job heraus
    # aufgerufen, in dem kein GUI-Log-Kontext existiert.
    param(
        [string]$Server,
        [int]$TimeoutSeconds = 8
    )

    $out = [pscustomobject]@{ Cas = @(); Error = $null }
    try {
        $rootPath = if ($Server) { "LDAP://$Server/RootDSE" } else { 'LDAP://RootDSE' }
        $rootDse = New-Object System.DirectoryServices.DirectoryEntry($rootPath)
        $configNC = $rootDse.Properties['configurationNamingContext'].Value
        if (-not $configNC) {
            $out.Error = (T 'Keine Antwort von {0} (configurationNamingContext leer).') -f $rootPath
            return $out
        }

        $casDn = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configNC"
        $casPath = if ($Server) { "LDAP://$Server/$casDn" } else { "LDAP://$casDn" }
        $casEntry = New-Object System.DirectoryServices.DirectoryEntry($casPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($casEntry)
        $searcher.Filter = '(objectClass=pKIEnrollmentService)'
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $searcher.ServerTimeLimit = [TimeSpan]::FromSeconds($TimeoutSeconds)
        [void]$searcher.PropertiesToLoad.AddRange(@('cn', 'dNSHostName', 'certificateTemplates'))

        $results = $searcher.FindAll()
        # Attribute defensiv lesen: Ergebnisse ohne die erwarteten Attribute (z.B. bei
        # Bind gegen eine unerwartete Domäne) würfen bei ['cn'][0] sonst
        # "Cannot index into a null array".
        $cas = foreach ($r in $results) {
            if (-not $r.Properties['cn'] -or $r.Properties['cn'].Count -eq 0) { continue }
            if (-not $r.Properties['dNSHostName'] -or $r.Properties['dNSHostName'].Count -eq 0) { continue }
            $name = $r.Properties['cn'][0]
            $server = $r.Properties['dNSHostName'][0]
            [pscustomobject]@{
                Name         = $name
                Server       = $server
                ConfigString = "$server\$name"
                Templates    = @($r.Properties['certificateTemplates'])
            }
        }
        $out.Cas = @($cas)
        if ($out.Cas.Count -eq 0) {
            $out.Error = T 'LDAP-Verbindung erfolgreich, aber keine registrierten CAs (pKIEnrollmentService) gefunden.'
        }
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Get-OfflineTemplateCandidates {
    # Kandidaten für das Offline-/Supply-in-request-Template (Szenario 03): alle auf der
    # konfigurierten CA veröffentlichten Templates (Find-EnterpriseCAs, certificateTemplates)
    # samt Flag, ob der Antragsteller Subject/SAN selbst liefern darf
    # (msPKI-Certificate-Name-Flag Bit 0x1 = CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT) - nur solche
    # Templates übernehmen die Ziel-UPN aus dem CSR.
    # Absichtlich ohne Write-WizardLog (läuft typischerweise in einem Start-Job).
    param(
        [string]$Server,
        [string]$CAConfig,
        [int]$TimeoutSeconds = 8
    )

    $out = [pscustomobject]@{ Templates = @(); CaName = $null; Error = $null }
    $found = Find-EnterpriseCAs -Server $Server -TimeoutSeconds $TimeoutSeconds
    if ($found.Error -and $found.Cas.Count -eq 0) { $out.Error = $found.Error; return $out }

    $cas = @($found.Cas | Where-Object { $CAConfig -and ($_.ConfigString -eq $CAConfig) })
    if ($cas.Count -eq 0) { $cas = @($found.Cas) }   # konfigurierte CA nicht gefunden -> alle
    $out.CaName = ($cas | ForEach-Object { $_.Name }) -join ', '
    $published = @($cas | ForEach-Object { $_.Templates } | Where-Object { $_ } | Select-Object -Unique)
    if ($published.Count -eq 0) { $out.Error = T 'Auf der CA sind keine Templates veröffentlicht.'; return $out }

    $flags = @{}
    try {
        $rootPath = if ($Server) { "LDAP://$Server/RootDSE" } else { 'LDAP://RootDSE' }
        $configNC = (New-Object System.DirectoryServices.DirectoryEntry($rootPath)).Properties['configurationNamingContext'].Value
        $tplDn = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
        $tplPath = if ($Server) { "LDAP://$Server/$tplDn" } else { "LDAP://$tplDn" }
        $searcher = New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry($tplPath)))
        $searcher.Filter = '(objectClass=pKICertificateTemplate)'
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $searcher.ServerTimeLimit = [TimeSpan]::FromSeconds($TimeoutSeconds)
        [void]$searcher.PropertiesToLoad.AddRange(@('cn', 'displayName', 'msPKI-Certificate-Name-Flag', 'pKIExtendedKeyUsage'))
        foreach ($r in $searcher.FindAll()) {
            if (-not $r.Properties['cn'] -or $r.Properties['cn'].Count -eq 0) { continue }
            $nameFlag = if ($r.Properties['mspki-certificate-name-flag'].Count -gt 0) { [int64]$r.Properties['mspki-certificate-name-flag'][0] } else { 0 }
            $display = if ($r.Properties['displayname'].Count -gt 0) { [string]$r.Properties['displayname'][0] } else { $null }
            $flags[[string]$r.Properties['cn'][0]] = [pscustomobject]@{ NameFlag = $nameFlag; DisplayName = $display; Eku = @($r.Properties['pkiextendedkeyusage'] | ForEach-Object { [string]$_ }) }
        }
    } catch {
        $out.Error = (T 'Template-Details nicht lesbar: {0}') -f $_.Exception.Message
    }

    # EKU: Smartcard-Anmeldung (1.3.6.1.4.1.311.20.2.2) bzw. Client-Authentifizierung
    # (1.3.6.1.5.5.7.3.2). Supply-in-request allein trifft auch WebServer/SubCA/CEP -
    # die gehören nicht in diese Auswahl.
    $out.Templates = @($published | Sort-Object | ForEach-Object {
        $f = $flags[$_]
        $eku = if ($f) { @($f.Eku) } else { @() }
        [pscustomobject]@{
            Name            = $_
            DisplayName     = if ($f) { $f.DisplayName } else { $null }
            SuppliesSubject = [bool]($f -and ($f.NameFlag -band 1))
            SmartCardLogon  = ($eku -contains '1.3.6.1.4.1.311.20.2.2')
            ClientAuth      = ($eku -contains '1.3.6.1.5.5.7.3.2')
            # KDC-Authentifizierung (1.3.6.1.5.2.3.5) = DC-Template (Kerberos Authentication)
            KdcAuth         = ($eku -contains '1.3.6.1.5.2.3.5')
            FlagKnown       = [bool]$f
        }
    })
    return $out
}

function Test-CAConnectivity {
    param(
        [Parameter(Mandatory)][string]$ConfigString,
        [int]$TimeoutSeconds = 8
    )
    $result = Invoke-ExternalCommand -FilePath 'certutil.exe' -ArgumentList @('-ping', '-config', $ConfigString) -TimeoutSeconds $TimeoutSeconds
    return $result.Success
}

function Get-PkiReachability {
    # Kombiniert AD-Discovery und RPC-Erreichbarkeitstest. Gibt neben den erreichbaren
    # CAs auch Diagnoseinformationen zurück (LDAP-Fehler, per LDAP gefundene aber per
    # RPC nicht erreichbare CAs), damit ein Fehlschlag nachvollziehbar ist statt nur
    # "nichts gefunden". Gedacht zum Aufruf in einem Start-Job mit Wait-Job -Timeout,
    # da sowohl LDAP- als auch RPC-Aufrufe bei nicht erreichbaren Servern lange
    # hängen können.
    param(
        [string]$Server,
        [int]$TimeoutSeconds = 8
    )

    $discovery = Find-EnterpriseCAs -Server $Server -TimeoutSeconds $TimeoutSeconds
    $reachable = @()
    $unreachable = @()
    foreach ($ca in $discovery.Cas) {
        if (Test-CAConnectivity -ConfigString $ca.ConfigString -TimeoutSeconds $TimeoutSeconds) {
            $reachable += $ca
        } else {
            $unreachable += $ca.ConfigString
        }
    }

    [pscustomobject]@{
        AllCas         = $discovery.Cas
        ReachableCas   = @($reachable)
        UnreachableCas = @($unreachable)
        DiscoveryError = $discovery.Error
    }
}

function Test-DirectEnrollmentCapability {
    # Prüft die tatsächliche FAEHIGKEIT, von hier aus direkt bei der CA einzureichen -
    # unabhängig vom Domain-Join-Status. Genau das ist das belastbare Kriterium für
    # "Plan A (direkt)" vs. "Plan B (CA-Schritt delegieren)": ein DJ-Client kann off-net
    # scheitern, ein EJ-Client mit Cloud Kerberos Trust + korrektem DNS direkt einreichen.
    #
    # Die Kette (jeweils mit Klartext-Begründung):
    #   1. Join-Kontext (nur Info)              - dsregcmd /status
    #   2. On-Prem-Kerberos-TGT vorhanden?      - klist  (Ground Truth der On-Prem-Identität)
    #   3. CA-Ziel bestimmbar?                  - $CAConfig oder AD-Discovery
    #   4. CA-Server per DNS auflösbar?        - DNS
    #   5. certutil -ping (Transport + Auth)    - der entscheidende Test
    # Enroll-BERECHTIGUNG auf dem Template prüft ping NICHT - die zeigt sich erst beim
    # echten Submit; ein erfolgreicher Ping beweist aber die schwierige Hälfte (Auth zur CA).
    #
    # Ohne Write-WizardLog: zum Aufruf in einem Start-Job (Wait-Job -Timeout) gedacht,
    # da DNS-, RPC- und certutil-Aufrufe bei nicht erreichbaren Zielen lange hängen können.
    param(
        [string]$CAConfig,
        [string]$Server,
        [int]$TimeoutSeconds = 8
    )

    # 1) Join-Kontext + OnPremTgt-Feld (rein informativ)
    $joinMode = 'unbekannt'; $onPremTgtField = $null
    try {
        $dsreg = & dsregcmd /status 2>$null
        if     ($dsreg -match 'DomainJoined\s*:\s*YES')  { $joinMode = 'ADDomain' }
        elseif ($dsreg -match 'AzureAdJoined\s*:\s*YES') { $joinMode = 'EntraJoined' }
        else                                             { $joinMode = 'Workgroup' }
        if ($dsreg -match 'OnPremTgt\s*:\s*(YES|NO)')    { $onPremTgtField = $Matches[1] }
    } catch { }

    # 2) Kerberos-TGT vorhanden? (Server-Name 'krbtgt/REALM' ist nicht lokalisiert)
    $hasTgt = $false; $realm = $null
    try {
        $kl = (& klist 2>$null) -join "`n"
        $m = [regex]::Match($kl, 'krbtgt/([A-Za-z0-9._-]+)')
        if ($m.Success) { $hasTgt = $true; $realm = $m.Groups[1].Value }
    } catch { }

    # 3) CA-Ziel bestimmen (explizit konfiguriert oder per AD-Discovery)
    $caConfigEffective = $CAConfig
    $discoveryError = $null
    if (-not $caConfigEffective) {
        $disc = Find-EnterpriseCAs -Server $Server -TimeoutSeconds $TimeoutSeconds
        if ($disc.Cas.Count -gt 0) { $caConfigEffective = $disc.Cas[0].ConfigString }
        else { $discoveryError = $disc.Error }
    }
    $caServer = if ($caConfigEffective -and $caConfigEffective.Contains('\')) { $caConfigEffective.Split('\')[0] } else { $null }

    # 4) DNS: CA-Server auflösbar?
    $dnsOk = $false
    if ($caServer) {
        try { $null = [System.Net.Dns]::GetHostEntry($caServer); $dnsOk = $true } catch { $dnsOk = $false }
    }

    # 5) certutil -ping: Transport + Authentifizierung zur CA (entscheidend)
    $pingOk = $false
    if ($caConfigEffective) {
        $pingOk = Test-CAConnectivity -ConfigString $caConfigEffective -TimeoutSeconds $TimeoutSeconds
    }

    $direct = [bool]$pingOk

    # Klartext-Begründung: die ERSTE zutreffende Fehlerursache zählt (Kette).
    if ($direct) {
        $reason = T 'Direkte Einreichung möglich: die CA ist erreichbar und akzeptiert deine Anmeldung. Plan A empfohlen. (Ob dein Konto für das gewählte Template Enroll-Rechte hat, zeigt sich erst beim Submit.)'
    } elseif (-not $hasTgt) {
        $reason = T 'Kein On-Prem-Kerberos-Ticket (TGT) gefunden - es fehlt eine authentifizierbare AD-Identität. Auf einem Entra-joined Client setzt das funktionierendes Cloud Kerberos Trust voraus (Anmeldung per Windows Hello/passwordless, erreichbarer DC). Ohne Ticket kann die CA dich nicht autorisieren -> Plan B (CA-Schritt delegieren).'
    } elseif (-not $caConfigEffective) {
        $reason = (T 'CA-Ziel ließ sich nicht bestimmen (AD-Discovery fehlgeschlagen: {0}). Meist DNS/DC-Locator: der Client nutzt nicht den On-Prem-DNS -> SRV-Records/DC nicht auffindbar. CA-Konfigurationsstring in den Einstellungen setzen oder DNS korrigieren -> sonst Plan B.') -f $discoveryError
    } elseif (-not $dnsOk) {
        $reason = (T "CA-Server '{0}' ist per DNS nicht auflösbar - der Client nutzt vermutlich nicht den On-Prem-DNS-Server. DNS korrigieren (On-Prem-DNS / Conditional Forwarder) -> sonst Plan B.") -f $caServer
    } else {
        $reason = (T "Kerberos-Ticket und DNS sind vorhanden, aber 'certutil -ping' an {0} schlägt fehl - vermutlich RPC/DCOM (Port 135 + dynamische Ports) durch Firewall blockiert, oder die CA weist die Anmeldung ab. Details im Log -> vorerst Plan B.") -f $caConfigEffective
    }

    $yes = T 'ja'; $no = T 'nein'
    $tgtText = if ($hasTgt) { "$yes ($realm)" } else { $no }
    $onPremText = if ($onPremTgtField) { $onPremTgtField } else { 'n/a' }
    $caText = if ($caConfigEffective) { $caConfigEffective } else { T 'nicht bestimmbar' }
    $dnsText = if ($caServer) { if ($dnsOk) { $yes } else { $no } } else { 'n/a' }
    $pingText = if ($caConfigEffective) { if ($pingOk) { 'ok' } else { T 'fehlgeschlagen' } } else { T 'nicht ausgeführt' }
    $detail = (T "Join-Kontext        : {0} (dsregcmd OnPremTgt: {1})`r`nOn-Prem-TGT (klist) : {2}`r`nCA-Ziel             : {3}`r`nCA-DNS auflösbar   : {4}`r`ncertutil -ping      : {5}") -f $joinMode, $onPremText, $tgtText, $caText, $dnsText, $pingText

    return [pscustomobject]@{
        DirectPossible = $direct
        JoinMode       = $joinMode
        HasKerberosTgt = $hasTgt
        Realm          = $realm
        OnPremTgtField = $onPremTgtField
        CaConfig       = $caConfigEffective
        DnsResolves    = $dnsOk
        CaPingOk       = $pingOk
        DiscoveryError = $discoveryError
        Reason         = $reason
        Detail         = $detail
    }
}

function Get-EnvironmentCapabilities {
    # Schnelle, rein LOKALE Momentaufnahme der Umgebung fuer die Startseite - bewusst
    # OHNE langsame Netz-/CA-Pings (die misst 'Direkt-Einreichung pruefen' bzw. der
    # Szenario-3-Ablauf selbst). Dient dazu, auf der Szenario-Auswahl die Punkte
    # auszugrauen, die HIER definitiv nicht funktionieren koennen. Alles hier ist
    # sub-sekunden schnell (dsregcmd/CIM, klist, Get-Tpm, PnP, Zertifikatsspeicher).
    $join = Get-DomainJoinState
    $tpm  = Test-TpmReadiness

    # On-Prem-Kerberos-TGT? (Ground Truth einer authentifizierbaren AD-Identitaet -
    # ein Entra-joined Client MIT Cloud Kerberos Trust hat eins, ein reiner
    # Cloud-/Workgroup-Kontext nicht.)
    $hasTgt = $false; $realm = $null
    try {
        $kl = (& klist 2>$null) -join "`n"
        $m = [regex]::Match($kl, 'krbtgt/([A-Za-z0-9._-]+)')
        if ($m.Success) { $hasTgt = $true; $realm = $m.Groups[1].Value }
    } catch { }

    $vscCount = 0
    try { $vscCount = @(Get-VirtualSmartCardReaders | Where-Object { $_.PcscName }).Count } catch { }
    $eaCount = 0
    try { $eaCount = @(Get-EnrollmentAgentCertificates).Count } catch { }

    # TPM-Werte kommen direkt aus Test-TpmReadiness - dort steckt die Ground-Truth-Logik
    # (inkl. "VSC vorhanden -> TPM vorhanden"), sodass Banner und Plan-A-Status identisch
    # und korrekt sind (keine doppelte, driftende Logik mehr).
    return [pscustomobject]@{
        JoinMode     = $join.Mode
        Domain       = $join.Domain
        TpmPresent   = [bool]$tpm.Present
        TpmReady     = [bool]$tpm.Ready
        HasOnPremTgt = $hasTgt
        Realm        = $realm
        VscCount     = $vscCount
        EaCertCount  = $eaCount
    }
}

function Find-OnPremAccountByUpn {
    # Gibt es das (als Cloud-Konto gedachte) Zielkonto AUCH im lokalen AD? Dann ist es ein
    # Hybrid-Konto, und Szenario 03 (Offline-Template ohne SID) ist der falsche Weg: die
    # Smartcard-Anmeldung am lokalen DC scheitert (starke Zuordnung, KB5014754), SSO auf
    # lokale Ressourcen fehlt. Richtig: Szenario 01 (fremdes on-prem/hybrid-Konto).
    # Liefert $null, wenn das AD nicht erreichbar ist (dann KEIN Hinweis, nichts blockiert),
    # sonst ein Objekt mit Found = $true/$false.
    param([Parameter(Mandatory)][string]$Upn, [string]$Domain, [int]$TimeoutSeconds = 8)
    if (-not $Domain) {
        # Kerberos-Realm aus dem On-Prem-TGT (funktioniert auch auf Entra-joined Geräten
        # mit Cloud Kerberos Trust), sonst die Domäne des Join-Status.
        try {
            $m = [regex]::Match(((& klist 2>$null) -join "`n"), 'krbtgt/([A-Za-z0-9._-]+)')
            if ($m.Success) { $Domain = $m.Groups[1].Value }
        } catch { }
        if (-not $Domain) { try { $Domain = (Get-DomainJoinState).Domain } catch { } }
    }
    if (-not $Domain -or $Domain -eq 'WORKGROUP') { return $null }
    $escaped = $Upn -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
    Enter-WizardBusy -Text 'Prüfe, ob das Konto im lokalen AD existiert...'
    try {
        $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Domain")
        $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
        $ds.Filter = "(&(objectCategory=person)(objectClass=user)(userPrincipalName=$escaped))"
        $ds.ClientTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $ds.ServerTimeLimit = [TimeSpan]::FromSeconds($TimeoutSeconds)
        [void]$ds.PropertiesToLoad.AddRange(@('distinguishedName', 'sAMAccountName'))
        $hit = $ds.FindOne()
        if (-not $hit) {
            Write-WizardLog -Message "Konto '$Upn' im lokalen AD ($Domain) nicht gefunden - reines Cloud-Konto." -Level Info
            return [pscustomobject]@{ Found = $false; Domain = $Domain }
        }
        $dn = "$($hit.Properties['distinguishedname'])"; $sam = "$($hit.Properties['samaccountname'])"
        Write-WizardLog -Message "Konto '$Upn' existiert auch im lokalen AD: $dn (sAMAccountName $sam) - Hybrid-Konto." -Level Info
        return [pscustomobject]@{ Found = $true; Domain = $Domain; DistinguishedName = $dn; SamAccountName = $sam }
    } catch {
        Write-WizardLog -Message "Lokales AD ($Domain) nicht abfragbar: $($_.Exception.Message) - Hybrid-Prüfung übersprungen." -Level Info
        return $null
    } finally { Exit-WizardBusy }
}

#endregion

#region Virtuelle Smartcard

function Get-RecentVscEventLog {
    # tpmvscmgr's eigentliche Fehlerausgabe läuft über die interaktive Konsole und
    # kann deshalb NICHT umgeleitet/mitgeloggt werden (siehe New-VirtualSmartCard).
    # Windows protokolliert die VSC-Operationen aber zusätzlich im Event-Log - von
    # dort holen wir nach einem Versuch die relevanten Einträge, um im Fehlerfall
    # einen aussagekraeftigen Grund zeigen zu können statt nur eines Exit-Codes.
    param([Parameter(Mandatory)][datetime]$Since)

    $logNames = @(
        'Microsoft-Windows-SmartCard-TPM-VCard-Module/Operational',
        'Microsoft-Windows-SmartCard-TPM-VCard-Module/Admin'
    )
    $entries = foreach ($logName in $logNames) {
        try {
            Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $Since } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, Message
        } catch { }
    }
    return @($entries | Sort-Object TimeCreated)
}

function Get-FrameworkCscPath {
    # csc.exe des .NET Framework (v4.x) - auf jedem Windows 10/11 vorhanden.
    # Framework64 bevorzugt; das erzeugte AnyCPU-IL ist ohnehin architekturneutral.
    foreach ($frameworkDir in @('Framework64', 'Framework')) {
        $csc = Join-Path $env:WINDIR "Microsoft.NET\$frameworkDir\v4.0.30319\csc.exe"
        if (Test-Path $csc) { return $csc }
    }
    return $null
}

function Get-NativeOsArchitecture {
    # Echte Prozessorarchitektur des Geräts ('ARM64', 'AMD64', 'x86', ...).
    # NICHT über $env:PROCESSOR_ARCHITECTURE/-W6432: in einem x64-emulierten Prozess
    # auf ARM64 (z.B. die PS2EXE-Exe oder eine x64-pwsh) steht dort 'AMD64', und der
    # Wert wird sogar an native Kindprozesse vererbt. Auch
    # RuntimeInformation::OSArchitecture meldet emuliert 'X64'. Der systemweite Wert in
    # HKLM\...\Session Manager\Environment ist dagegen immer die Hardware (und mit ~0,1 s
    # deutlich schneller als Win32_Processor mit ~1 s).
    if ($script:NativeOsArchitecture) { return $script:NativeOsArchitecture }
    $arch = $null
    try {
        $arch = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE -ErrorAction Stop).PROCESSOR_ARCHITECTURE
    } catch { }
    if (-not $arch) {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    $script:NativeOsArchitecture = $arch
    return $arch
}

function Get-NativeCreateHelperPath {
    # Pfad des im Build erzeugten nativen COM-Helfers (helper\VscCreateHelper.csproj,
    # 'dotnet publish' durch build.ps1) oder $null. Gesucht wird neben dem modules-
    # Ordner (ausgelieferter EXE-Fall: dist\helper-<arch>) und im dist-Ordner des
    # Repos (Start als .ps1 aus dem Repo nach einem build.ps1-Lauf).
    param([Parameter(Mandatory)][ValidateSet('arm64')][string]$Architecture)
    $appRoot = Split-Path -Parent $PSScriptRoot
    foreach ($dir in @((Join-Path $appRoot "helper-$Architecture"), (Join-Path $appRoot "dist\helper-$Architecture"))) {
        $exe = Join-Path $dir 'VscCreateHelper.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Test-IsUserCancelledError {
    # $true, wenn ein Start-Process -Verb RunAs daran scheiterte, dass der Benutzer die
    # UAC-Abfrage abgebrochen hat (ERROR_CANCELLED 1223). Windows PowerShell 5.1
    # verpackt den Fehler in eine InvalidOperationException OHNE InnerException - dort
    # bleibt nur der (lokalisierte) Win32-Meldungstext; der wird deshalb über Windows
    # selbst ermittelt und verglichen (sprachunabhängig).
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex -is [System.ComponentModel.Win32Exception] -and $ex.NativeErrorCode -eq 1223) { return $true }
        $ex = $ex.InnerException
    }
    $cancelText = (New-Object System.ComponentModel.Win32Exception 1223).Message
    return [bool]($cancelText -and $ErrorRecord.Exception.Message -and $ErrorRecord.Exception.Message.Contains($cancelText))
}

function New-VscCancelledResult {
    # Einheitliches Ergebnis "vom Benutzer abgebrochen" für alle Wege der VSC-Erstellung
    # (die GUI zeigt das neutral statt als Fehler an).
    param([Parameter(Mandatory)][string]$Reason)
    Write-WizardLog -Message "VSC-Erstellung vom Benutzer abgebrochen ($Reason) - keine Karte erstellt." -Level Info
    return [pscustomobject]@{ Success = $false; Cancelled = $true; InstanceId = $null; HResult = $null; Message = (T 'Vom Benutzer abgebrochen.'); PcscName = $null }
}

function New-VirtualSmartCard {
    # Erstellt eine virtuelle Smartcard über die COM-API (ITpmVirtualSmartCardManager)
    # statt über tpmvscmgr.exe. Vorteil: die PIN wird in einem echten, maskierten
    # GUI-Dialog abgefragt und der API direkt übergeben - kein rohes Konsolenfenster,
    # keine ins Leere laufende PIN-Abfrage, und ein echter HRESULT als Fehlersignal.
    #
    # Die COM-Aufrufe erfordern lokale Administratorrechte UND muessen in kompiliertem
    # C# erfolgen (PowerShell kann diese reinen IUnknown-Interfaces nicht aufrufen).
    # Der Helfer (VscWizard.CreateHelper.cs) wird dafür zur Laufzeit mit dem csc.exe
    # des .NET Framework zu einer /target:winexe-Anwendung kompiliert und eleviert
    # gestartet: eine Fenster-Exe hat KEIN Konsolenfenster - es erscheint
    # ausschließlich der PIN-Dialog (die PIN verlaesst den elevierten Prozess nie).
    # Auf ARM64 ersetzt ein im Build erzeugter NATIVER Helfer (derselbe Quelltext als
    # .NET-win-arm64-App) das csc-Kompilat - .NET Framework läuft dort nur emuliert.
    #
    # Exe und Ergebnisdatei liegen in C:\Users\Public: bei einer Über-die-Schulter-
    # Elevation (der angemeldete Benutzer ist kein Admin, es wird ein separates
    # Admin-Konto verwendet) kann dieses Admin-Konto das Benutzerprofil des
    # angemeldeten Benutzers (z.B. OneDrive-Ordner) nicht zwangsläufig lesen -
    # C:\Users\Public ist für beide Konten zugänglich.
    param(
        [Parameter(Mandatory)][string]$CardName,
        # Wird über ITpmVirtualSmartCardManager2::CreateVirtualSmartCardWithPinPolicy
        # durchgesetzt (siehe CreateHelper); ohne diese Schnittstelle faellt der Helfer
        # auf die Basis-API mit Minimum 8 zurück und passt den PIN-Dialog entsprechend an.
        [int]$PinPolicyMinLength = 6,
        # Optional: PIN NICHT interaktiv abfragen, sondern diese verwenden (Silent-/
        # Provisionierungsweg, z.B. Intune-SYSTEM mit Start-PIN aus dem Computernamen).
        # Die PIN wird dem Helfer über eine kurzlebige Datei übergeben (NIE über die
        # Kommandozeile) und beidseitig sofort gelöscht. Nur mit dem COM-Helfer möglich -
        # der tpmvscmgr-Fallback kann keine PIN entgegennehmen.
        [string]$Pin = ''
    )

    $supplyPin = -not [string]::IsNullOrEmpty($Pin)
    Clear-SmartCardInfoCache   # Kartenbestand ändert sich (PC/SC-Nummern werden wiederverwendet)
    $publicDir = Join-Path $env:SystemDrive 'Users\Public'
    $token = [guid]::NewGuid().ToString('N')
    $helperExe = Join-Path $publicDir "vscwizard-createhelper-$token.exe"
    $resultPath = Join-Path $publicDir "vscwizard-createresult-$token.txt"
    $pinFile = Join-Path $publicDir "vscwizard-pin-$token.txt"

    # ARM64: .NET Framework hat KEINE native ARM64-Laufzeit - ein AnyCPU-FW-Exe
    # laeuft dort emuliert, und der ARM64-Proxy/Stub des TPM-VSC-COM-Servers laesst
    # sich in einen solchen Prozess nicht laden (QueryInterface 0x800700C1). Auf ARM64
    # daher den im Build erzeugten NATIVEN Helfer verwenden (derselbe Quelltext, als
    # self-contained .NET-win-arm64-App, siehe helper\VscCreateHelper.csproj). Fehlt
    # er (z.B. Build ohne .NET SDK), direkt tpmvscmgr.exe (PIN in der Konsole).
    if ((Get-NativeOsArchitecture) -eq 'ARM64') {
        $nativeHelper = Get-NativeCreateHelperPath -Architecture 'arm64'
        if (-not $nativeHelper) {
            if ($supplyPin) {
                $msg = 'ARM64 ohne nativen COM-Helfer: die stille Bereitstellung mit gelieferter PIN ist nur mit dem COM-Helfer möglich (tpmvscmgr kann keine PIN entgegennehmen). Bitte den nativen Helfer bauen (build.ps1 mit .NET SDK).'
                Write-WizardLog -Message $msg -Level Error
                return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
            }
            Write-WizardLog -Message 'ARM64 erkannt, nativer COM-Helfer (helper-arm64\VscCreateHelper.exe) nicht vorhanden - verwende tpmvscmgr.exe.' -Level Info
            return New-VirtualSmartCardViaTpmVscMgr -CardName $CardName -PinPolicyMinLength $PinPolicyMinLength
        }
        # Kopie nach C:\Users\Public: gleicher Grund wie beim csc-Kompilat (Über-die-
        # Schulter-Elevation kann das Benutzerprofil nicht zwangsläufig lesen).
        try {
            Copy-Item -Path $nativeHelper -Destination $helperExe -Force -ErrorAction Stop
        } catch {
            Write-WizardLog -Message "Nativer COM-Helfer konnte nicht bereitgestellt werden ($($_.Exception.Message)) - verwende tpmvscmgr.exe." -Level Error
            return New-VirtualSmartCardViaTpmVscMgr -CardName $CardName -PinPolicyMinLength $PinPolicyMinLength
        }
        Write-WizardLog -Message "ARM64 erkannt: verwende nativen COM-Helfer ($nativeHelper)." -Level Info
    } else {
        $helperSource = Join-Path $PSScriptRoot 'VscWizard.CreateHelper.cs'
        if (-not (Test-Path $helperSource)) {
            $msg = (T 'Helfer-Quelldatei nicht gefunden: {0}') -f $helperSource
            Write-WizardLog -Message $msg -Level Error
            return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
        }

        $csc = Get-FrameworkCscPath
        if (-not $csc) {
            $msg = T 'csc.exe des .NET Framework nicht gefunden (Microsoft.NET\Framework*\v4.0.30319).'
            Write-WizardLog -Message $msg -Level Error
            return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
        }

        $compile = Invoke-ExternalCommand -FilePath $csc -ArgumentList @(
            '/nologo', '/target:winexe', "/out:$helperExe",
            '/r:System.dll', '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll',
            $helperSource) -TimeoutSeconds 120 -Silent
        if (-not $compile.Success -or -not (Test-Path $helperExe)) {
            $detail = "$($compile.StdOut) $($compile.StdErr)".Trim()
            $msg = (T 'Helfer konnte nicht kompiliert werden: {0}') -f $detail
            Write-WizardLog -Message $msg -Level Error
            return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
        }
    }

    # Argumente als fertig quotierter String (Start-Process quotiert Array-Elemente
    # in Windows PowerShell 5.1 NICHT selbst - Kartennamen mit Leerzeichen würden
    # sonst zerfallen). Optionaler 4. Parameter = PIN-Datei (Supplied-PIN-Modus).
    $exeArgs = "`"$CardName`" $PinPolicyMinLength `"$resultPath`""
    if ($supplyPin) {
        # PIN in eine kurzlebige Datei schreiben (NICHT auf die Kommandozeile). ASCII,
        # ohne Zeilenende. Der Helfer liest sie und löscht sie sofort; wir löschen unten
        # zusätzlich. Die Start-PIN wird ohnehin aus dem Computernamen abgeleitet und
        # direkt danach vom Benutzer zwingend geändert.
        Set-Content -Path $pinFile -Value $Pin -Encoding Ascii -NoNewline -ErrorAction SilentlyContinue
        $exeArgs += " `"$pinFile`""
    }

    $createLog = if ($supplyPin) {
        "Erstelle virtuelle Smartcard '$CardName' über die COM-API (elevierter Helfer, PIN geliefert - kein Dialog)."
    } else {
        "Erstelle virtuelle Smartcard '$CardName' über die COM-API (elevierter Helfer ohne Konsolenfenster, PIN-Dialog dort)."
    }
    Write-WizardLog -Message $createLog -Level Command

    try {
        if (Test-IsElevated) {
            Start-Process -FilePath $helperExe -ArgumentList $exeArgs -Wait -ErrorAction Stop
        } else {
            # -Verb RunAs fordert die Elevation an (UAC); der Helfer läuft dann als
            # Admin und zeigt seinen eigenen PIN-Dialog.
            Start-Process -FilePath $helperExe -ArgumentList $exeArgs -Verb RunAs -Wait -ErrorAction Stop
        }
    } catch {
        Remove-Item $helperExe -ErrorAction SilentlyContinue
        if (Test-IsUserCancelledError -ErrorRecord $_) { return New-VscCancelledResult -Reason 'UAC-Abfrage abgebrochen' }
        $msg = (T 'Erhöhter Prozess konnte nicht gestartet werden: {0}') -f $_.Exception.Message
        Write-WizardLog -Message $msg -Level Error
        return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
    }

    # Ergebnis auslesen (key=value je Zeile).
    $res = @{ Success = 'False'; HResult = ''; InstanceId = ''; Message = '' }
    if (Test-Path $resultPath) {
        foreach ($line in (Get-Content -Path $resultPath -ErrorAction SilentlyContinue)) {
            $idx = $line.IndexOf('=')
            if ($idx -gt 0) { $res[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
        }
    } else {
        $res.Message = T 'Kein Ergebnis vom elevierten Helfer erhalten (Prozess evtl. abgebrochen).'
    }
    Remove-Item $helperExe, $resultPath, $pinFile -ErrorAction SilentlyContinue

    # Abbruch im PIN-Dialog ist KEIN Fehler: kein Fallback auf tpmvscmgr (sonst
    # folgte sofort eine zweite PIN-Abfrage in der Konsole).
    if ($res['Cancelled'] -eq 'True') { return New-VscCancelledResult -Reason 'PIN-Dialog abgebrochen' }

    $success = ($res.Success -eq 'True')
    $pcscName = $null
    if ($success) {
        # PC/SC-Namen der frisch erstellten Karte aufloesen ("Microsoft Virtual Smart
        # Card N"): unter DIESEM Namen erscheint die Karte in Windows-Kartenauswahl-
        # Dialogen (z.B. bei certreq -new) - der vergebene FriendlyName taucht dort
        # NICHT auf, und die PC/SC-Nummer stimmt nicht mit der Nummer in der
        # PnP-InstanceId überein. Kurz wiederholen, da die PnP-Registrierung nach
        # der Erstellung einen Moment brauchen kann.
        for ($attempt = 0; $attempt -lt 5 -and -not $pcscName; $attempt++) {
            if ($attempt -gt 0) { Start-Sleep -Milliseconds 800 }
            $reader = @(Get-VirtualSmartCardReaders) | Where-Object { $_.InstanceId -eq $res.InstanceId } | Select-Object -First 1
            if ($reader -and $reader.PcscName) { $pcscName = $reader.PcscName }
        }
        $policyNote = if ($res['PinPolicyUsed'] -eq 'True') { "PIN-Policy via Manager2, Mindestlänge $PinPolicyMinLength" } else { 'Basis-API, PIN-Mindestlänge 8' }
        $pcscNote = if ($pcscName) { "; erscheint in Windows-Kartendialogen als '$pcscName'" } else { '' }
        Write-WizardLog -Message "Virtuelle Smartcard '$CardName' erstellt (InstanceId $($res.InstanceId); $policyNote$pcscNote)." -Level Success
    } else {
        # COM-Weg fehlgeschlagen (z.B. 0x800700C1 bei Architektur-Mismatch).
        if ($supplyPin) {
            # Kein tpmvscmgr-Fallback im Supplied-PIN-Modus (tpmvscmgr kann keine PIN
            # entgegennehmen und würde interaktiv nachfragen).
            Write-WizardLog -Message "COM-Erstellung mit gelieferter PIN fehlgeschlagen: $($res.Message) $(if ($res.HResult) { "(HRESULT $($res.HResult))" })." -Level Error
            return [pscustomobject]@{ Success = $false; InstanceId = $null; HResult = $res.HResult; Message = $res.Message }
        }
        # Interaktiv: auf den nativen tpmvscmgr.exe zurueckfallen, der arch-unabhaengig laeuft.
        Write-WizardLog -Message "COM-Erstellung fehlgeschlagen: $($res.Message) $(if ($res.HResult) { "(HRESULT $($res.HResult))" }) - Fallback über tpmvscmgr.exe." -Level Error
        return New-VirtualSmartCardViaTpmVscMgr -CardName $CardName -PinPolicyMinLength $PinPolicyMinLength
    }
    return [pscustomobject]@{
        Success    = $success
        InstanceId = $res.InstanceId
        HResult    = $res.HResult
        Message    = $res.Message
        PcscName   = $pcscName
    }
}

function New-VirtualSmartCardViaTpmVscMgr {
    # Nativer Fallback/Primaerweg (ARM64): erstellt die VSC mit dem eingebauten
    # tpmvscmgr.exe. Die PIN wird im elevierten KONSOLENFENSTER abgefragt (/PIN PROMPT,
    # daher sichtbares Fenster, kein -WindowStyle Hidden). Erfolg wird danach anhand
    # eines neu hinzugekommenen Smartcard-Readers mit diesem FriendlyName erkannt, da
    # -Verb RunAs keine Ausgabeumleitung erlaubt.
    param(
        [Parameter(Mandatory)][string]$CardName,
        # Wird als /PINPOLICY minlen an tpmvscmgr durchgereicht.
        [int]$PinPolicyMinLength = 6
    )

    Clear-SmartCardInfoCache

    $tpmvscmgr = Join-Path $env:WINDIR 'System32\tpmvscmgr.exe'
    if (-not (Test-Path $tpmvscmgr)) {
        $msg = T 'tpmvscmgr.exe nicht gefunden (System32).'
        Write-WizardLog -Message $msg -Level Error
        return [pscustomobject]@{ Success = $false; InstanceId = $null; HResult = $null; Message = $msg; PcscName = $null }
    }

    Write-WizardLog -Message "Erstelle virtuelle Smartcard '$CardName' über tpmvscmgr.exe (PIN-Eingabe im elevierten Konsolenfenster; PIN-Mindestlänge $PinPolicyMinLength)." -Level Command

    # Vorher vorhandene Reader merken, um die neue Karte danach sicher zu identifizieren.
    $before = @(Get-VirtualSmartCardReaders | ForEach-Object { $_.InstanceId })

    # /AdminKey DEFAULT + /PIN PROMPT + /generate: der dokumentierte Weg fuer eine
    # enrollment-faehige Karte. /PINPOLICY minlen setzt die PIN-Mindestlänge. /PIN PROMPT
    # erfordert ein interaktives Fenster - daher Start-Process (nicht Invoke-ExternalCommand
    # mit Umleitung).
    $vscArgs = "create /name `"$CardName`" /AdminKey DEFAULT /PIN PROMPT /PINPOLICY minlen $PinPolicyMinLength /generate"
    try {
        if (Test-IsElevated) {
            Start-Process -FilePath $tpmvscmgr -ArgumentList $vscArgs -Wait -ErrorAction Stop
        } else {
            Start-Process -FilePath $tpmvscmgr -ArgumentList $vscArgs -Verb RunAs -Wait -ErrorAction Stop
        }
    } catch {
        if (Test-IsUserCancelledError -ErrorRecord $_) { return New-VscCancelledResult -Reason 'UAC-Abfrage abgebrochen' }
        $msg = (T 'tpmvscmgr.exe konnte nicht gestartet werden: {0}') -f $_.Exception.Message
        Write-WizardLog -Message $msg -Level Error
        return [pscustomobject]@{ Success = $false; InstanceId = $null; HResult = $null; Message = $msg; PcscName = $null }
    }

    # Neue Karte finden: bevorzugt ein neu hinzugekommener Reader mit diesem Namen.
    $newReader = $null
    for ($attempt = 0; $attempt -lt 6 -and -not $newReader; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Milliseconds 800 }
        $readers = @(Get-VirtualSmartCardReaders)
        $newReader = $readers | Where-Object { $_.FriendlyName -eq $CardName -and $_.InstanceId -notin $before } | Select-Object -First 1
        if (-not $newReader) { $newReader = $readers | Where-Object { $_.FriendlyName -eq $CardName } | Select-Object -First 1 }
    }

    if ($newReader) {
        $pcscNote = if ($newReader.PcscName) { "; erscheint in Windows-Kartendialogen als '$($newReader.PcscName)'" } else { '' }
        Write-WizardLog -Message "Virtuelle Smartcard '$CardName' über tpmvscmgr erstellt (InstanceId $($newReader.InstanceId)$pcscNote)." -Level Success
        return [pscustomobject]@{ Success = $true; InstanceId = $newReader.InstanceId; HResult = $null; Message = ''; PcscName = $newReader.PcscName }
    }

    $msg = (T "Nach dem tpmvscmgr-Lauf wurde keine Karte '{0}' gefunden (Abbruch, abweichende/zu kurze PIN oder Erstellung fehlgeschlagen).") -f $CardName
    Write-WizardLog -Message $msg -Level Error
    return [pscustomobject]@{ Success = $false; InstanceId = $null; HResult = $null; Message = $msg; PcscName = $null }
}

function Get-VirtualSmartCardReaders {
    # tpmvscmgr kennt keinen "list"-Befehl - virtuelle Smartcards werden deshalb
    # über die PnP-Geräteklasse für Smartcard-Lesegeräte erkannt, unter der sich
    # auch TPM Virtual Smart Cards (mit dem bei der Erstellung vergebenen Namen als
    # FriendlyName) einordnen.
    #
    # PcscName: der PC/SC-Lesegerätename ("Microsoft Virtual Smart Card N"), unter dem
    # ein Zertifikat seinen Schlüssel meldet (CNG-Property "SmartCardReader", siehe
    # Get-SmartCardCngProviderInfo). Der PnP-FriendlyName (der bei der Erstellung
    # vergebene VSC-Name, z.B. "VSC-T0") und dieser PC/SC-Name teilen keinen gemeinsamen
    # Text - die Verknuepfung steht aber deterministisch in der PnP-Child-/BusRelations-
    # Eigenschaft des Lesegeräts als Token "Microsoft_Virtual_Smart_Card_N" (die
    # SCFILTER-Kindknoten-Kennung). Darüber laesst sich jedes Zertifikat exakt seinem
    # Lesegerät zuordnen, statt es in den Sammel-Eintrag "nicht zuordenbar" zu werfen.
    #
    # Performance: EINE WMI-Abfrage (Win32_PnPEntity liefert nur vorhandene Geräte) für
    # Lesegeräte UND Karten-Kindknoten, Zuordnung über den ParentIdPrefix des Lesegeräts
    # aus der Registry (Kind-Instanz = "<ParentIdPrefix>&MICROSOFT_VIRTUAL_SMART_CARD_N_...").
    # Früher: Get-PnpDeviceProperty einzeln je Lesegerät (~0,65 s pro Gerät, bei 6
    # Lesegeräten ~5 s - und das bei jedem Aufruf).
    Enter-WizardBusy -Text 'Lese Smartcard-Lesegeräte...'
    try {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='SmartCardReader' OR PNPClass='SmartCard'" -ErrorAction Stop)
        $cardIds = @($devices | Where-Object { $_.PNPClass -eq 'SmartCard' } | ForEach-Object { [string]$_.DeviceID })
        return @($devices | Where-Object { $_.PNPClass -eq 'SmartCardReader' } | ForEach-Object {
            $pcscName = $null
            try {
                # -LiteralPath: Geräte-IDs können [ ] enthalten (sonst als Wildcard gedeutet).
                $prefix = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.DeviceID)" -Name ParentIdPrefix -ErrorAction Stop).ParentIdPrefix
                if ($prefix) {
                    foreach ($cardId in $cardIds) {
                        if ($cardId -match ('\\' + [regex]::Escape($prefix) + '&MICROSOFT_VIRTUAL_SMART_CARD_(\d+)')) {
                            $pcscName = "Microsoft Virtual Smart Card $($Matches[1])"
                            break
                        }
                    }
                }
            } catch { }
            [pscustomobject]@{
                FriendlyName = $_.Name
                InstanceId   = [string]$_.DeviceID
                Status       = $_.Status
                PcscName     = $pcscName
            }
        })
    } catch {
        return @()
    } finally { Exit-WizardBusy }
}

$script:VscPinSource = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// PIN einer (virtuellen) Smartcard über ihren Kartentreiber (Minitreiber, z.B. msclmd.dll)
// ändern: CardAcquireContext + CardChangeAuthenticator - derselbe Weg, den Windows'
// Sicherheitsbildschirm (Strg+Alt+Entf > Kennwort ändern) über den Base-CSP nimmt.
// Der WinRT-Weg (SmartCardProvisioning.RequestPinChangeAsync) ist nur für UWP-Apps frei.
// CARD_DATA-Layout (cardmod.h, Version 7, 64 Bit) am Gerät verifiziert: reservierte Felder
// leer, alle Treiberfunktionen im Modul, CardReadFile("cardid") = WinRT-Karten-ID.
// Schutz: jeder Funktionszeiger wird vor dem Aufruf auf "liegt im Treiber" geprüft; die
// Struktur ist großzügig überdimensioniert (4 KB).
public static class VscWizardPin {
    [DllImport("winscard.dll")] static extern int SCardEstablishContext(uint scope, IntPtr r1, IntPtr r2, out IntPtr ctx);
    [DllImport("winscard.dll", CharSet = CharSet.Unicode)] static extern int SCardConnectW(IntPtr ctx, string reader, uint share, uint proto, out IntPtr card, out uint active);
    [DllImport("winscard.dll", CharSet = CharSet.Unicode)] static extern int SCardStatusW(IntPtr card, StringBuilder names, ref uint len, out uint state, out uint proto, byte[] atr, ref uint atrLen);
    [DllImport("winscard.dll", CharSet = CharSet.Unicode)] static extern int SCardListCardsW(IntPtr ctx, byte[] atr, IntPtr guids, uint cguids, char[] cards, ref uint len);
    [DllImport("winscard.dll", CharSet = CharSet.Unicode)] static extern int SCardGetCardTypeProviderNameW(IntPtr ctx, string card, uint provId, StringBuilder prov, ref uint len);
    [DllImport("winscard.dll")] static extern int SCardDisconnect(IntPtr card, uint disp);
    [DllImport("winscard.dll")] static extern int SCardReleaseContext(IntPtr ctx);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr mod, string name);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate IntPtr AllocFn(UIntPtr size);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate IntPtr ReAllocFn(IntPtr p, UIntPtr size);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate void FreeFn(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate uint CacheAddFn(IntPtr ctx, IntPtr name, uint flags, IntPtr data, UIntPtr cb);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate uint CacheLookupFn(IntPtr ctx, IntPtr name, uint flags, IntPtr ppData, IntPtr pcb);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] public delegate uint CacheDeleteFn(IntPtr ctx, IntPtr name, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate uint AcquireFn(IntPtr cardData, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate uint DeleteCtxFn(IntPtr cardData);
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)] delegate uint AuthPinFn(IntPtr cardData, string userId, byte[] pin, uint cbPin, out uint attempts);
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)] delegate uint ChangeAuthFn(IntPtr cardData, string userId, byte[] cur, uint cbCur, byte[] neu, uint cbNew, uint retryCount, uint flags, out uint attempts);

    // Statisch gehalten, damit der GC die an den Treiber übergebenen Rückrufe nicht einsammelt.
    static AllocFn sAlloc = s => Marshal.AllocHGlobal((IntPtr)(long)s.ToUInt64());
    static ReAllocFn sReAlloc = (p, s) => Marshal.ReAllocHGlobal(p, (IntPtr)(long)s.ToUInt64());
    static FreeFn sFree = p => { if (p != IntPtr.Zero) Marshal.FreeHGlobal(p); };
    static CacheAddFn sAdd = (c, n, f, d, cb) => 0;
    static CacheLookupFn sLookup = (c, n, f, pp, pcb) => 0x80100024; // SCARD_E_FILE_NOT_FOUND -> Treiber liest von der Karte
    static CacheDeleteFn sDelete = (c, n, f) => 0;

    public const uint E_SETUP = 0xE0000001;      // eigener Code: Vorbereitung/Treiber unerwartet

    // Rückgabe 0 = geändert (und mit neuer PIN gegengeprüft); sonst SCARD-Code bzw. E_SETUP.
    public static uint Change(string reader, byte[] cur, byte[] neu, out uint attempts, out string detail) {
        attempts = 0xFFFFFFFF; detail = "";
        if (IntPtr.Size != 8) { detail = "nur 64-Bit"; return E_SETUP; }
        IntPtr ctx = IntPtr.Zero, card = IntPtr.Zero, cd = IntPtr.Zero, nameW = IntPtr.Zero, atrMem = IntPtr.Zero;
        try {
            uint active;
            int rc = SCardEstablishContext(0, IntPtr.Zero, IntPtr.Zero, out ctx);
            if (rc != 0) { detail = "SCardEstablishContext"; return (uint)rc; }
            rc = SCardConnectW(ctx, reader, 2 /*SHARED*/, 3 /*T0|T1*/, out card, out active);
            if (rc != 0) { detail = "SCardConnect"; return (uint)rc; }
            uint nl = 512, st, pr, al = 36; var names = new StringBuilder(512); var atr = new byte[36];
            rc = SCardStatusW(card, names, ref nl, out st, out pr, atr, ref al);
            if (rc != 0) { detail = "SCardStatus"; return (uint)rc; }
            Array.Resize(ref atr, (int)al);
            uint cl = 1024; var cards = new char[1024];
            rc = SCardListCardsW(ctx, atr, IntPtr.Zero, 0, cards, ref cl);
            if (rc != 0) { detail = "SCardListCards"; return (uint)rc; }
            string cardName = new string(cards, 0, (int)cl).Split('\0')[0];
            uint pl = 512; var prov = new StringBuilder(512);
            rc = SCardGetCardTypeProviderNameW(ctx, cardName, 0x80000001 /*CARD_MODULE*/, prov, ref pl);
            if (rc != 0) { detail = "SCardGetCardTypeProviderName"; return (uint)rc; }
            IntPtr mod = LoadLibraryW(prov.ToString());
            if (mod == IntPtr.Zero) { detail = "LoadLibrary " + prov; return E_SETUP; }
            long modBase = mod.ToInt64(), modEnd = modBase;
            foreach (ProcessModule pm in Process.GetCurrentProcess().Modules)
                if (pm.BaseAddress == mod) modEnd = modBase + pm.ModuleMemorySize;
            Func<IntPtr, bool> inModule = p => p.ToInt64() >= modBase && p.ToInt64() < modEnd;
            IntPtr acq = GetProcAddress(mod, "CardAcquireContext");
            if (!inModule(acq)) { detail = "CardAcquireContext fehlt in " + prov; return E_SETUP; }

            cd = Marshal.AllocHGlobal(4096);
            for (int i = 0; i < 4096; i += 8) Marshal.WriteInt64(cd, i, 0);
            nameW = Marshal.StringToHGlobalUni(cardName);
            atrMem = Marshal.AllocHGlobal(atr.Length); Marshal.Copy(atr, 0, atrMem, atr.Length);
            Marshal.WriteInt32(cd, 0, 7);                 // dwVersion
            Marshal.WriteIntPtr(cd, 8, atrMem);           // pbAtr
            Marshal.WriteInt32(cd, 16, atr.Length);       // cbAtr
            Marshal.WriteIntPtr(cd, 24, nameW);           // pwszCardName
            Marshal.WriteIntPtr(cd, 32, Marshal.GetFunctionPointerForDelegate(sAlloc));
            Marshal.WriteIntPtr(cd, 40, Marshal.GetFunctionPointerForDelegate(sReAlloc));
            Marshal.WriteIntPtr(cd, 48, Marshal.GetFunctionPointerForDelegate(sFree));
            Marshal.WriteIntPtr(cd, 56, Marshal.GetFunctionPointerForDelegate(sAdd));
            Marshal.WriteIntPtr(cd, 64, Marshal.GetFunctionPointerForDelegate(sLookup));
            Marshal.WriteIntPtr(cd, 72, Marshal.GetFunctionPointerForDelegate(sDelete));
            Marshal.WriteIntPtr(cd, 96, ctx);             // hSCardCtx
            Marshal.WriteIntPtr(cd, 104, card);           // hScard
            uint r = ((AcquireFn)Marshal.GetDelegateForFunctionPointer(acq, typeof(AcquireFn)))(cd, 0);
            if (r != 0) { detail = "CardAcquireContext"; return r; }
            IntPtr pDel = Marshal.ReadIntPtr(cd, 120), pAuth = Marshal.ReadIntPtr(cd, 160), pChange = Marshal.ReadIntPtr(cd, 192);
            try {
                if (!inModule(pAuth) || !inModule(pChange)) { detail = "Treiberfunktionen nicht wie erwartet"; return E_SETUP; }
                r = ((ChangeAuthFn)Marshal.GetDelegateForFunctionPointer(pChange, typeof(ChangeAuthFn)))(
                    cd, "user", cur, (uint)cur.Length, neu, (uint)neu.Length, 0, 2 /*CARD_AUTHENTICATE_PIN_PIN*/, out attempts);
                if (r != 0) { detail = "CardChangeAuthenticator"; return r; }
                uint a2;
                r = ((AuthPinFn)Marshal.GetDelegateForFunctionPointer(pAuth, typeof(AuthPinFn)))(cd, "user", neu, (uint)neu.Length, out a2);
                if (r != 0) { detail = "Gegenprüfung mit neuer PIN"; return r; }
                return 0;
            } finally {
                if (inModule(pDel)) ((DeleteCtxFn)Marshal.GetDelegateForFunctionPointer(pDel, typeof(DeleteCtxFn)))(cd);
            }
        } finally {
            Array.Clear(cur, 0, cur.Length); Array.Clear(neu, 0, neu.Length);
            if (card != IntPtr.Zero) SCardDisconnect(card, 1 /*RESET: Anmeldung verwerfen*/);
            if (ctx != IntPtr.Zero) SCardReleaseContext(ctx);
            if (cd != IntPtr.Zero) Marshal.FreeHGlobal(cd);
            if (nameW != IntPtr.Zero) Marshal.FreeHGlobal(nameW);
            if (atrMem != IntPtr.Zero) Marshal.FreeHGlobal(atrMem);
        }
    }
}
'@

function Set-VscPin {
    # PIN einer virtuellen Smartcard ändern (Kartentreiber-Weg, siehe $script:VscPinSource).
    # Die PINs kommen als Byte-Arrays (ASCII) und werden nach dem Aufruf gelöscht; sie
    # erscheinen nie im Log. Ergebnis.Status: Changed | WrongPin | Blocked | InvalidNewPin | Error.
    param(
        [Parameter(Mandatory)][string]$PcscName,
        [Parameter(Mandatory)][byte[]]$CurrentPin,
        [Parameter(Mandatory)][byte[]]$NewPin
    )
    if (-not ('VscWizardPin' -as [type])) { Add-Type -TypeDefinition $script:VscPinSource }
    $attempts = [uint32]0; $detail = ''
    Write-WizardLog -Message "PIN ändern: '$PcscName' (Kartentreiber)." -Level Command
    try {
        $rc = [VscWizardPin]::Change($PcscName, $CurrentPin, $NewPin, [ref]$attempts, [ref]$detail)
    } catch {
        Write-WizardLog -Message "PIN ändern: Ausnahme $($_.Exception.Message)" -Level Error
        return [pscustomobject]@{ Status = 'Error'; Attempts = $null; Code = $null; Message = $_.Exception.Message }
    } finally {
        [Array]::Clear($CurrentPin, 0, $CurrentPin.Length); [Array]::Clear($NewPin, 0, $NewPin.Length)
    }
    $code = '0x{0:X8}' -f $rc
    # Über den Code-Text: PowerShell 5.1 liest 0x8010006B als NEGATIVES Int32 - ein
    # Zahlenvergleich mit dem uint-Rückgabewert griffe nie.
    $status = switch ($code) {
        '0x00000000' { 'Changed' }
        '0x8010006B' { 'WrongPin' }        # SCARD_W_WRONG_CHV
        '0x8010006C' { 'Blocked' }         # SCARD_W_CHV_BLOCKED
        '0x8010002A' { 'InvalidNewPin' }   # SCARD_E_INVALID_CHV (z.B. Richtlinie/Länge)
        default      { 'Error' }
    }
    $left = if ($status -eq 'WrongPin' -and $attempts -ne [uint32]::MaxValue) { [int]$attempts } else { $null }
    switch ($status) {
        'Changed' { Write-WizardLog -Message "PIN von '$PcscName' geändert und mit der neuen PIN gegengeprüft." -Level Success }
        'WrongPin' { Write-WizardLog -Message "PIN ändern: aktuelle PIN falsch ($code), verbleibende Versuche: $left." -Level Error }
        default { Write-WizardLog -Message "PIN ändern: $status ($code) bei '$detail'." -Level Error }
    }
    return [pscustomobject]@{ Status = $status; Attempts = $left; Code = $code; Message = "$detail $code".Trim() }
}

function Remove-VirtualSmartCard {
    # tpmvscmgr destroy /instance <InstanceId> - die InstanceId ist dieselbe
    # PnP-Gerätepfad-Kennung, die auch Get-VirtualSmartCardReaders liefert
    # (z.B. "ROOT\SMARTCARDREADER\0000"). Unwiderruflich: alle auf der Karte
    # gespeicherten Schlüssel gehen dabei verloren - Bestätigung ist Aufgabe der GUI.
    param([Parameter(Mandatory)][string]$InstanceId)

    Clear-SmartCardInfoCache
    $tpmvscmgr = Join-Path $env:WINDIR 'System32\tpmvscmgr.exe'
    $vscArgs = @('destroy', '/instance', $InstanceId)

    if (Test-IsElevated) {
        $result = Invoke-ExternalCommand -FilePath $tpmvscmgr -ArgumentList $vscArgs
        return [pscustomobject]@{ ExitCode = $result.ExitCode; Success = $result.Success }
    }

    # -WindowStyle Hidden: tpmvscmgr destroy braucht keine Interaktion - ShellExecute
    # startet die Konsole mit SW_HIDE, es blitzt also nicht einmal ein Fenster auf.
    Write-WizardLog -Message "Starte erhöhten Prozess (verstecktes Fenster): $tpmvscmgr $($vscArgs -join ' ')" -Level Command
    Enter-WizardBusy -Text 'Lösche virtuelle Smartcard...'
    try {
        $proc = Start-Process -FilePath $tpmvscmgr -ArgumentList $vscArgs -Verb RunAs -PassThru -Wait -WindowStyle Hidden
    } finally { Exit-WizardBusy }

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Success  = ($proc.ExitCode -eq 0)
    }
}

function Get-SmartCardCertificateInfo {
    # Ermittelt Provider-/Reader-/Hardware-Info für den privaten Schlüssel eines
    # Zertifikats über mehrere Wege, da je nach CSP/KSP (Legacy-CAPI vs. CNG)
    # unterschiedliche .NET-APIs greifen - EIN Weg allein deckt nicht alle Faelle ab:
    #   1. .PrivateKey.CspKeyContainerInfo - klassischer Weg für Legacy-CAPI-CSPs
    #      (z.B. "Microsoft Base Smart Card Crypto Provider", der Default dieses
    #      Wizards). Wirft bei rein CNG-basierten Schlüsseln typischerweise eine
    #      Exception.
    #   2. GetRSAPrivateKey() liefert je nach Schlüsseltyp ENTWEDER RSACng (CNG,
    #      Provider über .Key.Provider) ODER RSACryptoServiceProvider (Legacy-CAPI,
    #      Provider über .CspKeyContainerInfo wie bei Weg 1) - beide Faelle werden
    #      hier unterschieden, da ein direkter .Key-Zugriff auf einem
    #      RSACryptoServiceProvider-Objekt schlicht $null liefert (kein Fehler, aber
    #      auch kein Ergebnis - das war der Grund, warum bisher gar keine Zertifikate
    #      gefunden wurden).
    #      WICHTIG: GetRSAPrivateKey() ist in .NET eine C#-Extension-Method
    #      (RSACertificateExtensions), keine Instanzmethode - PowerShells Dot-Notation
    #      ($Certificate.GetRSAPrivateKey()) löst Extension-Methods NICHT auf und
    #      wirft "does not contain a method named 'GetRSAPrivateKey'". Muss deshalb
    #      als statischer Aufruf erfolgen (siehe unten) - das war der eigentliche
    #      Grund, warum auf echten CNG-Zertifikaten (der Normalfall auf aktuellen
    #      Windows-Versionen) bislang GAR KEINE Zertifikate erkannt wurden.
    #      Reader-Zuordnung für CNG/KSP-Schlüssel: über die NCrypt-Property
    #      "SmartCardReader" (der korrekte Name OHNE Leerzeichen - "Smart Card Reader"
    #      MIT Leerzeichen liefert NTE_NOT_SUPPORTED, das war urspruenglich der
    #      Trugschluss "Reader nicht ermittelbar"). Liefert den PC/SC-Namen
    #      ("Microsoft Virtual Smart Card N"), der über Get-VirtualSmartCardReaders
    #      (PcscName) dem PnP-Lesegerät zugeordnet wird.
    # HardwareDevice (falls ermittelbar) ist ein zusätzliches, von der Provider-Namen-
    # Heuristik unabhängiges Signal.
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        # Optional: bereits per Sammelabfrage (Get-SmartCardCngProviderInfoBatch)
        # ermitteltes CNG-Ergebnis - spart den eigenen Kindprozess pro Zertifikat.
        [object]$CngResult
    )

    $info = [pscustomobject]@{ Provider = $null; Reader = $null; IsHardware = $false; KeyContainerName = $null; DetectionError = $null }

    try {
        $capiKey = $Certificate.PrivateKey
        if ($capiKey -and $capiKey.CspKeyContainerInfo) {
            $info.Provider = $capiKey.CspKeyContainerInfo.ProviderName
            $info.Reader = $capiKey.CspKeyContainerInfo.Reader
            $info.IsHardware = [bool]$capiKey.CspKeyContainerInfo.HardwareDevice
            $info.KeyContainerName = $capiKey.CspKeyContainerInfo.KeyContainerName
        }
    } catch {
        $info.DetectionError = $_.Exception.Message
    }

    if (-not $info.Provider) {
        $cngResult = if ($CngResult) { $CngResult } else { Get-SmartCardCngProviderInfo -Thumbprint $Certificate.Thumbprint }
        if ($cngResult.TimedOut) {
            $info.DetectionError = T 'Zeitüberschreitung beim CNG-Schlüsselzugriff (evtl. verweist das Zertifikat auf eine bereits gelöschte virtuelle Smartcard).'
        } elseif ($cngResult.Provider) {
            $info.Provider = $cngResult.Provider
            $info.Reader = $cngResult.Reader
            $info.IsHardware = $cngResult.IsHardware
            $info.KeyContainerName = $cngResult.Container
        } elseif ($cngResult.DetectionError -and -not $info.DetectionError) {
            $info.DetectionError = $cngResult.DetectionError
        }
    }

    return $info
}

function Clear-SmartCardInfoCache {
    # Nach Erstellen/Löschen von Karten oder Schlüsseln aufrufen (siehe Cache in
    # Get-SmartCardCngProviderInfoBatch). Verwirft auch das gecachte TPM-Ergebnis: dessen
    # letzte Stufe ("eine VSC existiert -> TPM nutzbar") hängt vom Kartenbestand ab.
    $script:CngInfoCache = @{}
    $script:TpmReadinessCache = $null
}

function Get-VscInventorySignature {
    # Günstige (~20 ms) Signatur des VSC-Bestands: Instanzen + ParentIdPrefix unter
    # Enum\ROOT\SMARTCARDREADER. Ändert sich bei jedem Erstellen/Löschen einer TPM-VSC,
    # egal durch wen.
    try {
        return (@(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\SMARTCARDREADER' -ErrorAction Stop | ForEach-Object {
            "$($_.PSChildName)=$((Get-ItemProperty -LiteralPath $_.PSPath -Name ParentIdPrefix -ErrorAction SilentlyContinue).ParentIdPrefix)"
        }) -join ';')
    } catch { return '' }
}

function Get-SmartCardCngProviderInfo {
    # Einzelabfrage - dünner Wrapper um die Sammelabfrage (eine Quelle der Wahrheit).
    param(
        [Parameter(Mandatory)][string]$Thumbprint,
        [int]$TimeoutSeconds = 3
    )
    return (Get-SmartCardCngProviderInfoBatch -Thumbprint @($Thumbprint) -TimeoutSeconds $TimeoutSeconds)[$Thumbprint]
}

function Get-SmartCardCngProviderInfoBatch {
    # Liefert eine Hashtable Thumbprint -> Info-Objekt (Provider/Reader/IsHardware/
    # Container/DetectionError/TimedOut) für MEHRERE Zertifikate in EINEM Kindprozess.
    # Früher: ein powershell.exe-Start pro Zertifikat (~1 s je Stück, bei 17
    # Zertifikaten ~18 s ohne Rückmeldung). Hängt der Sammelprozess an einem
    # verwaisten Zertifikat (siehe unten), werden die bis dahin abgeschlossenen
    # Ergebnisse übernommen und NUR die fehlenden einzeln (mit eigenem Timeout)
    # nachgeholt - der Hänger-Schutz bleibt also vollständig erhalten.
    #
    # GetRSAPrivateKey().Key.Provider (CNG-Weg, siehe Get-SmartCardCertificateInfo)
    # kann bei einem Zertifikat, dessen zugehörige virtuelle Smartcard bereits
    # gelöscht wurde (Schlüsselcontainer verweist auf eine nicht mehr vorhandene
    # Karte), UNBEGRENZT blockieren - Windows' Smartcard-Ressourcenverwaltung wartet
    # in diesem Fall auf das (nie kommende) Einstecken der Karte. Auf echter Hardware
    # reproduziert: virtuelle Smartcard gelöscht, zugehöriges Zertifikat blieb im
    # Speicher, GetRSAPrivateKey() hängt beim nächsten Aufruf fest und blockiert
    # damit den GESAMTEN Wizard (Inventar-Dialog öffnet sich nie). Deshalb NIE direkt
    # im GUI-Prozess aufrufen - stattdessen in einem separaten, per Timeout zwangs-
    # beendbaren Prozess (Invoke-ExternalCommand tötet den Prozess zuverlässig bei
    # Zeitüberschreitung, im Gegensatz zu einem im selben Prozess hängenden Thread).
    param(
        # AllowEmptyCollection: ein Benutzer ohne Zertifikat mit privatem Schlüssel ist
        # legitim (sonst Bindungsfehler -> in der PS2EXE-Exe als Fehler-Popup).
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Thumbprint,
        # Grundbudget (Prozessstart); pro Zertifikat kommt ein kleiner Zuschlag dazu.
        [int]$TimeoutSeconds = 3
    )

    # Sitzungs-Cache: die Schlüssel-Zuordnung eines Zertifikats ändert sich nicht - nur
    # neue Zertifikate brauchen den Kindprozess. Nur fehlerfreie Ergebnisse (kein
    # Timeout/DetectionError) werden gecacht; Clear-SmartCardInfoCache leert ihn, sobald Karten
    # erstellt/gelöscht werden (PC/SC-Nummern werden wiederverwendet).
    # Kartenbestand auch AUSSERHALB des Wizards geändert (tpmvscmgr, zweite Instanz)?
    # Dann Cache verwerfen - sonst würden alte Zertifikate einer wiederverwendeten
    # PC/SC-Nummer der neuen Karte zugeordnet.
    $vscSignature = Get-VscInventorySignature
    if ($script:CngInfoCacheSignature -ne $vscSignature) { Clear-SmartCardInfoCache; $script:CngInfoCacheSignature = $vscSignature }
    if (-not $script:CngInfoCache) { $script:CngInfoCache = @{} }
    $results = @{}
    foreach ($tp in @($Thumbprint | Where-Object { $_ } | Select-Object -Unique)) {
        if ($script:CngInfoCache.ContainsKey($tp)) { $results[$tp] = $script:CngInfoCache[$tp] }
    }
    $pending = @($Thumbprint | Where-Object { $_ -and -not $results.ContainsKey($_) } | Select-Object -Unique)
    if ($pending.Count -eq 0) { return $results }

    # Dieses Skript läuft als EIGENER Prozess (siehe unten) und importiert Core.psm1
    # deshalb NICHT - braucht den nativen-Module-Fix vom Kopf dieser Datei also
    # eigenständig, sonst fehlt in genau diesem Kindprozess das "Cert:"-Laufwerk
    # (gleiche Ursache wie beim Hauptprozess, siehe Kommentar oben in dieser Datei).
    # Immer neu schreiben (nicht nur bei Nichtvorhandensein) - sonst würde eine
    # bereits von einer AELTEREN Skriptversion angelegte Datei liegen bleiben und
    # Änderungen an diesem Lookup-Skript würden nie wirksam.
    $scriptPath = Join-Path (Get-WizardWorkingDir) 'cng-provider-lookup.ps1'
    $lookupScript = @'
# Thumbprints kommagetrennt (ein -File-Parameter kann kein Array aufnehmen).
# Ausgabe je Zertifikat: "Begin=<tp>", key=value-Zeilen, "End=<tp>" - nur Blöcke mit
# End-Marker gelten als abgeschlossen (wichtig bei einem Timeout-Abbruch).
param([Parameter(Mandatory)][string]$Thumbprints)
foreach ($nativeModuleName in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Management')) {
    $nativeModulePath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\Modules\$nativeModuleName\$nativeModuleName.psd1"
    if (Test-Path $nativeModulePath) {
        Import-Module $nativeModulePath -Force -ErrorAction SilentlyContinue
    }
}
foreach ($Thumbprint in ($Thumbprints -split ',')) {
    [Console]::Out.WriteLine("Begin=$Thumbprint")
    try {
        $cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction Stop
        $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if ($rsaKey -is [System.Security.Cryptography.RSACng]) {
            $k = $rsaKey.Key
            if ($k -and $k.Provider) {
                [Console]::Out.WriteLine("Provider=$($k.Provider.Provider)")
                [Console]::Out.WriteLine("Container=$($k.KeyName)")
                # NCrypt-Property "SmartCardReader" (ohne Leerzeichen!) - PC/SC-Lesegerätename.
                # Fehlt bei Nicht-Smartcard-CNG-Schlüsseln; dann still überspringen.
                try {
                    $prop = $k.GetProperty('SmartCardReader', [System.Security.Cryptography.CngPropertyOptions]::None)
                    $readerName = [System.Text.Encoding]::Unicode.GetString($prop.GetValue()).TrimEnd([char]0)
                    if ($readerName) { [Console]::Out.WriteLine("Reader=$readerName") }
                } catch { }
            }
        } elseif ($rsaKey -and $rsaKey.CspKeyContainerInfo) {
            [Console]::Out.WriteLine("Provider=$($rsaKey.CspKeyContainerInfo.ProviderName)")
            [Console]::Out.WriteLine("Reader=$($rsaKey.CspKeyContainerInfo.Reader)")
            [Console]::Out.WriteLine("IsHardware=$([bool]$rsaKey.CspKeyContainerInfo.HardwareDevice)")
            [Console]::Out.WriteLine("Container=$($rsaKey.CspKeyContainerInfo.KeyContainerName)")
        }
    } catch {
        [Console]::Out.WriteLine("Error=$($_.Exception.Message -replace '[\r\n]+', ' ')")
    }
    [Console]::Out.WriteLine("End=$Thumbprint")
    [Console]::Out.Flush()
}
'@
    Set-Content -Path $scriptPath -Value $lookupScript -Encoding UTF8

    $batchTimeout = $TimeoutSeconds + [int][math]::Ceiling($pending.Count / 4)
    $result = Invoke-ExternalCommand -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Thumbprints', ($pending -join ',')
    ) -TimeoutSeconds $batchTimeout -Silent
    $timedOut = ($result.StdErr -eq 'Timeout')
    $output = if ($timedOut) { $result.PartialStdOut } else { $result.StdOut }

    $current = $null
    foreach ($line in ("$output" -split "`r?`n")) {
        if ($line -match '^Begin=(.*)$') {
            $current = [pscustomobject]@{ Provider = $null; Reader = $null; IsHardware = $false; Container = $null; DetectionError = $null; TimedOut = $false }
        } elseif (-not $current) {
            continue
        } elseif ($line -match '^End=(.*)$') {
            $results[$Matches[1]] = $current
            # Auch "kein CNG-RSA-Schlüssel" (z.B. ECC) ist stabil - nur Fehler nicht cachen.
            if (-not $current.DetectionError) { $script:CngInfoCache[$Matches[1]] = $current }
            $current = $null
        }
        elseif ($line -match '^Provider=(.*)$') { $current.Provider = $Matches[1] }
        elseif ($line -match '^Reader=(.*)$') { $current.Reader = $Matches[1] }
        elseif ($line -match '^IsHardware=(.*)$') { $current.IsHardware = [bool]::Parse($Matches[1]) }
        elseif ($line -match '^Container=(.*)$') { $current.Container = $Matches[1] }
        elseif ($line -match '^Error=(.*)$') { $current.DetectionError = $Matches[1] }
    }

    $missing = @($pending | Where-Object { -not $results.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        if ($timedOut -and $pending.Count -gt 1) {
            # Sammelprozess hing (typisch: verwaistes Zertifikat einer gelöschten VSC) -
            # die fehlenden einzeln nachholen; nur der Hänger läuft dann in seinen Timeout.
            Write-WizardLog -Message "CNG-Sammelabfrage: Zeitüberschreitung, $($missing.Count) Zertifikat(e) werden einzeln geprüft." -Level Info
            foreach ($tp in $missing) {
                $results[$tp] = (Get-SmartCardCngProviderInfoBatch -Thumbprint @($tp) -TimeoutSeconds $TimeoutSeconds)[$tp]
            }
        } else {
            $err = if ($timedOut) { $null } elseif ($result.StdErr) { $result.StdErr.Trim() } else { T 'Kein Ergebnis vom Lookup-Prozess.' }
            foreach ($tp in $missing) {
                $results[$tp] = [pscustomobject]@{ Provider = $null; Reader = $null; IsHardware = $false; Container = $null; DetectionError = $err; TimedOut = $timedOut }
            }
        }
    }
    return $results
}

function Get-SmartCardCertificates {
    # Hülle: Busy-Anzeige um die eigentliche Erkennung (Read-SmartCardCertificates).
    param([string]$StoreLocation = 'Cert:\CurrentUser\My')
    Enter-WizardBusy -Text 'Lese Smartcard-Zertifikate...'
    try { return (Read-SmartCardCertificates -StoreLocation $StoreLocation) } finally { Exit-WizardBusy }
}

function Read-SmartCardCertificates {
    # Alle Zertifikate im Benutzer-Zertifikatsspeicher mit privatem Schlüssel.
    # IsSmartCard=true, wenn Provider-Name "Smart Card" enthält ODER die CSP-Info
    # das Gerät als Hardware-Schlüssel meldet. Zertifikate mit privatem Schlüssel,
    # die NICHT sicher als Smartcard erkannt wurden, werden trotzdem zurückgegeben
    # (samt Provider/DetectionError) statt sie stillschweigend zu verwerfen - damit
    # eine unvollständige Erkennung in der GUI sichtbar/diagnostizierbar bleibt statt
    # einfach nichts anzuzeigen.
    param([string]$StoreLocation = 'Cert:\CurrentUser\My')

    $certs = $null
    try {
        $certs = Get-ChildItem -Path $StoreLocation -ErrorAction Stop
    } catch {
        Write-WizardLog -Message "Get-ChildItem $StoreLocation fehlgeschlagen: $($_.Exception.Message)" -Level Error
    }
    Write-WizardLog -Message "Get-SmartCardCertificates: Get-ChildItem $StoreLocation lieferte $(@($certs).Count) Einträge (davon $(@($certs | Where-Object HasPrivateKey).Count) mit privatem Schlüssel)." -Level Info
    # CNG-Infos für ALLE Kandidaten in EINEM Kindprozess vorab holen (statt eines
    # powershell.exe-Starts pro Zertifikat - siehe Get-SmartCardCngProviderInfoBatch).
    $keyCerts = @($certs | Where-Object { $_.HasPrivateKey })
    if ($keyCerts.Count -eq 0) { return @() }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cngLookup = Get-SmartCardCngProviderInfoBatch -Thumbprint @($keyCerts | ForEach-Object { $_.Thumbprint })
    Write-WizardLog -Message "Get-SmartCardCertificates: CNG-Sammelabfrage für $($keyCerts.Count) Zertifikat(e) in $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s." -Level Info
    $results = foreach ($cert in $keyCerts) {
        $info = Get-SmartCardCertificateInfo -Certificate $cert -CngResult $cngLookup[$cert.Thumbprint]
        $isSmartCard = $info.IsHardware -or ($info.Provider -and $info.Provider -match 'Smart Card')
        # UPN (Principal Name) aus dem SubjectAltName lesen - identifiziert das KONTO,
        # fuer das die Karte ausgestellt wurde (wichtig fuer die Verlaengerung, damit
        # nicht versehentlich fuer den falschen Benutzer re-enrollt wird). Format($true)
        # ist lokalisiert, daher ueber ein E-Mail-/UPN-Muster statt fester Feldnamen.
        $upn = $null
        try {
            $san = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
            if ($san) {
                $sanTxt = $san.Format($true)
                if ($sanTxt -match '([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})') { $upn = $Matches[1] }
            }
        } catch { }
        [pscustomobject]@{
            Subject          = $cert.Subject
            Upn              = $upn
            Thumbprint       = $cert.Thumbprint
            NotBefore        = $cert.NotBefore
            NotAfter         = $cert.NotAfter
            Provider         = $info.Provider
            Reader           = $info.Reader
            KeyContainerName = $info.KeyContainerName
            IsSmartCard      = [bool]$isSmartCard
            DetectionError   = $info.DetectionError
        }
    }
    return @($results)
}

function Remove-SmartCardCertificateFromCard {
    # Entfernt EINEN Schlüssel-Container (samt zugehörigem Zertifikat) von einer
    # Karte - z.B. ein versehentlich zusätzlich aufgespieltes Cert. Nutzt
    # 'certutil -csp <Provider> -delkey <Container>' (fragt ggf. die Karten-PIN).
    # Entfernt danach den (nun verwaisten) Eintrag aus dem Benutzer-Zertifikatsspeicher.
    # KEINE Sicherheitsabfrage hier - die Bestätigung ist Aufgabe der GUI.
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerName,
        [string]$Thumbprint
    )

    Clear-SmartCardInfoCache
    Write-WizardLog -Message "Entferne Schlüssel-Container '$ContainerName' (Provider '$Provider') von der Karte - 'certutil -delkey' erfordert Administratorrechte (UAC), danach ggf. PIN-Dialog." -Level Command

    $ok = $false
    $detail = ''
    if (Test-IsElevated) {
        # Bereits eleviert: direkt mit Ausgabe-Erfassung.
        $result = Invoke-ExternalCommand -FilePath 'certutil.exe' -ArgumentList @('-csp', $Provider, '-delkey', $ContainerName) -TimeoutSeconds 120
        $ok = $result.Success
        $detail = "$($result.StdOut) $($result.StdErr)".Trim()
    } else {
        # Nicht eleviert: 'certutil -delkey' braucht Adminrechte -> eleviert starten.
        # RunAs erlaubt keine Ausgabeumleitung, daher laeuft ein kleiner Wrapper, der
        # Exit-Code + Ausgabe in eine Datei in C:\Users\Public schreibt (fuer beide
        # Konten lesbar, auch bei Ueber-die-Schulter-Elevation).
        $publicDir = Join-Path $env:SystemDrive 'Users\Public'
        $token = [guid]::NewGuid().ToString('N')
        $scriptPath = Join-Path $publicDir "vscwizard-delkey-$token.ps1"
        $outPath = Join-Path $publicDir "vscwizard-delkey-$token.txt"
        $wrapper = @"
`$o = & certutil.exe -csp '$Provider' -delkey '$ContainerName' 2>&1
Set-Content -Path '$outPath' -Value ("EXIT=`$LASTEXITCODE`r`n" + (`$o -join "`r`n")) -Encoding UTF8
"@
        Set-Content -Path $scriptPath -Value $wrapper -Encoding UTF8
        Enter-WizardBusy -Text 'Entferne Schlüssel von der Smartcard...'
        try {
            # -WindowStyle Hidden: bei -Verb RunAs erzwingt Windows ShellExecute; der
            # Hidden-Style wird zu SW_HIDE, sodass das elevierte PowerShell-Fenster
            # NICHT aufblitzt (nur der UAC-Dialog erscheint, der ist unvermeidbar).
            # Gleiche Technik wie beim 'tpmvscmgr destroy' weiter oben. certutil erbt
            # die versteckte Konsole des Hosts und oeffnet kein eigenes Fenster.
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) -Verb RunAs -Wait -WindowStyle Hidden -ErrorAction Stop
        } catch {
            Remove-Item $scriptPath, $outPath -ErrorAction SilentlyContinue
            $msg = (T 'Elevierter Löschvorgang konnte nicht gestartet werden (UAC abgelehnt?): {0}') -f $_.Exception.Message
            Write-WizardLog -Message $msg -Level Error
            return [pscustomobject]@{ Success = $false; Message = $msg }
        } finally { Exit-WizardBusy }
        if (Test-Path $outPath) {
            $content = (Get-Content -Path $outPath -Raw -ErrorAction SilentlyContinue)
            if ($content -match 'EXIT=(-?\d+)') { $ok = ($Matches[1] -eq '0') }
            $detail = "$content".Trim()
        } else {
            $detail = T 'Kein Ergebnis vom elevierten Prozess erhalten.'
        }
        Remove-Item $scriptPath, $outPath -ErrorAction SilentlyContinue
    }

    if (-not $ok) {
        Write-WizardLog -Message "Löschen des Schlüssel-Containers fehlgeschlagen: $detail" -Level Error
        return [pscustomobject]@{ Success = $false; Message = "certutil -delkey fehlgeschlagen. $detail" }
    }

    # Store-Eintrag im AKTUELLEN (angemeldeten) Benutzerkontext bereinigen - der
    # verweist nach dem Löschen auf einen nicht mehr vorhandenen Schlüssel.
    if ($Thumbprint) {
        Remove-Item -Path "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction SilentlyContinue
    }
    Write-WizardLog -Message 'Schlüssel-Container von der Karte entfernt und Speicher-Eintrag bereinigt.' -Level Success
    return [pscustomobject]@{ Success = $true; Message = '' }
}

#endregion

#region Zertifikatsanforderung (certreq)

function ConvertTo-CleanPemRequest {
    # Saeubert eine eingefuegte/geladene CSR zu einem kanonischen PEM, an dem certreq
    # zuverlaessig parsen kann. Haeufige Ursache fuer CRYPT_E_ASN1_BADTAG (0x8009310b)
    # beim Submit: ein fuehrendes BOM-Zeichen, Fremd-Whitespace, kaputte Zeilenumbrueche
    # oder Text vor/nach dem PEM-Block aus dem Copy&Paste-/RDP-Round-trip.
    # Vorgehen: PEM-Block extrahieren, reines Base64 herausfiltern, validieren und
    # sauber bei 64 Zeichen neu umbrechen. Gibt $null zurueck, wenn kein gueltiges
    # Base64 vorliegt (dann ist die Quelle wirklich defekt, nicht nur unsauber).
    param([Parameter(Mandatory)][string]$Text)

    $t = $Text -replace "$([char]0xFEFF)", ''   # BOM-Zeichen entfernen
    $header = 'NEW CERTIFICATE REQUEST'
    if ($t -match '(?s)-----BEGIN ([A-Z0-9 ]+)-----(.*?)-----END \1-----') {
        $header = $Matches[1].Trim()
        $body = $Matches[2]
    } else {
        $body = $t   # kein Header gefunden - als reinen Base64-Koerper behandeln
    }

    $b64 = ($body -replace '[^A-Za-z0-9+/=]', '')
    if (-not $b64) { return $null }
    try { [void][Convert]::FromBase64String($b64) } catch { return $null }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("-----BEGIN $header-----`r`n")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $len = [Math]::Min(64, $b64.Length - $i)
        [void]$sb.Append($b64.Substring($i, $len)); [void]$sb.Append("`r`n")
    }
    [void]$sb.Append("-----END $header-----`r`n")
    return $sb.ToString()
}

function New-EnrollmentInfFile {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Upn,
        [string]$CspName = 'Microsoft Base Smart Card Crypto Provider',
        [Parameter(Mandatory)][string]$Path,
        # Enroll on Behalf Of: setzt das Konto, FÜR das ausgestellt wird
        # (z.B. "CONTOSO\adm.mustermann"). Ist es gesetzt, wird ein PKCS7-Antrag
        # erzeugt, der später mit dem Enrollment-Agent-Zertifikat co-signiert wird.
        [string]$RequesterName,
        # Für den EA-Zertifikatsantrag selbst: das Template steuert die EKU; hier
        # nur die Key-Parameter. Für ein Software-EA-Zertifikat wird der
        # Software-KSP verwendet (kein Smartcard-Provider).
        [string]$TemplateName
    )

    $sanBlock = ''
    if ($Upn) {
        $sanBlock = @"

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "upn=$Upn&"
"@
    }

    # ProviderType/KeySpec sind reine CAPI-Konstrukte (Legacy-CSPs wie der
    # "Microsoft Base Smart Card Crypto Provider"). Für einen CNG-KSP (z.B.
    # "Microsoft Smart Card Key Storage Provider" oder "Microsoft Software Key
    # Storage Provider") dürfen sie NICHT gesetzt werden, sonst lehnt certreq die
    # Kombination ab - dort wählt certreq den CNG-Pfad allein anhand des
    # Provider-Namens. Heuristik: "Key Storage Provider" im Namen = KSP.
    $isKsp = $CspName -match 'Key Storage Provider'
    $capiBlock = if ($isKsp) { '' } else { "KeySpec = 1`r`nProviderType = 1`r`n" }

    $requestType = if ($RequesterName) { 'PKCS7' } else { 'PKCS10' }
    $requesterBlock = if ($RequesterName) { "RequesterName = `"$RequesterName`"`r`n" } else { '' }
    # Bei EOBO (PKCS7) gehört der Template-Verweis IN den Antrag; bei PKCS10
    # übergibt Submit-CertificateSigningRequest ihn später per -attrib.
    $templateBlock = if ($RequesterName -and $TemplateName) { "`r`n[RequestAttributes]`r`nCertificateTemplate = $TemplateName`r`n" } else { '' }

    # Hinweis: KeyLength/KeyUsage/HashAlgorithm sind gängige Defaults für
    # Smartcard-Logon-Zertifikate und können bei Bedarf an das eigene
    # Zertifikatstemplate angepasst werden.
    $inf = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "$Subject"
Exportable = FALSE
KeyLength = 2048
KeyUsage = 0xA0
MachineKeySet = FALSE
ProviderName = "$CspName"
$($capiBlock)$($requesterBlock)RequestType = $requestType
HashAlgorithm = SHA256
$sanBlock
$templateBlock
"@

    Set-Content -Path $Path -Value $inf -Encoding Default
    return $Path
}

function New-CertificateSigningRequest {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Upn,
        [string]$CspName,
        [Parameter(Mandatory)][string]$OutputDirectory,
        # Enroll on Behalf Of (siehe New-EnrollmentInfFile): Zielkonto + Template
        # gehören in den PKCS7-Antrag, und der Antrag wird mit dem
        # Enrollment-Agent-Zertifikat (Thumbprint) co-signiert.
        [string]$RequesterName,
        [string]$TemplateName,
        [string]$SigningCertThumbprint
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $infPath = Join-Path $OutputDirectory 'request.inf'
    # PKCS7-Anträge (EOBO) tragen zur Klarheit eine andere Endung.
    $isEobo = [bool]$RequesterName
    $csrPath = Join-Path $OutputDirectory $(if ($isEobo) { 'request.p7' } else { 'request.csr' })
    if (Test-Path $csrPath) { Remove-Item $csrPath -Force }

    New-EnrollmentInfFile -Subject $Subject -Upn $Upn -CspName $CspName -Path $infPath -RequesterName $RequesterName -TemplateName $TemplateName | Out-Null

    # -cert <Thumbprint>: certreq signiert den PKCS7-Antrag mit diesem
    # Enrollment-Agent-Zertifikat (der EA-Schlüssel bleibt in seinem Store/auf
    # seiner Karte; ggf. erscheint dabei dessen PIN-Dialog).
    $newArgs = @('-new')
    if ($SigningCertThumbprint) { $newArgs += @('-cert', $SigningCertThumbprint) }
    $newArgs += @($infPath, $csrPath)

    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList $newArgs
    if ($result.Success -and (Test-Path $csrPath)) {
        Write-WizardLog -Message "$(if ($isEobo) { 'EOBO-Antrag (PKCS7)' } else { 'CSR' }) erstellt: $csrPath" -Level Success
        return [pscustomobject]@{ Success = $true; CsrPath = $csrPath }
    }
    Write-WizardLog -Message 'Antragserstellung fehlgeschlagen.' -Level Error
    return [pscustomobject]@{ Success = $false; CsrPath = $null }
}

function Get-EnrollmentAgentCertificates {
    # Findet im Benutzer-Zertifikatsspeicher Zertifikate mit der EKU
    # "Certificate Request Agent" (OID 1.3.6.1.4.1.311.20.2.1) und privatem
    # Schlüssel - genau die, mit denen sich Enroll-on-Behalf-Of-Anträge
    # signieren lassen. Abgelaufene werden weggelassen.
    $eaOid = '1.3.6.1.4.1.311.20.2.1'
    $now = Get-Date
    $certs = Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue
    $results = foreach ($cert in $certs) {
        if (-not $cert.HasPrivateKey) { continue }
        if ($cert.NotAfter -lt $now -or $cert.NotBefore -gt $now) { continue }
        $ekus = @($cert.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId })
        if ($ekus -contains $eaOid) {
            [pscustomobject]@{
                Subject    = $cert.Subject
                Thumbprint = $cert.Thumbprint
                NotAfter   = $cert.NotAfter
            }
        }
    }
    return @($results)
}

function Submit-CertificateSigningRequest {
    param(
        [Parameter(Mandatory)][string]$CsrPath,
        [Parameter(Mandatory)][string]$CAConfig,
        # Bei EOBO/PKCS7-Anträgen leer lassen: das Template steht dann bereits im
        # Antrag (RequestAttributes) - ein zusätzliches -attrib wäre redundant.
        [string]$TemplateName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $cerPath = Join-Path $OutputDirectory 'certnew.cer'
    # Beide Ausgabedateien eines früheren Laufs entfernen - sonst fragt certreq per
    # MessageBox "Soll die Datei ... certnew.rsp überschrieben werden?" (z.B. beim
    # erneuten Antrag auf dieselbe VSC; gleiches Verzeichnis PlanA-<Karte>).
    Remove-Item -LiteralPath $cerPath, ([IO.Path]::ChangeExtension($cerPath, '.rsp')) -Force -ErrorAction SilentlyContinue

    $submitArgs = @('-submit', '-config', $CAConfig)
    if ($TemplateName) { $submitArgs += @('-attrib', "CertificateTemplate:$TemplateName") }
    $submitArgs += @($CsrPath, $cerPath)
    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList $submitArgs

    $requestId = Get-CertReqRequestId -Output $result.StdOut

    if (Test-CertReqPending -Output $result.StdOut) {
        Write-WizardLog -Message "Antrag eingereicht, wartet auf Genehmigung (RequestId: $requestId). $(Get-PendingApprovalHint -RequestId $requestId -NextStep '')" -Level Info
        return [pscustomobject]@{ Success = $true; Pending = $true; RequestId = $requestId; CerPath = $null }
    }

    if ($result.Success -and (Test-Path $cerPath)) {
        Write-WizardLog -Message "Zertifikat ausgestellt: $cerPath" -Level Success
        return [pscustomobject]@{ Success = $true; Pending = $false; RequestId = $requestId; CerPath = $cerPath }
    }

    Write-WizardLog -Message 'Antrag fehlgeschlagen.' -Level Error
    return [pscustomobject]@{ Success = $false; Pending = $false; RequestId = $requestId; CerPath = $null }
}

function Receive-PendingCertificate {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$CAConfig,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    # Eigener Dateiname je Antrag: ein bereits zuvor ausgestelltes certnew.cer im selben
    # (in Plan B vom Benutzer gewählten) Ordner bleibt unangetastet.
    $cerPath = Join-Path $OutputDirectory "certnew-$RequestId.cer"
    # Nur DIESE Ausgabedateien entfernen - sonst fragt certreq interaktiv "overwrite?"
    # und der umgeleitete Prozess blockiert.
    Remove-Item -LiteralPath $cerPath, ([IO.Path]::ChangeExtension($cerPath, '.rsp')) -Force -ErrorAction SilentlyContinue
    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList @('-retrieve', '-config', $CAConfig, $RequestId, $cerPath)

    if ($result.Success -and (Test-Path $cerPath)) {
        Write-WizardLog -Message "Zertifikat abgerufen: $cerPath" -Level Success
        return [pscustomobject]@{ Success = $true; Status = 'Issued'; CerPath = $cerPath; Message = '' }
    }
    # Unterscheiden statt pauschal "noch nicht ausgestellt": noch offen / abgelehnt / Fehler.
    $out = "$($result.StdOut) $($result.StdErr)"
    if (Test-CertReqPending -Output $out) {
        return [pscustomobject]@{ Success = $false; Status = 'Pending'; CerPath = $null; Message = ((T 'Antrag {0} ist noch nicht genehmigt. {1}') -f $RequestId, (Get-PendingApprovalHint -RequestId $RequestId)) }
    }
    if ($out -match 'Denied|abgelehnt|verweigert') {
        return [pscustomobject]@{ Success = $false; Status = 'Denied'; CerPath = $null; Message = ((T 'Antrag {0} wurde von der CA abgelehnt - bitte neu beantragen.') -f $RequestId) }
    }
    return [pscustomobject]@{ Success = $false; Status = 'Error'; CerPath = $null; Message = ((T 'Abruf von Antrag {0} fehlgeschlagen (Details siehe Log).') -f $RequestId) }
}

function Get-CertReqRequestId {
    # Request-ID aus der certreq-Ausgabe. Die Beschriftung ist LOKALISIERT
    # (EN "RequestId: 932", DE "Anforderungs-ID: 932") - früher wurde nur die englische
    # erkannt; auf deutschem Windows blieb die ID leer und "Zertifikat abrufen" tat
    # nichts. Fallback sprachunabhängig: erste Zeile der Form "<Beschriftung>: <Zahl>".
    param([string]$Output)
    if ("$Output" -match '(?im)^\s*(?:RequestId|Request ID|Anforderungs-ID)\s*:\s*"?(\d+)') { return $Matches[1] }
    if ("$Output" -match '(?m)^[^:\r\n]{1,40}:\s*"?(\d+)"?\s*$') { return $Matches[1] }
    return $null
}

function Test-CertReqPending {
    # "Taken Under Submission" stammt von der CA (Sprache der CA), "Certificate Pending"/
    # "ausstehend" von certreq (Sprache des Clients).
    param([string]$Output)
    return [bool]("$Output" -match 'Taken Under Submission|Certificate Pending|ausstehend')
}

function Get-PendingApprovalHint {
    # Was bei einem wartenden Antrag zu tun ist - vorher stand das nirgends.
    param(
        [string]$RequestId,
        # Für Stellen ohne "Zertifikat abrufen"-Button (z.B. EA-Dialog).
        [string]$NextStep = (T "Danach hier 'Zertifikat abrufen'.")
    )
    $id = if ($RequestId) { $RequestId } else { '<ID>' }
    return ((T "Ein CA-Manager muss ihn genehmigen: auf der CA in der Zertifizierungsstellen-Konsole (certsrv.msc) unter 'Ausstehende Anforderungen' ausstellen oder dort 'certutil -resubmit {0}' ausführen. {1}") -f $id, $NextStep).Trim()
}

function Complete-CertificateEnrollment {
    param([Parameter(Mandatory)][string]$CerPath)

    # Vorab prüfen, ob der offene Antrag (gleicher öffentlicher Schlüssel) noch im
    # Antragsspeicher liegt. Fehlt er, scheitert certreq -accept sicher - und zeigt dabei
    # eine eigene Fehler-MessageBox. Dann gleich den Ersatzweg gehen, ohne certreq.
    $cer = $null
    try { $cer = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CerPath } catch { }
    if ($cer) {
        $pub = [Convert]::ToBase64String($cer.GetPublicKey())
        $inStore = @(Get-ChildItem Cert:\CurrentUser\REQUEST -ErrorAction SilentlyContinue | Where-Object { [Convert]::ToBase64String($_.GetPublicKey()) -eq $pub })
        if ($inStore.Count -eq 0) {
            Write-WizardLog -Message 'Der offene Antrag ist nicht mehr im Antragsspeicher (certreq -accept nicht möglich) - installiere das Zertifikat stattdessen direkt auf die passende Karte. Windows fragt dafür die Karten-PIN ab.' -Level Info
            $direct = Install-CertificateOnSmartCard -CerPath $CerPath
            if ($direct.Success) { return [pscustomobject]@{ Success = $true } }
            Write-WizardLog -Message 'Zertifikatsübernahme fehlgeschlagen.' -Level Error
            return [pscustomobject]@{ Success = $false }
        }
    }

    # Still ausführen und selbst protokollieren: certreq schreibt bei CRYPT_E_NOT_FOUND
    # seine komplette Syntax-Hilfe + Fehlertext - das wirkte wie ein harter Fehler,
    # obwohl direkt danach der Ersatzweg greift. Rohausgabe nur, wenn am Ende nichts half.
    Write-WizardLog -Message "certreq.exe -accept $CerPath" -Level Command
    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList @('-accept', $CerPath) -Silent
    if ($result.Success) {
        Write-WizardLog -Message 'Zertifikat wurde erfolgreich auf der Smartcard hinterlegt.' -Level Success
        return [pscustomobject]@{ Success = $true }
    }
    $raw = "$($result.StdOut) $($result.StdErr)".Trim()
    # CRYPT_E_NOT_FOUND: certreq findet den offenen Antrag im Antragsspeicher
    # (CurrentUser\REQUEST) nicht mehr - der Schlüssel liegt aber auf der Karte. Dann
    # direkt installieren (Install-CertificateOnSmartCard) statt neu zu beantragen.
    if ($raw -match '0x80092004|CRYPT_E_NOT_FOUND') {
        Write-WizardLog -Message 'Der offene Antrag ist nicht mehr im Antragsspeicher (certreq -accept nicht möglich) - installiere das Zertifikat stattdessen direkt auf die passende Karte. Windows fragt dafür die Karten-PIN ab.' -Level Info
        $direct = Install-CertificateOnSmartCard -CerPath $CerPath
        if ($direct.Success) { return [pscustomobject]@{ Success = $true } }
    }
    if ($raw) { Write-WizardLog -Message $raw -Level Output }
    Write-WizardLog -Message 'Zertifikatsübernahme fehlgeschlagen.' -Level Error
    return [pscustomobject]@{ Success = $false }
}

function Install-CertificateOnSmartCard {
    # Ersatzweg für certreq -accept ohne Antragsspeicher-Eintrag: sucht auf den
    # virtuellen Karten den Schlüssel-Container mit demselben öffentlichen Schlüssel
    # wie das Zertifikat, schreibt das Zertifikat AUF DIE KARTE (NCrypt-Eigenschaft
    # "SmartCardKeyCertificate" - so macht es auch certreq; Windows fragt dabei die
    # Karten-PIN ab) und verknüpft es im Benutzerspeicher (My) mit dem Kartenschlüssel
    # (certutil -repairstore). Läuft als eigener Prozess mit Zeitlimit (Hänger-Schutz
    # wie bei Get-SmartCardCngProviderInfoBatch).
    param([Parameter(Mandatory)][string]$CerPath, [int]$TimeoutSeconds = 300,
        # Nur den passenden Container suchen, nichts schreiben (Tests/Diagnose).
        [switch]$DryRun)

    $readers = @(Get-VirtualSmartCardReaders | Where-Object { $_.PcscName } | ForEach-Object { $_.PcscName })
    if (-not $readers) { Write-WizardLog -Message 'Direkt-Installation: keine virtuelle Smartcard gefunden.' -Level Error; return [pscustomobject]@{ Success = $false } }

    $scriptPath = Join-Path (Get-WizardWorkingDir) 'install-on-card.ps1'
    $installScript = @'
param([Parameter(Mandatory)][string]$CerPath, [Parameter(Mandatory)][string]$Readers, [switch]$DryRun)
foreach ($m in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Management')) {
    $mp = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\Modules\$m\$m.psd1"; if (Test-Path $mp) { Import-Module $mp -Force -ErrorAction SilentlyContinue }
}
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class VscNcEnum {
    [StructLayout(LayoutKind.Sequential)] public struct NCryptKeyName { public IntPtr pszName; public IntPtr pszAlgid; public int dwLegacyKeySpec; public int dwFlags; }
    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)] static extern int NCryptOpenStorageProvider(out IntPtr phProvider, string pszProviderName, int dwFlags);
    [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)] static extern int NCryptEnumKeys(IntPtr hProvider, string pszScope, out IntPtr ppKeyName, ref IntPtr ppEnumState, int dwFlags);
    [DllImport("ncrypt.dll")] static extern int NCryptFreeBuffer(IntPtr pvInput);
    [DllImport("ncrypt.dll")] static extern int NCryptFreeObject(IntPtr hObject);
    public static List<string> Enum(string provider, string scope) {
        var list = new List<string>(); IntPtr hProv;
        if (NCryptOpenStorageProvider(out hProv, provider, 0) != 0) return list;
        IntPtr state = IntPtr.Zero;
        while (true) {
            IntPtr pName;
            if (NCryptEnumKeys(hProv, scope, out pName, ref state, 0x40) != 0) break;
            var kn = (NCryptKeyName)Marshal.PtrToStructure(pName, typeof(NCryptKeyName));
            list.Add(Marshal.PtrToStringUni(kn.pszName)); NCryptFreeBuffer(pName);
        }
        if (state != IntPtr.Zero) NCryptFreeBuffer(state);
        NCryptFreeObject(hProv); return list;
    }
}
"@
$provName = 'Microsoft Smart Card Key Storage Provider'
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CerPath
$want = [Convert]::ToBase64String(([System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)).ExportParameters($false).Modulus)
$prov = New-Object System.Security.Cryptography.CngProvider($provName)
$found = $null
foreach ($r in ($Readers -split '\|')) {
    $scope = "\\.\$r\"
    foreach ($n in [VscNcEnum]::Enum($provName, $scope)) {
        try {
            $k = [System.Security.Cryptography.CngKey]::Open("$scope$n", $prov, [System.Security.Cryptography.CngKeyOpenOptions]::Silent)
            $mod = [Convert]::ToBase64String((New-Object System.Security.Cryptography.RSACng($k)).ExportParameters($false).Modulus)
            $k.Dispose()
            if ($mod -eq $want) { $found = @{ Reader = $r; Name = $n; Full = "$scope$n" }; break }
        } catch { }
    }
    if ($found) { break }
}
if (-not $found) { Write-Output 'Result=KeyNotFound'; exit 0 }
Write-Output "Reader=$($found.Reader)"; Write-Output "Container=$($found.Name)"
if ($DryRun) { Write-Output 'Result=DryRun'; exit 0 }   # nur suchen (Tests)
# Zertifikat auf die Karte schreiben (nicht still: Windows fragt die Karten-PIN).
try {
    $k = [System.Security.Cryptography.CngKey]::Open($found.Full, $prov, [System.Security.Cryptography.CngKeyOpenOptions]::None)
    $k.SetProperty((New-Object System.Security.Cryptography.CngProperty('SmartCardKeyCertificate', $cert.RawData, [System.Security.Cryptography.CngPropertyOptions]::None)))
    $k.Dispose()
    Write-Output 'WrittenToCard=True'
} catch { Write-Output "Error=Schreiben auf die Karte fehlgeschlagen: $($_.Exception.Message -replace '[\r\n]+', ' ')"; exit 0 }
# In den Benutzerspeicher und mit dem Kartenschlüssel verknüpfen.
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
$store.Open('ReadWrite'); $store.Add($cert); $store.Close()
$rep = & certutil.exe -user -silent -csp $provName -repairstore My $cert.SerialNumber 2>&1
$linked = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
Write-Output "HasPrivateKey=$([bool]($linked -and $linked.HasPrivateKey))"
Write-Output 'Result=Installed'
'@
    Set-Content -Path $scriptPath -Value $installScript -Encoding UTF8

    Write-WizardLog -Message "Direkt-Installation auf die Karte (Suche über den öffentlichen Schlüssel auf: $($readers -join ', '))." -Level Command
    $res = Invoke-ExternalCommand -FilePath 'powershell.exe' -ArgumentList @(
        @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-CerPath', $CerPath, '-Readers', ($readers -join '|')) + $(if ($DryRun) { @('-DryRun') } else { @() })
    ) -TimeoutSeconds $TimeoutSeconds -Silent
    if ($DryRun) {
        $o = @{}; foreach ($line in ("$($res.StdOut)" -split "`r?`n")) { $i = $line.IndexOf('='); if ($i -gt 0) { $o[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
        return [pscustomobject]@{ Success = ($o['Result'] -eq 'DryRun'); Reader = $o['Reader']; Container = $o['Container']; Raw = "$($res.StdOut) $($res.StdErr)".Trim() }
    }
    $out = @{}
    foreach ($line in ("$($res.StdOut)" -split "`r?`n")) { $i = $line.IndexOf('='); if ($i -gt 0) { $out[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
    if ($out['Result'] -eq 'Installed') {
        Write-WizardLog -Message "Zertifikat direkt auf '$($out['Reader'])' (Container $($out['Container'])) geschrieben und im Benutzerspeicher abgelegt (privater Schlüssel verknüpft: $($out['HasPrivateKey']))." -Level Success
        return [pscustomobject]@{ Success = $true; Reader = $out['Reader']; Container = $out['Container'] }
    }
    $why = if ($res.StdErr -eq 'Timeout') { 'Zeitüberschreitung' } elseif ($out['Result'] -eq 'KeyNotFound') { 'kein passender Schlüssel auf den virtuellen Karten gefunden' } elseif ($out['Error']) { $out['Error'] } else { "$($res.StdErr)".Trim() }
    Write-WizardLog -Message "Direkt-Installation fehlgeschlagen: $why" -Level Error
    return [pscustomobject]@{ Success = $false }
}

function Get-IssuedCertificateSummary {
    # Findet das (neueste) frisch ausgestellte Zertifikat. Matcht den Suchbegriff
    # gegen den Subject ODER den UPN im SubjectAltName - wichtig, weil bei
    # Build-from-AD-Templates der Subject nur "CN=adm-t0" ist, das Konto sich aber
    # ueber die UPN (adm-t0@contoso.com) identifiziert, die im SAN steht.
    param([Parameter(Mandatory)][string]$Match)

    $result = Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue | Where-Object { $_.HasPrivateKey } | Where-Object {
        if ($_.Subject -like "*$Match*") { return $true }
        try {
            $san = $_.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
            if ($san -and ($san.Format($true) -like "*$Match*")) { return $true }
        } catch { }
        return $false
    } | Sort-Object NotBefore -Descending | Select-Object -First 1

    return $result | Select-Object Subject, Thumbprint, NotBefore, NotAfter
}

#endregion

#region Sonstige Hilfsfunktionen

function Set-WizardClipboard {
    param([Parameter(Mandatory)][string]$Text)
    Set-Clipboard -Value $Text
    Write-WizardLog -Message "In Zwischenablage kopiert: $Text" -Level Info
}

function Open-WizardFolder {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) {
        $dir = if (Test-Path $Path -PathType Leaf) { Split-Path $Path -Parent } else { $Path }
        Start-Process explorer.exe -ArgumentList "`"$dir`""
    }
}

#endregion

# ============================================================================
#region INTUNE-/PROVISIONIERUNG-HELFER (siehe docs/intune-rollout.md)
# ============================================================================

function Get-VscBootstrapPin {
    # Deterministische QUELL-/Start-PIN aus der GERAETE-SERIENNUMMER fuer die STILLE
    # Provisionierung. App 1 (SYSTEM) legt die Karte damit an; App 2 (Benutzer) leitet
    # DIESELBE PIN ab und belegt sie als "alte PIN" fuer die ERZWUNGENE Aenderung vor -
    # deshalb muss sie reproduzierbar sein, OHNE etwas zu speichern.
    #
    # Warum die Seriennummer: sie ist pro Geraet verschieden UND steht auf dem
    # OEM-Aufkleber/Service-Tag (der Benutzer kann sie notfalls ablesen). Sie ist
    # bewusst KEIN echtes Geheimnis (ohnehin sichtbar) -> in App 2 sofort zwingend
    # aendern. Die vom Benutzer gesetzte ZIEL-PIN ist dagegen NUMERISCH (siehe
    # Enter-SimpleFlow / Show-VscPinChangeDialog -NumericOnly).
    #
    # Regel: alphanumerische Zeichen der Seriennummer, mindestens ein Buchstabe UND eine
    # Ziffer, auf Mindestlaenge auffuellen (max(MinLength, 8): ohne Manager2-Policy
    # verlangt die Basis-API 8), auf 63 kappen. HINWEIS: setzt einen ALPHANUMERISCHEN
    # PIN-Zeichensatz beim ERSTELLEN voraus (Default-Policy erlaubt das) -> auf der
    # Zielhardware pruefen (siehe docs/intune-rollout.md).
    #
    # -Source erlaubt das Uebersteuern (Tests); leer => Seriennummer (WMI), sonst
    # Fallback auf den Computernamen, falls die Seriennummer fehlt/ein OEM-Platzhalter ist.
    param([string]$Source = '', [int]$MinLength = 6)

    $seed = $Source
    if (-not $seed) {
        try {
            $seed = "$((Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim()
        } catch {
            try { $seed = "$((Get-WmiObject -Class Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch { $seed = '' }
        }
    }
    # Unbrauchbare/Platzhalter-Seriennummern -> Fallback Computername (bleibt deterministisch).
    $junk = @('', 'To be filled by O.E.M.', 'Default string', 'System Serial Number', 'None', '0', 'Not Applicable', 'Not Specified', 'Unknown')
    if ($junk -contains $seed) {
        Write-WizardLog -Message "Bootstrap-PIN: Seriennummer unbrauchbar ('$seed') - Fallback auf den Computernamen." -Level Warn
        $seed = $env:COMPUTERNAME
    }
    $clean = ($seed -replace '[^A-Za-z0-9]', '')
    if (-not $clean) { $clean = 'Vsc' }
    if ($clean -notmatch '[A-Za-z]') { $clean += 'A' }
    if ($clean -notmatch '[0-9]')    { $clean += '0' }
    $target = [Math]::Max($MinLength, 8)
    while ($clean.Length -lt $target) { $clean += '0' }
    if ($clean.Length -gt 63) { $clean = $clean.Substring(0, 63) }
    return $clean
}

function Set-VscProvisionMarker {
    # HKLM-Marker fuer die Intune-Erkennung von App 1 (Device/SYSTEM). Braucht Adminrechte.
    param([string]$InstanceId = '')
    try {
        $key = 'HKLM:\SOFTWARE\VSC-Wizard'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'Provisioned'   -Value '1' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name 'ProvisionedAt' -Value (Get-Date -Format 'o') -PropertyType String -Force | Out-Null
        if ($InstanceId) { New-ItemProperty -Path $key -Name 'InstanceId' -Value $InstanceId -PropertyType String -Force | Out-Null }
        return $true
    } catch {
        Write-WizardLog -Message "Provision-Marker (HKLM) konnte nicht gesetzt werden: $($_.Exception.Message)" -Level Warn
        return $false
    }
}

function Get-VscProvisionCardName {
    # Name der per -Provision angelegten Karte - EINE Quelle für Provisionierung und
    # Simple-Modus (der die Karte daran wiedererkennt).
    param($Config)
    $prefix = if ($Config -and $Config.VscNamePrefix) { $Config.VscNamePrefix } else { 'VSC-' }
    return "$prefix$env:COMPUTERNAME"
}

function Find-ProvisionedVsc {
    # Die per -Provision (Intune-App 1) angelegte Karte unter den vorhandenen finden, damit
    # der Simple-Modus sie OHNE Auswahldialog nimmt - auch wenn weitere VSCs existieren.
    # Reihenfolge: (1) InstanceId aus dem HKLM-Marker, (2) Provisionierungs-Name,
    # (3) genau eine VSC vorhanden. Sonst $null (-> Auswahl durch den Benutzer).
    # Ergebnis: @{ Reader; Reason } oder $null.
    param([object[]]$Readers, [string]$ExpectedName)
    $cards = @($Readers | Where-Object { $_.PcscName })
    if ($cards.Count -eq 0) { return $null }
    $markerId = $null
    $markerKey = 'HKLM:\SOFTWARE\VSC-Wizard'
    if (Test-Path $markerKey) {
        $markerId = (Get-ItemProperty -Path $markerKey -ErrorAction SilentlyContinue).InstanceId
    }
    if ($markerId) {
        $hit = @($cards | Where-Object { "$($_.InstanceId)" -eq "$markerId" }) | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Reader = $hit; Reason = "InstanceId aus dem Provisionierungs-Marker ($markerId)" } }
    }
    if ($ExpectedName) {
        $byName = @($cards | Where-Object { $_.FriendlyName -eq $ExpectedName })
        if ($byName.Count -eq 1) { return [pscustomobject]@{ Reader = $byName[0]; Reason = "Name '$ExpectedName'" } }
    }
    if ($cards.Count -eq 1) { return [pscustomobject]@{ Reader = $cards[0]; Reason = 'einzige VSC auf dem Gerät' } }
    return $null
}

function Set-VscEnrollMarker {
    # HKCU-Marker fuer die Intune-Erkennung von App 2 (Benutzerkontext).
    try {
        $key = 'HKCU:\SOFTWARE\VSC-Wizard'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'Enrolled'   -Value '1' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name 'EnrolledAt' -Value (Get-Date -Format 'o') -PropertyType String -Force | Out-Null
        return $true
    } catch {
        Write-WizardLog -Message "Enroll-Marker (HKCU) konnte nicht gesetzt werden: $($_.Exception.Message)" -Level Warn
        return $false
    }
}

#endregion

Export-ModuleMember -Function *
