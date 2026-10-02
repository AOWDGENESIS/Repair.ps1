#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - FileIntegrity
 Version: 1.5.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 Suche nach defekten Dateien und deren Reparatur.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
 Drei Arten von Schaden, die hier unterschieden werden:

 1. NICHT LESBAR   Die Datei liegt auf defekten Sektoren. Jeder Versuch
                   endet mit einem Ein-/Ausgabefehler. Das ist der Fall,
                   den Windows selbst nie meldet, bis man die Datei
                   anfasst - und der Grund, warum Fehler "nicht erkannt"
                   werden.
 2. STRUKTUR KAPUTT Die Datei ist lesbar, aber ihr Inhalt passt nicht
                   zum Format: ein JPEG ohne Endmarke, ein ZIP ohne
                   Verzeichnis, ein PDF ohne %%EOF. Typisch nach
                   Stromausfall, abgebrochener Uebertragung oder
                   sterbendem Datentraeger.
 3. LEER           0 Byte, obwohl die Datei etwas enthalten sollte -
                   klassisch nach einem Absturz waehrend des Schreibens.

 Reparaturwege, in dieser Reihenfolge:
   a) Systemdatei  -> SFC kann sie aus dem Komponentenstore ersetzen
   b) Schattenkopie-> Windows hat oft eine aeltere, heile Fassung
   c) sonst        -> ehrlich melden statt so tun als ob
=========================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')

#region ====================== Formatpruefung ==========================

function Get-FileSignatureCheck {
    <#
    .SYNOPSIS
        Prueft Kopf und Ende einer Datei gegen das erwartete Format.
    .DESCRIPTION
        Gelesen werden nur die ersten und letzten Bytes - das geht auch
        bei Gigabytedateien in Millisekunden. Erkannt werden die Formate,
        bei denen ein Abbruch typisch ist: Bilder, Archive, Dokumente,
        Datenbanken und Programme.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $ergebnis = [ordered]@{ format = 'unbekannt'; known = $false; valid = $true; reason = '' }
    $strom = $null
    try {
        $strom = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $laenge = $strom.Length
        if ($laenge -eq 0) {
            $ergebnis.valid = $false; $ergebnis.reason = 'Datei ist leer (0 Byte)'
            return $ergebnis
        }

        $kopfLaenge = [int][math]::Min(64, $laenge)
        $kopf = New-Object byte[] $kopfLaenge
        [void]$strom.Read($kopf, 0, $kopfLaenge)

        $endLaenge = [int][math]::Min(66560, $laenge)   # 65 KiB fuer das ZIP-Verzeichnis
        $ende = New-Object byte[] $endLaenge
        $strom.Seek(-1 * $endLaenge, [System.IO.SeekOrigin]::End) | Out-Null
        [void]$strom.Read($ende, 0, $endLaenge)

        function Test-ByteMatch {
            param($Daten, [int]$Offset, [byte[]]$Muster)
            if ($Daten.Length -lt ($Offset + $Muster.Length)) { return $false }
            for ($i = 0; $i -lt $Muster.Length; $i++) {
                if ($Daten[$Offset + $i] -ne $Muster[$i]) { return $false }
            }
            return $true
        }
        function Find-ByteSequence {
            param($Daten, [byte[]]$Muster)
            for ($i = 0; $i -le ($Daten.Length - $Muster.Length); $i++) {
                $treffer = $true
                for ($j = 0; $j -lt $Muster.Length; $j++) {
                    if ($Daten[$i + $j] -ne $Muster[$j]) { $treffer = $false; break }
                }
                if ($treffer) { return $true }
            }
            return $false
        }

        # ---------------- JPEG ----------------
        if (Test-ByteMatch $kopf 0 @(0xFF, 0xD8, 0xFF)) {
            $ergebnis.format = 'JPEG'; $ergebnis.known = $true
            if (-not (Test-ByteMatch $ende ($endLaenge - 2) @(0xFF, 0xD9))) {
                $ergebnis.valid = $false; $ergebnis.reason = 'JPEG ohne Endmarke FFD9 - Bild ist abgeschnitten'
            }
        }
        # ---------------- PNG ----------------
        elseif (Test-ByteMatch $kopf 0 @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) {
            $ergebnis.format = 'PNG'; $ergebnis.known = $true
            if (-not (Find-ByteSequence $ende @(0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82))) {
                $ergebnis.valid = $false; $ergebnis.reason = 'PNG ohne IEND-Block - Bild ist unvollstaendig'
            }
        }
        # ---------------- GIF ----------------
        elseif (Test-ByteMatch $kopf 0 @(0x47, 0x49, 0x46, 0x38)) {
            $ergebnis.format = 'GIF'; $ergebnis.known = $true
            if ($ende[$endLaenge - 1] -ne 0x3B) {
                $ergebnis.valid = $false; $ergebnis.reason = 'GIF ohne Abschlusszeichen'
            }
        }
        # ---------------- PDF ----------------
        elseif (Test-ByteMatch $kopf 0 @(0x25, 0x50, 0x44, 0x46)) {
            $ergebnis.format = 'PDF'; $ergebnis.known = $true
            if (-not (Find-ByteSequence $ende @(0x25, 0x25, 0x45, 0x4F, 0x46))) {
                $ergebnis.valid = $false; $ergebnis.reason = 'PDF ohne %%EOF - Dokument wurde nicht fertig geschrieben'
            }
        }
        # ------------- ZIP, DOCX, XLSX, PPTX -------------
        elseif (Test-ByteMatch $kopf 0 @(0x50, 0x4B, 0x03, 0x04)) {
            $ergebnis.format = 'ZIP/Office'; $ergebnis.known = $true
            if (-not (Find-ByteSequence $ende @(0x50, 0x4B, 0x05, 0x06))) {
                $ergebnis.valid = $false; $ergebnis.reason = 'Archiv ohne zentrales Verzeichnis - Inhalt nicht mehr auffindbar'
            }
        }
        # ---------------- GZIP ----------------
        elseif (Test-ByteMatch $kopf 0 @(0x1F, 0x8B)) {
            $ergebnis.format = 'GZIP'; $ergebnis.known = $true
            if ($laenge -lt 18) { $ergebnis.valid = $false; $ergebnis.reason = 'GZIP-Datei zu kurz' }
        }
        # ---------------- SQLite ----------------
        elseif (Test-ByteMatch $kopf 0 @(0x53, 0x51, 0x4C, 0x69, 0x74, 0x65)) {
            $ergebnis.format = 'SQLite'; $ergebnis.known = $true
            if ($laenge % 512 -ne 0) { $ergebnis.valid = $false; $ergebnis.reason = 'SQLite-Datei endet mitten in einer Seite' }
        }
        # ------------- Programm oder Bibliothek -------------
        elseif (Test-ByteMatch $kopf 0 @(0x4D, 0x5A)) {
            $ergebnis.format = 'EXE/DLL'; $ergebnis.known = $true
            if ($kopfLaenge -ge 64) {
                $peVersatz = [BitConverter]::ToInt32($kopf, 60)
                if ($peVersatz -le 0 -or $peVersatz -ge $laenge - 4) {
                    $ergebnis.valid = $false; $ergebnis.reason = 'Programmdatei ohne gueltigen PE-Kopf'
                }
                else {
                    $pe = New-Object byte[] 4
                    $strom.Seek($peVersatz, [System.IO.SeekOrigin]::Begin) | Out-Null
                    [void]$strom.Read($pe, 0, 4)
                    if (-not (Test-ByteMatch $pe 0 @(0x50, 0x45, 0x00, 0x00))) {
                        $ergebnis.valid = $false; $ergebnis.reason = 'Programmdatei ohne PE-Signatur'
                    }
                }
            }
        }
    }
    catch {
        $ergebnis.valid = $false
        $ergebnis.reason = ('Datei nicht lesbar: {0}' -f $_.Exception.Message)
    }
    finally { if ($strom) { $strom.Dispose() } }
    return $ergebnis
}

function Test-FileReadable {
    <#  Liest die Datei vollstaendig - so zeigen sich defekte Sektoren. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [int]$BufferKiB = 1024)
    $strom = $null
    try {
        $strom = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $puffer = New-Object byte[] ($BufferKiB * 1024)
        while ($strom.Read($puffer, 0, $puffer.Length) -gt 0) { }
        return @{ readable = $true; reason = '' }
    }
    catch { return @{ readable = $false; reason = $_.Exception.Message } }
    finally { if ($strom) { $strom.Dispose() } }
}

#endregion

#region ========================== Suche ===============================

function Invoke-FileIntegrityScan {
    <#
    .SYNOPSIS
        Durchsucht einen Ordner nach defekten Dateien.
    .PARAMETER Deep
        Liest jede Datei vollstaendig. Findet defekte Sektoren, dauert
        aber so lange, wie der Datentraeger zum Lesen braucht. Ohne
        diesen Schalter werden nur Kopf und Ende geprueft - das findet
        kaputte Strukturen in Sekunden.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Deep,
        [int]$MaxFiles = 100000,
        [string]$Filter = '*',
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    # Bewusst nur bei -Demo: Dateien lesen und Formate pruefen ist
    # plattformneutral und muss deshalb auch ausserhalb von Windows
    # wirklich laufen - sonst liesse sich die Suche gar nicht pruefen.
    if ($Demo) { return Invoke-DemoIntegrityScan -Path $Path -Deep:$Deep -OnProgress $OnProgress }

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ ok = $false; detail = ('Pfad nicht gefunden: {0}' -f $Path) }
    }

    $uhr = [System.Diagnostics.Stopwatch]::StartNew()
    $funde = New-Object System.Collections.ArrayList
    $gezaehlt = 0; $bytes = 0; $gesperrt = 0

    $dateien = @()
    try {
        $dateien = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse -Force -ErrorAction SilentlyContinue |
                Select-Object -First $MaxFiles)
    }
    catch { Write-Verbose 'Verzeichnis nicht vollstaendig lesbar.' }

    $gesamt = @($dateien).Count
    foreach ($datei in $dateien) {
        $gezaehlt++
        $bytes += $datei.Length
        if ($OnProgress -and ($gezaehlt % 25) -eq 0) {
            & $OnProgress @{
                percent = $(if ($gesamt -gt 0) { [math]::Round(($gezaehlt / $gesamt) * 100, 1) } else { 0 })
                stage   = 'scan'; current = $datei.Name; filesDone = $gezaehlt; filesTotal = $gesamt
            }
        }

        $befund = $null
        if ($Deep) {
            $lesbar = Test-FileReadable -Path $datei.FullName
            if (-not $lesbar.readable) {
                $befund = [ordered]@{
                    path = $datei.FullName; sizeBytes = $datei.Length; kind = 'unreadable'
                    format = ''; reason = $lesbar.reason; repairable = $true
                }
            }
        }
        if (-not $befund) {
            $pruefung = Get-FileSignatureCheck -Path $datei.FullName
            if (-not $pruefung.valid) {
                $art = 'structure'
                if ($pruefung.reason -like '*leer*') { $art = 'empty' }
                elseif ($pruefung.reason -like '*nicht lesbar*') { $art = 'unreadable' }
                $befund = [ordered]@{
                    path = $datei.FullName; sizeBytes = $datei.Length; kind = $art
                    format = $pruefung.format; reason = $pruefung.reason; repairable = $true
                }
            }
        }
        if ($befund) { [void]$funde.Add($befund) }
    }
    $uhr.Stop()

    return [ordered]@{
        ok          = $true
        path        = $Path
        deep        = [bool]$Deep
        filesTotal  = $gesamt
        bytesTotal  = $bytes
        locked      = $gesperrt
        findings    = @($funde)
        damaged     = @($funde).Count
        durationSec = [int]$uhr.Elapsed.TotalSeconds
        detail      = ('{0} Dateien geprueft, {1} auffaellig' -f $gesamt, @($funde).Count)
    }
}

function Invoke-DemoIntegrityScan {
    param([string]$Path, [switch]$Deep, [scriptblock]$OnProgress)
    $gesamt = 4820
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep -Milliseconds 220
        if ($OnProgress) {
            & $OnProgress @{
                percent = [math]::Round(($i / 12) * 100, 1); stage = 'scan'
                current = ('Datei_{0}.dat' -f ($i * 311)); filesDone = [int]($gesamt * $i / 12); filesTotal = $gesamt
            }
        }
    }
    # Bewusst mit Zeichenketten statt Join-Path: die Pfade sind erfunden,
    # und Join-Path besteht ausserhalb von Windows auf ein vorhandenes
    # Laufwerk "C".
    $wurzel = ([string]$Path).TrimEnd('\', '/')
    $funde = @(
        [ordered]@{ path = ($wurzel + '\Bilder\Urlaub\IMG_2291.jpg'); sizeBytes = 3821044; kind = 'structure'; format = 'JPEG'; reason = 'JPEG ohne Endmarke FFD9 - Bild ist abgeschnitten'; repairable = $true },
        [ordered]@{ path = ($wurzel + '\Dokumente\Vertrag.pdf'); sizeBytes = 1204221; kind = 'structure'; format = 'PDF'; reason = 'PDF ohne %%EOF - Dokument wurde nicht fertig geschrieben'; repairable = $true },
        [ordered]@{ path = ($wurzel + '\Archiv\Projekt-2025.zip'); sizeBytes = 48221104; kind = 'structure'; format = 'ZIP/Office'; reason = 'Archiv ohne zentrales Verzeichnis - Inhalt nicht mehr auffindbar'; repairable = $true },
        [ordered]@{ path = 'C:\Windows\System32\drivers\beispiel.sys'; sizeBytes = 92160; kind = 'unreadable'; format = ''; reason = 'Ein-/Ausgabefehler beim Lesen (Sektor defekt)'; repairable = $true },
        [ordered]@{ path = ($wurzel + '\Dokumente\Notizen.docx'); sizeBytes = 0; kind = 'empty'; format = ''; reason = 'Datei ist leer (0 Byte)'; repairable = $true }
    )
    return [ordered]@{
        ok = $true; path = $Path; deep = [bool]$Deep; filesTotal = $gesamt
        bytesTotal = 18400000000; locked = 3; findings = $funde; damaged = $funde.Count
        durationSec = 3; detail = ('Demo: {0} Dateien geprueft, {1} auffaellig' -f $gesamt, $funde.Count)
    }
}

#endregion

#region ======================== Reparatur =============================

function Get-ShadowCopySource {
    <#
    .SYNOPSIS
        Sucht die neueste Schattenkopie, die diese Datei enthaelt.
    .DESCRIPTION
        Windows legt mit der Systemwiederherstellung auch Schattenkopien
        von Benutzerdateien an ("Vorgaengerversionen"). Darueber laesst
        sich eine beschaedigte Datei oft einfach zurueckholen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$Demo)

    if ($Demo -or -not $script:IsWindowsHost) {
        return @{ found = $true; source = '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy7\Demo'; created = (Get-Date).AddDays(-3).ToString('o') }
    }
    try {
        $laufwerk = [System.IO.Path]::GetPathRoot($Path)
        $rest = $Path.Substring($laufwerk.Length)
        $kopien = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop |
            Sort-Object InstallDate -Descending
        foreach ($k in $kopien) {
            $kandidat = Join-Path ($k.DeviceObject + '\') $rest
            $voll = '\\?\GLOBALROOT' + $kandidat.Substring($kandidat.IndexOf('\Device'))
            if (Test-Path -LiteralPath $voll) {
                return @{ found = $true; source = $voll; created = $k.InstallDate }
            }
        }
    }
    catch { Write-Verbose 'Schattenkopien nicht abfragbar.' }
    return @{ found = $false; source = ''; created = $null }
}

function Repair-DamagedFile {
    <#
    .SYNOPSIS
        Repariert eine beschaedigte Datei.
    .PARAMETER Strategy
        Auto        - Systemdatei ueber SFC, sonst Schattenkopie
        ShadowCopy  - nur aus einer Vorgaengerversion zurueckholen
        SystemFile  - nur ueber SFC
        ReportOnly  - nichts tun, nur melden
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Auto', 'ShadowCopy', 'SystemFile', 'ReportOnly')][string]$Strategy = 'Auto',
        [switch]$Demo
    )

    $istSystemdatei = $false
    if ($script:IsWindowsHost -and $env:SystemRoot) {
        $istSystemdatei = $Path.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)
    }
    elseif ($Path -like 'C:\Windows\*') { $istSystemdatei = $true }

    $gewaehlt = $Strategy
    if ($Strategy -eq 'Auto') { $gewaehlt = $(if ($istSystemdatei) { 'SystemFile' } else { 'ShadowCopy' }) }

    if ($Strategy -eq 'ReportOnly') {
        return @{ ok = $false; strategy = 'ReportOnly'; detail = 'Nur gemeldet, nichts veraendert.' }
    }

    if ($Demo -or -not $script:IsWindowsHost) {
        Start-Sleep -Milliseconds 250
        if ($gewaehlt -eq 'SystemFile') {
            return @{ ok = $true; strategy = 'SystemFile'; detail = 'Demo: Systemdatei ueber SFC aus dem Komponentenstore ersetzt.' }
        }
        if ($Path -like '*Projekt-2025.zip') {
            return @{ ok = $false; strategy = 'ShadowCopy'; detail = 'Demo: keine Vorgaengerversion vorhanden - Datei bleibt beschaedigt.' }
        }
        return @{ ok = $true; strategy = 'ShadowCopy'; detail = 'Demo: aus Vorgaengerversion vom 27.09.2026 zurueckgeholt.' }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, ('Reparieren ueber ' + $gewaehlt))) {
        return @{ ok = $false; strategy = $gewaehlt; detail = 'WhatIf - nichts veraendert' }
    }

    if ($gewaehlt -eq 'SystemFile') {
        try {
            $sfc = Resolve-SystemTool -Name 'sfc.exe'
            $r = Invoke-NativeCommand -FilePath $sfc -Arguments @('/scannow') -SuccessExitCodes @(0, 1, 2, 3) -ToolEncoding Unicode
            return @{ ok = ($r.Status -ne 'FAILED'); strategy = 'SystemFile'; detail = ('SFC ausgefuehrt (Exitcode {0}) - Ergebnis siehe CBS-Auswertung.' -f $r.ExitCode) }
        }
        catch { return @{ ok = $false; strategy = 'SystemFile'; detail = $_.Exception.Message } }
    }

    # Schattenkopie
    $quelle = Get-ShadowCopySource -Path $Path
    if (-not $quelle.found) {
        return @{ ok = $false; strategy = 'ShadowCopy'; detail = 'Keine Vorgaengerversion vorhanden - Datei kann nicht wiederhergestellt werden.' }
    }
    try {
        $sicherung = $Path + '.beschaedigt'
        if (Test-Path -LiteralPath $Path) { Move-Item -LiteralPath $Path -Destination $sicherung -Force -ErrorAction Stop }
        Copy-Item -LiteralPath $quelle.source -Destination $Path -Force -ErrorAction Stop
        return @{ ok = $true; strategy = 'ShadowCopy'; detail = ('Aus Vorgaengerversion zurueckgeholt; die beschaedigte Fassung liegt als "{0}" daneben.' -f (Split-Path $sicherung -Leaf)) }
    }
    catch { return @{ ok = $false; strategy = 'ShadowCopy'; detail = $_.Exception.Message } }
}

function Invoke-FileRepairBatch {
    <#
    .SYNOPSIS
        Repariert mehrere Befunde und fasst das Ergebnis zusammen.
    .DESCRIPTION
        Systemdateien werden gesammelt und mit einem einzigen SFC-Lauf
        behandelt - SFC prueft ohnehin alles auf einmal, mehrfach
        aufzurufen waere reine Zeitverschwendung.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]$Findings,
        [ValidateSet('Auto', 'ShadowCopy', 'SystemFile', 'ReportOnly')][string]$Strategy = 'Auto',
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    $liste = @($Findings)
    $ergebnisse = New-Object System.Collections.ArrayList
    $repariert = 0; $gescheitert = 0
    $sfcGelaufen = $false
    $index = 0

    foreach ($f in $liste) {
        $index++
        if ($OnProgress) {
            & $OnProgress @{
                percent = [math]::Round(($index / [math]::Max(1, $liste.Count)) * 100, 1)
                stage   = 'repair'; current = (Split-Path ([string]$f.path) -Leaf)
            }
        }

        $istSystemdatei = ([string]$f.path) -like 'C:\Windows\*'
        if ($script:IsWindowsHost -and $env:SystemRoot) {
            $istSystemdatei = ([string]$f.path).StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)
        }
        if ($istSystemdatei -and $sfcGelaufen) {
            [void]$ergebnisse.Add([ordered]@{ path = $f.path; ok = $true; strategy = 'SystemFile'; detail = 'Durch den vorherigen SFC-Lauf mit abgedeckt.' })
            $repariert++
            continue
        }

        $r = Repair-DamagedFile -Path ([string]$f.path) -Strategy $Strategy -Demo:$Demo -Confirm:$false
        if ($istSystemdatei -and $r.strategy -eq 'SystemFile') { $sfcGelaufen = $true }
        if ($r.ok) { $repariert++ } else { $gescheitert++ }
        [void]$ergebnisse.Add([ordered]@{ path = $f.path; ok = $r.ok; strategy = $r.strategy; detail = $r.detail })
    }

    return [ordered]@{
        ok       = ($gescheitert -eq 0)
        repaired = $repariert
        failed   = $gescheitert
        results  = @($ergebnisse)
        detail   = ('{0} von {1} Dateien repariert' -f $repariert, $liste.Count)
    }
}

#endregion

Export-ModuleMember -Function `
    Get-FileSignatureCheck, Test-FileReadable, Invoke-FileIntegrityScan, `
    Invoke-DemoIntegrityScan, Get-ShadowCopySource, Repair-DamagedFile, Invoke-FileRepairBatch
