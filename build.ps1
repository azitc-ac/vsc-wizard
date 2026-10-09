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
    # Default <Repo>\dist - wird unten gesetzt, da $PSScriptRoot in Windows PowerShell
    # 5.1 im param()-Default leer sein kann.
    [string]$OutputDir,
    # Optional: Thumbprint eines Code-Signing-Zertifikats (Cert:\CurrentUser\My)
    # zum Signieren der erzeugten .exe (vermeidet SmartScreen/AV-Warnungen).
    [string]$CertThumbprint
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'dist' }

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

# Build-Version VOR dem Bauen bestimmen (Anzahl Commits): als Dateiversion in die EXEs
# (Explorer > Eigenschaften > Details), in version.txt und ins Intune-Erkennungsskript.
$script:BuildVersion = $null
try {
    $c = (& git -C $PSScriptRoot rev-list --count HEAD 2>$null | Select-Object -First 1)
    if ($c) { $script:BuildVersion = "1.0.$($c.ToString().Trim())" }
} catch { }

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
    # Programm-Icon (assets\VscWizard.ico, erzeugt von assets\New-VscWizardIcon.ps1):
    # erscheint in Explorer, Taskleiste, Startmenü und "Apps & Features".
    $iconFile = Join-Path $PSScriptRoot 'assets\VscWizard.ico'
    if (Test-Path $iconFile) { $p2Args['IconFile'] = $iconFile }
    # Dateiversion + Herausgeber (sichtbar in Eigenschaften > Details und für Intune-Diagnose).
    if ($script:BuildVersion) { $p2Args['Version'] = "$($script:BuildVersion).0" }
    $p2Args['Company'] = 'AZITC'
    $p2Args['Description'] = $Title
    $p2Args['Copyright'] = 'MIT License'
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
# config.psd1 liegt im Repo bewusst LEER (keine Organisationswerte im Git). Die echten
# Werte (CA, Template, Domäne) stehen in config.local.psd1 (per .gitignore ausgeschlossen)
# und kommen - falls vorhanden - als config.psd1 in die Ausgabe (z.B. für das Intune-Paket).
# Intune-Logo (256 px PNG) neben das Erkennungsskript.
$logoSrc = Join-Path $PSScriptRoot 'assets\VscWizard.png'
if (Test-Path $logoSrc) {
    $logoDir = Join-Path $OutputDir 'intune'
    if (-not (Test-Path $logoDir)) { New-Item -ItemType Directory -Path $logoDir -Force | Out-Null }
    Copy-Item -Path $logoSrc -Destination (Join-Path $logoDir 'VscWizard.png') -Force
}
$configLocal = Join-Path $PSScriptRoot 'config.local.psd1'
$configSrc = if (Test-Path $configLocal) { $configLocal } else { Join-Path $PSScriptRoot 'config.psd1' }
if (Test-Path $configSrc) {
    Copy-Item -Path $configSrc -Destination (Join-Path $OutputDir 'config.psd1') -Force
    Write-Host "Konfiguration: $(Split-Path -Leaf $configSrc) -> config.psd1$(if ($configSrc -ne $configLocal) { ' (LEER - für eine Verteilung config.local.psd1 anlegen)' })"
}

# --- 2b) Nativer ARM64-COM-Helfer (optional, benoetigt das .NET SDK nur zur BUILD-Zeit) ---
# Derselbe Quelltext wie modules\VscWizard.CreateHelper.cs, als self-contained
# .NET-win-arm64-Einzeldatei (siehe helper\VscCreateHelper.csproj und
# docs\ARM64-native-vsc.md). New-VirtualSmartCard nutzt ihn auf ARM64 automatisch,
# sonst faellt es dort auf tpmvscmgr.exe zurueck. Beim Endnutzer keine Laufzeit noetig.
$helperArm64Exe = $null
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    $helperArm64Dir = Join-Path $OutputDir 'helper-arm64'
    Write-Host "Baue nativen ARM64-Helfer nach $helperArm64Dir ..."
    & dotnet publish (Join-Path $PSScriptRoot 'helper\VscCreateHelper.csproj') -c Release -r win-arm64 -o $helperArm64Dir --nologo
    $helperArm64Exe = Join-Path $helperArm64Dir 'VscCreateHelper.exe'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $helperArm64Exe)) { throw 'dotnet publish des ARM64-Helfers fehlgeschlagen.' }
} else {
    Write-Host 'WARN: dotnet (SDK) nicht gefunden - nativer ARM64-Helfer wird nicht gebaut (ARM64 nutzt dann tpmvscmgr.exe).'
}

# --- version.txt aus der GIT-Historie erzeugen (fuer die EXE, die kein git sieht) ---
# Die Version "reist mit dem Repo": Build-Nummer = Anzahl Commits (waechst mit jedem
# Commit, ohne lokalen Hook). Wird neben die EXE gelegt; der Wizard liest sie, wenn
# kein .git danebenliegt (also im ausgelieferten EXE-Fall).
try {
    $verCount  = (& git -C $PSScriptRoot rev-list --count HEAD 2>$null | Select-Object -First 1)
    $verDate   = (& git -C $PSScriptRoot log -1 --format=%cd --date=short 2>$null | Select-Object -First 1)
    $verCommit = (& git -C $PSScriptRoot rev-parse --short HEAD 2>$null | Select-Object -First 1)
    if ($verCount) {
        $verText = "Version=1.0.$($verCount.ToString().Trim())`r`nDate=$verDate`r`nCommit=$verCommit`r`n"
        Set-Content -Path (Join-Path $OutputDir 'version.txt') -Value $verText -Encoding UTF8
        Write-Host "version.txt: 1.0.$($verCount.ToString().Trim()) ($verCommit, $verDate)"
        # Intune-Erkennungsskript mit DIESER Version (zum Paket hochladen): erkannt wird nur
        # "installierte Version >= gebaute Version" -> neue Pakete installieren über ältere.
        $detSrc = Join-Path $PSScriptRoot 'intune\Detect-VscWizard.ps1'
        if (Test-Path $detSrc) {
            $detDir = Join-Path $OutputDir 'intune'
            if (-not (Test-Path $detDir)) { New-Item -ItemType Directory -Path $detDir -Force | Out-Null }
            $detText = [IO.File]::ReadAllText($detSrc, [Text.Encoding]::UTF8).Replace('__VSCWIZARD_VERSION__', "1.0.$($verCount.ToString().Trim())")
            [IO.File]::WriteAllText((Join-Path $detDir 'Detect-VscWizard.ps1'), $detText, (New-Object System.Text.UTF8Encoding($true)))
            Write-Host "Intune-Erkennung: intune\Detect-VscWizard.ps1 (erkennt ab Version 1.0.$($verCount.ToString().Trim()))"
        }
    } else {
        Write-Host 'WARN: git nicht verfuegbar - version.txt nicht erzeugt (Wizard zeigt Fallback-Version).'
    }
} catch {
    Write-Host "WARN: version.txt konnte nicht erzeugt werden: $($_.Exception.Message)"
}

# --- 3) Optional signieren ---
if ($CertThumbprint) {
    $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Signaturzertifikat $CertThumbprint nicht in Cert:\CurrentUser\My gefunden." }
    foreach ($exe in @($submitExe, $mainExe, $helperArm64Exe | Where-Object { $_ })) {
        Write-Host "Signiere $exe ..."
        $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256
        Write-Host "  -> $($sig.Status)"
    }
}

Write-Host ''
Write-Host "Fertig. Ausgabe in: $OutputDir"
Write-Host '  VscWizard.Submit.exe  - eigenstaendig (auf den RDP-/Einreich-Host kopieren).'
Write-Host '  VscWizard.exe         - zusammen mit dem Ordner modules\ und config.psd1 verteilen.'
if ($helperArm64Exe) {
    Write-Host '  helper-arm64\         - mitverteilen (nativer PIN-Dialog/COM-Weg auf ARM64-Geraeten).'
}
