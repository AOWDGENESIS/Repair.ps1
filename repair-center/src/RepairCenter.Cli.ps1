#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Kommandozeile
 Version: 1.5.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 Dieselbe Engine wie die Oberflaeche - ohne Weboberflaeche, fuer
 Taskplaner, Fernwartung und Skripte.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Windows reparieren, diagnostizieren und warten.

.EXAMPLE
    .\RepairCenter.Cli.ps1
.EXAMPLE
    .\RepairCenter.Cli.ps1 -Mode Diagnose
.EXAMPLE
    .\RepairCenter.Cli.ps1 -Mode Full -Optimize Standard
.EXAMPLE
    .\RepairCenter.Cli.ps1 -Optimize Aggressive -WhatIf

.NOTES
    Exitcodes: 0 HEALTHY | 1 REPAIRED | 2 WARNING | 3 FAILED
               4 keine Administratorrechte | 5 UAC abgebrochen
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Konsolenwerkzeug: farbige Statusausgabe ist gewollt.')]
param(
    [ValidateSet('Quick', 'Diagnose', 'Repair', 'Full')][string]$Mode = 'Repair',
    [ValidateSet('None', 'Safe', 'Standard', 'Aggressive')][string]$Optimize = 'Safe',
    [string]$LogRoot = 'C:\RepairLogs',
    [int]$TempFileAgeDays = 2,
    [switch]$SkipDism,
    [switch]$SkipSfc,
    [switch]$SkipDisk,
    [switch]$NoEscalate,
    [switch]$NoRestorePoint,
    [switch]$Demo,
    [ValidateSet('Healthy', 'Repaired', 'Escalation', 'Failed', 'Preflight')]
    [string]$DemoScenario = 'Repaired',
    [switch]$NoElevate,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

#region ---------------- Automatische Rechteerhoehung (UAC) ----------------

function Test-IsAdministrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-RelaunchArgumentList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters)
    $list = New-Object System.Collections.ArrayList
    foreach ($entry in $BoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'Elevated' -or $entry.Key -eq 'NoElevate') { continue }
        $value = $entry.Value
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { [void]$list.Add('-' + $entry.Key) }
            continue
        }
        $text = ([string]$value).TrimEnd('\').Replace('"', '`"')
        [void]$list.Add('-' + $entry.Key)
        [void]$list.Add('"' + $text + '"')
    }
    if ($WhatIfPreference -and -not $BoundParameters.ContainsKey('WhatIf')) { [void]$list.Add('-WhatIf') }
    return $list
}

if ($env:OS -eq 'Windows_NT' -and -not (Test-IsAdministrator)) {
    if ($NoElevate) { Write-Warning 'Administratorrechte fehlen (-NoElevate).'; exit 4 }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { Write-Warning 'Bitte als .ps1-Datei starten.'; exit 4 }

    Write-Host ''
    Write-Host '  Administratorrechte erforderlich - starte neu (UAC) ...' -ForegroundColor Yellow
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID).Path } catch { $psExe = $null }
    if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = Join-Path $PSHOME 'powershell.exe' }

    $argumentList = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))) { [void]$argumentList.Add($a) }
    foreach ($a in (Get-RelaunchArgumentList -BoundParameters $PSBoundParameters)) { [void]$argumentList.Add($a) }
    [void]$argumentList.Add('-Elevated')
    try {
        $child = Start-Process -FilePath $psExe -ArgumentList $argumentList -Verb RunAs -PassThru -Wait -ErrorAction Stop
        exit $child.ExitCode
    }
    catch {
        Write-Warning 'Rechteerhoehung abgebrochen oder fehlgeschlagen (UAC).'
        exit 5
    }
}

#endregion

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'RepairEngine.psm1') -Force -DisableNameChecking

if ($env:OS -ne 'Windows_NT' -and $LogRoot -eq 'C:\RepairLogs') {
    $LogRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'RepairLogs'
}

$result = Invoke-RepairRun -Mode $Mode -Optimize $Optimize -LogRoot $LogRoot `
    -TempFileAgeDays $TempFileAgeDays -SkipDism:$SkipDism -SkipSfc:$SkipSfc -SkipDisk:$SkipDisk `
    -NoEscalate:$NoEscalate -NoRestorePoint:$NoRestorePoint -Demo:$Demo -DemoScenario $DemoScenario

Write-Host ''
Write-Host ('  Gesamtstatus : {0}' -f $result.overall)
Write-Host ('  Neustart     : {0}' -f $(if ($result.restartRequired) { 'JA' } else { 'nein' }))
Write-Host ('  Bericht      : {0}' -f $result.reportFile)
Write-Host ''

$exitCode = 3
if ($null -ne $result.exitCode) { $exitCode = [int]$result.exitCode }

if ($Elevated -and [Environment]::UserInteractive) {
    try {
        Write-Host '  Fenster bleibt offen - zum Schliessen Enter druecken.' -ForegroundColor DarkGray
        [void](Read-Host)
    }
    catch { Write-Verbose 'Keine interaktive Eingabe moeglich.' }
}

exit $exitCode
