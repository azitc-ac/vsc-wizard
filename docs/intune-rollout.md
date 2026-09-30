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

### Variante 2 — eine Karte pro Benutzer (DESIGN, nicht umgesetzt)

Ziel: Jeder Hybrid-Benutzer, der sich anmeldet und noch keine Karte hat, bekommt eine.

**Bausteine (App 1 installiert sie, statt selbst eine Karte anzulegen):**

1. **Wizard fest installieren** nach `%ProgramFiles%\VSC-Wizard` (nur Admins schreibbar —
   wichtig, weil eine SYSTEM-Aufgabe ihn ausführt).
2. **SYSTEM-Aufgabe „VSC-Wizard\CreateCard“** (Aufgabenplanung, Konto SYSTEM, kein
   Auslöser, nur bei Bedarf): `VscWizard.exe -Provision -Silent -ForUser`. Ihre
   Sicherheitsbeschreibung erlaubt **Benutzern nur das Starten** (Lesen+Ausführen), nicht
   das Ändern.
   - Für **welchen** Benutzer? Nicht aus einer vom Benutzer beschreibbaren Datei
     vertrauen, sondern selbst ermitteln: die interaktiv angemeldeten Sitzungen
     (WTSEnumerateSessions / Besitzer von explorer.exe) → deren SIDs.
   - Pro SID höchstens **eine** Karte: HKLM-Marker je Benutzer
     (`HKLM\SOFTWARE\VSC-Wizard\Users\<SID>\InstanceId`); Karte `VSC-<sAMAccountName>`.
   - Missbrauchsschutz: nie mehr als eine Karte pro SID, Obergrenze pro Gerät (z.B. 8 von
     max. 10 VSCs pro TPM), Protokoll in `C:\ProgramData\VSC-Wizard\provision.log`.
3. **Benutzer-Aufgabe „VSC-Wizard\Setup“** (Gruppe „Benutzer“, interaktiv, Auslöser
   „bei Anmeldung eines beliebigen Benutzers“, leicht verzögert):
   `VscWizard.exe -Simple -AutoStart`:
   - **Beenden ohne Fenster**, wenn: kein Hybrid-Konto (kein On-Prem-TGT / keine
     onprem-UPN), eigenes Zertifikat schon vorhanden (HKCU-Marker + Karte), oder
     Benutzer hat „später“ gewählt (Zurückstellen mit Datum, sonst nervt es bei jeder
     Anmeldung).
   - Sonst: eigene Karte suchen (`Find-ProvisionedVsc` pro SID); fehlt sie →
     `Start-ScheduledTask 'VSC-Wizard\CreateCard'`, auf die Karte warten (Timeout, klare
     Meldung) → dann der bekannte Simple-Ablauf.
4. **Intune:** nur noch **eine** Device-App (installiert Wizard + beide Aufgaben).
   Erkennung: Programmordner + Aufgaben vorhanden. App 2 entfällt (die Aufgabe übernimmt).

**Aufräumen:** Benutzer verlässt das Gerät → Karte bleibt belegt. Optional SYSTEM-
Aufgabe „Cleanup“ (z.B. wöchentlich): Karten zu SIDs ohne Profil auf dem Gerät bzw.
mit abgelaufenem Zertifikat nach Frist entfernen (`tpmvscmgr destroy`) — vorsichtig,
nur mit Protokoll und klarer Regel.

**Grenzen / Risiken:**
- Max. **10 VSCs pro TPM** → echte Grenze für Gemeinschafts-/Schichtgeräte.
- Die Start-PIN (Seriennummer) wäre für **alle** Karten eines Geräts gleich → pro Karte
  variieren (z.B. Seriennummer + sAMAccountName ableiten), sonst kann Benutzer A die
  frisch angelegte Karte von B vor B einrichten.
- Anmelde-Aufgabe + SYSTEM-Aufgabe sind nur auf echten Geräten mit Intune sinnvoll
  testbar (mehrere Benutzerkonten, Hybrid + Nicht-Hybrid, Offline-Anmeldung ohne CA).

**Aufwand (Schätzung):** einige Tage Entwicklung (Aufgaben anlegen/absichern, Sitzungs-
ermittlung, per-SID-Marker, `-AutoStart`-Logik mit Zurückstellen, Cleanup) plus Pilot.

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
