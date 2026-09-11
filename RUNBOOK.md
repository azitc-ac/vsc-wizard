# VSC-Wizard - Runbook

Handlungsanleitung pro Szenario: was das Tool automatisch tut **[Tool]**, was du
manuell machst **[Du]** und wo ein Faehigkeits-Check entscheidet **[Pruefung]**.
Dieses Runbook ist zugleich die fachliche Vorlage fuer die szenariobasierte
Oberflaeche (siehe README, Abschnitt "Startseite").

> **Status:** Die Engine (VSC-Erstellung, CSR, Submit, EOBO, Direkt-Einreichungs-
> pruefung) ist implementiert. Die **szenariobasierte Startseite**, der
> **headless-Submit (`-NoGui`)** und **`build.ps1`** sind in diesem Runbook
> spezifiziert und noch umzusetzen - sie sind hier als Soll beschrieben und
> entsprechend markiert.

---

## Grundprinzip: Faehigkeit, nicht Domain-Join

Ob direkt bei der CA eingereicht werden kann, haengt **nicht** am Maschinen-Status
(DJ/EJ), sondern an der gemessenen Faehigkeit dieses Rechners:

1. On-Prem-Kerberos-Ticket (TGT) vorhanden?
2. DC-/DNS-Lokalisierung funktioniert?
3. CA per RPC erreichbar (`certutil -ping`)?

Der Button **"Direkt-Einreichung pruefen"** misst das und waehlt den Weg:

- **geht** -> direkt einreichen (frueher "Plan A"),
- **geht nicht** -> CA-Schritt delegieren (frueher "Plan B": Einreichung als
  Zielkonto auf einem CA-nahen Host, danach Uebernahme lokal).

Ein DJ-Client kann off-net scheitern; ein EJ-Client mit funktionierendem Cloud
Kerberos Trust + korrektem On-Prem-DNS kann direkt einreichen.

## Was laeuft wo

| Ort | Oberflaeche |
|---|---|
| Deine Workstation (Full Desktop, Win10/11) | **GUI** (WinForms) - der Szenario-Wizard |
| CA-naher Einreich-/Sprung-Host, **Server Core** | **Konsole/headless** - `VscWizard.Submit.ps1 -NoGui` (kein WinForms auf Server Core) |

Grund: Server Core hat kein verlaessliches GUI-Subsystem; PowerShell auf der
Konsole laeuft dort aber einwandfrei. Details siehe Abschnitt
"Plan-B-Submit auf Server Core".

## Wichtige Rahmenbedingung: VSC-Bindung

Eine TPM-VSC ist **an das TPM der Maschine gebunden, auf der sie erstellt wird**,
und nicht uebertragbar. Regel: **Die VSC dort erstellen, wo die Karte spaeter
genutzt wird** (z.B. auf der Workstation, von der aus du RDP-Verbindungen
aufbaust). Eine zentral auf fremdem TPM erzeugte VSC ist fuer das Zielkonto
wertlos.

---

## Szenario 01 - Neues SC-only-Admin-Konto einrichten (Bootstrap)

**Wann:** Ein Konto soll Smartcard-only werden, hat aber noch keine Karte -
klassisches Henne-Ei-Problem (ohne Karte keine Anmeldung, ohne Anmeldung keine
Einreichung).

**Voraussetzungen:** bereites TPM auf der Zielmaschine; Recht, das Zielkonto
kurzzeitig auf Passwort-Anmeldung zu stellen; erreichbare CA (direkt oder ueber
einen Einreich-Host).

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Du]** | Zielkonto **temporaer auf Passwort-Anmeldung** zulassen ("Smartcard erforderlich" voruebergehend aus). Noetig, weil ein kartenloses SC-only-Konto sich sonst nirgends anmelden kann. |
| 2 | **[Tool]** | VSC **auf dieser Maschine** erstellen, PIN vergeben (`tpmvscmgr create`). |
| 3 | **[Tool]** | CSR erzeugen - der private Schluessel entsteht auf der VSC. |
| 4 | **[Pruefung]** | Direkt-Einreichung moeglich? **ja** -> [Tool] direkt bei der CA einreichen. **nein** -> [Du] per RDP als Zielkonto auf einen Einreich-Host, dort Submit (siehe Server-Core-Abschnitt, wenn der Host Server Core ist). |
| 5 | **[Tool]** | Ausgestelltes Zertifikat auf die VSC uebernehmen (`certreq -accept`). |
| 6 | **[Du]** | Zielkonto wieder auf **"Smartcard erforderlich"** setzen, Passwort-Anmeldung deaktivieren. |

**Guardrails:**
- Das Passwort ist ein **einmaliger** Bootstrap. Der Wizard erinnert am Ende an
  Schritt 6 (Rueckstellung auf SC-only).
- VSC nicht auf einem fremden TPM erzeugen (siehe VSC-Bindung oben).

**Ergebnis:** Konto ist SC-only mit gueltiger VSC. Kuenftige Verlaengerungen
laufen **ohne** Passwort (Szenario 02).

**Troubleshooting:** Schlaegt die Direkt-Einreichung fehl, zeigt die Pruefung den
konkreten Grund (kein TGT / DNS / RPC). Kein bereites TPM -> VSC-Erstellung nicht
moeglich.

---

## Szenario 02 - Zertifikat verlaengern (vor Ablauf)

**Wann:** Ein SC-only-Konto hat eine **noch gueltige** VSC; das Zertifikat laeuft
bald ab.

**Voraussetzung:** mindestens eine noch nicht abgelaufene VSC/Zertifikat (die
Kette braucht eine gueltige Karte als Anmeldemittel).

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Tool]** | Vorhandene VSC + Zertifikat erkennen, **Restlaufzeit** anzeigen. |
| 2 | **[Du]** | Mit der **gueltigen Karte** anmelden - beim delegierten Weg per **Smartcard-Redirect** ins Einreich-Host, **kein Passwort noetig**. |
| 3 | **[Tool]** | Neuen CSR erzeugen und einreichen (direkt oder delegiert). |
| 4 | **[Tool]** | Neues Zertifikat auf die bestehende VSC uebernehmen. |

**Der Trick:** Die noch gueltige Karte ersetzt das Passwort - deshalb
**rechtzeitig** verlaengern.

**Wenn bereits abgelaufen:** Kein Chain moeglich, es fuehrt kein passwortfreier
Weg mehr hinein -> zurueck zu **Szenario 01 (Bootstrap)** mit temporaerem
Passwort.

**Ergebnis:** frisches Zertifikat auf derselben VSC, Kette bleibt intakt.

---

## Szenario 03 - VSC fuer dieses Konto direkt ausstellen

**Wann:** Fuer das aktuell angemeldete Konto, wenn die CA von hier erreichbar ist
(DJ-Client oder EJ-Client mit funktionierendem Cloud Kerberos Trust).

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Pruefung]** | Direkt-Einreichung pruefen (Kerberos-Ticket, DNS, `certutil -ping`). |
| 2 | **[Tool]** | VSC erstellen, PIN vergeben. |
| 3 | **[Tool]** | CSR -> direkt einreichen -> Zertifikat uebernehmen. Ein durchgehender Ablauf. |

**Ergebnis:** VSC mit Logon-Zertifikat fuer dich, ohne Umweg.

**Hinweis:** Scheitert Schritt 1 auf einem EJ-Client, ist meist CKT oder On-Prem-
DNS das Problem (siehe Abschnitt "Direkt-Einreichung pruefen").

---

## Szenario 04 - Cloud-Global-Admin: Smartcard + VSC (Entra)

**Wann:** Ein Cloud-Konto (Entra Global Admin) soll phishing-resistent anmelden -
mit einem portablen YubiKey **und** einer VSC als Alternative/Fallback.

### Teil A - lokal (Tool)

| # | Wer | Schritt |
|---|---|---|
| A1 | **[Tool]** | Zertifikat provisionieren: **YubiKey (PIV, geraetuebergreifend/portabel)** und/oder **VSC (maschinengebunden)** als Alternative. |

### Teil B - Entra, Variante CBA (Du, Checkliste/Runbook)

| # | Wer | Schritt |
|---|---|---|
| B1 | **[Du]** | Ausstellende CA in den **Entra-Vertrauensspeicher** importieren (Certificate Authorities / PKI-based trust store). |
| B2 | **[Du]** | **CBA** als Authentifizierungsmethode aktivieren; **Username-Binding** festlegen (z.B. SAN PUN oder SKI); Auth-Bindung = MFA. |
| B3 | **[Du]** | **CRL-Endpunkte fuer Entra oeffentlich erreichbar** sicherstellen - haeufigster Stolperstein. |

### Teil B (Alternative) - FIDO2/Passkey

- **[Du]** FIDO2/Passkey auf demselben YubiKey registrieren - phishing-resistent,
  **ohne** PKI-in-Entra-Klempnerei.
- **Empfehlung:** FIDO2 ist der leichtere Cloud-Weg. **CBA** nur waehlen, wenn du
  bewusst **dieselbe Zert-Identitaet** on-prem **und** in der Cloud willst.

**Ergebnis:** Cloud-GA meldet sich per CBA (Smartcard/VSC) oder FIDO2 (Passkey)
an; die VSC dient als Fallback zur physischen Karte.

**Charakter:** Teil B ist ueberwiegend Checkliste mit Links - das Tool
dokumentiert, was wo noetig ist, statt es zu automatisieren (Entra-Konfiguration
ist Portal-/Graph-seitig).

---

## Szenario 05 - VSCs verwalten

**Wann:** Ueberblick vor Verlaengerung/Neuausstellung oder Aufraeumen.

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Tool]** | Inventar: VSC-Reader, Karteninhalt, Zertifikate mit Ablaufdatum und Provider. |
| 2 | **[Du]** | Ganze Karte loeschen - ueber `tpmvscmgr destroy` (zuverlaessiger als die COM-API, siehe README "Bekannte Einschraenkungen"). |
| 3 | **[Du]** | EINZELNES Zertifikat von einer Karte entfernen (z.B. versehentlich zusaetzlich aufgespieltes): Zertifikat in der Liste waehlen -> "Zertifikat von Karte entfernen". Zeigt Konto (UPN)/Subject/Thumbprint zur Kontrolle und entfernt nur diesen Schluessel-Container (`certutil -delkey`), andere Zertifikate der Karte bleiben. |

---

## Szenario 06 - Fuer ein anderes Konto ausstellen (EOBO) [Fortgeschritten]

**Wann:** Direkt-Ausstellung fuer ein separates Konto ohne dessen Anmeldung -
ueber ein Enrollment-Agent-Zertifikat (Enroll on Behalf Of).

> **ESC3 - sicherheitskritisch.** Ein EA-Zertifikat, mit dem sich Logon-Certs fuer
> Admins ausstellen lassen, ist **admin-aequivalent**: wer es besitzt, kann sich
> als diese Konten anmelden. Fuer Admin-Zielkonten ist **Self-Enrollment
> (Szenario 01/02) meist die sicherere Wahl.** EOBO nur als bewusste Ausnahme:
> Restricted Enrollment Agent auf der CA, EA-Schluessel auf Hardware/VSC,
> auditiert.

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Tool]** | EA-Zertifikat im Speicher erkennen; EOBO-Antrag bauen: `RequesterName=Zielkonto`, **Build-from-AD-Template** (die CA fuellt Subject + UPN des Zielkontos aus dem AD). |
| 2 | **[Tool]** | Antrag mit dem EA-Zertifikat co-signieren (`certreq -new -cert <EA>`), einreichen, auf VSC uebernehmen. |

**CA-Voraussetzung:** Ziel-Template erlaubt EOBO; Antragsteller ist als
(Restricted) Enrollment Agent zugelassen.

**Template-Wahl:** **Build from AD** verwenden, **nicht** "Supply in request" -
sonst muesste die Ziel-UPN manuell exakt geliefert werden, und ein Fehler bricht
den Smartcard-Logon des Zielkontos.

---

## Plan-B-Submit auf Server Core (headless) [geplant]

Wenn der Einreich-/Sprung-Host **Server Core** ist, laeuft dort **keine GUI**. Der
Einreichungsschritt erfolgt dann ueber den headless-Modus des Submit-Helfers:

```
VscWizard.Submit.ps1 -NoGui -CAConfig "<Server\CA-Name>" -Template "<TemplateName>" -CsrPath "<Pfad\request.csr>" [-OutputDirectory "<Pfad>"]
```

- Laeuft rein auf der Konsole (kein WinForms), damit Server-Core-tauglich.
- Fuehrt `certreq -submit` als das angemeldete (Ziel-)Konto aus und legt die
  `.cer` ab; die Uebernahme auf die VSC passiert wieder auf der Workstation.
- Full-Desktop-Hosts nutzen weiterhin die GUI-Variante des Helfers.

---

## Direkt-Einreichung pruefen (Referenz)

Die Pruefung (`Test-DirectEnrollmentCapability`) laeuft als Hintergrund-Job
(~45 s Timeout) und liefert pro Stufe eine Klartext-Begruendung:

| Stufe | Pruefung | Bedeutung bei Fehlschlag |
|---|---|---|
| 1 | Join-Kontext (`dsregcmd`, `OnPremTgt`) | nur Information |
| 2 | On-Prem-Kerberos-TGT (`klist`) | keine authentifizierbare AD-Identitaet (EJ ohne funktionierendes CKT) |
| 3 | CA-Ziel bestimmbar (Config/AD-Discovery) | meist DNS-/DC-Locator-Problem |
| 4 | CA-Server per DNS aufloesbar | Client nutzt nicht den On-Prem-DNS |
| 5 | `certutil -ping` (Transport + Auth) | RPC/DCOM (Port 135 + dyn. Ports) blockiert oder CA weist ab |

Erfolg bei Stufe 5 => direkte Einreichung moeglich. **Hinweis:** `ping` beweist
Transport + Authentifizierung, **nicht** die Enroll-Berechtigung auf dem Template
- die zeigt sich erst beim echten Submit.

---

## Packaging: Single-Exe + Signatur [geplant]

Ziel: eine anklickbare `.exe` fuer einfache Bedienung und weniger lose Dateien -
ohne neue Abhaengigkeit (die eingebaute Windows PowerShell 5.1 genuegt).

### build.ps1

1. **Merge:** `modules/VscWizard.Core.psm1` in eine Kopie von `VscWizard.ps1`
   einbetten (statt `Import-Module` zur Laufzeit). **Wichtig fuer ExecutionPolicy
   Restricted**, siehe unten.
2. **Wrappen** mit Win-PS2EXE:
   `-STA` (WinForms), `-noConsole`, `-requireAdmin` (UAC fuer `tpmvscmgr`),
   `-iconFile <icon>`, Versionsinfo.
3. **Config bleibt extern** (neben der Exe bzw. in `%APPDATA%`), vom
   Einstellungen-Dialog geschrieben - nicht in die Exe einbacken.
4. **Signieren** (`Set-AuthenticodeSignature`) mit einem internen
   Code-Signing-Zertifikat, um SmartScreen/AV-Warnungen zu vermeiden.

### ExecutionPolicy und CLM - was die Exe loest und was nicht

- **ExecutionPolicy (auch Restricted/AllSigned):** PS2EXE fuehrt den **eingebetteten
  Code in-memory** aus und laedt **keine `.ps1`/`.psm1` von der Platte** ->
  ExecutionPolicy (ein Datei-Gate) greift **nicht**. **Bedingung:** der Merge aus
  Schritt 1, damit zur Laufzeit kein Datei-Load stattfindet. Die Exe **hilft** hier
  also.
- **AppLocker / WDAC mit Constrained Language Mode:** CLM kann die gehostete
  PowerShell einschraenken und WinForms/`Add-Type` brechen; WDAC kann unsignierte
  `.exe` blocken. In solchen Umgebungen ist **Signieren Pflicht**, und nur ein
  echter C#/.NET-Standalone waere gegen CLM immun. Das ist der einzige Fall, in dem
  die PS2EXE-Exe an Grenzen stoesst - ansonsten nicht noetig.

### Server Core

Bekommt **nicht** die GUI-Exe, sondern die schlanke `VscWizard.Submit.ps1`
(Konsole/`-NoGui`).

---

## Anhang: Konfigurationsschluessel (`config.psd1`)

| Schluessel | Bedeutung |
|---|---|
| `Template` | Zertifikatstemplate fuer die VSC-Anmeldung |
| `CAConfig` | CA-Konfigurationsstring `Server\CA-Name` |
| `CspName` | Provider (CSP/KSP), muss zum Template passen |
| `VscNamePrefix` | Namenspraefix fuer virtuelle Smartcards |
| `RdpJumpServer` | CA-naher Einreich-/Sprung-Host fuer den delegierten Weg |
| `DiscoveryDomain` | AD-Domaene/DC fuer die PKI-Erkennung (v.a. EJ/Workgroup) |
| `EATemplate` | Template fuer das Enrollment-Agent-Zertifikat (Szenario 06) |
| `WorkingDir` | Arbeitsverzeichnis (leer = TEMP) |
