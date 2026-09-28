# Übergabe-Prompt: Weiterentwicklung auf Windows-ARM64

> Dieser Text ist ein **Übergabe-Prompt**. Gib ihn (bzw. verweise darauf) einer
> Claude-Session, die auf einem **Windows-ARM64-Gerät** läuft. Sie hat den
> entscheidenden Vorteil: echte ARM64-Hardware **und** die Möglichkeit, die GUI zu
> starten und den COM-Test wirklich auszuführen.

---

Du übernimmst die Weiterentwicklung des Tools „VSC-Wizard" auf einem Windows-ARM64-Gerät.

## PROJEKT
- VSC-Wizard: PowerShell/WinForms-Tool für AD-Admins zum Provisionieren von TPM Virtual
  Smart Cards (VSC) und zur Beantragung von Smartcard-Logon-Zertifikaten von einer
  On-Prem AD CS Enterprise-CA.
- Repo: https://github.com/azitc-ac/vsc-wizard — Branch: **main** (direkt auf main arbeiten).
- Läuft in **Windows PowerShell 5.1** (WinForms). Start als `.ps1` via `VscWizard.bat`,
  oder als PS2EXE-`.exe` über `build.ps1`.

## DEINE UMGEBUNG (der Grund für die Übergabe)
- Du läufst auf **echter Windows-ARM64-Hardware**. Die bisherige Cloud-Session konnte die
  GUI nicht starten und nicht auf ARM64 testen — **DU kannst beides**. Nutze das: GUI
  wirklich starten, Abläufe durchklicken, den COM-Test unten real ausführen.

## SOFORT-AUFGABE: Nativer ARM64-Weg für die VSC-Erstellung
- Ziel: eigener maskierter PIN-Dialog auf ARM64 statt der tpmvscmgr-Konsole.
- Lies **ZUERST `docs/ARM64-native-vsc.md`** — dort steht die komplette Design-Skizze.
- Reihenfolge:
  1. **VALIDIEREN** (billig, zwingend zuerst): In einer **elevierten, nativen ARM64-`pwsh`**
     den COM-`CreateInstance` + `QueryInterface` auf die TPM-VSC-Manager-CoClass testen
     (Snippet steht im Doc). Kommt **kein** `0x800700C1` → nativer Weg tragfähig. Kommt es
     doch → **nicht** weiterbauen, Ursache analysieren; tpmvscmgr bleibt.
  2. **UMSETZEN (Option A, empfohlen):** den vorhandenen `modules/VscWizard.CreateHelper.cs`
     (COM-Interop + PIN-Dialog + `CreateVirtualSmartCardWithPinPolicy` — alles schon da)
     in ein winziges **.NET-WinForms-Projekt** überführen und im Build
     `dotnet publish -r win-arm64 --self-contained` → nativer ARM64-Helfer **ohne**
     Endnutzer-Laufzeitabhängigkeit. In `modules/VscWizard.Core.psm1` den ARM64-Zweig in
     `New-VirtualSmartCard` (~Z. 650) so ändern: wenn der native Helfer existiert → den
     eleviert starten (PIN-Dialog + COM laufen im elevierten nativen Prozess), sonst
     Fallback `tpmvscmgr.exe`. `build.ps1` bekommt den `dotnet publish`-Schritt.

## HARTE RANDBEDINGUNG (nicht aufweichen)
- Die **PIN darf den elevierten Prozess NIE verlassen** — nicht per Kommandozeile, Datei
  oder Env-Var. Der PIN-Dialog läuft **innerhalb** des elevierten nativen Prozesses (wie
  heute im FW-Helfer und bei `tpmvscmgr /PIN PROMPT`).

## COM-SPEZIFIKA (aus `VscWizard.CreateHelper.cs`)
- CoClass `TpmVirtualSmartCardManager`, CLSID `16A18E86-7F6E-4C20-AD89-4FFC0DB7A96A`
  (LocalServer `TpmVscMgrSvr.exe`).
- Interfaces: `ITpmVirtualSmartCardManager` `112B1DFF-D9DC-41F7-869F-D67FEE7CB591`,
  `ITpmVirtualSmartCardManager2` `FDF8A2B9-02DE-47F4-BC26-AA85AB5E5267`,
  `StatusCallback` `1A1BB35F-ABB8-451C-A1AE-33D98F1BEF4A`.
- Methode `CreateVirtualSmartCardWithPinPolicy` (Opnum 5).
- Warum es auf ARM64 mit .NET Framework scheitert: der Interface-**Proxy/Stub** wird
  in-proc geladen und ist native ARM64 → in einen emulierten FW-Prozess nicht ladbar
  → `QueryInterface` `0x800700C1`. Deshalb muss der **COM-Client nativ ARM64** sein.

## ARBEITSKONVENTIONEN (unbedingt einhalten)
- Alle `.ps1`/`.psm1` **IMMER als UTF-8 MIT BOM** speichern (sonst Umlaut-Mojibake in PS 5.1).
- **„Geschwister-Suchlauf":** vor JEDEM Fix per Suche ALLE Stellen mit demselben
  Symptom/derselben Logik finden und **gemeinsam** beheben; Logik an **einer** Stelle
  zentralisieren (eine „Quelle der Wahrheit").
- **In echter GUI testen** und ehrlich berichten, was getestet wurde.
- **Versionierung ist git-abgeleitet** (Build-Nummer = Commit-Anzahl, siehe `Get-AppVersion`
  und `build.ps1`) — KEIN lokaler Hook, das reist mit dem Repo. Nicht umbauen.
- Nach dem Push auf `main` einen **Draft-PR** anlegen, falls noch keiner offen ist.
- Commits mit den vorgesehenen Attributionszeilen abschließen.

## ORIENTIERUNG IM REPO
- `STATUS.md` — Projektstand, Backlog, mentales Modell, Konventionen (**zuerst lesen**).
- `RUNBOOK.md` — die fünf Szenarien (01 onprem-Adminkonto, 02 onprem/hybrid-Konto,
  03 Cloudonly-Adminkonto/Entra CBA, 04 VSCs verwalten, 05 EOBO).
- `docs/ARM64-native-vsc.md` — die ARM64-Skizze (**deine Hauptaufgabe**).
- `modules/VscWizard.Core.psm1` — Kernlogik (`New-VirtualSmartCard`, TPM-Erkennung,
  certreq/certutil-Wrapper).
- `modules/VscWizard.CreateHelper.cs` — der COM-Helfer (Basis für die .NET-Portierung).
- `VscWizard.ps1` — die GUI (Szenario-Startseite, Plan A/B, Dialoge).
- `build.ps1` — PS2EXE-Build + `version.txt`-Erzeugung.

## WICHTIGES MENTALES MODELL (damit du nichts kaputt machst)
- Eine VSC läuft **nie ab** — nur das Zertifikat darauf. „Erneuern" ist ein Re-Enroll
  (neuer Schlüssel), kein echtes Renewal; im Tool nur die Wahl „neue/bestehende VSC".
- **On-Prem-Smartcard-Logon** braucht eine **starke** Zert-zu-Konto-Zuordnung
  (SID-Erweiterung, KB5014754) → nur Build-from-AD (Submit als Zielkonto / EOBO). Das
  **Offline-Template (Szenario 03)** taugt **nur für Entra CBA/Cloud**, NICHT für
  On-Prem-Logon.

## ABSCHLUSS
Zum Abschluss der ARM64-Arbeit: `STATUS.md` und `docs/ARM64-native-vsc.md` aktualisieren
(Backlog-Punkt 3 abhaken/ergänzen) und sauber committen.
