@{
    # CA-Konfigurationsstring im Format "Servername\CA-Name" (siehe: certutil -config -).
    # Leer ausgeliefert - im Tab "Einstellungen" eintragen (manuell oder per
    # "PKI automatisch erkennen"). Solange leer, oeffnet der Wizard beim Start
    # automatisch die Einstellungen.
    CAConfig      = ''

    # Name(n) des/der Zertifikatstemplates fuer Smartcard-Logon-Zertifikate,
    # die in der eigenen PKI-Umgebung existieren muessen. Leer ausgeliefert,
    # siehe CAConfig.
    Templates     = @()

    # Praefix fuer automatisch vorgeschlagene Namen virtueller Smartcards.
    VscNamePrefix = 'VSC'

    # Provider-Name der virtuellen Smartcard (Standard fuer TPM Virtual Smart Cards).
    CspName       = 'Microsoft Base Smart Card Crypto Provider'

    # Plan B: Name/Adresse eines Servers mit Sicht auf die Zertifizierungsstelle,
    # auf den sich der Zielbenutzer per RDP verbindet, um den CSR einzureichen.
    # Leer ausgeliefert - im Tab "Einstellungen" eintragen.
    RdpJumpServer = ''

    # Arbeitsverzeichnis fuer temporaere CSR-/CER-/Log-Dateien (wird bei Bedarf angelegt).
    # Unterstuetzt Windows-Umgebungsvariablen im Format %VARNAME%.
    WorkingDir    = '%TEMP%\VscWizard'
}
