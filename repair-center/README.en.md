<div align="center">

# RepairCenter

**Repair, diagnose, maintain Windows and manage disks – with a UI, fully traceable and completely offline.**

Languages / Sprachen:
[Deutsch](README.md) | **English**

![Version](https://img.shields.io/badge/Version-1.5.1-1473e6)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078d4)
![PowerShell](https://img.shields.io/badge/Windows%20PowerShell-5.1%2B-5391fe)
![Offline](https://img.shields.io/badge/100%25-offline-2e7d32)
![Tests](https://img.shields.io/badge/Tests-184%2F184-2e7d32)
![License](https://img.shields.io/badge/License-MIT-yellow)

</div>

---

## What is RepairCenter?

RepairCenter turns the built-in Windows tools **DISM**, **SFC** and **chkdsk** into one
traceable workflow and puts a bilingual UI in front of it:

> find out what is actually needed → do only that → verify the result → document it properly

A **graded maintenance stage** then tidies up – from "lossless" to "aggressive", and every
stage can be simulated first. There are **no registry cleaners, no tuning tweaks, no cloud**:
no third-party modules, no internet connection, no telemetry.

## Features

### Four modes
| Mode | What happens | Typical duration |
|---|---|---|
| **Quick** | SFC plus a short integrity check | a few minutes |
| **Diagnose** | strictly read-only: CheckHealth, ScanHealth, `sfc /verifyonly`, `chkdsk /scan`, SMART | 5–20 minutes |
| **Repair** *(default)* | RestoreHealth **only when needed**, SFC, CBS analysis, verification | 10–40 minutes |
| **Full** | adds deep scan and forced repair | 20–60 minutes |

### Automatic escalation
When SFC reports "Cannot repair member file", the source files in the component store are
usually damaged themselves. RepairCenter detects this and runs a second pass **on its own**:
`DISM /RestoreHealth` → `sfc /scannow` → re-evaluation. If it is clean afterwards, the overall
status is correctly changed from FAILED to REPAIRED.

### Four maintenance levels
| Level | Contents | Reversibility |
|---|---|---|
| `None` | repair only | – |
| `Safe` *(default)* | temp files, DNS cache, WinSxS analysis, fragmentation analysis | nothing is lost |
| `Standard` | + WinSxS clean-up (only when DISM recommends it), update cache, WER, Delivery Optimization, thumbnails, **TRIM on SSD / defrag on HDD** | caches rebuild themselves |
| `Aggressive` | + `/ResetBase`, recycle bin, Windows Update component reset, Winsock/IP reset | restart required, warned about in the UI |

A **restore point** is created automatically before *Standard* and *Aggressive*.

### User interface
- **German by default**, English one click away – switchable at runtime
- **Dark theme by default**, light theme one click away; the choice is remembered
- Six areas: **Repair · System · History · Report · Schedule · About**
- Live progress, step table, colour-coded log (tool output can be hidden), findings list
- **Every engine parameter is exposed**: mode, maintenance level, simulation, skipping
  DISM/SFC/disk, disabling escalation, opting out of the restore point, file age and
  minimum free space under "Advanced"
- **Report viewer** inside the app: report, tool log, CBS excerpt, JSON – with copy button
- **Restart banner** with reasons and a "Restart now" button (60 s delay, `shutdown /a` cancels)
- **Schedule**: create and remove the weekly maintenance task
- **Demo mode** with five test scenarios – explore the whole UI without touching the system


## Disk management (since 1.1.0)

Format, change the file system and erase disks for good – in the **Disks** tab.
The system disk is always refused and every operation requires typing a
confirmation token (`DISK1`, `E:` …).

### Rescue first, then erase

Data can be secured in the same run before zeroing – the UI chains both into one
job: **back up data → erase**. If the backup fails, **nothing** is erased.

- **Copy** (source stays untouched until erasing) or **Move** (source is emptied
  only after a successful copy).
- Data volume and file count are measured up front and the free space on the
  target is checked. If it does not fit, the start button stays disabled.
- The target may never live on the disk that is about to be erased – this is
  caught.

**Why copying is fast:** it uses `robocopy` with **32 copy threads** (`/MT:32`)
and **unbuffered I/O** (`/J`). The first helps with many small files, the second
with large ones. Deliberately *not* set: `/Z` – restartable mode is notorious for
slowing copies down by a multiple, and is still recommended by many guides.
Threads and buffering are adjustable in the UI.

### Erasing: why this is faster

Most tools write buffered in 4 KiB to 1 MiB chunks and run three passes out of
habit. That, not the drive, is what causes the waiting.

| Situation | Typical tools | RepairCenter |
|---|---|---|
| BitLocker disk | hours of overwriting | **destroy the key – seconds** |
| SSD / NVMe | overwriting (slow *and* harmful to the cells) | **TRIM / UNMAP – seconds** |
| 8 TB HDD | 3 buffered passes: 20–40 hours | **1 unbuffered pass – about 12 hours, i.e. device speed** |
| Formatting right after erasing | zero the FAT again | **detects "already empty" – instant** |

The four levers:

1. **Unbuffered** (`FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH`): the file
   system cache is not flooded, data goes straight to the drive.
2. **Large blocks** – 32 MiB by default instead of 4 KiB. One request instead of
   eight thousand.
3. **Several outstanding requests** (queue depth 4, up to 8): the drive keeps
   working while the next request is already on its way. On NVMe this is a
   multiplier.
4. **One zero pass instead of three random passes.** On magnetic drives made
   after roughly 2001 nothing is recoverable after a single overwrite – more
   passes only cost time.

Block size and queue depth are adjustable in the UI, and the remaining time is
calculated live from the measured throughput.

### Five methods

| Method | When to use | Duration for 8 TB |
|---|---|---|
| `Automatic` | default – picks the fastest permitted | – |
| `Destroy BitLocker key` | encrypted disks | seconds |
| `TRIM / UNMAP` | SSD, NVMe | seconds |
| `Overwrite with zeros` | hard disks, handover, resale | ~12 h |
| `Overwrite and verify` | when proof is required | ~24 h |

### Formatting and changing the file system

- **NTFS, exFAT, FAT32, ReFS** – quick or full, free choice of label and cluster size.
- **FAT32 beyond the 32 GB limit:** Windows' own `format` refuses FAT32 above
  32 GB. RepairCenter ships its **own FAT32 formatter** built to the Microsoft
  specification – verified up to **2 TiB** with 512-byte sectors and **14 TiB**
  with 4 KiB sectors. Limits are reported with a reason instead of failing silently.
- **FAT32 → NTFS is lossless** via `convert.exe`. Any other change (e.g.
  NTFS → FAT32) is only possible by reformatting – the UI says so up front and
  requires separate consent.

### USB sticks and memory cards

Removable media are detected and named instead of showing up as "unknown drive":

| Bus / media type | Detected as |
|---|---|
| SD, MMC | **memory card** |
| USB, small (≤ 512 GB) | **USB stick** |
| USB + HDD | USB hard disk |
| USB + SSD | USB SSD |
| NVMe | NVMe SSD |
| SATA + HDD | hard disk |

Every card shows its kind as a badge, removable media additionally get a
"removable" badge. Detection combines `Get-Disk`, `Get-PhysicalDisk` and
`Win32_DiskDrive`, because no single source is reliable on its own.

### Protecting the service

The web service listens on `localhost` only. Because a local service is still
reachable from any browser window, every writing request must carry the
`X-RepairCenter` header, preflight requests are not answered and foreign
`Origin` values are rejected. All fields are checked against allowlists before
they become process arguments, and only one disk operation runs at a time.
Details in [SECURITY.md](SECURITY.md).

### Safety net

- If the preceding backup fails, the erase is **not** started.
- System disks and read-only media are **always** refused – in the UI, in the API
  and in the engine itself (checked three times).
- The confirmation token must match exactly, otherwise the button stays disabled.
- Every operation runs as its own process with live progress and can be cancelled.
- In demo mode everything can be rehearsed safely.


## Disk analysis – why Windows misses failures

Windows almost always reports "Healthy". That only means *the drive still
answers*. A disk with hundreds of pending sectors counts as healthy – until it
dies. The **Analysis** tab therefore looks where the truth is: raw SMART values
(pending 197, uncorrectable 198, reallocated 5, CRC 199, hours, temperature,
wear), the reliability counters, the event log (`disk 7/11/51/52`,
`Ntfs 55/98/130`, `storahci 129`) and a surface test with unbuffered read probes
spread evenly across the whole disk – which also spots *slow* areas where the
electronics need several attempts.

The result is a four-step verdict – **Healthy · Keep an eye on it · Replacement
recommended · Critical** – and every step lists its reasons. Events are matched
to the disk they came from, so one sick drive no longer drags the others down
with it.

## Finding and repairing damaged files

The **Files** tab distinguishes three kinds of damage: **not readable** (bad
sectors – the case Windows never reports until someone touches the file),
**structure damaged** (JPEG without its end marker, PNG without `IEND`, PDF
without `%%EOF`, archive without a central directory, executable without a PE
signature – only head and tail are read, so even gigabyte files take
milliseconds) and **empty** (0 bytes where content should be).

Repair order: **system file → SFC** (one run for all, not one per file),
**otherwise → previous version** from a shadow copy with the damaged version
kept alongside, and **if nothing works → say so honestly**.

## Updating

Every area has its own refresh, plus a global one in the header and an **Auto**
switch (every 5 seconds, remembered). For the program itself the **About** tab
checks a folder – removable media, network share or downloads – for packages
named `RepairCenter-X.Y.Z.zip`. **Nothing is downloaded**; a find is only
reported, installing is done through the installer.


## Live operation instead of demo

The preview runs on **made-up values** so you can try everything safely. On your
Windows machine live operation is the **default**:

```powershell
RepairCenter.cmd          # real disks
RepairCenter.cmd -Demo    # demo mode for practising and presenting
```

Before the first run: **System → Readiness for live operation → Check**. It
states plainly which measurement sources this machine provides – administrator
rights, SMART (often not passed through by USB enclosures and RAID), reliability
counters, event log, raw access, shadow copies and the built-in tools. A yellow
item is not a failure but a named limitation.

The full guide is in [docs/ECHTBETRIEB.md](docs/ECHTBETRIEB.md) (German),
including the order that matters with a dying disk: **rescue first, measure
afterwards.**

### Installing an update

If the package check finds a newer release, **Install now** appears: verify that
no job is running and the package is complete → **back up** the current version
next to the program folder → stop the service, install, restart → and if
anything fails, **the backup is restored**. A running service cannot overwrite
itself, so `tools/Apply-Update.ps1` does the work as its own process. Runtime
data under `C:\RepairLogs` stays untouched.

## Installation

**Option A – setup program** (classic wizard, start menu entry, uninstaller):

1. Download `RepairCenter-Setup-1.0.0.exe` from the [releases page](../../releases)
2. Double-click and follow the wizard (German or English)
3. Start from the start menu → **RepairCenter**

**Option B – without a setup program:**

1. Download and extract the repository
2. Run `installer\Install.cmd` as administrator

**Option C – portable:** double-click `RepairCenter.cmd`. Nothing is installed.

All options only require **Windows 10/11 with Windows PowerShell 5.1**, which is already
on board. No runtime, no libraries, no internet.

## Usage

After the start the UI opens at `http://localhost:8720/`.
The service binds to **localhost only** and cannot be reached from outside.

### Command line

The same engine without a UI – for the task scheduler and remote maintenance:

```powershell
.\src\RepairCenter.Cli.ps1                              # repair + safe maintenance
.\src\RepairCenter.Cli.ps1 -Mode Diagnose               # check only
.\src\RepairCenter.Cli.ps1 -Mode Full -Optimize Standard
.\src\RepairCenter.Cli.ps1 -Optimize Aggressive -WhatIf # simulate first
```

The script requests administrator rights on its own when needed (UAC).

| Exit code | Meaning |
|---|---|
| 0 | HEALTHY – system is intact |
| 1 | REPAIRED – restart recommended |
| 2 | WARNING – review the findings |
| 3 | FAILED – repair with an installation source required |
| 4 | no administrator rights |
| 5 | UAC cancelled |

## Reports

Every run writes to `C:\RepairLogs\runs\<timestamp>\`:

| File | Contents |
|---|---|
| `report.txt` | human readable result report |
| `state.json` | complete data, machine readable |
| `tools.log` | raw output of DISM, SFC, chkdsk |
| `transcript.log` | full session transcript |
| `CBS-SFC.txt` | the relevant `[SR]` lines of this run |

## Architecture

| Component | Responsibility |
|---|---|
| `src/modules/RepairEngine.psm1` | core: preflight, repair, escalation, verification, maintenance, report |
| `src/modules/DiskAnalysis.psm1` | raw SMART values, event log, surface test, verdict |
| `src/modules/FileIntegrity.psm1` | finding damaged files, format checks, repair via SFC and previous versions |
| `src/modules/DiskManager.psm1` | disks: inventory, formatting, FAT32 formatter, file system change, fast erase |
| `src/RepairCenter.DiskJob.ps1` | runs one disk operation as its own process |
| `src/RepairCenter.Server.ps1` | backend: REST API and UI delivery (`HttpListener`) |
| `src/RepairCenter.Runner.ps1` | runs one job as its own process so the UI never blocks |
| `src/RepairCenter.Cli.ps1` | command line with automatic elevation |
| `web/` | UI: plain HTML/CSS/JavaScript, no dependencies |
| `web/i18n/` | German and English language packs |
| `installer/` | Inno Setup script, `Install.cmd`, `Uninstall.cmd` |
| `tests/` | self-test (101 tests), UI tests (83 tests, 14 of them against the real service), PowerShell 5.1 compatibility check |
| `tools/Update-Version.ps1` | sets and verifies the version across the project |
| `tools/Apply-Update.ps1` | installs a package: backup, swap, restart, rollback on failure |
| `tools/Invoke-Analyzer.ps1` | static analysis that aborts on a missing module instead of reporting success |

Backend and UI talk over a small REST API:

| Endpoint | Purpose |
|---|---|
| `GET /api/system` | system overview |
| `POST /api/run` | start a run |
| `GET /api/run/{id}` | progress, steps, log |
| `POST /api/run/{id}/cancel` | cancel a run |
| `GET /api/runs` | history (damaged entries stay visible) |
| `DELETE /api/run/{id}` | remove a run from the history |
| `GET /api/report/{id}` | report (`?format=json` / `tools` / `cbs` / `transcript`) |
| `GET /api/health` | service heartbeat |
| `GET /api/config` | version, storage location, operating mode |
| `GET POST DELETE /api/schedule` | weekly maintenance task |
| `POST /api/restart` | restart with a 60 second delay |
| `GET /api/disks` | disks, volumes, protection status |
| `GET /api/disk/estimate` | method and estimated duration |
| `GET /api/disk/active` | is a disk operation currently running? |
| `POST /api/disk/analyze` | start a disk analysis |
| `POST /api/files/scan` · `/repair` | find and repair damaged files |
| `GET /api/update/check` | check a package folder for a newer release |
| `POST /api/update/apply` | install the update and restart |
| `GET /api/readiness` | which measurement sources does this machine provide? |
| `GET /api/disk/targets` | possible targets for the backup |
| `GET /api/disk/measure` | data volume and file count of a disk |
| `POST /api/disk/format` · `/convert` · `/wipe` | start an operation |
| `GET /api/disk/job/{id}` | progress, throughput, remaining time |

## Test environment

In demo mode the engine simulates a system state instead of really calling DISM and SFC.
**Five scenarios** let you walk through every possible outcome without needing a broken
Windows installation:

| Scenario | What is simulated | Expected result |
|---|---|---|
| `Healthy` | no findings | HEALTHY |
| `Repaired` | SFC repairs two files | REPAIRED + restart reason |
| `Escalation` | SFC fails, DISM helps, second pass is clean | REPAIRED, first finding downgraded to WARNING |
| `Failed` | SFC fails, DISM fails as well | FAILED + hint about the missing installation source |
| `Preflight` | preflight blocks | FAILED, **no** changes to the system |

## Tests

```powershell
.\tests\Test-RepairCenter.ps1     # 101 tests: engine, scenarios, disks, API, compatibility
.\tests\Test-Compat51.ps1         # compatibility check only
```

```bash
npm install && npm test            # 83 UI tests (jsdom, no browser)
```

**184 tests** in total. The PowerShell self-test runs entirely in demo mode – it does not
touch the system and also works under PowerShell 7 (Linux/CI). The UI tests run against a
mocked backend and cover the default language, default theme, completeness of all controls,
language switching, form → request mapping, rendering of steps/findings/log, the restart
banner, the report viewer, scheduling and protection against HTML injection.
**Node.js is only needed for testing – the application itself runs without it.**

The compatibility check uses AST and token analysis to find constructs that PowerShell 7
accepts but Windows PowerShell 5.1 rejects – such as `break` inside a `finally` block
(`ControlLeavingFinally`), `??`, `&&`/`||` or `-Parallel`.

## What RepairCenter deliberately does not do

- no registry "cleaners", no "RAM optimisers", no tuning tweaks
- it never disables services or startup entries on its own – they are only reported
- it never deletes `Windows.old` or user data
- no cloud, no telemetry, no network connection

## Documentation

- [CHANGELOG](CHANGELOG.md) – all versions
- [Architecture](docs/ARCHITEKTUR.md) – structure and data flow
- [Security](SECURITY.md) – privileges, binding, data handling
- [Contributing](CONTRIBUTING.md)

## License

[MIT](LICENSE) – Copyright © 2026 AOWD GENESIS.

---

<div align="center">

**RepairCenter – it fixes what is broken. And leaves everything else alone.**

</div>
