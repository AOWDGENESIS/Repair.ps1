#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Statische Pruefung mit PSScriptAnalyzer
 Version: 1.5.1 | MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Prueft src, tools und tests mit PSScriptAnalyzer.

.DESCRIPTION
    Warum es dieses Skript gibt: ein direkter Aufruf von
    Invoke-ScriptAnalyzer meldet "keine Befunde", wenn das Modul gar nicht
    geladen ist - die Fehlermeldung geht im Rauschen unter und die Pruefung
    besteht scheinbar. Genau das ist in der Entwicklung passiert.

    Dieses Skript macht drei Dinge anders:
      1. Es bricht ab, wenn das Modul fehlt, statt Erfolg zu melden.
      2. Es nennt die geladene Version.
      3. Es prueft sich selbst: eine bewusst fehlerhafte Datei muss
         Befunde liefern. Tut sie es nicht, arbeitet die Pruefung nicht
         und das Skript bricht ab.

.EXAMPLE
    .\tools\Invoke-Analyzer.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Path = @('src', 'tools', 'tests'),
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    if ($Install) {
        Write-Host '  PSScriptAnalyzer wird installiert ...'
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
    }
    else {
        Write-Host ''
        Write-Host '  PSScriptAnalyzer ist nicht vorhanden - die Pruefung wurde NICHT ausgefuehrt.' -ForegroundColor Red
        Write-Host '  Nachholen mit:  .\tools\Invoke-Analyzer.ps1 -Install' -ForegroundColor Yellow
        Write-Host '  (Ein stilles "keine Befunde" waere hier schlimmer als ein Abbruch.)'
        exit 2
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$version = (Get-Module PSScriptAnalyzer).Version
$settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'

# Selbstprobe: eine absichtlich fehlerhafte Datei muss Befunde ergeben.
$bait = Join-Path ([System.IO.Path]::GetTempPath()) ('rc-bait-' + [guid]::NewGuid().ToString('N') + '.ps1')
Set-Content -LiteralPath $bait -Value 'function Set-Bait { param($x) $args = @(1); Write-Output $args }' -Encoding UTF8
$probe = @(Invoke-ScriptAnalyzer -Path $bait -Settings $settings)
Remove-Item -LiteralPath $bait -Force -ErrorAction SilentlyContinue
if ($probe.Count -eq 0) {
    Write-Host '  Die Selbstprobe schlug fehl - die Pruefung arbeitet nicht wie erwartet.' -ForegroundColor Red
    exit 3
}

Write-Host ''
Write-Host ('  PSScriptAnalyzer {0} | Selbstprobe: {1} Befund(e) wie erwartet' -f $version, $probe.Count)

$findings = @()
foreach ($p in $Path) {
    $full = Join-Path $Root $p
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $findings += Invoke-ScriptAnalyzer -Path $full -Recurse -Settings $settings
}

if ($findings.Count -eq 0) {
    Write-Host ('  Geprueft: {0} - keine Befunde' -f ($Path -join ', ')) -ForegroundColor Green
    exit 0
}
Write-Host ('  {0} Befund(e):' -f $findings.Count) -ForegroundColor Red
$findings | Format-Table Severity, ScriptName, Line, RuleName, Message -AutoSize -Wrap |
    Out-String -Width 150 | Write-Host
exit 1
