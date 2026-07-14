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

    PIN-Mindestlaenge: die Basis-CreateVirtualSmartCard nutzt die Default-PIN-Policy
    der Karte (Minimum 8). Fuer kuerzere Mindestlaengen (z.B. 6) wird
    ITpmVirtualSmartCardManager2::CreateVirtualSmartCardWithPinPolicy (MS-TPMVSC
    Opnum 5) mit einer serialisierten PIN-Policy verwendet. Das Blob-Format IST
    dokumentiert (MS-TPMVSC, Abschnitt "PinPolicySerialization"): 8 DWORDs in
    Little-Endian-Reihenfolge:
      Reserved (MUSS 1), minLength, maxLength, uppercaseLettersPolicyOption,
      lowercaseLettersPolicyOption, digitsPolicyOption,
      specialCharactersPolicyOption, otherCharactersPolicyOption
    Zeichenklassen-Policy-Werte (SmartCardPinCharacterPolicyOption, Abschn. 2.2.1.3):
      0 = Allow, 1 = RequireAtLeastOne, 2 = Disallow.
    Die Verfuegbarkeit von Manager2 wird VOR dem PIN-Dialog geprueft, damit der
    Dialog von Anfang an die tatsaechlich geltende Mindestlaenge anzeigt (Fallback
    auf Minimum 8 ueber die Basis-API, falls Manager2 nicht verfuegbar ist).
#>
param(
    [Parameter(Mandatory)][string]$CardName,
    [int]$MinPinLength = 6,
    [Parameter(Mandatory)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'

function Write-VscResult {
    param([bool]$Success, [string]$HResult = '', [string]$InstanceId = '', [string]$Message = '', [string]$PinPolicyUsed = 'False')
    @(
        "Success=$Success"
        "HResult=$HResult"
        "InstanceId=$InstanceId"
        "Message=$Message"
        "PinPolicyUsed=$PinPolicyUsed"
    ) | Set-Content -Path $ResultPath -Encoding UTF8
}

# Zulaessiger Bereich laut Plattform: 4-127 (die Basis-API ohne Policy erzwingt 8).
if ($MinPinLength -lt 4) { $MinPinLength = 4 }
if ($MinPinLength -gt 127) { $MinPinLength = 127 }

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
// ITpmVirtualSmartCardManager2 (MS-TPMVSC): erbt in der IDL von ITpmVirtualSmartCardManager.
// .NET-COM-Interop uebernimmt vtable-Slots NICHT von geerbten Managed-Interfaces, deshalb
// werden die Basis-Methoden hier in exakt derselben Reihenfolge erneut deklariert
// (IUnknown belegt Slots 0-2, danach Opnum 3/4 aus der Basis, dann Opnum 5).
[ComImport, Guid("FDF8A2B9-02DE-47F4-BC26-AA85AB5E5267"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITpmVirtualSmartCardManager2 {
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
    // Opnum 5 (MS-TPMVSC CreateVirtualSmartCardWithPinPolicy): identisch zur Basis-
    // Methode, plus pbPinPolicy/cbPinPolicy zwischen cbPin und fGenerate.
    [PreserveSig] int CreateVirtualSmartCardWithPinPolicy(
        [MarshalAs(UnmanagedType.LPWStr)] string pszFriendlyName, byte bAdminAlgId,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKey, uint cbAdminKey,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKcv, uint cbAdminKcv,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbPuk, uint cbPuk,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbPin, uint cbPin,
        [MarshalAs(UnmanagedType.LPArray)] byte[] pbPinPolicy, uint cbPinPolicy,
        [MarshalAs(UnmanagedType.Bool)] bool fGenerate,
        [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
        [MarshalAs(UnmanagedType.LPWStr)] out string ppszInstanceId,
        [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
}
public static class VscCom {
    public static string LastError = "";
    static object _manager;
    // CLSID der TpmVirtualSmartCardManager-CoClass (LocalServer TpmVscMgrSvr.exe).
    static object GetManagerObject() {
        if (_manager == null) {
            Type t = Type.GetTypeFromCLSID(new Guid("16A18E86-7F6E-4C20-AD89-4FFC0DB7A96A"));
            _manager = Activator.CreateInstance(t);
        }
        return _manager;
    }
    // QueryInterface-Probe VOR dem PIN-Dialog: bestimmt, ob die Policy-Variante
    // (und damit eine Mindestlaenge unter 8) verfuegbar ist.
    public static bool ProbePinPolicySupport() {
        try { return GetManagerObject() is ITpmVirtualSmartCardManager2; }
        catch (Exception ex) { LastError = ex.GetType().Name + ": " + ex.Message; return false; }
    }
    // PinPolicySerialization (MS-TPMVSC): 8 DWORDs little-endian.
    // Zeichenklassen: 0 = Allow (bewusst ueberall, maximal permissiv wie die
    // tpmvscmgr-Defaults - die Mindestlaenge ist die einzige Verschaerfung).
    static byte[] BuildPinPolicy(uint minLen, uint maxLen) {
        byte[] blob = new byte[32];
        Buffer.BlockCopy(BitConverter.GetBytes((uint)1), 0, blob, 0, 4);   // Reserved, MUSS 1
        Buffer.BlockCopy(BitConverter.GetBytes(minLen), 0, blob, 4, 4);    // minLength
        Buffer.BlockCopy(BitConverter.GetBytes(maxLen), 0, blob, 8, 4);    // maxLength
        // Offsets 12/16/20/24/28: uppercase/lowercase/digits/special/other = 0 (Allow),
        // Array ist bereits nullinitialisiert.
        return blob;
    }
    [HandleProcessCorruptedStateExceptions, SecurityCritical]
    public static int Create(string name, byte[] adminKey, byte[] pin, uint minPinLength, out string instanceId, out bool needReboot, out bool pinPolicyUsed) {
        instanceId = null; needReboot = false; pinPolicyUsed = false; LastError = "";
        try {
            object mgr = GetManagerObject();
            ITpmVirtualSmartCardManager2 mgr2 = mgr as ITpmVirtualSmartCardManager2;
            if (mgr2 != null) {
                pinPolicyUsed = true;
                byte[] policy = BuildPinPolicy(minPinLength, 127);
                return mgr2.CreateVirtualSmartCardWithPinPolicy(
                    name, 0x82, adminKey, (uint)adminKey.Length,
                    null, 0, null, 0, pin, (uint)pin.Length,
                    policy, (uint)policy.Length,
                    true, new VscStatusCallback(), out instanceId, out needReboot);
            }
            return ((ITpmVirtualSmartCardManager)mgr).CreateVirtualSmartCard(
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

# --- Verfuegbarkeit der Policy-API pruefen, BEVOR der PIN-Dialog erscheint ---
# Ohne ITpmVirtualSmartCardManager2 gilt das Basis-Minimum 8; der Dialog soll von
# Anfang an die tatsaechlich geltende Grenze anzeigen statt eine PIN anzunehmen,
# die die API hinterher ablehnt.
$pinPolicySupported = [VscCom]::ProbePinPolicySupport()
if (-not $pinPolicySupported -and $MinPinLength -lt 8) {
    $MinPinLength = 8
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
$instanceId = ''; $needReboot = $false; $pinPolicyUsed = $false
$hr = [VscCom]::Create($CardName, $adminKey, $pinBytes, [uint32]$MinPinLength, [ref]$instanceId, [ref]$needReboot, [ref]$pinPolicyUsed)
$hex = '0x{0:X8}' -f $hr

if ($hr -eq 0 -and $instanceId) {
    Write-VscResult -Success $true -HResult $hex -InstanceId $instanceId -PinPolicyUsed "$pinPolicyUsed"
} else {
    $detail = if ([VscCom]::LastError) { [VscCom]::LastError } else { "HRESULT $hex" }
    Write-VscResult -Success $false -HResult $hex -Message "Kartenerstellung fehlgeschlagen ($detail)." -PinPolicyUsed "$pinPolicyUsed"
}
