<#
    VscWizard.Core.psm1

    Nicht-GUI-Logik fuer den VSC-Wizard: Konfiguration, Logging, Prozessausfuehrung,
    Erkennung von Domaenen-/TPM-Status sowie die eigentlichen Schritte zur Erstellung
    einer virtuellen Smartcard (tpmvscmgr) und zur Zertifikatsbeantragung (certreq).
#>

#Requires -Version 5.1

# Wenn dieses Skript aus einer PowerShell-7(pwsh)-Umgebung heraus gestartet wird (z.B.
# aus einem pwsh-Terminal oder von einem Prozess, der pwsh's PSModulePath-Eintraege
# geerbt hat), steht "C:\Program Files\PowerShell\7\Modules" VOR dem nativen
# Windows-PowerShell-5.1-Modulpfad in $env:PSModulePath. Windows PowerShell 5.1 laedt
# dann beim Autoloading eingebauter Module die dortige, fuer PowerShell 7 gebaute
# Variante statt der eigenen - betroffen sind nicht nur Microsoft.PowerShell.Utility
# (Import-PowerShellDataFile fehlt dann, config.psd1 wird nie geladen), sondern auch
# Microsoft.PowerShell.Security: dessen falsch geladene Variante registriert das
# "Cert:"-Laufwerk nicht, wodurch Get-ChildItem Cert:\CurrentUser\My mit "Ein Laufwerk
# mit dem Namen 'Cert' ist nicht vorhanden" fehlschlaegt - auf echter Hardware
# reproduziert, dadurch zeigte das Smartcard-Inventar trotz vorhandener Zertifikate
# konsequent 0 Eintraege. Fix: die nativen Module explizit ueber den vollen Pfad laden
# (umgeht die PSModulePath-Suche) - fuer jedes eingebaute Modul, von dem dieses Skript
# abhaengt.
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
        # Nicht erneut werfen: ein leeres $data fuehrt dazu, dass der Wizard die Werte
        # als fehlend behandelt und automatisch den Einstellungen-Tab oeffnet (siehe
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
        if ($value -is [array]) {
            $items = ($value | ForEach-Object { "'$_'" }) -join ', '
            $lines += "    $key = @($items)"
        } else {
            $lines += "    $key = '$value'"
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

# Ein begonnener Antrag ueberlebt einen Wizard-Neustart als key=value-Datei im
# Arbeitsverzeichnis: nach jedem Meilenstein (CSR erstellt, Antrag eingereicht/
# wartet auf Genehmigung) gespeichert, nach erfolgreicher Zertifikatsuebernahme
# geloescht. Windows haelt den offenen certreq-Antrag ohnehin im REQUEST-Store
# des Benutzers - hier geht es nur um den Wizard-Kontext (RequestId, Kartenname,
# Pfade), der sonst beim Schliessen verloren ginge.

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
        [ValidateSet('Info', 'Command', 'Output', 'Error', 'Success')][string]$Level = 'Info'
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

#region Prozessausfuehrung

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location),
        # 0 = kein Timeout (Standardverhalten). Bei Ueberschreitung wird der Prozess beendet
        # und Success=$false zurueckgegeben - wichtig fuer Netzwerkaufrufe (z.B. certutil -ping)
        # gegen eventuell nicht erreichbare Server.
        [int]$TimeoutSeconds = 0,
        # Fuer haeufige interne Hintergrund-Aufrufe (z.B. ein Lookup pro Zertifikat), die fuer
        # den Nutzer kein sinnvolles Log-Ereignis darstellen und das Log/Diagnose-Panel sonst
        # mit vielen kleinen Eintraegen zumuellen wuerden.
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
    [void]$proc.Start()

    if ($TimeoutSeconds -gt 0) {
        # Asynchrones Lesen startet VOR WaitForExit, damit die Pipes laufend geleert werden
        # und ein volles Output-Puffer nicht zum Deadlock mit dem Kindprozess fuehrt.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            if (-not $Silent) { Write-WizardLog -Message "$FilePath $quotedArgs (Zeitueberschreitung nach $TimeoutSeconds s)" -Level Error }
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'Timeout'; Success = $false }
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
    } else {
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
    }

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
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        return [pscustomobject]@{
            Present = [bool]$tpm.TpmPresent
            Ready   = [bool]$tpm.TpmReady
            Enabled = [bool]$tpm.TpmEnabled
        }
    } catch {
        return [pscustomobject]@{ Present = $false; Ready = $false; Enabled = $false }
    }
}

function Get-DomainJoinState {
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
    # Bestes-Effort-Vorschlag fuer die LDAP-Ziel-Domaene der PKI-Discovery.
    # $env:USERDNSDOMAIN ist bei echten Domain-Logons gesetzt, bei Entra-joined/
    # Workgroup-Rechnern i.d.R. NICHT (kein klassischer Domain-Logon). Fallback:
    # Domaenenanteil der UPN - Achtung, kann vom tatsaechlichen AD-DNS-Namen
    # abweichen, wenn ein abweichender UPN-Suffix konfiguriert ist; deshalb nur
    # ein Vorschlag, manuell in den Einstellungen ueberschreibbar.
    if ($env:USERDNSDOMAIN) { return $env:USERDNSDOMAIN }
    $upn = Get-CurrentUpn
    if ($upn -and $upn.Contains('@')) { return $upn.Split('@')[1] }
    return ''
}

#endregion

#region PKI-Erreichbarkeit (fuer Entra-joined/Workgroup-Rechner mit Netzwerkpfad ins Firmennetz,
# z.B. per Cloud Kerberos Trust + VPN/Private Access - Kerberos allein ersetzt keine Netzwerksicht)

function Find-EnterpriseCAs {
    # Fragt die Enterprise-CAs direkt aus der AD-Konfigurationspartition ab
    # (CN=Enrollment Services,CN=Public Key Services,CN=Services,CN=Configuration,...),
    # genau der Mechanismus, den auch die Windows-Zertifikatsanforderung intern nutzt.
    #
    # WICHTIG: Ohne -Server versucht .NET ein "serverless" LDAP-Binding, das auf lokal
    # zwischengespeicherten Domain-Join-Informationen beruht (DsGetDcName). Ein
    # Entra-joined/Workgroup-Rechner ist NICHT domaenen-gebunden und hat diese
    # Informationen i.d.R. nicht - selbst mit gueltigem Kerberos-Ticket (Cloud
    # Kerberos Trust) schlaegt serverless Binding dann fehl. Fuer diesen Fall
    # -Server auf eine DNS-Domaene oder einen konkreten DC/Servernamen setzen.
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
            $out.Error = "Keine Antwort von $rootPath (configurationNamingContext leer)."
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
        # Bind gegen eine unerwartete Domaene) wuerfen bei ['cn'][0] sonst
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
            $out.Error = 'LDAP-Verbindung erfolgreich, aber keine registrierten CAs (pKIEnrollmentService) gefunden.'
        }
    } catch {
        $out.Error = $_.Exception.Message
    }
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
    # CAs auch Diagnoseinformationen zurueck (LDAP-Fehler, per LDAP gefundene aber per
    # RPC nicht erreichbare CAs), damit ein Fehlschlag nachvollziehbar ist statt nur
    # "nichts gefunden". Gedacht zum Aufruf in einem Start-Job mit Wait-Job -Timeout,
    # da sowohl LDAP- als auch RPC-Aufrufe bei nicht erreichbaren Servern lange
    # haengen koennen.
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

#endregion

#region Virtuelle Smartcard

function Get-RecentVscEventLog {
    # tpmvscmgr's eigentliche Fehlerausgabe laeuft ueber die interaktive Konsole und
    # kann deshalb NICHT umgeleitet/mitgeloggt werden (siehe New-VirtualSmartCard).
    # Windows protokolliert die VSC-Operationen aber zusaetzlich im Event-Log - von
    # dort holen wir nach einem Versuch die relevanten Eintraege, um im Fehlerfall
    # einen aussagekraeftigen Grund zeigen zu koennen statt nur eines Exit-Codes.
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

function New-VirtualSmartCard {
    # Erstellt eine virtuelle Smartcard ueber die COM-API (ITpmVirtualSmartCardManager)
    # statt ueber tpmvscmgr.exe. Vorteil: die PIN wird in einem echten, maskierten
    # GUI-Dialog abgefragt und der API direkt uebergeben - kein rohes Konsolenfenster,
    # keine ins Leere laufende PIN-Abfrage, und ein echter HRESULT als Fehlersignal.
    #
    # Die COM-Aufrufe erfordern lokale Administratorrechte UND muessen in kompiliertem
    # C# erfolgen (PowerShell kann diese reinen IUnknown-Interfaces nicht aufrufen).
    # Der Helfer (VscWizard.CreateHelper.cs) wird dafuer zur Laufzeit mit dem csc.exe
    # des .NET Framework zu einer /target:winexe-Anwendung kompiliert und eleviert
    # gestartet: eine Fenster-Exe hat KEIN Konsolenfenster - es erscheint
    # ausschliesslich der PIN-Dialog (die PIN verlaesst den elevierten Prozess nie).
    # csc erzeugt architekturneutrales IL (AnyCPU), das beim Start nativ laeuft
    # (auf ARM64 als ARM64-Prozess) - der native TPM-COM-Server ist damit immer
    # erreichbar, unabhaengig davon, aus welchem Prozess kompiliert wurde.
    #
    # Exe und Ergebnisdatei liegen in C:\Users\Public: bei einer Ueber-die-Schulter-
    # Elevation (der angemeldete Benutzer ist kein Admin, es wird ein separates
    # Admin-Konto verwendet) kann dieses Admin-Konto das Benutzerprofil des
    # angemeldeten Benutzers (z.B. OneDrive-Ordner) nicht zwangslaeufig lesen -
    # C:\Users\Public ist fuer beide Konten zugaenglich.
    param(
        [Parameter(Mandatory)][string]$CardName,
        # Wird ueber ITpmVirtualSmartCardManager2::CreateVirtualSmartCardWithPinPolicy
        # durchgesetzt (siehe CreateHelper); ohne diese Schnittstelle faellt der Helfer
        # auf die Basis-API mit Minimum 8 zurueck und passt den PIN-Dialog entsprechend an.
        [int]$PinPolicyMinLength = 6
    )

    $helperSource = Join-Path $PSScriptRoot 'VscWizard.CreateHelper.cs'
    if (-not (Test-Path $helperSource)) {
        $msg = "Helfer-Quelldatei nicht gefunden: $helperSource"
        Write-WizardLog -Message $msg -Level Error
        return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
    }

    $csc = Get-FrameworkCscPath
    if (-not $csc) {
        $msg = 'csc.exe des .NET Framework nicht gefunden (Microsoft.NET\Framework*\v4.0.30319).'
        Write-WizardLog -Message $msg -Level Error
        return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
    }

    $publicDir = Join-Path $env:SystemDrive 'Users\Public'
    $token = [guid]::NewGuid().ToString('N')
    $helperExe = Join-Path $publicDir "vscwizard-createhelper-$token.exe"
    $resultPath = Join-Path $publicDir "vscwizard-createresult-$token.txt"

    $compile = Invoke-ExternalCommand -FilePath $csc -ArgumentList @(
        '/nologo', '/target:winexe', "/out:$helperExe",
        '/r:System.dll', '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll',
        $helperSource) -TimeoutSeconds 120 -Silent
    if (-not $compile.Success -or -not (Test-Path $helperExe)) {
        $detail = "$($compile.StdOut) $($compile.StdErr)".Trim()
        $msg = "Helfer konnte nicht kompiliert werden: $detail"
        Write-WizardLog -Message $msg -Level Error
        return [pscustomobject]@{ Success = $false; InstanceId = $null; Message = $msg }
    }

    # Argumente als fertig quotierter String (Start-Process quotiert Array-Elemente
    # in Windows PowerShell 5.1 NICHT selbst - Kartennamen mit Leerzeichen wuerden
    # sonst zerfallen).
    $exeArgs = "`"$CardName`" $PinPolicyMinLength `"$resultPath`""

    Write-WizardLog -Message "Erstelle virtuelle Smartcard '$CardName' ueber die COM-API (elevierter Helfer ohne Konsolenfenster, PIN-Dialog dort)." -Level Command

    try {
        if (Test-IsElevated) {
            Start-Process -FilePath $helperExe -ArgumentList $exeArgs -Wait -ErrorAction Stop
        } else {
            # -Verb RunAs fordert die Elevation an (UAC); der Helfer laeuft dann als
            # Admin und zeigt seinen eigenen PIN-Dialog.
            Start-Process -FilePath $helperExe -ArgumentList $exeArgs -Verb RunAs -Wait -ErrorAction Stop
        }
    } catch {
        Remove-Item $helperExe -ErrorAction SilentlyContinue
        $msg = "Erhoehter Prozess konnte nicht gestartet werden (UAC abgelehnt?): $($_.Exception.Message)"
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
        $res.Message = 'Kein Ergebnis vom elevierten Helfer erhalten (Prozess evtl. abgebrochen).'
    }
    Remove-Item $helperExe, $resultPath -ErrorAction SilentlyContinue

    $success = ($res.Success -eq 'True')
    $pcscName = $null
    if ($success) {
        # PC/SC-Namen der frisch erstellten Karte aufloesen ("Microsoft Virtual Smart
        # Card N"): unter DIESEM Namen erscheint die Karte in Windows-Kartenauswahl-
        # Dialogen (z.B. bei certreq -new) - der vergebene FriendlyName taucht dort
        # NICHT auf, und die PC/SC-Nummer stimmt nicht mit der Nummer in der
        # PnP-InstanceId ueberein. Kurz wiederholen, da die PnP-Registrierung nach
        # der Erstellung einen Moment brauchen kann.
        for ($attempt = 0; $attempt -lt 5 -and -not $pcscName; $attempt++) {
            if ($attempt -gt 0) { Start-Sleep -Milliseconds 800 }
            $reader = @(Get-VirtualSmartCardReaders) | Where-Object { $_.InstanceId -eq $res.InstanceId } | Select-Object -First 1
            if ($reader -and $reader.PcscName) { $pcscName = $reader.PcscName }
        }
        $policyNote = if ($res['PinPolicyUsed'] -eq 'True') { "PIN-Policy via Manager2, Mindestlaenge $PinPolicyMinLength" } else { 'Basis-API, PIN-Mindestlaenge 8' }
        $pcscNote = if ($pcscName) { "; erscheint in Windows-Kartendialogen als '$pcscName'" } else { '' }
        Write-WizardLog -Message "Virtuelle Smartcard '$CardName' erstellt (InstanceId $($res.InstanceId); $policyNote$pcscNote)." -Level Success
    } else {
        Write-WizardLog -Message "Erstellung fehlgeschlagen: $($res.Message) $(if ($res.HResult) { "(HRESULT $($res.HResult))" })" -Level Error
    }
    return [pscustomobject]@{
        Success    = $success
        InstanceId = $res.InstanceId
        HResult    = $res.HResult
        Message    = $res.Message
        PcscName   = $pcscName
    }
}

function Get-VirtualSmartCardReaders {
    # tpmvscmgr kennt keinen "list"-Befehl - virtuelle Smartcards werden deshalb
    # ueber die PnP-Geraeteklasse fuer Smartcard-Lesegeraete erkannt, unter der sich
    # auch TPM Virtual Smart Cards (mit dem bei der Erstellung vergebenen Namen als
    # FriendlyName) einordnen.
    #
    # PcscName: der PC/SC-Lesegeraetename ("Microsoft Virtual Smart Card N"), unter dem
    # ein Zertifikat seinen Schluessel meldet (CNG-Property "SmartCardReader", siehe
    # Get-SmartCardCngProviderInfo). Der PnP-FriendlyName (der bei der Erstellung
    # vergebene VSC-Name, z.B. "VSC-T0") und dieser PC/SC-Name teilen keinen gemeinsamen
    # Text - die Verknuepfung steht aber deterministisch in der PnP-Child-/BusRelations-
    # Eigenschaft des Lesegeraets als Token "Microsoft_Virtual_Smart_Card_N" (die
    # SCFILTER-Kindknoten-Kennung). Darueber laesst sich jedes Zertifikat exakt seinem
    # Lesegeraet zuordnen, statt es in den Sammel-Eintrag "nicht zuordenbar" zu werfen.
    try {
        $readers = Get-PnpDevice -Class SmartCardReader -PresentOnly -ErrorAction Stop
        return @($readers | ForEach-Object {
            $pcscName = $null
            try {
                $children = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop).Data
                foreach ($child in @($children)) {
                    if ("$child" -match 'Microsoft_Virtual_Smart_Card_(\d+)') {
                        $pcscName = "Microsoft Virtual Smart Card $($Matches[1])"
                        break
                    }
                }
            } catch { }
            [pscustomobject]@{
                FriendlyName = $_.FriendlyName
                InstanceId   = $_.InstanceId
                Status       = $_.Status
                PcscName     = $pcscName
            }
        })
    } catch {
        return @()
    }
}

function Remove-VirtualSmartCard {
    # tpmvscmgr destroy /instance <InstanceId> - die InstanceId ist dieselbe
    # PnP-Geraetepfad-Kennung, die auch Get-VirtualSmartCardReaders liefert
    # (z.B. "ROOT\SMARTCARDREADER\0000"). Unwiderruflich: alle auf der Karte
    # gespeicherten Schluessel gehen dabei verloren - Bestaetigung ist Aufgabe der GUI.
    param([Parameter(Mandatory)][string]$InstanceId)

    $tpmvscmgr = Join-Path $env:WINDIR 'System32\tpmvscmgr.exe'
    $vscArgs = @('destroy', '/instance', $InstanceId)

    if (Test-IsElevated) {
        $result = Invoke-ExternalCommand -FilePath $tpmvscmgr -ArgumentList $vscArgs
        return [pscustomobject]@{ ExitCode = $result.ExitCode; Success = $result.Success }
    }

    # -WindowStyle Hidden: tpmvscmgr destroy braucht keine Interaktion - ShellExecute
    # startet die Konsole mit SW_HIDE, es blitzt also nicht einmal ein Fenster auf.
    Write-WizardLog -Message "Starte erhoehten Prozess (verstecktes Fenster): $tpmvscmgr $($vscArgs -join ' ')" -Level Command
    $proc = Start-Process -FilePath $tpmvscmgr -ArgumentList $vscArgs -Verb RunAs -PassThru -Wait -WindowStyle Hidden

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Success  = ($proc.ExitCode -eq 0)
    }
}

function Get-SmartCardCertificateInfo {
    # Ermittelt Provider-/Reader-/Hardware-Info fuer den privaten Schluessel eines
    # Zertifikats ueber mehrere Wege, da je nach CSP/KSP (Legacy-CAPI vs. CNG)
    # unterschiedliche .NET-APIs greifen - EIN Weg allein deckt nicht alle Faelle ab:
    #   1. .PrivateKey.CspKeyContainerInfo - klassischer Weg fuer Legacy-CAPI-CSPs
    #      (z.B. "Microsoft Base Smart Card Crypto Provider", der Default dieses
    #      Wizards). Wirft bei rein CNG-basierten Schluesseln typischerweise eine
    #      Exception.
    #   2. GetRSAPrivateKey() liefert je nach Schluesseltyp ENTWEDER RSACng (CNG,
    #      Provider ueber .Key.Provider) ODER RSACryptoServiceProvider (Legacy-CAPI,
    #      Provider ueber .CspKeyContainerInfo wie bei Weg 1) - beide Faelle werden
    #      hier unterschieden, da ein direkter .Key-Zugriff auf einem
    #      RSACryptoServiceProvider-Objekt schlicht $null liefert (kein Fehler, aber
    #      auch kein Ergebnis - das war der Grund, warum bisher gar keine Zertifikate
    #      gefunden wurden).
    #      WICHTIG: GetRSAPrivateKey() ist in .NET eine C#-Extension-Method
    #      (RSACertificateExtensions), keine Instanzmethode - PowerShells Dot-Notation
    #      ($Certificate.GetRSAPrivateKey()) loest Extension-Methods NICHT auf und
    #      wirft "does not contain a method named 'GetRSAPrivateKey'". Muss deshalb
    #      als statischer Aufruf erfolgen (siehe unten) - das war der eigentliche
    #      Grund, warum auf echten CNG-Zertifikaten (der Normalfall auf aktuellen
    #      Windows-Versionen) bislang GAR KEINE Zertifikate erkannt wurden.
    #      Reader-Zuordnung fuer CNG/KSP-Schluessel: ueber die NCrypt-Property
    #      "SmartCardReader" (der korrekte Name OHNE Leerzeichen - "Smart Card Reader"
    #      MIT Leerzeichen liefert NTE_NOT_SUPPORTED, das war urspruenglich der
    #      Trugschluss "Reader nicht ermittelbar"). Liefert den PC/SC-Namen
    #      ("Microsoft Virtual Smart Card N"), der ueber Get-VirtualSmartCardReaders
    #      (PcscName) dem PnP-Lesegeraet zugeordnet wird.
    # HardwareDevice (falls ermittelbar) ist ein zusaetzliches, von der Provider-Namen-
    # Heuristik unabhaengiges Signal.
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $info = [pscustomobject]@{ Provider = $null; Reader = $null; IsHardware = $false; DetectionError = $null }

    try {
        $capiKey = $Certificate.PrivateKey
        if ($capiKey -and $capiKey.CspKeyContainerInfo) {
            $info.Provider = $capiKey.CspKeyContainerInfo.ProviderName
            $info.Reader = $capiKey.CspKeyContainerInfo.Reader
            $info.IsHardware = [bool]$capiKey.CspKeyContainerInfo.HardwareDevice
        }
    } catch {
        $info.DetectionError = $_.Exception.Message
    }

    if (-not $info.Provider) {
        $cngResult = Get-SmartCardCngProviderInfo -Thumbprint $Certificate.Thumbprint
        if ($cngResult.TimedOut) {
            $info.DetectionError = 'Zeitueberschreitung beim CNG-Schluesselzugriff (evtl. verweist das Zertifikat auf eine bereits geloeschte virtuelle Smartcard).'
        } elseif ($cngResult.Provider) {
            $info.Provider = $cngResult.Provider
            $info.Reader = $cngResult.Reader
            $info.IsHardware = $cngResult.IsHardware
        } elseif ($cngResult.DetectionError -and -not $info.DetectionError) {
            $info.DetectionError = $cngResult.DetectionError
        }
    }

    return $info
}

function Get-SmartCardCngProviderInfo {
    # GetRSAPrivateKey().Key.Provider (CNG-Weg, siehe Get-SmartCardCertificateInfo)
    # kann bei einem Zertifikat, dessen zugehoerige virtuelle Smartcard bereits
    # geloescht wurde (Schluesselcontainer verweist auf eine nicht mehr vorhandene
    # Karte), UNBEGRENZT blockieren - Windows' Smartcard-Ressourcenverwaltung wartet
    # in diesem Fall auf das (nie kommende) Einstecken der Karte. Auf echter Hardware
    # reproduziert: virtuelle Smartcard geloescht, zugehoeriges Zertifikat blieb im
    # Speicher, GetRSAPrivateKey() haengt beim naechsten Aufruf fest und blockiert
    # damit den GESAMTEN Wizard (Inventar-Dialog oeffnet sich nie). Deshalb NIE direkt
    # im GUI-Prozess aufrufen - stattdessen in einem separaten, per Timeout zwangs-
    # beendbaren Prozess (Invoke-ExternalCommand toetet den Prozess zuverlaessig bei
    # Zeitueberschreitung, im Gegensatz zu einem im selben Prozess haengenden Thread).
    param(
        [Parameter(Mandatory)][string]$Thumbprint,
        [int]$TimeoutSeconds = 3
    )

    # Dieses Skript laeuft als EIGENER Prozess (siehe unten) und importiert Core.psm1
    # deshalb NICHT - braucht den nativen-Module-Fix vom Kopf dieser Datei also
    # eigenstaendig, sonst fehlt in genau diesem Kindprozess das "Cert:"-Laufwerk
    # (gleiche Ursache wie beim Hauptprozess, siehe Kommentar oben in dieser Datei).
    # Immer neu schreiben (nicht nur bei Nichtvorhandensein) - sonst wuerde eine
    # bereits von einer AELTEREN Skriptversion angelegte Datei liegen bleiben und
    # Aenderungen an diesem Lookup-Skript wuerden nie wirksam.
    $scriptPath = Join-Path (Get-WizardWorkingDir) 'cng-provider-lookup.ps1'
    $lookupScript = @'
param([Parameter(Mandatory)][string]$Thumbprint)
foreach ($nativeModuleName in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Security', 'Microsoft.PowerShell.Management')) {
    $nativeModulePath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\Modules\$nativeModuleName\$nativeModuleName.psd1"
    if (Test-Path $nativeModulePath) {
        Import-Module $nativeModulePath -Force -ErrorAction SilentlyContinue
    }
}
$cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction Stop
$rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
if ($rsaKey -is [System.Security.Cryptography.RSACng]) {
    $k = $rsaKey.Key
    if ($k -and $k.Provider) {
        Write-Output "Provider=$($k.Provider.Provider)"
        # NCrypt-Property "SmartCardReader" (ohne Leerzeichen!) - PC/SC-Lesegeraetename.
        # Fehlt bei Nicht-Smartcard-CNG-Schluesseln; dann still ueberspringen.
        try {
            $prop = $k.GetProperty('SmartCardReader', [System.Security.Cryptography.CngPropertyOptions]::None)
            $readerName = [System.Text.Encoding]::Unicode.GetString($prop.GetValue()).TrimEnd([char]0)
            if ($readerName) { Write-Output "Reader=$readerName" }
        } catch { }
    }
} elseif ($rsaKey -and $rsaKey.CspKeyContainerInfo) {
    Write-Output "Provider=$($rsaKey.CspKeyContainerInfo.ProviderName)"
    Write-Output "Reader=$($rsaKey.CspKeyContainerInfo.Reader)"
    Write-Output "IsHardware=$([bool]$rsaKey.CspKeyContainerInfo.HardwareDevice)"
}
'@
    Set-Content -Path $scriptPath -Value $lookupScript -Encoding UTF8

    $result = Invoke-ExternalCommand -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Thumbprint', $Thumbprint
    ) -TimeoutSeconds $TimeoutSeconds -Silent

    $info = [pscustomobject]@{ Provider = $null; Reader = $null; IsHardware = $false; DetectionError = $null; TimedOut = $false }
    if ($result.StdErr -eq 'Timeout') {
        $info.TimedOut = $true
        return $info
    }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^Provider=(.*)$') { $info.Provider = $Matches[1] }
        elseif ($line -match '^Reader=(.*)$') { $info.Reader = $Matches[1] }
        elseif ($line -match '^IsHardware=(.*)$') { $info.IsHardware = [bool]::Parse($Matches[1]) }
    }
    if (-not $info.Provider -and $result.StdErr) { $info.DetectionError = $result.StdErr.Trim() }
    return $info
}

function Get-SmartCardCertificates {
    # Alle Zertifikate im Benutzer-Zertifikatsspeicher mit privatem Schluessel.
    # IsSmartCard=true, wenn Provider-Name "Smart Card" enthaelt ODER die CSP-Info
    # das Geraet als Hardware-Schluessel meldet. Zertifikate mit privatem Schluessel,
    # die NICHT sicher als Smartcard erkannt wurden, werden trotzdem zurueckgegeben
    # (samt Provider/DetectionError) statt sie stillschweigend zu verwerfen - damit
    # eine unvollstaendige Erkennung in der GUI sichtbar/diagnostizierbar bleibt statt
    # einfach nichts anzuzeigen.
    param([string]$StoreLocation = 'Cert:\CurrentUser\My')

    $certs = $null
    try {
        $certs = Get-ChildItem -Path $StoreLocation -ErrorAction Stop
    } catch {
        Write-WizardLog -Message "Get-ChildItem $StoreLocation fehlgeschlagen: $($_.Exception.Message)" -Level Error
    }
    Write-WizardLog -Message "Get-SmartCardCertificates: Get-ChildItem $StoreLocation lieferte $(@($certs).Count) Eintraege (davon $(@($certs | Where-Object HasPrivateKey).Count) mit privatem Schluessel)." -Level Info
    $results = foreach ($cert in $certs) {
        if (-not $cert.HasPrivateKey) { continue }
        $info = Get-SmartCardCertificateInfo -Certificate $cert
        $isSmartCard = $info.IsHardware -or ($info.Provider -and $info.Provider -match 'Smart Card')
        [pscustomobject]@{
            Subject        = $cert.Subject
            Thumbprint     = $cert.Thumbprint
            NotBefore      = $cert.NotBefore
            NotAfter       = $cert.NotAfter
            Provider       = $info.Provider
            Reader         = $info.Reader
            IsSmartCard    = [bool]$isSmartCard
            DetectionError = $info.DetectionError
        }
    }
    return @($results)
}

#endregion

#region Zertifikatsanforderung (certreq)

function New-EnrollmentInfFile {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Upn,
        [string]$CspName = 'Microsoft Base Smart Card Crypto Provider',
        [Parameter(Mandatory)][string]$Path,
        # Enroll on Behalf Of: setzt das Konto, FUER das ausgestellt wird
        # (z.B. "CONTOSO\adm.mustermann"). Ist es gesetzt, wird ein PKCS7-Antrag
        # erzeugt, der spaeter mit dem Enrollment-Agent-Zertifikat co-signiert wird.
        [string]$RequesterName,
        # Fuer den EA-Zertifikatsantrag selbst: das Template steuert die EKU; hier
        # nur die Key-Parameter. Fuer ein Software-EA-Zertifikat wird der
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
    # "Microsoft Base Smart Card Crypto Provider"). Fuer einen CNG-KSP (z.B.
    # "Microsoft Smart Card Key Storage Provider" oder "Microsoft Software Key
    # Storage Provider") duerfen sie NICHT gesetzt werden, sonst lehnt certreq die
    # Kombination ab - dort waehlt certreq den CNG-Pfad allein anhand des
    # Provider-Namens. Heuristik: "Key Storage Provider" im Namen = KSP.
    $isKsp = $CspName -match 'Key Storage Provider'
    $capiBlock = if ($isKsp) { '' } else { "KeySpec = 1`r`nProviderType = 1`r`n" }

    $requestType = if ($RequesterName) { 'PKCS7' } else { 'PKCS10' }
    $requesterBlock = if ($RequesterName) { "RequesterName = `"$RequesterName`"`r`n" } else { '' }
    # Bei EOBO (PKCS7) gehoert der Template-Verweis IN den Antrag; bei PKCS10
    # uebergibt Submit-CertificateSigningRequest ihn spaeter per -attrib.
    $templateBlock = if ($RequesterName -and $TemplateName) { "`r`n[RequestAttributes]`r`nCertificateTemplate = $TemplateName`r`n" } else { '' }

    # Hinweis: KeyLength/KeyUsage/HashAlgorithm sind gaengige Defaults fuer
    # Smartcard-Logon-Zertifikate und koennen bei Bedarf an das eigene
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
        # gehoeren in den PKCS7-Antrag, und der Antrag wird mit dem
        # Enrollment-Agent-Zertifikat (Thumbprint) co-signiert.
        [string]$RequesterName,
        [string]$TemplateName,
        [string]$SigningCertThumbprint
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $infPath = Join-Path $OutputDirectory 'request.inf'
    # PKCS7-Antraege (EOBO) tragen zur Klarheit eine andere Endung.
    $isEobo = [bool]$RequesterName
    $csrPath = Join-Path $OutputDirectory $(if ($isEobo) { 'request.p7' } else { 'request.csr' })
    if (Test-Path $csrPath) { Remove-Item $csrPath -Force }

    New-EnrollmentInfFile -Subject $Subject -Upn $Upn -CspName $CspName -Path $infPath -RequesterName $RequesterName -TemplateName $TemplateName | Out-Null

    # -cert <Thumbprint>: certreq signiert den PKCS7-Antrag mit diesem
    # Enrollment-Agent-Zertifikat (der EA-Schluessel bleibt in seinem Store/auf
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
    # Schluessel - genau die, mit denen sich Enroll-on-Behalf-Of-Antraege
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
        # Bei EOBO/PKCS7-Antraegen leer lassen: das Template steht dann bereits im
        # Antrag (RequestAttributes) - ein zusaetzliches -attrib waere redundant.
        [string]$TemplateName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $cerPath = Join-Path $OutputDirectory 'certnew.cer'
    if (Test-Path $cerPath) { Remove-Item $cerPath -Force }

    $submitArgs = @('-submit', '-config', $CAConfig)
    if ($TemplateName) { $submitArgs += @('-attrib', "CertificateTemplate:$TemplateName") }
    $submitArgs += @($CsrPath, $cerPath)
    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList $submitArgs

    $requestId = $null
    if ($result.StdOut -match 'RequestId:\s*(\d+)') { $requestId = $Matches[1] }

    if ($result.StdOut -match 'Certificate Pending' -or $result.StdOut -match 'Taken Under Submission') {
        Write-WizardLog -Message "Antrag eingereicht, wartet auf Genehmigung (RequestId: $requestId)." -Level Info
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

    $cerPath = Join-Path $OutputDirectory 'certnew.cer'
    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList @('-retrieve', '-config', $CAConfig, $RequestId, $cerPath)

    if ($result.Success -and (Test-Path $cerPath)) {
        Write-WizardLog -Message "Zertifikat abgerufen: $cerPath" -Level Success
        return [pscustomobject]@{ Success = $true; CerPath = $cerPath }
    }
    return [pscustomobject]@{ Success = $false; CerPath = $null }
}

function Complete-CertificateEnrollment {
    param([Parameter(Mandatory)][string]$CerPath)

    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList @('-accept', $CerPath)
    if ($result.Success) {
        Write-WizardLog -Message 'Zertifikat wurde erfolgreich auf der Smartcard hinterlegt.' -Level Success
    } else {
        Write-WizardLog -Message 'Zertifikatsuebernahme fehlgeschlagen.' -Level Error
    }
    return [pscustomobject]@{ Success = $result.Success }
}

function Get-IssuedCertificateSummary {
    param([Parameter(Mandatory)][string]$SubjectContains)

    $certs = Get-ChildItem -Path 'Cert:\CurrentUser\My' | Where-Object {
        $_.Subject -like "*$SubjectContains*" -and $_.HasPrivateKey
    } | Sort-Object NotBefore -Descending

    return $certs | Select-Object -First 1 | Select-Object Subject, Thumbprint, NotBefore, NotAfter
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

Export-ModuleMember -Function *
