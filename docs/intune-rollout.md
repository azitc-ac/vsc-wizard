# Design: VSC-Rollout per Intune (Win32-App)

> Status: **Design** – abgestimmt am 2026-09-29. Ziel: Für Entra-joined Clients eine
> VSC „so einfach wie möglich" ausrollen. Testen braucht echtes Intune + Hardware
> (Windows/AD-Session).

## Grundidee & harte Randbedingungen

- **VSC erstellen braucht Adminrechte** (TPM/COM bzw. tpmvscmgr) → geht nur im
  **SYSTEM-/Admin-Kontext**.
- **Zertifikat beantragen + PIN ändern** laufen im **Benutzerkontext** (Benutzer-
  Zertifikatsspeicher, Benutzer kennt/setzt die PIN).
- Diese beiden Kontexte lassen sich nicht in **einer** Intune-App sauber vereinen
  (Device-App = SYSTEM, keine User-UI; User-App = Benutzer, kein Admin).

→ **Entscheidung: ZWEI Win32-Apps** (klar getrennt nach Kontext), statt einer App mit
ServiceUI-Bastelei.

Merksatz: **Die VSC ist maschinen-gebunden (TPM), das Zertifikat benutzer-gebunden.**
SYSTEM legt die leere Karte an; der Benutzer stellt später sein Cert darauf aus.

## Architektur

### App 1 — „VSC bereitstellen" (Device-targeted → läuft als SYSTEM)
- Legt **leere VSC** an, **Start-PIN = aus dem Computernamen abgeleitet** (deterministisch).
- **Silent, keine UI.** Ergebnis als Exit-Code + Registry-Marker für die Intune-Erkennung.
- Erkennungsregel: Registry-Marker (`HKLM\SOFTWARE\VSC-Wizard\Provisioned = 1` o.ä.)
  UND/ODER VSC vorhanden.
- Aufruf (Vorschlag): `VscWizard.exe -Provision -Silent`
  (PIN wird intern aus dem Computernamen abgeleitet, siehe unten).

### App 2 — „Smartcard einrichten" (User-targeted → läuft als angemeldeter Benutzer)
- Zeigt einen **vereinfachten Assistenten** (`VscWizard.exe -Simple`).
- Ablauf bewusst kurz:
  1. **PIN ändern erzwingen**: alte PIN = abgeleitete Start-PIN (vorbelegt), neue PIN
     vom Benutzer. **Erst danach geht es weiter** (Start-PIN ist bekannt/erratbar).
  2. **Zertifikat ausstellen** (entspricht Szenario 02 „eigenes on-prem/hybrid-Konto",
     direkt bei der CA) auf die vorhandene VSC.
- Erkennungsregel (pro Benutzer): Cert mit Smartcard-Logon-EKU auf der VSC vorhanden /
  per-User-Marker (`HKCU\...\Enrolled = 1`).
- Fallback: der Benutzer kann `VscWizard.exe -Simple` auch manuell starten.

> Reihenfolge **PIN-Änderung ZUERST**, dann Ausstellung: so entsteht das Cert nur unter
> der privaten PIN des Benutzers, nie unter der bekannten Start-PIN.

## Quell-/Start-PIN aus der Seriennummer (Aufkleber) + numerische Ziel-PIN

**Zwei PINs, klar getrennt:**

- **Quell-/Start-PIN (App 1, alphanumerisch):** deterministisch aus der **Geräte-
  Seriennummer** abgeleitet (`Win32_BIOS.SerialNumber`, `Get-VscBootstrapPin`). Grund:
  pro Gerät verschieden UND auf dem **OEM-Aufkleber/Service-Tag** ablesbar. App 2 rechnet
  sie identisch neu aus und belegt sie im PIN-Dialog vor → **kein Storage nötig**, der
  Benutzer muss sie normalerweise nicht kennen (Aufkleber nur als Fallback/zur Kontrolle).
  Bewusst **kein echtes Geheimnis** (Serie ist ohnehin sichtbar) → in App 2 sofort
  zwingend ändern. Bereinigt auf `[A-Za-z0-9]`, mind. 1 Buchstabe + 1 Ziffer, auf
  `max(config.PinMinLength, 8)` aufgefüllt (Basis-API verlangt ohne Manager2-Policy 8),
  auf 63 gekürzt. Fallback auf den Computernamen, falls die Seriennummer fehlt/ein
  OEM-Platzhalter ist (`To be filled by O.E.M.` etc.).
- **Ziel-PIN (App 2, vom Benutzer):** **numerisch, mindestens 6 Stellen** (bzw. die
  Karten-Mindestlänge, falls höher). Erzwungen im `Show-VscPinChangeDialog -NumericOnly
  -MinNewLength`.

- **Auf Hardware zu verifizieren:** Die VSC muss beim **Erstellen** eine alphanumerische
  PIN (Quell-PIN) und bei der **Änderung** eine rein numerische PIN (Ziel-PIN) akzeptieren
  — bei einer reinen Mindestlängen-Policy üblich, aber zu prüfen. Karten-Erstellungs-Policy
  (Manager2) entsprechend auf Mindestlänge 6 (bzw. `config.PinMinLength`).

## Sicherheitsbetrachtung

- Zwischen App 1 (Karte mit bekannter Start-PIN) und App 2 (Benutzer ändert PIN + stellt
  Cert aus) ist die Karte **leer** – eine bekannte PIN auf einer leeren Karte schützt
  nichts Sensibles. Erst App 2 bringt (a) die private PIN und (b) das Cert. Fenster klein
  halten: App 2 zeitnah, PIN-Änderung **erzwungen** (Assistent nicht beendbar, bevor
  geändert).

## Was am Tool zu bauen ist (reist mit dem Repo)

1. **Startparameter** in `VscWizard.ps1` (Param-Block ganz oben ergänzen):
   - `-Provision` + `-Silent`: keine GUI. VSC anlegen mit **gelieferter** Start-PIN
     (aus Computername). Exit-Code (0 ok / !=0 Fehler) + Registry-Marker setzen. Log in
     eine Datei (z.B. `C:\ProgramData\VSC-Wizard\provision.log`) für Intune-Diagnose.
   - `-Simple`: GUI im schlanken Modus – kein Szenario-Picker, direkt Schritt „PIN ändern
     (erzwungen)" → „Zertifikat ausstellen". Am Ende Erfolgshinweis.
2. **`New-VirtualSmartCard` um einen `-Pin`-Weg erweitern** (gelieferte PIN, KEIN Dialog):
   heute fragt der Helfer die PIN im GUI-Dialog ab. Für `-Provision -Silent` braucht es
   einen **supplied-PIN-Modus** (die COM-API `CreateVirtualSmartCardWithPinPolicy` nimmt
   die PIN als Parameter). Betrifft `VscWizard.CreateHelper.cs` **und** den nativen
   ARM64-Helfer → **auf ARM64/x64-Hardware testen** (Windows/AD-Session). Sicherheits-
   randbedingung bleibt: PIN nicht über Kommandozeile/Log; im SYSTEM-Kontext direkt an
   die API.
3. **Erzwungene PIN-Änderung** nutzt die vorhandenen Bausteine `Show-VscPinChangeDialog`
   / `Set-VscPin` (alte PIN vorbelegt = abgeleitete Start-PIN).
4. **Marker-Helfer**: Registry-Marker setzen/lesen (HKLM für App 1, HKCU für App 2) für
   die Intune-Erkennung.

## Intune-Paketierung (Windows/AD-Session, nicht im Repo)

- `.intunewin` je App mit `IntuneWinAppUtil.exe` bauen (Inhalt: `VscWizard.exe` +
  `modules\` + `config.psd1` + `version.txt`).
- **App 1 (Device):** Install `VscWizard.exe -Provision -Silent`; Uninstall optional
  (VSC entfernen); Detection: Registry-Marker HKLM / VSC vorhanden; Assignment: Geräte-
  gruppe (SYSTEM).
- **App 2 (User):** Install `VscWizard.exe -Simple` (läuft interaktiv im User-Kontext);
  Detection: HKCU-Marker / Cert vorhanden; Assignment: Benutzergruppe; ggf.
  **Abhängigkeit** App 2 → App 1.
- **Install behavior:** App 1 = System; App 2 = User.

## Mehrere Benutzer pro Gerät

Grundsatz: **jeder Benutzer braucht eine eigene VSC.** Eine gemeinsame Karte hieße eine
gemeinsame PIN. VSC anlegen geht nur als Admin/SYSTEM, einrichten (PIN, Zertifikat) nur
in der Benutzersitzung.

### Variante 1 — eine Karte pro Gerät, „erster Benutzer“ (UMGESETZT, 2026-09-30)

- App 1 legt **eine** Karte an; App 2 läuft (user-targeted) für jeden zugewiesenen
  Benutzer, aber nur der erste richtet die Karte ein.
- Der Simple-Modus prüft beim Start **auf der Karte selbst** (`Get-SmartCardOccupancy`:
  Container + dort gespeichertes Zertifikat, still, ohne PIN — Zertifikate anderer
  Benutzer stehen nicht im eigenen Speicher), Entscheidung in `Get-SimpleCardState`:
  - **Own** (Zertifikat mit eigener UPN): „bereits eingerichtet, nichts zu tun“, Start
    gesperrt, HKCU-Marker gesetzt (Intune-Erkennung erfüllt).
  - **Other** (Zertifikat eines anderen): „bereits für {UPN} eingerichtet – an die IT
    wenden“, Start gesperrt. Kein Versuch mit der Start-PIN (hätte einen Fehlversuch
    gekostet).
  - **Started** (nur Schlüssel ohne Zertifikat, z.B. Einrichtung abgebrochen): Start
    erlaubt, Hinweis „ggf. eigene PIN als aktuelle PIN eintragen“.
  - **Free** / **Unknown** (Belegung nicht ermittelbar): normaler Ablauf.
- Intune-Folge: für den zweiten Benutzer bleibt App 2 „nicht installiert“ (kein Marker)
  und versucht es periodisch erneut — er sieht dann jeweils den Hinweis. Wer das nicht
  will: App 2 nur dem Hauptbenutzer zuweisen.

### Variante 2 — eine Karte pro Benutzer, Anlegen + Zertifikat als EINE Einheit (UMGESETZT, 2026-09-30, Admin-/HW-Test offen)

Ziel: Jeder Hybrid-Benutzer, der sich anmeldet und noch kein gültiges Smartcard-
Anmeldezertifikat hat, bekommt seine **eigene** Karte `VSC-<Benutzername>` — angelegt erst
im Moment der Einrichtung, direkt gefolgt von eigener PIN und Zertifikat. Keine vorab
angelegten Karten, keine Start-PIN aus der Seriennummer.

**Intune: nur EINE Win32-App (Gerät, SYSTEM)**
- Install: `VscWizard.exe -Install` · Uninstall: `"%ProgramFiles%\VSC-Wizard\VscWizard.exe" -Uninstall`
- Erkennung: **`dist\intune\Detect-VscWizard.ps1`** (von `build.ps1` mit der gebauten
  Version erzeugt — mit **jedem** Paket neu hochladen). Erkannt nur, wenn installierte
  Version **>=** Paketversion (+ EXE + SYSTEM-Aufgabe vorhanden); liest die 64-Bit-
  Registry auch als 32-Bit-Skript. Alternativ ArpName `VSC-Wizard` (ohne Versionsprüfung).
- **Updates:** neues Paket + neue Erkennung hochladen -> ältere Installationen gelten als
  fehlend, Intune installiert drüber (keine Deinstallation, keine Ersatzkette nötig).
  `-Install` aktualisiert Programmdateien, Aufgaben, Rechte, ARP-Eintrag; **Karten,
  Benutzer-Zuordnungen, Start-PINs und Aufträge bleiben**. Ist der Assistent gerade offen
  (EXE gesperrt), bricht `-Install` sauber mit **1618** ab (keine halbe Kopie); Intune
  wiederholt später.- Paketinhalt (PSADT 4, Ordner `Files\`): `VscWizard.exe`, `modules\`, `config.psd1`
  (mit CAConfig/Template der Organisation!), `version.txt`; `helper-arm64\` nur für
  ARM64-Geräte (62 MB); `VscWizard.Submit.exe` wird auf Clients nicht gebraucht.
- PSADT: Install `Start-ADTProcess -FilePath "$($adtSession.DirFiles)\VscWizard.exe" -ArgumentList '-Install'`,
  Uninstall dito mit `-Uninstall` (aus dem Paket, nicht aus %ProgramFiles%). Exit-Codes:
  0 ok, 1 Fehler, 3 nicht eleviert. Install-Verhalten **System**, nicht interaktiv.
- `-Install` (`Install-VscCardService`):
  1. Kopiert den Wizard nach `%ProgramFiles%\VSC-Wizard` (nur Admins schreibbar — wichtig,
     weil SYSTEM ihn ausführt).
  2. `C:\ProgramData\VSC-Wizard\Requests` — Benutzer dürfen nur Dateien **anlegen**
     (CREATOR OWNER = Vollzugriff auf die eigene Datei, fremde nicht lesbar);
     `…\State` — nur SYSTEM/Admins.
  3. Aufgabe **„VSC-Wizard CreateCard“**: SYSTEM, **kein Auslöser**, `-ProcessRequests`,
     parallele Starts ignoriert; Sicherheitsbeschreibung: Benutzer dürfen **nur lesen und
     starten** (`D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)`).
  4. Aufgabe **„VSC-Wizard Setup“**: Gruppe „Benutzer“, Auslöser **bei jeder Anmeldung**
     (30 s verzögert), `-Simple -AutoStart`, in der Sitzung des Benutzers.
  5. Startmenü „Smartcard einrichten“ (`-Simple`) als Weg zurück (z.B. nach „Später“).

**Ablauf beim Benutzer**
1. Anmeldung → nach 30 s startet „VSC-Wizard Setup“ → `-AutoStart` beendet sich **still**,
   wenn: gültiges Smartcard-Anmeldezertifikat vorhanden (> 30 Tage gültig), kein On-Prem-
   Kerberos-Ticket (kein Hybrid-Konto / gerade keine AD-Verbindung), „Später“ aktiv, oder
   Konfiguration unvollständig. Grund steht im Tageslog des Benutzers.
2. Sonst: Startseite „Smartcard einrichten“ — „Beim Start wird deine persönliche Smartcard
   „VSC-<name>“ angelegt“ (oder die vorhandene eigene Karte).
3. **Klick „Einrichtung starten“ = hier startet der Wizard (mit den Rechten des Benutzers)
   die SYSTEM-Aufgabe:** `Requests\<id>.req` ablegen (Besitzer = Benutzer) →
   `Start-ScheduledTask 'VSC-Wizard CreateCard'` → Warten per Timer (Fenster bleibt
   bedienbar; nach 20 s wird die Aufgabe einmal erneut angestoßen).
4. SYSTEM (`Invoke-VscCardRequests`): Benutzer = **NTFS-Besitzer** des Auftrags (nicht
   fälschbar), muss interaktiv angemeldet sein (Besitzer von explorer.exe). Eigene Karte
   gemerkt (`HKLM\…\Users\<SID>`) und vorhanden → **wiederverwenden**; sonst Grenze
   prüfen (`MaxVscPerDevice`, Standard 10) + TPM bereit → Karte `VSC-<name>` mit
   **zufälliger 12-stelliger Start-PIN** anlegen. Start-PIN bis zur gemeldeten Änderung in
   `State\<SID>.pin` (nur SYSTEM/Admins). Antwort `<id>.res`: nur **dieser Benutzer**
   (+ SYSTEM/Admins) darf sie lesen/löschen; der Wizard löscht sie sofort nach dem Lesen.
5. Wizard: PIN-Dialog mit vorbelegter Start-PIN → eigene PIN (Ziffern, min. 6, erzwungen)
   → meldet „PinChanged“ (SYSTEM verwirft die gemerkte Start-PIN) → Ausstellung
   (Szenario 02) → HKCU-Marker.

**Erwartete Fehler → jeweils mit Ausweg (keine Sackgasse, in Test-Flows abgedeckt)**

| Fehler | Verhalten |
|---|---|
| Aufgabe fehlt / nicht startbar | Hinweis „nicht vollständig vorbereitet – IT“, „Einrichtung starten“ bleibt aktiv |
| Auftragsordner fehlt/gesperrt | dito, mit Fehlertext |
| Keine Antwort nach 90 s | Frage „Weiter warten?“ – Ja: wartet erneut (Aufgabe neu angestoßen); Nein: Hinweis mit Protokollpfad, erneut versuchbar. Ein später doch verarbeiteter Auftrag schadet nicht (nächster Versuch = „vorhanden“) |
| TPM voll (`Limit`) | „kein Platz (x von max. y) – IT kann alte Karten entfernen“, erneut versuchbar |
| TPM nicht bereit | „Gerät neu starten, dann erneut; sonst IT“ |
| Erstellung fehlgeschlagen | Fehlertext + Protokollpfad, erneut versuchbar |
| PIN-Änderung abgebrochen | Karte bleibt; nächster Start: gleiche Karte, Start-PIN wieder vorbelegt |
| PIN geändert, Ausstellung nicht fertig (CA/VPN) | nächster Start: gleiche Karte, **ohne** PIN-Dialog direkt zur Ausstellung |
| Gemerkte Karte gelöscht | wird automatisch neu angelegt |
| Zertifikat läuft in < 30 Tagen ab | Autostart öffnet sich wieder → Ausstellung auf derselben Karte (Verlängerung) |

**Grenzen / offen**
- Max. **10 VSCs pro TPM**; Aufräumen verwaister Karten (Benutzer weg) ist **nicht**
  automatisiert (bewusst: Löschen nur mit klarer Regel) — per „VSCs verwalten“ als Admin.
- Nur auf echten Geräten testbar: `-Install` (Admin), SYSTEM-Aufgabe legt Karte an,
  Anmelde-Aufgabe, mehrere Benutzer. Protokoll-/Fehlerlogik ist per Test ohne Admin
  abgedeckt (Austausch mit Test-Ordner, alle Fehlercodes, Ordner-/Dateirechte).
- Variante 1 (`-Provision`) bleibt als Alternative erhalten; ohne `-Install` nutzt `-Simple`
  automatisch die vorbereitete Karte.
## Offene Punkte / vor der Umsetzung zu klären

- **PIN-Zeichensatz/-länge** der VSC auf Hardware prüfen: Quell-PIN **alphanumerisch**
  (aus Seriennummer) beim Erstellen, Ziel-PIN **numerisch min. 6** bei der Änderung —
  beides muss die Karten-Policy akzeptieren (reine Mindestlängen-Policy sollte das).
- **Supplied-PIN im Helfer** (COM + nativer ARM64) [implementiert] auf HW testen.
- **Szenario 02 auf EJ-Clients** braucht On-Prem-TGT (Cloud Kerberos Trust) + erreichbare
  CA (Sichtverbindung/VPN). Ohne das schlägt die Ausstellung fehl → im `-Simple`-Modus
  klare Meldung „CA nicht erreichbar, später erneut / VPN".
- **User-UI aus App 2**: user-targeted Win32-Apps laufen im User-Kontext → GUI erscheint
  normal (kein ServiceUI nötig). Verifizieren.
- **Detection-Robustheit**: Marker + realer VSC-/Cert-Zustand kombinieren, damit Intune
  nicht „installiert" meldet, wenn die Karte fehlt.
- **Alternative geprüft & verworfen:** Intune-SCEP/PKCS-Profile können **nicht** in den
  Smartcard-KSP schreiben (nur TPM-/Software-KSP bzw. WHfB) → der Assistent bleibt nötig.

## Empfohlene Reihenfolge der Umsetzung

1. Tool-seitig: `-Simple`-Modus (reine PS/GUI, mit `Test-Flows.ps1` prüfbar) — kein
   Hardware-Risiko.
2. `New-VirtualSmartCard -Pin` (supplied-PIN) + `-Provision -Silent` — auf Hardware testen.
3. Marker/Detection + `.intunewin`-Paketierung + Zuweisung; Pilot auf einem Gerät.
