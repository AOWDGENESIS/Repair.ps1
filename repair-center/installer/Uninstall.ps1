#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Deinstallation
 Version: 1.5.1 | MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Entfernt RepairCenter - Programm, Verknuepfungen, Eintrag und Aufgabe.

.DESCRIPTION
    Die Berichte unter C:\RepairLogs bleiben absichtlich erhalten. Sie
    sind oft der einzige Nachweis, was an einem Rechner gemacht wurde.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallDir = '',
    [switch]$KeepLogs = $true,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Zeile {
    param([string]$Text, [string]$Art = 'info')
    $farbe = 'Gray'
    if ($Art -eq 'ok') { $farbe = 'Green' }
    elseif ($Art -eq 'warn') { $farbe = 'Yellow' }
    elseif ($Art -eq 'error') { $farbe = 'Red' }
    Write-Host ('  ' + $Text) -ForegroundColor $farbe
}
function Wait-Taste {
    if ($Quiet -or $env:RC_NONINTERACTIVE -eq '1' -or -not [Environment]::UserInteractive) { return }
    Write-Host ''
    Write-Zeile -Art warn -Text 'Zum Schliessen die Eingabetaste druecken.'
    try { [void](Read-Host) } catch { Start-Sleep -Seconds 15 }
}

$istWindows = ($env:OS -eq 'Windows_NT')
if (-not $InstallDir) {
    $InstallDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

Write-Host ''
Write-Zeile -Art warn -Text ('RepairCenter wird entfernt: ' + $InstallDir)

# Laeuft der Dienst noch?
if ($istWindows) {
    try {
        $laufend = Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*RepairCenter.Server.ps1*' }
        foreach ($p in @($laufend)) {
            Write-Zeile -Art warn -Text ('Beende laufenden Dienst (PID {0}) ...' -f $p.ProcessId)
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { Write-Verbose 'schon beendet' }
        }
    }
    catch { Write-Verbose 'Prozessliste nicht lesbar.' }

    try {
        & (Join-Path $env:SystemRoot 'System32\schtasks.exe') '/Delete' '/TN' 'RepairCenter\Woechentliche Wartung' '/F' 2>&1 | Out-Null
        Write-Zeile -Text 'Geplante Wartung entfernt (falls vorhanden).'
    }
    catch { Write-Verbose 'Aufgabe nicht vorhanden.' }

    try {
        $schluessel = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RepairCenter'
        if (Test-Path -LiteralPath $schluessel) { Remove-Item -LiteralPath $schluessel -Recurse -Force }
        Write-Zeile -Text 'Eintrag aus "Apps & Features" entfernt.'
    }
    catch { Write-Zeile -Art warn -Text ('Eintrag nicht entfernbar: ' + $_.Exception.Message) }

    foreach ($pfad in @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\RepairCenter'),
            (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'RepairCenter.lnk'))) {
        try { if (Test-Path -LiteralPath $pfad) { Remove-Item -LiteralPath $pfad -Recurse -Force } }
        catch { Write-Verbose 'Verknuepfung nicht entfernbar.' }
    }
    Write-Zeile -Text 'Verknuepfungen entfernt.'
}

if ($PSCmdlet.ShouldProcess($InstallDir, 'Programmordner entfernen')) {
    try {
        # Das eigene Verzeichnis laesst sich nicht loeschen, waehrend man
        # darin steht - deshalb zuerst woanders hin.
        Set-Location ([System.IO.Path]::GetTempPath())
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        Write-Zeile -Art ok -Text 'Programmordner entfernt.'
    }
    catch {
        Write-Zeile -Art warn -Text ('Programmordner konnte nicht vollstaendig entfernt werden: ' + $_.Exception.Message)
        Write-Zeile -Text ('Bitte von Hand loeschen: ' + $InstallDir)
    }
}

Write-Host ''
Write-Zeile -Art ok -Text 'Fertig. Die Berichte unter C:\RepairLogs wurden bewusst behalten.'
Wait-Taste
exit 0
