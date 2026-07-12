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

Beim Start fragt der Wizard zunaechst, **fuer wen** die Smartcard beantragt
wird:

- **Fuer mich**: normaler Ablauf im aktuell angemeldeten Benutzerkontext.
- **Fuer ein separates Konto** (z.B. ein Admin-Konto): PIN-Vergabe und
  Zertifikatsbindung muessen im Sicherheitskontext des Zielkontos erfolgen.
  Der Wizard zeigt dafuer einen `runas`-Befehl (inkl. Zwischenablage-Kopie)
  oder eine RDP-Anleitung an, um sich als Zielkonto interaktiv anzumelden -
  in der neuen Sitzung dann erneut den Wizard starten und "Fuer mich"
  waehlen. Fuer mehrere Admin-Konten wird dieser Ablauf entsprechend
  mehrfach durchlaufen (je eine eigene virtuelle Smartcard pro Konto).

## Voraussetzungen

- Windows 10/11 mit PowerShell 5.1
- TPM (fuer die Erstellung virtueller Smartcards via `tpmvscmgr.exe`)
- `certreq.exe` (Bestandteil von Windows)
- Fuer Plan A: direkte Netzwerksicht auf eine Active Directory Certificate
  Services (Enterprise) CA
- Fuer Plan B: ein per RDP erreichbarer Server mit Sicht auf die CA

## Verwendung

1. `VscWizard.bat` ausfuehren (startet `VscWizard.ps1` mit
   `-ExecutionPolicy Bypass` im aktuellen Benutzerkontext).
2. `config.psd1` wird leer ausgeliefert (CA-Konfigurationsstring,
   Zertifikatstemplates und RDP-Zielserver sind org-spezifisch und daher nicht
   vorbefuellt). Solange diese Werte fehlen, oeffnet der Wizard beim Start
   automatisch den Tab "Einstellungen" - dort entweder manuell eintragen oder
   per "PKI automatisch erkennen" befuellen lassen (siehe unten), dann
   "Speichern". Danach wird beim naechsten Start automatisch der passende
   Tab (Plan A/Plan B) vorausgewaehlt.
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
   konfigurierter RDP-Zielserver. Die automatische PKI-Erkennung (siehe
   Einstellungen) kann auch fuer Entra-joined-Rechner mit Cloud Kerberos
   Trust und einer VPN-/Private-Access-Verbindung dazu fuehren, dass direkter
   PKI-Zugriff besteht - in dem Fall einfach in Tab "Plan A" wechseln, statt
   den manuellen RDP-Ablauf zu durchlaufen.
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

### Einstellungen

Leere Felder zeigen einen grauen Hinweistext (z.B. `z.B. ca01.contoso.local\
Contoso-Issuing-CA`), der beim Klick ins Feld verschwindet und beim Verlassen
eines leeren Feldes wieder erscheint - er wird nicht als echter Wert
gespeichert.

Der Button **"PKI automatisch erkennen"** fragt die Enterprise-CAs direkt aus
der AD-Konfigurationspartition ab (LDAP) und testet die RPC-Erreichbarkeit
jeder gefundenen CA (`certutil -ping`, ca. 40 Sekunden Zeitlimit). Bei Erfolg
werden CA-Konfigurationsstring und verfuegbare Templates direkt in die
Felder geschrieben (als echte Werte, nicht nur als Hinweis) - anschliessend
noch "Speichern" klicken, um sie dauerhaft in `config.psd1` zu uebernehmen.
Schlaegt die Erkennung fehl, zeigt das Ergebnisfeld die konkrete Ursache
(LDAP-Fehler, CA gefunden aber per RPC nicht erreichbar, Zeitueberschreitung).

Das Feld **"AD-Domaene oder Domain Controller"** ist fuer die Discovery
wichtig: .NET versucht ohne diese Angabe ein "serverloses" LDAP-Binding, das
auf lokalen Domain-Join-Informationen beruht. Auf einem domaenen-gebundenen
Rechner klappt das von selbst; auf einem **Entra-joined- oder
Workgroup-Rechner fehlt dieser Kontext praktisch immer** - selbst mit
gueltigem Kerberos-Ticket (z.B. via Cloud Kerberos Trust) schlaegt die
Erkennung dann ab, wenn dieses Feld leer bleibt. Der Wizard schlaegt beim
ersten Oeffnen der Einstellungen automatisch einen Wert aus der
UPN-Domaene vor (Achtung: kann vom tatsaechlichen AD-DNS-Namen abweichen,
falls ein eigener UPN-Suffix konfiguriert ist - im Zweifel einen konkreten
Domain-Controller-Namen eintragen, z.B. `dc01.contoso.local`).

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
- Die automatische Erreichbarkeitspruefung ist auf ca. 25 Sekunden begrenzt
  (LDAP-Discovery + RPC-Ping je CA); bei einer sehr langsamen, aber
  grundsaetzlich erreichbaren PKI kann das faelschlich als "nicht erreichbar"
  gewertet werden.
- Der `runas`-Weg fuer separate Konten setzt voraus, dass das Zielkonto sich
  interaktiv lokal anmelden darf (keine GPO-Einschraenkung); sonst RDP nutzen.
