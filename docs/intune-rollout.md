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

## Start-PIN aus dem Computernamen

- Muss die **PIN-Richtlinie** erfüllen (Mindestlänge `config.PinMinLength`, Default 6,
  geklemmt 4–20) und den **erlaubten Zeichensatz** der VSC.
- Deterministische Ableitung (Vorschlag): Computername nehmen, auf erlaubte Zeichen
  reduzieren, auf Mindestlänge **auffüllen** (fixe, dokumentierte Regel), auf Maximallänge
  kürzen. Muss reproduzierbar sein, damit App 2 die Start-PIN kennt (beide leiten sie
  identisch aus `$env:COMPUTERNAME` ab).
- **Auf Hardware zu verifizieren:** erlaubter PIN-Zeichensatz einer TPM-VSC (numerisch
  vs. alphanumerisch je nach Policy). Notfalls Policy anpassen oder rein numerische
  Ableitung (z.B. Hash des Computernamens → Ziffern).

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

## Offene Punkte / vor der Umsetzung zu klären

- **PIN-Zeichensatz/-länge** der VSC (numerisch vs. alphanumerisch) → Start-PIN-Ableitung
  daran ausrichten. Auf Hardware prüfen.
- **Supplied-PIN im Helfer** (COM + nativer ARM64) implementieren und testen.
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
