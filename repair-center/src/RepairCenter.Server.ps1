#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Backend (REST-API + Auslieferung der Oberflaeche)
 Version: 1.5.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 100 % lokal - bindet standardmaessig NUR an localhost.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Startet den lokalen Webdienst von RepairCenter.

.EXAMPLE
    .\RepairCenter.Server.ps1
.EXAMPLE
    .\RepairCenter.Server.ps1 -Port 8720 -Demo -NoBrowser
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8720,
    [string]$BindAddress = 'localhost',
    [string]$LogRoot = 'C:\RepairLogs',
    [string]$WebRoot,
    [switch]$Demo,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$IsWindowsHost = ($env:OS -eq 'Windows_NT')
if (-not $WebRoot) { $WebRoot = (Join-Path $ProjectDir 'web') }
$WebRoot = [System.IO.Path]::GetFullPath($WebRoot)
$RunnerPath = Join-Path $ScriptDir 'RepairCenter.Runner.ps1'
$ModulePath = Join-Path (Join-Path $ScriptDir 'modules') 'RepairEngine.psm1'
$DiskModulePath = Join-Path (Join-Path $ScriptDir 'modules') 'DiskManager.psm1'
$DiskJobPath = Join-Path $ScriptDir 'RepairCenter.DiskJob.ps1'

Import-Module $ModulePath -Force -DisableNameChecking
Import-Module $DiskModulePath -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'DiskAnalysis.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'FileIntegrity.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $ScriptDir 'modules') 'ArchiveManager.psm1') -Force -DisableNameChecking

if (-not $IsWindowsHost -and $LogRoot -eq 'C:\RepairLogs') {
    $LogRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'RepairLogs'
}
$RunsDir = Join-Path $LogRoot 'runs'
if (-not (Test-Path -LiteralPath $RunsDir)) { New-Item -ItemType Directory -Path $RunsDir -Force | Out-Null }
$DiskJobsDir = Join-Path $LogRoot 'diskjobs'
if (-not (Test-Path -LiteralPath $DiskJobsDir)) { New-Item -ItemType Directory -Path $DiskJobsDir -Force | Out-Null }

#region ---------------------------- Helfer ----------------------------

function Get-PowerShellExecutable {
    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { $exe = $null }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $name = 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $name = 'pwsh' }
        $exe = Join-Path $PSHOME $name
    }
    return $exe
}

function Get-MimeType {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.html') { return 'text/html; charset=utf-8' }
    if ($ext -eq '.js') { return 'application/javascript; charset=utf-8' }
    if ($ext -eq '.css') { return 'text/css; charset=utf-8' }
    if ($ext -eq '.json') { return 'application/json; charset=utf-8' }
    if ($ext -eq '.svg') { return 'image/svg+xml' }
    if ($ext -eq '.png') { return 'image/png' }
    if ($ext -eq '.ico') { return 'image/x-icon' }
    if ($ext -eq '.txt') { return 'text/plain; charset=utf-8' }
    return 'application/octet-stream'
}

function Write-HttpText {
    param($Response, [string]$Content, [string]$ContentType = 'text/plain; charset=utf-8', [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Write-HttpJson {
    <#  -AsArray erzwingt eckige Klammern. Notwendig, weil ConvertTo-Json
        aus einem einelementigen Array ein Objekt macht und aus einem leeren
        Array "null" - die Oberflaeche erwartet aber immer eine Liste.
        Der Fehler faellt erst auf, wenn genau ein Eintrag da ist, also beim
        allerersten Lauf auf einem frischen Rechner. #>
    param($Response, $Object, [int]$StatusCode = 200, [switch]$AsArray)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    if ($AsArray) {
        if ($null -eq $json -or $json -eq 'null' -or $json -eq '') { $json = '[]' }
        elseif (-not $json.StartsWith('[')) { $json = '[' + $json + ']' }
    }
    if ($null -eq $json) { $json = 'null' }
    Write-HttpText -Response $Response -Content $json -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Write-HttpFile {
    param($Response, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-HttpText -Response $Response -Content '404 - nicht gefunden' -StatusCode 404
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Response.StatusCode = 200
    $Response.ContentType = Get-MimeType -Path $Path
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-RequestBody {
    param($Request, [int]$MaxBytes = 65536)
    if (-not $Request.HasEntityBody) { return $null }
    # Begrenzen: ein lokaler Dienst braucht keine Megabyte-Anfragen.
    if ($Request.ContentLength64 -gt $MaxBytes) { return $null }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $buffer = New-Object char[] $MaxBytes
    $read = $reader.Read($buffer, 0, $MaxBytes)
    $reader.Dispose()
    if ($read -le 0) { return $null }
    $text = -join $buffer[0..($read - 1)]
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

#region ------------------- Schutz und Pruefung ------------------------

<#  Schutz gegen Anfragen fremder Webseiten (CSRF).
    Ein Browser darf den Zusatzkopf "X-RepairCenter" nur bei gleicher
    Herkunft ohne Vorabanfrage senden. Der Dienst beantwortet keine
    Vorabanfragen (OPTIONS) und lehnt fremde Origin-Angaben ab - damit
    kann keine beliebige Webseite im Hintergrund einen Loeschauftrag
    ausloesen, nur weil der Dienst auf localhost lauscht. #>
function Test-RequestTrusted {
    param($Request)
    $method = $Request.HttpMethod
    if ($method -eq 'GET' -or $method -eq 'HEAD') { return @{ ok = $true; reason = '' } }

    if ($Request.Headers['X-RepairCenter'] -ne '1') {
        return @{ ok = $false; reason = 'Zusatzkopf X-RepairCenter fehlt - Anfrage stammt nicht aus der Oberflaeche.' }
    }
    $origin = $Request.Headers['Origin']
    if ($origin) {
        $allowed = @(('http://localhost:{0}' -f $Port), ('http://127.0.0.1:{0}' -f $Port), ('http://[::1]:{0}' -f $Port))
        if ($allowed -notcontains $origin.TrimEnd('/')) {
            return @{ ok = $false; reason = ('Fremde Herkunft abgelehnt: {0}' -f $origin) }
        }
    }
    return @{ ok = $true; reason = '' }
}

function Test-TextPattern {
    param([string]$Value, [string]$Pattern)
    if ($null -eq $Value) { return $false }
    return ($Value -match $Pattern)
}

<#  Prueft und bereinigt alles, was aus dem Netz kommt, bevor daraus
    Prozessargumente werden. Grundsatz: Positivliste statt Verbotsliste. #>
function Get-CheckedRequest {
    param([Parameter(Mandatory)][string]$Kind, $Body)

    $problems = New-Object System.Collections.ArrayList
    $clean = @{}
    if (-not $Body) { return @{ ok = $false; problems = @('Kein Anfragekoerper.'); body = $clean } }

    $enums = @{
        mode          = @('Quick', 'Diagnose', 'Repair', 'Full')
        optimize      = @('None', 'Safe', 'Standard', 'Aggressive')
        demoScenario  = @('Healthy', 'Repaired', 'Escalation', 'Failed', 'Preflight')
        fileSystem    = @('NTFS', 'exFAT', 'FAT32', 'ReFS')
        strategy      = @('Auto', 'CryptoErase', 'Trim', 'Zero', 'ZeroVerify')
        rescueMode    = @('Copy', 'Move')
        repairStrategy = @('Auto', 'ShadowCopy', 'SystemFile', 'ReportOnly')
        archiveFormat  = @('Zip', 'SevenZip', 'Rar')
        archiveLevel   = @('Fastest', 'Normal', 'Maximum')
        copyMode       = @('Copy', 'Move')
        day           = @('MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN')
    }
    $ranges = @{
        tempFileAgeDays    = @(0, 365)
        minFreeSpaceGB     = @(1, 500)
        diskNumber         = @(0, 127)
        bufferMiB          = @(1, 256)
        queueDepth         = @(1, 16)
        rescueThreads      = @(1, 128)
        allocationUnitSize = @(0, 65536)
        samples            = @(4, 4096)
        threads            = @(1, 128)
    }
    $flags = @('skipDism', 'skipSfc', 'skipDisk', 'noEscalate', 'noRestorePoint', 'whatIf',
        'demo', 'full', 'allowDataLoss', 'rescueUnbuffered', 'deep', 'skipSurface', 'unbuffered')

    foreach ($prop in $Body.PSObject.Properties) {
        $name = $prop.Name
        $value = $prop.Value

        if ($enums.ContainsKey($name)) {
            $text = [string]$value
            if ($enums[$name] -notcontains $text) {
                [void]$problems.Add(("{0}: '{1}' ist nicht zulaessig (erlaubt: {2})" -f $name, $text, ($enums[$name] -join ', ')))
            }
            else { $clean[$name] = $text }
            continue
        }
        if ($ranges.ContainsKey($name)) {
            $num = 0
            if (-not [int]::TryParse([string]$value, [ref]$num)) {
                [void]$problems.Add(("{0}: '{1}' ist keine Zahl" -f $name, $value))
            }
            elseif ($num -lt $ranges[$name][0] -or $num -gt $ranges[$name][1]) {
                [void]$problems.Add(("{0}: {1} liegt ausserhalb von {2} bis {3}" -f $name, $num, $ranges[$name][0], $ranges[$name][1]))
            }
            else { $clean[$name] = $num }
            continue
        }
        if ($flags -contains $name) { $clean[$name] = [bool]$value; continue }

        switch ($name) {
            'driveLetter' {
                $text = ([string]$value).Trim().TrimEnd(':').ToUpperInvariant()
                if (-not (Test-TextPattern -Value $text -Pattern '^[A-Z]$')) {
                    [void]$problems.Add(("driveLetter: '{0}' ist kein einzelner Laufwerksbuchstabe" -f $value))
                }
                else { $clean['driveLetter'] = $text }
            }
            'label' {
                # Buchstaben heisst Buchstaben - auch Umlaute, Akzente und
                # andere Schriften. \p{L} statt A-Z, sonst scheitert jede
                # Bezeichnung wie "Buero" mit echtem Umlaut.
                $text = [string]$value
                if (-not (Test-TextPattern -Value $text -Pattern '^[\p{L}\p{N} _\-\.\(\)]{0,32}$')) {
                    [void]$problems.Add('label: nur Buchstaben, Ziffern, Leerzeichen, Klammern, Punkt, Strich und Unterstrich, hoechstens 32 Zeichen')
                }
                else { $clean['label'] = $text }
            }
            'confirmation' {
                $text = ([string]$value).Trim().ToUpperInvariant()
                if (-not (Test-TextPattern -Value $text -Pattern '^(DISK[0-9]{1,3}|[A-Z]:)$')) {
                    [void]$problems.Add(("confirmation: '{0}' hat nicht die erwartete Form" -f $value))
                }
                else { $clean['confirmation'] = $text }
            }
            'rescueTarget' {
                $text = ([string]$value).Trim()
                if ($text -match '\.\.' -or $text -match '["|<>*?]') {
                    [void]$problems.Add('rescueTarget: unzulaessige Zeichen oder Verzeichniswechsel')
                }
                elseif (-not (Test-TextPattern -Value $text -Pattern '^[A-Za-z]:\\[\p{L}\p{N} _\-\.\\\(\)]{1,200}$')) {
                    [void]$problems.Add(("rescueTarget: '{0}' muss ein Pfad der Form D:\Ordner sein" -f $text))
                }
                else { $clean['rescueTarget'] = $text }
            }
            'path' {
                $text = ([string]$value).Trim()
                if ($text -match '\.\.' -or $text -match '["|<>*?]') {
                    [void]$problems.Add('path: unzulaessige Zeichen oder Verzeichniswechsel')
                }
                elseif (-not (Test-TextPattern -Value $text -Pattern '^([A-Za-z]:\\|/)[\p{L}\p{N} _\-\.\\/\(\)]{0,250}$')) {
                    [void]$problems.Add(("path: '{0}' ist kein zulaessiger Pfad" -f $text))
                }
                else { $clean['path'] = $text }
            }
            'source' {
                $text = ([string]$value).Trim()
                if ($text -match '\.\.' -or $text -match '["|<>*?]') { [void]$problems.Add('source: unzulaessige Zeichen') }
                else { $clean['source'] = $text }
            }
            'target' {
                $text = ([string]$value).Trim()
                if ($text -match '\.\.' -or $text -match '["|<>*?]') { [void]$problems.Add('target: unzulaessige Zeichen') }
                elseif (-not (Test-TextPattern -Value $text -Pattern '^([A-Za-z]:\\|/)[\p{L}\p{N} _\-\.\\/\(\)]{0,250}$')) {
                    [void]$problems.Add(("target: '{0}' ist kein zulaessiger Pfad" -f $text))
                }
                else { $clean['target'] = $text }
            }
            'scanJobId' {
                $text = ([string]$value).Trim()
                if (-not (Test-TextPattern -Value $text -Pattern '^[A-Za-z0-9\-]{1,64}$')) {
                    [void]$problems.Add('scanJobId: unzulaessige Kennung')
                }
                else { $clean['scanJobId'] = $text }
            }
            'time' {
                $text = [string]$value
                if (-not (Test-TextPattern -Value $text -Pattern '^([01][0-9]|2[0-3]):[0-5][0-9]$')) {
                    [void]$problems.Add(("time: '{0}' ist keine Uhrzeit im Format HH:MM" -f $text))
                }
                else { $clean['time'] = $text }
            }
            default { [void]$problems.Add(("{0}: unbekanntes Feld" -f $name)) }
        }
    }

    # Pflichtfelder je Vorgang
    if ($Kind -eq 'FileScan' -and -not $clean.ContainsKey('path')) { [void]$problems.Add('path fehlt') }
    if (($Kind -eq 'Archive' -or $Kind -eq 'CopyFolder') -and -not $clean.ContainsKey('path')) { [void]$problems.Add('path fehlt') }
    if (($Kind -eq 'Archive' -or $Kind -eq 'CopyFolder') -and -not $clean.ContainsKey('target')) { [void]$problems.Add('target fehlt') }
    if ($Kind -eq 'Analyze' -and -not $clean.ContainsKey('diskNumber')) { [void]$problems.Add('diskNumber fehlt') }
    if ($Kind -eq 'Wipe' -and -not $clean.ContainsKey('confirmation')) { [void]$problems.Add('confirmation fehlt') }
    if ($Kind -eq 'Wipe' -and -not $clean.ContainsKey('diskNumber')) { [void]$problems.Add('diskNumber fehlt') }
    if (($Kind -eq 'Format' -or $Kind -eq 'Convert') -and -not $clean.ContainsKey('driveLetter')) { [void]$problems.Add('driveLetter fehlt') }

    return @{ ok = ($problems.Count -eq 0); problems = @($problems); body = $clean }
}

#endregion

function Write-StateFileAtomic {
    <#
    .SYNOPSIS
        Schreibt eine Zustandsdatei so, dass nie eine halbe zurueckbleibt.
    .DESCRIPTION
        Erst in eine Nebendatei, dann umbenennen - das Umbenennen ist auf
        NTFS unteilbar. Wird der Dienst mittendrin beendet, liegt entweder
        die alte oder die neue Fassung da, niemals eine abgeschnittene.
        Vorher wurde direkt in state.json geschrieben; genau daher stammen
        die leeren und halben Dateien, die im Betrieb aufgetaucht sind.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object, [int]$Depth = 6)

    $json = $Object | ConvertTo-Json -Depth $Depth
    # Leeres Ergebnis niemals schreiben - sonst zerstoert ein Fehlschlag
    # beim Umwandeln die vorhandene, gute Datei.
    if ([string]::IsNullOrWhiteSpace($json) -or $json.Trim().Length -lt 5) {
        Write-Host '  Warnung: Zustand liess sich nicht umwandeln - die vorhandene Datei bleibt unangetastet.' -ForegroundColor Yellow
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Zustand schreiben')) { return $false }
    $tmp = $Path + '.tmp'
    try {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force -WhatIf:$false
        Move-Item -LiteralPath $tmp -Destination $Path -Force -WhatIf:$false
        return $true
    }
    catch {
        Write-Host ('  Warnung: Zustand nicht schreibbar: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# Einmal gemeldet reicht: sonst flutet jede Verlaufsabfrage die Konsole.
$script:GemeldeteDefekte = @{}

function Get-RunState {
    param([string]$RunId, [switch]$WithReason)
    $path = Join-Path (Join-Path $RunsDir $RunId) 'state.json'
    if (-not (Test-Path -LiteralPath $path)) {
        if ($WithReason) { return @{ ok = $false; reason = 'state.json fehlt'; state = $null } }
        return $null
    }
    # Dreimal versuchen: die Datei kann gerade geschrieben werden.
    for ($versuch = 1; $versuch -le 3; $versuch++) {
        try {
            $roh = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($roh)) { throw 'Datei ist leer' }
            $zustand = $roh | ConvertFrom-Json -ErrorAction Stop
            if ($WithReason) { return @{ ok = $true; reason = ''; state = $zustand } }
            return $zustand
        }
        catch {
            if ($versuch -lt 3) { Start-Sleep -Milliseconds 150; continue }
            $groesse = 0
            try { $groesse = (Get-Item -LiteralPath $path -ErrorAction Stop).Length } catch { $groesse = -1 }
            $grund = ('{0} ({1} Byte)' -f $_.Exception.Message, $groesse)
            if (-not $script:GemeldeteDefekte.ContainsKey($RunId)) {
                $script:GemeldeteDefekte[$RunId] = $true
                Write-Host ('  Hinweis: Zustandsdatei von {0} ist beschaedigt: {1}' -f $RunId, $grund) -ForegroundColor Yellow
                Write-Host '           Der Eintrag bleibt im Verlauf sichtbar und laesst sich dort entfernen.' -ForegroundColor DarkGray
            }
            if ($WithReason) { return @{ ok = $false; reason = $grund; state = $null } }
            return $null
        }
    }
}

function Get-RunHistory {
    $result = New-Object System.Collections.ArrayList
    $dirs = Get-ChildItem -LiteralPath $RunsDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 30
    foreach ($d in $dirs) {
        $gelesen = Get-RunState -RunId $d.Name -WithReason
        if (-not $gelesen.ok) {
            # Verstecken waere das Schlechteste: dann wundert man sich, wo
            # der Lauf geblieben ist. Lieber sichtbar und entfernbar.
            [void]$result.Add([ordered]@{
                    runId = $d.Name; mode = '-'; optimize = '-'
                    status = 'unreadable'; overall = 'UNKNOWN'
                    startTime = $d.CreationTime.ToString('o'); durationSec = 0
                    demo = $false; restartRequired = $false; reclaimedGB = 0
                    reason = $gelesen.reason
                })
            continue
        }
        $st = $gelesen.state
        [void]$result.Add([ordered]@{
                runId           = $st.runId
                mode            = $st.mode
                optimize        = $st.optimize
                status          = $st.status
                overall         = $st.overall
                startTime       = $st.startTime
                durationSec     = $st.durationSec
                demo            = $st.demo
                restartRequired = $st.restartRequired
                reclaimedGB     = $st.reclaimedGB
            })
    }
    return $result
}

function Start-RepairRunner {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($Body)
    if (-not $PSCmdlet.ShouldProcess('Reparaturlauf', 'starten')) { return @{ error = 'abgebrochen' } }
    $runId = New-RunIdentifier
    $runDir = Join-Path $RunsDir $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    # Zustand sofort anlegen. Sonst antwortet /api/run/{id} zwischen Start und
    # erstem Lebenszeichen des Laufprozesses mit 404 - unter Last sind das
    # mehrere Sekunden, in denen die Oberflaeche nichts anzuzeigen hat.
    $initialRun = [ordered]@{
        schema = 1; runId = $runId; tool = 'RepairCenter'; version = '1.5.1'
        mode = $mode; optimize = $optimize; status = 'running'; overall = 'UNKNOWN'
        progress = 0; currentStep = 'Start'; steps = @(); findings = @()
        restartRequired = $false; restartReasons = @()
        startTime = (Get-Date).ToString('o')
        log = @([ordered]@{ t = (Get-Date).ToString('HH:mm:ss'); kind = 'info'; text = 'Lauf wird gestartet ...' })
    }
    [void](Write-StateFileAtomic -Path (Join-Path $runDir 'state.json') -Object ([pscustomobject]$initialRun) -Depth 6 -Confirm:$false)

    $mode = 'Repair'; $optimize = 'Safe'; $scenario = 'Repaired'
    $tempAge = 2; $minFree = 8
    if ($Body -and $Body.mode) { $mode = [string]$Body.mode }
    if ($Body -and $Body.optimize) { $optimize = [string]$Body.optimize }
    if ($Body -and $Body.demoScenario) { $scenario = [string]$Body.demoScenario }
    if ($Body -and $Body.tempFileAgeDays) { $tempAge = [int]$Body.tempFileAgeDays }
    if ($Body -and $Body.minFreeSpaceGB) { $minFree = [int]$Body.minFreeSpaceGB }

    # Anfuehrungszeichen sind auf JEDER Plattform noetig: Start-Process
    # setzt die Argumentliste zu einer Kommandozeile zusammen und trennt
    # anschliessend an Leerzeichen. Ohne Anfuehrungszeichen wird aus
    # "D:\Rettung Buero" stillschweigend "D:\Rettung" - gemessen unter
    # PowerShell 7, gilt genauso fuer Windows PowerShell.
    $q = { param($v) return ('"{0}"' -f (([string]$v) -replace '"', '')) }

    $arguments = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $q $RunnerPath),
            '-RunId', $runId, '-Mode', $mode, '-Optimize', $optimize, '-LogRoot', (& $q ($LogRoot.TrimEnd('\'))),
            '-TempFileAgeDays', $tempAge, '-MinFreeSpaceGB', $minFree, '-DemoScenario', $scenario)) {
        [void]$arguments.Add($a)
    }
    foreach ($flag in @('skipDism', 'skipSfc', 'skipDisk', 'noEscalate', 'noRestorePoint', 'whatIf')) {
        if ($Body -and $Body.$flag) { [void]$arguments.Add('-' + $flag.Substring(0, 1).ToUpper() + $flag.Substring(1)) }
    }
    if ($Demo -or ($Body -and $Body.demo)) { [void]$arguments.Add('-Demo') }

    $exe = Get-PowerShellExecutable
    if ($IsWindowsHost) {
        $proc = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
    else {
        $proc = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
    }
    Set-Content -LiteralPath (Join-Path $runDir 'runner.pid') -Value ([string]$proc.Id) -Encoding UTF8
    Write-Host ('  -> Lauf {0} gestartet (PID {1}, Modus {2}/{3})' -f $runId, $proc.Id, $mode, $optimize) -ForegroundColor Cyan
    return @{ runId = $runId; pid = $proc.Id }
}

function Stop-RepairRunner {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$RunId)
    if (-not $PSCmdlet.ShouldProcess($RunId, 'abbrechen')) { return $false }
    $runDir = Join-Path $RunsDir $RunId
    if (-not (Test-Path -LiteralPath $runDir)) { return $false }
    Set-Content -LiteralPath (Join-Path $runDir 'cancel.flag') -Value 'cancel' -Encoding UTF8
    $pidFile = Join-Path $runDir 'runner.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $runnerPid = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$runnerPid) -and $runnerPid -gt 0) {
            Start-Sleep -Milliseconds 300
            try { Stop-Process -Id $runnerPid -Force -ErrorAction Stop } catch { Write-Verbose 'Prozess bereits beendet.' }
        }
    }
    Start-Sleep -Milliseconds 200
    [void](Set-StateCancelled -Directory $runDir -Confirm:$false)
    return $true
}

function Set-StateCancelled {
    <#  Nach dem Abbruch schreibt niemand mehr in die Zustandsdatei - der
        Prozess ist ja tot. Ohne diesen Nachtrag bliebe der Vorgang fuer
        immer auf "running" stehen, auch im Verlauf. #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)][string]$Directory)

    $path = Join-Path $Directory 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($path, 'als abgebrochen vermerken')) { return $false }
    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.status -eq 'done') { return $false }

        # Laeufe und Datentraegerauftraege haben unterschiedliche Felder.
        # Ein fehlendes Feld einfach zuzuweisen wirft bei PSCustomObject eine
        # Ausnahme - deshalb hier anlegen statt annehmen.
        $setzen = {
            param($obj, $name, $wert)
            if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $wert }
            else { Add-Member -InputObject $obj -MemberType NoteProperty -Name $name -Value $wert -Force }
        }
        & $setzen $state 'status' 'done'
        & $setzen $state 'ok' $false
        & $setzen $state 'detail' 'Vom Benutzer abgebrochen.'
        & $setzen $state 'endTime' ((Get-Date).ToString('o'))
        if ($state.PSObject.Properties.Name -contains 'overall') { $state.overall = 'WARNING' }
        $eintrag = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss'); kind = 'warn'; text = 'Vom Benutzer abgebrochen.' }
        if ($state.PSObject.Properties.Name -contains 'log') { $state.log = @($state.log) + , $eintrag }
        else { & $setzen $state 'log' @($eintrag) }
        $tmp = $path + '.tmp'
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmp -Destination $path -Force
        return $true
    }
    catch { Write-Verbose 'Abbruchvermerk nicht schreibbar.'; return $false }
}

function Get-DiskJobState {
    param([string]$JobId)
    $path = Join-Path (Join-Path $DiskJobsDir $JobId) 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

$script:ActiveDiskJobId = $null

function Test-DiskJobRunning {
    <#  Nur ein Datentraegervorgang zur Zeit - zwei gleichzeitige Loeschungen
        auf demselben Rechner sind nie gewollt.

        Wichtig: Der Auftragsprozess braucht rund eine Sekunde, bis er seine
        Zustandsdatei anlegt. Wuerde nur diese Datei geprueft, kaeme in genau
        diesem Fenster ein zweiter Auftrag durch. Deshalb merkt sich der
        Dienst den zuletzt gestarteten Auftrag zusaetzlich selbst. #>
    if ($script:ActiveDiskJobId) {
        $dir = Join-Path $DiskJobsDir $script:ActiveDiskJobId
        $sf = Join-Path $dir 'state.json'
        $stillRunning = $true
        if (Test-Path -LiteralPath $sf) {
            try {
                $st = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($st.status -eq 'done') { $stillRunning = $false }
            }
            catch { Write-Verbose 'Zustand noch nicht lesbar.' }
        }
        # Prozess gestorben, ohne fertig zu werden? Dann Sperre loesen.
        $pidFile = Join-Path $dir 'runner.pid'
        if ($stillRunning -and (Test-Path -LiteralPath $pidFile)) {
            $jobPid = 0
            if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$jobPid) -and $jobPid -gt 0) {
                if (-not (Get-Process -Id $jobPid -ErrorAction SilentlyContinue)) { $stillRunning = $false }
            }
        }
        if ($stillRunning) { return $script:ActiveDiskJobId }
        $script:ActiveDiskJobId = $null
    }

    $dirs = Get-ChildItem -LiteralPath $DiskJobsDir -Directory -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        $sf = Join-Path $d.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $sf)) { continue }
        try {
            $st = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.status -ne 'running') { continue }
        }
        catch { continue }
        # Laeuft der Prozess ueberhaupt noch?
        $pidFile = Join-Path $d.FullName 'runner.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $jobPid = 0
            if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$jobPid) -and $jobPid -gt 0) {
                if (Get-Process -Id $jobPid -ErrorAction SilentlyContinue) { return $d.Name }
            }
        }
    }
    return $null
}

function Start-DiskJob {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$Action, $Body)
    if (-not $PSCmdlet.ShouldProcess(('Datentraegerauftrag ' + $Action), 'starten')) { return @{ error = 'abgebrochen' } }
    $jobId = New-DiskJobId -Action $Action
    $jobDir = Join-Path $DiskJobsDir $jobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null

    # Zustand sofort anlegen und Sperre setzen - noch bevor der Prozess
    # ueberhaupt laeuft. Sonst entsteht ein Fenster fuer einen zweiten Auftrag.
    $script:ActiveDiskJobId = $jobId
    $initial = [ordered]@{
        jobId = $jobId; action = $Action; status = 'running'; ok = $false; percent = 0
        stage = 'start'; stages = @(); startTime = (Get-Date).ToString('o')
        detail = 'Auftrag wird gestartet ...'
        log = @([ordered]@{ t = (Get-Date).ToString('HH:mm:ss'); kind = 'info'; text = 'Auftrag wird gestartet ...' })
    }
    [void](Write-StateFileAtomic -Path (Join-Path $jobDir 'state.json') -Object ([pscustomobject]$initial) -Depth 5 -Confirm:$false)

    $q = { param($v) return ('"{0}"' -f (([string]$v) -replace '"', '')) }
    $a = New-Object System.Collections.ArrayList
    foreach ($x in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $q $DiskJobPath),
            '-JobId', $jobId, '-Action', $Action, '-LogRoot', (& $q ($LogRoot.TrimEnd('\'))))) { [void]$a.Add($x) }

    if ($null -ne $Body.diskNumber) { [void]$a.Add('-DiskNumber'); [void]$a.Add([int]$Body.diskNumber) }
    if ($Body.driveLetter) { [void]$a.Add('-DriveLetter'); [void]$a.Add([string]$Body.driveLetter) }
    if ($Body.fileSystem) { [void]$a.Add('-FileSystem'); [void]$a.Add([string]$Body.fileSystem) }
    if ($Body.label) { [void]$a.Add('-Label'); [void]$a.Add((& $q ([string]$Body.label))) }
    if ($Body.allocationUnitSize) { [void]$a.Add('-AllocationUnitSize'); [void]$a.Add([int]$Body.allocationUnitSize) }
    if ($Body.strategy) { [void]$a.Add('-Strategy'); [void]$a.Add([string]$Body.strategy) }
    if ($Body.confirmation) { [void]$a.Add('-Confirmation'); [void]$a.Add([string]$Body.confirmation) }
    if ($Body.bufferMiB) { [void]$a.Add('-BufferMiB'); [void]$a.Add([int]$Body.bufferMiB) }
    if ($Body.queueDepth) { [void]$a.Add('-QueueDepth'); [void]$a.Add([int]$Body.queueDepth) }
    if ($Body.rescueTarget) { [void]$a.Add('-RescueTarget'); [void]$a.Add((& $q ([string]$Body.rescueTarget))) }
    if ($Body.rescueMode) { [void]$a.Add('-RescueMode'); [void]$a.Add([string]$Body.rescueMode) }
    if ($Body.rescueThreads) { [void]$a.Add('-RescueThreads'); [void]$a.Add([int]$Body.rescueThreads) }
    if ($Body.rescueUnbuffered) { [void]$a.Add('-RescueUnbuffered') }
    if ($Body.samples) { [void]$a.Add('-Samples'); [void]$a.Add([int]$Body.samples) }
    if ($Body.skipSurface) { [void]$a.Add('-SkipSurface') }
    if ($Body.path) { [void]$a.Add('-Path'); [void]$a.Add((& $q ([string]$Body.path))) }
    if ($Body.deep) { [void]$a.Add('-Deep') }
    if ($Body.scanJobId) { [void]$a.Add('-ScanJobId'); [void]$a.Add([string]$Body.scanJobId) }
    if ($Body.repairStrategy) { [void]$a.Add('-RepairStrategy'); [void]$a.Add([string]$Body.repairStrategy) }
    if ($Body.target) { [void]$a.Add('-Target'); [void]$a.Add((& $q ([string]$Body.target))) }
    if ($Body.archiveFormat) { [void]$a.Add('-ArchiveFormat'); [void]$a.Add([string]$Body.archiveFormat) }
    if ($Body.archiveLevel) { [void]$a.Add('-ArchiveLevel'); [void]$a.Add([string]$Body.archiveLevel) }
    if ($Body.copyMode) { [void]$a.Add('-CopyMode'); [void]$a.Add([string]$Body.copyMode) }
    if ($Body.threads) { [void]$a.Add('-Threads'); [void]$a.Add([int]$Body.threads) }
    if ($Body.unbuffered) { [void]$a.Add('-Unbuffered') }
    if ($Body.full) { [void]$a.Add('-Full') }
    if ($Body.allowDataLoss) { [void]$a.Add('-AllowDataLoss') }
    if ($Demo -or $Body.demo) { [void]$a.Add('-Demo') }

    $exe = Get-PowerShellExecutable
    try {
        if ($IsWindowsHost) { $proc = Start-Process -FilePath $exe -ArgumentList $a -WindowStyle Hidden -PassThru }
        else { $proc = Start-Process -FilePath $exe -ArgumentList $a -PassThru }
    }
    catch {
        # Start misslungen: Sperre wieder freigeben, sonst blockiert sie dauerhaft.
        $script:ActiveDiskJobId = $null
        throw
    }
    Set-Content -LiteralPath (Join-Path $jobDir 'runner.pid') -Value ([string]$proc.Id) -Encoding UTF8
    Write-Host ('  -> Datentraegerauftrag {0} gestartet (PID {1})' -f $jobId, $proc.Id) -ForegroundColor Cyan
    return @{ jobId = $jobId; pid = $proc.Id }
}

function Stop-DiskJob {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$JobId)
    if (-not $PSCmdlet.ShouldProcess($JobId, 'abbrechen')) { return $false }
    $pidFile = Join-Path (Join-Path $DiskJobsDir $JobId) 'runner.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    $jobPid = 0
    if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$jobPid) -and $jobPid -gt 0) {
        try { Stop-Process -Id $jobPid -Force -ErrorAction Stop }
        catch { Write-Verbose 'Auftrag bereits beendet.' }
    }
    Start-Sleep -Milliseconds 200
    [void](Set-StateCancelled -Directory (Join-Path $DiskJobsDir $JobId) -Confirm:$false)
    if ($script:ActiveDiskJobId -eq $JobId) { $script:ActiveDiskJobId = $null }
    return $true
}

function Get-ReadinessStep {
    <#
    .SYNOPSIS
        Fuehrt genau einen Bereitschaftspunkt aus.
    .DESCRIPTION
        Die gesamte Pruefung dauert auf einem Rechner mit mehreren
        Datentraegern einige Sekunden - und solange sah man nur "wird
        geprueft". Schrittweise abgerufen waechst die Liste sichtbar.
    #>
    param([Parameter(Mandatory)][string]$Step)

    $alle = @('os', 'admin', 'mode', 'smart', 'counters', 'events', 'raw', 'shadow', 'tools')
    if ($Step -eq 'list') { return @{ steps = $alle } }

    $name = ''; $status = 'WARNING'; $detail = ''
    # Ein einzelner Pruefpunkt darf nie die gesamte Pruefung kippen.
    # Faellt er aus, wird genau das gemeldet - mit Grund.
    try {
    switch ($Step) {
        'os' {
            $name = 'Betriebssystem'
            if ($IsWindowsHost) {
                $status = 'PASS'
                try { $detail = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption.Trim() }
                catch { $detail = 'Windows' }
            }
            else { $status = 'FAILED'; $detail = 'Kein Windows - es laufen nur Demodaten.' }
        }
        'admin' {
            $name = 'Administratorrechte'
            $admin = $false
            try {
                $k = [Security.Principal.WindowsIdentity]::GetCurrent()
                $admin = (New-Object Security.Principal.WindowsPrincipal($k)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            }
            catch { $admin = $false }
            $status = $(if ($admin) { 'PASS' } else { 'FAILED' })
            $detail = $(if ($admin) { 'Vorhanden.' } else { 'Fehlen - ohne sie sind Rohzugriff, SFC und Datentraegervorgaenge nicht moeglich.' })
        }
        'mode' {
            $name = 'Betriebsart'
            $status = $(if ($Demo) { 'WARNING' } else { 'PASS' })
            $detail = $(if ($Demo) { 'Demomodus: alle Werte sind erfunden. Fuer echte Messwerte ohne -Demo starten.' } else { 'Echtbetrieb - es werden echte Werte gelesen und echte Aenderungen vorgenommen.' })
        }
        'smart' {
            $name = 'SMART-Werte'
            if (-not $IsWindowsHost) { $status = 'WARNING'; $detail = 'Nur unter Windows lesbar.'; break }
            $ok = 0; $gesamt = 0
            try {
                foreach ($d in (Get-Disk -ErrorAction Stop)) {
                    $gesamt++
                    if ((Get-SmartAttribute -DiskNumber ([int]$d.Number)).available) { $ok++ }
                }
            }
            catch { $detail = $_.Exception.Message }
            if ($gesamt -eq 0) { $status = 'WARNING'; $detail = ('Keine Datentraeger gefunden. ' + $detail).Trim() }
            elseif ($ok -eq $gesamt) { $status = 'PASS'; $detail = ('Bei allen {0} Datentraegern lesbar.' -f $gesamt) }
            elseif ($ok -gt 0) { $status = 'WARNING'; $detail = ('Nur bei {0} von {1} lesbar - USB-Gehaeuse und RAID-Controller reichen SMART oft nicht durch.' -f $ok, $gesamt) }
            else { $status = 'WARNING'; $detail = 'Bei keinem Datentraeger lesbar. Analyse stuetzt sich dann auf Ereignisse und Oberflaechenpruefung.' }
        }
        'counters' {
            $name = 'Zuverlaessigkeitszaehler'
            $da = [bool](Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)
            $status = $(if ($da) { 'PASS' } else { 'WARNING' })
            $detail = $(if ($da) { 'Verfuegbar.' } else { 'Nicht verfuegbar - aeltere Windows-Fassung oder fehlender Treiber.' })
        }
        'events' {
            $name = 'Ereignisprotokoll'
            $ok = $false
            try { Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction Stop | Out-Null; $ok = $true } catch { $ok = $false }
            $status = $(if ($ok) { 'PASS' } else { 'WARNING' })
            $detail = $(if ($ok) { 'Lesbar.' } else { 'Nicht lesbar - Datentraegerfehler aus der Vergangenheit bleiben unsichtbar.' })
        }
        'raw' {
            $name = 'Rohzugriff auf Datentraeger'
            if (-not $IsWindowsHost) { $status = 'WARNING'; $detail = 'Nur unter Windows.'; break }
            try {
                Initialize-DiskNative
                $strom = [RepairCenter.Storage.RawDevice]::Open('\\.\PhysicalDrive0', $true, $false)
                $strom.Dispose()
                $status = 'PASS'; $detail = 'Moeglich - Oberflaechenpruefung und Nullschreiben funktionieren.'
            }
            catch { $status = 'WARNING'; $detail = ('Nicht moeglich: ' + $_.Exception.Message) }
        }
        'shadow' {
            $name = 'Schattenkopien'
            $anzahl = 0
            try { $anzahl = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop).Count } catch { $anzahl = 0 }
            $status = $(if ($anzahl -gt 0) { 'PASS' } else { 'WARNING' })
            $detail = $(if ($anzahl -gt 0) { ('{0} vorhanden - beschaedigte Dateien lassen sich daraus zurueckholen.' -f $anzahl) }
                else { 'Keine vorhanden - Dateireparatur kann dann nur ueber SFC laufen (nur Systemdateien).' })
        }
        'tools' {
            $name = 'Bordwerkzeuge'
            if (-not $IsWindowsHost -or [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
                $status = 'WARNING'; $detail = 'Nur unter Windows vorhanden.'; break
            }
            $fehlt = @()
            foreach ($w in @('sfc.exe', 'dism.exe', 'chkdsk.exe', 'robocopy.exe')) {
                $pfad = Join-Path $env:SystemRoot ('System32\' + $w)
                if (-not (Test-Path -LiteralPath $pfad)) { $fehlt += $w }
            }
            $status = $(if ($fehlt.Count -eq 0) { 'PASS' } else { 'FAILED' })
            $detail = $(if ($fehlt.Count -eq 0) { 'sfc, dism, chkdsk und robocopy sind vorhanden.' } else { ('Es fehlen: ' + ($fehlt -join ', ')) })
        }
        default { return @{ error = ('Unbekannter Pruefpunkt: ' + $Step) } }
    }
    }
    catch {
        if (-not $name) { $name = $Step }
        return [ordered]@{ step = $Step; name = $name; status = 'WARNING'
            detail = ('Pruefung nicht moeglich: ' + $_.Exception.Message)
        }
    }
    return [ordered]@{ step = $Step; name = $name; status = $status; detail = $detail }
}

function Get-ReadinessReport {
    <#
    .SYNOPSIS
        Prueft, was auf diesem Rechner wirklich auslesbar ist.
    .DESCRIPTION
        Vor dem ersten Einsatz auf echter Hardware ist die wichtigste
        Frage: welche Messwerte liefert dieses System ueberhaupt? SMART
        ist ueber USB-Gehaeuse und RAID-Controller oft nicht erreichbar,
        Schattenkopien sind manchmal abgeschaltet, und ohne
        Administratorrechte geht fast nichts. Das hier sagt es vorher -
        statt dass hinterher leere Felder raetseln lassen.
    #>
    $punkte = New-Object System.Collections.ArrayList
    function Add-Punkt {
        param([string]$Name, [string]$Status, [string]$Detail)
        [void]$script:_punkte.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
    }
    $script:_punkte = $punkte

    if (-not $IsWindowsHost) {
        Add-Punkt 'Betriebssystem' 'FAILED' 'Kein Windows - es laufen nur Demodaten.'
        return [ordered]@{ windows = $false; ready = $false; demo = [bool]$Demo; checks = @($punkte) }
    }

    $admin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $admin = $false }
    Add-Punkt 'Administratorrechte' $(if ($admin) { 'PASS' } else { 'FAILED' }) `
        $(if ($admin) { 'Vorhanden.' } else { 'Fehlen - ohne sie sind Rohzugriff, SFC und Datentraegervorgaenge nicht moeglich.' })

    Add-Punkt 'Betriebsart' $(if ($Demo) { 'WARNING' } else { 'PASS' }) `
        $(if ($Demo) { 'Demomodus: alle Werte sind erfunden. Fuer echte Messwerte ohne -Demo starten.' } else { 'Produktiv - es werden echte Werte gelesen.' })

    # SMART je Datentraeger
    $smartOk = 0; $smartGesamt = 0
    try {
        foreach ($d in (Get-Disk -ErrorAction Stop)) {
            $smartGesamt++
            $w = Get-SmartAttribute -DiskNumber ([int]$d.Number)
            if ($w.available) { $smartOk++ }
        }
    }
    catch { Write-Verbose 'Datentraeger nicht aufzaehlbar.' }
    if ($smartGesamt -eq 0) { Add-Punkt 'SMART-Werte' 'WARNING' 'Keine Datentraeger gefunden.' }
    elseif ($smartOk -eq $smartGesamt) { Add-Punkt 'SMART-Werte' 'PASS' ('Bei allen {0} Datentraegern lesbar.' -f $smartGesamt) }
    elseif ($smartOk -gt 0) { Add-Punkt 'SMART-Werte' 'WARNING' ('Nur bei {0} von {1} Datentraegern lesbar - USB-Gehaeuse und RAID-Controller geben sie oft nicht weiter.' -f $smartOk, $smartGesamt) }
    else { Add-Punkt 'SMART-Werte' 'WARNING' 'Bei keinem Datentraeger lesbar. Die Analyse stuetzt sich dann auf Ereignisprotokoll und Oberflaechenpruefung.' }

    Add-Punkt 'Zuverlaessigkeitszaehler' $(if (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue) { 'PASS' } else { 'WARNING' }) `
        $(if (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue) { 'Verfuegbar.' } else { 'Nicht verfuegbar - aeltere Windows-Fassung oder fehlender Treiber.' })

    $ereignisOk = $false
    try { Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction Stop | Out-Null; $ereignisOk = $true } catch { $ereignisOk = $false }
    Add-Punkt 'Ereignisprotokoll' $(if ($ereignisOk) { 'PASS' } else { 'WARNING' }) `
        $(if ($ereignisOk) { 'Lesbar.' } else { 'Nicht lesbar - Datentraegerfehler aus der Vergangenheit bleiben unsichtbar.' })

    $rohOk = $false; $rohGrund = ''
    try {
        Initialize-DiskNative
        $strom = [RepairCenter.Storage.RawDevice]::Open('\\.\PhysicalDrive0', $true, $false)
        $strom.Dispose(); $rohOk = $true
    }
    catch { $rohGrund = $_.Exception.Message }
    Add-Punkt 'Rohzugriff auf Datentraeger' $(if ($rohOk) { 'PASS' } else { 'WARNING' }) `
        $(if ($rohOk) { 'Moeglich - Oberflaechenpruefung und Nullschreiben funktionieren.' } else { ('Nicht moeglich: {0}' -f $rohGrund) })

    $vss = $false
    try { $vss = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop).Count -gt 0 } catch { $vss = $false }
    Add-Punkt 'Schattenkopien' $(if ($vss) { 'PASS' } else { 'WARNING' }) `
        $(if ($vss) { 'Vorhanden - beschaedigte Dateien lassen sich daraus zurueckholen.' } else { 'Keine vorhanden - Dateireparatur kann dann nur ueber SFC laufen (nur Systemdateien).' })

    foreach ($werkzeug in @('sfc.exe', 'dism.exe', 'chkdsk.exe', 'robocopy.exe')) {
        $pfad = Join-Path $env:SystemRoot ('System32\' + $werkzeug)
        Add-Punkt ('Werkzeug ' + $werkzeug) $(if (Test-Path -LiteralPath $pfad) { 'PASS' } else { 'FAILED' }) `
            $(if (Test-Path -LiteralPath $pfad) { $pfad } else { 'nicht gefunden' })
    }

    $bereit = (@($punkte | Where-Object { $_.status -eq 'FAILED' }).Count -eq 0)
    return [ordered]@{ windows = $true; ready = $bereit; demo = [bool]$Demo; checks = @($punkte) }
}

function Get-UpdateInformation {
    <#
    .SYNOPSIS
        Prueft, ob in einem Ordner eine neuere Fassung bereitliegt.
    .DESCRIPTION
        Bewusst ohne Internet: RepairCenter laedt nichts nach. Geprueft
        wird ein Ordner - Wechseldatentraeger, Netzlaufwerk oder
        Downloadordner - auf Dateien der Form RepairCenter-X.Y.Z.zip.
        Gefunden wird nur gemeldet; eingespielt wird ueber den Installer,
        damit kein laufender Dienst sich selbst unter den Fuessen
        wegzieht.
    #>
    param([string]$Source)

    $aktuell = '1.5.1'
    if (-not $Source) {
        $Source = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
        if (-not $IsWindowsHost) { $Source = [System.IO.Path]::GetTempPath() }
    }
    $antwort = [ordered]@{
        currentVersion = $aktuell
        source         = $Source
        available      = $false
        newestVersion  = $null
        file           = $null
        checked        = (Get-Date).ToString('o')
        note           = ''
    }
    if (-not (Test-Path -LiteralPath $Source)) {
        $antwort.note = 'Der angegebene Ordner wurde nicht gefunden.'
        return $antwort
    }
    try {
        $treffer = Get-ChildItem -LiteralPath $Source -Filter 'RepairCenter-*.zip' -File -ErrorAction SilentlyContinue
        $beste = $null
        foreach ($t in $treffer) {
            if ($t.Name -match 'RepairCenter-(\d+)\.(\d+)\.(\d+)\.zip') {
                $v = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
                if (-not $beste -or $v -gt $beste.Version) { $beste = @{ Version = $v; File = $t.FullName } }
            }
        }
        if ($beste) {
            $antwort.newestVersion = $beste.Version.ToString()
            $antwort.file = $beste.File
            $antwort.available = ($beste.Version -gt [version]$aktuell)
            $antwort.note = $(if ($antwort.available) {
                    'Eine neuere Fassung liegt bereit. Zum Einspielen den Dienst beenden und installer\Install.cmd aus dem neuen Paket ausfuehren.'
                }
                else { 'Es liegt keine neuere Fassung vor.' })
        }
        else { $antwort.note = 'In diesem Ordner liegt kein Paket der Form RepairCenter-X.Y.Z.zip.' }
    }
    catch { $antwort.note = $_.Exception.Message }
    return $antwort
}

function Start-UpdateApply {
    <#
    .SYNOPSIS
        Spielt ein Paket ein und startet den Dienst neu.
    .DESCRIPTION
        Der Dienst kann sich nicht selbst ueberschreiben, solange er
        laeuft. Deshalb wird tools\Apply-Update.ps1 als eigener Prozess
        gestartet; der wartet, bis dieser Dienst beendet ist, legt eine
        Sicherung an, spielt ein und startet neu. Danach beendet sich
        dieser Dienst selbst.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($Body)

    if ($Demo) { return @{ ok = $false; reason = 'Im Demomodus ist das Einspielen abgeschaltet.' } }
    if (-not $IsWindowsHost) { return @{ ok = $false; reason = 'Nur unter Windows moeglich.' } }
    $laeuft = Test-DiskJobRunning
    if ($laeuft) { return @{ ok = $false; reason = ('Es laeuft ein Vorgang ({0}) - bitte abwarten.' -f $laeuft) } }

    $info = Get-UpdateInformation -Source $(if ($Body -and $Body.source) { [string]$Body.source } else { $null })
    if (-not $info.available) { return @{ ok = $false; reason = $info.note } }
    if (-not $PSCmdlet.ShouldProcess($info.file, 'Aktualisierung einspielen')) { return @{ ok = $false; reason = 'abgebrochen' } }

    $installDir = Split-Path -Parent $ScriptDir
    $helfer = Join-Path (Join-Path $installDir 'tools') 'Apply-Update.ps1'
    if (-not (Test-Path -LiteralPath $helfer)) { return @{ ok = $false; reason = 'Apply-Update.ps1 wurde nicht gefunden.' } }

    $protokoll = Join-Path $LogRoot ('Update-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $exe = Get-PowerShellExecutable
    $argumente = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helfer),
        '-Package', ('"{0}"' -f $info.file), '-InstallDir', ('"{0}"' -f $installDir),
        '-ServicePid', $PID, '-Port', $Port, '-LogFile', ('"{0}"' -f $protokoll))
    Start-Process -FilePath $exe -ArgumentList $argumente -WindowStyle Hidden | Out-Null

    # Dem Helfer Zeit geben, dann selbst Platz machen.
    $script:ShutdownRequested = $true
    return @{
        ok = $true; version = $info.newestVersion; package = $info.file; log = $protokoll
        reason = ('Wird eingespielt. Der Dienst beendet sich jetzt und startet in wenigen Sekunden neu. Protokoll: {0}' -f $protokoll)
    }
}

$script:ShutdownRequested = $false
$script:TaskName = 'RepairCenter\Woechentliche Wartung'

function Get-MaintenanceSchedule {
    if (-not $IsWindowsHost) { return @{ supported = $false; exists = $false; reason = 'nur unter Windows' } }
    try {
        $out = & (Join-Path $env:SystemRoot 'System32\schtasks.exe') '/Query' '/TN' $script:TaskName '/FO' 'LIST' 2>&1
        $exists = ($LASTEXITCODE -eq 0)
        return @{ supported = $true; exists = $exists; detail = (($out | Select-Object -First 8) -join "`n") }
    }
    catch { return @{ supported = $true; exists = $false; detail = $_.Exception.Message } }
}

function Set-MaintenanceSchedule {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($Body)
    if (-not $PSCmdlet.ShouldProcess('Wartungsaufgabe', 'anlegen')) { return @{ ok = $false; reason = 'abgebrochen' } }
    if (-not $IsWindowsHost) { return @{ ok = $false; reason = 'nur unter Windows' } }
    $day = 'SUN'; $time = '03:00'; $mode = 'Quick'; $optimize = 'Safe'
    if ($Body -and $Body.day) { $day = [string]$Body.day }
    if ($Body -and $Body.time) { $time = [string]$Body.time }
    if ($Body -and $Body.mode) { $mode = [string]$Body.mode }
    if ($Body -and $Body.optimize) { $optimize = [string]$Body.optimize }

    $cli = Join-Path $ScriptDir 'RepairCenter.Cli.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode {2} -Optimize {3} -NoElevate' -f $ps, $cli, $mode, $optimize)
    try {
        & (Join-Path $env:SystemRoot 'System32\schtasks.exe') '/Create' '/TN' $script:TaskName '/SC' 'WEEKLY' `
            '/D' $day '/ST' $time '/RL' 'HIGHEST' '/RU' 'SYSTEM' '/F' '/TR' $action | Out-Null
        return @{ ok = ($LASTEXITCODE -eq 0); day = $day; time = $time; mode = $mode; optimize = $optimize }
    }
    catch { return @{ ok = $false; reason = $_.Exception.Message } }
}

function Remove-MaintenanceSchedule {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param()
    if (-not $PSCmdlet.ShouldProcess('Wartungsaufgabe', 'entfernen')) { return @{ ok = $false; reason = 'abgebrochen' } }
    if (-not $IsWindowsHost) { return @{ ok = $false; reason = 'nur unter Windows' } }
    try {
        & (Join-Path $env:SystemRoot 'System32\schtasks.exe') '/Delete' '/TN' $script:TaskName '/F' | Out-Null
        return @{ ok = ($LASTEXITCODE -eq 0) }
    }
    catch { return @{ ok = $false; reason = $_.Exception.Message } }
}

function Request-SystemRestart {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if (-not $PSCmdlet.ShouldProcess('Windows', 'neu starten')) { return @{ ok = $false; reason = 'abgebrochen' } }
    if (-not $IsWindowsHost) { return @{ ok = $false; reason = 'nur unter Windows' } }
    if ($Demo) { return @{ ok = $false; reason = 'im Demomodus deaktiviert' } }
    try {
        & (Join-Path $env:SystemRoot 'System32\shutdown.exe') '/r' '/t' '60' '/c' 'RepairCenter: Neustart zum Abschluss der Reparatur' | Out-Null
        return @{ ok = $true; delaySeconds = 60 }
    }
    catch { return @{ ok = $false; reason = $_.Exception.Message } }
}

#endregion

#region ---------------------------- Routing ---------------------------

function Invoke-Route {
    param($Context)
    $req = $Context.Request
    $res = $Context.Response
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if ([string]::IsNullOrEmpty($path)) { $path = '/' }
    $method = $req.HttpMethod

    # Vorabanfragen werden nicht beantwortet - fremde Seiten sollen den
    # Dienst gar nicht erst ansprechen koennen.
    if ($method -eq 'OPTIONS') {
        Write-HttpText -Response $res -Content '' -StatusCode 405
        return
    }
    $trust = Test-RequestTrusted -Request $req
    if (-not $trust.ok) {
        Write-Host ('  Abgewiesen: {0} {1} - {2}' -f $method, $path, $trust.reason) -ForegroundColor Yellow
        Write-HttpJson -Response $res -Object @{ error = $trust.reason } -StatusCode 403
        return
    }

    # ---------- API ----------
    if ($path -eq '/api/health') {
        Write-HttpJson -Response $res -Object @{ ok = $true; version = '1.5.1'; demo = [bool]$Demo }
        return
    }
    if ($path -eq '/api/system') {
        $snap = Get-SystemSnapshot
        $snap.logRoot = $LogRoot
        $snap.demo = [bool]$Demo
        Write-HttpJson -Response $res -Object $snap
        return
    }
    if ($path -eq '/api/config') {
        Write-HttpJson -Response $res -Object @{
            version   = '1.5.1'
            logRoot   = $LogRoot
            demo      = [bool]$Demo
            isWindows = $IsWindowsHost
            port      = $Port
        }
        return
    }
    if ($path -eq '/api/schedule') {
        if ($method -eq 'GET') { Write-HttpJson -Response $res -Object (Get-MaintenanceSchedule); return }
        if ($method -eq 'POST') {
            $body = Read-RequestBody -Request $req
            if ($body) {
                $checked = Get-CheckedRequest -Kind 'Schedule' -Body $body
                if (-not $checked.ok) {
                    Write-HttpJson -Response $res -Object @{ error = 'Ungueltige Angaben'; problems = $checked.problems } -StatusCode 400
                    return
                }
                $body = [pscustomobject]$checked.body
            }
            Write-HttpJson -Response $res -Object (Set-MaintenanceSchedule -Body $body)
            return
        }
        if ($method -eq 'DELETE') { Write-HttpJson -Response $res -Object (Remove-MaintenanceSchedule); return }
    }
    if ($path -eq '/api/restart' -and $method -eq 'POST') {
        Write-HttpJson -Response $res -Object (Request-SystemRestart)
        return
    }
    if ($path -eq '/api/disks') {
        $liste = @(Get-DiskInventory -Demo:$Demo)
        if ($liste.Count -eq 0) {
            # Leere Liste ohne Erklaerung ist das Schlimmste: die Oberflaeche
            # zeigte dann eine leere Auswahl und niemand wusste warum.
            $grund = Get-DiskInventoryError
            if (-not $grund) { $grund = 'Es wurden keine Datentraeger gefunden.' }
            Write-Host ('  Datentraegerliste leer: {0}' -f $grund) -ForegroundColor Yellow
            Write-HttpJson -Response $res -StatusCode 500 -Object @{
                error = ('Datentraeger konnten nicht gelesen werden: {0}' -f $grund)
                hint  = 'Laeuft RepairCenter als Administrator? Der Dienst "Virtueller Datentraeger" (vds) muss gestartet sein.'
            }
            return
        }
        Write-HttpJson -Response $res -Object $liste -AsArray
        return
    }
    if ($path -eq '/api/disk/estimate') {
        $num = [int]$req.QueryString['number']
        $strategy = $req.QueryString['strategy']
        if (-not $strategy) { $strategy = 'Auto' }
        $disk = @(Get-DiskInventory -Demo:$Demo) | Where-Object { $_.number -eq $num } | Select-Object -First 1
        if (-not $disk) { Write-HttpJson -Response $res -Object @{ error = 'unbekannter Datentraeger' } -StatusCode 404; return }
        $eff = Get-WipeStrategy -Disk $disk -Requested $strategy
        $est = Get-WipeEstimate -SizeBytes $disk.sizeBytes -Strategy $eff -BusType $disk.busType -MediaType $disk.mediaType
        Write-HttpJson -Response $res -Object @{
            strategy = $eff; seconds = $est.seconds; readable = (Format-Duration $est.seconds)
            throughputMBs = $est.throughputMBs; note = $est.note
            confirmationToken = ('DISK' + $disk.number)
            protected = $disk.protected; protectReason = $disk.protectReason
        }
        return
    }
    if ($path -eq '/api/files/tools') {
        Write-HttpJson -Response $res -Object (Get-ArchiveToolInfo)
        return
    }
    if ($path -match '^/api/files/(scan|repair|archive|copy)$' -and $method -eq 'POST') {
        $action = @{ scan = 'FileScan'; repair = 'FileRepair'; archive = 'Archive'; copy = 'CopyFolder' }[$Matches[1]]
        $body = Read-RequestBody -Request $req
        if (-not $body) { Write-HttpJson -Response $res -Object @{ error = 'keine Daten' } -StatusCode 400; return }
        $checked = Get-CheckedRequest -Kind $action -Body $body
        if (-not $checked.ok) {
            Write-HttpJson -Response $res -Object @{ error = 'Ungueltige Angaben'; problems = $checked.problems } -StatusCode 400
            return
        }
        $running = Test-DiskJobRunning
        if ($running) {
            Write-HttpJson -Response $res -Object @{ error = ('Es laeuft bereits ein Vorgang ({0}).' -f $running); runningJob = $running } -StatusCode 409
            return
        }
        try { Write-HttpJson -Response $res -Object (Start-DiskJob -Action $action -Body ([pscustomobject]$checked.body)) }
        catch { Write-HttpJson -Response $res -Object @{ error = $_.Exception.Message } -StatusCode 500 }
        return
    }
    if ($path -eq '/api/readiness') {
        $schritt = $req.QueryString['step']
        if ($schritt) {
            Write-HttpJson -Response $res -Object (Get-ReadinessStep -Step $schritt)
            return
        }
        Write-HttpJson -Response $res -Object (Get-ReadinessReport)
        return
    }
    if ($path -eq '/api/update/apply' -and $method -eq 'POST') {
        $body = Read-RequestBody -Request $req
        Write-HttpJson -Response $res -Object (Start-UpdateApply -Body $body -Confirm:$false)
        return
    }
    if ($path -eq '/api/update/check') {
        Write-HttpJson -Response $res -Object (Get-UpdateInformation -Source $req.QueryString['source'])
        return
    }
    if ($path -eq '/api/disk/active') {
        $running = Test-DiskJobRunning
        Write-HttpJson -Response $res -Object @{ running = $running; busy = [bool]$running }
        return
    }
    if ($path -eq '/api/disk/targets') {
        $exclude = -1
        if ($req.QueryString['exclude']) { $exclude = [int]$req.QueryString['exclude'] }
        Write-HttpJson -Response $res -Object @(Get-BackupTarget -ExcludeDiskNumber $exclude -Demo:$Demo) -AsArray
        return
    }
    if ($path -eq '/api/disk/measure') {
        $num = [int]$req.QueryString['number']
        $disk = @(Get-DiskInventory -Demo:$Demo) | Where-Object { $_.number -eq $num } | Select-Object -First 1
        if (-not $disk) { Write-HttpJson -Response $res -Object @{ error = 'unbekannter Datentraeger' } -StatusCode 404; return }
        $files = 0; $bytes = 0
        foreach ($v in @($disk.volumes)) {
            if (-not $v.driveLetter) { continue }
            $m = Measure-VolumeContent -DriveLetter $v.driveLetter -Demo:$Demo
            $files += [long]$m.files; $bytes += [long]$m.bytes
        }
        Write-HttpJson -Response $res -Object @{
            files = $files; bytes = $bytes; readable = (Format-ByteSizeShort $bytes)
            volumes = @(@($disk.volumes) | ForEach-Object { $_.driveLetter })
        }
        return
    }
    if ($path -match '^/api/disk/(format|convert|wipe|rescue|analyze)$' -and $method -eq 'POST') {
        $action = @{ format = 'Format'; convert = 'Convert'; wipe = 'Wipe'; rescue = 'Rescue'; analyze = 'Analyze' }[$Matches[1]]
        $body = Read-RequestBody -Request $req
        if (-not $body) { Write-HttpJson -Response $res -Object @{ error = 'keine Daten' } -StatusCode 400; return }

        $checked = Get-CheckedRequest -Kind $action -Body $body
        if (-not $checked.ok) {
            Write-HttpJson -Response $res -Object @{ error = 'Ungueltige Angaben'; problems = $checked.problems } -StatusCode 400
            return
        }
        $running = Test-DiskJobRunning
        if ($running) {
            Write-HttpJson -Response $res -Object @{
                error = ('Es laeuft bereits ein Datentraegervorgang ({0}). Bitte abwarten oder abbrechen.' -f $running)
                runningJob = $running
            } -StatusCode 409
            return
        }
        try { Write-HttpJson -Response $res -Object (Start-DiskJob -Action $action -Body ([pscustomobject]$checked.body)) }
        catch { Write-HttpJson -Response $res -Object @{ error = $_.Exception.Message } -StatusCode 500 }
        return
    }
    if ($path -match '^/api/disk/job/([A-Za-z0-9\-]+)/cancel$' -and $method -eq 'POST') {
        Write-HttpJson -Response $res -Object @{ cancelled = (Stop-DiskJob -JobId $Matches[1]) }
        return
    }
    if ($path -match '^/api/disk/job/([A-Za-z0-9\-]+)$') {
        $st = Get-DiskJobState -JobId $Matches[1]
        if (-not $st) { Write-HttpJson -Response $res -Object @{ error = 'unbekannter Auftrag' } -StatusCode 404; return }
        Write-HttpJson -Response $res -Object $st
        return
    }
    if ($path -eq '/api/runs') {
        Write-HttpJson -Response $res -Object @(Get-RunHistory) -AsArray
        return
    }
    if ($path -eq '/api/run' -and $method -eq 'POST') {
        $body = Read-RequestBody -Request $req
        if ($body) {
            $checked = Get-CheckedRequest -Kind 'Run' -Body $body
            if (-not $checked.ok) {
                Write-HttpJson -Response $res -Object @{ error = 'Ungueltige Angaben'; problems = $checked.problems } -StatusCode 400
                return
            }
            $body = [pscustomobject]$checked.body
        }
        try { Write-HttpJson -Response $res -Object (Start-RepairRunner -Body $body) }
        catch { Write-HttpJson -Response $res -Object @{ error = $_.Exception.Message } -StatusCode 500 }
        return
    }
    if ($path -match '^/api/run/([0-9a-fA-F\-]+)/cancel$' -and $method -eq 'POST') {
        $ok = Stop-RepairRunner -RunId $Matches[1]
        Write-HttpJson -Response $res -Object @{ cancelled = $ok }
        return
    }
    if ($path -match '^/api/run/([0-9a-fA-F\-]+)$' -and $method -eq 'DELETE') {
        $runId = $Matches[1]
        $dir = Join-Path $RunsDir $runId
        if (-not (Test-Path -LiteralPath $dir)) {
            Write-HttpJson -Response $res -Object @{ error = 'unbekannte Lauf-ID' } -StatusCode 404
            return
        }
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
            if ($script:GemeldeteDefekte.ContainsKey($runId)) { [void]$script:GemeldeteDefekte.Remove($runId) }
            Write-Host ('  Lauf {0} entfernt.' -f $runId) -ForegroundColor DarkGray
            Write-HttpJson -Response $res -Object @{ removed = $true; runId = $runId }
        }
        catch { Write-HttpJson -Response $res -Object @{ error = $_.Exception.Message } -StatusCode 500 }
        return
    }
    if ($path -match '^/api/run/([0-9a-fA-F\-]+)$') {
        $st = Get-RunState -RunId $Matches[1]
        if (-not $st) { Write-HttpJson -Response $res -Object @{ error = 'unbekannte Lauf-ID' } -StatusCode 404; return }
        Write-HttpJson -Response $res -Object $st
        return
    }
    if ($path -match '^/api/report/([0-9a-fA-F\-]+)$') {
        $runId = $Matches[1]
        $fmt = $req.QueryString['format']
        $dir = Join-Path $RunsDir $runId
        if ($fmt -eq 'json') { Write-HttpFile -Response $res -Path (Join-Path $dir 'state.json'); return }
        if ($fmt -eq 'tools') { Write-HttpFile -Response $res -Path (Join-Path $dir 'tools.log'); return }
        if ($fmt -eq 'cbs') {
            $cbs = Join-Path $dir 'CBS-SFC.txt'
            if (-not (Test-Path -LiteralPath $cbs)) { $cbs = Join-Path $dir 'CBS-SFC2.txt' }
            Write-HttpFile -Response $res -Path $cbs
            return
        }
        if ($fmt -eq 'transcript') { Write-HttpFile -Response $res -Path (Join-Path $dir 'transcript.log'); return }
        Write-HttpFile -Response $res -Path (Join-Path $dir 'report.txt')
        return
    }
    if ($path -like '/api/*') {
        Write-HttpJson -Response $res -Object @{ error = 'unbekannter Endpunkt' } -StatusCode 404
        return
    }

    # ---------- statische Dateien ----------
    if ($path -eq '/') { $path = '/index.html' }
    $safe = $path.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $full = Join-Path $WebRoot $safe
    $fullResolved = [System.IO.Path]::GetFullPath($full)
    if (-not $fullResolved.StartsWith([System.IO.Path]::GetFullPath($WebRoot))) {
        Write-HttpText -Response $res -Content '403' -StatusCode 403
        return
    }
    Write-HttpFile -Response $res -Path $fullResolved
}

#endregion

#region ---------------------------- Start -----------------------------

$listener = New-Object System.Net.HttpListener
$prefix = ('http://{0}:{1}/' -f $BindAddress, $Port)
$listener.Prefixes.Add($prefix)

try { $listener.Start() }
catch {
    Write-Host ''
    Write-Host ('  FEHLER: Der Dienst konnte nicht auf {0} starten.' -f $prefix) -ForegroundColor Red
    Write-Host ('  {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '  Moegliche Ursachen: Port belegt, oder Bindung an * ohne Administratorrechte.'
    exit 1
}

$url = ('http://{0}:{1}/' -f $(if ($BindAddress -eq '*' -or $BindAddress -eq '+') { 'localhost' } else { $BindAddress }), $Port)
Write-Host ''
Write-Host '  ====================================================' -ForegroundColor DarkCyan
Write-Host '   RepairCenter 1.5.1' -ForegroundColor Cyan
Write-Host '  ====================================================' -ForegroundColor DarkCyan
Write-Host ('   Oberflaeche : {0}' -f $url)
Write-Host ('   Berichte    : {0}' -f $LogRoot)
Write-Host ('   Modus       : {0}' -f $(if ($Demo) { 'DEMO (keine echten Eingriffe)' } else { 'produktiv' }))
Write-Host '   Beenden     : Strg+C'
Write-Host ''

if (-not $NoBrowser -and $IsWindowsHost) {
    try { Start-Process $url | Out-Null } catch { Write-Verbose 'Browser nicht startbar.' }
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try { Invoke-Route -Context $context }
        catch {
            Write-Host ('  Anfragefehler: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
            try { Write-HttpJson -Response $context.Response -Object @{ error = $_.Exception.Message } -StatusCode 500 }
            catch { Write-Verbose 'Antwort bereits geschlossen.' }
        }

        # Nach dem Einspielen macht der Dienst Platz fuer die neue Fassung.
        # Diese Pruefung steht bewusst NICHT in einem finally-Block:
        # Windows PowerShell 5.1 verbietet dort jede Ablaufsteuerung.
        if ($script:ShutdownRequested) {
            Write-Host '  Aktualisierung laeuft - der Dienst beendet sich jetzt.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            break
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Host '  Dienst beendet.' -ForegroundColor DarkGray
}

#endregion
