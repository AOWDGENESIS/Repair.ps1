#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Runner
 Version: 1.5.1
 Fuehrt genau einen Lauf aus und schreibt den Zustand nach
 <LogRoot>\runs\<RunId>\state.json. Wird vom Backend als eigener Prozess
 gestartet, damit die Oberflaeche nie blockiert.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$RunId,
    [ValidateSet('Quick', 'Diagnose', 'Repair', 'Full')][string]$Mode = 'Repair',
    [ValidateSet('None', 'Safe', 'Standard', 'Aggressive')][string]$Optimize = 'Safe',
    [string]$LogRoot = 'C:\RepairLogs',
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

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'RepairEngine.psm1') -Force -DisableNameChecking

if ($env:OS -ne 'Windows_NT' -and $LogRoot -eq 'C:\RepairLogs') {
    $LogRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'RepairLogs'
}
$runDir = Join-Path (Join-Path $LogRoot 'runs') $RunId
# -WhatIf:$false: das Laufverzeichnis und das Sitzungsprotokoll gehoeren zur
# Buchfuehrung. Ohne die Ausnahme erzeugt "Nur simulieren" keinerlei Spur.
if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Path $runDir -Force -WhatIf:$false | Out-Null }

$transcript = Join-Path $runDir 'transcript.log'
$transcriptStarted = $false
try {
    Start-Transcript -Path $transcript -Force -ErrorAction Stop -WhatIf:$false | Out-Null
    $transcriptStarted = $true
}
catch { Write-Warning ('Transcript nicht startbar: {0}' -f $_.Exception.Message) }

$exitCode = 3
try {
    $result = Invoke-RepairRun -Mode $Mode -Optimize $Optimize -LogRoot $LogRoot -RunId $RunId `
        -TempFileAgeDays $TempFileAgeDays -MinFreeSpaceGB $MinFreeSpaceGB `
        -SkipDism:$SkipDism -SkipSfc:$SkipSfc -SkipDisk:$SkipDisk `
        -NoEscalate:$NoEscalate -NoRestorePoint:$NoRestorePoint -Demo:$Demo -DemoScenario $DemoScenario
    if ($null -ne $result.exitCode) { $exitCode = [int]$result.exitCode }
}
catch {
    Write-Error ('Lauf fehlgeschlagen: {0}' -f $_.Exception.Message)
    $exitCode = 3
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose 'Transcript bereits beendet.' }
    }
}

exit $exitCode
