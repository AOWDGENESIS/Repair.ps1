#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Auftrag der Datentraegerverwaltung
 Version: 1.5.1
 Fuehrt genau einen Vorgang aus (Formatieren, Dateisystem wechseln oder
 Loeschen) und schreibt den Fortschritt nach
 <LogRoot>\diskjobs\<JobId>\state.json.
 Laeuft als eigener Prozess, damit die Oberflaeche waehrend eines
 stundenlangen Loeschvorgangs bedienbar bleibt.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][ValidateSet('Format', 'Convert', 'Wipe', 'Rescue', 'Analyze', 'FileScan', 'FileRepair', 'Archive', 'CopyFolder')][string]$Action,
    [string]$LogRoot = 'C:\RepairLogs',

    [int]$DiskNumber = -1,
    [string]$DriveLetter = '',
    [ValidateSet('NTFS', 'exFAT', 'FAT32', 'ReFS')][string]$FileSystem = 'NTFS',
    [string]$Label = '',
    [switch]$Full,
    [int]$AllocationUnitSize = 0,
    [switch]$AllowDataLoss,

    [ValidateSet('Auto', 'CryptoErase', 'Trim', 'Zero', 'ZeroVerify')][string]$Strategy = 'Auto',
    [string]$Confirmation = '',
    [int]$BufferMiB = 32,
    [int]$QueueDepth = 4,

    # Datenrettung vor dem Loeschen
    [string]$RescueTarget = '',
    [ValidateSet('Copy', 'Move')][string]$RescueMode = 'Copy',
    [int]$RescueThreads = 32,
    [switch]$RescueUnbuffered,

    # Analyse und Dateipruefung
    [int]$Samples = 64,
    [switch]$SkipSurface,
    [string]$Path = '',
    [switch]$Deep,
    [string]$ScanJobId = '',
    [ValidateSet('Auto', 'ShadowCopy', 'SystemFile', 'ReportOnly')][string]$RepairStrategy = 'Auto',

    # Packen und Uebertragen
    [string]$Target = '',
    [ValidateSet('Zip', 'SevenZip', 'Rar')][string]$ArchiveFormat = 'Zip',
    [ValidateSet('Fastest', 'Normal', 'Maximum')][string]$ArchiveLevel = 'Normal',
    [ValidateSet('Copy', 'Move')][string]$CopyMode = 'Copy',
    [int]$Threads = 32,
    [switch]$Unbuffered,

    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'DiskManager.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'DiskAnalysis.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'FileIntegrity.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'ArchiveManager.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'RepairEngine.psm1') -Force -DisableNameChecking

if ($env:OS -ne 'Windows_NT' -and $LogRoot -eq 'C:\RepairLogs') {
    $LogRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'RepairLogs'
}
$jobDir = Join-Path (Join-Path $LogRoot 'diskjobs') $JobId
if (-not (Test-Path -LiteralPath $jobDir)) { New-Item -ItemType Directory -Path $jobDir -Force -WhatIf:$false | Out-Null }
$statePath = Join-Path $jobDir 'state.json'

$state = [ordered]@{
    jobId       = $JobId
    action      = $Action
    diskNumber  = $DiskNumber
    driveLetter = $DriveLetter
    fileSystem  = $FileSystem
    strategy    = $Strategy
    demo        = [bool]$Demo
    stage       = ''
    stages      = @()
    rescue      = $null
    analysis    = $null
    scan        = $null
    repair      = $null
    archive     = $null
    copy        = $null
    status      = 'running'
    ok          = $false
    percent     = 0
    bytesDone   = 0
    bytesTotal  = 0
    throughput  = 0
    secondsLeft = $null
    startTime   = (Get-Date).ToString('o')
    endTime     = $null
    durationSec = 0
    detail      = ''
    log         = @()
}

$script:LastFlush = [datetime]::MinValue

function Save-JobState {
    param([switch]$Force)
    $now = Get-Date
    if (-not $Force -and ($now - $script:LastFlush).TotalMilliseconds -lt 400) { return }
    $script:LastFlush = $now
    try {
        $json = ([pscustomobject]$state) | ConvertTo-Json -Depth 5
        if ([string]::IsNullOrWhiteSpace($json) -or $json.Trim().Length -lt 5) { return }
        $tmp = $statePath + '.tmp'
        # Buchfuehrung, keine Systemaenderung - siehe RepairEngine.
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force -WhatIf:$false
        Move-Item -LiteralPath $tmp -Destination $statePath -Force -WhatIf:$false
    }
    catch { Write-Verbose 'Zustand nicht speicherbar.' }
}

function Write-JobLog {
    param([string]$Text, [string]$Kind = 'info')
    $entry = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss'); kind = $Kind; text = $Text }
    $list = @($state.log) + , $entry
    if ($list.Count -gt 500) { $list = $list[($list.Count - 500)..($list.Count - 1)] }
    $state.log = $list
    Write-Host ('  ' + $Text)
    Save-JobState
}

Save-JobState -Force
Write-JobLog -Kind section -Text ('Auftrag {0} gestartet ({1})' -f $Action, $(if ($Demo) { 'Demo' } else { 'produktiv' }))

function Set-JobStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Vermerkt nur den Abschnitt in der Zustandsdatei.')]
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $state.stage = $Name
    $list = @($state.stages)
    $found = $false
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i].name -eq $Name) { $list[$i].status = $Status; $list[$i].detail = $Detail; $found = $true }
    }
    if (-not $found) { $list += , ([ordered]@{ name = $Name; status = $Status; detail = $Detail }) }
    $state.stages = $list
    Save-JobState -Force
}

# Fortschrittsmeldung, die zwischen Sicherung und Loeschen unterscheidet
$progressHandler = {
    param($p)
    $state.percent = $p.percent
    $state.bytesDone = $p.bytesDone
    $state.bytesTotal = $p.bytesTotal
    $state.throughput = $p.throughput
    $state.secondsLeft = $p.secondsLeft
    if ($p.stage) { $state.stage = [string]$p.stage }
    Save-JobState
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    # ---- Schritt 1: Daten sichern, falls gewuenscht -------------------
    if ($RescueTarget -and ($Action -eq 'Wipe' -or $Action -eq 'Rescue')) {
        Set-JobStage -Name 'rescue' -Status 'running'
        Write-JobLog ('Sichere Daten nach "{0}" ({1}, {2} Faeden{3})' -f $RescueTarget,
            $(if ($RescueMode -eq 'Move') { 'verschieben' } else { 'kopieren' }), $RescueThreads,
            $(if ($RescueUnbuffered) { ', ungepuffert' } else { '' }))

        $rescue = Invoke-DataRescue -DiskNumber $DiskNumber -TargetPath $RescueTarget -Mode $RescueMode `
            -Threads $RescueThreads -Unbuffered:$RescueUnbuffered -OnProgress $progressHandler -Demo:$Demo -Confirm:$false

        $state.rescue = $rescue
        if (-not $rescue.ok) {
            Set-JobStage -Name 'rescue' -Status 'FAILED' -Detail ([string]$rescue.detail)
            $state.ok = $false
            $state.detail = ('Datensicherung fehlgeschlagen - es wurde NICHTS geloescht. {0}' -f $rescue.detail)
            Write-JobLog -Kind error -Text $state.detail
            throw $state.detail
        }
        Set-JobStage -Name 'rescue' -Status 'PASS' -Detail ([string]$rescue.detail)
        Write-JobLog -Kind ok -Text ('Datensicherung abgeschlossen: {0}' -f $rescue.detail)
        $state.percent = 0
        Save-JobState -Force
    }

    if ($Action -eq 'Archive') {
        Set-JobStage -Name 'archive' -Status 'running'
        Write-JobLog ('Packe "{0}" nach "{1}" ({2}, Stufe {3})' -f $Path, $Target, $ArchiveFormat, $ArchiveLevel)
        $a = New-FolderArchive -Source $Path -Target $Target -Format $ArchiveFormat -Level $ArchiveLevel `
            -OnProgress $progressHandler -Demo:$Demo -Confirm:$false
        $state.archive = $a
        $state.ok = [bool]$a.ok
        $state.detail = [string]$a.detail
        Set-JobStage -Name 'archive' -Status $(if ($a.ok) { 'PASS' } else { 'FAILED' }) -Detail ([string]$a.detail)
    }
    elseif ($Action -eq 'CopyFolder') {
        Set-JobStage -Name 'copy' -Status 'running'
        Write-JobLog ('{0} "{1}" nach "{2}" ({3} Faeden{4})' -f $(if ($CopyMode -eq 'Move') { 'Verschiebe' } else { 'Kopiere' }),
            $Path, $Target, $Threads, $(if ($Unbuffered) { ', ungepuffert' } else { '' }))
        $c = Copy-FolderFast -Source $Path -Target $Target -Mode $CopyMode -Threads $Threads `
            -Unbuffered:$Unbuffered -OnProgress $progressHandler -Demo:$Demo -Confirm:$false
        $state.copy = $c
        $state.ok = [bool]$c.ok
        $state.detail = [string]$c.detail
        Set-JobStage -Name 'copy' -Status $(if ($c.ok) { 'PASS' } else { 'FAILED' }) -Detail ([string]$c.detail)
    }
    elseif ($Action -eq 'Analyze') {
        Set-JobStage -Name 'analyze' -Status 'running'
        Write-JobLog ('Analysiere Datentraeger {0} mit {1} Leseproben{2}' -f $DiskNumber, $Samples,
            $(if ($SkipSurface) { ' (ohne Oberflaechenpruefung)' } else { '' }))
        $a = Invoke-DiskAnalysis -DiskNumber $DiskNumber -Samples $Samples -SkipSurface:$SkipSurface `
            -OnProgress $progressHandler -Demo:$Demo
        $state.analysis = $a
        $state.ok = [bool]$a.ok
        if ($a.ok) {
            $state.detail = ('{0}: {1}' -f $a.friendlyName, $a.verdict.verdict)
            Write-JobLog -Kind $(if ($a.verdict.level -ge 2) { 'error' } elseif ($a.verdict.level -eq 1) { 'warn' } else { 'ok' }) `
                -Text ('Bewertung: {0}' -f $a.verdict.verdict)
            foreach ($g in @($a.verdict.reasons)) { Write-JobLog -Kind $(if ($g.level -ge 2) { 'warn' } else { 'info' }) -Text ('  ' + $g.text) }
            Write-JobLog -Text ('Empfehlung: ' + $a.verdict.recommendation)
        }
        else { $state.detail = [string]$a.detail }
        Set-JobStage -Name 'analyze' -Status $(if ($state.ok) { 'PASS' } else { 'FAILED' }) -Detail ([string]$state.detail)
    }
    elseif ($Action -eq 'FileScan') {
        Set-JobStage -Name 'scan' -Status 'running'
        Write-JobLog ('Suche defekte Dateien in "{0}"{1}' -f $Path, $(if ($Deep) { ' (jede Datei vollstaendig lesen)' } else { ' (Kopf und Ende pruefen)' }))
        $sc = Invoke-FileIntegrityScan -Path $Path -Deep:$Deep -OnProgress $progressHandler -Demo:$Demo
        $state.scan = $sc
        $state.ok = [bool]$sc.ok
        $state.detail = [string]$sc.detail
        if ($sc.ok) {
            foreach ($f in @($sc.findings)) {
                Write-JobLog -Kind warn -Text ('{0} - {1}' -f (Split-Path ([string]$f.path) -Leaf), $f.reason)
            }
            if (@($sc.findings).Count -eq 0) { Write-JobLog -Kind ok -Text 'Keine defekten Dateien gefunden.' }
        }
        Set-JobStage -Name 'scan' -Status $(if ($state.ok) { 'PASS' } else { 'FAILED' }) -Detail ([string]$state.detail)
    }
    elseif ($Action -eq 'FileRepair') {
        Set-JobStage -Name 'repair' -Status 'running'
        $befunde = @()
        if ($ScanJobId) {
            $quelle = Join-Path (Join-Path $LogRoot 'diskjobs') $ScanJobId
            $datei = Join-Path $quelle 'state.json'
            if (Test-Path -LiteralPath $datei) {
                try {
                    $alt = Get-Content -LiteralPath $datei -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($alt.scan -and $alt.scan.findings) { $befunde = @($alt.scan.findings) }
                }
                catch { Write-JobLog -Kind warn -Text 'Befunde der Suche nicht lesbar.' }
            }
        }
        if (@($befunde).Count -eq 0) {
            $state.ok = $false
            $state.detail = 'Keine Befunde zum Reparieren - bitte zuerst suchen lassen.'
            Write-JobLog -Kind warn -Text $state.detail
        }
        else {
            Write-JobLog ('Repariere {0} Datei(en), Verfahren {1}' -f @($befunde).Count, $RepairStrategy)
            $rp = Invoke-FileRepairBatch -Findings $befunde -Strategy $RepairStrategy -OnProgress $progressHandler -Demo:$Demo -Confirm:$false
            $state.repair = $rp
            $state.ok = [bool]$rp.ok
            $state.detail = [string]$rp.detail
            foreach ($r in @($rp.results)) {
                Write-JobLog -Kind $(if ($r.ok) { 'ok' } else { 'warn' }) -Text ('{0}: {1}' -f (Split-Path ([string]$r.path) -Leaf), $r.detail)
            }
        }
        Set-JobStage -Name 'repair' -Status $(if ($state.ok) { 'PASS' } else { 'FAILED' }) -Detail ([string]$state.detail)
    }
    elseif ($Action -eq 'Rescue') {
        $state.ok = $true
        if ($state.rescue) { $state.detail = [string]$state.rescue.detail }
        else { $state.detail = 'Kein Ziel angegeben - nichts zu tun.'; $state.ok = $false }
    }
    elseif ($Action -eq 'Format') {
        Write-JobLog ('Formatiere {0}: mit {1}{2}' -f $DriveLetter, $FileSystem, $(if ($Full) { ' (vollstaendig)' } else { ' (schnell)' }))
        $r = Format-ManagedVolume -DriveLetter $DriveLetter -FileSystem $FileSystem -Label $Label `
            -Full:$Full -AllocationUnitSize $AllocationUnitSize -Demo:$Demo -Confirm:$false
        $state.ok = [bool]$r.ok
        $state.detail = [string]$r.detail
    }
    elseif ($Action -eq 'Convert') {
        Write-JobLog ('Wechsle Dateisystem von {0}: nach {1}' -f $DriveLetter, $FileSystem)
        $r = Convert-VolumeFileSystem -DriveLetter $DriveLetter -TargetFileSystem $FileSystem -Label $Label `
            -AllowDataLoss:$AllowDataLoss -Demo:$Demo -Confirm:$false
        $state.ok = [bool]$r.ok
        $state.detail = [string]$r.detail
        if ($r.lossless) { Write-JobLog -Kind ok -Text 'Verlustfreier Weg verwendet (convert.exe).' }
    }
    else {
        Set-JobStage -Name 'wipe' -Status 'running'
        $disks = @(Get-DiskInventory -Demo:$Demo)
        $disk = $disks | Where-Object { $_.number -eq $DiskNumber } | Select-Object -First 1
        if ($disk) {
            $state.bytesTotal = [long]$disk.sizeBytes
            $eff = Get-WipeStrategy -Disk $disk -Requested $Strategy
            $est = Get-WipeEstimate -SizeBytes $disk.sizeBytes -Strategy $eff -BusType $disk.busType -MediaType $disk.mediaType
            $state.strategy = $eff
            Write-JobLog ('Datentraeger {0}: {1} ({2} GB, {3}/{4})' -f $disk.number, $disk.friendlyName,
                [math]::Round($disk.sizeBytes / 1GB, 1), $disk.busType, $disk.mediaType)
            Write-JobLog ('Verfahren {0} - geschaetzte Dauer {1}. {2}' -f $eff, (Format-Duration $est.seconds), $est.note)
            Save-JobState -Force
        }

        $state.stage = 'wipe'
        $r = Clear-DiskContent -DiskNumber $DiskNumber -Strategy $Strategy -Confirmation $Confirmation `
            -BufferMiB $BufferMiB -QueueDepth $QueueDepth -OnProgress $progressHandler -Demo:$Demo -Confirm:$false
        $state.ok = [bool]$r.ok
        $state.detail = [string]$r.detail
        if ($r.strategy) { $state.strategy = [string]$r.strategy }
        if ($r.throughput) { $state.throughput = $r.throughput }
        Set-JobStage -Name 'wipe' -Status $(if ($r.ok) { 'PASS' } else { 'FAILED' }) -Detail ([string]$r.detail)
    }
}
catch {
    $state.ok = $false
    $state.detail = $_.Exception.Message
    Write-JobLog -Kind error -Text ('Fehlgeschlagen: {0}' -f $_.Exception.Message)
}
finally { $sw.Stop() }

$state.status = 'done'
$state.percent = 100
$state.endTime = (Get-Date).ToString('o')
$state.durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Write-JobLog -Kind $(if ($state.ok) { 'ok' } else { 'error' }) -Text $state.detail
Save-JobState -Force

if ($state.ok) { exit 0 }
exit 3
