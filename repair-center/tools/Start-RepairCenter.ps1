#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Starter
 Version: 1.5.1 | MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Startet den Dienst - mit Rechteerhoehung, verstaendlichen Meldungen
    und einem Fenster, das bei einem Fehler offen bleibt.

.DESCRIPTION
    Vorher steckte diese Logik in einer .cmd-Datei. Das war ein Fehler:
    cmd.exe verschluckt Meldungen, Fortsetzungszeichen am Zeilenende
    verhalten sich innerhalb von Klammern anders als ausserhalb, und bei
    einem Abbruch schliesst sich das Fenster, bevor man lesen kann, was
    schiefging. Genau das ist passiert.

    Hier gilt: jeder Fehler wird benannt, das Fenster bleibt offen, und
    es gibt am Ende immer einen Hinweis, was als Naechstes zu tun ist.
#>
[CmdletBinding()]
param(
    [int]$Port = 8720,
    [switch]$Demo,
    [switch]$NoBrowser,
    [string]$LogRoot = 'C:\RepairLogs',
    [switch]$NoElevate,
    [switch]$Elevated
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
    param([string]$Text = 'Zum Schliessen die Eingabetaste druecken.')
    # RC_NONINTERACTIVE=1 setzen Tests und Automatisierung, damit hier
    # niemand auf eine Eingabe wartet, die nie kommt.
    if ($env:RC_NONINTERACTIVE -eq '1') { return }
    if (-not [Environment]::UserInteractive) { return }
    Write-Host ''
    Write-Zeile -Art warn -Text $Text
    try { [void](Read-Host) } catch { Start-Sleep -Seconds 20 }
}

function Exit-MitRat {
    param([string]$Text, [string[]]$Hinweise = @(), [int]$Code = 1)
    Write-Host ''
    Write-Zeile -Art error -Text $Text
    foreach ($h in $Hinweise) { Write-Zeile -Text ('-> ' + $h) }
    Wait-Taste
    exit $Code
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $ScriptDir
$Server = Join-Path (Join-Path $Root 'src') 'RepairCenter.Server.ps1'

Write-Host ''
Write-Zeile -Art kopf -Text '===================================================='
Write-Zeile -Art kopf -Text ' RepairCenter wird gestartet'
Write-Zeile -Art kopf -Text '===================================================='

# ---------------------------------------------------------------- Pruefungen
if (-not (Test-Path -LiteralPath $Server)) {
    Exit-MitRat -Text ('Der Dienst wurde nicht gefunden: ' + $Server) -Hinweise @(
        'Liegt die Datei RepairCenter.cmd im selben Ordner wie "src" und "web"?',
        'Beim Entpacken alle Ordner mit extrahieren, nicht nur einzelne Dateien.')
}

$istWindows = ($env:OS -eq 'Windows_NT')

# ------------------------------------------------------- Rechte und Neustart
if ($istWindows) {
    $admin = $false
    try {
        $kennung = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal($kennung)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $admin = $false }

    if (-not $admin -and -not $NoElevate) {
        Write-Zeile -Art warn -Text 'Administratorrechte erforderlich - es erscheint die Nachfrage von Windows (UAC).'

        $eigene = $MyInvocation.MyCommand.Path
        $argumente = New-Object System.Collections.ArrayList
        foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $eigene))) { [void]$argumente.Add($a) }
        [void]$argumente.Add('-Port'); [void]$argumente.Add($Port)
        [void]$argumente.Add('-LogRoot'); [void]$argumente.Add(('"{0}"' -f $LogRoot.TrimEnd('\')))
        if ($Demo) { [void]$argumente.Add('-Demo') }
        if ($NoBrowser) { [void]$argumente.Add('-NoBrowser') }
        [void]$argumente.Add('-Elevated')

        $psExe = $null
        try { $psExe = (Get-Process -Id $PID).Path } catch { $psExe = $null }
        if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = Join-Path $PSHOME 'powershell.exe' }

        try {
            # Bewusst ohne -Wait: das neue Fenster uebernimmt.
            Start-Process -FilePath $psExe -ArgumentList $argumente -Verb RunAs -ErrorAction Stop | Out-Null
            Write-Zeile -Art ok -Text 'Weiter geht es im neuen Fenster mit Administratorrechten.'
            Start-Sleep -Seconds 2
            exit 0
        }
        catch {
            Exit-MitRat -Text ('Die Rechteerhoehung ist fehlgeschlagen: ' + $_.Exception.Message) -Hinweise @(
                'Wurde die Nachfrage von Windows mit "Nein" beantwortet?',
                'Alternative: PowerShell als Administrator oeffnen und dort aufrufen:',
                ('  & "{0}" -NoElevate' -f $eigene))
        }
    }
    if (-not $admin -and $NoElevate) {
        Write-Zeile -Art warn -Text 'Ohne Administratorrechte: Analyse und Reparatur sind stark eingeschraenkt.'
    }

    # Internet-Markierung entfernen - sonst blockt die Ausfuehrungsrichtlinie
    try {
        Get-ChildItem -LiteralPath $Root -Recurse -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    }
    catch { Write-Verbose 'Unblock-File nicht verfuegbar.' }
}
else {
    Write-Zeile -Art warn -Text 'Kein Windows erkannt - der Dienst laeuft dann nur mit Demodaten.'
}

# ------------------------------------------------------------- Port pruefen
if ($istWindows) {
    try {
        $belegt = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if ($belegt.Count -gt 0) {
            $wer = ''
            try { $wer = (Get-Process -Id $belegt[0].OwningProcess -ErrorAction Stop).ProcessName } catch { $wer = 'unbekannt' }
            Exit-MitRat -Text ('Port {0} ist bereits belegt (durch "{1}").' -f $Port, $wer) -Hinweise @(
                'Laeuft RepairCenter vielleicht schon? Dann einfach im Browser oeffnen:',
                ('  http://localhost:{0}/' -f $Port),
                'Oder mit einem anderen Port starten:',
                ('  RepairCenter.cmd -Port {0}' -f ($Port + 1)))
        }
    }
    catch { Write-Verbose 'Portpruefung nicht moeglich.' }
}

# --------------------------------------------------------------- Dienst
Write-Zeile -Art ok -Text ('Oberflaeche: http://localhost:{0}/' -f $Port)
Write-Zeile -Text ('Betriebsart: {0}' -f $(if ($Demo) { 'Demomodus - keine echten Eingriffe' } else { 'produktiv - es wird wirklich gearbeitet' }))
Write-Zeile -Text 'Beenden mit Strg+C. Dieses Fenster bitte offen lassen.'
Write-Host ''

# Hashtabelle, nicht Array: ein Array wird beim Splatting POSITIONSWEISE
# uebergeben, dann landet "-Port" als Wert im Parameter Port und der Start
# scheitert mit einer Typumwandlungsmeldung. Genau das ist passiert.
$dienstParameter = @{
    Port    = $Port
    LogRoot = $LogRoot
}
if ($Demo) { $dienstParameter['Demo'] = $true }
if ($NoBrowser) { $dienstParameter['NoBrowser'] = $true }

try {
    & $Server @dienstParameter
    $code = $LASTEXITCODE
    if ($null -ne $code -and $code -ne 0) {
        Exit-MitRat -Text ('Der Dienst hat sich mit Fehlercode {0} beendet.' -f $code) -Hinweise @(
            'Die letzten Zeilen oben nennen den Grund.',
            'Haeufig: Port belegt, fehlende Administratorrechte oder eine blockierte Datei.') -Code $code
    }
}
catch {
    Exit-MitRat -Text ('Der Dienst konnte nicht starten: ' + $_.Exception.Message) -Hinweise @(
        'Vollstaendige Meldung:',
        ('  ' + ($_.ScriptStackTrace -split "`n" | Select-Object -First 1)),
        'Bitte diese Zeilen melden - sie benennen die Ursache.')
}

Write-Host ''
Write-Zeile -Art ok -Text 'Der Dienst wurde beendet.'
Wait-Taste
exit 0
