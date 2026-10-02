#Requires -Version 5.1
<#
=========================================================================
 Repair - Windows-Reparatur, Diagnose & Wartung
 Version: 3.0.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 100 % lokal - keine Cloud, keine Telemetrie, keine Fremdmodule
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
-------------------------------------------------------------------------
 Ablauf:  Initialize -> Preflight -> Repair -> Analyze -> (Eskalation)
          -> Verify -> Optimize -> Report -> Cleanup

 Grundsatz: Es wird nur ausgefuehrt, was noetig ist. Jede Aenderung ist
 einer Stufe zugeordnet, protokolliert und ueber -WhatIf simulierbar.
=========================================================================

.SYNOPSIS
    Repariert, prueft und wartet eine Windows-Installation.

.DESCRIPTION
    Vier Modi:
      Quick     - nur SFC + schnelle Integritaetspruefung
      Diagnose  - ausschliesslich lesend (CheckHealth, ScanHealth,
                  sfc /verifyonly, chkdsk /scan, Datentraeger-Gesundheit)
      Repair    - Standard: DISM /RestoreHealth + SFC + Verifikation
      Full      - Repair + ScanHealth + chkdsk /scan + alle Analysen

    Vier Optimierungsstufen (-Optimize):
      None        - keine Wartung
      Safe        - rein additiv/verlustfrei: Temp-Dateien, DNS-Cache,
                    Component-Store-Analyse, Fragmentierungsanalyse
      Standard    - zusaetzlich: WinSxS-Bereinigung (StartComponentCleanup),
                    Windows-Update-Cache, WER, Delivery Optimization,
                    Thumbnail-Cache, TRIM/Defrag
      Aggressive  - zusaetzlich: /ResetBase, Papierkorb, Windows-Update-
                    Komponenten-Reset, Winsock/IP-Reset  (erfordert Neustart)

.PARAMETER Mode
    Quick | Diagnose | Repair (Standard) | Full

.PARAMETER Optimize
    None | Safe (Standard) | Standard | Aggressive

.PARAMETER SkipDism
    Ueberspringt saemtliche DISM-Schritte.

.PARAMETER SkipSfc
    Ueberspringt SFC und die CBS-Auswertung.

.PARAMETER SkipDisk
    Ueberspringt chkdsk /scan sowie TRIM/Defrag.

.PARAMETER NoEscalate
    Verhindert den automatischen zweiten Anlauf (DISM + SFC), wenn SFC
    Dateien nicht reparieren konnte.

.PARAMETER NoRestorePoint
    Legt vor Wartungsstufe Standard/Aggressive keinen Wiederherstellungspunkt an.

.PARAMETER Force
    Uebergeht eine vorhandene Sperrdatei eines parallelen Laufs.

.PARAMETER NoElevate
    Keine automatische Rechteerhoehung. Ohne Administratorrechte wird
    dann sauber abgebrochen (fuer Taskplaner/Automatisierung).

.PARAMETER Elevated
    Wird intern beim Neustart mit Administratorrechten gesetzt. Nicht
    manuell verwenden - haelt lediglich das Fenster am Ende offen.

.EXAMPLE
    .\Repair.ps1
    Standardreparatur mit sicherer Wartung.

.EXAMPLE
    .\Repair.ps1 -Mode Diagnose
    Reine Bestandsaufnahme, veraendert nichts.

.EXAMPLE
    .\Repair.ps1 -Mode Full -Optimize Standard

.EXAMPLE
    .\Repair.ps1 -Optimize Aggressive -WhatIf
    Zeigt an, was die aggressive Stufe tun wuerde - ohne es zu tun.

.NOTES
    Das Skript startet sich bei Bedarf selbst mit Administratorrechten
    neu (UAC-Abfrage). Ein Rechtsklick auf "Als Administrator ausfuehren"
    ist damit nicht mehr noetig - Doppelklick bzw. "Mit PowerShell
    ausfuehren" genuegt.

    Exitcodes des Skripts:
      0 = HEALTHY    1 = REPAIRED (Neustart empfohlen)
      2 = WARNING    3 = FAILED
      4 = keine Administratorrechte   5 = UAC abgebrochen
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interaktives Konsolenwerkzeug: farbige Statusausgabe ist gewollt und wird per Transcript protokolliert.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Parameter werden in verschachtelten Funktionen und Scriptblocks ueber den Skript-Scope verwendet.')]
param(
    [ValidateSet('Quick', 'Diagnose', 'Repair', 'Full')]
    [string]$Mode = 'Repair',

    [ValidateSet('None', 'Safe', 'Standard', 'Aggressive')]
    [string]$Optimize = 'Safe',

    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\RepairLogs',

    [ValidateRange(0, 365)]
    [int]$TempFileAgeDays = 2,

    [ValidateRange(0, 3650)]
    [int]$LogRetentionDays = 30,

    [ValidateRange(1, 500)]
    [int]$MinFreeSpaceGB = 8,

    [switch]$SkipDism,
    [switch]$SkipSfc,
    [switch]$SkipDisk,
    [switch]$NoEscalate,
    [switch]$NoRestorePoint,
    [switch]$NoTranscript,
    [switch]$Force,
    [switch]$NoElevate,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

#region ================= Automatische Rechteerhoehung (UAC) =================

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# Baut die aktuelle Parameterliste fuer den erhoehten Neustart nach.
# Wichtig: die gebundenen Parameter muessen uebergeben werden - innerhalb
# einer Funktion ist $PSBoundParameters ihre eigene (leere) Variable.
function Get-RelaunchArgumentList {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$BoundParameters
    )
    $list = New-Object System.Collections.ArrayList
    foreach ($entry in $BoundParameters.GetEnumerator()) {
        if ($entry.Key -in @('Elevated', 'NoElevate')) { continue }
        $value = $entry.Value
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { [void]$list.Add('-' + $entry.Key) }
            continue
        }
        # Abschliessende Backslashes wuerden das schliessende Anfuehrungszeichen
        # maskieren ("C:\Logs\" -> kaputt), deshalb entfernen.
        $text = ([string]$value).TrimEnd('\').Replace('"', '`"')
        [void]$list.Add('-' + $entry.Key)
        [void]$list.Add('"' + $text + '"')
    }
    # nur ergaenzen, wenn nicht ohnehin schon gebunden (sonst doppelt)
    if ($WhatIfPreference -and -not $BoundParameters.ContainsKey('WhatIf')) { [void]$list.Add('-WhatIf') }
    if ($VerbosePreference -eq 'Continue' -and -not $BoundParameters.ContainsKey('Verbose')) { [void]$list.Add('-Verbose') }
    return $list
}

if (-not (Test-Administrator)) {

    if ($NoElevate) {
        Write-Warning 'Administratorrechte fehlen und -NoElevate ist gesetzt. Abbruch.'
        exit 4
    }

    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Warning 'Das Skript wurde nicht als Datei gestartet (z. B. eingefuegter Code).'
        Write-Warning 'Bitte als .ps1 speichern und erneut starten - nur dann ist eine Rechteerhoehung moeglich.'
        exit 4
    }

    Write-Host ''
    Write-Host '  Administratorrechte erforderlich - starte neu mit Rechteerhoehung (UAC) ...' -ForegroundColor Yellow

    # Dieselbe PowerShell-Variante wieder verwenden (Windows PowerShell oder pwsh).
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch { $psExe = $null }
    if ([string]::IsNullOrWhiteSpace($psExe) -or $psExe -notmatch '(?i)(powershell|pwsh)\.exe$') {
        $exeName = 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $exeName = 'pwsh.exe' }
        $psExe = Join-Path $PSHOME $exeName
    }

    $argumentList = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))) {
        [void]$argumentList.Add($a)
    }
    foreach ($a in (Get-RelaunchArgumentList -BoundParameters $PSBoundParameters)) { [void]$argumentList.Add($a) }
    [void]$argumentList.Add('-Elevated')

    try {
        $child = Start-Process -FilePath $psExe -ArgumentList $argumentList `
            -Verb RunAs -PassThru -Wait -ErrorAction Stop
        exit $child.ExitCode
    }
    catch {
        Write-Host ''
        Write-Warning 'Rechteerhoehung abgebrochen oder fehlgeschlagen (UAC).'
        Write-Host '  Alternative: PowerShell als Administrator oeffnen und das Skript dort starten.'
        exit 5
    }
}

# --- ab hier laufen wir garantiert mit Administratorrechten ---
if ($Elevated) {
    # Aus dem Internet geladene Dateien sind markiert - Markierung entfernen,
    # damit spaetere Starts nicht an der Sicherheitswarnung haengen.
    try { Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue }
    catch { Write-Verbose 'Unblock-File nicht verfuegbar.' }
    try { $Host.UI.RawUI.WindowTitle = 'Repair.ps1 v3.0.1 - Administrator' }
    catch { Write-Verbose 'Fenstertitel nicht setzbar.' }
}

#endregion

$Script:PrevProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

#region ============================ Zustand ============================

$Script:Run = [ordered]@{
    Tool             = 'Windows Repair, Diagnose & Maintenance Tool'
    Version          = '3.0.1'
    Computer         = $env:COMPUTERNAME
    User             = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    Mode             = $Mode
    OptimizeLevel    = $Optimize
    StartTime        = Get-Date
    EndTime          = $null
    DurationSec      = 0
    PSVersion        = $PSVersionTable.PSVersion.ToString()
    OS               = $null
    Steps            = New-Object System.Collections.ArrayList
    Findings         = New-Object System.Collections.ArrayList
    FreeSpaceStartGB = $null
    FreeSpaceEndGB   = $null
    ReclaimedGB      = 0
    RestartRequired  = $false
    RestartReasons   = New-Object System.Collections.ArrayList
    Overall          = 'UNKNOWN'
    LogFile          = $null
    ReportFile       = $null
    JsonFile         = $null
    ToolLog          = $null
}

$Script:TranscriptStarted = $false
$Script:LockFile = $null
$Script:LockOwned = $false
$Script:SystemDrive = $env:SystemDrive
if ([string]::IsNullOrWhiteSpace($Script:SystemDrive)) { $Script:SystemDrive = 'C:' }

#endregion

#region ========================= Ausgabe-Helfer ========================

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    $line = '=' * 68
    Write-Host ''
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host (' ' + $Text) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
}

function Write-Info { param([string]$Text) Write-Host ('  ' + $Text) }
function Write-Ok { param([string]$Text) Write-Host ('  + ' + $Text) -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host ('  - ' + $Text) -ForegroundColor DarkGray }
function Write-Attention { param([string]$Text) Write-Host ('  ! ' + $Text) -ForegroundColor Yellow }
function Write-Problem { param([string]$Text) Write-Host ('  x ' + $Text) -ForegroundColor Red }

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'PASS' { 'Green'; break }
        'HEALTHY' { 'Green'; break }
        'OK' { 'Green'; break }
        'REPAIRED' { 'Yellow'; break }
        'REBOOT' { 'Yellow'; break }
        'WARNING' { 'Yellow'; break }
        'SKIPPED' { 'DarkGray'; break }
        'FAILED' { 'Red'; break }
        default { 'Gray' }
    }
}

function Add-Finding {
    param(
        [Parameter(Mandatory)][ValidateSet('Info', 'Warnung', 'Problem')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )
    [void]$Script:Run.Findings.Add([pscustomobject]@{ Level = $Level; Text = $Text })
    switch ($Level) {
        'Info' { Write-Note $Text }
        'Warnung' { Write-Attention $Text }
        'Problem' { Write-Problem $Text }
    }
}

function Add-RestartReason {
    param([Parameter(Mandatory)][string]$Reason)
    if (-not $Script:Run.RestartReasons.Contains($Reason)) {
        [void]$Script:Run.RestartReasons.Add($Reason)
    }
    $Script:Run.RestartRequired = $true
}

function Add-StepResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        $ExitCode = $null,
        [string]$Detail = '',
        [timespan]$Duration = [timespan]::Zero
    )
    $obj = [pscustomobject]@{
        Name        = $Name
        Status      = $Status
        ExitCode    = $ExitCode
        Detail      = $Detail
        DurationSec = [math]::Round($Duration.TotalSeconds, 1)
    }
    [void]$Script:Run.Steps.Add($obj)
    return $obj
}

# Fuehrt einen Schritt gekapselt aus: Fehler beenden niemals den Gesamtlauf,
# sie werden als FAILED erfasst. Der Scriptblock gibt eine Hashtable
# @{ Status = ...; ExitCode = ...; Detail = ... } zurueck.
function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Section $Title
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'UNKNOWN'; $exit = $null; $detail = ''
    try {
        $res = & $Action
        if ($res -is [System.Array] -and $res.Count -gt 0) { $res = $res[-1] }
        if ($res -is [hashtable] -or $res -is [System.Collections.Specialized.OrderedDictionary]) {
            if ($res.Contains('Status')) { $status = [string]$res['Status'] }
            if ($res.Contains('ExitCode')) { $exit = $res['ExitCode'] }
            if ($res.Contains('Detail')) { $detail = [string]$res['Detail'] }
        }
        elseif ($null -ne $res) {
            $status = [string]$res
        }
    }
    catch {
        $status = 'FAILED'
        $detail = $_.Exception.Message
        Write-Problem ("Schritt fehlgeschlagen: {0}" -f $_.Exception.Message)
    }
    finally {
        $sw.Stop()
    }
    $result = Add-StepResult -Name $Name -Status $status -ExitCode $exit -Detail $detail -Duration $sw.Elapsed
    Write-Host ''
    Write-Host ('  => {0}: ' -f $Name) -NoNewline
    Write-Host $status -ForegroundColor (Get-StatusColor $status) -NoNewline
    Write-Host (' ({0}s)' -f $result.DurationSec) -ForegroundColor DarkGray
    return $result
}

function Format-ByteSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

#endregion

#region ====================== System-Werkzeuge ========================

# Loest Systemtools zuverlaessig auf. Wichtig fuer 32-Bit-PowerShell auf
# 64-Bit-Windows: dort zeigt System32 auf SysWOW64 (Dateisystem-Redirection),
# dism/sfc muessen ueber Sysnative gestartet werden.
function Resolve-SystemTool {
    param([Parameter(Mandatory)][string]$Name)
    $candidates = New-Object System.Collections.ArrayList
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        [void]$candidates.Add((Join-Path $env:SystemRoot ('Sysnative\' + $Name)))
    }
    [void]$candidates.Add((Join-Path $env:SystemRoot ('System32\' + $Name)))
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw ("Systemwerkzeug '{0}' wurde nicht gefunden." -f $Name)
}

# Startet ein natives Werkzeug im aktuellen Konsolenstrom (nicht ueber
# Start-Process): nur so landet die Ausgabe auch im Transcript.
# Fortschrittsbalken werden auf 10%-Schritte eingedampft.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0),
        [ValidateSet('Default', 'Unicode')][string]$ToolEncoding = 'Default',
        [string]$RawLogFile
    )

    Write-Host ''
    Write-Host ('  > {0} {1}' -f (Split-Path $FilePath -Leaf), ($Arguments -join ' ')) -ForegroundColor DarkGray

    $prevEncoding = $null
    try { $prevEncoding = [Console]::OutputEncoding }
    catch { Write-Verbose 'Konsolen-Encoding nicht abfragbar (z. B. ISE).' }
    $writer = $null
    $lastBucket = -1
    $code = $null
    $tail = New-Object System.Collections.Generic.Queue[string]
    $all = New-Object System.Collections.Generic.List[string]
    # Wichtig: mit ErrorActionPreference 'Stop' wuerde jede stderr-Zeile eines
    # nativen Werkzeugs (chkdsk, netsh, ...) einen NativeCommandError ausloesen
    # und den Schritt abbrechen. Deshalb hier bewusst lokal herabgestuft.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        # sfc.exe schreibt UTF-16; ohne Umstellung entstehen Luecken/Steuerzeichen.
        if ($ToolEncoding -eq 'Unicode' -and $null -ne $prevEncoding) {
            try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode }
            catch { Write-Verbose 'Konsolen-Encoding nicht umstellbar.' }
        }
        if ($RawLogFile) {
            $writer = New-Object System.IO.StreamWriter($RawLogFile, $true, [System.Text.Encoding]::UTF8)
            $writer.WriteLine('')
            $writer.WriteLine(('--- {0} {1} ({2:yyyy-MM-dd HH:mm:ss}) ---' -f $FilePath, ($Arguments -join ' '), (Get-Date)))
        }

        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = ([string]$_).Replace([string][char]0, '').Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { return }

            if ($writer) { $writer.WriteLine($line) }
            $all.Add($line)
            $tail.Enqueue($line)
            while ($tail.Count -gt 15) { [void]$tail.Dequeue() }

            $pct = $null
            if ($line -match '^\s*\[[=\s]*([0-9]{1,3})(?:[\.,][0-9]+)?\s*%') { $pct = [int]$Matches[1] }
            elseif ($line -match '([0-9]{1,3})\s*%\s*(?:complete|abgeschlossen|fertig)') { $pct = [int]$Matches[1] }

            if ($null -ne $pct) {
                $bucket = [math]::Floor($pct / 10)
                if ($bucket -gt $lastBucket) {
                    $lastBucket = $bucket
                    Write-Host ('    ... {0,3} %' -f ($bucket * 10)) -ForegroundColor DarkGray
                }
                return
            }
            if ($line -match '^\s*\[[=\s\.]*\]\s*$') { return }
            Write-Host ('    ' + $line)
        }
        $code = $LASTEXITCODE
    }
    finally {
        if ($writer) { $writer.Flush(); $writer.Dispose() }
        if ($null -ne $prevEncoding) {
            try { [Console]::OutputEncoding = $prevEncoding }
            catch { Write-Verbose 'Konsolen-Encoding nicht zuruecksetzbar.' }
        }
        $ErrorActionPreference = $prevEap
    }

    $status = 'FAILED'
    if ($SuccessExitCodes -contains $code) { $status = 'PASS' }
    elseif ($code -eq 3010) { $status = 'REBOOT' }

    if ($code -eq 3010) { Add-RestartReason ('{0} meldet: Neustart erforderlich (3010)' -f (Split-Path $FilePath -Leaf)) }

    return @{
        ExitCode = $code
        Status   = $status
        Tail     = ($tail -join [Environment]::NewLine)
        Lines    = $all
    }
}

#endregion

#region ====================== Initialisierung =========================

function Initialize-Run {
    $dayDir = Join-Path $LogRoot (Get-Date -Format 'yyyyMMdd')
    if (-not (Test-Path -LiteralPath $dayDir -PathType Container)) {
        New-Item -ItemType Directory -Path $dayDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:Run.LogFile = Join-Path $dayDir ('Repair-{0}.log' -f $stamp)
    $Script:Run.ReportFile = Join-Path $dayDir ('Repair-{0}-Report.txt' -f $stamp)
    $Script:Run.JsonFile = Join-Path $dayDir ('Repair-{0}.json' -f $stamp)
    $Script:Run.ToolLog = Join-Path $dayDir ('Repair-{0}-Tools.log' -f $stamp)
    $Script:LockFile = Join-Path $LogRoot 'Repair.lock'

    if (-not $NoTranscript) {
        try {
            Start-Transcript -Path $Script:Run.LogFile -Force -ErrorAction Stop | Out-Null
            $Script:TranscriptStarted = $true
        }
        catch {
            Write-Warning ('Transcript konnte nicht gestartet werden: {0}' -f $_.Exception.Message)
            $Script:Run.LogFile = $null
        }
    }
    else {
        $Script:Run.LogFile = $null
    }
}

# Verhindert parallele Laeufe. Ein Lock gilt als verwaist, wenn der
# eingetragene Prozess nicht mehr existiert oder aelter als 12 h ist.
function Enter-RunLock {
    if (Test-Path -LiteralPath $Script:LockFile) {
        $stale = $true
        $info = $null
        try {
            $info = Get-Content -LiteralPath $Script:LockFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $owner = Get-Process -Id $info.ProcessId -ErrorAction SilentlyContinue
            $age = (Get-Date) - [datetime]$info.Started
            if ($owner -and $age.TotalHours -lt 12) { $stale = $false }
        }
        catch { $stale = $true }

        if (-not $stale -and -not $Force) {
            $who = 'unbekannt'
            if ($info) { $who = ('PID {0}, gestartet {1}' -f $info.ProcessId, $info.Started) }
            throw ("Es laeuft bereits ein Reparaturvorgang ({0}). Abbruch. Mit -Force ueberschreiben." -f $who)
        }
        if ($stale) { Write-Note 'Verwaiste Sperrdatei gefunden und uebernommen.' }
    }

    $lock = [pscustomobject]@{
        ProcessId = $PID
        Started   = (Get-Date).ToString('o')
        User      = $Script:Run.User
        Mode      = $Mode
    }
    $lock | ConvertTo-Json | Set-Content -LiteralPath $Script:LockFile -Encoding UTF8 -Force
    $Script:LockOwned = $true
}

function Exit-RunLock {
    if ($Script:LockOwned -and (Test-Path -LiteralPath $Script:LockFile)) {
        Remove-Item -LiteralPath $Script:LockFile -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region ========================== Preflight ===========================

function Get-PendingRebootReason {
    $reasons = New-Object System.Collections.ArrayList
    $checks = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Text = 'Component Based Servicing (CBS)' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Text = 'Windows Update' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'; Text = 'CBS Reboot in Arbeit' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'; Text = 'Ausstehende Pakete' }
    )
    foreach ($c in $checks) {
        if (Test-Path -LiteralPath $c.Path) { [void]$reasons.Add($c.Text) }
    }
    try {
        $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations' -and $sm.PendingFileRenameOperations) {
            [void]$reasons.Add('PendingFileRenameOperations')
        }
    }
    catch { Write-Verbose ('uebersprungen: {0}' -f $_.Exception.Message) }
    return $reasons
}

function Get-FreeSpaceGB {
    param([string]$Drive = $Script:SystemDrive)
    try {
        $letter = $Drive.TrimEnd('\').TrimEnd(':')
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letter) -ErrorAction Stop
        return [math]::Round($vol.FreeSpace / 1GB, 2)
    }
    catch { return $null }
}

function Invoke-Preflight {
    $blocking = New-Object System.Collections.ArrayList

    # --- Betriebssystem
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $Script:Run.OS = ('{0} (Build {1})' -f $os.Caption.Trim(), $os.BuildNumber)
        Add-Finding -Level Info -Text ('Betriebssystem : {0}' -f $Script:Run.OS)
        Add-Finding -Level Info -Text ('Letzter Start  : {0:yyyy-MM-dd HH:mm}' -f $os.LastBootUpTime)
        $uptime = (Get-Date) - $os.LastBootUpTime
        if ($uptime.TotalDays -gt 14) {
            Add-Finding -Level Warnung -Text ('Laufzeit seit letztem Neustart: {0:N0} Tage - ein Neustart vor der Reparatur ist empfehlenswert.' -f $uptime.TotalDays)
        }
    }
    catch {
        Add-Finding -Level Warnung -Text 'Betriebssysteminformationen konnten nicht gelesen werden.'
    }

    Add-Finding -Level Info -Text ('PowerShell     : {0} ({1}-Bit-Prozess)' -f $Script:Run.PSVersion, $(if ([Environment]::Is64BitProcess) { 64 } else { 32 }))
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Add-Finding -Level Warnung -Text '32-Bit-PowerShell auf 64-Bit-Windows erkannt - Systemtools werden ueber Sysnative aufgerufen. Besser: 64-Bit-Konsole verwenden.'
    }

    # --- Werkzeuge
    foreach ($tool in @('dism.exe', 'sfc.exe', 'chkdsk.exe', 'ipconfig.exe', 'netsh.exe')) {
        try {
            $p = Resolve-SystemTool -Name $tool
            Write-Note ('Werkzeug gefunden: {0}' -f $p)
        }
        catch {
            if ($tool -in @('dism.exe', 'sfc.exe')) { [void]$blocking.Add(('{0} fehlt' -f $tool)) }
            Add-Finding -Level Warnung -Text ('Werkzeug nicht gefunden: {0}' -f $tool)
        }
    }

    # --- Freier Speicher
    $free = Get-FreeSpaceGB
    $Script:Run.FreeSpaceStartGB = $free
    if ($null -ne $free) {
        Add-Finding -Level Info -Text ('Freier Speicher auf {0} : {1} GB' -f $Script:SystemDrive, $free)
        if ($free -lt $MinFreeSpaceGB) {
            Add-Finding -Level Warnung -Text ('Weniger als {0} GB frei - DISM/SFC koennen fehlschlagen. Die Wartungsstufe schafft ggf. Platz.' -f $MinFreeSpaceGB)
        }
    }

    # --- Bereits laufende Wartung
    $busy = Get-Process -Name 'dism', 'DismHost', 'sfc', 'TiWorker', 'TrustedInstaller', 'CompatTelRunner' -ErrorAction SilentlyContinue
    $hard = $busy | Where-Object { $_.ProcessName -in @('dism', 'sfc') }
    if ($hard) {
        [void]$blocking.Add(('Es laeuft bereits: {0}' -f (($hard | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')))
    }
    $soft = $busy | Where-Object { $_.ProcessName -in @('TiWorker', 'TrustedInstaller', 'DismHost', 'CompatTelRunner') }
    if ($soft) {
        Add-Finding -Level Warnung -Text ('Windows-Wartung aktiv ({0}) - Laufzeit kann sich deutlich verlaengern.' -f (($soft | Select-Object -ExpandProperty ProcessName -Unique) -join ', '))
    }

    # --- Ausstehender Neustart
    $pending = Get-PendingRebootReason
    if ($pending.Count -gt 0) {
        Add-Finding -Level Warnung -Text ('Es steht bereits ein Neustart aus ({0}). Reparaturen koennen dadurch unvollstaendig bleiben.' -f ($pending -join ', '))
        foreach ($r in $pending) { Add-RestartReason ('Bereits vor dem Lauf ausstehend: ' + $r) }
    }

    # --- Stromversorgung (Notebooks)
    try {
        $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bat -and $bat.BatteryStatus -eq 1) {
            Add-Finding -Level Warnung -Text ('Geraet laeuft im Akkubetrieb ({0} %). Fuer DISM/SFC bitte Netzteil anschliessen.' -f $bat.EstimatedChargeRemaining)
        }
    }
    catch { Write-Verbose ('uebersprungen: {0}' -f $_.Exception.Message) }

    if ($blocking.Count -gt 0) {
        return @{ Status = 'FAILED'; Detail = ($blocking -join '; ') }
    }
    return @{ Status = 'PASS'; Detail = ('{0} Hinweise' -f $Script:Run.Findings.Count) }
}

function New-SafetyRestorePoint {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()
    if ($NoRestorePoint) { return @{ Status = 'SKIPPED'; Detail = '-NoRestorePoint gesetzt' } }
    if (-not (Get-Command -Name Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        return @{ Status = 'SKIPPED'; Detail = 'Checkpoint-Computer nicht verfuegbar' }
    }
    try {
        $sr = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction SilentlyContinue
        if (-not $sr) {
            Add-Finding -Level Info -Text 'Systemwiederherstellung ist deaktiviert - kein Wiederherstellungspunkt moeglich.'
            return @{ Status = 'SKIPPED'; Detail = 'Systemwiederherstellung deaktiviert' }
        }
    }
    catch { Write-Verbose ('uebersprungen: {0}' -f $_.Exception.Message) }

    if (-not $PSCmdlet.ShouldProcess('System', 'Wiederherstellungspunkt erstellen')) {
        return @{ Status = 'SKIPPED'; Detail = 'WhatIf' }
    }
    try {
        Checkpoint-Computer -Description ('Repair.ps1 {0} ({1})' -f $Script:Run.Version, $Mode) `
            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Ok 'Wiederherstellungspunkt erstellt.'
        return @{ Status = 'PASS' }
    }
    catch {
        # Windows erlaubt standardmaessig nur einen Punkt pro 24 h.
        Add-Finding -Level Info -Text ('Wiederherstellungspunkt nicht erstellt: {0}' -f $_.Exception.Message)
        return @{ Status = 'WARNING'; Detail = $_.Exception.Message }
    }
}

#endregion

#region =========================== Reparatur ==========================

function Invoke-DismAction {
    param(
        [Parameter(Mandatory)][string[]]$DismArgs,
        [int[]]$SuccessExitCodes = @(0, 3010)
    )
    $dism = Resolve-SystemTool -Name 'dism.exe'
    $r = Invoke-NativeCommand -FilePath $dism -Arguments $DismArgs `
        -SuccessExitCodes $SuccessExitCodes -RawLogFile $Script:Run.ToolLog

    if ($r.Status -eq 'FAILED') {
        $hint = switch ($r.ExitCode) {
            1726 { 'RPC-Aufruf fehlgeschlagen - meist laeuft parallel eine Windows-Wartung. Spaeter erneut versuchen.'; break }
            50 { 'Der Vorgang wird in dieser Umgebung nicht unterstuetzt.'; break }
            87 { 'Ungueltiger Parameter fuer diese Windows-Version.'; break }
            2 { 'Datei nicht gefunden - Quelle fuer die Reparatur fehlt (-Source pruefen).'; break }
            default { 'Details siehe C:\Windows\Logs\DISM\dism.log' }
        }
        Add-Finding -Level Problem -Text ('DISM ExitCode {0}: {1}' -f $r.ExitCode, $hint)
        return @{ Status = 'FAILED'; ExitCode = $r.ExitCode; Detail = $hint }
    }
    return @{ Status = $r.Status; ExitCode = $r.ExitCode; Detail = ''; Lines = $r.Lines }
}

function Test-ComponentStoreHealth {
    # Schnelle, saubere Statusabfrage ueber das DISM-Modul.
    if (-not (Get-Command -Name Repair-WindowsImage -ErrorAction SilentlyContinue)) {
        return $null
    }
    try { return (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop) }
    catch { return $null }
}

function Invoke-RepairStage {
    # ---- DISM
    if ($SkipDism) {
        Add-StepResult -Name 'DISM' -Status 'SKIPPED' -Detail '-SkipDism' | Out-Null
    }
    else {
        if ($Mode -in @('Diagnose', 'Full')) {
            Invoke-Step -Name 'DISM_CheckHealth' -Title 'DISM - SCHNELLPRUEFUNG (CheckHealth)' -Action {
                Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/CheckHealth')
            } | Out-Null

            Invoke-Step -Name 'DISM_ScanHealth' -Title 'DISM - TIEFENPRUEFUNG (ScanHealth)' -Action {
                Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/ScanHealth')
            } | Out-Null
        }

        if ($Mode -in @('Repair', 'Full')) {
            # Vorabpruefung: RestoreHealth nur ausfuehren, wenn noetig -
            # das ist der groesste Zeitgewinn gegenueber der alten Version.
            $health = Test-ComponentStoreHealth
            $needRestore = $true
            if ($health -and $health.ImageHealthState -eq 'Healthy' -and $Mode -eq 'Repair') {
                $needRestore = $false
            }

            if ($needRestore) {
                Invoke-Step -Name 'DISM_RestoreHealth' -Title 'DISM - REPARATUR (RestoreHealth)' -Action {
                    Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/RestoreHealth')
                } | Out-Null
            }
            else {
                Write-Section 'DISM - REPARATUR (RestoreHealth)'
                Write-Ok 'Komponentenstore meldet "Healthy" - RestoreHealth wird uebersprungen.'
                Write-Note 'Mit -Mode Full wird die Reparatur unabhaengig davon erzwungen.'
                Add-StepResult -Name 'DISM_RestoreHealth' -Status 'SKIPPED' -Detail 'nicht erforderlich (Healthy)' | Out-Null
            }
        }
    }

    # ---- SFC
    if ($SkipSfc) {
        Add-StepResult -Name 'SFC' -Status 'SKIPPED' -Detail '-SkipSfc' | Out-Null
        return
    }

    $sfcArgs = @('/scannow')
    $title = 'SYSTEM FILE CHECKER (sfc /scannow)'
    if ($Mode -eq 'Diagnose') {
        $sfcArgs = @('/verifyonly')
        $title = 'SYSTEM FILE CHECKER (sfc /verifyonly - nur pruefen)'
    }

    Invoke-Step -Name 'SFC' -Title $title -Action {
        $sfc = Resolve-SystemTool -Name 'sfc.exe'
        # sfc.exe liefert keine verlaesslichen Exitcodes; die belastbare
        # Auswertung erfolgt spaeter ueber die CBS-Logdatei.
        $r = Invoke-NativeCommand -FilePath $sfc -Arguments $sfcArgs `
            -SuccessExitCodes @(0, 1, 2, 3) -ToolEncoding Unicode -RawLogFile $Script:Run.ToolLog
        return @{ Status = 'PASS'; ExitCode = $r.ExitCode; Detail = 'Bewertung erfolgt ueber CBS-Analyse' }
    } | Out-Null
}

#endregion

#region ======================== Verifikation ==========================

function Invoke-VerifyStage {
    Invoke-Step -Name 'ComponentStore' -Title 'VERIFIKATION - KOMPONENTENSTORE' -Action {
        $health = Test-ComponentStoreHealth
        if (-not $health) {
            return @{ Status = 'WARNING'; Detail = 'Status konnte nicht ermittelt werden' }
        }
        $state = [string]$health.ImageHealthState
        if ($state -eq 'Healthy') {
            Write-Ok 'Komponentenstore ist sauber (Healthy).'
            return @{ Status = 'PASS'; Detail = $state }
        }
        if ($state -eq 'Repairable') {
            Add-Finding -Level Warnung -Text 'Komponentenstore ist reparierbar, aber noch beschaedigt. Empfehlung: Neustart, danach -Mode Full.'
            Add-RestartReason 'Komponentenstore noch nicht sauber'
            return @{ Status = 'WARNING'; Detail = $state }
        }
        Add-Finding -Level Problem -Text ('Komponentenstore-Status: {0}. Reparatur mit Installationsquelle noetig (DISM /Source).' -f $state)
        return @{ Status = 'FAILED'; Detail = $state }
    } | Out-Null

    if ($SkipDisk -or $Mode -eq 'Quick') { return }

    Invoke-Step -Name 'Datentraeger' -Title 'VERIFIKATION - DATENTRAEGER & DATEISYSTEM' -Action {
        $worst = 'PASS'
        $details = New-Object System.Collections.ArrayList

        # SMART/Gesundheit der physischen Datentraeger
        if (Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue) {
            foreach ($d in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                $txt = ('{0} | {1} | {2:N0} GB | Health: {3} | {4}' -f $d.FriendlyName, $d.MediaType, ($d.Size / 1GB), $d.HealthStatus, $d.OperationalStatus)
                if ($d.HealthStatus -ne 'Healthy') {
                    Add-Finding -Level Problem -Text ('Datentraegerproblem: ' + $txt)
                    $worst = 'FAILED'
                }
                else { Write-Note $txt }
                [void]$details.Add($txt)
            }
        }

        # Dateisystem online pruefen (read-only, kein Reparaturlauf)
        $chk = Resolve-SystemTool -Name 'chkdsk.exe'
        $r = Invoke-NativeCommand -FilePath $chk -Arguments @($Script:SystemDrive, '/scan', '/perf') `
            -SuccessExitCodes @(0) -RawLogFile $Script:Run.ToolLog
        if ($r.ExitCode -ne 0) {
            Add-Finding -Level Warnung -Text ('chkdsk /scan meldet ExitCode {0} - Dateisystemfehler gefunden. Behebung: "chkdsk {1} /spotfix" (erfordert Neustart).' -f $r.ExitCode, $Script:SystemDrive)
            if ($worst -eq 'PASS') { $worst = 'WARNING' }
        }
        else { Write-Ok ('Dateisystem auf {0} ohne Befund.' -f $Script:SystemDrive) }

        return @{ Status = $worst; ExitCode = $r.ExitCode; Detail = ($details -join ' / ') }
    } | Out-Null
}

#endregion

#region ========================= Optimierung ==========================

# Loescht Inhalte eines Ordners mit Altersfilter und Groessenbilanz.
# Gesperrte Dateien werden still uebersprungen (voellig normal bei Temp).
function Clear-FolderContent {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$OlderThanDays = 0,
        [string]$Filter = '*',
        [string]$Label
    )
    $result = [pscustomobject]@{ Label = $Label; Path = $Path; Files = 0; Bytes = 0; Skipped = 0; Exists = $true }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Exists = $false
        return $result
    }
    $limit = (Get-Date).AddDays(-1 * $OlderThanDays)
    $items = @()
    try {
        $items = Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $limit }
    }
    catch { return $result }

    foreach ($f in $items) {
        $size = $f.Length
        if (-not $PSCmdlet.ShouldProcess($f.FullName, 'Loeschen')) { continue }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $result.Files++
            $result.Bytes += $size
        }
        catch { $result.Skipped++ }
    }

    # leere Unterordner aufraeumen
    try {
        Get-ChildItem -LiteralPath $Path -Directory -Force -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    if ($PSCmdlet.ShouldProcess($_.FullName, 'Leeren Ordner entfernen')) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
    }
    catch { Write-Verbose ('uebersprungen: {0}' -f $_.Exception.Message) }

    return $result
}

function Invoke-FileCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)

    $targets = New-Object System.Collections.ArrayList

    # --- Safe: verlustfrei, jederzeit wiederherstellbar
    [void]$targets.Add(@{ Label = 'Benutzer-Temp'; Path = $env:TEMP; Days = $TempFileAgeDays })
    [void]$targets.Add(@{ Label = 'Windows-Temp'; Path = (Join-Path $env:SystemRoot 'Temp'); Days = $TempFileAgeDays })
    [void]$targets.Add(@{ Label = 'Windows-Installer-Patch-Cache (verwaist)'; Path = (Join-Path $env:SystemRoot 'Temp\*.tmp'); Days = 7; Skip = $true })

    if ($Level -in @('Standard', 'Aggressive')) {
        [void]$targets.Add(@{ Label = 'Windows-Update-Downloadcache'; Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download'); Days = 1 })
        [void]$targets.Add(@{ Label = 'Fehlerberichte (WER Queue)'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'); Days = 1 })
        [void]$targets.Add(@{ Label = 'Fehlerberichte (WER Archive)'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Days = 1 })
        [void]$targets.Add(@{ Label = 'Archivierte CBS-Logs'; Path = (Join-Path $env:SystemRoot 'Logs\CBS'); Days = 7; Filter = 'CbsPersist_*.log' })
        [void]$targets.Add(@{ Label = 'Windows-Upgrade-Reste'; Path = (Join-Path $env:SystemRoot 'Panther\UnattendGC'); Days = 30 })
    }

    $totalBytes = 0
    $totalFiles = 0
    foreach ($t in $targets) {
        if ($t.ContainsKey('Skip') -and $t.Skip) { continue }
        $filter = '*'
        if ($t.ContainsKey('Filter')) { $filter = $t.Filter }

        $r = Clear-FolderContent -Path $t.Path -OlderThanDays $t.Days -Filter $filter -Label $t.Label
        if (-not $r.Exists) { continue }
        $totalBytes += $r.Bytes
        $totalFiles += $r.Files
        if ($r.Files -gt 0 -or $r.Skipped -gt 0) {
            Write-Info ('{0,-40} {1,6} Dateien  {2,10}{3}' -f $r.Label, $r.Files, (Format-ByteSize $r.Bytes), $(if ($r.Skipped) { ('  ({0} gesperrt)' -f $r.Skipped) } else { '' }))
        }
    }

    # --- Delivery Optimization (eigener Cache mit eigenem Cmdlet)
    if ($Level -in @('Standard', 'Aggressive') -and (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess('Delivery Optimization Cache', 'Leeren')) {
            try {
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
                Write-Info ('{0,-40} geleert' -f 'Delivery-Optimization-Cache')
            }
            catch { Write-Note ('Delivery-Optimization-Cache: {0}' -f $_.Exception.Message) }
        }
    }

    # --- Thumbnail-/Icon-Cache
    if ($Level -in @('Standard', 'Aggressive')) {
        $explorerCache = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
        $r = Clear-FolderContent -Path $explorerCache -OlderThanDays 0 -Filter 'thumbcache_*.db' -Label 'Thumbnail-Cache'
        if ($r.Files -gt 0) {
            $totalBytes += $r.Bytes; $totalFiles += $r.Files
            Write-Info ('{0,-40} {1,6} Dateien  {2,10}' -f 'Thumbnail-Cache', $r.Files, (Format-ByteSize $r.Bytes))
        }
    }

    # --- Papierkorb: echter Datenverlust -> nur aggressive Stufe
    if ($Level -eq 'Aggressive' -and (Get-Command -Name Clear-RecycleBin -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess('Papierkorb', 'Leeren')) {
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-Info ('{0,-40} geleert' -f 'Papierkorb')
            }
            catch { Write-Note ('Papierkorb: {0}' -f $_.Exception.Message) }
        }
    }

    # --- Alte eigene Logs aufraeumen
    if ($LogRetentionDays -gt 0) {
        $r = Clear-FolderContent -Path $LogRoot -OlderThanDays $LogRetentionDays -Label 'Eigene Reparaturlogs'
        if ($r.Files -gt 0) { Write-Info ('{0,-40} {1,6} Dateien  {2,10}' -f 'Eigene Reparaturlogs', $r.Files, (Format-ByteSize $r.Bytes)) }
    }

    if ($totalFiles -eq 0) {
        Write-Ok 'Keine loeschbaren Altlasten gefunden.'
    }
    else {
        Write-Ok ('{0} Dateien entfernt, {1} freigegeben.' -f $totalFiles, (Format-ByteSize $totalBytes))
    }
    return @{ Status = 'PASS'; Detail = ('{0} Dateien / {1}' -f $totalFiles, (Format-ByteSize $totalBytes)) }
}

function Invoke-ComponentStoreMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)

    # Analyse ist billig und sagt, ob eine Bereinigung ueberhaupt lohnt.
    $analyze = Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -SuccessExitCodes @(0, 3010)
    $recommended = $false
    if ($analyze.ContainsKey('Lines') -and $analyze.Lines) {
        foreach ($l in $analyze.Lines) {
            if ($l -match 'Component Store Cleanup Recommended\s*:\s*(Yes|Ja)') { $recommended = $true }
            if ($l -match 'Bereinigung des Komponentenspeichers empfohlen\s*:\s*Ja') { $recommended = $true }
        }
    }

    if ($Level -eq 'Safe') {
        Write-Note ('Bereinigung empfohlen: {0}  (Stufe "Safe" analysiert nur)' -f $(if ($recommended) { 'ja' } else { 'nein' }))
        if ($recommended) {
            Add-Finding -Level Info -Text 'WinSxS-Bereinigung waere sinnvoll - mit -Optimize Standard ausfuehren.'
        }
        return @{ Status = 'PASS'; Detail = ('Analyse; Bereinigung empfohlen = {0}' -f $recommended) }
    }

    if (-not $recommended -and $Level -ne 'Aggressive') {
        Write-Ok 'Keine WinSxS-Bereinigung noetig - uebersprungen.'
        return @{ Status = 'SKIPPED'; Detail = 'nicht empfohlen' }
    }

    $cleanupArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    $what = 'WinSxS bereinigen (StartComponentCleanup)'
    if ($Level -eq 'Aggressive') {
        $cleanupArgs += '/ResetBase'
        $what = 'WinSxS bereinigen inkl. /ResetBase'
        Add-Finding -Level Warnung -Text '/ResetBase: bereits installierte Windows-Updates lassen sich danach nicht mehr einzeln deinstallieren.'
    }

    if (-not $PSCmdlet.ShouldProcess('Komponentenstore (WinSxS)', $what)) {
        return @{ Status = 'SKIPPED'; Detail = 'WhatIf' }
    }
    return Invoke-DismAction -DismArgs $cleanupArgs -SuccessExitCodes @(0, 3010)
}

function Invoke-StorageMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)

    if (-not (Get-Command -Name Optimize-Volume -ErrorAction SilentlyContinue)) {
        return @{ Status = 'SKIPPED'; Detail = 'Optimize-Volume nicht verfuegbar' }
    }

    $volumes = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -in @('NTFS', 'ReFS') }
    if (-not $volumes) { return @{ Status = 'SKIPPED'; Detail = 'keine passenden Volumes' } }

    $done = New-Object System.Collections.ArrayList
    foreach ($v in $volumes) {
        $media = 'Unspecified'
        try {
            $disk = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop
            $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$disk.Number }
            if ($phys) { $media = [string]$phys.MediaType }
        }
        catch { Write-Verbose ('uebersprungen: {0}' -f $_.Exception.Message) }

        if ($Level -eq 'Safe') {
            try {
                Optimize-Volume -DriveLetter $v.DriveLetter -Analyze -Verbose:$false -ErrorAction Stop | Out-Null
                Write-Note ('{0}: Analyse durchgefuehrt ({1})' -f $v.DriveLetter, $media)
            }
            catch { Write-Note ('{0}: Analyse nicht moeglich ({1})' -f $v.DriveLetter, $_.Exception.Message) }
            continue
        }

        if ($media -eq 'SSD') {
            if ($PSCmdlet.ShouldProcess(('Laufwerk ' + $v.DriveLetter), 'TRIM (ReTrim)')) {
                try {
                    Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -Verbose:$false -ErrorAction Stop
                    Write-Ok ('{0}: TRIM ausgefuehrt (SSD).' -f $v.DriveLetter)
                    [void]$done.Add(('{0}=TRIM' -f $v.DriveLetter))
                }
                catch { Write-Note ('{0}: TRIM fehlgeschlagen ({1})' -f $v.DriveLetter, $_.Exception.Message) }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess(('Laufwerk ' + $v.DriveLetter), 'Defragmentieren')) {
                try {
                    Optimize-Volume -DriveLetter $v.DriveLetter -Defrag -Verbose:$false -ErrorAction Stop
                    Write-Ok ('{0}: defragmentiert ({1}).' -f $v.DriveLetter, $media)
                    [void]$done.Add(('{0}=Defrag' -f $v.DriveLetter))
                }
                catch { Write-Note ('{0}: Defrag fehlgeschlagen ({1})' -f $v.DriveLetter, $_.Exception.Message) }
            }
        }
    }
    return @{ Status = 'PASS'; Detail = ($done -join ', ') }
}

function Invoke-NetworkMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)

    $ipconfig = Resolve-SystemTool -Name 'ipconfig.exe'
    if ($PSCmdlet.ShouldProcess('DNS-Cache', 'Leeren')) {
        Invoke-NativeCommand -FilePath $ipconfig -Arguments @('/flushdns') -SuccessExitCodes @(0) -RawLogFile $Script:Run.ToolLog | Out-Null
    }

    if ($Level -ne 'Aggressive') { return @{ Status = 'PASS'; Detail = 'DNS-Cache geleert' } }

    $netsh = Resolve-SystemTool -Name 'netsh.exe'
    if ($PSCmdlet.ShouldProcess('Netzwerkstack', 'Winsock- und IP-Reset')) {
        Invoke-NativeCommand -FilePath $netsh -Arguments @('winsock', 'reset') -SuccessExitCodes @(0) -RawLogFile $Script:Run.ToolLog | Out-Null
        Invoke-NativeCommand -FilePath $netsh -Arguments @('int', 'ip', 'reset') -SuccessExitCodes @(0) -RawLogFile $Script:Run.ToolLog | Out-Null
        Add-RestartReason 'Winsock-/IP-Reset durchgefuehrt'
        Add-Finding -Level Warnung -Text 'Netzwerkstack zurueckgesetzt - VPN-Clients und virtuelle Adapter muessen ggf. neu konfiguriert werden.'
    }
    return @{ Status = 'PASS'; Detail = 'DNS + Winsock/IP zurueckgesetzt' }
}

function Reset-WindowsUpdateComponent {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()
    $services = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    if (-not $PSCmdlet.ShouldProcess('Windows-Update-Komponenten', 'Zuruecksetzen')) {
        return @{ Status = 'SKIPPED'; Detail = 'WhatIf' }
    }
    $stopped = New-Object System.Collections.ArrayList
    foreach ($s in $services) {
        try {
            $svc = Get-Service -Name $s -ErrorAction Stop
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $s -Force -ErrorAction Stop
                [void]$stopped.Add($s)
            }
        }
        catch { Write-Note ('Dienst {0}: {1}' -f $s, $_.Exception.Message) }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($pair in @(
            @{ Path = (Join-Path $env:SystemRoot 'SoftwareDistribution'); New = ('SoftwareDistribution.old-' + $stamp) },
            @{ Path = (Join-Path $env:SystemRoot 'System32\catroot2'); New = ('catroot2.old-' + $stamp) }
        )) {
        if (Test-Path -LiteralPath $pair.Path) {
            try {
                Rename-Item -LiteralPath $pair.Path -NewName $pair.New -Force -ErrorAction Stop
                Write-Ok ('{0} umbenannt -> {1}' -f (Split-Path $pair.Path -Leaf), $pair.New)
            }
            catch { Write-Note ('{0} konnte nicht umbenannt werden: {1}' -f $pair.Path, $_.Exception.Message) }
        }
    }

    foreach ($s in $stopped) {
        try { Start-Service -Name $s -ErrorAction Stop }
        catch { Write-Note ('Dienst {0} konnte nicht gestartet werden: {1}' -f $s, $_.Exception.Message) }
    }
    Add-RestartReason 'Windows-Update-Komponenten zurueckgesetzt'
    Add-Finding -Level Info -Text 'Die umbenannten Ordner (.old-*) koennen nach erfolgreichem Update-Lauf geloescht werden.'
    return @{ Status = 'PASS'; Detail = 'SoftwareDistribution + catroot2 zurueckgesetzt' }
}

# Reine Bestandsaufnahme - es wird bewusst nichts automatisch deaktiviert.
function Get-StartupReport {
    $items = New-Object System.Collections.ArrayList
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                [void]$items.Add([pscustomobject]@{ Quelle = 'Registry'; Name = $p.Name; Ziel = [string]$p.Value })
            }
        }
        catch { Write-Verbose ('uebersprungen: {0}' -f $_.Exception.Message) }
    }
    foreach ($folder in @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
        )) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            [void]$items.Add([pscustomobject]@{ Quelle = 'Autostart-Ordner'; Name = $_.Name; Ziel = $_.FullName })
        }
    }

    if ($items.Count -eq 0) {
        Write-Ok 'Keine klassischen Autostart-Eintraege gefunden.'
    }
    else {
        Write-Info ('{0} Autostart-Eintraege gefunden:' -f $items.Count)
        foreach ($i in ($items | Select-Object -First 25)) {
            Write-Note ('{0,-18} {1}' -f $i.Quelle, $i.Name)
        }
        if ($items.Count -gt 25) { Write-Note ('... und {0} weitere (siehe Report)' -f ($items.Count - 25)) }
        Add-Finding -Level Info -Text ('Autostart-Eintraege: {0}. Bewusst nicht automatisch deaktiviert - Entscheidung liegt bei dir.' -f $items.Count)
    }
    return @{ Status = 'PASS'; Detail = ('{0} Eintraege' -f $items.Count); Items = $items }
}

function Invoke-OptimizeStage {
    param([Parameter(Mandatory)][string]$Level)

    if ($Level -eq 'None') {
        Add-StepResult -Name 'Wartung' -Status 'SKIPPED' -Detail '-Optimize None' | Out-Null
        return
    }

    Write-Section ('WARTUNG & OPTIMIERUNG - STUFE: ' + $Level.ToUpper())
    Write-Note 'Bereinigt und wartet. Es werden keine Tweaks, Dienste oder Registry-Werte "optimiert".'

    Invoke-Step -Name 'OPT_Bereinigung' -Title 'WARTUNG - DATEISYSTEM-BEREINIGUNG' -Action {
        Invoke-FileCleanup -Level $Level
    } | Out-Null

    Invoke-Step -Name 'OPT_Komponentenstore' -Title 'WARTUNG - KOMPONENTENSTORE (WinSxS)' -Action {
        Invoke-ComponentStoreMaintenance -Level $Level
    } | Out-Null

    Invoke-Step -Name 'OPT_Datentraeger' -Title 'WARTUNG - TRIM / DEFRAGMENTIERUNG' -Action {
        if ($SkipDisk) { return @{ Status = 'SKIPPED'; Detail = '-SkipDisk' } }
        Invoke-StorageMaintenance -Level $Level
    } | Out-Null

    Invoke-Step -Name 'OPT_Netzwerk' -Title 'WARTUNG - NETZWERK' -Action {
        Invoke-NetworkMaintenance -Level $Level
    } | Out-Null

    if ($Level -eq 'Aggressive') {
        Invoke-Step -Name 'OPT_WindowsUpdate' -Title 'WARTUNG - WINDOWS-UPDATE-KOMPONENTEN ZURUECKSETZEN' -Action {
            Reset-WindowsUpdateComponent
        } | Out-Null
    }

    Invoke-Step -Name 'OPT_Autostart' -Title 'WARTUNG - AUTOSTART-BESTANDSAUFNAHME (nur Bericht)' -Action {
        Get-StartupReport
    } | Out-Null
}

#endregion

#region ========================== Auswertung ==========================

# Liest CBS.log auch dann, wenn Windows die Datei offen haelt, und wertet
# ausschliesslich die [SR]-Zeilen des aktuellen Laufs aus.
function Get-CbsSfcSummary {
    param([Parameter(Mandatory)][datetime]$Since)

    $cbs = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    $summary = [pscustomobject]@{
        Available    = $false
        Repaired     = 0
        CannotRepair = 0
        Corrupt      = 0
        TotalSrLines = 0
        Lines        = (New-Object System.Collections.ArrayList)
    }
    if (-not (Test-Path -LiteralPath $cbs)) { return $summary }

    $stream = $null; $reader = $null
    try {
        $stream = New-Object System.IO.FileStream($cbs, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream)
        $summary.Available = $true

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line -notmatch '\[SR\]') { continue }
            if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $ts = [datetime]::MinValue
                if ([datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss',
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::None, [ref]$ts)) {
                    if ($ts -lt $Since) { continue }
                }
            }
            $summary.TotalSrLines++
            if ($line -match 'Cannot repair member file|Reparaturelement kann nicht') { $summary.CannotRepair++ }
            elseif ($line -match 'Repaired file|Repairing corrupted file|Datei wurde repariert') { $summary.Repaired++ }
            elseif ($line -match 'is corrupt|beschaedigt|Hashes for file member .* do not match') { $summary.Corrupt++ }
            else { continue }
            if ($summary.Lines.Count -lt 400) { [void]$summary.Lines.Add($line) }
        }
    }
    catch {
        Write-Note ('CBS.log konnte nicht vollstaendig gelesen werden: {0}' -f $_.Exception.Message)
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    return $summary
}

function Get-SfcOutcome {
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [Parameter(Mandatory)][string]$SfcStepName,
        [Parameter(Mandatory)][string]$ExportTag
    )
    $sum = Get-CbsSfcSummary -Since $Since
    if (-not $sum.Available) {
        return @{ Status = 'WARNING'; Detail = 'CBS.log nicht lesbar' }
    }
    Write-Info ('Relevante [SR]-Eintraege dieses Durchlaufs : {0}' -f $sum.TotalSrLines)
    Write-Info ('Repariert                                 : {0}' -f $sum.Repaired)
    Write-Info ('Nicht reparierbar                         : {0}' -f $sum.CannotRepair)
    Write-Info ('Als beschaedigt erkannt                   : {0}' -f $sum.Corrupt)

    if ($sum.Lines.Count -gt 0) {
        $out = Join-Path (Split-Path $Script:Run.ReportFile -Parent) `
            ('Repair-{0:yyyyMMdd-HHmmss}-CBS-{1}.txt' -f $Script:Run.StartTime, $ExportTag)
        $sum.Lines | Set-Content -LiteralPath $out -Encoding UTF8
        Write-Note ('Details exportiert: {0}' -f $out)
    }

    # Das belastbare SFC-Ergebnis steht in CBS.log, nicht im Exitcode.
    $sfcStep = $Script:Run.Steps | Where-Object { $_.Name -eq $SfcStepName } | Select-Object -First 1
    if ($sum.CannotRepair -gt 0) {
        Add-Finding -Level Problem -Text ('SFC konnte {0} Datei(en) nicht reparieren.' -f $sum.CannotRepair)
        if ($sfcStep) { $sfcStep.Status = 'FAILED'; $sfcStep.Detail = ('{0} Datei(en) nicht reparierbar' -f $sum.CannotRepair) }
        return @{ Status = 'FAILED'; Detail = ('{0} nicht reparierbar' -f $sum.CannotRepair) }
    }
    if ($sum.Repaired -gt 0) {
        Add-Finding -Level Warnung -Text ('SFC hat {0} Datei(en) repariert - Neustart erforderlich, danach Gegenprobe.' -f $sum.Repaired)
        Add-RestartReason 'SFC hat Systemdateien repariert'
        if ($sfcStep) { $sfcStep.Status = 'REPAIRED'; $sfcStep.Detail = ('{0} Datei(en) repariert' -f $sum.Repaired) }
        return @{ Status = 'REPAIRED'; Detail = ('{0} repariert' -f $sum.Repaired) }
    }
    Write-Ok 'Keine Integritaetsverletzungen in diesem Durchlauf.'
    if ($sfcStep -and $sfcStep.Status -eq 'PASS') { $sfcStep.Detail = 'keine Integritaetsverletzungen' }
    return @{ Status = 'PASS'; Detail = 'keine Verletzungen' }
}

function Invoke-AnalyzeStage {
    if ($SkipSfc) { return }
    Invoke-Step -Name 'CBS_Analyse' -Title 'AUSWERTUNG - CBS-PROTOKOLL (SFC-Ergebnis)' -Action {
        Get-SfcOutcome -Since $Script:Run.StartTime -SfcStepName 'SFC' -ExportTag 'SFC'
    } | Out-Null
}

# Wenn SFC Dateien nicht reparieren konnte, sind meist die Quelldateien im
# Komponentenstore selbst defekt. Genau dann - und nur dann - lohnt der
# zweite Anlauf: DISM /RestoreHealth, danach SFC erneut.
function Invoke-EscalationStage {
    if ($NoEscalate) { return }
    if ($Mode -notin @('Repair', 'Full')) { return }
    if ($SkipDism -or $SkipSfc) { return }

    $cbsStep = $Script:Run.Steps | Where-Object { $_.Name -eq 'CBS_Analyse' } | Select-Object -First 1
    if (-not $cbsStep -or $cbsStep.Status -ne 'FAILED') { return }

    Write-Section 'ESKALATION - SFC KONNTE NICHT ALLES REPARIEREN'
    Write-Info 'Vermutlich sind die Quelldateien im Komponentenstore defekt.'
    Write-Info 'Automatischer zweiter Anlauf: DISM /RestoreHealth, danach SFC erneut.'
    Write-Note 'Abschaltbar mit -NoEscalate.'
    $since = Get-Date

    $dism = Invoke-Step -Name 'DISM_RestoreHealth_2' -Title 'ESKALATION - DISM /RestoreHealth' -Action {
        Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/RestoreHealth')
    }
    if ($dism.Status -eq 'FAILED') {
        Add-Finding -Level Problem -Text 'Eskalation gestoppt: DISM konnte den Komponentenstore nicht reparieren. Jetzt ist eine Installationsquelle noetig (/Source).'
        return
    }

    Invoke-Step -Name 'SFC_2' -Title 'ESKALATION - SFC /scannow (2. Durchlauf)' -Action {
        $sfc = Resolve-SystemTool -Name 'sfc.exe'
        $r = Invoke-NativeCommand -FilePath $sfc -Arguments @('/scannow') `
            -SuccessExitCodes @(0, 1, 2, 3) -ToolEncoding Unicode -RawLogFile $Script:Run.ToolLog
        return @{ Status = 'PASS'; ExitCode = $r.ExitCode; Detail = 'Bewertung ueber CBS-Analyse' }
    } | Out-Null

    $second = Invoke-Step -Name 'CBS_Analyse_2' -Title 'ESKALATION - CBS-AUSWERTUNG (2. Durchlauf)' -Action {
        Get-SfcOutcome -Since $since -SfcStepName 'SFC_2' -ExportTag 'SFC2'
    }

    if ($second.Status -in @('PASS', 'REPAIRED')) {
        # Der erste Durchlauf ist damit ueberholt - Gesamtstatus darf nicht
        # wegen eines inzwischen behobenen Befunds auf FAILED haengen bleiben.
        foreach ($name in @('SFC', 'CBS_Analyse')) {
            $st = $Script:Run.Steps | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($st -and $st.Status -eq 'FAILED') {
                $st.Status = 'WARNING'
                $st.Detail = ($st.Detail + ' (im 2. Durchlauf behoben)').Trim()
            }
        }
        Add-RestartReason 'Reparatur ueber zweiten Durchlauf abgeschlossen'
        Write-Ok 'Eskalation erfolgreich: der zweite Durchlauf meldet keine unreparierbaren Dateien mehr.'
    }
}

#endregion

#region ============================ Report ============================

function Get-OverallStatus {
    $s = $Script:Run.Steps
    if ($s | Where-Object { $_.Status -eq 'FAILED' }) { return 'FAILED' }
    if ($s | Where-Object { $_.Status -in @('REPAIRED', 'REBOOT') }) { return 'REPAIRED' }
    if ($Script:Run.RestartRequired) { return 'REPAIRED' }
    if ($s | Where-Object { $_.Status -eq 'WARNING' }) { return 'WARNING' }
    return 'HEALTHY'
}

function Write-FinalReport {
    $Script:Run.EndTime = Get-Date
    $Script:Run.DurationSec = [math]::Round(($Script:Run.EndTime - $Script:Run.StartTime).TotalSeconds, 0)
    $Script:Run.FreeSpaceEndGB = Get-FreeSpaceGB
    if ($null -ne $Script:Run.FreeSpaceStartGB -and $null -ne $Script:Run.FreeSpaceEndGB) {
        $Script:Run.ReclaimedGB = [math]::Round($Script:Run.FreeSpaceEndGB - $Script:Run.FreeSpaceStartGB, 2)
    }
    $Script:Run.Overall = Get-OverallStatus

    $sb = New-Object System.Text.StringBuilder
    function Add-Line {
        param([string]$Text = '')
        [void]$sb.AppendLine($Text)
    }

    Add-Line ('=' * 68)
    Add-Line ' ERGEBNIS'
    Add-Line ('=' * 68)
    Add-Line ('Computer        : {0}' -f $Script:Run.Computer)
    Add-Line ('Betriebssystem  : {0}' -f $Script:Run.OS)
    Add-Line ('Modus           : {0}   Wartungsstufe: {1}' -f $Script:Run.Mode, $Script:Run.OptimizeLevel)
    Add-Line ('Start / Ende    : {0:HH:mm:ss} - {1:HH:mm:ss}  ({2}s)' -f $Script:Run.StartTime, $Script:Run.EndTime, $Script:Run.DurationSec)
    Add-Line ''
    Add-Line ('{0,-26} {1,-10} {2,8}  {3}' -f 'Schritt', 'Status', 'Dauer(s)', 'Detail')
    Add-Line ('-' * 68)
    foreach ($s in $Script:Run.Steps) {
        Add-Line ('{0,-26} {1,-10} {2,8}  {3}' -f $s.Name, $s.Status, $s.DurationSec, $s.Detail)
    }
    Add-Line ('-' * 68)
    Add-Line ('Gesamtstatus    : {0}' -f $Script:Run.Overall)
    Add-Line ('Neustart noetig : {0}' -f $(if ($Script:Run.RestartRequired) { 'JA' } else { 'nein' }))
    foreach ($r in $Script:Run.RestartReasons) { Add-Line ('                  - {0}' -f $r) }
    if ($null -ne $Script:Run.FreeSpaceEndGB) {
        Add-Line ('Freier Speicher : {0} GB  (Differenz: {1:+0.00;-0.00;0} GB)' -f $Script:Run.FreeSpaceEndGB, $Script:Run.ReclaimedGB)
    }
    Add-Line ''
    if ($Script:Run.Findings.Count -gt 0) {
        Add-Line 'Hinweise:'
        foreach ($f in $Script:Run.Findings) { Add-Line ('  [{0,-7}] {1}' -f $f.Level, $f.Text) }
        Add-Line ''
    }

    Add-Line 'Empfohlene naechste Schritte:'
    switch ($Script:Run.Overall) {
        'HEALTHY' {
            Add-Line '  System ist integer. Kein Handlungsbedarf, kein Neustart noetig.'
            break
        }
        'REPAIRED' {
            Add-Line '  1. Windows neu starten.'
            Add-Line '  2. Danach: .\Repair.ps1 -Mode Diagnose   (Gegenprobe, veraendert nichts)'
            break
        }
        'WARNING' {
            Add-Line '  1. Hinweise oben pruefen.'
            Add-Line '  2. Bei Dateisystemhinweisen: chkdsk /spotfix, dann Neustart.'
            break
        }
        'FAILED' {
            Add-Line '  1. Windows neu starten und .\Repair.ps1 -Mode Full erneut ausfuehren.'
            Add-Line '  2. Bleibt es dabei, mit Installationsquelle reparieren:'
            Add-Line '     DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:1 /LimitAccess'
            Add-Line '  3. Logs pruefen: C:\Windows\Logs\CBS\CBS.log und C:\Windows\Logs\DISM\dism.log'
            break
        }
    }
    Add-Line ''
    if ($Script:Run.LogFile) { Add-Line ('Transcript : {0}' -f $Script:Run.LogFile) }
    Add-Line ('Report     : {0}' -f $Script:Run.ReportFile)
    Add-Line ('Werkzeuge  : {0}' -f $Script:Run.ToolLog)
    Add-Line ('JSON       : {0}' -f $Script:Run.JsonFile)

    $text = $sb.ToString()

    Write-Host ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^Gesamtstatus') {
            Write-Host $line -ForegroundColor (Get-StatusColor $Script:Run.Overall)
        }
        elseif ($line -match '^\s*\[Problem') { Write-Host $line -ForegroundColor Red }
        elseif ($line -match '^\s*\[Warnung') { Write-Host $line -ForegroundColor Yellow }
        else { Write-Host $line }
    }

    try {
        $text | Set-Content -LiteralPath $Script:Run.ReportFile -Encoding UTF8
        $Script:Run.Steps = @($Script:Run.Steps)
        $Script:Run.Findings = @($Script:Run.Findings)
        $Script:Run.RestartReasons = @($Script:Run.RestartReasons)
        ([pscustomobject]$Script:Run) | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $Script:Run.JsonFile -Encoding UTF8
    }
    catch {
        Write-Warning ('Report konnte nicht geschrieben werden: {0}' -f $_.Exception.Message)
    }
}

#endregion

#region =========================== Ablauf =============================

$exitCode = 0
try {
    Initialize-Run

    Write-Section ('{0} v{1}' -f $Script:Run.Tool, $Script:Run.Version)
    Write-Info ('Modus: {0}    Wartungsstufe: {1}' -f $Mode, $Optimize)
    if ($WhatIfPreference) { Write-Attention 'SIMULATION (-WhatIf): es werden keine Aenderungen vorgenommen.' }

    if ($Mode -eq 'Diagnose' -and $Optimize -ne 'None') {
        Write-Attention 'Diagnosemodus ist strikt lesend - die Wartungsstufe wird auf "None" gesetzt.'
        $Optimize = 'None'
        $Script:Run.OptimizeLevel = 'None'
    }

    Enter-RunLock

    $pre = Invoke-Step -Name 'Preflight' -Title 'PREFLIGHT - UMGEBUNGSPRUEFUNG' -Action { Invoke-Preflight }
    if ($pre.Status -eq 'FAILED') {
        Write-Problem 'Preflight blockiert die Ausfuehrung. Es wurden keine Aenderungen vorgenommen.'
    }
    else {
        $changesPlanned = ($Mode -ne 'Diagnose') -and (-not $WhatIfPreference)
        if ($changesPlanned -and ($Optimize -in @('Standard', 'Aggressive'))) {
            Invoke-Step -Name 'Wiederherstellungspunkt' -Title 'SICHERHEIT - WIEDERHERSTELLUNGSPUNKT' -Action {
                New-SafetyRestorePoint
            } | Out-Null
        }

        Invoke-RepairStage
        Invoke-AnalyzeStage
        Invoke-EscalationStage
        Invoke-VerifyStage
        Invoke-OptimizeStage -Level $Optimize
    }
}
catch {
    Write-Problem ('Unerwarteter Fehler: {0}' -f $_.Exception.Message)
    Add-StepResult -Name 'Laufzeitfehler' -Status 'FAILED' -Detail $_.Exception.Message | Out-Null
}
finally {
    try { Write-FinalReport }
    catch { Write-Warning ('Abschlussbericht fehlgeschlagen: {0}' -f $_.Exception.Message) }

    Exit-RunLock
    $ProgressPreference = $Script:PrevProgress

    if ($Script:TranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose ('Transcript bereits beendet: {0}' -f $_.Exception.Message) }
    }

    # Kein switch/break an dieser Stelle: Windows PowerShell 5.1 verbietet
    # jede Ablaufsteuerung, die einen finally-Block verlassen koennte
    # (ParserError 'ControlLeavingFinally').
    if ($Script:Run.Overall -eq 'HEALTHY') { $exitCode = 0 }
    elseif ($Script:Run.Overall -eq 'REPAIRED') { $exitCode = 1 }
    elseif ($Script:Run.Overall -eq 'WARNING') { $exitCode = 2 }
    elseif ($Script:Run.Overall -eq 'FAILED') { $exitCode = 3 }
    else { $exitCode = 2 }
}

if ($Elevated -and [Environment]::UserInteractive) {
    try {
        Write-Host ''
        Write-Host '  Fenster bleibt offen - zum Schliessen Enter druecken.' -ForegroundColor DarkGray
        [void](Read-Host)
    }
    catch { Write-Verbose 'Keine interaktive Eingabe moeglich.' }
}

exit $exitCode

#endregion
