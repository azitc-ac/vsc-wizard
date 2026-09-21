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
2. **[ERLEDIGT] Direkt-Weg für separates Konto ohne EA (Offline-Template).** Umgesetzt
   als **Szenario 07 „Direkt für ein anderes Konto (Offline-Template)"**: als DU direkt
   einreichen, Ziel-Subject/UPN im CSR (Supply-in-request), kein EA/RDP, auch für
   cloud-only Ziele (Entra CBA). Template kommt aus `config.OfflineTemplate` (leer →
   im Ablauf tippbar). Offene Anschlusspunkte siehe #1 (cloud-only-Auto-Erkennung) und
   Follow-ups unten.
3. *(Optional)* Eigener kleiner **C#-Elevations-Shim** für literal null Flackern
   (aktuell reicht `-WindowStyle Hidden`).
4. *(Optional)* **Echtes Renew** (RenewalCert, gleicher Schlüssel) als Experiment.
5. *(Optional/zurückgestellt)* **Accordion-/aufklappbare Schritte** in der UI.

## Zuletzt erledigt (Ergänzung)

- **Szenario 07 „Direkt für ein anderes Konto (Offline-Template)"**: als DU direkt bei
  der CA einreichen, Ziel-Subject/UPN im CSR (Supply-in-request), **kein EA, kein RDP**;
  funktioniert auch für **cloud-only** Ziele (Entra CBA). Nutzt `config.OfflineTemplate`
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
