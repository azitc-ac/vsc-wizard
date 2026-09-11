# Projektstand & Backlog (VSC-Wizard)

> Kurzes „wo stehen wir"-Dokument, damit der Faden zwischen Testrunden nicht reißt.
> Ergänzt das RUNBOOK.md (das die Szenarien/Abläufe beschreibt).

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
2. **Szenario-02-Text geradeziehen:** „abgelaufen" ist **kein** harter Blocker
   (Passwort/RDP-Weg funktioniert); RDP-**Ziel** = domänen-gebundener Einreich-Host
   (DC/Member) als Zielkonto, **nicht** eine weitere EJ-Kiste.
3. *(Optional)* Eigener kleiner **C#-Elevations-Shim** für literal null Flackern
   (aktuell reicht `-WindowStyle Hidden`).
4. *(Optional)* **Echtes Renew** (RenewalCert, gleicher Schlüssel) als Experiment.
5. *(Optional/zurückgestellt)* **Accordion-/aufklappbare Schritte** in der UI.

## Betriebs-Reminder

- Nach jedem `git pull` auf dem **Einreich-Host**: `.\build.ps1` — die `.exe` wird
  **nicht** durch den Pull aktualisiert.
- Alle `.ps1`/`.psm1` sind **UTF-8 mit BOM** zu speichern (sonst Umlaut-Mojibake in
  Windows PowerShell 5.1).
