# VSC-Wizard

Ein Wizard-Tool fuer AD-Administratoren zur Beantragung virtueller Smartcards
(TPM Virtual Smart Card). Fuehrt Schritt fuer Schritt durch die Erstellung der
Karte und die Zertifikatsbeantragung. Der Ablauf ist als durchgaengige
Schrittfolge aufgebaut (Schritt 1: Modus- und Kontowahl, danach die einzelnen
Beantragungsschritte mit "Weiter"/"Zurueck") mit einer schrittunabhaengigen
Kopfleiste, ueber die jederzeit die Einstellungen erreichbar sind. Es gibt zwei
Szenarien, die in Schritt 1 gewaehlt werden:

- **Plan A - AD-Domaene**: Rechner ist domaenen-gebunden und hat direkte Sicht
  auf die Enterprise-CA. Kartenerstellung und Zertifikatsbeantragung laufen in
  einem durchgehenden, automatisierten Ablauf.
- **Plan B - Entra-joined / Workgroup**: Rechner hat keine direkte Sicht auf
  die Zertifizierungsstelle. Der CSR wird lokal erzeugt, per RDP-Login als
  Zielbenutzer auf einen CA-nahen Server eingereicht, und das ausgestellte
  Zertifikat anschliessend wieder lokal auf der virtuellen Smartcard hinterlegt.

Die Beantragung laeuft im Benutzerkontext, in dem der Wizard gestartet wurde
(nur die Kartenerstellung mit `tpmvscmgr` fordert gezielt eine
UAC-Elevation an) - das gilt unabhaengig davon, fuer wen die Smartcard
gedacht ist, siehe naechster Abschnitt.

In Schritt 1 fragt der Wizard zunaechst, **fuer wen** die Smartcard beantragt
wird (und welcher der beiden Ablaeufe genutzt wird - anhand des erkannten
Domaenen-Status vorausgewaehlt, aber frei aenderbar):

- **Fuer mich**: normaler Ablauf, alles im aktuell angemeldeten
  Benutzerkontext.
- **Fuer ein separates Konto** (z.B. ein Admin-Konto): Kartenerstellung und
  CSR-Erstellung laufen trotzdem ganz normal im eigenen Benutzerkontext -
  die Smartcard-PIN ist kontounabhaengig und `certreq` verwaltet offene
  Antraege im Profil des aufrufenden Benutzers, nicht des Zielkontos. Es ist
  also **keine** gesonderte Anmeldung als Zielkonto fuer VSC/CSR noetig.
  Nur die Einreichung bei der CA muss aus Berechtigungsgruenden als
  Zielkonto erfolgen (die CA prueft die Enroll-Berechtigung anhand des
  einreichenden Kontos). Dafuer gibt es zwei Wege:
    - **Mit Enrollment-Agent-Zertifikat (empfohlen, ohne RDP)**: Liegt im
      eigenen Zertifikatsspeicher ein EA-Zertifikat, laeuft die gesamte
      Ausstellung fuer das Zielkonto bruchfrei in **Plan A** ueber *Enroll
      on Behalf Of* - der Antrag wird mit dem EA-Zertifikat co-signiert, die
      CA stellt trotzdem auf das Zielkonto aus. Siehe Abschnitt "Enrollment
      Agent" weiter unten.
    - **Ohne EA-Zertifikat (Fallback)**: **Plan B** fuehrt an der passenden
      Stelle einen RDP-Zwischenschritt ein (Einreichung als Zielkonto),
      unabhaengig vom Domaenen-Status. Die Uebernahme des fertigen
      Zertifikats passiert danach wieder hier im eigenen Konto.
  Fuer mehrere Admin-Konten wird der Ablauf entsprechend mehrfach durchlaufen
  (je eine eigene virtuelle Smartcard pro Konto).

## Voraussetzungen

- Windows 10/11 mit PowerShell 5.1
- TPM (fuer die Erstellung virtueller Smartcards via `tpmvscmgr.exe`)
- `certreq.exe` (Bestandteil von Windows)
- Fuer Plan A: direkte Netzwerksicht auf eine Active Directory Certificate
  Services (Enterprise) CA
- Fuer Plan B: ein per RDP erreichbarer Server mit Sicht auf die CA

Hinweis fuer Umgebungen, in denen PowerShell 7 (pwsh) als Standard-Terminal
genutzt wird: Wird `VscWizard.bat` aus einer pwsh-Umgebung heraus gestartet
(z.B. Doppelklick aus einem pwsh-Terminal, oder ein Prozess, der pwsh's
Umgebung geerbt hat), steht pwsh's Modulpfad in `$env:PSModulePath` vor dem
nativen Windows-PowerShell-5.1-Pfad. Windows PowerShell 5.1 laedt dann beim
Autoloading eingebauter Module faelschlich die PowerShell-7-Variante. Betroffen
waren `Microsoft.PowerShell.Utility` (ohne `Import-PowerShellDataFile` - die
gespeicherte `config.psd1` wurde dadurch bei jedem Start ignoriert) und
`Microsoft.PowerShell.Security` (die Variante registriert das `Cert:`-Laufwerk
nicht - das Smartcard-Inventar zeigte dadurch trotz vorhandener Zertifikate
nichts an). `VscWizard.Core.psm1` erzwingt deshalb beim Laden explizit die
nativen Module ueber ihren vollen Pfad (siehe Kommentar dort) - auch im
Kindprozess, der die CNG-Schluesselinfos ermittelt.

## Verwendung

1. `VscWizard.bat` ausfuehren (startet `VscWizard.ps1` mit
   `-ExecutionPolicy Bypass` im aktuellen Benutzerkontext).
2. `config.psd1` wird leer ausgeliefert (CA-Konfigurationsstring,
   Zertifikatstemplate und RDP-Zielserver sind org-spezifisch und daher nicht
   vorbefuellt). Solange diese Werte fehlen, oeffnet der Wizard beim Start
   automatisch den **Einstellungen**-Dialog (jederzeit ueber den Knopf in der
   Kopfleiste erreichbar) - dort entweder manuell eintragen oder per "PKI
   automatisch erkennen" befuellen lassen (siehe unten), dann "Speichern".
3. In Schritt 1 Konto und Ablauf (Plan A/Plan B) waehlen (Plan wird anhand des
   erkannten Domaenen-Status vorausgewaehlt) und dem Wizard mit "Weiter" folgen.

## Aufbau

- `VscWizard.ps1` - GUI/Wizard-Flow (WinForms): schrittbasierter Ablauf
  (Moduswahl + Plan A/Plan B) mit gemeinsamer "Weiter"/"Zurueck"-Navigation und
  einer Kopfleiste, die die Einstellungen als Dialog oeffnet
- `modules/VscWizard.Core.psm1` - Nicht-GUI-Logik: Logging, Prozessausfuehrung,
  Erkennung von Domaenen-/TPM-Status, Erstellung der virtuellen Smartcard,
  CSR-Erstellung/-Einreichung/-Abschluss ueber `certreq`
- `modules/VscWizard.CreateHelper.cs` - C#-Quellcode des elevierten
  Erstellungshelfers (COM-Interop + PIN-Dialog); wird zur Laufzeit per
  `csc.exe` zu einer fensterlosen winexe kompiliert, siehe "Ablauf im Detail"
- `config.psd1` - Konfiguration (CA, Template, RDP-Zielserver, etc.)
- `VscWizard.bat` - Launcher
- `VscWizard.Submit.ps1` - eigenstaendiger Einreichungshelfer fuer die RDP-Sitzung
  in Plan B, siehe Abschnitt "Einreichungshelfer" unten

## Einreichungshelfer (VscWizard.Submit.ps1)

Kleines, bewusst von `VscWizard.Core.psm1` unabhaengiges Begleitwerkzeug fuer die
RDP-Sitzung in Plan B Schritt 5: nimmt eine per Zwischenablage eingefuegte
Zertifikatsanforderung (CSR) als PEM-Text entgegen, reicht sie bei der CA ein
(inkl. eigener automatischer PKI-Erkennung und Pending/Retrieve-Unterstuetzung)
und gibt das ausgestellte Zertifikat wieder als PEM-Text zurueck (via
`certutil -encode`), automatisch in die Zwischenablage kopiert.

Da CSR-Dateien (`certreq -new`) und `certutil -encode`-Ausgaben ohnehin reiner
PEM-Text sind, ist dafuer **keine Laufwerksfreigabe oder Dateitransfer** in die
RDP-Sitzung noetig - nur RDP-Zwischenablage (Text). Dazu passend:

- Plan B Schritt 3 ("CSR erstellen") zeigt den CSR-Inhalt zusaetzlich zum Dateipfad
  als kopierbaren Text an ("CSR-Text kopieren").
- Plan B Schritt 6 ("Zertifikat abschliessen") akzeptiert wahlweise eine
  CER-Datei oder eingefuegten CER-Text als Alternative.

Da das Skript keine Abhaengigkeiten zum restlichen Projekt hat, kann es im
Zweifel auch als reiner Text per RDP-Zwischenablage in die Zielsitzung kopiert,
dort in eine neue `.ps1`-Datei eingefuegt und direkt gestartet werden - ganz
ohne das restliche Projekt mit rueberzukopieren.

## Ablauf im Detail

### Plan A (automatisiert)

Fuer "Fuer mich" (angemeldeter Benutzer) der Standardweg. Fuer ein separates
Zielkonto funktioniert Plan A ebenfalls, **sofern ein
Enrollment-Agent-Zertifikat vorliegt** - dann stellt Schritt 3 per Enroll on
Behalf Of direkt fuer das Zielkonto aus (siehe "Enrollment Agent"). Fehlt das
EA-Zertifikat, weist Schritt 3 auf Plan B (RDP) hin.

1. **Status**: Domaenen-Status, TPM-Status und angemeldeter Benutzer werden
   automatisch geprueft.
2. **Virtuelle Smartcard erstellen**: laeuft ueber die COM-API
   (`ITpmVirtualSmartCardManager`) in einem gezielt elevierten Helfer.
   Dessen Quellcode liegt als `modules/VscWizard.CreateHelper.cs` vor und
   wird zur Laufzeit mit dem `csc.exe` des .NET Framework zu einer
   `/target:winexe`-Anwendung kompiliert: eine Fenster-Exe hat **kein
   Konsolenfenster** - es erscheint ausschliesslich der echte maskierte
   PIN-Dialog (PIN + Bestaetigung; die PIN verlaesst den elevierten Prozess
   nie). csc erzeugt architekturneutrales IL (AnyCPU), das beim Start nativ
   laeuft (auf ARM64 als ARM64-Prozess) - der native TPM-COM-Server ist
   damit unabhaengig vom kompilierenden Prozess immer erreichbar. Nach der
   Erstellung ermittelt der Wizard den PC/SC-Namen der neuen Karte
   ("Microsoft Virtual Smart Card N") und zeigt ihn an - unter DIESEM Namen
   (nicht dem vergebenen Kartennamen!) erscheint die Karte in
   Windows-Kartenauswahl-Dialogen, z.B. bei der Zertifikatsanforderung.
   Die PIN-Mindestlaenge betraegt 6 Zeichen und wird ueber
   `ITpmVirtualSmartCardManager2::CreateVirtualSmartCardWithPinPolicy` mit
   einer serialisierten PIN-Policy (dokumentiertes MS-TPMVSC-Format
   "PinPolicySerialization": 8 Little-Endian-DWORDs - Reserved=1, minLength,
   maxLength, dann fuenf Zeichenklassen-Optionen mit 0=Allow/
   1=RequireAtLeastOne/2=Disallow) durchgesetzt. Steht diese Schnittstelle
   nicht zur Verfuegung, faellt der Helfer automatisch auf die Basis-API
   zurueck (dann Minimum 8) - der PIN-Dialog zeigt in beiden Faellen die
   tatsaechlich geltende Mindestlaenge an, da die Verfuegbarkeit vor dem
   Dialog geprueft wird.
3. **Zertifikat anfordern**: `certreq -new` (Schluesselerzeugung auf der
   Smartcard) gefolgt von `certreq -submit` gegen die konfigurierte CA und
   `certreq -accept` zur Uebernahme - alles im Benutzerkontext. Erfordert das
   Template eine Genehmigung, kann das Zertifikat spaeter ueber "Zertifikat
   abrufen" nachtraeglich abgeholt werden.
4. **Zusammenfassung**: Anzeige des ausgestellten Zertifikats (Subject,
   Thumbprint, Gueltigkeit).

### Plan B (mit RDP-Zwischenschritt)

Wird gebraucht, wenn dieser Rechner keine direkte Sicht auf die
Zertifizierungsstelle hat **oder** die Smartcard fuer ein separates Konto
beantragt wird (dann unabhaengig vom Domaenen-Status, da die Einreichung
in beiden Faellen woanders/als andere Identitaet passieren muss).

1. **Status**: Erkannter Domaenen-Status (Entra-joined/Workgroup), gewaehltes
   Zielkonto (falls "Fuer ein separates Konto" gewaehlt wurde) und
   konfigurierter RDP-Zielserver. Die automatische PKI-Erkennung (siehe
   Einstellungen) kann auch fuer Entra-joined-Rechner mit Cloud Kerberos
   Trust und einer VPN-/Private-Access-Verbindung dazu fuehren, dass direkter
   PKI-Zugriff besteht - in dem Fall (sofern kein separates Konto involviert
   ist) einfach in Schritt 1 "Plan A" waehlen, statt den manuellen RDP-Ablauf zu
   durchlaufen.
2. **Virtuelle Smartcard erstellen**: wie bei Plan A - im eigenen
   Benutzerkontext, unabhaengig vom Zielkonto.
3. **CSR erstellen (lokal)**: `certreq -new` erzeugt eine an die Smartcard
   gebundene Zertifikatsanforderung mit dem Zielkonto (oder dem eigenen
   Konto) als Subject; laeuft ebenfalls im eigenen Benutzerkontext. Pfad
   kann per Knopfdruck kopiert oder der Ordner geoeffnet werden - alternativ
   steht der CSR-Inhalt auch als kopierbarer PEM-Text bereit (fuer die
   RDP-Zwischenablage, z.B. mit dem Einreichungshelfer, siehe unten).
4. **Uebergabe per RDP**: Anleitung mit konkretem Zielserver und dem Konto,
   als das man sich dort anmelden soll (Zielkonto bei separatem Konto, sonst
   das eigene); CSR entweder als Datei (Laufwerksfreigabe) oder als Text
   (RDP-Zwischenablage) rueberbringen.
5. **Antrag einreichen (auf dem Server)**: Auf dem RDP-Zielserver, angemeldet
   als das Konto aus Schritt 4, entweder dieselbe Anwendung im gleichen Modus
   weiter bedienen (CSR-Datei auswaehlen, Template waehlen, einreichen) oder
   den schlankeren Einreichungshelfer `VscWizard.Submit.ps1` nutzen (CSR-Text
   einfuegen, einreichen, Ergebnis als Text zurueck in die Zwischenablage).
   Das ausgestellte Zertifikat muss zurueck auf den Ausgangsrechner - als
   Datei oder als kopierter Text.
6. **Zertifikat abschliessen (lokal)**: Zurueck auf dem Ausgangsrechner, im
   **eigenen** Benutzerkontext (nicht dem Zielkonto - `certreq` verwaltet den
   offenen Antrag im Profil des Kontos, das die CSR erstellt hat), wird die
   `.cer`-Datei ausgewaehlt (oder der CER-Text eingefuegt) und per
   `certreq -accept` an den bereits auf der
   Smartcard vorhandenen privaten Schluessel gebunden.

### Einstellungen

Die Einstellungen sind ein ueber die Kopfleiste (Knopf **"Einstellungen"**)
jederzeit erreichbarer Dialog. Die Eingabefelder liegen in einem scrollbaren
Bereich; die Zeile mit **"Speichern"**/**"Schliessen"** ist unten fest verankert
und daher immer sichtbar, unabhaengig von der Fenstergroesse.

Das **Provider-Feld** (CSP/KSP) ist ein editierbares Dropdown mit den beiden
Standard-Smartcard-Providern und muss zum gewaehlten Zertifikatstemplate
passen: der Legacy-CSP "Microsoft Base Smart Card Crypto Provider" (CAPI,
Template-Schema V1/V2) oder der CNG-KSP "Microsoft Smart Card Key Storage
Provider" (Template-Schema V3/V4 - empfohlen, sofern keine reine
CAPI-Altanwendung das Zertifikat nutzen muss; fuer die Smartcard-Anmeldung
selbst sind beide gleichwertig). Die INF-Erzeugung erkennt einen KSP am
Namensbestandteil "Key Storage Provider" und laesst dann die reinen
CAPI-Direktiven (`ProviderType`, `KeySpec`) weg, die ein KSP nicht
akzeptiert.

Der Button **"Vorhandene virtuelle Smartcards anzeigen..."** oeffnet einen
weiteren Dialog (Master-Detail: Lesegeraete oben, Zertifikate des ausgewaehlten
Lesegeraets unten, beide als Listen mit Spalten statt Baumtext) mit allen
auf diesem Rechner erkannten Smartcard-Lesegeraeten (inkl. virtueller
TPM-Smartcards, da `tpmvscmgr` selbst keinen "list"-Befehl kennt - die
Erkennung laeuft ueber die PnP-Geraeteklasse fuer Smartcard-Lesegeraete).
Lesegeraet auswaehlen zeigt die zugehoerigen Zertifikate aus dem
Benutzer-Zertifikatsspeicher (Subject, Gueltigkeit, Thumbprint, Provider). Die
Zuordnung Zertifikat -> Lesegeraet erfolgt ueber den PC/SC-Lesegeraetenamen
("Microsoft Virtual Smart Card N"): das Zertifikat meldet ihn ueber die
NCrypt-Property `SmartCardReader`, das PnP-Lesegeraet traegt ihn (ueber seine
`DEVPKEY_Device_Children`-Kennung) als PcscName - so landet jedes Zertifikat
unter seinem konkreten Lesegeraet. Der Scan kann durch den Timeout-Schutz gegen
haengende CNG-Schluesselzugriffe (verwaiste Verweise auf bereits geloeschte
Karten) einige Sekunden dauern; solange laeuft ein Wartecursor.

Zertifikate, die zwar als smartcard-gebunden erkannt, aber keinem vorhandenen
Lesegeraet zugeordnet werden konnten (z.B. Verweis auf eine bereits geloeschte
Karte), sowie alle sonstigen Zertifikate mit privatem Schluessel (zur
Fehlersuche), erscheinen als eigene Sammel-Eintraege in der Lesegeraete-Liste -
diese tauchen nur auf, wenn es entsprechende Zertifikate gibt.

**"Ausgewaehlte Smartcard loeschen..."** ruft `tpmvscmgr destroy` fuer das
ausgewaehlte Lesegeraet auf (nach Sicherheitsabfrage) - unwiderruflich,
alle darauf gespeicherten Schluessel gehen dabei verloren. Nur fuer echte
Lesegeraete verfuegbar, nicht fuer die Sammel-Eintraege.

Kompaktes Grid-Layout (Label neben statt ueber dem Feld). Leere Felder zeigen
einen grauen Hinweistext (z.B. `z.B. ca01.contoso.local\Contoso-Issuing-CA`),
der beim Klick ins Feld verschwindet und beim Verlassen eines leeren Feldes
wieder erscheint - er wird nicht als echter Wert gespeichert.

Das **Zertifikatstemplate** ist ein Dropdown (mit manueller Eingabe
kombinierbar) - es wird bewusst nur eines konfiguriert, da eine
VSC-Anmeldung immer genau ein Template verwendet.

Der Button **"PKI automatisch erkennen"** fragt die Enterprise-CAs direkt aus
der AD-Konfigurationspartition ab (LDAP) und testet die RPC-Erreichbarkeit
jeder gefundenen CA (`certutil -ping`, ca. 40 Sekunden Zeitlimit). Bei Erfolg
wird der CA-Konfigurationsstring direkt eingetragen und das
Zertifikatstemplate-Dropdown mit allen auf der CA verfuegbaren Templates
befuellt (erstes als Vorschlag vorausgewaehlt - im Dropdown ggf. das
passende auswaehlen, z.B. ein "SmartcardLogon"/"SmartcardUser"-artiges
Template statt eines fuer Verschluesselung/Webserver/etc.). Anschliessend
noch "Speichern" klicken, um die Werte dauerhaft in `config.psd1` zu
uebernehmen.
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
   inklusive echtem RDP-Hop auf einen CA-nahen Server als Zielbenutzer -
   einmal mit Datei-Uebergabe (Laufwerksfreigabe), einmal rein per
   RDP-Zwischenablage (CSR-Text kopieren -> `VscWizard.Submit.ps1` auf dem
   Server -> CER-Text zurueckkopieren -> Schritt 6 per Text abschliessen).
3. Fehlerfaelle pruefen: falsches Zertifikatstemplate, nicht erreichbare CA,
   abgelehnter UAC-Prompt, TPM nicht bereit.
4. Log-Export im Bereich "Log / Diagnose" (unten im Hauptfenster) pruefen.

## Enrollment Agent (Ausstellung fuer separate Konten ohne RDP)

Ein Enrollment-Agent-Zertifikat (EKU *Certificate Request Agent*,
`1.3.6.1.4.1.311.20.2.1`) erlaubt es, Zertifikate **im Auftrag anderer
Konten** auszustellen (Enroll on Behalf Of, EOBO). Damit entfaellt der
RDP-Bruch fuer separate Zielkonten komplett: der Antrag wird mit dem
EA-Zertifikat co-signiert, die CA stellt trotzdem auf das Zielkonto aus -
alles in der eigenen Sitzung.

**EA-Zertifikat beantragen** (Einstellungen): Da das EA-Zertifikat auf das
**eigene** Konto ausgestellt wird, ist das eine ganz normale
Direkt-Beantragung (kein RDP). Der Wizard bietet zwei Schutzvarianten fuer
den maechtigen EA-Schluessel:
- **Auf eigener VSC (TPM/PIN, Standard/empfohlen)**: der EA-Schluessel liegt
  auf einer eigenen virtuellen Smartcard - nicht exportierbar,
  PIN-geschuetzt. Jede EOBO-Ausstellung verlangt dann die PIN (bewusster
  Autorisierungs-Gate).
- **Software-Schluessel**: CNG-Software-Schluessel im Benutzerspeicher -
  bequemer, aber portabler/weniger geschuetzt.

Ist ein EA-Zertifikat vorhanden, erkennt der Wizard es automatisch und
schaltet fuer separate Konten den bruchfreien Plan-A-Weg frei (Schritt 3
erzeugt dann einen PKCS7-EOBO-Antrag: `certreq -new -cert <EA-Thumbprint>`
mit `RequestType=PKCS7` und `RequesterName=<Zielkonto>`; der Template-Verweis
steht im Antrag, `certreq -submit` reicht ihn ohne `-attrib` ein).

**Voraussetzungen auf der CA-Seite**: Das Ziel-Template muss EOBO erlauben und
die CA muss den Antragsteller als Enrollment Agent akzeptieren; oft ist
"Restricted Enrollment Agents" konfiguriert (schraenkt ein, welcher EA fuer
welche Konten/Templates ausstellen darf). Ein EA-Zertifikat ist
sicherheitskritisch - damit lassen sich Anmelde-Zertifikate fuer beliebige
Konten ausstellen; die Vergabe sollte der PKI-Policy entsprechen.

## Begonnene Antraege fortsetzen

Der Wizard speichert den Stand eines laufenden Antrags nach jedem Meilenstein
(Plan B: CSR erstellt; Plan A/B: Antrag eingereicht und wartet auf
Genehmigung) als `resume-state.txt` im Arbeitsverzeichnis. Wird der Wizard
geschlossen und spaeter neu gestartet, bietet er das Fortsetzen an und
springt mit wiederhergestelltem Kontext (Kartenname, RequestId, Pfade)
direkt zum passenden Schritt - z.B. um ein inzwischen genehmigtes Zertifikat
ueber "Zertifikat abrufen" abzuholen. Bei "Nein" wird nur der gespeicherte
Wizard-Stand verworfen; der offene Antrag selbst bleibt im
Zertifikatsspeicher des Benutzers (Windows verwaltet ihn im REQUEST-Store)
und kann notfalls ueber Schritt "Zertifikat abschliessen" mit der
CER-Datei/dem CER-Text weiterhin abgeschlossen werden. Nach erfolgreicher
Uebernahme des Zertifikats wird der gespeicherte Stand automatisch
geloescht.

## Bekannte Einschraenkungen (v1)

- Keine granulare Uebersetzung von `certreq`-Fehlercodes; Rohausgabe steht im
  Log.
- Der RDP-Zwischenschritt in Plan B bleibt bewusst manuell (Kopieren der
  CSR-/CER-Datei) - dies ist eine inhaerente Einschraenkung des Szenarios ohne
  direkte CA-Sicht.
- Die automatische Erreichbarkeitspruefung ist auf ca. 40 Sekunden begrenzt
  (LDAP-Discovery + RPC-Ping je CA); bei einer sehr langsamen, aber
  grundsaetzlich erreichbaren PKI kann das faelschlich als "nicht erreichbar"
  gewertet werden.
- Enroll on Behalf Of / EA-Zertifikate: der Ablauf ist implementiert, aber auf
  echter Hardware noch nicht verifiziert; er setzt zudem passende CA-seitige
  EOBO-Konfiguration voraus (siehe "Enrollment Agent"). Ohne EA-Zertifikat
  bleibt fuer separate Konten der Plan-B/RDP-Weg.
- Das Loeschen virtueller Smartcards laeuft weiterhin ueber `tpmvscmgr destroy`
  statt ueber die COM-API: `DestroyVirtualSmartCard` lieferte auf der
  Testhardware S_OK, entfernte die Karte aber nicht (Verhalten ungeklaert,
  moeglicherweise verzoegerte Entfernung) - `tpmvscmgr` verhaelt sich korrekt.
- Die PIN-Mindestlaenge von 6 setzt `ITpmVirtualSmartCardManager2` voraus;
  ohne diese Schnittstelle greift automatisch die Basis-API mit Minimum 8
  (der PIN-Dialog zeigt die jeweils geltende Grenze an).
