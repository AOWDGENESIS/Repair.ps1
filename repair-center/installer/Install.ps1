#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Installation
 Version: 1.5.1 | MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Installiert RepairCenter nach %ProgramFiles%\RepairCenter.

.DESCRIPTION
    Die Installation lag frueher in einer .cmd-Datei. Dort war sie kaum
    zu durchschauen und bei einem Fehler schloss sich das Fenster, bevor
    man die Meldung lesen konnte. Jetzt steht jeder Schritt hier, jeder
    Fehler wird benannt, und am Ende bleibt das Fenster offen.

.PARAMETER DestinationRoot
    Zielordner. Standard ist %ProgramFiles%. Fuer Tests frei waehlbar.

.PARAMETER NoShortcuts / NoRegistry / NoTask
    Einzelne Schritte auslassen - wird von den Tests genutzt, damit die
    Installation auch ohne Windows pruefbar bleibt.

.EXAMPLE
    .\Install.ps1
.EXAMPLE
    .\Install.ps1 -DestinationRoot D:\Werkzeuge -NoShortcuts -NoRegistry -NoTask
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$DestinationRoot = '',
    [switch]$NoShortcuts,
    [switch]$NoRegistry,
    [switch]$NoTask,
    [switch]$WithTask,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Zeile {
    param([string]$Text, [string]$Art = 'info')
    $farbe = 'Gray'
    if ($Art -eq 'ok') { $farbe = 'Green' }
    elseif ($Art -eq 'warn') { $farbe = 'Yellow' }
    elseif ($Art -eq 'error') { $farbe = 'Red' }
    elseif ($Art -eq 'kopf') { $farbe = 'Cyan' }
    Write-Host ('  ' + $Text) -ForegroundColor $farbe
}

function Wait-Taste {
    if ($Quiet -or $env:RC_NONINTERACTIVE -eq '1' -or -not [Environment]::UserInteractive) { return }
    Write-Host ''
    Write-Zeile -Art warn -Text 'Zum Schliessen die Eingabetaste druecken.'
    try { [void](Read-Host) } catch { Start-Sleep -Seconds 15 }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Quelle = Split-Path -Parent $ScriptDir
$istWindows = ($env:OS -eq 'Windows_NT')

if (-not $DestinationRoot) {
    $DestinationRoot = $(if ($istWindows -and $env:ProgramFiles) { $env:ProgramFiles } else { [System.IO.Path]::GetTempPath() })
}
$Ziel = Join-Path $DestinationRoot 'RepairCenter'

# Version aus package.json - eine Quelle, kein zweiter Ort zum Vergessen
$Version = 'unbekannt'
try {
    $pkg = Get-Content -LiteralPath (Join-Path $Quelle 'package.json') -Raw | ConvertFrom-Json
    if ($pkg.version) { $Version = [string]$pkg.version }
}
catch { Write-Verbose 'package.json nicht lesbar.' }

Write-Host ''
Write-Zeile -Art kopf -Text '===================================================='
Write-Zeile -Art kopf -Text (' RepairCenter {0} - Installation' -f $Version)
Write-Zeile -Art kopf -Text '===================================================='
Write-Zeile -Text ('Quelle: ' + $Quelle)
Write-Zeile -Text ('Ziel  : ' + $Ziel)
Write-Host ''

# ----------------------------------------------------------- Vorbedingungen
$fehlend = @()
foreach ($teil in @('src\RepairCenter.Server.ps1', 'src\modules\RepairEngine.psm1', 'web\index.html', 'RepairCenter.cmd')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Quelle $teil))) { $fehlend += $teil }
}
if ($fehlend.Count -gt 0) {
    Write-Zeile -Art error -Text 'Das Paket ist unvollstaendig. Es fehlen:'
    foreach ($f in $fehlend) { Write-Zeile -Text ('  - ' + $f) }
    Write-Zeile -Art warn -Text 'Bitte das ZIP-Archiv vollstaendig entpacken - mit allen Unterordnern.'
    Wait-Taste
    exit 2
}

if ($istWindows -and -not $NoRegistry) {
    $admin = $false
    try {
        $kennung = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal($kennung)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $admin = $false }
    if (-not $admin) {
        Write-Zeile -Art error -Text 'Administratorrechte fehlen.'
        Write-Zeile -Text 'Bitte Install.cmd mit Rechtsklick und "Als Administrator ausfuehren" starten.'
        Wait-Taste
        exit 3
    }
}

# ------------------------------------------------------------- Dateien
try {
    if (Test-Path -LiteralPath $Ziel) { Write-Zeile -Art warn -Text 'Vorhandene Installation wird aktualisiert.' }
    else { New-Item -ItemType Directory -Path $Ziel -Force | Out-Null }

    foreach ($ordner in @('src', 'web', 'tools', 'installer', 'docs')) {
        $von = Join-Path $Quelle $ordner
        if (-not (Test-Path -LiteralPath $von)) { continue }
        $nach = Join-Path $Ziel $ordner
        if (-not $PSCmdlet.ShouldProcess($nach, 'kopieren')) { continue }
        if (Test-Path -LiteralPath $nach) { Remove-Item -LiteralPath $nach -Recurse -Force }
        Copy-Item -LiteralPath $von -Destination $nach -Recurse -Force
        Write-Zeile -Text ('kopiert: ' + $ordner)
    }
    foreach ($datei in @('RepairCenter.cmd', 'README.md', 'README.en.md', 'LICENSE', 'CHANGELOG.md', 'SECURITY.md', 'package.json')) {
        $von = Join-Path $Quelle $datei
        if (Test-Path -LiteralPath $von) { Copy-Item -LiteralPath $von -Destination (Join-Path $Ziel $datei) -Force }
    }
    Write-Zeile -Art ok -Text 'Dateien vollstaendig kopiert.'
}
catch {
    Write-Zeile -Art error -Text ('Kopieren fehlgeschlagen: ' + $_.Exception.Message)
    Write-Zeile -Text 'Haeufige Ursachen: fehlende Rechte, Virenschutz, oder der Dienst laeuft noch.'
    Wait-Taste
    exit 4
}

# --------------------------------------------------------- Verknuepfungen
if ($istWindows -and -not $NoShortcuts) {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $startmenue = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\RepairCenter'
        if (-not (Test-Path -LiteralPath $startmenue)) { New-Item -ItemType Directory -Path $startmenue -Force | Out-Null }

        $eintraege = @(
            @{ Name = 'RepairCenter.lnk'; Ziel = (Join-Path $Ziel 'RepairCenter.cmd'); Argumente = ''; Symbol = 165 },
            @{ Name = 'RepairCenter (Demomodus).lnk'; Ziel = (Join-Path $Ziel 'RepairCenter.cmd'); Argumente = '-Demo'; Symbol = 22 }
        )
        foreach ($e in $eintraege) {
            $lnk = $wsh.CreateShortcut((Join-Path $startmenue $e.Name))
            $lnk.TargetPath = $e.Ziel
            $lnk.Arguments = $e.Argumente
            $lnk.WorkingDirectory = $Ziel
            $lnk.IconLocation = ('{0}\System32\shell32.dll,{1}' -f $env:SystemRoot, $e.Symbol)
            $lnk.Description = 'Windows reparieren, diagnostizieren, warten'
            $lnk.Save()
        }
        $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        if ($desktop) {
            $lnk = $wsh.CreateShortcut((Join-Path $desktop 'RepairCenter.lnk'))
            $lnk.TargetPath = (Join-Path $Ziel 'RepairCenter.cmd')
            $lnk.WorkingDirectory = $Ziel
            $lnk.IconLocation = ('{0}\System32\shell32.dll,165' -f $env:SystemRoot)
            $lnk.Save()
        }
        Write-Zeile -Art ok -Text 'Verknuepfungen im Startmenue und auf dem Desktop angelegt.'
    }
    catch { Write-Zeile -Art warn -Text ('Verknuepfungen konnten nicht angelegt werden: ' + $_.Exception.Message) }
}

# ------------------------------------------------------- Apps und Features
if ($istWindows -and -not $NoRegistry) {
    try {
        $schluessel = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RepairCenter'
        if (-not (Test-Path -LiteralPath $schluessel)) { New-Item -Path $schluessel -Force | Out-Null }
        $werte = @{
            DisplayName     = 'RepairCenter'
            DisplayVersion  = $Version
            Publisher       = 'AOWD GENESIS'
            InstallLocation = $Ziel
            DisplayIcon     = ('{0}\System32\shell32.dll,165' -f $env:SystemRoot)
            UninstallString = ('"{0}"' -f (Join-Path (Join-Path $Ziel 'installer') 'Uninstall.cmd'))
            NoModify        = 1
            NoRepair        = 1
        }
        foreach ($name in $werte.Keys) {
            $art = $(if ($werte[$name] -is [int]) { 'DWord' } else { 'String' })
            New-ItemProperty -Path $schluessel -Name $name -Value $werte[$name] -PropertyType $art -Force | Out-Null
        }
        Write-Zeile -Art ok -Text ('In "Apps & Features" eingetragen (Version {0}).' -f $Version)
    }
    catch { Write-Zeile -Art warn -Text ('Eintrag nicht moeglich: ' + $_.Exception.Message) }
}

# ------------------------------------------------------- Geplante Wartung
if ($istWindows -and -not $NoTask) {
    $anlegen = $WithTask
    if (-not $WithTask -and -not $Quiet -and $env:RC_NONINTERACTIVE -ne '1' -and [Environment]::UserInteractive) {
        Write-Host ''
        $antwort = Read-Host '  Woechentliche Wartung einrichten (sonntags 03:00)? [j/N]'
        $anlegen = ($antwort -eq 'j' -or $antwort -eq 'J')
    }
    if ($anlegen) {
        try {
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $cli = Join-Path (Join-Path $Ziel 'src') 'RepairCenter.Cli.ps1'
            $befehl = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode Quick -Optimize Safe -NoElevate' -f $ps, $cli)
            $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
            & $schtasks '/Create' '/TN' 'RepairCenter\Woechentliche Wartung' '/SC' 'WEEKLY' '/D' 'SUN' `
                '/ST' '03:00' '/RL' 'HIGHEST' '/RU' 'SYSTEM' '/F' '/TR' $befehl | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Zeile -Art ok -Text 'Aufgabe angelegt: sonntags 03:00 Uhr.' }
            else { Write-Zeile -Art warn -Text ('Aufgabe konnte nicht angelegt werden (Code {0}).' -f $LASTEXITCODE) }
        }
        catch { Write-Zeile -Art warn -Text ('Aufgabe konnte nicht angelegt werden: ' + $_.Exception.Message) }
    }
}

Write-Host ''
Write-Zeile -Art ok -Text 'Installation abgeschlossen.'
Write-Zeile -Text ('Start ueber das Startmenue oder: "{0}"' -f (Join-Path $Ziel 'RepairCenter.cmd'))
Write-Zeile -Text 'Erster Schritt dort: Reiter "System" -> "Bereitschaft fuer den Echtbetrieb" -> Pruefen.'
Wait-Taste
exit 0
