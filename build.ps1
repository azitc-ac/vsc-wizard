<#
    build.ps1 - erzeugt .exe-Dateien aus den Wizard-Skripten (Win-PS2EXE).

    WICHTIG:
    - PS2EXE kompiliert nicht nativ, sondern bettet das Skript ein und startet es
      mit der eingebauten Windows PowerShell 5.1 - also KEINE neue Abhaengigkeit
      auf Windows. ExecutionPolicy Restricted wird umgangen (In-Memory-Ausfuehrung).
    - VscWizard.Submit.exe ist eine echte EINZELDATEI (self-contained).
    - VscWizard.exe ist ein Drop-in-Ersatz fuer die .ps1/.bat, braucht aber weiterhin
      den 'modules'-Ordner + config.psd1 DANEBEN: der Wizard startet Hintergrund-Jobs,
      die VscWizard.Core.psm1 zur Laufzeit vom Pfad ($PSScriptRoot\modules) nachladen.
      Ein reiner Inline-Merge wuerde diese Jobs brechen - daher bewusst nicht gemergt.
    - KEIN -requireAdmin: der Wizard MUSS im Kontext des angemeldeten Benutzers laufen
      (er eleviert nur einzelne Aktionen wie tpmvscmgr/certutil selbst). Ein global
      elevierter Prozess wuerde z.B. den falschen Zertifikatsspeicher sehen.

    Aufruf (auf einem Windows mit Internetzugang fuer die einmalige PS2EXE-Installation):
        .\build.ps1
        .\build.ps1 -CertThumbprint <Thumbprint>   # zusaetzlich signieren
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    # Optional: Thumbprint eines Code-Signing-Zertifikats (Cert:\CurrentUser\My)
    # zum Signieren der erzeugten .exe (vermeidet SmartScreen/AV-Warnungen).
    [string]$CertThumbprint
)

$ErrorActionPreference = 'Stop'

# --- PS2EXE sicherstellen ---
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'PS2EXE-Modul nicht gefunden - installiere aus der PSGallery (CurrentUser)...'
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        throw "PS2EXE konnte nicht installiert werden: $($_.Exception.Message). Manuell: Install-Module ps2exe -Scope CurrentUser"
    }
}
Import-Module ps2exe -Force

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

function Build-Exe {
    param(
        [Parameter(Mandatory)][string]$InputFile,
        [Parameter(Mandatory)][string]$OutputFile,
        [string]$Title,
        [switch]$RequireAdmin
    )
    Write-Host "Baue $OutputFile ..."
    $p2Args = @{
        InputFile  = (Join-Path $PSScriptRoot $InputFile)
        OutputFile = $OutputFile
        STA        = $true       # WinForms braucht Single-Threaded Apartment
        NoConsole  = $true       # kein Konsolenfenster (reine GUI)
        Title      = $Title
        Product    = 'VSC-Wizard'
    }
    if ($RequireAdmin) { $p2Args['RequireAdmin'] = $true }
    Invoke-PS2EXE @p2Args
    if (-not (Test-Path $OutputFile)) { throw "Build fehlgeschlagen: $OutputFile wurde nicht erzeugt." }
}

# --- 1) Einreicher-Helfer: echte Einzeldatei ---
$submitExe = Join-Path $OutputDir 'VscWizard.Submit.exe'
Build-Exe -InputFile 'VscWizard.Submit.ps1' -OutputFile $submitExe -Title 'VSC-Wizard Einreichungshelfer'

# --- 2) Haupt-Wizard: exe + modules-Ordner + config.psd1 daneben ---
$mainExe = Join-Path $OutputDir 'VscWizard.exe'
Build-Exe -InputFile 'VscWizard.ps1' -OutputFile $mainExe -Title 'VSC-Wizard'

$modulesTarget = Join-Path $OutputDir 'modules'
if (-not (Test-Path $modulesTarget)) { New-Item -ItemType Directory -Path $modulesTarget -Force | Out-Null }
Copy-Item -Path (Join-Path $PSScriptRoot 'modules\*') -Destination $modulesTarget -Recurse -Force
$configSrc = Join-Path $PSScriptRoot 'config.psd1'
if (Test-Path $configSrc) { Copy-Item -Path $configSrc -Destination (Join-Path $OutputDir 'config.psd1') -Force }

# --- 3) Optional signieren ---
if ($CertThumbprint) {
    $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Signaturzertifikat $CertThumbprint nicht in Cert:\CurrentUser\My gefunden." }
    foreach ($exe in @($submitExe, $mainExe)) {
        Write-Host "Signiere $exe ..."
        $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256
        Write-Host "  -> $($sig.Status)"
    }
}

Write-Host ''
Write-Host "Fertig. Ausgabe in: $OutputDir"
Write-Host '  VscWizard.Submit.exe  - eigenstaendig (auf den RDP-/Einreich-Host kopieren).'
Write-Host '  VscWizard.exe         - zusammen mit dem Ordner modules\ und config.psd1 verteilen.'
