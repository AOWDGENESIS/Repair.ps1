#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - DiskAnalysis
 Version: 1.5.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 Tiefenanalyse von Datentraegern: SMART-Werte, Zuverlaessigkeitszaehler,
 Ereignisprotokoll, Oberflaechenpruefung und eine klare Bewertung.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
 Warum es dieses Modul gibt:
 Windows meldet ueber "HealthStatus" fast immer "Healthy" - selbst bei
 einer Platte mit hunderten wartenden Sektoren. Der Wert kommt vom
 Treiber und bedeutet nur "antwortet noch". Wer wissen will, ob ein
 Laufwerk stirbt, muss die Rohwerte lesen:

   ID 5   Reallocated Sectors   bereits ersetzte Sektoren
   ID 197 Current Pending       Sektoren, die beim naechsten Schreiben
                                ersetzt werden muessen - der wichtigste
                                Fruehwarnwert ueberhaupt
   ID 198 Offline Uncorrectable endgueltig nicht lesbar
   ID 199 UDMA CRC Errors       Uebertragungsfehler, meist Kabel
   ID 9   Power On Hours        Betriebsstunden
   ID 194 Temperature           Temperatur

 Dazu das Ereignisprotokoll: Windows schreibt bei Lesefehlern seit Jahren
 dieselben Kennungen (disk 7/11/51/52, Ntfs 55/98/130, storahci 129).
 Die tauchen auf, lange bevor ein Werkzeug "defekt" meldet.
=========================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')

#region ========================== SMART ===============================

function Get-SmartAttribute {
    <#
    .SYNOPSIS
        Liest die wichtigen SMART-Rohwerte eines Datentraegers.
    .DESCRIPTION
        Erste Wahl ist Get-StorageReliabilityCounter (sauber, aber nicht
        bei jedem Treiber vorhanden). Faellt das aus, werden die rohen
        SMART-Daten ueber WMI gelesen und von Hand ausgewertet - die
        Rohwerte stehen dort als Bytefolge je Attribut.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$DiskNumber, [switch]$Demo)

    $ergebnis = [ordered]@{
        available            = $false
        source               = 'keine'
        reallocatedSectors   = $null
        pendingSectors       = $null
        uncorrectableSectors = $null
        crcErrors            = $null
        powerOnHours         = $null
        temperatureCelsius   = $null
        wearPercent          = $null
        readErrorsTotal      = $null
        writeErrorsTotal     = $null
    }

    if ($Demo -or -not $script:IsWindowsHost) {
        # Datentraeger 1 bekommt im Demobetrieb bewusst kranke Werte,
        # damit die Bewertung sichtbar wird.
        if ($DiskNumber -eq 1) {
            $ergebnis.available = $true; $ergebnis.source = 'Demo'
            $ergebnis.reallocatedSectors = 184
            $ergebnis.pendingSectors = 27
            $ergebnis.uncorrectableSectors = 6
            $ergebnis.crcErrors = 0
            $ergebnis.powerOnHours = 41280
            $ergebnis.temperatureCelsius = 46
            $ergebnis.readErrorsTotal = 912
            $ergebnis.writeErrorsTotal = 3
            return $ergebnis
        }
        if ($DiskNumber -eq 2) {
            $ergebnis.available = $true; $ergebnis.source = 'Demo'
            $ergebnis.reallocatedSectors = 0; $ergebnis.pendingSectors = 0
            $ergebnis.uncorrectableSectors = 0; $ergebnis.crcErrors = 14
            $ergebnis.powerOnHours = 2100; $ergebnis.temperatureCelsius = 38
            $ergebnis.readErrorsTotal = 0; $ergebnis.writeErrorsTotal = 0
            return $ergebnis
        }
        $ergebnis.available = $true; $ergebnis.source = 'Demo'
        $ergebnis.reallocatedSectors = 0; $ergebnis.pendingSectors = 0
        $ergebnis.uncorrectableSectors = 0; $ergebnis.crcErrors = 0
        $ergebnis.powerOnHours = 9400; $ergebnis.temperatureCelsius = 41
        $ergebnis.wearPercent = 3
        $ergebnis.readErrorsTotal = 0; $ergebnis.writeErrorsTotal = 0
        return $ergebnis
    }

    # --- Weg 1: Zuverlaessigkeitszaehler ---
    if (Get-Command -Name Get-StorageReliabilityCounter -ErrorAction SilentlyContinue) {
        try {
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$DiskNumber }
            if ($pd) {
                $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($rc) {
                    $ergebnis.available = $true
                    $ergebnis.source = 'StorageReliabilityCounter'
                    $ergebnis.powerOnHours = $rc.PowerOnHours
                    $ergebnis.temperatureCelsius = $rc.Temperature
                    $ergebnis.wearPercent = $rc.Wear
                    $ergebnis.readErrorsTotal = $rc.ReadErrorsTotal
                    $ergebnis.writeErrorsTotal = $rc.WriteErrorsTotal
                }
            }
        }
        catch { Write-Verbose 'Zuverlaessigkeitszaehler nicht lesbar.' }
    }

    # --- Weg 2: rohe SMART-Daten ueber WMI ---
    try {
        $pnp = $null
        $w32 = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
            Where-Object { $_.Index -eq $DiskNumber } | Select-Object -First 1
        if ($w32) { $pnp = $w32.PNPDeviceID }

        $daten = Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_ATAPISmartData -ErrorAction Stop |
            Where-Object { -not $pnp -or $_.InstanceName -like ($pnp.Replace('\', '\\') + '*') } | Select-Object -First 1
        if ($daten) {
            $roh = $daten.VendorSpecific
            # Aufbau: 2 Byte Kopf, dann je 12 Byte pro Attribut
            for ($i = 2; $i -lt $roh.Length - 11; $i += 12) {
                $id = [int]$roh[$i]
                if ($id -eq 0) { continue }
                $wert = [int]$roh[$i + 5] + ([int]$roh[$i + 6] -shl 8) + ([int]$roh[$i + 7] -shl 16) + ([int]$roh[$i + 8] -shl 24)
                switch ($id) {
                    5 { $ergebnis.reallocatedSectors = $wert }
                    9 { if ($null -eq $ergebnis.powerOnHours) { $ergebnis.powerOnHours = $wert } }
                    194 { if ($null -eq $ergebnis.temperatureCelsius) { $ergebnis.temperatureCelsius = ($wert -band 0xFF) } }
                    197 { $ergebnis.pendingSectors = $wert }
                    198 { $ergebnis.uncorrectableSectors = $wert }
                    199 { $ergebnis.crcErrors = $wert }
                    default { }
                }
            }
            $ergebnis.available = $true
            if ($ergebnis.source -eq 'keine') { $ergebnis.source = 'SMART (WMI)' }
            else { $ergebnis.source = 'StorageReliabilityCounter + SMART (WMI)' }
        }
    }
    catch { Write-Verbose 'Rohe SMART-Daten nicht lesbar (haeufig bei USB-Gehaeusen und RAID).' }

    return $ergebnis
}

function Get-FailurePrediction {
    <#  Die Vorhersage des Laufwerks selbst ("SMART Status: BAD"). #>
    param([Parameter(Mandatory)][int]$DiskNumber, [switch]$Demo)
    if ($Demo -or -not $script:IsWindowsHost) { return ($DiskNumber -eq 1) }
    try {
        $status = Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop |
            Select-Object -First 1
        if ($status) { return [bool]$status.PredictFailure }
    }
    catch { Write-Verbose 'Ausfallvorhersage nicht verfuegbar.' }
    return $false
}

#endregion

#region ===================== Ereignisprotokoll ========================

function Get-DiskEventSummary {
    <#
    .SYNOPSIS
        Zaehlt die typischen Datentraegerfehler im Systemprotokoll.
    .DESCRIPTION
        Diese Kennungen schreibt Windows bei echten Lese- und
        Schreibfehlern - oft monatelang, ohne dass es jemand bemerkt:
          disk 7   : Fehlerhafter Block
          disk 11  : Controllerfehler
          disk 51  : Fehler beim Auslagern
          disk 52  : Ausfall steht bevor
          Ntfs 55  : Dateisystem beschaedigt, chkdsk noetig
          Ntfs 98  : Beschaedigung in den Metadaten
          Ntfs 130 : Beschaedigung erkannt
          storahci 129 : Zuruecksetzen des Geraets (haengende Befehle)
          volmgr 162   : Absturzabbild nicht schreibbar
    #>
    [CmdletBinding()]
    param([int]$Days = 30, [int]$DiskNumber = -1, [switch]$Demo)

    $muster = @(
        @{ Provider = 'disk'; Id = 7; Text = 'Fehlerhafter Block auf dem Datentraeger' },
        @{ Provider = 'disk'; Id = 11; Text = 'Controllerfehler' },
        @{ Provider = 'disk'; Id = 51; Text = 'Fehler beim Auslagern auf den Datentraeger' },
        @{ Provider = 'disk'; Id = 52; Text = 'Ausfall des Datentraegers steht bevor' },
        @{ Provider = 'Ntfs'; Id = 55; Text = 'Dateisystem beschaedigt - chkdsk erforderlich' },
        @{ Provider = 'Ntfs'; Id = 98; Text = 'Beschaedigung in den NTFS-Metadaten' },
        @{ Provider = 'Ntfs'; Id = 130; Text = 'NTFS hat eine Beschaedigung erkannt' },
        @{ Provider = 'storahci'; Id = 129; Text = 'Geraet musste zurueckgesetzt werden' },
        @{ Provider = 'volmgr'; Id = 162; Text = 'Absturzabbild konnte nicht geschrieben werden' }
    )

    if ($Demo -or -not $script:IsWindowsHost) {
        # Im Demobetrieb gehoeren die Fehler zu Datentraeger 1 - sonst
        # saehe jede Platte krank aus, obwohl nur eine es ist.
        if ($DiskNumber -ne -1 -and $DiskNumber -ne 1) { return @() }
        return @(
            [ordered]@{ provider = 'disk'; id = 7; text = 'Fehlerhafter Block auf dem Datentraeger'; count = 23; lastTime = (Get-Date).AddHours(-6).ToString('o'); disk = 1 },
            [ordered]@{ provider = 'Ntfs'; id = 55; text = 'Dateisystem beschaedigt - chkdsk erforderlich'; count = 2; lastTime = (Get-Date).AddDays(-2).ToString('o'); disk = 1 },
            [ordered]@{ provider = 'storahci'; id = 129; text = 'Geraet musste zurueckgesetzt werden'; count = 9; lastTime = (Get-Date).AddDays(-1).ToString('o'); disk = 1 }
        )
    }

    $seit = (Get-Date).AddDays(-1 * $Days)
    $treffer = New-Object System.Collections.ArrayList
    foreach ($m in $muster) {
        try {
            $ereignisse = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = $m.Provider
                Id           = $m.Id
                StartTime    = $seit
            } -ErrorAction Stop
            if ($ereignisse) {
                # Windows nennt im Text das Geraet, etwa "\Device\Harddisk2\DR2".
                # Ohne diese Zuordnung wuerde ein kranker Datentraeger alle
                # anderen mit in Sippenhaft nehmen.
                if ($DiskNumber -ge 0) {
                    $ereignisse = @($ereignisse | Where-Object {
                            $nachricht = [string]$_.Message
                            if ([string]::IsNullOrEmpty($nachricht)) { return $false }
                            return ($nachricht -match ('Harddisk{0}\b' -f $DiskNumber)) -or
                                   ($nachricht -match ('\\Device\\Harddisk{0}\\' -f $DiskNumber))
                        })
                }
                if (@($ereignisse).Count -gt 0) {
                    $letzte = ($ereignisse | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                    [void]$treffer.Add([ordered]@{
                            provider = $m.Provider; id = $m.Id; text = $m.Text
                            count    = @($ereignisse).Count
                            lastTime = $letzte.ToString('o')
                            disk     = $DiskNumber
                        })
                }
            }
        }
        catch { Write-Verbose ('Keine Ereignisse fuer {0}/{1}.' -f $m.Provider, $m.Id) }
    }
    return @($treffer)
}

#endregion

#region ==================== Oberflaechenpruefung ======================

function Test-DiskSurface {
    <#
    .SYNOPSIS
        Liest stichprobenartig ueber den gesamten Datentraeger und zaehlt
        Lesefehler und auffaellig langsame Stellen.
    .DESCRIPTION
        Eine vollstaendige Oberflaechenpruefung einer 8-TB-Platte dauert
        Stunden. Diese Pruefung verteilt eine waehlbare Zahl von Proben
        gleichmaessig ueber den Datentraeger - damit sind defekte Bereiche
        in Minuten auffindbar. Jede Probe wird ungepuffert gelesen, damit
        kein Zwischenspeicher das Ergebnis schoent.

        Langsame Stellen sind das zweite Warnzeichen: wo die Elektronik
        einen Sektor mehrfach lesen muss, dauert es messbar laenger,
        bevor er endgueltig ausfaellt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [long]$SizeBytes = 0,
        [int]$Samples = 64,
        [int]$BlockKiB = 256,
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    if ($Samples -lt 4) { $Samples = 4 }
    if ($Samples -gt 4096) { $Samples = 4096 }

    $ergebnis = [ordered]@{
        samples = $Samples; ok = 0; errors = 0; slow = 0
        avgMsPerRead = 0.0; maxMsPerRead = 0.0; badOffsets = @(); durationSec = 0
    }

    if ($Demo -or -not $script:IsWindowsHost) {
        $schlecht = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $Samples; $i++) {
            Start-Sleep -Milliseconds 20
            if ($OnProgress -and ($i % 8) -eq 0) {
                & $OnProgress @{ percent = [math]::Round((($i + 1) / $Samples) * 100, 1); stage = 'surface' }
            }
            # Demo: Datentraeger 1 hat einen kaputten Bereich bei etwa 38 %
            if ($DiskNumber -eq 1 -and $i -ge [int]($Samples * 0.37) -and $i -le [int]($Samples * 0.40)) {
                $ergebnis.errors++
                [void]$schlecht.Add([long]($i * 1GB))
            }
            elseif ($DiskNumber -eq 1 -and ($i % 17) -eq 0) { $ergebnis.slow++; $ergebnis.ok++ }
            else { $ergebnis.ok++ }
        }
        $ergebnis.badOffsets = @($schlecht)
        $ergebnis.avgMsPerRead = 8.4
        $ergebnis.maxMsPerRead = $(if ($DiskNumber -eq 1) { 2840.0 } else { 19.0 })
        $ergebnis.durationSec = [int]($Samples * 0.02)
        return $ergebnis
    }

    Initialize-DiskNative
    $pfad = ('\\.\PhysicalDrive{0}' -f $DiskNumber)
    if ($SizeBytes -le 0) {
        try { $SizeBytes = [long](Get-Disk -Number $DiskNumber -ErrorAction Stop).Size } catch { $SizeBytes = 0 }
    }
    if ($SizeBytes -le 0) { return $ergebnis }

    $block = $BlockKiB * 1024
    $schritt = [long]([math]::Floor(($SizeBytes - $block) / $Samples))
    $puffer = New-Object byte[] $block
    $zeiten = New-Object System.Collections.ArrayList
    $schlecht = New-Object System.Collections.ArrayList
    $uhr = [System.Diagnostics.Stopwatch]::StartNew()
    $strom = $null

    try {
        $strom = [RepairCenter.Storage.RawDevice]::Open($pfad, $true, $false)
        for ($i = 0; $i -lt $Samples; $i++) {
            $position = [long]($i * $schritt)
            $position = $position - ($position % 4096)
            $einzel = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $strom.Seek($position, [System.IO.SeekOrigin]::Begin) | Out-Null
                $gelesen = $strom.Read($puffer, 0, $block)
                $einzel.Stop()
                if ($gelesen -le 0) { throw 'Nichts gelesen' }
                $ergebnis.ok++
                [void]$zeiten.Add($einzel.Elapsed.TotalMilliseconds)
                # Deutlich langsamer als ueblich = Sektor musste mehrfach gelesen werden
                if ($einzel.Elapsed.TotalMilliseconds -gt 500) { $ergebnis.slow++ }
            }
            catch {
                $einzel.Stop()
                $ergebnis.errors++
                [void]$schlecht.Add($position)
            }
            if ($OnProgress -and ($i % 4) -eq 0) {
                & $OnProgress @{ percent = [math]::Round((($i + 1) / $Samples) * 100, 1); stage = 'surface' }
            }
        }
    }
    catch { Write-Verbose ('Oberflaechenpruefung abgebrochen: {0}' -f $_.Exception.Message) }
    finally {
        if ($strom) { $strom.Dispose() }
        $uhr.Stop()
    }

    if ($zeiten.Count -gt 0) {
        $ergebnis.avgMsPerRead = [math]::Round((($zeiten | Measure-Object -Average).Average), 2)
        $ergebnis.maxMsPerRead = [math]::Round((($zeiten | Measure-Object -Maximum).Maximum), 2)
    }
    $ergebnis.badOffsets = @($schlecht)
    $ergebnis.durationSec = [int]$uhr.Elapsed.TotalSeconds
    return $ergebnis
}

#endregion

#region ========================= Bewertung ============================

function Get-DiskVerdict {
    <#
    .SYNOPSIS
        Fasst alle Messwerte zu einer verstaendlichen Bewertung zusammen.
    .DESCRIPTION
        Die Schwellen folgen der gaengigen Praxis:
          - wartende Sektoren (197) > 0      -> beobachten, > 10 -> ersetzen
          - nicht korrigierbare (198) > 0    -> ersetzen
          - ersetzte Sektoren (5) > 0        -> beobachten, > 50 -> ersetzen
          - CRC-Fehler (199) > 0             -> Kabel pruefen
          - Lesefehler in der Oberflaechenpruefung -> akut
          - Ausfallvorhersage des Laufwerks   -> akut
        Jede Bewertung nennt ihre Gruende, damit nachvollziehbar bleibt,
        warum ein Laufwerk auffaellt.
    #>
    [CmdletBinding()]
    param($Smart, $Events, $Surface, [bool]$FailurePredicted = $false, [string]$HealthStatus = 'Healthy')

    $gruende = New-Object System.Collections.ArrayList
    $stufe = 0   # 0 gesund, 1 beobachten, 2 ersetzen, 3 akut

    function Add-Grund {
        param([int]$Wert, [string]$Text)
        if ($Wert -gt $script:_stufe) { $script:_stufe = $Wert }
        [void]$script:_gruende.Add([ordered]@{ level = $Wert; text = $Text })
    }
    $script:_gruende = $gruende
    $script:_stufe = $stufe

    if ($FailurePredicted) { Add-Grund 3 'Das Laufwerk sagt den eigenen Ausfall voraus (SMART-Status BAD).' }

    if ($Smart -and $Smart.available) {
        if ($Smart.pendingSectors -gt 10) { Add-Grund 2 ('{0} wartende Sektoren - Austausch empfohlen.' -f $Smart.pendingSectors) }
        elseif ($Smart.pendingSectors -gt 0) { Add-Grund 1 ('{0} wartende Sektoren - beobachten.' -f $Smart.pendingSectors) }

        if ($Smart.uncorrectableSectors -gt 0) { Add-Grund 2 ('{0} endgueltig nicht lesbare Sektoren.' -f $Smart.uncorrectableSectors) }

        if ($Smart.reallocatedSectors -gt 50) { Add-Grund 2 ('{0} bereits ersetzte Sektoren - die Reserve geht zur Neige.' -f $Smart.reallocatedSectors) }
        elseif ($Smart.reallocatedSectors -gt 0) { Add-Grund 1 ('{0} bereits ersetzte Sektoren.' -f $Smart.reallocatedSectors) }

        if ($Smart.crcErrors -gt 0) { Add-Grund 1 ('{0} Uebertragungsfehler (CRC) - meist Kabel oder Gehaeuse, nicht die Platte.' -f $Smart.crcErrors) }

        if ($Smart.temperatureCelsius -gt 55) { Add-Grund 1 ('Temperatur {0} Grad - zu warm.' -f $Smart.temperatureCelsius) }
        if ($null -ne $Smart.wearPercent -and $Smart.wearPercent -gt 80) { Add-Grund 2 ('Abnutzung {0} Prozent - die Lebensdauer ist weitgehend aufgebraucht.' -f $Smart.wearPercent) }
        if ($Smart.readErrorsTotal -gt 0) { Add-Grund 1 ('{0} Lesefehler laut Zuverlaessigkeitszaehler.' -f $Smart.readErrorsTotal) }
    }
    else {
        Add-Grund 1 'SMART-Werte sind nicht lesbar (haeufig bei USB-Gehaeusen, Kartenlesern und RAID-Controllern).'
    }

    foreach ($e in @($Events)) {
        if ($e.id -eq 7 -or $e.id -eq 52) { Add-Grund 2 ('{0}x "{1}" im Systemprotokoll.' -f $e.count, $e.text) }
        elseif ($e.id -eq 55 -or $e.id -eq 98 -or $e.id -eq 130) { Add-Grund 2 ('{0}x "{1}" - Dateisystempruefung noetig.' -f $e.count, $e.text) }
        else { Add-Grund 1 ('{0}x "{1}".' -f $e.count, $e.text) }
    }

    if ($Surface) {
        if ($Surface.errors -gt 0) { Add-Grund 3 ('{0} von {1} Proben waren nicht lesbar - es gibt defekte Bereiche.' -f $Surface.errors, $Surface.samples) }
        if ($Surface.slow -gt 0) { Add-Grund 1 ('{0} Proben waren auffaellig langsam (bis {1} ms) - typisch fuer Sektoren kurz vor dem Ausfall.' -f $Surface.slow, $Surface.maxMsPerRead) }
    }

    if ($HealthStatus -and $HealthStatus -ne 'Healthy') { Add-Grund 2 ('Windows meldet den Zustand "{0}".' -f $HealthStatus) }

    $stufe = $script:_stufe
    $namen = @{ 0 = 'Gesund'; 1 = 'Beobachten'; 2 = 'Austausch empfohlen'; 3 = 'Akut - Daten sofort sichern' }
    $empfehlung = @{
        0 = 'Keine Auffaelligkeiten. Trotzdem gilt: Sicherungen ersetzt keine Diagnose.'
        1 = 'Werte im Auge behalten und in einigen Wochen erneut pruefen.'
        2 = 'Daten sichern und das Laufwerk ersetzen. Es arbeitet noch, aber die Reserve schwindet.'
        3 = 'Sofort sichern - am besten mit der Datenrettung in diesem Programm - und das Laufwerk austauschen. Jeder weitere Betrieb kann Daten kosten.'
    }

    return [ordered]@{
        level          = $stufe
        verdict        = $namen[$stufe]
        recommendation = $empfehlung[$stufe]
        reasons        = @($gruende)
    }
}

function Invoke-DiskAnalysis {
    <#
    .SYNOPSIS
        Fuehrt die komplette Analyse eines Datentraegers aus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [int]$Samples = 64,
        [switch]$SkipSurface,
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    $disks = @(Get-DiskInventory -Demo:$Demo)
    $disk = $disks | Where-Object { $_.number -eq $DiskNumber } | Select-Object -First 1
    if (-not $disk) { return @{ ok = $false; detail = ('Datentraeger {0} nicht gefunden.' -f $DiskNumber) } }

    if ($OnProgress) { & $OnProgress @{ percent = 5; stage = 'smart' } }
    $smart = Get-SmartAttribute -DiskNumber $DiskNumber -Demo:$Demo
    $vorhersage = Get-FailurePrediction -DiskNumber $DiskNumber -Demo:$Demo

    if ($OnProgress) { & $OnProgress @{ percent = 20; stage = 'events' } }
    $ereignisse = @(Get-DiskEventSummary -DiskNumber $DiskNumber -Demo:$Demo)

    $oberflaeche = $null
    if (-not $SkipSurface) {
        if ($OnProgress) { & $OnProgress @{ percent = 30; stage = 'surface' } }
        $oberflaeche = Test-DiskSurface -DiskNumber $DiskNumber -SizeBytes ([long]$disk.sizeBytes) `
            -Samples $Samples -OnProgress $OnProgress -Demo:$Demo
    }

    if ($OnProgress) { & $OnProgress @{ percent = 95; stage = 'verdict' } }
    $bewertung = Get-DiskVerdict -Smart $smart -Events $ereignisse -Surface $oberflaeche `
        -FailurePredicted $vorhersage -HealthStatus ([string]$disk.healthStatus)

    return [ordered]@{
        ok               = $true
        diskNumber       = $DiskNumber
        friendlyName     = $disk.friendlyName
        deviceKindLabel  = $disk.deviceKindLabel
        sizeBytes        = $disk.sizeBytes
        smart            = $smart
        failurePredicted = $vorhersage
        events           = $ereignisse
        surface          = $oberflaeche
        verdict          = $bewertung
        detail           = ('{0}: {1}' -f $disk.friendlyName, $bewertung.verdict)
    }
}

#endregion

Export-ModuleMember -Function `
    Get-SmartAttribute, Get-FailurePrediction, Get-DiskEventSummary, `
    Test-DiskSurface, Get-DiskVerdict, Invoke-DiskAnalysis
