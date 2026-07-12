@{
    # CA-Konfigurationsstring im Format "Servername\CA-Name" (siehe: certutil -config -)
    CAConfig      = 'ca01.contoso.local\Contoso-Issuing-CA'

    # Name(n) des/der Zertifikatstemplates fuer Smartcard-Logon-Zertifikate,
    # die in der eigenen PKI-Umgebung existieren muessen.
    Templates     = @('SmartcardLogon')

    # Praefix fuer automatisch vorgeschlagene Namen virtueller Smartcards.
    VscNamePrefix = 'VSC'

    # Provider-Name der virtuellen Smartcard (Standard fuer TPM Virtual Smart Cards).
    CspName       = 'Microsoft Base Smart Card Crypto Provider'

    # Plan B: Name/Adresse eines Servers mit Sicht auf die Zertifizierungsstelle,
    # auf den sich der Zielbenutzer per RDP verbindet, um den CSR einzureichen.
    RdpJumpServer = 'pki-jump.contoso.local'

    # Arbeitsverzeichnis fuer temporaere CSR-/CER-/Log-Dateien (wird bei Bedarf angelegt).
    # Unterstuetzt Windows-Umgebungsvariablen im Format %VARNAME%.
    WorkingDir    = '%TEMP%\VscWizard'
}
