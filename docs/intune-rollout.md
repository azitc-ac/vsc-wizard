# VSC-Rollout per Intune

Anleitung für die Verteilung des VSC-Wizards per Intune (Win32-App) an Entra-joined bzw.
Hybrid-Clients. Ergebnis: Jeder Hybrid-Benutzer, der sich anmeldet und noch kein gültiges
Smartcard-Anmeldezertifikat hat, bekommt seine **eigene virtuelle Smartcard** mit eigener
PIN und Zertifikat – geführt durch einen schlanken Assistenten, ohne Adminrechte.

Grundprinzip: **Die VSC ist maschinengebunden (TPM), das Zertifikat benutzergebunden.**
Karte anlegen braucht SYSTEM/Admin, PIN und Zertifikat laufen in der Sitzung des
Benutzers. Die App verbindet beides über eine SYSTEM-Aufgabe, die der Benutzer nur
**starten** darf.

## Voraussetzungen

- **TPM 2.0**, bereit (max. 10 virtuelle Smartcards je TPM).
- **Hybrid-Konten** mit On-Prem-Kerberos-Ticket beim Benutzer (z.B. Cloud Kerberos Trust)
  und **Sicht auf die Zertifizierungsstelle** (LAN/VPN) zum Zeitpunkt der Einrichtung.
  Ohne Ticket startet der Assistent bei der Anmeldung gar nicht erst.
- **Zertifikatvorlage** für die Smartcard-Anmeldung, auf der die Benutzer *Registrieren*
  dürfen (Provider: Microsoft Smart Card Key Storage Provider bzw. passend zur Vorlage).
- **`config.psd1` mit `CAConfig` und `Template`** der Organisation. Der automatische Start
  bei der Anmeldung setzt eine vollständige Konfiguration voraus – der Benutzer soll nichts
  einstellen müssen. Optional: `PinMinLength` (Standard 6), `VscNamePrefix`,
  `MaxVscPerDevice` (Standard 10), `Language` (`de`/`en`).

> Intune-SCEP/PKCS-Profile sind keine Alternative: Sie können nicht in den
> Smartcard-KSP schreiben (nur TPM-/Software-KSP bzw. WHfB).

## Paket bauen

1. Org-Werte in **`config.local.psd1`** pflegen (liegt nur lokal, ist in `.gitignore`).
2. `.\build.ps1` ausführen. Ergebnis in `dist\`:
   - `VscWizard.exe`, `modules\`, `version.txt`
   - `config.psd1` – aus `config.local.psd1` übernommen, falls vorhanden
   - `VscWizard.png` – Programmsymbol, auch als App-Logo in Intune verwendbar
   - `intune\Detect-VscWizard.ps1` – Erkennungsskript **für genau diese Version**
   - `helper-arm64\` – nur für ARM64-Geräte nötig (groß, ca. 60 MB)
   - `VscWizard.Submit.exe` – wird auf Clients **nicht** gebraucht (Einreicher für den
     RDP-/Server-Weg der Admin-Szenarien)
3. Das Build-Skript nennt am Ende die Version (`1.0.<Anzahl Commits>`), z.B. 1.0.114.

## Intune-App anlegen (eine Win32-App, Gerät/SYSTEM)

| Einstellung | Wert |
|---|---|
| Installationsbefehl | `VscWizard.exe -Install` |
| Deinstallationsbefehl | `"%ProgramFiles%\VSC-Wizard\VscWizard.exe" -Uninstall` |
| Installationsverhalten | **System**, keine Benutzerinteraktion |
| Zuweisung | Gerätegruppe |
| Rückgabecodes | `0` Erfolg · `1618` Wiederholen (Assistent ist gerade offen) · `3` nicht eleviert · `1` Fehler |

**Mit PSADT 4 / IntuneWin32Helper:** Inhalt von `dist\` in den Ordner `Files\` legen.
Install: `Start-ADTProcess -FilePath "$($adtSession.DirFiles)\VscWizard.exe" -ArgumentList '-Install'`,
Uninstall dito mit `-Uninstall` (aus dem Paket). In `Apps.csv` die Spalte **`Version`
auf die gebaute Version setzen** (das Build-Skript nennt sie).

**Erkennung** – eine von beiden, wichtig ist die Versionsprüfung:

- **IntuneWin32Helper-Standard:** ArpName `VSC-Wizard`, vergleicht `DisplayVersion` mit
  `Version` aus `Apps.csv`.
- **`dist\intune\Detect-VscWizard.ps1`:** erkannt nur, wenn installierte Version **≥**
  Paketversion, `VscWizard.exe` im Programmordner und die SYSTEM-Aufgabe vorhanden sind.
  Liest die 64-Bit-Registry auch als 32-Bit-Skript. Mit **jedem** Paket neu hochladen.

Ohne Versionsprüfung hält Intune eine ältere Installation für aktuell und installiert ein
Update nie.

### Was `-Install` einrichtet

1. Programm nach **`%ProgramFiles%\VSC-Wizard`** (nur Admins schreibbar – wichtig, weil
   SYSTEM es ausführt). Prüft nach dem Kopieren, dass die Paketversion dort liegt.
2. **`C:\ProgramData\VSC-Wizard\Requests`** – Benutzer dürfen nur Dateien *anlegen*
   (fremde Aufträge nicht lesbar); **`…\State`** – nur SYSTEM/Admins.
3. Aufgabe **„VSC-Wizard CreateCard“** – SYSTEM, ohne Auslöser, `-ProcessRequests`.
   Benutzer dürfen sie nur lesen und starten (`D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)`).
4. Aufgabe **„VSC-Wizard Setup“** – Gruppe *Benutzer*, bei jeder Anmeldung (30 s
   verzögert), `-Simple -AutoStart` in der Sitzung des Benutzers.
5. Startmenü-Eintrag **„Smartcard einrichten“** bzw. **„Set up smart card“** (Sprache aus
   der Konfiguration bzw. dem Gerät) als Weg zurück, z.B. nach „Später erinnern“.
6. Eintrag unter **Apps & Features** (`VSC-Wizard`, mit Version) und
   `HKLM\SOFTWARE\VSC-Wizard\ServiceVersion`.
7. Protokoll (Installation, SYSTEM-Aufgabe): `C:\ProgramData\VSC-Wizard\provision.log`.

Nach der Installation ist **kein Neustart** nötig; der Assistent erscheint bei der
nächsten Anmeldung.

### Updates und Deinstallation

- **Update:** neues Paket mit neuer Version (+ ggf. neues Erkennungsskript) hochladen.
  Intune installiert über die alte Version, keine Ersatzkette nötig. Programmdateien,
  Aufgaben, Rechte und ARP-Eintrag werden erneuert; **Karten, Benutzerzuordnungen,
  Start-PINs und offene Aufträge bleiben erhalten**. Ist der Assistent gerade offen,
  bricht `-Install` sauber mit `1618` ab und Intune versucht es später erneut.
- **Deinstallation** entfernt Programm, Aufgaben, Startmenü- und ARP-Eintrag. Die
  **Karten bleiben** auf den Geräten (Löschen nur bewusst über „VSCs verwalten“).

## Ablauf beim Benutzer

1. **Anmeldung** → nach 30 s startet „VSC-Wizard Setup“. Der Assistent beendet sich
   **still**, wenn nichts zu tun ist:
   - gültiges Smartcard-Anmeldezertifikat für das eigene Konto vorhanden (mehr als 30
     Tage gültig; Windows-Hello- und für andere Konten ausgestellte Zertifikate zählen
     nicht),
   - kein On-Prem-Kerberos-Ticket (kein Hybrid-Konto bzw. gerade keine AD-Verbindung),
   - „Später erinnern“ aktiv,
   - Konfiguration unvollständig.

   Der Grund steht im Tagesprotokoll des Benutzers.
2. Sonst erscheint **„Smartcard einrichten“**: Hinweis, dass die persönliche Karte
   `VSC-<Benutzername>` angelegt wird (bzw. die vorhandene eigene Karte verwendet wird).
3. **„Einrichtung starten“**: Der Assistent legt einen Auftrag in `Requests\` ab und
   startet die SYSTEM-Aufgabe. Das Fenster bleibt bedienbar; nach 20 s wird die Aufgabe
   einmal erneut angestoßen, nach 90 s fragt der Assistent, ob er weiter warten soll.
4. **SYSTEM** (`Invoke-VscCardRequests`): Der Benutzer ist der **NTFS-Besitzer** des
   Auftrags (nicht fälschbar) und muss interaktiv angemeldet sein. Eine bereits gemerkte
   eigene Karte wird wiederverwendet; sonst wird – nach Prüfung von Kartenlimit und TPM –
   `VSC-<Benutzername>` mit **zufälliger 12-stelliger Start-PIN** angelegt. Die Start-PIN
   liegt bis zur Änderung in `State\<SID>.pin` (nur SYSTEM/Admins); die Antwortdatei
   darf nur dieser Benutzer lesen, der Assistent löscht sie sofort.
5. **PIN festlegen:** Dialog mit vorbelegter Start-PIN, neue PIN nur aus Ziffern,
   mindestens 6 Stellen (bzw. `PinMinLength`). Erst danach geht es weiter; SYSTEM verwirft
   die gemerkte Start-PIN.
6. **Zertifikat ausstellen** direkt bei der CA auf die neue Karte (entspricht Szenario 02,
   eigenes Konto). „Fertig“ schließt den Assistenten.

Über das Startmenü öffnet der Benutzer den Assistenten jederzeit wieder, z.B. um die PIN
zu ändern oder das Zertifikat anzusehen („Meine Smartcard“).

### Erwartete Fehler (jeweils mit Ausweg, in `tests\Test-Flows.ps1` abgedeckt)

| Fehler | Verhalten |
|---|---|
| Aufgabe fehlt / nicht startbar | Hinweis „nicht vollständig vorbereitet – IT“, erneut versuchbar |
| Auftragsordner fehlt / gesperrt | dito, mit Fehlertext |
| Keine Antwort nach 90 s | „Weiter warten?“ – Ja: wartet erneut; Nein: Hinweis mit Protokollpfad. Ein später doch verarbeiteter Auftrag schadet nicht |
| TPM voll | „kein Platz (x von max. y) – IT kann alte Karten entfernen“ |
| TPM nicht bereit | „Gerät neu starten, dann erneut; sonst IT“ |
| Erstellung fehlgeschlagen | Fehlertext + Protokollpfad, erneut versuchbar |
| PIN-Änderung abgebrochen | Karte bleibt; nächster Start: gleiche Karte, Start-PIN wieder vorbelegt |
| PIN geändert, Ausstellung nicht fertig (CA/VPN) | nächster Start: gleiche Karte, direkt zur Ausstellung |
| Gemerkte Karte gelöscht | wird automatisch neu angelegt |
| Zertifikat läuft in < 30 Tagen ab | Assistent erscheint wieder → Verlängerung auf derselben Karte |

## Alternative: eine vorbereitete Karte pro Gerät (`-Provision`)

Für Geräte mit **einem** Hauptbenutzer, wenn keine SYSTEM-Aufgabe gewünscht ist:

- **App 1 (Gerät, SYSTEM):** `VscWizard.exe -Provision -Silent` legt eine leere Karte an.
  Start-PIN deterministisch aus der **Geräte-Seriennummer** (`Get-VscBootstrapPin`,
  Fallback Computername) – kein Geheimnis, wird beim Benutzer sofort geändert.
  Erkennung: `HKLM\SOFTWARE\VSC-Wizard`, Wert `Provisioned = 1`. Exit-Codes `0` / `1` / `3`.
- **App 2 (Benutzer):** `VscWizard.exe -Simple` – PIN ändern (Start-PIN vorbelegt), dann
  Zertifikat ausstellen; Erkennung über den HKCU-Marker. Abhängigkeit App 2 → App 1.
- Nur der **erste** Benutzer richtet die Karte ein. Der Assistent prüft die Karte still
  (ohne PIN): eigenes Zertifikat → „bereits eingerichtet“; Zertifikat eines anderen →
  „bereits für {UPN} eingerichtet – an die IT wenden“; nur Schlüssel ohne Zertifikat →
  Fortsetzen möglich.

Ist `-Install` vorhanden, nutzt der Assistent automatisch den Weg mit eigener Karte pro
Benutzer.

## Sicherheit

- Karten werden erst im Moment der Einrichtung angelegt; die Start-PIN ist zufällig und
  nur für SYSTEM und den jeweiligen Benutzer lesbar. Die PIN-Änderung ist erzwungen,
  bevor ein Zertifikat entsteht – das Zertifikat liegt nie unter der Start-PIN.
- Benutzer können die SYSTEM-Aufgabe nur starten, nicht ändern. Welche Karte angelegt
  wird, bestimmt der NTFS-Besitzer des Auftrags, nicht dessen Inhalt.
- PINs erscheinen weder auf der Kommandozeile noch im Protokoll.

## Grenzen

- Max. **10 VSCs pro TPM**. Verwaiste Karten (Benutzer existiert nicht mehr) werden
  bewusst **nicht** automatisch gelöscht – Aufräumen als Admin über „VSCs verwalten“.
- Der Simple-Modus arbeitet nur mit virtuellen Smartcards. Physische Karten (z.B.
  YubiKey, Einstellung „Auch andere Smartcards beschreiben“) sind für die Admin-Szenarien
  im vollständigen Assistenten gedacht.
