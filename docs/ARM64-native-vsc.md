# Native ARM64-VSC-Erstellung (eigener PIN-Dialog statt tpmvscmgr-Konsole)

> Status: **UMGESETZT (Option A)** am 2026-09-28 auf echter ARM64-Hardware
> (Snapdragon X Elite, Windows 11 ARM64). Fallback (tpmvscmgr.exe) bleibt bestehen.
>
> **Ergebnis der Validierung** (nativer ARM64-.NET-8-Prozess, eleviert):
> `CreateInstance` OK, `QueryInterface` auf `ITpmVirtualSmartCardManager` und
> `…Manager2` jeweils `0x00000000` - kein `0x800700C1`. Ohne Elevation:
> `0x800702E4` (ERROR_ELEVATION_REQUIRED) - erwartet.
> Hinweis: die installierte `pwsh` 7 war die **x64**-Variante (emuliert) - der
> Test-Snippet unten wäre damit NICHT aussagekräftig gewesen; validiert wurde daher
> direkt mit einer nativen .NET-8-win-arm64-Konsolen-App.
>
> **Umsetzung:**
> - `helper/VscCreateHelper.csproj` kompiliert **dieselbe** Quelldatei
>   `modules/VscWizard.CreateHelper.cs` (per `<Compile Include>`, keine Kopie) als
>   self-contained Einzeldatei für `win-arm64` (~60 MB; WinForms ist nicht trimmbar).
> - `build.ps1` ruft `dotnet publish` auf, falls das .NET SDK vorhanden ist →
>   `dist\helper-arm64\VscCreateHelper.exe` (wird mitsigniert).
> - `New-VirtualSmartCard`: auf ARM64 den nativen Helfer nach `C:\Users\Public`
>   kopieren und eleviert starten (gleiche Result-Datei wie beim csc-Weg); fehlt er →
>   tpmvscmgr.exe. Suche über `Get-NativeCreateHelperPath` (`<App>\helper-arm64` und
>   `<Repo>\dist\helper-arm64`).
> - **ARM64-Erkennung** (`Get-NativeOsArchitecture`) liest den systemweiten Wert aus
>   `HKLM\...\Session Manager\Environment`: `$env:PROCESSOR_ARCHITECTURE` meldet in
>   emulierten Prozessen (z.B. der PS2EXE-Exe) `AMD64` und wird sogar an native
>   Kindprozesse vererbt; `RuntimeInformation::OSArchitecture` meldet dort `X64`.
> - PIN-Dialog-Abbruch (`Cancelled=True` in der Result-Datei) und UAC-Abbruch
>   (Fehler 1223) gelten als Benutzerabbruch → **kein** tpmvscmgr-Fallback mehr.
> - Real getestet: Erstellung per `New-VirtualSmartCard` und per GUI (`dist\VscWizard.exe`),
>   PIN-Dialog ohne Konsolenfenster, PIN-Policy via Manager2 (Mindestlänge 6).
>
> Die ursprüngliche Design-Skizze folgt unverändert.

## Problem (warum aktuell tpmvscmgr auf ARM64)

Unser eigener COM-Weg (`modules/VscWizard.CreateHelper.cs`) erzeugt die VSC über die
COM-API und zeigt einen **eigenen maskierten PIN-Dialog** – kompiliert per in-box
`csc` (.NET **Framework**) zu einem `/target:winexe`, eleviert gestartet.

Auf **ARM64** hat .NET Framework **keine native Laufzeit**: das AnyCPU-FW-Exe läuft
emuliert. Beim `QueryInterface` auf `ITpmVirtualSmartCardManager[2]` scheitert es mit
**`0x800700C1` (BAD_EXE_FORMAT)**.

Wichtiges Detail aus dem Helfer-Code:
- CoClass **`TpmVirtualSmartCardManager`**, CLSID `16A18E86-7F6E-4C20-AD89-4FFC0DB7A96A`
  – ein **LocalServer** (`TpmVscMgrSvr.exe`, out-of-proc).
- Interfaces: `ITpmVirtualSmartCardManager` (IID `112B1DFF-D9DC-41F7-869F-D67FEE7CB591`),
  `ITpmVirtualSmartCardManager2` (IID `FDF8A2B9-02DE-47F4-BC26-AA85AB5E5267`),
  `…StatusCallback` (IID `1A1BB35F-ABB8-451C-A1AE-33D98F1BEF4A`).
- Methode: `CreateVirtualSmartCardWithPinPolicy` (Opnum 5) bzw. `CreateVirtualSmartCard`.

Da der Server **out-of-proc** ist, wird nicht der Server in unseren Prozess geladen –
wohl aber der **Proxy/Stub** der Schnittstelle (fürs Marshaling), und der ist native
ARM64. In einen emulierten Prozess lässt er sich nicht laden → `QueryInterface`
scheitert. **Fazit: der COM-Client-Prozess muss NATIV ARM64 sein.**

## Ziel & Randbedingung

- Auf ARM64 die VSC über **unseren eigenen PIN-Dialog** erstellen (statt
  tpmvscmgr-Konsole).
- **Sicherheits-Randbedingung (nicht aufweichen):** Die PIN darf **den elevierten
  Prozess nie verlassen** – nicht über Kommandozeile, Datei oder Env-Var. Deshalb muss
  der **PIN-Dialog INNERHALB des elevierten, nativen Prozesses** laufen (genau wie
  heute im FW-Helfer und bei `tpmvscmgr /PIN PROMPT`).

## Erster, billiger Validierungsschritt (vor jeder Implementierung!)

Bestätigen, dass ein **nativer ARM64-Prozess** die COM-Instanz wirklich bekommt.
In einer **elevierten, nativen ARM64 PowerShell 7** (`pwsh`):

```powershell
Add-Type @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("112B1DFF-D9DC-41F7-869F-D67FEE7CB591"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITpmVscMgr { }
public static class T {
  public static object Get() {
    Type t = Type.GetTypeFromCLSID(new Guid("16A18E86-7F6E-4C20-AD89-4FFC0DB7A96A"));
    return Activator.CreateInstance(t);
  }
}
"@
$mgr = [T]::Get()
[System.Runtime.InteropServices.Marshal]::GetIUnknownForObject($mgr)  # QI-Test
"OK - COM-Instanz erhalten, kein 0x800700C1"
```

- **Kein** `0x800700C1` → nativer Weg ist tragfähig → weiter mit Option A.
- Schlägt es auch nativ fehl → das Problem liegt woanders; dann NICHT weiterbauen,
  sondern die Fehlermeldung analysieren (tpmvscmgr bleibt.)

## Option A (empfohlen): eigenen Helfer als **native ARM64-.NET-App** bauen

Den vorhandenen `VscWizard.CreateHelper.cs` (Interfaces + PIN-Dialog +
`CreateVirtualSmartCardWithPinPolicy`) fast **unverändert** in ein winziges
**.NET (Core) WinForms**-Projekt überführen und beim Build **nativ für ARM64**
veröffentlichen.

Bausteine:
1. `helper/VscCreateHelper.csproj` (neu, im Repo):
   - `net8.0-windows`, `UseWindowsForms=true`, `OutputType=WinExe`.
   - `RuntimeIdentifier=win-arm64`, `SelfContained=true` (keine Laufzeit-Abhängigkeit
     beim Endnutzer), `PublishSingleFile=true`.
   - `Program.cs` = quasi der heutige `.cs`-Inhalt (COM-Interop identisch; STA über
     `[STAThread]` in `Main`).
2. `build.ps1`: falls `dotnet` (SDK) vorhanden →
   `dotnet publish helper -c Release -r win-arm64 --self-contained -o dist\helper-arm64`.
   Ergebnis: `dist\helper-arm64\VscCreateHelper.exe` (nativ ARM64).
   (Optional zusätzlich `-r win-x64` → damit ließe sich der **Runtime-`csc`-FW-Weg
   auf x64 ebenfalls durch denselben Helfer ersetzen** und beide Architekturen
   vereinheitlichen.)
3. `New-VirtualSmartCard` (ARM64-Zweig in `modules/VscWizard.Core.psm1`):
   - Wenn `…\helper-arm64\VscCreateHelper.exe` existiert → **den** eleviert starten
     (`Start-Process -Verb RunAs -Wait`), Ergebnis wie heute aus der Result-Datei lesen.
     PIN-Dialog + COM laufen komplett im elevierten nativen Prozess.
   - Sonst → **Fallback tpmvscmgr.exe** (aktuelles Verhalten).

Vorteile: eigener PIN-Dialog auch auf ARM64; PIN verlässt den elevierten Prozess nie;
**keine** Laufzeit-Abhängigkeit (self-contained); Helfer-Code wird wiederverwendet.
Nachteile: **.NET SDK zur BUILD-Zeit** nötig; self-contained ARM64-Publish ist größer
(~einige MB, aber nur Dist-Artefakt, nicht committet); `build.ps1` bekommt einen
`dotnet publish`-Schritt.

## Option B: **PowerShell 7 (ARM64)** zur Laufzeit

Elevierte, native `pwsh` startet ein Skript, das den Interop per `Add-Type` (Roslyn)
kompiliert, auf einem **STA-Thread** den WinForms-PIN-Dialog zeigt und die VSC erstellt;
Ergebnis in eine Result-Datei.

Vorteile: kein Build-SDK nötig. Nachteile: **`pwsh` 7 (ARM64) muss auf JEDER
Zielmaschine installiert sein** (nicht in-box) → Laufzeit-Abhängigkeit; `pwsh` läuft
per Default MTA → WinForms braucht einen **manuell erzeugten STA-Thread**; Roslyn-
Kompilat bei jedem Aufruf. Insgesamt fragiler als Option A.

## Empfehlung

**Option A** (native ARM64-.NET-Helfer, self-contained, im Build erzeugt) – bester
Endnutzer-Weg, Code-Wiederverwendung, PIN-Sicherheit bleibt. **tpmvscmgr bleibt der
Fallback**, wenn der Helfer fehlt oder fehlschlägt. Vorher unbedingt den
Validierungsschritt oben ausführen.

## Betroffene Stellen (für die Umsetzung)

- `modules/VscWizard.Core.psm1` → `New-VirtualSmartCard` (ARM64-Zweig ~Z. 650).
- `modules/VscWizard.CreateHelper.cs` → Basis für `helper/Program.cs`.
- `build.ps1` → optionaler `dotnet publish`-Schritt (arm64, ggf. x64).
- Kein committetes Binär-Artefakt; alles wird im Build erzeugt.
