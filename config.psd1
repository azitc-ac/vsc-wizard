@{
    Template = 'ContosoSmartCardLogonKSP'
    # Offline-/Supply-in-request-Template (Subject/SAN kommen aus dem CSR, NICHT aus dem
    # AD). Für Szenario 04 (Cloud-Konto / Entra CBA): du reichst als DU ein, die
    # Ziel-UPN steht im Antrag. NUR für Entra CBA/Cloud - fuer On-Prem-Logon fehlt die
    # Konto-SID (KB5014754). Leer lassen, wenn du den Namen im Ablauf tippen willst.
    OfflineTemplate = ''
    WorkingDir = ''
    CAConfig = 'ca01.contoso.local\Contoso Issuing CA'
    CspName = 'Microsoft Smart Card Key Storage Provider'
    VscNamePrefix = 'VSC-'
    DiscoveryDomain = 'contoso.local'
    RdpJumpServer = 'rdp01.contoso.local'
    PinMinLength = '6'
}
