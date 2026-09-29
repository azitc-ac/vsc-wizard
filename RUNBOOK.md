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

## Szenario 01 - VSC fuer fremdes onprem-/hybrid-Konto

**Wann:** Eine VSC fuer ein SEPARATES On-Prem-Admin-Konto (nicht das gerade
angemeldete). Ausstellung per **EOBO** (mit Enrollment-Agent-Zertifikat, ohne RDP)
oder per **Plan B / Bootstrap** (Einreichung ALS das Zielkonto per RDP; bei
Erstausstellung ggf. einmalig Passwort-Anmeldung erlauben).

**Neue oder bestehende VSC:** Der Wizard fragt, ob eine neue VSC erstellt oder eine
vorhandene als Schluesseltraeger verwendet werden soll (letzteres ersetzt das
fruehere "Erneuern"). Die Identitaet kommt IMMER aus dem angegebenen Zielkonto,
nicht aus der Karte.

**Voraussetzungen:** bereites TPM (fuer eine neue VSC); erreichbare CA (direkt oder
ueber einen Einreich-Host); fuer den Bootstrap-Weg das Recht, das Zielkonto kurz auf
Passwort-Anmeldung zu stellen.

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Du]** | Separates Admin-Konto angeben. |
| 2 | **[Du]** | Neue VSC erstellen ODER eine bestehende verwenden. |
| 3 | **[Pruefung]** | Mit EA-Zertifikat: **EOBO** (Plan A, ohne RDP). Sonst: **Plan B** - Submit ALS das Zielkonto per RDP (bei Erstausstellung ggf. Konto kurz auf Passwort-Anmeldung; danach zurueck auf "Smartcard erforderlich"). |
| 4 | **[Tool]** | CSR erzeugen, einreichen, Zertifikat auf die VSC uebernehmen. |

**Guardrails:** Ein Bootstrap-Passwort ist einmalig; danach Konto wieder SC-only.
Das EA-Zertifikat ist admin-aequivalent (ESC3, siehe Szenario 05).

**Warum kein eigenes "Erneuern" mehr:** Es findet ohnehin keine echte Verlaengerung
statt (jeder Antrag ist eine Neuausstellung mit neuem Schluessel). Daher ist
"bestehende VSC verwenden" nur eine Option innerhalb der Konto-Szenarien 01-03. Eine
VSC laeuft nie ab - nur das Zertifikat darauf; "bestehende verwenden" funktioniert
also auch bei bereits abgelaufenem Zertifikat.

---

## Szenario 02 - VSC fuer eigenes onprem-/hybrid-Konto

**Wann:** Fuer das AKTUELL angemeldete Konto (reines On-Prem-AD-Konto oder hybrid
synchronisiert), wenn die CA von hier erreichbar ist (DJ-Client oder EJ-Client mit
funktionierendem Cloud Kerberos Trust). Direkt-Ausstellung als du selbst.

**Neue oder bestehende VSC:** wie in Szenario 01 - neu erstellen oder eine
vorhandene Karte weiterverwenden.

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Du]** | Neue VSC erstellen ODER eine bestehende verwenden. |
| 2 | **[Pruefung]** | Direkt-Einreichung pruefen (Kerberos-Ticket, DNS, `certutil -ping`). |
| 3 | **[Tool]** | CSR -> direkt einreichen (als du) -> Zertifikat auf die VSC uebernehmen. |

**Ergebnis:** VSC mit Logon-Zertifikat fuer dich, ohne Umweg.

**Hinweis:** Scheitert die Pruefung auf einem EJ-Client, ist meist CKT oder
On-Prem-DNS das Problem (siehe Abschnitt "Direkt-Einreichung pruefen").

---

## Szenario 03 - VSC fuer fremdes Cloud-only-Konto (Entra CBA)

> **Nur fuer reine Cloud-Konten.** Existiert das Konto auch im lokalen AD (Hybrid-Konto),
> ist Szenario 01 (fremdes Konto) bzw. 02 (eigenes Konto) richtig: deren Zertifikat traegt
> die Konto-SID und funktioniert fuer Entra CBA UND lokales Kerberos. Der Wizard prueft das
> nach der UPN-Eingabe per LDAP (wenn das AD erreichbar ist) und bietet den Wechsel an.

**Wann:** Ein CLOUD-ONLY-Konto (Entra, kein On-Prem-Pendant) soll ein Zertifikat
fuer **Entra CBA** bekommen. Du reichst als DU (ein Enroll-berechtigtes AD-Konto)
direkt bei der On-Prem-CA ein; die Ziel-UPN steht im CSR-SAN (Supply-in-request /
Offline-Template). Die On-Prem-CA ist hier nur Zertifikatsfabrik.

> **NUR Cloud/CBA - NICHT fuer On-Prem-Logon.** Ein Offline-Template bettet keine
> Konto-SID ein (starke Zuordnung, KB5014754) -> der KDC lehnt On-Prem-Smartcard-
> Logon ab. Fuer On-Prem-Konten stattdessen Szenario 01 oder 05 (Build-from-AD
> bettet die SID ein). Zusaetzlich ESC1: mit Supply-in-request + SAN ist jede UPN
> praegbar -> Template zusperren (enge Enroll-ACL, ggf. Manager-Approval).

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Du]** | Cloud-Zielkonto/UPN angeben (Entra). |
| 2 | **[Du]** | Neue VSC erstellen ODER eine bestehende verwenden. |
| 3 | **[Tool]** | CSR mit Ziel-UPN im SAN (Offline-Template). |
| 4 | **[Pruefung]** | Als DU direkt bei der CA einreichen (Enroll-Recht auf dem Offline-Template). |
| 5 | **[Tool]** | Zertifikat auf die VSC uebernehmen. |
| 6 | **[Du]** | In Entra: ausstellende CA importieren; CBA aktivieren; Username-Binding auf UPN; CRL oeffentlich erreichbar. |

**Alternative (ohne PKI):** FIDO2/Passkey - der leichtere Cloud-Weg. CBA nur, wenn
du bewusst dieselbe Zert-Identitaet on-prem und in der Cloud willst.

**Charakter:** Der Entra-Teil (Schritt 6) ist Checkliste mit Links - das Tool
dokumentiert, was wo noetig ist, statt die Entra-Konfiguration zu automatisieren.

---

## Szenario 04 - VSCs verwalten

**Wann:** Ueberblick vor Verlaengerung/Neuausstellung oder Aufraeumen.

| # | Wer | Schritt |
|---|---|---|
| 1 | **[Tool]** | Inventar: VSC-Reader, Karteninhalt, Zertifikate mit Ablaufdatum und Provider. |
| 2 | **[Du]** | Ganze Karte loeschen - ueber `tpmvscmgr destroy` (zuverlaessiger als die COM-API, siehe README "Bekannte Einschraenkungen"). |
| 3 | **[Du]** | EINZELNES Zertifikat von einer Karte entfernen (z.B. versehentlich zusaetzlich aufgespieltes): Zertifikat in der Liste waehlen -> "Zertifikat von Karte entfernen". Zeigt Konto (UPN)/Subject/Thumbprint zur Kontrolle und entfernt nur diesen Schluessel-Container (`certutil -delkey`), andere Zertifikate der Karte bleiben. |

---

## Szenario 05 - Fuer ein anderes Konto ausstellen (EOBO) [Fortgeschritten]

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

## Packaging: Single-Exe + Signatur (`build.ps1`)

Ziel: eine anklickbare `.exe` fuer einfache Bedienung und weniger lose Dateien -
ohne neue Abhaengigkeit (die eingebaute Windows PowerShell 5.1 genuegt).

### build.ps1

`.\build.ps1` (einmalig Win-PS2EXE aus der PSGallery), optional
`.\build.ps1 -CertThumbprint <Thumbprint>` zum Signieren. Erzeugt in `dist\`:

1. **`VscWizard.Submit.exe`** - der Einreicher-Helfer als **echte Einzeldatei**
   (self-contained, keine Nebendateien). Auf den RDP-/Einreich-Host kopieren.
2. **`VscWizard.exe`** - der Haupt-Wizard. Bewusst **nicht** gemergt: der Wizard
   startet Hintergrund-Jobs, die `VscWizard.Core.psm1` zur Laufzeit vom Pfad
   nachladen - ein Inline-Merge wuerde die brechen. Daher als **Drop-in-Ersatz**
   fuer `.ps1`/`.bat` verteilen, zusammen mit dem Ordner `modules\` und
   `config.psd1` DANEBEN.

Beide werden mit `-STA` (WinForms) und `-noConsole` (reine GUI) gebaut. **Kein
`-requireAdmin`**: der Wizard MUSS im Kontext des angemeldeten Benutzers laufen
(er eleviert nur einzelne Aktionen wie `tpmvscmgr`/`certutil` selbst) - ein global
elevierter Prozess wuerde z.B. den falschen Zertifikatsspeicher sehen.

### ExecutionPolicy und CLM

- **PS2EXE fuehrt den eingebetteten Code in-memory aus** - ExecutionPolicy (ein
  Datei-Gate fuer `.ps1`/`.psm1`) greift auf den Exe-Start nicht. `VscWizard.Submit.exe`
  ist damit voll ExecutionPolicy-unabhaengig. Der Haupt-Wizard startet zwar
  Kind-Prozesse, die Skripte vom Datentraeger laden - diese rufen `powershell.exe`
  aber mit `-ExecutionPolicy Bypass` bzw. beziehen sich auf die mitgelieferten
  Modul-/Lookup-Dateien; auf einer streng per Policy gesperrten Maschine ist das
  vor dem Ausrollen zu verifizieren.
- **AppLocker / WDAC mit Constrained Language Mode:** CLM kann die gehostete
  PowerShell einschraenken und WinForms/`Add-Type` brechen; WDAC kann unsignierte
  `.exe` blocken. Dort ist **Signieren Pflicht**, und nur ein echter
  C#/.NET-Standalone waere gegen CLM immun - der einzige Fall, in dem die PS2EXE-Exe
  an Grenzen stoesst.

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
| `EATemplate` | Template fuer das Enrollment-Agent-Zertifikat (Szenario 05) |
| `WorkingDir` | Arbeitsverzeichnis (leer = TEMP) |
