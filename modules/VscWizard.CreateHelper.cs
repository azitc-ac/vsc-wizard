// VscWizard.CreateHelper.cs
//
// Elevierter Helfer fuer die Erstellung einer virtuellen Smartcard ueber die
// COM-API (ITpmVirtualSmartCardManager[2]). Wird von New-VirtualSmartCard
// (VscWizard.Core.psm1) zur Laufzeit mit dem csc.exe des .NET Framework zu einer
// /target:winexe-Anwendung kompiliert und eleviert gestartet.
//
// Warum eine kompilierte Fenster-Exe statt des frueheren powershell.exe-Skripts:
//   - powershell.exe ist eine Konsolenanwendung - beim elevierten Start erscheint
//     zwangslaeufig ein (leeres) Konsolenfenster neben dem PIN-Dialog. Eine
//     winexe hat gar kein Konsolenfenster; es erscheint ausschliesslich der Dialog.
//   - Der Sprachstand muss C# 5 bleiben (csc aus %WINDIR%\Microsoft.NET\...\v4.0.30319):
//     keine String-Interpolation, keine ?.-Operatoren, keine expression-bodied members.
//
// ARM64: .NET Framework hat dort keine native Laufzeit - das csc-Kompilat laeuft
// emuliert, und der ARM64-Proxy/Stub des TPM-COM-Servers ist darin nicht ladbar
// (QueryInterface 0x800700C1). Dieselbe Quelldatei wird deshalb zusaetzlich von
// helper\VscCreateHelper.csproj als NATIVE, self-contained .NET-win-arm64-App gebaut
// (build.ps1 / dotnet publish) - Aenderungen hier wirken auf beide Wege. Der Code muss
// daher sowohl mit csc (C# 5, .NET Framework) als auch mit .NET 8 kompilieren.
//
// Aufruf:  VscWizard.CreateHelper.exe "<CardName>" <MinPinLength> "<ResultPath>"
// Ergebnis: key=value-Zeilen in ResultPath (Success/Cancelled/HResult/InstanceId/
//           Message/PinPolicyUsed).
//
// PIN-Policy: Mindestlaengen unter 8 erfordern
// ITpmVirtualSmartCardManager2::CreateVirtualSmartCardWithPinPolicy (MS-TPMVSC
// Opnum 5) mit serialisierter PIN-Policy ("PinPolicySerialization": 8 DWORDs
// little-endian: Reserved=1, minLength, maxLength, dann fuenf Zeichenklassen-
// Optionen mit 0=Allow/1=RequireAtLeastOne/2=Disallow). Die Verfuegbarkeit von
// Manager2 wird VOR dem PIN-Dialog geprueft, damit der Dialog die tatsaechlich
// geltende Mindestlaenge anzeigt (Fallback: Basis-API mit Minimum 8).

using System;
using System.Drawing;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

namespace VscWizardHelper
{
    [ComImport, Guid("1A1BB35F-ABB8-451C-A1AE-33D98F1BEF4A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITpmVirtualSmartCardManagerStatusCallback
    {
        [PreserveSig] int ReportProgress(int status);
        [PreserveSig] int ReportError(int error);
    }

    public class VscStatusCallback : ITpmVirtualSmartCardManagerStatusCallback
    {
        public int ReportProgress(int status) { return 0; }
        public int ReportError(int error) { return 0; }
    }

    [ComImport, Guid("112B1DFF-D9DC-41F7-869F-D67FEE7CB591"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITpmVirtualSmartCardManager
    {
        [PreserveSig]
        int CreateVirtualSmartCard(
            [MarshalAs(UnmanagedType.LPWStr)] string pszFriendlyName, byte bAdminAlgId,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKey, uint cbAdminKey,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKcv, uint cbAdminKcv,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbPuk, uint cbPuk,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbPin, uint cbPin,
            [MarshalAs(UnmanagedType.Bool)] bool fGenerate,
            [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
            [MarshalAs(UnmanagedType.LPWStr)] out string ppszInstanceId,
            [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
        [PreserveSig]
        int DestroyVirtualSmartCard(
            [MarshalAs(UnmanagedType.LPWStr)] string pszInstanceId,
            [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
            [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
    }

    // ITpmVirtualSmartCardManager2 (MS-TPMVSC): erbt in der IDL von
    // ITpmVirtualSmartCardManager. .NET-COM-Interop uebernimmt vtable-Slots NICHT
    // von geerbten Managed-Interfaces, deshalb werden die Basis-Methoden hier in
    // exakt derselben Reihenfolge erneut deklariert (IUnknown belegt Slots 0-2,
    // danach Opnum 3/4 aus der Basis, dann Opnum 5).
    [ComImport, Guid("FDF8A2B9-02DE-47F4-BC26-AA85AB5E5267"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITpmVirtualSmartCardManager2
    {
        [PreserveSig]
        int CreateVirtualSmartCard(
            [MarshalAs(UnmanagedType.LPWStr)] string pszFriendlyName, byte bAdminAlgId,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKey, uint cbAdminKey,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbAdminKcv, uint cbAdminKcv,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbPuk, uint cbPuk,
            [MarshalAs(UnmanagedType.LPArray)] byte[] pbPin, uint cbPin,
            [MarshalAs(UnmanagedType.Bool)] bool fGenerate,
            [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
            [MarshalAs(UnmanagedType.LPWStr)] out string ppszInstanceId,
            [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
        [PreserveSig]
        int DestroyVirtualSmartCard(
            [MarshalAs(UnmanagedType.LPWStr)] string pszInstanceId,
            [MarshalAs(UnmanagedType.Interface)] ITpmVirtualSmartCardManagerStatusCallback pStatusCallback,
            [MarshalAs(UnmanagedType.Bool)] out bool pfNeedReboot);
        // Opnum 5 (MS-TPMVSC CreateVirtualSmartCardWithPinPolicy): identisch zur
        // Basis-Methode, plus pbPinPolicy/cbPinPolicy zwischen cbPin und fGenerate.
        [PreserveSig]
        int CreateVirtualSmartCardWithPinPolicy(
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

    public static class VscCom
    {
        public static string LastError = "";
        private static object _manager;

        // CLSID der TpmVirtualSmartCardManager-CoClass (LocalServer TpmVscMgrSvr.exe).
        private static object GetManagerObject()
        {
            if (_manager == null)
            {
                Type t = Type.GetTypeFromCLSID(new Guid("16A18E86-7F6E-4C20-AD89-4FFC0DB7A96A"));
                _manager = Activator.CreateInstance(t);
            }
            return _manager;
        }

        // QueryInterface-Probe VOR dem PIN-Dialog: bestimmt, ob die Policy-Variante
        // (und damit eine Mindestlaenge unter 8) verfuegbar ist.
        public static bool ProbePinPolicySupport()
        {
            try { return GetManagerObject() is ITpmVirtualSmartCardManager2; }
            catch (Exception ex) { LastError = ex.GetType().Name + ": " + ex.Message; return false; }
        }

        // PinPolicySerialization (MS-TPMVSC): 8 DWORDs little-endian.
        // Zeichenklassen: 0 = Allow (bewusst ueberall, maximal permissiv wie die
        // tpmvscmgr-Defaults - die Mindestlaenge ist die einzige Verschaerfung).
        private static byte[] BuildPinPolicy(uint minLen, uint maxLen)
        {
            byte[] blob = new byte[32];
            Buffer.BlockCopy(BitConverter.GetBytes((uint)1), 0, blob, 0, 4);   // Reserved, MUSS 1
            Buffer.BlockCopy(BitConverter.GetBytes(minLen), 0, blob, 4, 4);    // minLength
            Buffer.BlockCopy(BitConverter.GetBytes(maxLen), 0, blob, 8, 4);    // maxLength
            // Offsets 12/16/20/24/28: uppercase/lowercase/digits/special/other = 0
            // (Allow), Array ist bereits nullinitialisiert.
            return blob;
        }

        [HandleProcessCorruptedStateExceptions, SecurityCritical]
        public static int Create(string name, byte[] adminKey, byte[] pin, uint minPinLength,
            out string instanceId, out bool needReboot, out bool pinPolicyUsed)
        {
            instanceId = null; needReboot = false; pinPolicyUsed = false; LastError = "";
            try
            {
                object mgr = GetManagerObject();
                ITpmVirtualSmartCardManager2 mgr2 = mgr as ITpmVirtualSmartCardManager2;
                if (mgr2 != null)
                {
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
            }
            catch (Exception ex) { LastError = ex.GetType().Name + ": " + ex.Message; return -1; }
        }
    }

    // Maskierter PIN-Dialog (PIN + Bestaetigung, Mindestlaenge, Abbrechen) - die PIN
    // wird NUR in diesem elevierten Prozess gehalten und nie ueber Prozessgrenzen/
    // Kommandozeile weitergereicht.
    public class PinDialog : Form
    {
        private readonly TextBox _txtPin;
        private readonly TextBox _txtConfirm;
        private readonly Label _lblError;
        private readonly int _minPinLength;
        public string Pin;

        public PinDialog(string cardName, int minPinLength)
        {
            _minPinLength = minPinLength;

            Text = "PIN fuer virtuelle Smartcard festlegen";
            ClientSize = new Size(444, 250);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MinimizeBox = false;
            MaximizeBox = false;
            TopMost = true;

            Label lblInfo = new Label();
            lblInfo.Text = "Karte: " + cardName + "\r\nBitte eine PIN festlegen (mindestens " + minPinLength + " Zeichen).";
            lblInfo.Location = new Point(16, 15);
            lblInfo.Size = new Size(412, 44);
            Controls.Add(lblInfo);

            Label lblPin = new Label();
            lblPin.Text = "PIN:";
            lblPin.Location = new Point(16, 70);
            lblPin.Size = new Size(120, 22);
            Controls.Add(lblPin);

            _txtPin = new TextBox();
            _txtPin.Location = new Point(140, 68);
            _txtPin.Size = new Size(280, 22);
            _txtPin.UseSystemPasswordChar = true;
            Controls.Add(_txtPin);

            Label lblConfirm = new Label();
            lblConfirm.Text = "PIN bestaetigen:";
            lblConfirm.Location = new Point(16, 104);
            lblConfirm.Size = new Size(120, 22);
            Controls.Add(lblConfirm);

            _txtConfirm = new TextBox();
            _txtConfirm.Location = new Point(140, 102);
            _txtConfirm.Size = new Size(280, 22);
            _txtConfirm.UseSystemPasswordChar = true;
            Controls.Add(_txtConfirm);

            _lblError = new Label();
            _lblError.Location = new Point(16, 138);
            _lblError.Size = new Size(412, 40);
            _lblError.ForeColor = Color.Firebrick;
            Controls.Add(_lblError);

            Button btnOk = new Button();
            btnOk.Text = "Erstellen";
            btnOk.Location = new Point(140, 196);
            btnOk.Size = new Size(130, 32);
            btnOk.Click += OnOkClick;
            Controls.Add(btnOk);

            Button btnCancel = new Button();
            btnCancel.Text = "Abbrechen";
            btnCancel.Location = new Point(290, 196);
            btnCancel.Size = new Size(130, 32);
            btnCancel.DialogResult = DialogResult.Cancel;
            Controls.Add(btnCancel);

            AcceptButton = btnOk;
            CancelButton = btnCancel;
        }

        private void OnOkClick(object sender, EventArgs e)
        {
            if (_txtPin.Text.Length < _minPinLength)
            {
                _lblError.Text = "PIN zu kurz (mindestens " + _minPinLength + " Zeichen).";
                return;
            }
            if (_txtPin.Text != _txtConfirm.Text)
            {
                _lblError.Text = "Die beiden PIN-Eingaben stimmen nicht ueberein.";
                return;
            }
            Pin = _txtPin.Text;
            DialogResult = DialogResult.OK;
            Close();
        }
    }

    public static class Program
    {
        private static void WriteResult(string path, bool success, string hresult, string instanceId, string message, bool pinPolicyUsed)
        {
            WriteResult(path, success, hresult, instanceId, message, pinPolicyUsed, false);
        }

        // Cancelled=True: Benutzer hat den PIN-Dialog abgebrochen - der Aufrufer darf
        // dann NICHT auf tpmvscmgr zurueckfallen (keine zweite PIN-Abfrage).
        private static void WriteResult(string path, bool success, string hresult, string instanceId, string message, bool pinPolicyUsed, bool cancelled)
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("Success=" + success);
            sb.AppendLine("Cancelled=" + cancelled);
            sb.AppendLine("HResult=" + hresult);
            sb.AppendLine("InstanceId=" + (instanceId == null ? "" : instanceId));
            sb.AppendLine("Message=" + message);
            sb.AppendLine("PinPolicyUsed=" + pinPolicyUsed);
            File.WriteAllText(path, sb.ToString(), Encoding.UTF8);
        }

        [STAThread]
        public static int Main(string[] args)
        {
            // Aufruf: CreateHelper.exe "<CardName>" <MinPinLength> "<ResultPath>" ["<PinFile>"]
            // Optionaler 4. Parameter = Pfad einer Datei mit der PIN (Supplied-PIN-Modus,
            // z.B. stille Provisionierung). Ist er gesetzt, wird die PIN aus der Datei
            // gelesen statt per Dialog abgefragt; die Datei wird sofort geloescht.
            if (args.Length < 3) { return 2; }
            string cardName = args[0];
            string resultPath = args[2];
            string pinFile = (args.Length >= 4) ? args[3] : null;
            int minPinLength;
            if (!int.TryParse(args[1], out minPinLength)) { minPinLength = 6; }
            // Zulaessiger Bereich laut Plattform: 4-127 (Basis-API ohne Policy: 8).
            if (minPinLength < 4) { minPinLength = 4; }
            if (minPinLength > 127) { minPinLength = 127; }

            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                // Verfuegbarkeit der Policy-API pruefen, BEVOR der PIN-Dialog
                // erscheint - der Dialog soll die tatsaechlich geltende
                // Mindestlaenge anzeigen.
                bool policySupported = VscCom.ProbePinPolicySupport();
                if (!policySupported && minPinLength < 8) { minPinLength = 8; }

                string pin;
                if (!string.IsNullOrEmpty(pinFile))
                {
                    // Supplied-PIN-Modus: PIN aus der Datei lesen, Datei sofort loeschen.
                    string supplied = null;
                    try
                    {
                        if (File.Exists(pinFile)) { supplied = File.ReadAllText(pinFile); }
                    }
                    catch (Exception) { }
                    try { File.Delete(pinFile); } catch (Exception) { }
                    if (supplied != null) { supplied = supplied.Trim(); }
                    if (string.IsNullOrEmpty(supplied))
                    {
                        WriteResult(resultPath, false, "", "", "Keine PIN in der uebergebenen Datei.", false);
                        return 1;
                    }
                    if (supplied.Length < minPinLength)
                    {
                        WriteResult(resultPath, false, "", "", "Gelieferte PIN ist kuerzer als die Mindestlaenge (" + minPinLength + ").", false);
                        return 1;
                    }
                    pin = supplied;
                }
                else
                {
                    using (PinDialog dlg = new PinDialog(cardName, minPinLength))
                    {
                        if (dlg.ShowDialog() != DialogResult.OK || string.IsNullOrEmpty(dlg.Pin))
                        {
                            WriteResult(resultPath, false, "", "", "Vom Benutzer abgebrochen.", false, true);
                            return 0;
                        }
                        pin = dlg.Pin;
                    }
                }

                // Zufaelliger 24-Byte-3DES-Admin-Key (entspricht tpmvscmgr /AdminKey RANDOM).
                byte[] adminKey = new byte[24];
                using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
                {
                    rng.GetBytes(adminKey);
                }
                byte[] pinBytes = Encoding.ASCII.GetBytes(pin);

                string instanceId;
                bool needReboot;
                bool pinPolicyUsed;
                int hr = VscCom.Create(cardName, adminKey, pinBytes, (uint)minPinLength,
                    out instanceId, out needReboot, out pinPolicyUsed);
                string hex = "0x" + hr.ToString("X8");

                if (hr == 0 && !string.IsNullOrEmpty(instanceId))
                {
                    WriteResult(resultPath, true, hex, instanceId, "", pinPolicyUsed);
                }
                else
                {
                    string detail = string.IsNullOrEmpty(VscCom.LastError) ? ("HRESULT " + hex) : VscCom.LastError;
                    WriteResult(resultPath, false, hex, "", "Kartenerstellung fehlgeschlagen (" + detail + ").", pinPolicyUsed);
                }
                return 0;
            }
            catch (Exception ex)
            {
                try { WriteResult(resultPath, false, "", "", "Helfer-Fehler: " + ex.GetType().Name + ": " + ex.Message, false); }
                catch (Exception) { }
                return 1;
            }
        }
    }
}
