# VSC-Wizard

Ein Wizard-Tool fuer AD-Administratoren zur Beantragung virtueller Smartcards
(TPM Virtual Smart Card). Fuehrt Schritt fuer Schritt durch die Erstellung der
Karte und die Zertifikatsbeantragung und unterstuetzt zwei Szenarien als Tabs:

- **Plan A - AD-Domaene**: Rechner ist domaenen-gebunden und hat direkte Sicht
  auf die Enterprise-CA. Kartenerstellung und Zertifikatsbeantragung laufen in
  einem durchgehenden, automatisierten Ablauf.
- **Plan B - Entra-joined / Workgroup**: Rechner hat keine direkte Sicht auf
  die Zertifizierungsstelle. Der CSR wird lokal erzeugt, per RDP-Login als
  Zielbenutzer auf einen CA-nahen Server eingereicht, und das ausgestellte
  Zertifikat anschliessend wieder lokal auf der virtuellen Smartcard hinterlegt.

Die Beantragung setzt eine bestehende Anmeldung als der Zielbenutzer voraus;
das Tool fuehrt die Schritte im jeweiligen Benutzerkontext aus (nur die
Kartenerstellung mit `tpmvscmgr` fordert gezielt eine UAC-Elevation an).

## Voraussetzungen

- Windows 10/11 mit PowerShell 5.1
- TPM (fuer die Erstellung virtueller Smartcards via `tpmvscmgr.exe`)
- `certreq.exe` (Bestandteil von Windows)
- Fuer Plan A: direkte Netzwerksicht auf eine Active Directory Certificate
  Services (Enterprise) CA
- Fuer Plan B: ein per RDP erreichbarer Server mit Sicht auf die CA

## Verwendung

1. `config.psd1` anpassen (CA-Konfigurationsstring, Zertifikatstemplates,
   RDP-Zielserver fuer Plan B) - oder die Werte spaeter bequem ueber den Tab
   "Einstellungen" in der Anwendung pflegen.
2. `VscWizard.bat` ausfuehren (startet `VscWizard.ps1` mit
   `-ExecutionPolicy Bypass` im aktuellen Benutzerkontext).
3. Passenden Tab waehlen (wird anhand des erkannten Domaenen-Status
   vorausgewaehlt) und dem Wizard folgen.

## Aufbau

- `VscWizard.ps1` - GUI/Wizard-Flow (WinForms), zwei Tabs (Plan A/Plan B)
  sowie ein Einstellungen-Tab
- `modules/VscWizard.Core.psm1` - Nicht-GUI-Logik: Logging, Prozessausfuehrung,
  Erkennung von Domaenen-/TPM-Status, Erstellung der virtuellen Smartcard,
  CSR-Erstellung/-Einreichung/-Abschluss ueber `certreq`
- `config.psd1` - Konfiguration (CA, Templates, RDP-Zielserver, etc.)
- `VscWizard.bat` - Launcher

## Ablauf im Detail

### Plan A (automatisiert)

1. **Status**: Domaenen-Status, TPM-Status und angemeldeter Benutzer werden
   automatisch geprueft.
2. **Virtuelle Smartcard erstellen**: `tpmvscmgr create` (mit gezielter
   UAC-Elevation); die Karten-PIN wird ueber den nativen Windows-PIN-Dialog
   vergeben.
3. **Zertifikat anfordern**: `certreq -new` (Schluesselerzeugung auf der
   Smartcard) gefolgt von `certreq -submit` gegen die konfigurierte CA und
   `certreq -accept` zur Uebernahme - alles im Benutzerkontext. Erfordert das
   Template eine Genehmigung, kann das Zertifikat spaeter ueber "Zertifikat
   abrufen" nachtraeglich abgeholt werden.
4. **Zusammenfassung**: Anzeige des ausgestellten Zertifikats (Subject,
   Thumbprint, Gueltigkeit).

### Plan B (mit RDP-Zwischenschritt)

1. **Status**: Erkannter Domaenen-Status (Entra-joined/Workgroup) und
   konfigurierter RDP-Zielserver.
2. **Virtuelle Smartcard erstellen**: wie bei Plan A.
3. **CSR erstellen (lokal)**: `certreq -new` erzeugt eine an die Smartcard
   gebundene Zertifikatsanforderung; Pfad kann per Knopfdruck kopiert oder
   der Ordner geoeffnet werden.
4. **Uebergabe per RDP**: Anleitung mit konkretem Zielserver und Benutzer;
   die CSR-Datei muss manuell auf den Server kopiert werden (Bruch im
   Workflow, da der Rechner keine direkte CA-Sicht hat).
5. **Antrag einreichen (auf dem Server)**: Auf dem RDP-Zielserver, angemeldet
   als Zielbenutzer, wird dieselbe Anwendung im gleichen Modus weiter
   bedient: CSR-Datei auswaehlen, Template waehlen, einreichen. Das
   ausgestellte Zertifikat (`certnew.cer`) wird lokal auf dem Server abgelegt
   und muss zurueck auf den Ausgangsrechner kopiert werden.
6. **Zertifikat abschliessen (lokal)**: Zurueck auf dem Ausgangsrechner wird
   die `.cer`-Datei ausgewaehlt und per `certreq -accept` an den bereits auf
   der Smartcard vorhandenen privaten Schluessel gebunden.

## Manueller Testplan

Da fuer diese Automatisierung ein echtes Windows-System mit TPM, AD und einer
erreichbaren Zertifizierungsstelle noetig ist, gibt es keine automatisierten
Tests. Vor dem produktiven Einsatz empfiehlt sich folgender manueller Ablauf:

1. **Plan A** auf einem domaenen-gebundenen Testrechner mit TPM und
   Netzwerksicht auf eine Test-CA durchspielen (inkl. Ablehnung/Timeout-Faelle
   und einem Template, das eine manuelle Genehmigung erfordert).
2. **Plan B** auf einem Entra-joined- oder Workgroup-Testrechner durchspielen,
   inklusive echtem RDP-Hop auf einen CA-nahen Server als Zielbenutzer.
3. Fehlerfaelle pruefen: falsches Zertifikatstemplate, nicht erreichbare CA,
   abgelehnter UAC-Prompt, TPM nicht bereit.
4. Log-Export im Tab "Log / Diagnose" pruefen.

## Bekannte Einschraenkungen (v1)

- Keine granulare Uebersetzung von `certreq`-Fehlercodes; Rohausgabe steht im
  Log.
- Der RDP-Zwischenschritt in Plan B bleibt bewusst manuell (Kopieren der
  CSR-/CER-Datei) - dies ist eine inhaerente Einschraenkung des Szenarios ohne
  direkte CA-Sicht.
