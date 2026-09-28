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
  (Escape-Hatch für On-Prem-Offline-Certs: manuell **starke** `altSecurityIdentities`
  am Zielkonto setzen — X509 Issuer+Serial / SKI / SHA1-PublicKey; noch nicht im Tool.)
- **CBA-Stolperstein:** CRL/CDP muss für **Entra erreichbar** sein (On-Prem-CDP ist
  oft nur intern) → sonst kann der CBA-Login an der Sperrprüfung scheitern.
  Binding **UPN → userPrincipalName**, MFA-Stufe passend setzen.

## Backlog / offene Punkte

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
3. *(Optional)* Eigener kleiner **C#-Elevations-Shim** für literal null Flackern
   (aktuell reicht `-WindowStyle Hidden`).
4. *(Optional)* **Echtes Renew** (RenewalCert, gleicher Schlüssel) als Experiment.
5. *(Optional/zurückgestellt)* **Accordion-/aufklappbare Schritte** in der UI.

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

## Betriebs-Reminder

- Nach jedem `git pull` auf dem **Einreich-Host**: `.\build.ps1` — die `.exe` wird
  **nicht** durch den Pull aktualisiert.
- Alle `.ps1`/`.psm1` sind **UTF-8 mit BOM** zu speichern (sonst Umlaut-Mojibake in
  Windows PowerShell 5.1).
