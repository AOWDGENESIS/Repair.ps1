# Architektur

## Überblick

RepairCenter besteht aus vier Teilen, die sich eine einzige Engine teilen.

```
   Browser (localhost)                  Windows
   +---------------------+
   |  web/index.html     |
   |  app.js  styles.css |
   |  i18n/de.json  en   |
   +----------+----------+
              | HTTP (nur localhost:8720)
              v
   +---------------------------+
   |  RepairCenter.Server.ps1  |   REST-API + Auslieferung der Oberflaeche
   |  (System.Net.HttpListener)|   liest nur Dateien, rechnet nie lange
   +----+-----------------+----+
        | startet          | liest
        v                  |
   +---------------------------+        +---------------------------+
   |  RepairCenter.Runner.ps1  | -----> |  <LogRoot>/runs/<id>/     |
   |  (eigener Prozess)        | schreibt| state.json  report.txt   |
   +-------------+-------------+        | tools.log   transcript   |
                 |                      +---------------------------+
                 v
   +---------------------------+
   |  modules/RepairEngine.psm1|  DISM · SFC · chkdsk · CBS · Wartung
   +---------------------------+
                 ^
                 |
   +---------------------------+
   |  RepairCenter.Cli.ps1     |  gleiche Engine ohne Oberflaeche
   +---------------------------+
```

Der entscheidende Punkt: **das Backend führt selbst nichts Langlaufendes aus.**
Es startet den Runner als eigenen Prozess und liest danach nur noch dessen
Zustandsdatei. Dadurch bleibt die Oberfläche auch während eines 40-Minuten-Laufs
bedienbar, und ein abgestürzter Runner reißt den Dienst nicht mit.

## Ablauf eines Laufs

```
Initialize
    |
    v
Preflight ----- blockiert? ----> Bericht -> Ende
    |
    v
Reparatur      DISM (nur wenn noetig) -> SFC
    |
    v
Auswertung     CBS.log des aktuellen Laufs
    |
    +-- "Cannot repair"? --> Eskalation: DISM -> SFC -> erneute Auswertung
    |
    v
Verifikation   Komponentenstore, chkdsk /scan, SMART
    |
    v
Wartung        Stufe None | Safe | Standard | Aggressive
    |
    v
Bericht        report.txt + state.json + tools.log
    |
    v
Cleanup        Exitcode 0/1/2/3
```

## Datenträgerverwaltung

Derselbe Aufbau wie bei den Reparaturläufen: das Backend startet
`RepairCenter.DiskJob.ps1` als eigenen Prozess, der seinen Fortschritt nach
`<LogRoot>/diskjobs/<JobId>/state.json` schreibt. Ein zwölfstündiger
Löschvorgang blockiert die Oberfläche damit an keiner Stelle.

```
modules/DiskManager.psm1
  ├── Get-DiskInventory          Datenträger, Volumes, Schutzstatus
  ├── Test-DiskOperationAllowed  Sicherheitsnetz (System, Schreibschutz, Schlüssel)
  ├── Get-WipeStrategy           BitLocker -> CryptoErase, SSD -> Trim, HDD -> Zero
  ├── Get-WipeEstimate           Dauer aus Größe, Anbindung und Medientyp
  ├── Format-ManagedVolume       NTFS, exFAT, FAT32, ReFS
  ├── Format-LargeFat32Volume    eigener Formatierer jenseits der 32-GB-Grenze
  ├── Convert-VolumeFileSystem   verlustfrei über convert.exe, sonst mit Ansage
  └── Clear-DiskContent          Löschen nach gewähltem Verfahren
        └── C#: RepairCenter.Storage.ZeroWiper
```

Die C#-Bausteine werden zur Laufzeit mit `Add-Type` übersetzt (bewusst
C#-5-Syntax, damit der Compiler von Windows PowerShell 5.1 sie annimmt).
Der Geräteszugriff ist gekapselt: unter Windows über `CreateFileW` mit
`FILE_FLAG_NO_BUFFERING`, außerhalb von Windows als gewöhnliche Datei – dadurch
lässt sich der FAT32-Formatierer gegen ein Abbild testen, ohne echte Hardware.

## Zustandsdatei `state.json`

Einzige Schnittstelle zwischen Runner und Oberfläche. Sie wird nach jedem Ereignis
atomar geschrieben (erst `.tmp`, dann verschieben), höchstens alle 400 ms.

```jsonc
{
  "schema": 1,
  "runId": "20260929-084424",
  "mode": "Repair",            // Quick | Diagnose | Repair | Full
  "optimize": "Standard",      // None | Safe | Standard | Aggressive
  "demo": false,
  "status": "running",         // running | done
  "overall": "REPAIRED",       // HEALTHY | REPAIRED | WARNING | FAILED
  "progress": 92,
  "currentStep": "OPT_Bereinigung",
  "steps": [
    { "name": "SFC", "status": "REPAIRED", "exitCode": 0,
      "detail": "2 Datei(en) repariert", "durationSec": 412.7 }
  ],
  "findings":       [ { "level": "warn", "text": "..." } ],
  "restartRequired": true,
  "restartReasons":  [ "SFC hat Systemdateien repariert" ],
  "freeSpaceStartGB": 41.2,
  "freeSpaceEndGB":   43.6,
  "reclaimedGB":       2.4,
  "log": [ { "t": "08:44:31", "kind": "ok", "text": "..." } ],
  "exitCode": 1
}
```

`kind` ist einer von `info`, `ok`, `warn`, `error`, `section`, `tool` und steuert
die Einfärbung im Protokollfenster.

## Statusmodell

| Status | Bedeutung |
|---|---|
| `PASS` | Schritt ohne Befund |
| `REPAIRED` | Schritt hat etwas repariert – Neustart wird vorgemerkt |
| `WARNING` | Auffälligkeit, kein Fehler |
| `REBOOT` | Werkzeug meldet Exitcode 3010 |
| `SKIPPED` | bewusst nicht ausgeführt (nicht nötig oder abgewählt) |
| `FAILED` | Schritt fehlgeschlagen |

Der Gesamtstatus ist die schlechteste Einzelbewertung, mit einer Ausnahme:
Behebt die Eskalation einen zuvor gescheiterten SFC-Lauf, werden die überholten
Schritte auf `WARNING` zurückgestuft, damit das Endergebnis die Realität abbildet.

## Warum das SFC-Ergebnis aus CBS.log kommt

`sfc.exe` liefert keine verlässlichen Exitcodes: derselbe Code steht je nach Windows-
Version für „nichts gefunden", „repariert" oder „Neustart nötig". Verlässlich ist nur
`C:\Windows\Logs\CBS\CBS.log`. Die Engine liest sie mit
`FileShare::ReadWrite` – also auch dann, wenn Windows die Datei geöffnet hält – und
wertet ausschließlich `[SR]`-Zeilen **ab dem Startzeitpunkt des Laufs** aus. Sonst
würden Befunde von vor Wochen als aktuelles Ergebnis erscheinen.

## Fehlerbehandlung

- Jeder Schritt läuft in `Invoke-EngineStep`. Eine Ausnahme beendet nie den Lauf,
  sie wird als `FAILED` mit Meldung erfasst.
- Native Werkzeuge werden mit lokal auf `Continue` gesetztem `$ErrorActionPreference`
  aufgerufen: sonst würde jede stderr-Zeile (z. B. von chkdsk) den Schritt abbrechen.
- Fortschrittsbalken von DISM werden auf 10-%-Schritte eingedampft, damit weder
  Konsole noch Protokoll zugemüllt werden.

## Kompatibilität

Ziel ist **Windows PowerShell 5.1** – vorhanden auf jedem Windows 10/11. PowerShell 7
funktioniert ebenfalls, ist aber nie Voraussetzung. `tests/Test-Compat51.ps1` prüft
per AST und Tokenstrom, dass sich keine PowerShell-7-Syntax einschleicht; besonders
`break` in einem `finally`-Block, das PowerShell 7 klaglos akzeptiert und Windows
PowerShell 5.1 mit `ControlLeavingFinally` ablehnt.
