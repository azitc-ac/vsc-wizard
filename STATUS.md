# Projektstand & Backlog (VSC-Wizard)

> Kurzes „wo stehen wir"-Dokument, damit der Faden zwischen Testrunden nicht reißt.
> Ergänzt das RUNBOOK.md (das die Szenarien/Abläufe beschreibt).

## Arbeitsweise: „Geschwister-Suchlauf" (verbindlich)

Vor JEDEM Fix: erst per Suche ALLE Stellen finden, die dasselbe Symptom/dieselbe
Logik teilen, und **gemeinsam** beheben — nicht nur die eine aufgefallene Stelle.
Bevorzugt die Logik an **einer** Stelle zentralisieren (eine Funktion als „Quelle der
Wahrheit"), damit Aufrufer nicht auseinanderdriften. Beispiel-Lehrgeld: der
TPM-Check war zuerst nur im Startseiten-Banner korrigiert, nicht im Plan-A-Status —
jetzt beides über `Test-TpmReadiness` zentralisiert.

## Erledigt / funktioniert (Stand zuletzt getestet)

- **Einreicher-Helfer, doppeltes BEGIN/END behoben** (Commit `197d622`).
  `certreq -submit` schreibt `certnew.cer` bereits als PEM; das frühere
  `certutil -encode` umschloss es ein **zweites** Mal. Jetzt lädt der Helfer das
  Zertifikat als `X509Certificate2` und schließt den DER-Inhalt selbst **einfach**
  um → genau ein BEGIN/END. **Wichtig:** die `.exe` muss nach `git pull` mit
  `.\build.ps1` **neu gebaut** werden (Pull ändert nur die `.ps1`).
- **„Zum Startbildschirm"-Button** auf den Abschluss-Panels von Plan A und Plan B
  (immer zurück zur Szenario-Auswahl, unabhängig vom Einstieg).
- **Renewal-Cleanup kartenbezogen** (Commit `51e55ec`). Früher stiller Skip, weil
  nach **Konto-UPN** gefiltert wurde: bei Build-from-AD trägt der ausgestellte Cert
  die **AD-UPN** (`…@contoso.com`), nicht den Antrags-Term (`…@contoso.local`). Jetzt:
  neuestes Cert der Karte behalten, ältere auf **derselben Karte** zum Entfernen
  anbieten; **jeder** Abbruchgrund + jede Entfernung wird geloggt.
- **Zusammenfassung zeigt Gültigkeit je Zertifikat**, wenn mehrere auf der Karte
  liegen (die Karte selbst hat kein Ablaufdatum).
- **Eleviertes `delkey`-PowerShell-Fenster versteckt** (`-WindowStyle Hidden`,
  Commit `473e0ee`) → kein Konsolen-Flackern beim Aufräumen; nur UAC bleibt.
- **T1-Karte `VSC-T1`** erfolgreich re-enrolled (gültig bis 2027).
- **Cloud-GA real ausgestellt** über **Offline-Template (Supply-in-request)**:
  Einreichung als AD-Account, CA-Manager-**Genehmigung**, und **Wiederaufnahme
  nach Genehmigung** (retrieve pending) durch den Helfer bestätigt. Das
  Offline-Template war essentiell dafür.

## Erkenntnisse / mentales Modell (nicht wieder verlieren)

- **Eine VSC läuft nie ab — nur das Zertifikat darauf.** „Verlängern" = frisches
  Cert auf die weiter funktionierende Karte. Es ist ein **Re-Enroll** (neuer
  Schlüssel via `certreq -new`), kein echtes Renewal (gleicher Schlüssel).
- **Plan B authentifiziert per Passwort/Kerberos des Zielkontos** (RDP als
  Zielkonto), **nicht** per Kartenzertifikat → funktioniert auch bei **abgelaufenem**
  Cert. Der Szenario-02-Text („abgelaufen → nicht möglich") gilt nur für den
  Cert-Chain-/Smartcard-Redirect-Weg, nicht für den Passwort/RDP-Weg.
- **Cloud-only-Konto = im AD niemand** → kann sich **nicht** an der On-Prem-AD-CS
  authentifizieren. Manuelle CA-Eingabe im Helfer löst nur die **Discovery**
  (`-config`), nicht die **Authentifizierung**. CKT gibt nur *synchronisierten*
  Usern einen On-Prem-TGT; ein cloud-only-Konto bekommt nie einen.
- **Cloud-GA-Cert ist für Entra CBA**, nicht für On-Prem-Smartcard-Logon. Die
  On-Prem-CA ist nur **Zertifikatsfabrik**; Entra vertraut der hochgeladenen
  CA-Kette und mappt per **SAN-UPN**. Der Einreicher ist Entra egal.
- **Offline-Template (Supply-in-request)** entkoppelt Cert-**Inhalt** vom
  **Einreicher**: Subject/SAN kommen aus dem CSR (Tool schreibt `2.5.29.17 upn=…`),
  Einreicher = beliebiger **Enroll-berechtigter AD-Account**.
  - Sicherheitsnuance (ESC1-Geschmack): wer enrollen darf, kann jede UPN prägen →
    Template **zusperren** (enge Enroll-ACL, ggf. Manager-Approval).
- **WICHTIG — Offline-Template taugt NICHT für On-Prem-Smartcard-Logon.** Der KDC
  (PKINIT) verlangt seit **KB5014754** (Full Enforcement default seit Feb 2025) eine
  **starke** Zert-zu-Konto-Zuordnung. Die kommt aus der **SID-Erweiterung**
  `szOID_NTDS_CA_SECURITY_EXT` (1.3.6.1.4.1.311.25.2), die die CA **nur bei
  Build-from-AD** einbettet (Submit *als* Zielkonto, oder EOBO). Supply-in-request
  bettet keine (bzw. die falsche = Einreicher-)SID ein → schwache/keine Zuordnung →
  **Logon abgelehnt**. UPN-im-SAN allein reicht nicht mehr. → **On-Prem-Konten:
  EOBO (06) oder Bootstrap/RDP (01).** **Entra CBA (Cloud):** braucht keine AD-SID,
  mappt per UPN/Binding + vertraut der CA-Kette → Offline-Template ist DER Weg.
  (Escape-Hatch für On-Prem-Offline-Certs: **starke** `altSecurityIdentities` am
  Zielkonto — X509 Issuer+Serial / SKI / SHA1-PublicKey. **Wird NICHT im Wizard gebaut**
  (Entscheidung 2026-09-29): bei uns läuft das **server-seitig** — ein DC-Listener greift
  das KDC-Weak-Mapping-Event (i.d.R. ID 39, Quelle *Kerberos-Key-Distribution-Center*)
  ab und schreibt automatisch die starke Bindung, beim nächsten Logon wirkt sie.
  Zentral, rechtekonform, kein Client-Schreibrecht nötig → dem Client-Feature überlegen.
  Der bestehende Listener wird bei Gelegenheit gemeinsam reviewt. **Folge:** in einer
  Umgebung mit solcher Auto-Remediation gilt „Offline = nur Cloud" faktisch nicht mehr
  (Szenario-03-Cert wird on-prem beim 2. Versuch nutzbar) - der **allgemeine Guard im
  Tool bleibt aber konservativ**, da nicht jede Org den Listener hat.)
- **CBA-Stolperstein:** CRL/CDP muss für **Entra erreichbar** sein (On-Prem-CDP ist
  oft nur intern) → sonst kann der CBA-Login an der Sperrprüfung scheitern.
  Binding **UPN → userPrincipalName**, MFA-Stufe passend setzen.

## Backlog / offene Punkte

0. **Rollout per Intune-Win32-App** — Design in **`docs/intune-rollout.md`** (2026-09-29).
   Kurz: ZWEI Apps — App 1 (Device/SYSTEM) legt leere VSC mit Start-PIN aus dem
   Computernamen an (silent); App 2 (User) `-Simple`-Assistent: PIN-Änderung ERZWINGEN,
   dann Szenario-02-Ausstellung.
   - **[ERLEDIGT — tool-seitiger erster Wurf, 2026-09-29, NICHT auf HW getestet]:**
     - `VscWizard.ps1` param-Block ganz oben: `-Provision -Silent -Simple -CardName -Pin`;
       `$script:SimpleMode`. Ohne Schalter unverändertes Verhalten (rein additiv).
     - `Invoke-VscProvision` (headless, `if ($Provision){exit …}` VOR dem GUI-Aufbau):
       Log nach `C:\ProgramData\VSC-Wizard\provision.log`, Name = `VscNamePrefix`+Computername,
       Start-PIN via `Get-VscBootstrapPin`, Elevations-Check (Exit 3), `New-VirtualSmartCard
       -Pin`, bei Erfolg `Set-VscProvisionMarker` (Exit 0) sonst 1.
     - `New-VirtualSmartCard -Pin` (supplied-PIN): PIN über kurzlebige Datei an den Helfer
       (NIE Kommandozeile/Log), beidseitig sofort gelöscht; im supplied-Modus KEIN
       tpmvscmgr-Fallback (kann keine PIN annehmen) → sauberer Fehler.
       Betrifft `VscWizard.CreateHelper.cs` (optionaler 4. Arg = PIN-Datei) — derselbe
       Quelltext für csc-FW **und** nativen ARM64-Helfer.
     - `Enter-SimpleFlow` (`-Simple`, Benutzerkontext): vorhandene VSC wählen → PIN-Änderung
       ERZWINGEN (Start-PIN vorbelegt via `Show-VscPinChangeDialog -PrefillCurrentPin`; ohne
       Änderung KEINE Ausstellung) → Szenario 02 (`Enter-PlanARenewal -TargetAccount $null`).
       Bei fehlender Config/VSC sauberer Rückfall auf den normalen Assistenten.
     - Registry-Marker `Set-VscProvisionMarker` (HKLM) / `Set-VscEnrollMarker` (HKCU, an
       beiden Plan-A-Erfolgspunkten wenn `-Simple`) für die Intune-Erkennung.
     - `VscWizard.bat` reicht jetzt Argumente durch (`%*`). EN-Strings ergänzt.
   - **PIN-Modell (entschieden 2026-09-29):** Quell-/Start-PIN **alphanumerisch, aus der
     Geräte-Seriennummer** abgeleitet (`Win32_BIOS.SerialNumber`, Aufkleber/Service-Tag →
     pro Gerät verschieden, ablesbar, kein Storage; Fallback Computername). Ziel-PIN
     **numerisch, min. 6** (erzwungen via `Show-VscPinChangeDialog -NumericOnly
     -MinNewLength`).
   - **NOCH ZU TESTEN (HW/Intune-Session):** supplied-PIN im Helfer (COM **und** nativer
     ARM64) auf ARM64/x64; Karten-Policy muss alphanum. Quell-PIN (Erstellen) UND
     numerische Ziel-PIN (Ändern) akzeptieren; Szenario 02 auf EJ-Client (CKT-TGT + CA
     erreichbar); Detection-Robustheit; `.intunewin`-Paketierung + Pilot.
   <!-- Alt-Outline unten bleibt als Detail; Doc ist maßgeblich. -->
   - **Teil 1 (Systemkontext, Intune-Win32-App/Skript):** VSC auf dem Ziel-PC anlegen,
     Start-PIN = Computername. Erkennungsregel für Intune (z.B. VSC vorhanden oder
     Registry-Marker).
   - **Teil 2 (Benutzerkontext):** Ist ein Benutzer angemeldet, einen vereinfachten
     Assistenten zeigen. EXE-Schalter z.B. `-Simple` (evtl. `-Silent` für Teil 1):
     nur Szenario 02 bzw. direkt „Der folgende Assistent führt dich durch die
     Erstellung einer virtuellen Smartcard“. Am Ende **erzwungene PIN-Änderung**
     (Set-VscPin / Show-VscPinChangeDialog, alte PIN = Computername vorbelegt).
   - Vorab zu klären:
     - Intune-Win32-Apps laufen als SYSTEM. Die UI muss in der Benutzersitzung
       erscheinen (Aufgabenplanung mit dem angemeldeten Benutzer, ServiceUI o.ä.).
       Alternativ zwei Apps: Systemkontext (VSC) + Benutzerkontext (Assistent).
     - Angemeldeten Benutzer erkennen (Besitzer von explorer.exe / WTS-Sitzungen).
     - Die Start-PIN ist bekannt/erratbar → PIN-Änderung wirklich erzwingen (Assistent
       erst beenden, wenn geändert; bis dahin keinen Nutzen aus der Karte ziehen lassen).
       Die PIN-Richtlinie (Mindestlänge) muss zum Computernamen passen (NetBIOS max. 15
       Zeichen, evtl. kürzer als die Mindestlänge → auffüllen oder Richtlinie anpassen).
     - Szenario 02 auf einem EJ-Client braucht ein On-Prem-TGT (Cloud Kerberos Trust)
       und eine erreichbare CA (Sichtverbindung/VPN), sonst Plan B.
     - Alternative prüfen: Intune-SCEP/PKCS-Profile können nicht in den
       Smartcard-KSP registrieren (nur TPM-/Software-KSP bzw. WHfB) → der Assistent
       bleibt nötig.

1. **GA-Zweig: Cloud-only automatisch erkennen/abfragen.** Der geführte Cloud-GA-Weg
   soll erkennen (oder fragen), ob das Zielkonto **cloud-only** ist (kein AD-Objekt /
   kein On-Prem-Pendant / kein CKT-TGT möglich) und dann automatisch auf den
   **Offline-Template + „als AD-Account einreichen"**-Weg abzweigen — statt
   Build-from-AD/EOBO. Erkennungsideen: AD-Auflösung des Kontos versuchen;
   `dsregcmd`/CKT-Status; oder schlicht Ja/Nein-Abfrage „reiner Cloud-Account
   (Entra-only)?". (Vorarbeit im AD ist bereits geleistet; Offline-Template
   vorhanden und erprobt.)
2. **[ERLEDIGT, korrigiert, konsolidiert] Offline-Template-Direktzweig = NUR Entra CBA.**
   Jetzt **Szenario 04 „Cloud-Konto (Entra CBA): Zertifikat auf VSC/YubiKey"** — das
   frühere separate Szenario 07 wurde in 04 verschmolzen (04 war nur ein „in
   Arbeit"-Platzhalter; 07 war die echte Umsetzung → jetzt EIN Cloud-Szenario, sechs
   Szenarien insgesamt). Als DU direkt einreichen, Ziel-UPN im CSR (Supply-in-request),
   kein EA/RDP. **Nur für Cloud/CBA** — NICHT für On-Prem-Logon (SID/KB5014754, siehe oben).
   Template aus `config.OfflineTemplate` (leer → im Ablauf tippbar).
   *Offener Follow-up:* On-Prem-Offline via **altSecurityIdentities** (starke Bindung
   am Zielkonto schreiben) als optionaler, expliziter Zweig. Siehe #1 (cloud-only-Auto-Erkennung) und
   Follow-ups unten.
3. **[ERLEDIGT 2026-09-28] Nativer ARM64-VSC-Weg** (eigener PIN-Dialog statt
   tpmvscmgr-Konsole) - Option A umgesetzt und auf echter ARM64-Hardware getestet,
   Details in `docs/ARM64-native-vsc.md`.
6. **[ERLEDIGT] Zweisprachigkeit (DE/EN).** Deutscher Text = Schlüssel: `(T 'Text')`,
   Übersetzungen in `modules\VscWizard.Strings.en.psd1` (356 Einträge), Werte über
   Platzhalter `(T '... {0} ...') -f $wert`. Umschalter Deutsch|English in der
   Seitenleiste (speichert `Language` in config.psd1 und startet neu; Hintergrund-Jobs
   übernehmen die Sprache über `VSCWIZARD_UILANG`). **Standardsprache** ohne
   `Language` in der config: Windows-Anzeigesprache (Deutsch -> de, sonst en); die
   Entscheidung fällt einmal ganz am Skriptanfang (`$script:StartLang`), damit auch der
   Splash (läuft vor dem Modul-Import, Texte dort über `L 'de' 'en'`) stimmt. Das **Protokoll bleibt deutsch**
   (Diagnose). Neue Texte IMMER mit `T` schreiben und die Übersetzung ergänzen -
   `tests\Test-Strings.ps1` meldet fehlende/verwaiste Einträge und Platzhalter-Fehler.
7. **[ERLEDIGT] Layout-/Design-Überarbeitung** nach dem freigegebenen Entwurf
   (claude.ai Design-Canvas): Seitenleiste mit Schrittanzeige/Gerät/Sprache,
   Szenario-Karten statt Zweiteilung, Inhaltskarten mit Fließlayout, Hinweisboxen,
   einklappbares Protokoll. *Offen:* die Dialoge (Einstellungen, Inventar, Über,
   Konto/VSC-Wahl) haben noch den alten Stil.
8. **[ERLEDIGT] `OfflineTemplate` in den Einstellungen.** Dabei behoben: „Speichern"
   baute die Konfiguration neu auf und **löschte** Schlüssel, die der Dialog nicht kennt
   (u.a. `OfflineTemplate`); Werte mit Apostroph machten die `config.psd1` unlesbar.
9. **[ERLEDIGT] EA-Dialog: „Wartenden EA-Antrag abrufen..."** (auch nach Neustart,
   ID wird dann abgefragt); vorher nur „erneut beantragen" (= neuer Antrag).
4. *(Optional)* Eigener kleiner **C#-Elevations-Shim** für literal null Flackern
   (aktuell reicht `-WindowStyle Hidden`).
4. *(Optional)* **Echtes Renew** (RenewalCert, gleicher Schlüssel) als Experiment.
5. *(Optional/zurückgestellt)* **Accordion-/aufklappbare Schritte** in der UI.

## Zuletzt erledigt (2026-09-28, ARM64-Session)

- **Nativer ARM64-Helfer** (Backlog #3) - siehe `docs/ARM64-native-vsc.md`.
- **Abbrechen bricht wirklich ab:** PIN-Dialog- oder UAC-Abbruch führt nicht mehr in
  den tpmvscmgr-Fallback (zweite PIN-Abfrage in der Konsole); GUI zeigt neutral
  „Abgebrochen - es wurde keine Karte erstellt."
- **Wartender Antrag (Pending) repariert:** die Request-ID wurde nur bei englischem
  certreq erkannt (`RequestId:`) - auf deutschem Windows (`Anforderungs-ID:`) blieb sie
  leer und „Zertifikat abrufen" tat **stumm nichts**. Jetzt zentral
  `Get-CertReqRequestId` (sprachunabhängig, auch im Einreichungshelfer); fehlt die ID
  trotzdem, fragt der Wizard sie ab. Der Wartet-Text sagt jetzt, **was zu tun ist**
  (CA-Manager: certsrv.msc „Ausstehende Anforderungen" oder `certutil -resubmit <ID>`),
  und der Abruf unterscheidet noch offen / abgelehnt / Fehler.
- **Performance** (gemessen, identische Ergebnisse): Karten auflisten 6,3 → 0,7 s
  (eine WMI-Abfrage + ParentIdPrefix aus der Registry statt Get-PnpDeviceProperty je
  Gerät), TPM 9,9 → 0,6 s (Win32_Tpm nur eleviert; gecacht), Domänen-Status gecacht,
  Zertifikate lesen 17,7 → ~4 s (EIN Kindprozess für alle statt einer je Zertifikat,
  Hänger-Schutz bleibt) und danach 0,09 s (Sitzungs-Cache je Thumbprint, geleert bei
  Karten-/Schlüsseländerungen).
- **Busy-Anzeige zentral:** langsame Kernfunktionen melden sich selbst
  (`Enter-/Exit-WizardBusy` + `Register-WizardBusyHook`) → Banner/Wartecursor erscheinen
  automatisch, egal von welcher GUI-Stelle; Warte-Phasen > 1 s landen mit Dauer im Log.
- **Szenario 03:** Template-Auswahl liest die auf der CA veröffentlichten
  Supply-in-request-Templates mit Smartcard-Anmelde-EKU (ohne DC-Templates) aus AD.
- **Layout-Fehler behoben** (per `tests\Test-Layout.ps1` gefunden/abgesichert):
  abgeschnittene Ergebniszeilen, überdeckte „Zertifikatstemplate"-Beschriftung,
  einzeilige „Hier nicht möglich"-Begründung, Szenario-Untertitel/Umgebungszeile über
  den Rand, zweizeilige Einstellungs-Beschriftungen.
- **Log-Level `Warn`** existierte nicht → Aufräumen nach Verlängerung wäre an zwei
  Stellen mit Fehler abgebrochen.
- „Vorhandene virtuelle Smartcards anzeigen" aus den Einstellungen entfernt (doppelt
  zu Szenario 04; Banner lag dort hinter dem Dialog).
- **Review-Fixes:** kein Bindungsfehler mehr ohne Zertifikate mit privatem Schlüssel;
  kein `DoEvents` mehr in `Set-/Clear-Busy` (sonst liefen gepufferte Klicks mitten in
  einer Aktion) + „Zertifikat abrufen" während des Laufs gesperrt; Zertifikats-Cache
  prüft eine Registry-Signatur des VSC-Bestands (auch Änderungen außerhalb des Wizards);
  Abruf schreibt `certnew-<ID>.cer` (überschreibt nichts Fremdes); eingetippte
  Request-ID wird im Fortsetzungs-Stand gespeichert; Template-Abfrage max. 15 s,
  Fehlschlag 2 min gemerkt; Plan A meldet jetzt, wenn ein abgerufenes Zertifikat nicht
  auf die Karte übernommen wurde (vorher stumm).
- *Bekannte Einschränkung:* ohne Adminrechte ist „TPM bereit" nur „TPM-Gerät läuft"
  (PnP-Status OK) - ein nicht provisioniertes TPM fällt erst bei der Erstellung auf.
- **Tests ohne Durchklicken:** `tests\Test-Layout.ps1` (28 Zustände + alle Dialoge,
  mehrere Fenstergrößen; auf Englisch zusätzlich "deutscher Text übrig?"),
  `tests\Test-Flows.ps1` (alle Szenarien mit Weiter/Zurück, Resume, Laufzeitfehler) und
  `tests\Test-Strings.ps1` (Übersetzungen) - vor jeder Auslieferung laufen lassen, die
  ersten beiden auch mit `$env:VSCWIZARD_LANG='en'`.

## Zuletzt erledigt (Ergänzung)

- **Titelleiste** trägt jetzt „… - blog.zarenko.net". **„Über"-Knopf** in der
  Kopfleiste zeigt Version, Release-Datum und einen klickbaren Link zum Blog.
- **Versionierung reist mit dem Repo (kein Hook):** `Get-AppVersion` leitet die
  Version aus der **git-Historie** ab — Build-Nummer = Commit-Anzahl (`rev-list
  --count HEAD`), wächst also mit **jedem Commit** automatisch; dazu Release-Datum
  (letztes Commit-Datum) und Kurz-Hash. Läuft der Wizard als `.ps1` im Checkout →
  live aus git; als gebaute `.exe` → aus `version.txt`, das **build.ps1** beim Build
  aus git erzeugt und neben die EXE legt. Damit funktioniert das identisch in der
  Windows-Claude-Session, ohne lokale Hook-Einrichtung.
- **Fix:** frischer Plan-A/B-Start setzt den Zustand zurück (der „VSC erstellen →
  Weiter"-Check war überspringbar, weil `VscCreated` vom vorherigen Durchlauf true blieb).

- **Busy-/Warte-Anzeige** bei blockierenden Aktionen: App-weiter OS-Wartecursor
  (`Application.UseWaitCursor` — vom Betriebssystem animiert, auch wenn der UI-Thread
  synchron blockiert) + gelbes „⏳ läuft…"-Banner. Helfer `Set-Busy`/`Clear-Busy`/
  `Invoke-Busy` (immer try/finally → nie hängender Cursor). Angewandt auf: VSCs
  auslesen (Inventar — der gemeldete Fall), Umgebungserkennung (Rückkehr zum Start),
  VSC-Erstellung (Plan A/B). certreq-Buttons haben bereits Klartext-Status; dort ließe
  sich das Banner bei Bedarf ebenso ergänzen.

- **Szenarien nach Kontotyp umgebaut, 02 (Erneuern) aufgelöst → jetzt fünf:**
  01 „VSC für onprem-Adminkonto" (separat; EOBO/Bootstrap), 02 „VSC für onprem- oder
  hybrid-Konto" (du selbst, direkt), 03 „VSC für Cloudonly-Adminkonto" (Entra CBA,
  Offline), 04 „VSCs verwalten", 05 „EOBO". YubiKey-Begriff raus.
  Das frühere „Erneuern" ist **keine** eigene Kachel mehr: in 01/02/03 fragt der
  Wizard **„neue VSC erstellen ODER bestehende verwenden"** (Helfer
  `Show-VscChoiceDialog` + `Select-ExistingVsc`; „bestehende" nutzt die
  Enter-Plan(A/B)Renewal-Maschinerie). **Identität kommt IMMER aus dem Szenario/der
  Kontowahl**, nicht mehr aus dem Kartenzertifikat (fixt die früheren Verwechslungen).
  `Start-Renewal` entfernt; alle Szenario-Nummern in Routing/Availability/Guards/
  Meldungen und im RUNBOOK durchgängig neu (Geschwister-Sweep).

- **Start-Splash mit Fortschritt:** kleiner Splash beim Start (Modul laden →
  Konfiguration → Oberfläche → Umgebung erkennen → Fertig), schließt sich, sobald das
  Hauptfenster erscheint. Kein „Blackbox"-Start mehr.
- **Plan-A-Status-Schritt entfernt** (Geschwister zur Join-Heuristik): die frühere
  „Schritt: Status"-Seite prüfte redundant, was schon beim Start erkannt wird, und
  zeigte die falsche „nicht domänen-gebunden → Plan B"-Warnung (auch bei EntraJoined+CKT).
  Plan A startet jetzt direkt bei „VSC erstellen" (Verlängern bei „Zertifikat anfordern");
  Schrittnummern angepasst. Plan-B-Status bleibt (zeigt RDP-Ziel, keine Fehlwarnung).
- **Szenario 04+07 konsolidiert** → ein Cloud-Szenario „Cloud-Konto (Entra CBA):
  Zertifikat auf VSC/YubiKey": als DU direkt bei der CA einreichen, Ziel-UPN im CSR
  (Supply-in-request), **kein EA, kein RDP**; **nur** für Entra CBA/Cloud. Nutzt `config.OfflineTemplate`
  (leer → Template im Ablauf tippbar; Combo dann editierbar). Guard warnt vor ESC1
  (Template zusperren). Verfügbarkeit wie 03 (TGT/AD-Join nötig).
  - *Follow-up:* `OfflineTemplate` noch nicht im Einstellungen-Tab (nur in `config.psd1`);
    cloud-only-Auto-Erkennung (Backlog #1) könnte direkt in 07 abzweigen.
- **TPM-Fehlanzeige behoben:** `Test-TpmReadiness` hat jetzt einen **WMI-Fallback**
  (`Win32_Tpm`), und `Get-EnvironmentCapabilities` schließt aus einer **vorhandenen VSC**
  auf „TPM vorhanden" (eine VSC kann ohne TPM nicht existieren). Kein falsches
  „kein TPM" mehr (z.B. wenn `Get-Tpm` auf ARM64 versagt).
- **Startseite erkennt die Umgebung** (`Get-EnvironmentCapabilities`): Banner mit
  Join/TPM/On-Prem-TGT/VSC-Anzahl/EA; **unpassende Szenarien werden ausgegraut**
  (02 ohne VSC, 03 ohne TGT&ohne AD-Join, 06 ohne EA-Zert) — mit Klartext-Begründung,
  „Weiter" dann blockiert. Entra-joined **mit** CKT hat ein TGT → 03 bleibt aktiv.
- **Szenario-02-Text geradegezogen:** „Zertifikat erneuern (Neuausstellung auf
  bestehende VSC)"; kein „VOR ABLAUF"/„kein Chain"-Blocker mehr — funktioniert auch
  bei abgelaufenem Zertifikat (die VSC läuft nie ab, nur das Zertifikat darauf).
- **Robuster Start** (PS2EXE): Basisverzeichnis über Prozesspfad-Fallback; klare
  Fehlermeldung statt „Import-VscWizardConfig unbekannt"-Kaskade, wenn `modules\`/
  `config.psd1` fehlen (z.B. EXE ohne Beiwerk / OneDrive-Platzhalter).

## Zuletzt erledigt (2026-09-29): VSCs verwalten neu
- **Verwaltungsdialog neu** (`Show-VscInventoryDialog`): oben die Karten (Name ·
  „In Windows-Dialogen" = PC/SC-Name · Anzahl Zertifikate · nächster Ablauf, rot
  abgelaufen / orange < 30 Tage), darunter „PIN ändern…" / „Karte löschen…" (nur
  virtuelle Karten `ROOT\SMARTCARDREADER\*`); unten die Zertifikate der gewählten
  Karte (Ausgestellt für · Gültig bis · Status · Fingerabdruck) mit „Anzeigen…"
  (auch Doppelklick; Windows-Zertifikatsdialog) und „Von Karte entfernen…".
  Geräte-ID-/GUID-Spalte entfällt; Szenario 04 ohne Tool/Du-Schritte.
- **PIN ändern** (`Show-VscPinChangeDialog` → `Set-VscPin`): eigener Dialog (aktuelle
  PIN, neue PIN, Wiederholung), Änderung über den **Kartentreiber** (`msclmd.dll`:
  `CardAcquireContext` + `CardChangeAuthenticator`, danach Gegenprüfung mit der neuen
  PIN, Karte wird zurückgesetzt). Derselbe Weg wie Strg+Alt+Entf → Kennwort ändern.
  CARD_DATA-Layout (v7, 64 Bit) am Gerät in 3 Stufen verifiziert: (1) nur lesen —
  reservierte Felder leer, alle Funktionen im Treiber, `cardid` = WinRT-Karten-ID;
  (2) PIN prüfen; (3) PIN ändern (vom Benutzer ausgeführt, neue = alte PIN). Läuft im
  emulierten x64-Prozess. Rückmeldung: falsche PIN (+ Restversuche), gesperrt,
  Richtlinie verletzt; sonst Fehler + Anleitung Strg+Alt+Entf.
  **Im Wizard (EXE) interaktiv bestätigt (2026-09-29): PIN geändert.**
  Verworfen: WinRT `RequestPinChangeAsync` — nur UWP, sonst 0x80070490.
## Zuletzt erledigt (2026-09-29): Hybrid-Erkennung in Szenario 03
- Systematik: **02 = eigenes on-prem/hybrid-Konto, 01 = fremdes on-prem/hybrid-Konto,
  03 = fremdes Cloud-only-Konto.** Titel/Texte entsprechend (vorher "onprem-Adminkonto"
  ohne "hybrid" -> Verwechslung).
- `Find-OnPremAccountByUpn`: LDAP-Suche nach der UPN im lokalen AD (Realm aus klist,
  8 s Timeout, Filter-Escaping). Gefunden -> Warnung "Hybrid-Konto erkannt" mit
  Ja = Wechsel zu 01 (Konto vorausgefüllt) / Nein = trotzdem 03 / Abbrechen. AD nicht
  erreichbar -> kein Hinweis. Test-Flows prüft beide Zweige (Gegenprobe ok).
- Anlass: jdoe@contoso.com (Hybrid, OU=Tier2) mit Szenario 03 ausgestellt. Befund:
  Entra-joined + RDP/Anmeldebildschirm mit VSC -> Entra CBA (SID S-1-12-1-..., Name
  wird als home\<sam> angezeigt); `runas /smartcard` mit dem 03-Zertifikat -> 1326
  (lokaler DC, keine SID/altSecId). UAC mit Smartcard für jdoe -> Fehler 740: noch
  ungeklärt (Test als jdoe am Anmeldebildschirm steht aus).

## Zuletzt erledigt (2026-09-29): PIN-Dialoge nicht mehr im Hintergrund
- Ursache: Windows-Fokussperre. PIN-/Sicherheitsdialoge beim Anfordern gehören
  certreq (unsichtbar gestartet) bzw. CredentialUIBroker ("Credential Dialog Xaml
  Host"), nicht dem Wizard - je nach Timing erschienen sie dahinter.
- `Invoke-ExternalCommand`: vor dem Start `AllowSetForegroundWindow(ASFW_ANY)`; beim
  Warten alle 250 ms `VscWizardForeground.PromoteDialogs` - holt ein sichtbares Fenster
  des Kindprozesses bzw. einen Sicherheitsdialog nach vorn, NUR solange der Wizard selbst
  vorn ist (kein Fokusdiebstahl bei App-Wechsel). Log-Eintrag "Dialog in den Vordergrund
  geholt". Warten jetzt immer mit asynchronem Pipe-Lesen (auch ohne Timeout).
- **Offen:** interaktiv bestätigen (tritt sporadisch auf; im Log erkennbar, wenn der
  Wizard eingreifen musste).

## Zuletzt erledigt (2026-09-29): Intune-Rollout — tool-seitiger erster Wurf
- Rein additiv: ohne die neuen Schalter startet weiterhin der normale Wizard.
- **App 1 (Device/SYSTEM):** `VscWizard.exe -Provision -Silent` → `Invoke-VscProvision`
  legt leere VSC mit Start-PIN aus dem Computernamen an (`Get-VscBootstrapPin`),
  Log `C:\ProgramData\VSC-Wizard\provision.log`, HKLM-Marker; Exit 0/1/3.
- **App 2 (User):** `VscWizard.exe -Simple` → `Enter-SimpleFlow`: vorhandene VSC wählen,
  PIN-Änderung ERZWINGEN (Start-PIN vorbelegt, ohne Änderung keine Ausstellung), dann
  Szenario 02 (`Enter-PlanARenewal`). HKCU-Marker an den Plan-A-Erfolgspunkten.
- **supplied-PIN:** `New-VirtualSmartCard -Pin` gibt die PIN über eine kurzlebige Datei
  an den COM-Helfer (NIE Kommandozeile/Log), beidseitig sofort gelöscht; kein
  tpmvscmgr-Fallback im supplied-Modus. Helfer `CreateHelper.cs` um optionalen 4. Arg
  (PIN-Datei) erweitert — gilt für csc-FW **und** nativen ARM64.
- **PIN-Modell:** Quell-PIN aus der **Seriennummer** (Aufkleber, alphanumerisch, kein
  Storage; `Get-VscBootstrapPin`), Ziel-PIN **numerisch min. 6** (erzwungen im PIN-Dialog).
- `VscWizard.bat` reicht Argumente durch (`%*`); EN-Strings ergänzt.
- **Ungetestet (HW/Intune):** supplied-PIN auf ARM64/x64, PIN-Zeichensatz der VSC,
  Szenario 02 auf EJ-Client, `.intunewin`-Paketierung. Siehe Backlog #0 / `docs/intune-rollout.md`.

## Zuletzt erledigt (2026-09-30): Simple-Modus schlank + automatische Kartenwahl
- `-Simple` zeigt eine eigene Startseite (`Show-SimpleStart`, `$pnlSimple`) statt der
  Szenario-Übersicht: 2 Schritte erklärt, erkannte Karte, „Einrichtung starten“.
  Seitenleiste: Start / Eigene PIN / Zertifikat / Fertig; Einstellungen + Geräte-
  Details ausgeblendet; „Zurück“ führt nie zur Szenario-Auswahl; Sprachwechsel
  behält `-Simple`. Umgebungserkennung der Szenario-Seite entfällt beim Start.
- `Find-ProvisionedVsc` (Core): per `-Provision` angelegte Karte über (1) InstanceId
  aus dem HKLM-Marker, (2) Namen `Get-VscProvisionCardName` (= Provisionierung),
  (3) einzige VSC. Sonst Auswahl durch den Benutzer.
- Texte im Simple-Modus duzen jetzt (wie der Rest des Wizards).
- Fehler beim Bau gefunden: Panel-Variable `$simpleCard` == `$script:SimpleCard`
  (PowerShell ignoriert Groß/Klein) -> umbenannt; Test-Flows prüft die echte Erkennung
  ohne Vorbelegung (Gegenprobe ok).
- **Offen:** auf dem Test-PC mit per -Provision angelegter Karte bestätigen.

## Zuletzt erledigt (2026-09-30): Kein "Smartcard auswählen"-Aufblitzen mehr
- Ursache: Die Zertifikats-/Kartenzuordnung (`Get-SmartCardCngProviderInfoBatch`) öffnete
  je Zertifikat den privaten Schlüssel (GetRSAPrivateKey). Bei einem Zertifikat ohne
  vorhandene Karte zeigte Windows "Smartcard auswählen" und wartete, bis der Hänger-
  Schutz den Prozess beendete. Sichtbar wurde das erst, seit Sicherheitsdialoge nach
  vorn geholt werden (vorher lag er dahinter).
- Neu: Schlüssel-VERWEIS aus dem Zertifikat (CERT_KEY_PROV_INFO, kein Kartenzugriff) +
  stille Container-Liste jeder Karte (NCryptEnumKeys, NCRYPT_SILENT_FLAG), Zuordnung
  über den Containernamen. Kein Dialog, kein Warten; 3,9 statt ~8 s bei 18 Zertifikaten.
- Verifiziert: alle 5 Smartcard-Zertifikate identisch zugeordnet wie vorher;
  nachgestelltes verwaistes Zertifikat (Verweis auf nicht vorhandenen Container) in
  2,4 s ohne Timeout als "ohne Karte" erkannt. Nebenbei erkennt der Lookup jetzt auch
  ECC-Schlüssel (vorher nur RSA).
- **Auf dem Test-PC bestätigt (2026-09-30): keine Auswahldialoge mehr.**

## Betriebs-Reminder

- Nach jedem `git pull` auf dem **Einreich-Host**: `.\build.ps1` — die `.exe` wird
  **nicht** durch den Pull aktualisiert.
- Alle `.ps1`/`.psm1` sind **UTF-8 mit BOM** zu speichern (sonst Umlaut-Mojibake in
  Windows PowerShell 5.1).
