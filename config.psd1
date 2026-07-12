@{
    # CA-Konfigurationsstring im Format "Servername\CA-Name" (siehe: certutil -config -).
    # Leer ausgeliefert - im Tab "Einstellungen" eintragen (manuell oder per
    # "PKI automatisch erkennen"). Solange leer, oeffnet der Wizard beim Start
    # automatisch die Einstellungen.
    CAConfig      = ''

    # Name des Zertifikatstemplates fuer Smartcard-Logon-Zertifikate, das in der
    # eigenen PKI-Umgebung existieren muss (genau eines - eine VSC-Anmeldung
    # verwendet immer nur ein Template). Leer ausgeliefert, siehe CAConfig.
    Template      = ''

    # Praefix fuer automatisch vorgeschlagene Namen virtueller Smartcards.
    VscNamePrefix = 'VSC'

    # Provider-Name der virtuellen Smartcard (Standard fuer TPM Virtual Smart Cards).
    CspName       = 'Microsoft Base Smart Card Crypto Provider'

    # Plan B: Name/Adresse eines Servers mit Sicht auf die Zertifizierungsstelle,
    # auf den sich der Zielbenutzer per RDP verbindet, um den CSR einzureichen.
    # Leer ausgeliefert - im Tab "Einstellungen" eintragen.
    RdpJumpServer = ''

    # AD-Domaene (DNS-Name) oder konkreter Domain Controller/Server, gegen den die
    # automatische PKI-Erkennung (LDAP) bindet. Auf domaenen-gebundenen Rechnern
    # meist nicht noetig (serverloses LDAP-Binding funktioniert dort von selbst).
    # Auf Entra-joined/Workgroup-Rechnern i.d.R. erforderlich, da dort kein
    # Domain-Join-Kontext fuer serverloses Binding existiert. Leer ausgeliefert -
    # der Wizard schlaegt beim ersten Start einen Wert aus der UPN-Domaene vor.
    DiscoveryDomain = ''

    # Arbeitsverzeichnis fuer temporaere CSR-/CER-/Log-Dateien (wird bei Bedarf angelegt).
    # Unterstuetzt Windows-Umgebungsvariablen im Format %VARNAME%.
    WorkingDir    = '%TEMP%\VscWizard'
}
