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
        $cas = foreach ($r in $results) {
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

function New-VirtualSmartCard {
    param(
        [Parameter(Mandatory)][string]$CardName,
        [int]$PinPolicyMinLength = 8
    )

    $tpmvscmgr = Join-Path $env:WINDIR 'System32\tpmvscmgr.exe'
    $vscArgs = @('create', '/name', $CardName, '/AdminKey', 'RANDOM', '/PIN', 'PROMPT', '/PINPolicyMinLength', $PinPolicyMinLength, '/generate')

    if (Test-IsElevated) {
        $result = Invoke-ExternalCommand -FilePath $tpmvscmgr -ArgumentList $vscArgs
        return [pscustomobject]@{ ExitCode = $result.ExitCode; Output = $result.StdOut; Success = $result.Success }
    }

    # tpmvscmgr benoetigt lokale Administratorrechte - nur fuer diesen Schritt wird
    # gezielt ein erhoehter Prozess gestartet, der Rest der App laeuft im normalen
    # Benutzerkontext (wichtig fuer die spaetere Zertifikatsbindung).
    #
    # WICHTIG: tpmvscmgr fragt die PIN interaktiv UEBER DIE KONSOLE ab (kein GUI-
    # Dialog!). Stdout/Stderr duerfen deshalb NICHT umgeleitet werden - sonst laeuft
    # die Prompt-Anzeige ins Leere und der Prozess haengt auf eine Eingabe, die nie
    # ankommt (leeres/unveraendertes Konsolenfenster). tpmvscmgr wird deshalb direkt
    # elevated gestartet (kein umschliessender powershell-Wrapper), damit es sein
    # eigenes, voll interaktives Konsolenfenster bekommt.
    Write-WizardLog -Message "Starte erhoehten Prozess (eigenes Konsolenfenster, PIN-Eingabe dort erforderlich): $tpmvscmgr $($vscArgs -join ' ')" -Level Command

    $proc = Start-Process -FilePath $tpmvscmgr -ArgumentList $vscArgs -Verb RunAs -PassThru -Wait

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Output   = $null
        Success  = ($proc.ExitCode -eq 0)
    }
}

function Get-VirtualSmartCardReaders {
    # tpmvscmgr kennt keinen "list"-Befehl - virtuelle Smartcards werden deshalb
    # ueber die PnP-Geraeteklasse fuer Smartcard-Lesegeraete erkannt, unter der sich
    # auch TPM Virtual Smart Cards (mit dem bei der Erstellung vergebenen Namen als
    # FriendlyName) einordnen.
    try {
        $readers = Get-PnpDevice -Class SmartCardReader -PresentOnly -ErrorAction Stop
        return @($readers | Select-Object -Property FriendlyName, InstanceId, Status)
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

    Write-WizardLog -Message "Starte erhoehten Prozess (eigenes Konsolenfenster): $tpmvscmgr $($vscArgs -join ' ')" -Level Command
    $proc = Start-Process -FilePath $tpmvscmgr -ArgumentList $vscArgs -Verb RunAs -PassThru -Wait

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
    #      Bekannte Einschraenkung: fuer CNG/KSP-Schluessel liefert dieser Weg zwar
    #      den Provider, aber KEIN Reader (NCryptGetProperty mit "Smart Card Reader"
    #      liefert bei der hier verwendeten Virtual-Smart-Card-KSP NTE_NOT_SUPPORTED,
    #      auf echter Hardware getestet) - solche Zertifikate werden deshalb korrekt
    #      als smartcard-gebunden erkannt, aber im Inventar-Dialog unter "weitere
    #      smartcard-gebundene Zertifikate (Lesegeraet nicht zuordenbar)" einsortiert
    #      statt unter ihrem konkreten Lesegeraet.
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
    if ($rsaKey.Key -and $rsaKey.Key.Provider) {
        Write-Output "Provider=$($rsaKey.Key.Provider.Provider)"
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
        [Parameter(Mandatory)][string]$Path
    )

    $sanBlock = ''
    if ($Upn) {
        $sanBlock = @"

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "upn=$Upn&"
"@
    }

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
KeySpec = 1
KeyUsage = 0xA0
MachineKeySet = FALSE
ProviderName = "$CspName"
ProviderType = 1
RequestType = PKCS10
HashAlgorithm = SHA256
$sanBlock
"@

    Set-Content -Path $Path -Value $inf -Encoding Default
    return $Path
}

function New-CertificateSigningRequest {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Upn,
        [string]$CspName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $infPath = Join-Path $OutputDirectory 'request.inf'
    $csrPath = Join-Path $OutputDirectory 'request.csr'
    if (Test-Path $csrPath) { Remove-Item $csrPath -Force }

    New-EnrollmentInfFile -Subject $Subject -Upn $Upn -CspName $CspName -Path $infPath | Out-Null

    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList @('-new', $infPath, $csrPath)
    if ($result.Success -and (Test-Path $csrPath)) {
        Write-WizardLog -Message "CSR erstellt: $csrPath" -Level Success
        return [pscustomobject]@{ Success = $true; CsrPath = $csrPath }
    }
    Write-WizardLog -Message 'CSR-Erstellung fehlgeschlagen.' -Level Error
    return [pscustomobject]@{ Success = $false; CsrPath = $null }
}

function Submit-CertificateSigningRequest {
    param(
        [Parameter(Mandatory)][string]$CsrPath,
        [Parameter(Mandatory)][string]$CAConfig,
        [Parameter(Mandatory)][string]$TemplateName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $cerPath = Join-Path $OutputDirectory 'certnew.cer'
    if (Test-Path $cerPath) { Remove-Item $cerPath -Force }

    $result = Invoke-ExternalCommand -FilePath 'certreq.exe' -ArgumentList @(
        '-submit', '-config', $CAConfig, '-attrib', "CertificateTemplate:$TemplateName", $CsrPath, $cerPath
    )

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
