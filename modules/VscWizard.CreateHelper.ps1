<#
    VscWizard.CreateHelper.ps1

    Elevierter Helfer fuer die Erstellung einer virtuellen Smartcard ueber die
    COM-API (ITpmVirtualSmartCardManager::CreateVirtualSmartCard) - loest den
    frueheren tpmvscmgr-Weg ab, der die PIN nur ueber ein rohes Konsolenfenster
    abfragen konnte.

    Ablauf:
      1. Zeigt einen echten, maskierten PIN-Dialog (PIN + Bestaetigung,
         Mindestlaenge, Abbrechen) - die PIN wird NUR in diesem elevierten Prozess
         gehalten und nie ueber Prozessgrenzen/Kommandozeile weitergereicht.
      2. Erzeugt einen zufaelligen 24-Byte-3DES-Admin-Key (entspricht dem frueheren
         tpmvscmgr /AdminKey RANDOM).
      3. Ruft CreateVirtualSmartCard mit direkt uebergebener PIN auf (kein Konsolen-
         Prompt) und meldet einen echten HRESULT zurueck.
      4. Schreibt ein strukturiertes Ergebnis nach -ResultPath (key=value), das der
         nicht-elevierte Hauptprozess ausliest.

    Wird von New-VirtualSmartCard (VscWizard.Core.psm1) eleviert gestartet. Die
    COM-Aufrufe MUESSEN in kompiliertem C# erfolgen - PowerShell kann diese reinen
    IUnknown-Interfaces (kein IDispatch) nicht selbst aufrufen.

    Hinweis zur PIN-Mindestlaenge: die Basis-CreateVirtualSmartCard nutzt die
    Default-PIN-Policy der Karte (Minimum 8). Eine kuerzere Mindestlaenge (z.B. 6)
    erfordert ITpmVirtualSmartCardManager2::CreateVirtualSmartCardWithPinPolicy mit
    einem serialisierten Policy-Blob, dessen Format nicht dokumentiert ist - offen
    als Folgeschritt.
#>
param(
    [Parameter(Mandatory)][string]$CardName,
    [int]$MinPinLength = 8,
    [Parameter(Mandatory)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'

function Write-VscResult {
    param([bool]$Success, [string]$HResult = '', [string]$InstanceId = '', [string]$Message = '')
    @(
        "Success=$Success"
        "HResult=$HResult"
        "InstanceId=$InstanceId"
        "Message=$Message"
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}

# Die Basis-CreateVirtualSmartCard erzwingt PIN-Minimum 8 - niedrigere Werte hier
# nicht zulassen, sonst wuerde der Nutzer eine PIN eingeben, die die API ablehnt.
if ($MinPinLength -lt 8) { $MinPinLength = 8 }

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Security;

[ComImport, Guid("1A1BB35F-ABB8-451C-A1AE-33D98F1BEF4A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITpmVirtualSmartCardManagerStatusCallback {
    [PreserveSig] int ReportProgress(int status);
    [PreserveSig] int ReportError(int error);
}
public class VscStatusCallback : ITpmVirtualSmartCardManagerStatusCallback {
    public int ReportProgress(int status) { return 0; }
    public int ReportError(int error) { return 0; }
}
[ComImport, Guid("112B1DFF-D9DC-41F7-869F-D67FEE7CB591"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITpmVirtualSmartCardManager {
    [PreserveSig] int CreateVirtualSmartCard(
        [MarshalAs(UnmanagedType.LPWStr)] string pszFriendlyName, byte bAdminAlgId,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKey, uint cbAdminKey,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKcv, uint cbAdminKcv,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbPuk, uint cbPuk,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbPin, uint cbPin,
        [MarshalAs(UnmanagedType.Bool)] bool fGenerate,
        [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
        [MarshalAs(UnmanagedType.LPWStr)] out string ppszInstanceId,
        [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
    [PreserveSig] int DestroyVirtualSmartCard(
        [MarshalAs(UnmanagedType.LPWStr)] string pszInstanceId,
        [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
        [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
}
public static class VscCom {
    public static string LastError = "";
    // CLSID der TpmVirtualSmartCardManager-CoClass (LocalServer TpmVscMgrSvr.exe).
    static ITpmVirtualSmartCardManager GetManager() {
        Type t = Type.GetTypeFromCLSID(new Guid("16A18E86-7F6E-4C20-AD89-4FFC0DB7A96A"));
        return (ITpmVirtualSmartCardManager)Activator.CreateInstance(t);
    }
    [HandleProcessCorruptedStateExceptions, SecurityCritical]
    public static int Create(string name, byte[] adminKey, byte[] pin, out string instanceId, out bool needReboot) {
        instanceId = null; needReboot = false; LastError = "";
        try {
            return GetManager().CreateVirtualSmartCard(
                name, 0x82, adminKey, (uint)adminKey.Length,
                null, 0, null, 0, pin, (uint)pin.Length,
                true, new VscStatusCallback(), out instanceId, out needReboot);
        } catch (Exception ex) { LastError = ex.GetType().Name + ": " + ex.Message; return -1; }
    }
}
"@ -ErrorAction Stop
} catch {
    Write-VscResult -Success $false -Message "Initialisierung fehlgeschlagen: $($_.Exception.Message)"
    return
}

# --- PIN-Dialog (maskiert, mit Bestaetigung) ---
$dlg = New-Object System.Windows.Forms.Form
$dlg.Text = 'PIN fuer virtuelle Smartcard festlegen'
$dlg.Size = New-Object System.Drawing.Size(460, 300)
$dlg.StartPosition = 'CenterScreen'
$dlg.FormBorderStyle = 'FixedDialog'
$dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.TopMost = $true

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "Karte: $CardName`r`nBitte eine PIN festlegen (mindestens $MinPinLength Zeichen)."
$lblInfo.Location = New-Object System.Drawing.Point(16, 15)
$lblInfo.Size = New-Object System.Drawing.Size(420, 44)

$lblPin = New-Object System.Windows.Forms.Label
$lblPin.Text = 'PIN:'
$lblPin.Location = New-Object System.Drawing.Point(16, 70)
$lblPin.Size = New-Object System.Drawing.Size(120, 22)
$txtPin = New-Object System.Windows.Forms.TextBox
$txtPin.Location = New-Object System.Drawing.Point(140, 68)
$txtPin.Size = New-Object System.Drawing.Size(280, 22)
$txtPin.UseSystemPasswordChar = $true

$lblConfirm = New-Object System.Windows.Forms.Label
$lblConfirm.Text = 'PIN bestaetigen:'
$lblConfirm.Location = New-Object System.Drawing.Point(16, 104)
$lblConfirm.Size = New-Object System.Drawing.Size(120, 22)
$txtConfirm = New-Object System.Windows.Forms.TextBox
$txtConfirm.Location = New-Object System.Drawing.Point(140, 102)
$txtConfirm.Size = New-Object System.Drawing.Size(280, 22)
$txtConfirm.UseSystemPasswordChar = $true

$lblError = New-Object System.Windows.Forms.Label
$lblError.Location = New-Object System.Drawing.Point(16, 138)
$lblError.Size = New-Object System.Drawing.Size(420, 40)
$lblError.ForeColor = [System.Drawing.Color]::Firebrick

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text = 'Erstellen'
$btnOk.Location = New-Object System.Drawing.Point(140, 210)
$btnOk.Size = New-Object System.Drawing.Size(130, 32)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Abbrechen'
$btnCancel.Location = New-Object System.Drawing.Point(290, 210)
$btnCancel.Size = New-Object System.Drawing.Size(130, 32)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

$dlg.Controls.AddRange(@($lblInfo, $lblPin, $txtPin, $lblConfirm, $txtConfirm, $lblError, $btnOk, $btnCancel))
$dlg.CancelButton = $btnCancel
$dlg.AcceptButton = $btnOk

$script:ChosenPin = $null
$btnOk.Add_Click({
    if ($txtPin.Text.Length -lt $MinPinLength) {
        $lblError.Text = "PIN zu kurz (mindestens $MinPinLength Zeichen)."
        return
    }
    if ($txtPin.Text -ne $txtConfirm.Text) {
        $lblError.Text = 'Die beiden PIN-Eingaben stimmen nicht ueberein.'
        return
    }
    $script:ChosenPin = $txtPin.Text
    $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Close()
})

$result = $dlg.ShowDialog()
if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $script:ChosenPin) {
    Write-VscResult -Success $false -Message 'Vom Benutzer abgebrochen.'
    return
}

# --- Karte erstellen ---
$adminKey = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($adminKey)
$pinBytes = [System.Text.Encoding]::ASCII.GetBytes($script:ChosenPin)
$instanceId = ''; $needReboot = $false
$hr = [VscCom]::Create($CardName, $adminKey, $pinBytes, [ref]$instanceId, [ref]$needReboot)
$hex = '0x{0:X8}' -f $hr

if ($hr -eq 0 -and $instanceId) {
    Write-VscResult -Success $true -HResult $hex -InstanceId $instanceId
} else {
    $detail = if ([VscCom]::LastError) { [VscCom]::LastError } else { "HRESULT $hex" }
    Write-VscResult -Success $false -HResult $hex -Message "Kartenerstellung fehlgeschlagen ($detail)."
}
