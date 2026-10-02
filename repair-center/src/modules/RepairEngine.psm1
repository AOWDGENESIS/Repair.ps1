#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - RepairEngine
 Version: 1.5.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 Kern der Reparatur-, Diagnose- und Wartungslogik.
 100 % lokal - keine Cloud, keine Telemetrie, keine Fremdmodule.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
 Die Engine ist oberflaechenunabhaengig: Fortschritt, Protokoll und
 Ergebnis werden ueber einen Zustand (state.json) veroeffentlicht.
 CLI, Web-Backend und Tests nutzen exakt denselben Code.
=========================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:State = $null
$script:StatePath = $null
$script:LastFlush = [datetime]::MinValue
$script:Demo = $false
$script:DemoScenario = 'Repaired'
$script:DemoPass = 0
$script:ToolLog = $null
$script:CancelFile = $null

$script:IsWindowsHost = $true
if ($null -ne $env:OS) { $script:IsWindowsHost = ($env:OS -eq 'Windows_NT') }
else { $script:IsWindowsHost = $false }

#region ============================ Zustand ============================

function New-RunIdentifier {
    <#
    .SYNOPSIS
        Eindeutige Kennung fuer einen Reparaturlauf.
    .DESCRIPTION
        Wie bei den Datentraegerauftraegen: der Zeitstempel allein reicht
        nicht, zwei Laeufe in derselben Sekunde wuerden sich dasselbe
        Verzeichnis teilen und ihre Zustandsdateien gegenseitig ueberschreiben.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Erzeugt nur eine Zeichenkette.')]
    param()
    return ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
}

function New-RepairState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Erzeugt nur ein Objekt im Speicher.')]
    param(
        [string]$RunId,
        [string]$Mode,
        [string]$Optimize,
        [bool]$WhatIfMode,
        [bool]$Demo
    )
    return [ordered]@{
        schema           = 1
        runId            = $RunId
        tool             = 'RepairCenter'
        version          = '1.5.1'
        mode             = $Mode
        optimize         = $Optimize
        whatIf           = $WhatIfMode
        demo             = $Demo
        demoScenario     = $null
        computer         = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName })
        os               = $null
        psVersion        = $PSVersionTable.PSVersion.ToString()
        status           = 'running'
        cancelled        = $false
        overall          = 'UNKNOWN'
        startTime        = (Get-Date).ToString('o')
        endTime          = $null
        durationSec      = 0
        progress         = 0
        currentStep      = ''
        steps            = @()
        findings         = @()
        restartRequired  = $false
        restartReasons   = @()
        freeSpaceStartGB = $null
        freeSpaceEndGB   = $null
        reclaimedGB      = 0
        log              = @()
        reportFile       = $null
        jsonFile         = $null
        exitCode         = $null
    }
}

function Save-RepairState {
    param([switch]$Force)
    if (-not $script:StatePath -or -not $script:State) { return }
    $now = Get-Date
    if (-not $Force -and ($now - $script:LastFlush).TotalMilliseconds -lt 400) { return }
    $script:LastFlush = $now
    try {
        $json = ([pscustomobject]$script:State) | ConvertTo-Json -Depth 6
        # Niemals eine leere Datei ueber eine gute schreiben.
        if ([string]::IsNullOrWhiteSpace($json) -or $json.Trim().Length -lt 5) { return }
        $tmp = $script:StatePath + '.tmp'
        # -WhatIf:$false ist hier Absicht: Zustand, Bericht und Protokolle
        # sind Buchfuehrung, keine Aenderung am System. Ohne diese Ausnahme
        # schreibt ein Lauf mit "Nur simulieren" gar nichts - die Oberflaeche
        # stand dann ewig auf 0 Prozent.
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force -WhatIf:$false
        Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force -WhatIf:$false
    }
    catch { Write-Verbose ('Zustand nicht speicherbar: {0}' -f $_.Exception.Message) }
}

function Write-EngineLog {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('info', 'ok', 'warn', 'error', 'section', 'tool')][string]$Kind = 'info'
    )
    $entry = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss'); kind = $Kind; text = $Text }
    if ($script:State) {
        $list = @($script:State.log)
        $list += , $entry
        if ($list.Count -gt 2000) { $list = $list[($list.Count - 2000)..($list.Count - 1)] }
        $script:State.log = $list
        Save-RepairState
    }
    $color = 'Gray'
    if ($Kind -eq 'ok') { $color = 'Green' }
    elseif ($Kind -eq 'warn') { $color = 'Yellow' }
    elseif ($Kind -eq 'error') { $color = 'Red' }
    elseif ($Kind -eq 'section') { $color = 'Cyan' }
    elseif ($Kind -eq 'tool') { $color = 'DarkGray' }
    if ($Kind -eq 'section') {
        Write-Host ''
        Write-Host ('=== {0} ' -f $Text).PadRight(68, '=') -ForegroundColor $color
    }
    else {
        Write-Host ('  ' + $Text) -ForegroundColor $color
    }
}

function Add-EngineFinding {
    param(
        [Parameter(Mandatory)][ValidateSet('info', 'warn', 'error')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )
    $script:State.findings = @($script:State.findings) + , ([ordered]@{ level = $Level; text = $Text })
    $kind = 'info'
    if ($Level -eq 'warn') { $kind = 'warn' }
    elseif ($Level -eq 'error') { $kind = 'error' }
    Write-EngineLog -Kind $kind -Text $Text
}

function Add-EngineRestartReason {
    param([Parameter(Mandatory)][string]$Reason)
    if (@($script:State.restartReasons) -notcontains $Reason) {
        $script:State.restartReasons = @($script:State.restartReasons) + $Reason
    }
    $script:State.restartRequired = $true
}

function Set-EngineProgress {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Schreibt nur den Fortschritt in die Zustandsdatei.')]
    param([int]$Percent, [string]$StepName)
    if ($Percent -ge 0) { $script:State.progress = [math]::Min(100, $Percent) }
    if ($StepName) { $script:State.currentStep = $StepName }
    Save-RepairState
}

function Test-EngineCancelled {
    if ($script:CancelFile -and (Test-Path -LiteralPath $script:CancelFile)) { return $true }
    return $false
}

#endregion

#region ========================= Schritt-Rahmen ========================

function Add-EngineStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        $ExitCode = $null,
        [string]$Detail = '',
        [double]$DurationSec = 0
    )
    $step = [ordered]@{
        name        = $Name
        status      = $Status
        exitCode    = $ExitCode
        detail      = $Detail
        durationSec = [math]::Round($DurationSec, 1)
    }
    $script:State.steps = @($script:State.steps) + , $step
    Save-RepairState -Force
    return $step
}

# Kapselt einen Schritt: ein Fehler beendet nie den Gesamtlauf.
function Invoke-EngineStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$Progress = -1
    )
    Write-EngineLog -Kind section -Text $Title
    Set-EngineProgress -Percent $Progress -StepName $Name
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
        elseif ($null -ne $res) { $status = [string]$res }
    }
    catch {
        $status = 'FAILED'
        $detail = $_.Exception.Message
        Write-EngineLog -Kind error -Text ('Schritt fehlgeschlagen: {0}' -f $detail)
    }
    finally { $sw.Stop() }
    $step = Add-EngineStep -Name $Name -Status $status -ExitCode $exit -Detail $detail -DurationSec $sw.Elapsed.TotalSeconds
    Write-EngineLog -Kind (Get-LogKindForStatus $status) -Text ('=> {0}: {1} ({2}s)' -f $Name, $status, $step.durationSec)
    return $step
}

function Get-LogKindForStatus {
    param([string]$Status)
    if ($Status -eq 'PASS') { return 'ok' }
    if ($Status -eq 'FAILED') { return 'error' }
    if ($Status -eq 'SKIPPED') { return 'info' }
    return 'warn'
}

#endregion

#region ====================== System-Werkzeuge ========================

function Resolve-SystemTool {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:IsWindowsHost) { return $Name }
    $candidates = New-Object System.Collections.ArrayList
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        [void]$candidates.Add((Join-Path $env:SystemRoot ('Sysnative\' + $Name)))
    }
    [void]$candidates.Add((Join-Path $env:SystemRoot ('System32\' + $Name)))
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw ("Systemwerkzeug '{0}' wurde nicht gefunden." -f $Name)
}

<#  Testumgebung: Das Demo-Szenario bestimmt, welchen Systemzustand die
    Engine vortaeuscht. So lassen sich alle Verlaeufe der Oberflaeche
    pruefen, ohne ein kaputtes Windows zu brauchen.
      Healthy    - alles sauber
      Repaired   - SFC repariert Dateien, Neustart noetig
      Escalation - SFC scheitert, DISM hilft, 2. Durchlauf sauber
      Failed     - SFC scheitert, DISM scheitert ebenfalls
      Preflight  - Preflight blockiert den Lauf
#>
function Invoke-DemoCommand {
    param([string]$Label, [int]$Seconds = 6, [int]$ExitCode = 0)
    $steps = 10
    for ($i = 1; $i -le $steps; $i++) {
        if (Test-EngineCancelled) { break }
        Start-Sleep -Milliseconds ([int](($Seconds * 1000) / $steps))
        Write-EngineLog -Kind tool -Text ('{0} ... {1,3} %' -f $Label, ($i * 10))
    }
    return @{ ExitCode = $ExitCode; Status = 'PASS'; Tail = 'Demo'; Lines = @('Demo-Ausgabe') }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0),
        [ValidateSet('Default', 'Unicode')][string]$ToolEncoding = 'Default'
    )
    Write-EngineLog -Kind tool -Text ('> {0} {1}' -f (Split-Path $FilePath -Leaf), ($Arguments -join ' '))

    $prevEncoding = $null
    try { $prevEncoding = [Console]::OutputEncoding } catch { $prevEncoding = $null }
    $writer = $null
    $lastBucket = -1
    $code = $null
    $all = New-Object System.Collections.Generic.List[string]
    # Mit ErrorActionPreference 'Stop' wuerde jede stderr-Zeile eines nativen
    # Werkzeugs einen NativeCommandError ausloesen - deshalb lokal herabgestuft.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        if ($ToolEncoding -eq 'Unicode' -and $null -ne $prevEncoding) {
            try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode } catch { Write-Verbose 'Encoding fix' }
        }
        if ($script:ToolLog) {
            $writer = New-Object System.IO.StreamWriter($script:ToolLog, $true, [System.Text.Encoding]::UTF8)
            $writer.WriteLine(('--- {0} {1} ({2:yyyy-MM-dd HH:mm:ss}) ---' -f $FilePath, ($Arguments -join ' '), (Get-Date)))
        }

        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = ([string]$_).Replace([string][char]0, '').Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            if ($writer) { $writer.WriteLine($line) }
            $all.Add($line)

            $pct = $null
            if ($line -match '^\s*\[[=\s]*([0-9]{1,3})(?:[\.,][0-9]+)?\s*%') { $pct = [int]$Matches[1] }
            elseif ($line -match '([0-9]{1,3})\s*%\s*(?:complete|abgeschlossen|fertig)') { $pct = [int]$Matches[1] }

            if ($null -ne $pct) {
                $bucket = [math]::Floor($pct / 10)
                if ($bucket -gt $lastBucket) {
                    $lastBucket = $bucket
                    Write-EngineLog -Kind tool -Text ('... {0,3} %' -f ($bucket * 10))
                }
                return
            }
            if ($line -match '^\s*\[[=\s\.]*\]\s*$') { return }
            Write-EngineLog -Kind tool -Text $line
        }
        $code = $LASTEXITCODE
    }
    finally {
        if ($writer) { $writer.Flush(); $writer.Dispose() }
        if ($null -ne $prevEncoding) {
            try { [Console]::OutputEncoding = $prevEncoding } catch { Write-Verbose 'Encoding restore' }
        }
        $ErrorActionPreference = $prevEap
    }

    $status = 'FAILED'
    if ($SuccessExitCodes -contains $code) { $status = 'PASS' }
    elseif ($code -eq 3010) { $status = 'REBOOT' }
    if ($code -eq 3010) { Add-EngineRestartReason ('{0}: Neustart erforderlich (3010)' -f (Split-Path $FilePath -Leaf)) }

    return @{ ExitCode = $code; Status = $status; Lines = $all }
}

function Invoke-DismAction {
    param([Parameter(Mandatory)][string[]]$DismArgs, [int[]]$SuccessExitCodes = @(0, 3010))
    if ($script:Demo) {
        $r = Invoke-DemoCommand -Label ('DISM ' + ($DismArgs -join ' ')) -Seconds 5
        if ($script:DemoScenario -eq 'Failed' -and ($DismArgs -contains '/RestoreHealth')) {
            Add-EngineFinding -Level error -Text 'DISM ExitCode 2: Quelle fuer die Reparatur fehlt (/Source pruefen). [Demo]'
            return @{ Status = 'FAILED'; ExitCode = 2; Detail = 'Quelle fehlt (Demo)'; Lines = @() }
        }
        return $r
    }
    $dism = Resolve-SystemTool -Name 'dism.exe'
    $r = Invoke-NativeCommand -FilePath $dism -Arguments $DismArgs -SuccessExitCodes $SuccessExitCodes
    if ($r.Status -eq 'FAILED') {
        $hint = 'Details siehe C:\Windows\Logs\DISM\dism.log'
        if ($r.ExitCode -eq 1726) { $hint = 'RPC-Aufruf fehlgeschlagen - parallele Windows-Wartung aktiv. Spaeter erneut versuchen.' }
        elseif ($r.ExitCode -eq 50) { $hint = 'Vorgang in dieser Umgebung nicht unterstuetzt.' }
        elseif ($r.ExitCode -eq 87) { $hint = 'Ungueltiger Parameter fuer diese Windows-Version.' }
        elseif ($r.ExitCode -eq 2) { $hint = 'Quelle fuer die Reparatur fehlt (/Source pruefen).' }
        Add-EngineFinding -Level error -Text ('DISM ExitCode {0}: {1}' -f $r.ExitCode, $hint)
        return @{ Status = 'FAILED'; ExitCode = $r.ExitCode; Detail = $hint; Lines = $r.Lines }
    }
    return @{ Status = $r.Status; ExitCode = $r.ExitCode; Detail = ''; Lines = $r.Lines }
}

#endregion

#region ============================ Preflight ==========================

function Get-FreeSpaceGB {
    param([string]$Drive)
    if (-not $script:IsWindowsHost) { return 42.0 }
    if (-not $Drive) { $Drive = $env:SystemDrive }
    try {
        $letter = $Drive.TrimEnd('\').TrimEnd(':')
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letter) -ErrorAction Stop
        return [math]::Round($vol.FreeSpace / 1GB, 2)
    }
    catch { return $null }
}

function Get-PendingRebootReason {
    $reasons = New-Object System.Collections.ArrayList
    if (-not $script:IsWindowsHost) { return $reasons }
    $checks = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'; Text = 'Component Based Servicing (CBS)' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'; Text = 'Windows Update' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'; Text = 'CBS Reboot in Arbeit' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'; Text = 'Ausstehende Pakete' }
    )
    foreach ($c in $checks) { if (Test-Path -LiteralPath $c.Path) { [void]$reasons.Add($c.Text) } }
    try {
        $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($sm.PSObject.Properties.Name -contains 'PendingFileRenameOperations' -and $sm.PendingFileRenameOperations) {
            [void]$reasons.Add('PendingFileRenameOperations')
        }
    }
    catch { Write-Verbose 'Session Manager nicht lesbar.' }
    return $reasons
}

function Test-AdminRights {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Eingebuergerter Name; "Rechte" sind hier sachlich Mehrzahl.')]
    param()
    if (-not $script:IsWindowsHost) { return $true }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-SystemSnapshot {
    <#  Schnelle, rein lesende Bestandsaufnahme fuer die Oberflaeche. #>
    $computerName = $env:COMPUTERNAME
    if ([string]::IsNullOrWhiteSpace($computerName)) { $computerName = [Environment]::MachineName }
    $snap = [ordered]@{
        computer        = $computerName
        os              = 'unbekannt'
        build           = ''
        psVersion       = $PSVersionTable.PSVersion.ToString()
        isAdmin         = (Test-AdminRights)
        is64BitProcess  = [Environment]::Is64BitProcess
        systemDrive     = $env:SystemDrive
        freeSpaceGB     = (Get-FreeSpaceGB)
        totalSpaceGB    = $null
        lastBoot        = $null
        uptimeDays      = $null
        pendingReboot   = @()
        componentStore  = 'unbekannt'
        disks           = @()
        maintenanceBusy = @()
        demo            = $script:Demo
    }
    if (-not $script:IsWindowsHost) {
        $snap.os = 'Demo-Umgebung (kein Windows)'
        $snap.componentStore = 'Healthy'
        $snap.disks = @([ordered]@{ name = 'Demo SSD 1 TB'; media = 'SSD'; health = 'Healthy'; sizeGB = 1000 })
        return $snap
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $snap.os = $os.Caption.Trim()
        $snap.build = [string]$os.BuildNumber
        $snap.lastBoot = $os.LastBootUpTime.ToString('o')
        $snap.uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    }
    catch { Write-Verbose 'OS-Info nicht lesbar.' }
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letter) -ErrorAction Stop
        $snap.totalSpaceGB = [math]::Round($vol.Size / 1GB, 2)
    }
    catch { Write-Verbose 'Volume nicht lesbar.' }
    $snap.pendingReboot = @(Get-PendingRebootReason)
    if (Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        try {
            $snap.disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
                    [ordered]@{ name = $_.FriendlyName; media = [string]$_.MediaType; health = [string]$_.HealthStatus; sizeGB = [math]::Round($_.Size / 1GB, 0) }
                })
        }
        catch { Write-Verbose 'PhysicalDisk nicht lesbar.' }
    }
    $busy = Get-Process -Name 'dism', 'DismHost', 'sfc', 'TiWorker', 'TrustedInstaller' -ErrorAction SilentlyContinue
    if ($busy) { $snap.maintenanceBusy = @($busy | Select-Object -ExpandProperty ProcessName -Unique) }
    if (Get-Command -Name Repair-WindowsImage -ErrorAction SilentlyContinue) {
        try { $snap.componentStore = [string](Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState }
        catch { $snap.componentStore = 'unbekannt' }
    }
    return $snap
}

function Invoke-PreflightStage {
    param([int]$MinFreeSpaceGB = 8)
    $blocking = New-Object System.Collections.ArrayList
    $snap = Get-SystemSnapshot
    $script:State.os = ('{0} {1}' -f $snap.os, $snap.build).Trim()
    $script:State.freeSpaceStartGB = $snap.freeSpaceGB

    Write-EngineLog -Text ('Betriebssystem : {0} (Build {1})' -f $snap.os, $snap.build)
    Write-EngineLog -Text ('PowerShell     : {0} ({1}-Bit)' -f $snap.psVersion, $(if ($snap.is64BitProcess) { 64 } else { 32 }))
    if ($null -ne $snap.freeSpaceGB) { Write-EngineLog -Text ('Freier Speicher: {0} GB' -f $snap.freeSpaceGB) }

    if (-not $snap.isAdmin) { [void]$blocking.Add('keine Administratorrechte') }
    if ($script:IsWindowsHost -and -not $script:Demo) {
        foreach ($tool in @('dism.exe', 'sfc.exe')) {
            try { [void](Resolve-SystemTool -Name $tool) }
            catch { [void]$blocking.Add(('{0} fehlt' -f $tool)) }
        }
    }
    if ($null -ne $snap.freeSpaceGB -and $snap.freeSpaceGB -lt $MinFreeSpaceGB) {
        Add-EngineFinding -Level warn -Text ('Weniger als {0} GB frei - DISM/SFC koennen fehlschlagen. Die Wartung schafft ggf. Platz.' -f $MinFreeSpaceGB)
    }
    if ($snap.uptimeDays -and $snap.uptimeDays -gt 14) {
        Add-EngineFinding -Level warn -Text ('Laufzeit seit letztem Neustart: {0} Tage - Neustart vor der Reparatur empfehlenswert.' -f $snap.uptimeDays)
    }
    if (@($snap.pendingReboot).Count -gt 0) {
        Add-EngineFinding -Level warn -Text ('Es steht bereits ein Neustart aus: {0}' -f (@($snap.pendingReboot) -join ', '))
        foreach ($r in @($snap.pendingReboot)) { Add-EngineRestartReason ('Bereits vor dem Lauf ausstehend: ' + $r) }
    }
    $hard = @($snap.maintenanceBusy) | Where-Object { $_ -in @('dism', 'sfc') }
    if ($hard -and -not $script:Demo) { [void]$blocking.Add(('Es laeuft bereits: {0}' -f ($hard -join ', '))) }
    foreach ($d in @($snap.disks)) {
        if ($d.health -and $d.health -ne 'Healthy') {
            Add-EngineFinding -Level error -Text ('Datentraegerproblem: {0} ({1})' -f $d.name, $d.health)
        }
    }

    if ($script:Demo -and $script:DemoScenario -eq 'Preflight') {
        [void]$blocking.Add('Demo: Administratorrechte fehlen')
    }
    if ($blocking.Count -gt 0) { return @{ Status = 'FAILED'; Detail = ($blocking -join '; ') } }
    return @{ Status = 'PASS'; Detail = ('{0} Hinweise' -f @($script:State.findings).Count) }
}

#endregion

#region =========================== Reparatur ===========================

function Test-ComponentStoreHealth {
    if ($script:Demo) {
        $sc = $script:DemoScenario
        if ($sc -eq 'Escalation') {
            if ($script:DemoPass -ge 2) { return 'Healthy' }
            return 'Repairable'
        }
        if ($sc -eq 'Failed') { return 'Repairable' }
        return 'Healthy'
    }
    if (-not (Get-Command -Name Repair-WindowsImage -ErrorAction SilentlyContinue)) { return $null }
    try { return [string](Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState }
    catch { return $null }
}

function Invoke-RepairStage {
    param([string]$Mode, [bool]$SkipDism, [bool]$SkipSfc)

    if ($SkipDism) { Add-EngineStep -Name 'DISM' -Status 'SKIPPED' -Detail 'uebersprungen' | Out-Null }
    else {
        if ($Mode -eq 'Diagnose' -or $Mode -eq 'Full') {
            Invoke-EngineStep -Name 'DISM_CheckHealth' -Title 'DISM - Schnellpruefung (CheckHealth)' -Progress 15 -Action {
                Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/CheckHealth')
            } | Out-Null
            Invoke-EngineStep -Name 'DISM_ScanHealth' -Title 'DISM - Tiefenpruefung (ScanHealth)' -Progress 25 -Action {
                Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/ScanHealth')
            } | Out-Null
        }
        if ($Mode -eq 'Repair' -or $Mode -eq 'Full') {
            $health = Test-ComponentStoreHealth
            $needRestore = $true
            if ($health -eq 'Healthy' -and $Mode -eq 'Repair') { $needRestore = $false }
            if ($needRestore) {
                Invoke-EngineStep -Name 'DISM_RestoreHealth' -Title 'DISM - Reparatur (RestoreHealth)' -Progress 35 -Action {
                    Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/RestoreHealth')
                } | Out-Null
            }
            else {
                Write-EngineLog -Kind section -Text 'DISM - Reparatur (RestoreHealth)'
                Write-EngineLog -Kind ok -Text 'Komponentenstore meldet "Healthy" - RestoreHealth wird uebersprungen.'
                Add-EngineStep -Name 'DISM_RestoreHealth' -Status 'SKIPPED' -Detail 'nicht erforderlich (Healthy)' | Out-Null
            }
        }
    }

    if ($SkipSfc) {
        Add-EngineStep -Name 'SFC' -Status 'SKIPPED' -Detail 'uebersprungen' | Out-Null
        return
    }
    $sfcArgs = @('/scannow')
    $title = 'System File Checker (sfc /scannow)'
    if ($Mode -eq 'Diagnose') { $sfcArgs = @('/verifyonly'); $title = 'System File Checker (sfc /verifyonly)' }

    Invoke-EngineStep -Name 'SFC' -Title $title -Progress 55 -Action {
        if ($script:Demo) { $r = Invoke-DemoCommand -Label 'SFC' -Seconds 6 }
        else {
            $sfc = Resolve-SystemTool -Name 'sfc.exe'
            $r = Invoke-NativeCommand -FilePath $sfc -Arguments $sfcArgs -SuccessExitCodes @(0, 1, 2, 3) -ToolEncoding Unicode
        }
        return @{ Status = 'PASS'; ExitCode = $r.ExitCode; Detail = 'Bewertung ueber CBS-Analyse' }
    } | Out-Null
}

#endregion

#region ========================== CBS-Analyse ==========================

function Get-CbsSfcSummary {
    param([Parameter(Mandatory)][datetime]$Since)
    $summary = [pscustomobject]@{
        Available = $false; Repaired = 0; CannotRepair = 0; Corrupt = 0
        TotalSrLines = 0; Lines = (New-Object System.Collections.ArrayList)
    }
    if ($script:Demo) {
        $script:DemoPass++
        $summary.Available = $true
        $summary.TotalSrLines = 12
        $sc = $script:DemoScenario
        if ($sc -eq 'Healthy') {
            $summary.TotalSrLines = 4
        }
        elseif ($sc -eq 'Escalation' -and $script:DemoPass -ge 2) {
            $summary.Repaired = 3
            [void]$summary.Lines.Add('[SR] Repaired file demo-nach-DISM.dll (Demo)')
        }
        elseif ($sc -eq 'Escalation' -or $sc -eq 'Failed') {
            $summary.CannotRepair = 3
            $summary.Corrupt = 1
            [void]$summary.Lines.Add('[SR] Cannot repair member file demo-kaputt.sys (Demo)')
        }
        else {
            $summary.Repaired = 2
            [void]$summary.Lines.Add('[SR] Repaired file \??\C:\Windows\System32\demo.dll (Demo)')
        }
        return $summary
    }
    $cbs = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    if (-not (Test-Path -LiteralPath $cbs)) { return $summary }
    $stream = $null; $reader = $null
    try {
        $stream = New-Object System.IO.FileStream($cbs, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
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
    catch { Write-EngineLog -Kind warn -Text ('CBS.log nicht vollstaendig lesbar: {0}' -f $_.Exception.Message) }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    return $summary
}

function Get-SfcOutcome {
    param([datetime]$Since, [string]$SfcStepName, [string]$ExportTag, [string]$RunDir)
    $sum = Get-CbsSfcSummary -Since $Since
    if (-not $sum.Available) { return @{ Status = 'WARNING'; Detail = 'CBS.log nicht lesbar' } }

    Write-EngineLog -Text ('[SR]-Eintraege: {0} | repariert: {1} | nicht reparierbar: {2} | beschaedigt: {3}' -f `
            $sum.TotalSrLines, $sum.Repaired, $sum.CannotRepair, $sum.Corrupt)

    if ($sum.Lines.Count -gt 0 -and $RunDir) {
        $out = Join-Path $RunDir ('CBS-{0}.txt' -f $ExportTag)
        $sum.Lines | Set-Content -LiteralPath $out -Encoding UTF8 -WhatIf:$false
        Write-EngineLog -Text ('Details exportiert: {0}' -f (Split-Path $out -Leaf))
    }

    $steps = @($script:State.steps)
    $sfcStep = $steps | Where-Object { $_.name -eq $SfcStepName } | Select-Object -First 1
    if ($sum.CannotRepair -gt 0) {
        Add-EngineFinding -Level error -Text ('SFC konnte {0} Datei(en) nicht reparieren.' -f $sum.CannotRepair)
        if ($sfcStep) { $sfcStep.status = 'FAILED'; $sfcStep.detail = ('{0} Datei(en) nicht reparierbar' -f $sum.CannotRepair) }
        return @{ Status = 'FAILED'; Detail = ('{0} nicht reparierbar' -f $sum.CannotRepair) }
    }
    if ($sum.Repaired -gt 0) {
        Add-EngineFinding -Level warn -Text ('SFC hat {0} Datei(en) repariert - Neustart erforderlich.' -f $sum.Repaired)
        Add-EngineRestartReason 'SFC hat Systemdateien repariert'
        if ($sfcStep) { $sfcStep.status = 'REPAIRED'; $sfcStep.detail = ('{0} Datei(en) repariert' -f $sum.Repaired) }
        return @{ Status = 'REPAIRED'; Detail = ('{0} repariert' -f $sum.Repaired) }
    }
    Write-EngineLog -Kind ok -Text 'Keine Integritaetsverletzungen in diesem Durchlauf.'
    return @{ Status = 'PASS'; Detail = 'keine Verletzungen' }
}

function Invoke-EscalationStage {
    param([string]$Mode, [string]$RunDir, [bool]$SkipDism, [bool]$SkipSfc, [bool]$NoEscalate)
    if ($NoEscalate -or $SkipDism -or $SkipSfc) { return }
    if ($Mode -ne 'Repair' -and $Mode -ne 'Full') { return }
    $cbsStep = @($script:State.steps) | Where-Object { $_.name -eq 'CBS_Analyse' } | Select-Object -First 1
    if (-not $cbsStep -or $cbsStep.status -ne 'FAILED') { return }

    Write-EngineLog -Kind section -Text 'Eskalation - SFC konnte nicht alles reparieren'
    Write-EngineLog -Text 'Zweiter Anlauf: DISM /RestoreHealth, danach SFC erneut.'
    $since = Get-Date

    $dism = Invoke-EngineStep -Name 'DISM_RestoreHealth_2' -Title 'Eskalation - DISM /RestoreHealth' -Progress 70 -Action {
        Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/RestoreHealth')
    }
    if ($dism.status -eq 'FAILED') {
        Add-EngineFinding -Level error -Text 'Eskalation gestoppt: DISM konnte den Komponentenstore nicht reparieren (Installationsquelle noetig).'
        return
    }
    Invoke-EngineStep -Name 'SFC_2' -Title 'Eskalation - sfc /scannow (2. Durchlauf)' -Progress 78 -Action {
        if ($script:Demo) { $r = Invoke-DemoCommand -Label 'SFC (2)' -Seconds 5 }
        else {
            $sfc = Resolve-SystemTool -Name 'sfc.exe'
            $r = Invoke-NativeCommand -FilePath $sfc -Arguments @('/scannow') -SuccessExitCodes @(0, 1, 2, 3) -ToolEncoding Unicode
        }
        return @{ Status = 'PASS'; ExitCode = $r.ExitCode; Detail = 'Bewertung ueber CBS-Analyse' }
    } | Out-Null

    $second = Invoke-EngineStep -Name 'CBS_Analyse_2' -Title 'Eskalation - CBS-Auswertung (2. Durchlauf)' -Progress 82 -Action {
        Get-SfcOutcome -Since $since -SfcStepName 'SFC_2' -ExportTag 'SFC2' -RunDir $RunDir
    }
    if ($second.status -eq 'PASS' -or $second.status -eq 'REPAIRED') {
        foreach ($name in @('SFC', 'CBS_Analyse')) {
            $st = @($script:State.steps) | Where-Object { $_.name -eq $name } | Select-Object -First 1
            if ($st -and $st.status -eq 'FAILED') {
                $st.status = 'WARNING'
                $st.detail = ($st.detail + ' (im 2. Durchlauf behoben)').Trim()
            }
        }
        Add-EngineRestartReason 'Reparatur ueber zweiten Durchlauf abgeschlossen'
        Write-EngineLog -Kind ok -Text 'Eskalation erfolgreich.'
    }
}

#endregion

#region ========================= Verifikation ==========================

function Invoke-VerifyStage {
    param([string]$Mode, [bool]$SkipDisk)

    Invoke-EngineStep -Name 'ComponentStore' -Title 'Verifikation - Komponentenstore' -Progress 86 -Action {
        $state = Test-ComponentStoreHealth
        if (-not $state) { return @{ Status = 'WARNING'; Detail = 'Status nicht ermittelbar' } }
        if ($state -eq 'Healthy') {
            Write-EngineLog -Kind ok -Text 'Komponentenstore ist sauber (Healthy).'
            return @{ Status = 'PASS'; Detail = $state }
        }
        if ($state -eq 'Repairable') {
            Add-EngineFinding -Level warn -Text 'Komponentenstore reparierbar, aber noch beschaedigt. Neustart, danach Modus "Full".'
            Add-EngineRestartReason 'Komponentenstore noch nicht sauber'
            return @{ Status = 'WARNING'; Detail = $state }
        }
        Add-EngineFinding -Level error -Text ('Komponentenstore-Status: {0}. Reparatur mit Installationsquelle noetig.' -f $state)
        return @{ Status = 'FAILED'; Detail = $state }
    } | Out-Null

    if ($SkipDisk -or $Mode -eq 'Quick') { return }

    Invoke-EngineStep -Name 'Datentraeger' -Title 'Verifikation - Datentraeger & Dateisystem' -Progress 90 -Action {
        if ($script:Demo) {
            Invoke-DemoCommand -Label 'chkdsk /scan' -Seconds 4 | Out-Null
            Write-EngineLog -Kind ok -Text 'Dateisystem ohne Befund (Demo).'
            return @{ Status = 'PASS'; Detail = 'Demo' }
        }
        $worst = 'PASS'
        $chk = Resolve-SystemTool -Name 'chkdsk.exe'
        $r = Invoke-NativeCommand -FilePath $chk -Arguments @($env:SystemDrive, '/scan', '/perf') -SuccessExitCodes @(0)
        if ($r.ExitCode -ne 0) {
            Add-EngineFinding -Level warn -Text ('chkdsk /scan ExitCode {0} - Dateisystemfehler. Behebung: chkdsk {1} /spotfix (Neustart).' -f $r.ExitCode, $env:SystemDrive)
            $worst = 'WARNING'
        }
        else { Write-EngineLog -Kind ok -Text ('Dateisystem auf {0} ohne Befund.' -f $env:SystemDrive) }
        return @{ Status = $worst; ExitCode = $r.ExitCode }
    } | Out-Null
}

#endregion

#region ========================== Optimierung ==========================

function Format-ByteSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Clear-FolderContent {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$OlderThanDays = 0,
        [string]$Filter = '*',
        [string]$Label
    )
    $result = [pscustomobject]@{ Label = $Label; Path = $Path; Files = 0; Bytes = 0; Skipped = 0; Exists = $true }
    if (-not (Test-Path -LiteralPath $Path)) { $result.Exists = $false; return $result }
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
    return $result
}

function Invoke-FileCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level, [int]$TempFileAgeDays = 2, [string]$LogRoot)

    if ($script:Demo) {
        Invoke-DemoCommand -Label 'Bereinigung' -Seconds 3 | Out-Null
        Write-EngineLog -Kind ok -Text '1.284 Dateien entfernt, 2,41 GB freigegeben (Demo).'
        return @{ Status = 'PASS'; Detail = 'Demo: 2,41 GB' }
    }

    $targets = New-Object System.Collections.ArrayList
    [void]$targets.Add(@{ Label = 'Benutzer-Temp'; Path = $env:TEMP; Days = $TempFileAgeDays })
    [void]$targets.Add(@{ Label = 'Windows-Temp'; Path = (Join-Path $env:SystemRoot 'Temp'); Days = $TempFileAgeDays })
    if ($Level -eq 'Standard' -or $Level -eq 'Aggressive') {
        [void]$targets.Add(@{ Label = 'Windows-Update-Downloadcache'; Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download'); Days = 1 })
        [void]$targets.Add(@{ Label = 'Fehlerberichte (WER Queue)'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'); Days = 1 })
        [void]$targets.Add(@{ Label = 'Fehlerberichte (WER Archive)'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'); Days = 1 })
        [void]$targets.Add(@{ Label = 'Archivierte CBS-Logs'; Path = (Join-Path $env:SystemRoot 'Logs\CBS'); Days = 7; Filter = 'CbsPersist_*.log' })
        [void]$targets.Add(@{ Label = 'Thumbnail-Cache'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Days = 0; Filter = 'thumbcache_*.db' })
    }

    $totalBytes = 0; $totalFiles = 0
    foreach ($t in $targets) {
        $filter = '*'
        if ($t.ContainsKey('Filter')) { $filter = $t.Filter }
        $r = Clear-FolderContent -Path $t.Path -OlderThanDays $t.Days -Filter $filter -Label $t.Label
        if (-not $r.Exists) { continue }
        $totalBytes += $r.Bytes; $totalFiles += $r.Files
        if ($r.Files -gt 0) {
            Write-EngineLog -Text ('{0,-38} {1,6} Dateien  {2}' -f $r.Label, $r.Files, (Format-ByteSize $r.Bytes))
        }
    }

    if (($Level -eq 'Standard' -or $Level -eq 'Aggressive') -and (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess('Delivery Optimization Cache', 'Leeren')) {
            try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Write-EngineLog -Text 'Delivery-Optimization-Cache geleert.' }
            catch { Write-EngineLog -Kind warn -Text ('Delivery-Optimization-Cache: {0}' -f $_.Exception.Message) }
        }
    }
    if ($Level -eq 'Aggressive' -and (Get-Command -Name Clear-RecycleBin -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess('Papierkorb', 'Leeren')) {
            try { Clear-RecycleBin -Force -ErrorAction Stop; Write-EngineLog -Text 'Papierkorb geleert.' }
            catch { Write-EngineLog -Kind warn -Text ('Papierkorb: {0}' -f $_.Exception.Message) }
        }
    }
    if ($LogRoot) {
        $r = Clear-FolderContent -Path $LogRoot -OlderThanDays 30 -Label 'Alte Berichte'
        if ($r.Files -gt 0) { $totalFiles += $r.Files; $totalBytes += $r.Bytes }
    }

    if ($totalFiles -eq 0) { Write-EngineLog -Kind ok -Text 'Keine loeschbaren Altlasten gefunden.' }
    else { Write-EngineLog -Kind ok -Text ('{0} Dateien entfernt, {1} freigegeben.' -f $totalFiles, (Format-ByteSize $totalBytes)) }
    return @{ Status = 'PASS'; Detail = ('{0} Dateien / {1}' -f $totalFiles, (Format-ByteSize $totalBytes)) }
}

function Invoke-ComponentStoreMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)

    if ($script:Demo) {
        Invoke-DemoCommand -Label 'WinSxS-Analyse' -Seconds 3 | Out-Null
        return @{ Status = 'PASS'; Detail = 'Demo: Bereinigung nicht noetig' }
    }
    $analyze = Invoke-DismAction -DismArgs @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -SuccessExitCodes @(0, 3010)
    $recommended = $false
    foreach ($l in @($analyze.Lines)) {
        if ($l -match 'Component Store Cleanup Recommended\s*:\s*(Yes|Ja)') { $recommended = $true }
        if ($l -match 'Bereinigung des Komponentenspeichers empfohlen\s*:\s*Ja') { $recommended = $true }
    }
    if ($Level -eq 'Safe') {
        Write-EngineLog -Text ('Bereinigung empfohlen: {0} (Stufe "Safe" analysiert nur)' -f $(if ($recommended) { 'ja' } else { 'nein' }))
        return @{ Status = 'PASS'; Detail = ('Analyse; empfohlen = {0}' -f $recommended) }
    }
    if (-not $recommended -and $Level -ne 'Aggressive') {
        Write-EngineLog -Kind ok -Text 'Keine WinSxS-Bereinigung noetig - uebersprungen.'
        return @{ Status = 'SKIPPED'; Detail = 'nicht empfohlen' }
    }
    $cleanupArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    $what = 'WinSxS bereinigen'
    if ($Level -eq 'Aggressive') {
        $cleanupArgs += '/ResetBase'
        $what = 'WinSxS bereinigen inkl. /ResetBase'
        Add-EngineFinding -Level warn -Text '/ResetBase: installierte Windows-Updates lassen sich danach nicht mehr einzeln deinstallieren.'
    }
    if (-not $PSCmdlet.ShouldProcess('Komponentenstore (WinSxS)', $what)) { return @{ Status = 'SKIPPED'; Detail = 'WhatIf' } }
    return Invoke-DismAction -DismArgs $cleanupArgs -SuccessExitCodes @(0, 3010)
}

function Invoke-StorageMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)

    if ($script:Demo) {
        Invoke-DemoCommand -Label 'TRIM' -Seconds 3 | Out-Null
        return @{ Status = 'PASS'; Detail = 'Demo: C=TRIM' }
    }
    if (-not (Get-Command -Name Optimize-Volume -ErrorAction SilentlyContinue)) {
        return @{ Status = 'SKIPPED'; Detail = 'Optimize-Volume nicht verfuegbar' }
    }
    $volumes = Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and ($_.FileSystem -eq 'NTFS' -or $_.FileSystem -eq 'ReFS') }
    if (-not $volumes) { return @{ Status = 'SKIPPED'; Detail = 'keine passenden Volumes' } }

    $done = New-Object System.Collections.ArrayList
    foreach ($v in $volumes) {
        $media = 'Unspecified'
        try {
            $disk = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop
            $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$disk.Number }
            if ($phys) { $media = [string]$phys.MediaType }
        }
        catch { Write-Verbose 'MediaType nicht ermittelbar.' }

        if ($Level -eq 'Safe') {
            try { Optimize-Volume -DriveLetter $v.DriveLetter -Analyze -Verbose:$false -ErrorAction Stop | Out-Null }
            catch { Write-Verbose 'Analyse nicht moeglich.' }
            Write-EngineLog -Text ('{0}: analysiert ({1})' -f $v.DriveLetter, $media)
            continue
        }
        if ($media -eq 'SSD') {
            if ($PSCmdlet.ShouldProcess(('Laufwerk ' + $v.DriveLetter), 'TRIM')) {
                try {
                    Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -Verbose:$false -ErrorAction Stop
                    Write-EngineLog -Kind ok -Text ('{0}: TRIM ausgefuehrt (SSD).' -f $v.DriveLetter)
                    [void]$done.Add(('{0}=TRIM' -f $v.DriveLetter))
                }
                catch { Write-EngineLog -Kind warn -Text ('{0}: TRIM fehlgeschlagen.' -f $v.DriveLetter) }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess(('Laufwerk ' + $v.DriveLetter), 'Defragmentieren')) {
                try {
                    Optimize-Volume -DriveLetter $v.DriveLetter -Defrag -Verbose:$false -ErrorAction Stop
                    Write-EngineLog -Kind ok -Text ('{0}: defragmentiert ({1}).' -f $v.DriveLetter, $media)
                    [void]$done.Add(('{0}=Defrag' -f $v.DriveLetter))
                }
                catch { Write-EngineLog -Kind warn -Text ('{0}: Defrag fehlgeschlagen.' -f $v.DriveLetter) }
            }
        }
    }
    return @{ Status = 'PASS'; Detail = ($done -join ', ') }
}

function Invoke-NetworkMaintenance {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Level)
    if ($script:Demo) { return @{ Status = 'PASS'; Detail = 'Demo: DNS-Cache geleert' } }
    $ipconfig = Resolve-SystemTool -Name 'ipconfig.exe'
    if ($PSCmdlet.ShouldProcess('DNS-Cache', 'Leeren')) {
        Invoke-NativeCommand -FilePath $ipconfig -Arguments @('/flushdns') -SuccessExitCodes @(0) | Out-Null
    }
    if ($Level -ne 'Aggressive') { return @{ Status = 'PASS'; Detail = 'DNS-Cache geleert' } }
    $netsh = Resolve-SystemTool -Name 'netsh.exe'
    if ($PSCmdlet.ShouldProcess('Netzwerkstack', 'Winsock- und IP-Reset')) {
        Invoke-NativeCommand -FilePath $netsh -Arguments @('winsock', 'reset') -SuccessExitCodes @(0) | Out-Null
        Invoke-NativeCommand -FilePath $netsh -Arguments @('int', 'ip', 'reset') -SuccessExitCodes @(0) | Out-Null
        Add-EngineRestartReason 'Winsock-/IP-Reset durchgefuehrt'
        Add-EngineFinding -Level warn -Text 'Netzwerkstack zurueckgesetzt - VPN-Clients ggf. neu konfigurieren.'
    }
    return @{ Status = 'PASS'; Detail = 'DNS + Winsock/IP' }
}

function Reset-WindowsUpdateComponent {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if ($script:Demo) { return @{ Status = 'PASS'; Detail = 'Demo' } }
    if (-not $PSCmdlet.ShouldProcess('Windows-Update-Komponenten', 'Zuruecksetzen')) { return @{ Status = 'SKIPPED'; Detail = 'WhatIf' } }
    $services = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    $stopped = New-Object System.Collections.ArrayList
    foreach ($s in $services) {
        try {
            $svc = Get-Service -Name $s -ErrorAction Stop
            if ($svc.Status -ne 'Stopped') { Stop-Service -Name $s -Force -ErrorAction Stop; [void]$stopped.Add($s) }
        }
        catch { Write-EngineLog -Kind warn -Text ('Dienst {0}: {1}' -f $s, $_.Exception.Message) }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($pair in @(
            @{ Path = (Join-Path $env:SystemRoot 'SoftwareDistribution'); New = ('SoftwareDistribution.old-' + $stamp) },
            @{ Path = (Join-Path $env:SystemRoot 'System32\catroot2'); New = ('catroot2.old-' + $stamp) })) {
        if (Test-Path -LiteralPath $pair.Path) {
            try {
                Rename-Item -LiteralPath $pair.Path -NewName $pair.New -Force -ErrorAction Stop
                Write-EngineLog -Kind ok -Text ('{0} umbenannt.' -f (Split-Path $pair.Path -Leaf))
            }
            catch { Write-EngineLog -Kind warn -Text ('{0} nicht umbenennbar.' -f $pair.Path) }
        }
    }
    foreach ($s in $stopped) {
        try { Start-Service -Name $s -ErrorAction Stop } catch { Write-EngineLog -Kind warn -Text ('Dienst {0} nicht startbar.' -f $s) }
    }
    Add-EngineRestartReason 'Windows-Update-Komponenten zurueckgesetzt'
    return @{ Status = 'PASS'; Detail = 'SoftwareDistribution + catroot2' }
}

function Get-StartupReport {
    if ($script:Demo) {
        Write-EngineLog -Text '7 Autostart-Eintraege gefunden (Demo).'
        return @{ Status = 'PASS'; Detail = '7 Eintraege' }
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        try {
            $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                [void]$items.Add($p.Name)
            }
        }
        catch { Write-Verbose 'Run-Key nicht lesbar.' }
    }
    foreach ($folder in @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'))) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue | ForEach-Object { [void]$items.Add($_.Name) }
    }
    if ($items.Count -eq 0) { Write-EngineLog -Kind ok -Text 'Keine klassischen Autostart-Eintraege gefunden.' }
    else {
        Write-EngineLog -Text ('{0} Autostart-Eintraege: {1}' -f $items.Count, (($items | Select-Object -First 15) -join ', '))
        Add-EngineFinding -Level info -Text ('Autostart-Eintraege: {0} - bewusst nicht automatisch deaktiviert.' -f $items.Count)
    }
    return @{ Status = 'PASS'; Detail = ('{0} Eintraege' -f $items.Count) }
}

function New-SafetyRestorePoint {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([string]$Description = 'RepairCenter - vor der Wartung')

    if ($script:Demo) {
        Write-EngineLog -Kind ok -Text 'Wiederherstellungspunkt angelegt (Demo).'
        return @{ Status = 'PASS'; Detail = 'Demo' }
    }
    if (-not (Get-Command -Name Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        return @{ Status = 'SKIPPED'; Detail = 'Checkpoint-Computer nicht verfuegbar' }
    }
    try {
        $sr = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop
        if (-not $sr) { Write-Verbose 'Keine Wiederherstellungspunkte vorhanden.' }
    }
    catch {
        Add-EngineFinding -Level warn -Text 'Systemwiederherstellung ist deaktiviert - es wird kein Wiederherstellungspunkt angelegt.'
        return @{ Status = 'SKIPPED'; Detail = 'Systemwiederherstellung deaktiviert' }
    }
    if (-not $PSCmdlet.ShouldProcess('System', 'Wiederherstellungspunkt anlegen')) {
        return @{ Status = 'SKIPPED'; Detail = 'WhatIf' }
    }
    try {
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-EngineLog -Kind ok -Text 'Wiederherstellungspunkt angelegt.'
        return @{ Status = 'PASS'; Detail = $Description }
    }
    catch {
        # Windows laesst hoechstens einen Punkt in 24 Stunden zu - das ist kein Fehler.
        Add-EngineFinding -Level warn -Text ('Wiederherstellungspunkt nicht angelegt: {0}' -f $_.Exception.Message)
        return @{ Status = 'WARNING'; Detail = $_.Exception.Message }
    }
}

function Invoke-OptimizeStage {
    param([string]$Level, [int]$TempFileAgeDays, [string]$LogRoot, [bool]$SkipDisk, [bool]$NoRestorePoint)
    if ($Level -eq 'None') {
        Add-EngineStep -Name 'Wartung' -Status 'SKIPPED' -Detail 'deaktiviert' | Out-Null
        return
    }
    if (($Level -eq 'Standard' -or $Level -eq 'Aggressive')) {
        if ($NoRestorePoint) {
            Add-EngineStep -Name 'Wiederherstellungspunkt' -Status 'SKIPPED' -Detail 'abgewaehlt' | Out-Null
        }
        else {
            Invoke-EngineStep -Name 'Wiederherstellungspunkt' -Title 'Wartung - Wiederherstellungspunkt' -Progress 91 -Action {
                New-SafetyRestorePoint
            } | Out-Null
        }
    }
    Invoke-EngineStep -Name 'OPT_Bereinigung' -Title ('Wartung - Bereinigung (Stufe {0})' -f $Level) -Progress 92 -Action {
        Invoke-FileCleanup -Level $Level -TempFileAgeDays $TempFileAgeDays -LogRoot $LogRoot
    } | Out-Null
    Invoke-EngineStep -Name 'OPT_Komponentenstore' -Title 'Wartung - Komponentenstore (WinSxS)' -Progress 94 -Action {
        Invoke-ComponentStoreMaintenance -Level $Level
    } | Out-Null
    Invoke-EngineStep -Name 'OPT_Datentraeger' -Title 'Wartung - TRIM / Defragmentierung' -Progress 96 -Action {
        if ($SkipDisk) { return @{ Status = 'SKIPPED'; Detail = 'uebersprungen' } }
        Invoke-StorageMaintenance -Level $Level
    } | Out-Null
    Invoke-EngineStep -Name 'OPT_Netzwerk' -Title 'Wartung - Netzwerk' -Progress 97 -Action {
        Invoke-NetworkMaintenance -Level $Level
    } | Out-Null
    if ($Level -eq 'Aggressive') {
        Invoke-EngineStep -Name 'OPT_WindowsUpdate' -Title 'Wartung - Windows-Update-Komponenten' -Progress 98 -Action {
            Reset-WindowsUpdateComponent
        } | Out-Null
    }
    Invoke-EngineStep -Name 'OPT_Autostart' -Title 'Wartung - Autostart (nur Bericht)' -Progress 99 -Action {
        Get-StartupReport
    } | Out-Null
}

#endregion

#region ============================ Bericht ============================

function Get-OverallStatus {
    $steps = @($script:State.steps)
    foreach ($s in $steps) { if ($s.status -eq 'FAILED') { return 'FAILED' } }
    foreach ($s in $steps) { if ($s.status -eq 'REPAIRED' -or $s.status -eq 'REBOOT') { return 'REPAIRED' } }
    if ($script:State.restartRequired) { return 'REPAIRED' }
    foreach ($s in $steps) { if ($s.status -eq 'WARNING') { return 'WARNING' } }
    return 'HEALTHY'
}

function Write-RepairReport {
    param([string]$RunDir)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('=' * 68))
    [void]$sb.AppendLine(' RepairCenter - Ergebnisbericht')
    [void]$sb.AppendLine(('=' * 68))
    [void]$sb.AppendLine(('Computer        : {0}' -f $script:State.computer))
    [void]$sb.AppendLine(('Betriebssystem  : {0}' -f $script:State.os))
    [void]$sb.AppendLine(('Modus           : {0}   Wartungsstufe: {1}' -f $script:State.mode, $script:State.optimize))
    [void]$sb.AppendLine(('Lauf-ID         : {0}' -f $script:State.runId))
    [void]$sb.AppendLine(('Dauer           : {0} s' -f $script:State.durationSec))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('{0,-26} {1,-10} {2,8}  {3}' -f 'Schritt', 'Status', 'Dauer(s)', 'Detail'))
    [void]$sb.AppendLine(('-' * 68))
    foreach ($s in @($script:State.steps)) {
        [void]$sb.AppendLine(('{0,-26} {1,-10} {2,8}  {3}' -f $s.name, $s.status, $s.durationSec, $s.detail))
    }
    [void]$sb.AppendLine(('-' * 68))
    [void]$sb.AppendLine(('Gesamtstatus    : {0}' -f $script:State.overall))
    [void]$sb.AppendLine(('Neustart noetig : {0}' -f $(if ($script:State.restartRequired) { 'JA' } else { 'nein' })))
    foreach ($r in @($script:State.restartReasons)) { [void]$sb.AppendLine(('                  - {0}' -f $r)) }
    if ($null -ne $script:State.freeSpaceEndGB) {
        [void]$sb.AppendLine(('Freier Speicher : {0} GB (Differenz {1:+0.00;-0.00;0} GB)' -f $script:State.freeSpaceEndGB, $script:State.reclaimedGB))
    }
    [void]$sb.AppendLine('')
    if (@($script:State.findings).Count -gt 0) {
        [void]$sb.AppendLine('Hinweise:')
        foreach ($f in @($script:State.findings)) { [void]$sb.AppendLine(('  [{0,-5}] {1}' -f $f.level, $f.text)) }
    }
    $path = Join-Path $RunDir 'report.txt'
    $sb.ToString() | Set-Content -LiteralPath $path -Encoding UTF8 -WhatIf:$false
    return $path
}

#endregion

#region =========================== Hauptlauf ===========================

function Invoke-RepairRun {
    <#
    .SYNOPSIS
        Fuehrt einen kompletten Lauf aus und veroeffentlicht den Zustand.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('Quick', 'Diagnose', 'Repair', 'Full')][string]$Mode = 'Repair',
        [ValidateSet('None', 'Safe', 'Standard', 'Aggressive')][string]$Optimize = 'Safe',
        [string]$LogRoot = 'C:\RepairLogs',
        [string]$RunId,
        [int]$TempFileAgeDays = 2,
        [int]$MinFreeSpaceGB = 8,
        [switch]$SkipDism,
        [switch]$SkipSfc,
        [switch]$SkipDisk,
        [switch]$NoEscalate,
        [switch]$NoRestorePoint,
        [switch]$Demo,
        [ValidateSet('Healthy', 'Repaired', 'Escalation', 'Failed', 'Preflight')]
        [string]$DemoScenario = 'Repaired'
    )

    if (-not $RunId) { $RunId = (Get-Date -Format 'yyyyMMdd-HHmmss') }
    $script:Demo = [bool]$Demo
    $script:DemoScenario = $DemoScenario
    $script:DemoPass = 0
    $runDir = Join-Path (Join-Path $LogRoot 'runs') $RunId
    if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Path $runDir -Force -WhatIf:$false | Out-Null }

    $script:StatePath = Join-Path $runDir 'state.json'
    $script:ToolLog = Join-Path $runDir 'tools.log'
    # Kopfzeile sofort schreiben: so existiert die Datei auch dann, wenn kein
    # externes Werkzeug aufgerufen wird (Demomodus, reine Analyse).
    try {
        Set-Content -LiteralPath $script:ToolLog -Encoding UTF8 -Force -WhatIf:$false -Value @(
            ('# RepairCenter - Rohausgabe der Systemwerkzeuge'),
            ('# Lauf {0} | Modus {1} | Wartung {2} | {3:yyyy-MM-dd HH:mm:ss}' -f $RunId, $Mode, $Optimize, (Get-Date)),
            ''
        )
    }
    catch { Write-Verbose 'tools.log nicht anlegbar.' }
    $script:CancelFile = Join-Path $runDir 'cancel.flag'
    $script:State = New-RepairState -RunId $RunId -Mode $Mode -Optimize $Optimize -WhatIfMode ([bool]$WhatIfPreference) -Demo $script:Demo
    if ($script:Demo) { $script:State.demoScenario = $DemoScenario }
    Save-RepairState -Force

    # Diagnose ist strikt lesend.
    if ($Mode -eq 'Diagnose' -and $Optimize -ne 'None') {
        $Optimize = 'None'
        $script:State.optimize = 'None'
        Write-EngineLog -Kind warn -Text 'Diagnosemodus ist strikt lesend - Wartung deaktiviert.'
    }

    $started = Get-Date
    Write-EngineLog -Kind section -Text ('RepairCenter - Modus {0}, Wartung {1}{2}' -f $Mode, $Optimize, $(if ($script:Demo) { ' [DEMO]' } else { '' }))

    try {
        $pre = Invoke-EngineStep -Name 'Preflight' -Title 'Preflight - Umgebungspruefung' -Progress 5 -Action {
            Invoke-PreflightStage -MinFreeSpaceGB $MinFreeSpaceGB
        }
        if ($pre.status -ne 'FAILED') {
            Invoke-RepairStage -Mode $Mode -SkipDism ([bool]$SkipDism) -SkipSfc ([bool]$SkipSfc)
            if (-not $SkipSfc -and -not (Test-EngineCancelled)) {
                Invoke-EngineStep -Name 'CBS_Analyse' -Title 'Auswertung - CBS-Protokoll' -Progress 65 -Action {
                    Get-SfcOutcome -Since $started -SfcStepName 'SFC' -ExportTag 'SFC' -RunDir $runDir
                } | Out-Null
            }
            if (-not (Test-EngineCancelled)) {
                Invoke-EscalationStage -Mode $Mode -RunDir $runDir -SkipDism ([bool]$SkipDism) -SkipSfc ([bool]$SkipSfc) -NoEscalate ([bool]$NoEscalate)
            }
            if (-not (Test-EngineCancelled)) { Invoke-VerifyStage -Mode $Mode -SkipDisk ([bool]$SkipDisk) }
            if (Test-EngineCancelled) {
                Write-EngineLog -Kind warn -Text 'Abbruch angefordert - die weiteren Abschnitte werden uebersprungen.'
            }
            else {
                Invoke-OptimizeStage -Level $Optimize -TempFileAgeDays $TempFileAgeDays -LogRoot $LogRoot `
                    -SkipDisk ([bool]$SkipDisk) -NoRestorePoint ([bool]$NoRestorePoint)
            }
        }
        else {
            Write-EngineLog -Kind error -Text 'Preflight blockiert die Ausfuehrung - keine Aenderungen vorgenommen.'
        }
    }
    catch {
        Write-EngineLog -Kind error -Text ('Unerwarteter Fehler: {0}' -f $_.Exception.Message)
        Add-EngineStep -Name 'Laufzeitfehler' -Status 'FAILED' -Detail $_.Exception.Message | Out-Null
    }

    $end = Get-Date
    $script:State.endTime = $end.ToString('o')
    $script:State.durationSec = [math]::Round(($end - $started).TotalSeconds, 0)
    $script:State.freeSpaceEndGB = Get-FreeSpaceGB
    if ($null -ne $script:State.freeSpaceStartGB -and $null -ne $script:State.freeSpaceEndGB) {
        $script:State.reclaimedGB = [math]::Round($script:State.freeSpaceEndGB - $script:State.freeSpaceStartGB, 2)
    }
    $script:State.overall = Get-OverallStatus
    if (Test-EngineCancelled) {
        # Ein abgebrochener Lauf darf nie wie ein regulaeres Ergebnis
        # aussehen - sonst haelt man ihn spaeter faelschlich fuer vollstaendig.
        $script:State.cancelled = $true
        $script:State.overall = 'CANCELLED'
        Add-EngineStep -Name 'Abbruch' -Status 'WARNING' -Detail 'Vom Benutzer abgebrochen' | Out-Null
        Write-EngineLog -Kind warn -Text 'Lauf wurde vom Benutzer abgebrochen - das Ergebnis ist unvollstaendig.'
    }
    $script:State.status = 'done'
    $script:State.progress = 100
    $script:State.currentStep = ''
    if ($script:State.cancelled) { $script:State.exitCode = 2 }
    elseif ($script:State.overall -eq 'HEALTHY') { $script:State.exitCode = 0 }
    elseif ($script:State.overall -eq 'REPAIRED') { $script:State.exitCode = 1 }
    elseif ($script:State.overall -eq 'WARNING') { $script:State.exitCode = 2 }
    else { $script:State.exitCode = 3 }

    try { $script:State.reportFile = Write-RepairReport -RunDir $runDir }
    catch { Write-EngineLog -Kind warn -Text ('Bericht nicht schreibbar: {0}' -f $_.Exception.Message) }
    $script:State.jsonFile = $script:StatePath
    Save-RepairState -Force

    Write-EngineLog -Kind (Get-LogKindForStatus $script:State.overall) -Text ('Gesamtstatus: {0}' -f $script:State.overall)
    return ([pscustomobject]$script:State)
}

#endregion

Export-ModuleMember -Function `
    Invoke-RepairRun, Get-SystemSnapshot, Test-AdminRights, Get-CbsSfcSummary, New-SafetyRestorePoint, `
    Get-OverallStatus, Format-ByteSize, Clear-FolderContent, Resolve-SystemTool, `
    Invoke-NativeCommand, Get-PendingRebootReason, Get-FreeSpaceGB, New-RepairState, New-RunIdentifier
