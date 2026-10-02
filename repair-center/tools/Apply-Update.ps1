#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Aktualisierung einspielen
 Version: 1.5.1 | MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Spielt ein Paket RepairCenter-X.Y.Z.zip in ein vorhandenes
    Installationsverzeichnis ein.

.DESCRIPTION
    Dieses Skript laeuft bewusst ALS EIGENER PROZESS und ausserhalb des
    Installationsverzeichnisses: ein Dienst kann sich nicht selbst
    ueberschreiben, waehrend er laeuft. Der Ablauf ist deshalb:

      1. warten, bis der Dienst beendet ist (notfalls beenden)
      2. Sicherung der bisherigen Fassung anlegen
      3. Paket in einen Zwischenordner entpacken und pruefen
      4. Dateien einspielen - Laufzeitdaten bleiben unangetastet
      5. Dienst wieder starten

    Schlaegt Schritt 3 oder 4 fehl, wird die Sicherung zurueckgespielt.
    Es gibt keinen Zustand, in dem eine halb eingespielte Fassung
    zurueckbleibt.

.EXAMPLE
    .\Apply-Update.ps1 -Package D:\Pakete\RepairCenter-1.5.0.zip `
        -InstallDir "C:\Program Files\RepairCenter" -ServicePid 1234 -Port 8720
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$InstallDir,
    [int]$ServicePid = 0,
    [int]$Port = 8720,
    [string]$LogFile = '',
    [switch]$NoRestart,
    [switch]$SkipWait
)

$ErrorActionPreference = 'Stop'

if (-not $LogFile) {
    $LogFile = Join-Path ([System.IO.Path]::GetTempPath()) ('RepairCenter-Update-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-Protokoll {
    param([string]$Text, [string]$Art = 'info')
    $zeile = ('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Art, $Text)
    try { Add-Content -LiteralPath $LogFile -Value $zeile -Encoding UTF8 } catch { Write-Verbose 'Protokoll nicht schreibbar.' }
    $farbe = 'Gray'
    if ($Art -eq 'ok') { $farbe = 'Green' }
    elseif ($Art -eq 'warn') { $farbe = 'Yellow' }
    elseif ($Art -eq 'error') { $farbe = 'Red' }
    Write-Host ('  ' + $Text) -ForegroundColor $farbe
}

function Exit-MitFehler {
    param([string]$Text)
    Write-Protokoll -Art error -Text $Text
    exit 1
}

Write-Protokoll -Art ok -Text ('Aktualisierung startet. Paket: {0}' -f $Package)
Write-Protokoll -Text ('Ziel: {0}' -f $InstallDir)
Write-Protokoll -Text ('Protokoll: {0}' -f $LogFile)

if (-not (Test-Path -LiteralPath $Package)) { Exit-MitFehler ('Paket nicht gefunden: {0}' -f $Package) }
if (-not (Test-Path -LiteralPath $InstallDir)) { Exit-MitFehler ('Installationsverzeichnis nicht gefunden: {0}' -f $InstallDir) }

# ---------------- 1. Auf das Ende des Dienstes warten ----------------
if ($ServicePid -gt 0 -and -not $SkipWait) {
    Write-Protokoll -Text ('Warte auf das Ende des Dienstes (PID {0}) ...' -f $ServicePid)
    for ($i = 0; $i -lt 60; $i++) {
        if (-not (Get-Process -Id $ServicePid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 1
    }
    if (Get-Process -Id $ServicePid -ErrorAction SilentlyContinue) {
        Write-Protokoll -Art warn -Text 'Dienst reagiert nicht - wird beendet.'
        try { Stop-Process -Id $ServicePid -Force -ErrorAction Stop } catch { Write-Verbose 'Bereits beendet.' }
        Start-Sleep -Seconds 2
    }
    Write-Protokoll -Art ok -Text 'Dienst ist beendet.'
}

# ---------------- 2. Sicherung ----------------
$stempel = Get-Date -Format 'yyyyMMdd-HHmmss'
$sicherung = Join-Path (Split-Path $InstallDir -Parent) ('RepairCenter-Sicherung-' + $stempel)
try {
    New-Item -ItemType Directory -Path $sicherung -Force | Out-Null
    foreach ($teil in @('src', 'web', 'tools', 'installer', 'docs')) {
        $quelle = Join-Path $InstallDir $teil
        if (Test-Path -LiteralPath $quelle) {
            Copy-Item -LiteralPath $quelle -Destination (Join-Path $sicherung $teil) -Recurse -Force -ErrorAction Stop
        }
    }
    foreach ($datei in (Get-ChildItem -LiteralPath $InstallDir -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $datei.FullName -Destination (Join-Path $sicherung $datei.Name) -Force -ErrorAction SilentlyContinue
    }
    Write-Protokoll -Art ok -Text ('Sicherung angelegt: {0}' -f $sicherung)
}
catch { Exit-MitFehler ('Sicherung fehlgeschlagen - es wurde nichts veraendert. {0}' -f $_.Exception.Message) }

# ---------------- 3. Entpacken und pruefen ----------------
$zwischen = Join-Path ([System.IO.Path]::GetTempPath()) ('rc-update-' + $stempel)
try {
    New-Item -ItemType Directory -Path $zwischen -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Package, $zwischen)
    Write-Protokoll -Art ok -Text 'Paket entpackt.'
}
catch { Exit-MitFehler ('Paket liess sich nicht entpacken: {0}' -f $_.Exception.Message) }

# Das Paket enthaelt einen Ordner "repair-center" - oder liegt flach vor
$neu = $zwischen
if (-not (Test-Path -LiteralPath (Join-Path $neu 'src'))) {
    $unterordner = Get-ChildItem -LiteralPath $zwischen -Directory | Select-Object -First 1
    if ($unterordner -and (Test-Path -LiteralPath (Join-Path $unterordner.FullName 'src'))) { $neu = $unterordner.FullName }
}
$pflicht = @('src\RepairCenter.Server.ps1', 'src\modules\RepairEngine.psm1', 'web\index.html')
foreach ($p in $pflicht) {
    if (-not (Test-Path -LiteralPath (Join-Path $neu $p))) {
        Remove-Item -LiteralPath $zwischen -Recurse -Force -ErrorAction SilentlyContinue
        Exit-MitFehler ('Das Paket ist unvollstaendig - "{0}" fehlt. Es wurde nichts veraendert.' -f $p)
    }
}
Write-Protokoll -Art ok -Text 'Paket ist vollstaendig.'

# ---------------- 4. Einspielen ----------------
if (-not $PSCmdlet.ShouldProcess($InstallDir, 'Aktualisierung einspielen')) {
    Write-Protokoll -Art warn -Text 'WhatIf - nichts veraendert.'
    exit 0
}
try {
    foreach ($teil in @('src', 'web', 'tools', 'installer', 'docs')) {
        $quelle = Join-Path $neu $teil
        if (-not (Test-Path -LiteralPath $quelle)) { continue }
        $ziel = Join-Path $InstallDir $teil
        if (Test-Path -LiteralPath $ziel) { Remove-Item -LiteralPath $ziel -Recurse -Force -ErrorAction Stop }
        Copy-Item -LiteralPath $quelle -Destination $ziel -Recurse -Force -ErrorAction Stop
    }
    foreach ($datei in (Get-ChildItem -LiteralPath $neu -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $datei.FullName -Destination (Join-Path $InstallDir $datei.Name) -Force -ErrorAction Stop
    }
    Write-Protokoll -Art ok -Text 'Dateien eingespielt.'
}
catch {
    Write-Protokoll -Art error -Text ('Einspielen fehlgeschlagen: {0}' -f $_.Exception.Message)
    Write-Protokoll -Art warn -Text 'Sicherung wird zurueckgespielt ...'
    try {
        foreach ($teil in @('src', 'web', 'tools', 'installer', 'docs')) {
            $quelle = Join-Path $sicherung $teil
            if (-not (Test-Path -LiteralPath $quelle)) { continue }
            $ziel = Join-Path $InstallDir $teil
            if (Test-Path -LiteralPath $ziel) { Remove-Item -LiteralPath $ziel -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -LiteralPath $quelle -Destination $ziel -Recurse -Force -ErrorAction Stop
        }
        Write-Protokoll -Art ok -Text 'Vorherige Fassung wiederhergestellt.'
    }
    catch { Write-Protokoll -Art error -Text ('Auch die Wiederherstellung schlug fehl. Die Sicherung liegt unter {0}' -f $sicherung) }
    Remove-Item -LiteralPath $zwischen -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item -LiteralPath $zwischen -Recurse -Force -ErrorAction SilentlyContinue

# ---------------- 5. Dienst wieder starten ----------------
if (-not $NoRestart) {
    $server = Join-Path (Join-Path $InstallDir 'src') 'RepairCenter.Server.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }
    try {
        Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            ('"{0}"' -f $server), '-Port', $Port) -WindowStyle Hidden | Out-Null
        Write-Protokoll -Art ok -Text ('Dienst wurde neu gestartet (Port {0}).' -f $Port)
    }
    catch { Write-Protokoll -Art warn -Text ('Neustart des Dienstes fehlgeschlagen: {0}' -f $_.Exception.Message) }
}

Write-Protokoll -Art ok -Text ('Fertig. Die vorherige Fassung liegt unter {0}' -f $sicherung)
exit 0
