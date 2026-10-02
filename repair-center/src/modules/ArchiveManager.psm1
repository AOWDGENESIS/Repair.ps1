#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - ArchiveManager
 Version: 1.6.0 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 Daten packen und schnell auf ein anderes Laufwerk uebertragen.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
 Drei Wege, bewusst unterschieden:

 ZIP      Immer verfuegbar - Windows bringt alles mit. Gepackt wird hier
          Datei fuer Datei ueber ZipArchive statt mit Compress-Archive:
          nur so laesst sich ein Fortschritt melden, und eine gesperrte
          Datei bricht nicht den ganzen Vorgang ab.
 7z       Falls 7-Zip installiert ist. Packt deutlich kleiner und nutzt
          alle Kerne.
 RAR      Nur mit installiertem WinRAR moeglich - das Format ist
          proprietaer, es gibt keinen freien Packer dafuer. Fehlt WinRAR,
          wird das ehrlich gesagt statt es zu verschweigen.

 Fuer das reine Uebertragen ohne Packen ist robocopy die schnellste
 Wahl, die Windows mitbringt: mehrere Kopierfaeden und ungepufferte
 Ein-/Ausgabe. Details stehen im DiskManager bei Get-RobocopyArgument.
=========================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')

#region ====================== Werkzeuge finden ========================

function Get-ArchiveToolInfo {
    <#
    .SYNOPSIS
        Welche Packer stehen auf diesem Rechner zur Verfuegung?
    #>
    [CmdletBinding()]
    param()

    # Join-Path wirft, wenn die Umgebungsvariable leer ist - auf
    # Nicht-Windows sind ProgramFiles schlicht nicht gesetzt. Deshalb
    # erst pruefen, dann zusammensetzen.
    function Join-WennVorhanden {
        param([string]$Basis, [string]$Rest)
        if ([string]::IsNullOrWhiteSpace($Basis)) { return $null }
        return (Join-Path $Basis $Rest)
    }

    $sieben = $null
    $siebenKandidaten = @(
        (Join-WennVorhanden $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-WennVorhanden ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )
    foreach ($kandidat in $siebenKandidaten) {
        if ($kandidat -and (Test-Path -LiteralPath $kandidat)) { $sieben = $kandidat; break }
    }
    if (-not $sieben) {
        $gefunden = Get-Command '7z' -ErrorAction SilentlyContinue
        if ($gefunden) { $sieben = $gefunden.Source }
    }

    $rar = $null
    foreach ($kandidat in @(
            (Join-WennVorhanden $env:ProgramFiles 'WinRAR\Rar.exe'),
            (Join-WennVorhanden ${env:ProgramFiles(x86)} 'WinRAR\Rar.exe'))) {
        if ($kandidat -and (Test-Path -LiteralPath $kandidat)) { $rar = $kandidat; break }
    }

    return [ordered]@{
        zip        = $true
        zipNote    = 'Immer verfuegbar - von Windows mitgebracht.'
        sevenZip   = [bool]$sieben
        sevenPath  = $sieben
        sevenNote  = $(if ($sieben) { ('7-Zip gefunden: ' + $sieben) } else { '7-Zip ist nicht installiert - dafuer waere 7-Zip noetig (kostenlos).' })
        rar        = [bool]$rar
        rarPath    = $rar
        rarNote    = $(if ($rar) { ('WinRAR gefunden: ' + $rar) } else { 'RAR braucht ein installiertes WinRAR - das Format ist proprietaer, es gibt keinen freien Packer dafuer.' })
    }
}

#endregion

#region ========================== Packen ==============================

function New-FolderArchive {
    <#
    .SYNOPSIS
        Packt einen Ordner in ein Archiv - mit laufender Fortschrittsmeldung.
    .PARAMETER Format
        Zip      - eingebaut, braucht nichts weiter
        SevenZip - benoetigt 7-Zip
        Rar      - benoetigt WinRAR
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [ValidateSet('Zip', 'SevenZip', 'Rar')][string]$Format = 'Zip',
        [ValidateSet('Fastest', 'Normal', 'Maximum')][string]$Level = 'Normal',
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    if ($Demo) { return Invoke-DemoArchive -Target $Target -Format $Format -OnProgress $OnProgress }

    if (-not (Test-Path -LiteralPath $Source)) {
        return @{ ok = $false; detail = ('Quelle nicht gefunden: {0}' -f $Source) }
    }
    $zielOrdner = Split-Path -Parent $Target
    if ($zielOrdner -and -not (Test-Path -LiteralPath $zielOrdner)) {
        New-Item -ItemType Directory -Path $zielOrdner -Force -WhatIf:$false | Out-Null
    }
    if (-not $PSCmdlet.ShouldProcess($Target, ('Archiv erstellen (' + $Format + ')'))) {
        return @{ ok = $false; detail = 'WhatIf - nichts veraendert' }
    }

    if ($Format -eq 'Zip') { return New-ZipArchiveWithProgress -Source $Source -Target $Target -Level $Level -OnProgress $OnProgress }

    $werkzeuge = Get-ArchiveToolInfo
    if ($Format -eq 'SevenZip') {
        if (-not $werkzeuge.sevenZip) { return @{ ok = $false; detail = $werkzeuge.sevenNote } }
        $stufe = @{ Fastest = '-mx=1'; Normal = '-mx=5'; Maximum = '-mx=9' }[$Level]
        return Invoke-PackerMitFortschritt -Exe $werkzeuge.sevenPath -Arguments @('a', '-tzip', $stufe, '-bsp1', '-y', $Target, (Join-Path $Source '*')) `
            -Muster '(\d{1,3})%' -Target $Target -OnProgress $OnProgress
    }
    if (-not $werkzeuge.rar) { return @{ ok = $false; detail = $werkzeuge.rarNote } }
    $stufe = @{ Fastest = '-m1'; Normal = '-m3'; Maximum = '-m5' }[$Level]
    return Invoke-PackerMitFortschritt -Exe $werkzeuge.rarPath -Arguments @('a', '-r', $stufe, '-ep1', $Target, (Join-Path $Source '*')) `
        -Muster '(\d{1,3})%' -Target $Target -OnProgress $OnProgress
}

function New-ZipArchiveWithProgress {
    <#  Datei fuer Datei packen: so gibt es einen echten Fortschritt, und
        eine gesperrte Datei kostet nicht den ganzen Vorgang. #>
    [CmdletBinding()]
    param([string]$Source, [string]$Target, [string]$Level = 'Normal', [scriptblock]$OnProgress)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $stufe = [System.IO.Compression.CompressionLevel]::Optimal
    if ($Level -eq 'Fastest') { $stufe = [System.IO.Compression.CompressionLevel]::Fastest }

    $dateien = @()
    try { $dateien = @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue) }
    catch { return @{ ok = $false; detail = ('Quelle nicht lesbar: ' + $_.Exception.Message) } }

    $gesamtBytes = 0
    foreach ($d in $dateien) { $gesamtBytes += $d.Length }
    $wurzel = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\', '/')

    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force -WhatIf:$false }
    $strom = $null; $archiv = $null
    $fertig = 0; $uebersprungen = 0; $bytesGepackt = 0
    $uhr = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $strom = [System.IO.File]::Open($Target, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        $archiv = New-Object System.IO.Compression.ZipArchive($strom, [System.IO.Compression.ZipArchiveMode]::Create)

        foreach ($datei in $dateien) {
            $relativ = $datei.FullName.Substring($wurzel.Length).TrimStart('\', '/')
            try {
                $eintrag = $archiv.CreateEntry($relativ.Replace('\', '/'), $stufe)
                $ziel = $eintrag.Open()
                $quelle = [System.IO.File]::Open($datei.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try { $quelle.CopyTo($ziel, 1048576) }
                finally { $quelle.Dispose(); $ziel.Dispose() }
                $bytesGepackt += $datei.Length
            }
            catch { $uebersprungen++ }

            $fertig++
            if ($OnProgress -and ($fertig % 20 -eq 0 -or $fertig -eq $dateien.Count)) {
                $mbs = 0
                if ($uhr.Elapsed.TotalSeconds -gt 0) { $mbs = [math]::Round(($bytesGepackt / 1MB) / $uhr.Elapsed.TotalSeconds, 0) }
                $rest = 0
                if ($mbs -gt 0 -and $gesamtBytes -gt $bytesGepackt) { $rest = [int]((($gesamtBytes - $bytesGepackt) / 1MB) / $mbs) }
                & $OnProgress @{
                    percent = $(if ($gesamtBytes -gt 0) { [math]::Round(($bytesGepackt / [double]$gesamtBytes) * 100, 1) } else { 100 })
                    bytesDone = $bytesGepackt; bytesTotal = $gesamtBytes
                    throughput = $mbs; secondsLeft = $rest
                    current = $datei.Name; stage = 'archive'
                }
            }
        }
    }
    catch { return @{ ok = $false; detail = ('Packen fehlgeschlagen: ' + $_.Exception.Message) } }
    finally {
        if ($archiv) { $archiv.Dispose() }
        if ($strom) { $strom.Dispose() }
        $uhr.Stop()
    }

    $groesse = 0
    try { $groesse = (Get-Item -LiteralPath $Target).Length } catch { $groesse = 0 }
    $verhaeltnis = 0
    if ($gesamtBytes -gt 0) { $verhaeltnis = [math]::Round(100 - (($groesse / [double]$gesamtBytes) * 100), 1) }

    return @{
        ok = $true; file = $Target; files = $dateien.Count; skipped = $uebersprungen
        bytesIn = $gesamtBytes; bytesOut = $groesse; ratioPercent = $verhaeltnis
        seconds = [int]$uhr.Elapsed.TotalSeconds
        detail = ('{0} Dateien gepackt ({1} -> {2}, {3} % gespart){4}' -f $dateien.Count,
            (Format-ByteSizeShort $gesamtBytes), (Format-ByteSizeShort $groesse), $verhaeltnis,
            $(if ($uebersprungen -gt 0) { (', {0} gesperrt und uebersprungen' -f $uebersprungen) } else { '' }))
    }
}

function Invoke-PackerMitFortschritt {
    <#  Ruft 7-Zip oder WinRAR auf und liest den Prozentwert aus der Ausgabe. #>
    [CmdletBinding()]
    param([string]$Exe, [string[]]$Arguments, [string]$Muster, [string]$Target, [scriptblock]$OnProgress)

    $uhr = [System.Diagnostics.Stopwatch]::StartNew()
    $letzte = -1
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $zeile = [string]$_
            if ($zeile -match $Muster) {
                $wert = [int]$Matches[1]
                if ($wert -ne $letzte -and $OnProgress) {
                    $letzte = $wert
                    & $OnProgress @{ percent = $wert; stage = 'archive'; current = '' }
                }
            }
        }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap; $uhr.Stop() }

    $groesse = 0
    try { $groesse = (Get-Item -LiteralPath $Target -ErrorAction Stop).Length } catch { $groesse = 0 }
    $ok = ($code -eq 0 -and $groesse -gt 0)
    return @{
        ok = $ok; file = $Target; bytesOut = $groesse; seconds = [int]$uhr.Elapsed.TotalSeconds
        detail = $(if ($ok) { ('Archiv erstellt: {0} ({1})' -f (Split-Path $Target -Leaf), (Format-ByteSizeShort $groesse)) }
            else { ('Packer meldete Fehlercode {0}' -f $code) })
    }
}

function Invoke-DemoArchive {
    param([string]$Target, [string]$Format, [scriptblock]$OnProgress)
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Milliseconds 250
        if ($OnProgress) {
            & $OnProgress @{ percent = $i * 10; bytesDone = [long](1.8GB * $i / 10); bytesTotal = 1.8GB
                throughput = 180; secondsLeft = (10 - $i); current = ('Datei_{0}.dat' -f ($i * 97)); stage = 'archive' }
        }
    }
    return @{
        ok = $true; file = $Target; files = 4820; skipped = 2; bytesIn = 1932735283; bytesOut = 912680550
        ratioPercent = 52.8; seconds = 3
        detail = ('Demo: 4820 Dateien in {0} gepackt (1,80 GB -> 870 MB, 52,8 % gespart)' -f $Format)
    }
}

#endregion

#region ======================= Uebertragen ============================

function Copy-FolderFast {
    <#
    .SYNOPSIS
        Kopiert oder verschiebt einen Ordner so schnell wie moeglich.
    .DESCRIPTION
        Nutzt robocopy mit mehreren Kopierfaeden und ungepufferter
        Ein-/Ausgabe. Der Fortschritt wird aus dem Schwund am Ziel
        berechnet - guenstiger als jede Datei einzeln zu zaehlen.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [ValidateSet('Copy', 'Move')][string]$Mode = 'Copy',
        [int]$Threads = 32,
        [switch]$Unbuffered,
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    if ($Demo) {
        for ($i = 1; $i -le 10; $i++) {
            Start-Sleep -Milliseconds 250
            if ($OnProgress) {
                & $OnProgress @{ percent = $i * 10; bytesDone = [long](12GB * $i / 10); bytesTotal = 12GB
                    throughput = 430; secondsLeft = (10 - $i) * 2; current = ''; stage = 'copy' }
            }
        }
        return @{ ok = $true; bytes = 12884901888; throughput = 430; seconds = 30
            detail = ('Demo: 12,0 GB {0} (430 MB/s)' -f $(if ($Mode -eq 'Move') { 'verschoben' } else { 'kopiert' })) }
    }

    if (-not (Test-Path -LiteralPath $Source)) { return @{ ok = $false; detail = ('Quelle nicht gefunden: ' + $Source) } }
    $quelleVoll = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
    $zielVoll = $Target.TrimEnd('\')
    if ($zielVoll -like ($quelleVoll + '*')) {
        return @{ ok = $false; detail = 'Das Ziel liegt innerhalb der Quelle - das gaebe eine Endlosschleife.' }
    }
    if (-not (Test-Path -LiteralPath $zielVoll)) { New-Item -ItemType Directory -Path $zielVoll -Force -WhatIf:$false | Out-Null }
    if (-not $PSCmdlet.ShouldProcess($zielVoll, ('Ordner ' + $Mode.ToLowerInvariant()))) {
        return @{ ok = $false; detail = 'WhatIf - nichts veraendert' }
    }

    $gesamt = 0
    try {
        $gesamt = (Get-ChildItem -LiteralPath $quelleVoll -File -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    }
    catch { $gesamt = 0 }
    if (-not $gesamt) { $gesamt = 0 }

    $zielLaufwerk = ''
    if ($zielVoll -match '^([A-Za-z]):') { $zielLaufwerk = $Matches[1] }
    $freiVorher = 0
    try { $freiVorher = [long](Get-Volume -DriveLetter $zielLaufwerk -ErrorAction Stop).SizeRemaining } catch { $freiVorher = 0 }

    $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $roboArgs = Get-RobocopyArgument -Source $quelleVoll -Destination $zielVoll -Mode $Mode -Threads $Threads -Unbuffered:$Unbuffered
    $uhr = [System.Diagnostics.Stopwatch]::StartNew()
    $prozess = Start-Process -FilePath $robo -ArgumentList $roboArgs -WindowStyle Hidden -PassThru

    while (-not $prozess.HasExited) {
        Start-Sleep -Milliseconds 700
        if ($OnProgress) {
            $freiJetzt = $freiVorher
            try { $freiJetzt = [long](Get-Volume -DriveLetter $zielLaufwerk -ErrorAction Stop).SizeRemaining } catch { Write-Verbose 'frei nicht lesbar' }
            $fertig = [math]::Max(0, $freiVorher - $freiJetzt)
            $mbs = 0
            if ($uhr.Elapsed.TotalSeconds -gt 0) { $mbs = [math]::Round(($fertig / 1MB) / $uhr.Elapsed.TotalSeconds, 0) }
            $rest = 0
            if ($mbs -gt 0 -and $gesamt -gt $fertig) { $rest = [int]((($gesamt - $fertig) / 1MB) / $mbs) }
            & $OnProgress @{
                percent = $(if ($gesamt -gt 0) { [math]::Round(($fertig / [double]$gesamt) * 100, 1) } else { 0 })
                bytesDone = $fertig; bytesTotal = $gesamt; throughput = $mbs; secondsLeft = $rest
                current = ''; stage = 'copy'
            }
        }
    }
    $uhr.Stop()

    $code = $prozess.ExitCode
    $ok = ($code -lt 8)
    $mbs = 0
    if ($uhr.Elapsed.TotalSeconds -gt 0 -and $gesamt -gt 0) { $mbs = [math]::Round(($gesamt / 1MB) / $uhr.Elapsed.TotalSeconds, 0) }
    return @{
        ok = $ok; exitCode = $code; bytes = $gesamt; throughput = $mbs; seconds = [int]$uhr.Elapsed.TotalSeconds
        detail = $(if ($ok) { ('{0} in {1} {2} ({3} MB/s)' -f (Format-ByteSizeShort $gesamt), (Format-Duration ([int]$uhr.Elapsed.TotalSeconds)),
                    $(if ($Mode -eq 'Move') { 'verschoben' } else { 'kopiert' }), $mbs) }
            else { ('robocopy meldete Fehlercode {0}' -f $code) })
    }
}

#endregion

Export-ModuleMember -Function Get-ArchiveToolInfo, New-FolderArchive, New-ZipArchiveWithProgress, `
    Invoke-PackerMitFortschritt, Invoke-DemoArchive, Copy-FolderFast
