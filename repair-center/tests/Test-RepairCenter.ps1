#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Selbsttest
 Prueft Engine, API und Oberflaeche ohne Fremdmodule und ohne echte
 Eingriffe ins System (Demomodus). Lauffaehig unter Windows PowerShell
 5.1 und PowerShell 7 (auch unter Linux fuer CI).
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
#>
[CmdletBinding()]
param([int]$Port = 8731)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $TestDir
$SrcDir = Join-Path $Root 'src'
$Module = Join-Path (Join-Path $SrcDir 'modules') 'RepairEngine.psm1'
$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('rc-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

# Pfad zur PowerShell einmal ganz oben bestimmen - weiter unten brauchen
# ihn mehrere Tests, und wer ihn erst spaeter setzt, laesst die frueheren
# ins Leere laufen.
$psExe = $null
try { $psExe = (Get-Process -Id $PID).Path } catch { $psExe = $null }
if ([string]::IsNullOrWhiteSpace($psExe)) {
    $name = 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') { $name = 'pwsh' }
    $psExe = Join-Path $PSHOME $name
}

$script:Pass = 0
$script:Fail = 0
$script:Failed = New-Object System.Collections.ArrayList

# Die Oberflaeche sendet diesen Kopf bei jeder Anfrage; der Dienst weist
# schreibende Anfragen ohne ihn ab (Schutz vor fremden Webseiten).
$script:ApiHeaders = @{ 'X-RepairCenter' = '1' }

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host ('  [ok]   ' + $Name) -ForegroundColor Green
    }
    catch {
        $script:Fail++
        [void]$script:Failed.Add([pscustomobject]@{ Name = $Name; Message = $_.Exception.Message })
        Write-Host ('  [FEHL] ' + $Name) -ForegroundColor Red
        Write-Host ('         ' + $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

<#  Wartet, bis kein Datentraegervorgang mehr laeuft. Seit der Sperre
    (nur ein Vorgang gleichzeitig) muessen Tests das abwarten, sonst
    scheitern sie sporadisch am 409 des Vorgaengers. #>
function Wait-DiskJobFree {
    param([string]$BaseUrl, [int]$TimeoutSeconds = 60)
    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        try {
            $a = Invoke-RestMethod -Uri ($BaseUrl + '/api/disk/active') -TimeoutSec 10
            if (-not $a.busy) { return $true }
        }
        catch { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw ('{0} (erwartet "{1}", erhalten "{2}")' -f $Message, $Expected, $Actual)
    }
}

Write-Host ''
Write-Host '  ===================================================='
Write-Host '   RepairCenter - Selbsttest'
Write-Host '  ===================================================='
Write-Host ''
Write-Host '  Engine' -ForegroundColor Cyan

Import-Module $Module -Force -DisableNameChecking

Test-Case 'Modul exportiert die erwarteten Funktionen' {
    foreach ($fn in @('Invoke-RepairRun', 'Get-SystemSnapshot', 'Get-CbsSfcSummary', 'Format-ByteSize')) {
        Assert-True ([bool](Get-Command -Name $fn -ErrorAction SilentlyContinue)) ("Funktion fehlt: " + $fn)
    }
}

Test-Case 'Format-ByteSize rechnet korrekt' {
    Assert-Equal '5.0 MB' (Format-ByteSize 5242880) 'MB-Formatierung'
    Assert-Equal '3.00 GB' (Format-ByteSize 3221225472) 'GB-Formatierung'
}

Test-Case 'Systemuebersicht liefert Pflichtfelder' {
    $snap = Get-SystemSnapshot
    foreach ($k in @('computer', 'os', 'psVersion', 'isAdmin', 'componentStore')) {
        Assert-True ($snap.Contains($k)) ("Feld fehlt: " + $k)
    }
}

Test-Case 'CBS-Parser ignoriert Eintraege vor Laufbeginn und liest gesperrte Datei' {
    $logDir = Join-Path $WorkDir 'Logs\CBS'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $oldEnv = $env:SystemRoot
    $env:SystemRoot = $WorkDir
    try {
        $since = (Get-Date).AddMinutes(-5)
        $old = (Get-Date).AddDays(-3).ToString('yyyy-MM-dd HH:mm:ss')
        $new = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss')
        $cbs = Join-Path $logDir 'CBS.log'
        @(
            ($old + ', Info CSI 0001 [SR] Repaired file alt.dll'),
            ($new + ', Info CSI 0002 [SR] Repaired file neu.dll'),
            ($new + ', Info CSI 0003 [SR] Repairing corrupted file zwei.dll'),
            ($new + ', Info CSI 0004 [SR] Cannot repair member file kaputt.sys'),
            ($new + ', Info CSI 0005 [SR] Hashes for file member x.dll do not match')
        ) | Set-Content -LiteralPath $cbs -Encoding UTF8

        # Datei absichtlich offen halten - so verhaelt sich Windows im Betrieb
        $locked = [System.IO.File]::Open($cbs, 'Open', 'Read', 'ReadWrite')
        try { $sum = Get-CbsSfcSummary -Since $since }
        finally { $locked.Dispose() }

        Assert-True $sum.Available 'CBS.log wurde nicht gelesen'
        Assert-Equal 4 $sum.TotalSrLines 'Anzahl [SR]-Zeilen des Laufs'
        Assert-Equal 2 $sum.Repaired 'reparierte Dateien'
        Assert-Equal 1 $sum.CannotRepair 'nicht reparierbare Dateien'
        Assert-Equal 1 $sum.Corrupt 'beschaedigte Dateien'
    }
    finally { $env:SystemRoot = $oldEnv }
}

Test-Case 'Vollstaendiger Demolauf erzeugt Bericht und Zustand' {
    $result = Invoke-RepairRun -Mode Quick -Optimize Safe -LogRoot $WorkDir -RunId 'testrun' -Demo
    Assert-True ($result.status -eq 'done') 'Lauf nicht abgeschlossen'
    Assert-True (@($result.steps).Count -ge 4) 'zu wenige Schritte'
    Assert-True ($null -ne $result.exitCode) 'kein Exitcode'
    $runDir = Join-Path (Join-Path $WorkDir 'runs') 'testrun'
    Assert-True (Test-Path (Join-Path $runDir 'state.json')) 'state.json fehlt'
    Assert-True (Test-Path (Join-Path $runDir 'report.txt')) 'report.txt fehlt'
    $json = Get-Content -LiteralPath (Join-Path $runDir 'state.json') -Raw | ConvertFrom-Json
    Assert-Equal 'testrun' $json.runId 'Lauf-ID im Zustand'
}

Test-Case 'Diagnosemodus erzwingt Wartungsstufe None (strikt lesend)' {
    $result = Invoke-RepairRun -Mode Diagnose -Optimize Aggressive -LogRoot $WorkDir -RunId 'diagrun' -Demo
    Assert-Equal 'None' $result.optimize 'Wartungsstufe im Diagnosemodus'
    $wartung = @($result.steps) | Where-Object { $_.name -eq 'Wartung' }
    Assert-True ($null -ne $wartung -and $wartung.status -eq 'SKIPPED') 'Wartung wurde nicht uebersprungen'
}

Write-Host ''
Write-Host '  Testumgebung: Demo-Szenarien' -ForegroundColor Cyan

$scenarioExpectations = @(
    @{ Scenario = 'Healthy';    Overall = 'HEALTHY';  Restart = $false },
    @{ Scenario = 'Repaired';   Overall = 'REPAIRED'; Restart = $true },
    @{ Scenario = 'Escalation'; Overall = 'REPAIRED'; Restart = $true },
    @{ Scenario = 'Failed';     Overall = 'FAILED';   Restart = $false }
)
foreach ($exp in $scenarioExpectations) {
    $sc = $exp.Scenario
    Test-Case ('Szenario "{0}" ergibt Gesamtstatus {1}' -f $sc, $exp.Overall) {
        $r = Invoke-RepairRun -Mode Repair -Optimize None -LogRoot $WorkDir -RunId ('sc-' + $sc) -Demo -DemoScenario $sc
        Assert-Equal $exp.Overall $r.overall ('Gesamtstatus fuer Szenario ' + $sc)
        if ($exp.Restart) { Assert-True $r.restartRequired 'Neustart haette verlangt werden muessen' }
    }
}

Test-Case 'Szenario "Escalation" fuehrt den zweiten Anlauf aus und stuft den Erstbefund herab' {
    $r = Invoke-RepairRun -Mode Repair -Optimize None -LogRoot $WorkDir -RunId 'sc-esc-detail' -Demo -DemoScenario Escalation
    $names = @($r.steps | ForEach-Object { $_.name })
    Assert-True ($names -contains 'DISM_RestoreHealth_2') 'DISM-Zweitlauf fehlt'
    Assert-True ($names -contains 'SFC_2') 'SFC-Zweitlauf fehlt'
    $first = @($r.steps) | Where-Object { $_.name -eq 'CBS_Analyse' } | Select-Object -First 1
    Assert-Equal 'WARNING' $first.status 'Erstbefund wurde nicht herabgestuft'
    Assert-True ($first.detail -like '*2. Durchlauf*') 'Hinweis auf den zweiten Durchlauf fehlt'
    Assert-Equal 'REPAIRED' $r.overall 'Gesamtstatus nach erfolgreicher Eskalation'
}

Test-Case 'Szenario "Failed" bricht die Eskalation mit Quellenhinweis ab' {
    $r = Invoke-RepairRun -Mode Repair -Optimize None -LogRoot $WorkDir -RunId 'sc-failed-detail' -Demo -DemoScenario Failed
    $names = @($r.steps | ForEach-Object { $_.name })
    Assert-True ($names -contains 'DISM_RestoreHealth_2') 'DISM-Zweitlauf fehlt'
    Assert-True ($names -notcontains 'SFC_2') 'Nach gescheitertem DISM darf kein zweiter SFC folgen'
    Assert-True (@($r.findings | Where-Object { $_.text -like '*Quelle*' }).Count -ge 1) 'Quellenhinweis fehlt'
}

Test-Case 'Szenario "Preflight" blockiert den Lauf ohne Eingriffe' {
    $r = Invoke-RepairRun -Mode Repair -Optimize Standard -LogRoot $WorkDir -RunId 'sc-pre' -Demo -DemoScenario Preflight
    Assert-Equal 'FAILED' $r.overall 'Gesamtstatus bei blockiertem Preflight'
    Assert-Equal 1 @($r.steps).Count 'Es haette nur der Preflight-Schritt laufen duerfen'
    Assert-Equal 'Preflight' $r.steps[0].name 'falscher Schritt'
}

Test-Case 'Wiederherstellungspunkt: bei Stufe Standard angelegt, mit Schalter uebersprungen' {
    $a = Invoke-RepairRun -Mode Quick -Optimize Standard -LogRoot $WorkDir -RunId 'rp-an' -Demo -DemoScenario Healthy
    $stepA = @($a.steps) | Where-Object { $_.name -eq 'Wiederherstellungspunkt' } | Select-Object -First 1
    Assert-True ($null -ne $stepA) 'Schritt fehlt'
    Assert-Equal 'PASS' $stepA.status 'Wiederherstellungspunkt wurde nicht angelegt'

    $b = Invoke-RepairRun -Mode Quick -Optimize Standard -LogRoot $WorkDir -RunId 'rp-aus' -Demo -DemoScenario Healthy -NoRestorePoint
    $stepB = @($b.steps) | Where-Object { $_.name -eq 'Wiederherstellungspunkt' } | Select-Object -First 1
    Assert-Equal 'SKIPPED' $stepB.status 'Schalter -NoRestorePoint wirkt nicht'

    $c = Invoke-RepairRun -Mode Quick -Optimize Safe -LogRoot $WorkDir -RunId 'rp-safe' -Demo -DemoScenario Healthy
    $stepC = @($c.steps) | Where-Object { $_.name -eq 'Wiederherstellungspunkt' }
    Assert-Equal 0 @($stepC).Count 'Stufe Safe braucht keinen Wiederherstellungspunkt'
}

Write-Host ''
Write-Host '  Datentraegerverwaltung' -ForegroundColor Cyan

Import-Module (Join-Path (Join-Path $SrcDir 'modules') 'DiskManager.psm1') -Force -DisableNameChecking

Test-Case 'Bestandsaufnahme liefert Datentraeger mit Schutzkennzeichnung' {
    $d = @(Get-DiskInventory -Demo)
    Assert-True ($d.Count -ge 3) 'zu wenige Datentraeger'
    $sys = $d | Where-Object { $_.number -eq 0 } | Select-Object -First 1
    Assert-True $sys.isSystem 'Datentraeger 0 muesste der Systemdatentraeger sein'
    Assert-True $sys.protected 'Systemdatentraeger muss geschuetzt sein'
    Assert-True (@($d[1].volumes).Count -ge 1) 'Volumes fehlen'
}

Test-Case 'Systemdatentraeger wird immer verweigert' {
    $disks = @(Get-DiskInventory -Demo)
    $sys = $disks | Where-Object { $_.number -eq 0 } | Select-Object -First 1
    $r = Test-DiskOperationAllowed -Disk $sys -Confirmation 'DISK0'
    Assert-True (-not $r.allowed) 'Systemdatentraeger wurde freigegeben'
    Assert-True ($r.reason -like '*Systemdatentraeger*') 'falsche Begruendung'
}

Test-Case 'Ohne korrekte Bestaetigung passiert nichts' {
    $disks = @(Get-DiskInventory -Demo)
    $hdd = $disks | Where-Object { $_.number -eq 1 } | Select-Object -First 1
    Assert-True (-not (Test-DiskOperationAllowed -Disk $hdd -Confirmation '').allowed) 'leere Bestaetigung akzeptiert'
    Assert-True (-not (Test-DiskOperationAllowed -Disk $hdd -Confirmation 'DISK2').allowed) 'falsche Bestaetigung akzeptiert'
    Assert-True (Test-DiskOperationAllowed -Disk $hdd -Confirmation 'DISK1').allowed 'richtige Bestaetigung abgelehnt'
}

Test-Case 'Kennungen sind auch im selben Sekundentakt eindeutig (Auftraege und Laeufe)' {
    # 2000 Ziehungen: mit den urspruenglichen vier Zeichen aus 36 waere hier
    # eine Kollision praktisch sicher gewesen - der Fehler ist im Lasttest
    # auch tatsaechlich aufgetreten.
    $jobIds = 1..2000 | ForEach-Object { New-DiskJobId -Action 'Wipe' }
    Assert-Equal 2000 (@($jobIds | Sort-Object -Unique)).Count 'Auftrags-IDs nicht eindeutig'
    Assert-True ($jobIds[0] -match '^wipe-\d{8}-\d{6}-[0-9a-f]{8}$') ('unerwartete Form: ' + $jobIds[0])

    $runIds = 1..2000 | ForEach-Object { New-RunIdentifier }
    Assert-Equal 2000 (@($runIds | Sort-Object -Unique)).Count 'Lauf-Kennungen nicht eindeutig'
    Assert-True ($runIds[0] -match '^\d{8}-\d{6}-[0-9a-f]{8}$') ('unerwartete Form: ' + $runIds[0])

    # Wirklich im selben Sekundentakt gezogen?
    $stamps = @($jobIds | ForEach-Object { $_.Substring(0, $_.LastIndexOf('-')) } | Sort-Object -Unique)
    Assert-True ($stamps.Count -lt 2000) 'Test untauglich - die Kennungen lagen nicht im selben Sekundentakt'
}

Test-Case 'Verfahrenswahl: BitLocker -> CryptoErase, SSD -> Trim, HDD -> Zero' {
    $disks = @(Get-DiskInventory -Demo)
    Assert-Equal 'CryptoErase' (Get-WipeStrategy -Disk $disks[0] -Requested 'Auto') 'BitLocker-Datentraeger'
    Assert-Equal 'Zero' (Get-WipeStrategy -Disk $disks[1] -Requested 'Auto') 'Festplatte'
    Assert-Equal 'Zero' (Get-WipeStrategy -Disk $disks[0] -Requested 'Zero') 'ausdrueckliche Wahl muss gewinnen'
    $ssd = @{ bitlocker = 'Off'; mediaType = 'SSD'; busType = 'SATA' }
    Assert-Equal 'Trim' (Get-WipeStrategy -Disk $ssd -Requested 'Auto') 'SSD'
}

Test-Case 'Dauerschaetzung ist plausibel' {
    $crypto = Get-WipeEstimate -SizeBytes 8TB -Strategy 'CryptoErase'
    Assert-True ($crypto.seconds -le 10) 'CryptoErase muesste Sekunden dauern'
    $trim = Get-WipeEstimate -SizeBytes 8TB -Strategy 'Trim'
    Assert-True ($trim.seconds -le 60) 'TRIM muesste Sekunden dauern'
    $zero = Get-WipeEstimate -SizeBytes 8TB -Strategy 'Zero' -BusType 'SATA' -MediaType 'HDD'
    Assert-True ($zero.seconds -gt 3600) '8 TB mit Nullen dauern laenger als eine Stunde'
    $verify = Get-WipeEstimate -SizeBytes 8TB -Strategy 'ZeroVerify' -BusType 'SATA' -MediaType 'HDD'
    Assert-Equal ($zero.seconds * 2) $verify.seconds 'Pruefdurchlauf verdoppelt die Dauer'
    Assert-True ((Format-Duration 3725) -like '1 h*') 'Dauerformatierung'
}

Test-Case 'FAT32-Formatierer erzeugt einen gueltigen Bootsektor (64 GB)' {
    Initialize-DiskNative
    $img = Join-Path $WorkDir 'fat64.img'
    $fs = [System.IO.File]::Create($img); $fs.SetLength(64GB); $fs.Dispose()
    $stream = [RepairCenter.Storage.RawDevice]::Open($img, $false, $false)
    try { $info = [RepairCenter.Storage.Fat32Formatter]::Format($stream, 64GB, 512, 0, 'PRUEFUNG') }
    finally { $stream.Dispose() }
    Assert-True ($info -like 'FAT32*') 'keine FAT32-Rueckmeldung'

    $bytes = New-Object byte[] 1024
    $fr = [System.IO.File]::OpenRead($img)
    try { $fr.Read($bytes, 0, 1024) | Out-Null } finally { $fr.Dispose() }

    Assert-Equal ([int]0xEB) ([int]$bytes[0]) 'Sprungbefehl fehlt'
    Assert-Equal ([int]0x55) ([int]$bytes[510]) 'Bootsignatur 0x55 fehlt'
    Assert-Equal ([int]0xAA) ([int]$bytes[511]) 'Bootsignatur 0xAA fehlt'
    $bps = [BitConverter]::ToUInt16($bytes, 11)
    Assert-Equal 512 $bps 'Sektorgroesse im BPB'
    $fsType = [System.Text.Encoding]::ASCII.GetString($bytes, 82, 8)
    Assert-Equal 'FAT32   ' $fsType 'Dateisystemkennung'
    $rootClus = [BitConverter]::ToUInt32($bytes, 44)
    Assert-Equal 2 $rootClus 'Wurzelverzeichnis muss in Cluster 2 liegen'
    $totSec32 = [BitConverter]::ToUInt32($bytes, 32)
    Assert-Equal 134217728 $totSec32 'Sektoranzahl'
    # FSInfo-Sektor
    Assert-Equal ([uint32]0x41615252) ([BitConverter]::ToUInt32($bytes, 512)) 'FSInfo-Signatur'
    Remove-Item $img -Force
}

Test-Case 'FAT32 jenseits der Windows-Grenze: 2 TB moeglich, 4 TB sauber abgelehnt' {
    Initialize-DiskNative
    $img = Join-Path $WorkDir 'fatbig.img'
    $fs = [System.IO.File]::Create($img); $fs.SetLength(2TB); $fs.Dispose()
    $stream = [RepairCenter.Storage.RawDevice]::Open($img, $false, $false)
    try { $info = [RepairCenter.Storage.Fat32Formatter]::Format($stream, 2TB, 4096, 0, 'GROSS', $false) }
    finally { $stream.Dispose() }
    Assert-True ($info -like '*FAT nicht genullt*') 'Schnellweg wurde nicht genutzt'
    Remove-Item $img -Force

    $img2 = Join-Path $WorkDir 'fat4t.img'
    $fs2 = [System.IO.File]::Create($img2); $fs2.SetLength(1GB); $fs2.Dispose()
    $stream2 = [RepairCenter.Storage.RawDevice]::Open($img2, $false, $false)
    $rejected = $false
    try { [RepairCenter.Storage.Fat32Formatter]::Format($stream2, 4TB, 512, 0, 'ZUGROSS', $false) | Out-Null }
    catch { $rejected = ($_.Exception.InnerException.Message -like '*2.0 TiB*') }
    finally { $stream2.Dispose(); Remove-Item $img2 -Force }
    Assert-True $rejected '4 TB mit 512-Byte-Sektoren haette abgelehnt werden muessen'
}

Test-Case 'Nullschreiber ueberschreibt tatsaechlich alles mit Nullen' {
    Initialize-DiskNative
    $img = Join-Path $WorkDir 'wipe.img'
    $size = 16MB
    $filler = New-Object byte[] $size
    for ($i = 0; $i -lt $size; $i += 997) { $filler[$i] = 0xFF }
    [System.IO.File]::WriteAllBytes($img, $filler)

    $wiper = New-Object RepairCenter.Storage.ZeroWiper($img, 0, [long]$size, 4, 2)
    $wiper.Start()
    $guard = 0
    while (-not $wiper.IsCompleted -and $guard -lt 200) { Start-Sleep -Milliseconds 50; $guard++ }
    Assert-True $wiper.IsCompleted 'Nullschreiber wurde nicht fertig'
    Assert-True ([string]::IsNullOrEmpty($wiper.Error)) ('Fehler: ' + $wiper.Error)
    Assert-Equal $size $wiper.BytesWritten 'geschriebene Menge'

    $check = [System.IO.File]::ReadAllBytes($img)
    $nonZero = 0
    foreach ($b in $check) { if ($b -ne 0) { $nonZero++ } }
    Assert-Equal 0 $nonZero 'es sind Daten uebrig geblieben'
    Remove-Item $img -Force
}

Test-Case 'Loeschen im Demomodus meldet Fortschritt und Verfahren' {
    $updates = New-Object System.Collections.ArrayList
    $cb = { param($p) [void]$updates.Add($p) }
    $r = Clear-DiskContent -DiskNumber 1 -Strategy 'Zero' -Confirmation 'DISK1' -OnProgress $cb -Demo -Confirm:$false
    Assert-True $r.ok 'Loeschvorgang fehlgeschlagen'
    Assert-Equal 'Zero' $r.strategy 'falsches Verfahren'
    Assert-True ($updates.Count -ge 5) 'zu wenige Fortschrittsmeldungen'
    Assert-Equal 100 $updates[$updates.Count - 1].percent 'Fortschritt endet nicht bei 100 %'
}

Test-Case 'Loeschen des Systemdatentraegers wird auch ueber die Engine verweigert' {
    $r = Clear-DiskContent -DiskNumber 0 -Strategy 'Zero' -Confirmation 'DISK0' -Demo -Confirm:$false
    Assert-True (-not $r.ok) 'Systemdatentraeger wurde geloescht'
    Assert-True ($r.detail -like '*Systemdatentraeger*') 'falsche Begruendung'
}

Test-Case 'Dateisystemwechsel: FAT32 -> NTFS verlustfrei, NTFS -> FAT32 nur mit Zustimmung' {
    $ok = Convert-VolumeFileSystem -DriveLetter 'E' -TargetFileSystem 'NTFS' -Demo -Confirm:$false
    Assert-True $ok.ok 'verlustfreier Wechsel fehlgeschlagen'
    Assert-True $ok.lossless 'haette verlustfrei sein muessen'

    $bad = Convert-VolumeFileSystem -DriveLetter 'E' -TargetFileSystem 'exFAT' -Demo -Confirm:$false
    Assert-True (-not $bad.ok) 'verlustbehafteter Wechsel lief ohne Zustimmung'
    Assert-True ($bad.needsAck -eq $true) 'Rueckfrage fehlt'

    $forced = Convert-VolumeFileSystem -DriveLetter 'E' -TargetFileSystem 'exFAT' -AllowDataLoss -Demo -Confirm:$false
    Assert-True $forced.ok 'Wechsel mit Zustimmung fehlgeschlagen'
}

Test-Case 'USB-Sticks und Speicherkarten werden als solche erkannt' {
    Assert-Equal 'MemoryCard' (Get-DeviceKind -BusType 'SD' -MediaType 'Unspecified' -SizeBytes 64GB -IsRemovable $true) 'SD-Karte'
    Assert-Equal 'MemoryCard' (Get-DeviceKind -BusType 'MMC' -MediaType 'Unspecified' -SizeBytes 32GB -IsRemovable $true) 'MMC-Karte'
    Assert-Equal 'UsbStick' (Get-DeviceKind -BusType 'USB' -MediaType 'Unspecified' -SizeBytes 64GB -IsRemovable $true) 'USB-Stick'
    Assert-Equal 'UsbDisk' (Get-DeviceKind -BusType 'USB' -MediaType 'HDD' -SizeBytes 4TB -IsRemovable $true) 'USB-Festplatte'
    Assert-Equal 'UsbSsd' (Get-DeviceKind -BusType 'USB' -MediaType 'SSD' -SizeBytes 1TB -IsRemovable $true) 'USB-SSD'
    Assert-Equal 'Nvme' (Get-DeviceKind -BusType 'NVMe' -MediaType 'SSD' -SizeBytes 1TB -IsRemovable $false) 'NVMe'
    Assert-Equal 'Hdd' (Get-DeviceKind -BusType 'SATA' -MediaType 'HDD' -SizeBytes 8TB -IsRemovable $false) 'Festplatte'
    Assert-Equal 'Speicherkarte' (Get-DeviceKindLabel 'MemoryCard') 'deutsche Bezeichnung'
}

Test-Case 'Bestandsaufnahme fuehrt Wechselmedien mit Art und Kennzeichnung' {
    $d = @(Get-DiskInventory -Demo)
    $stick = $d | Where-Object { $_.deviceKind -eq 'UsbStick' } | Select-Object -First 1
    $card = $d | Where-Object { $_.deviceKind -eq 'MemoryCard' } | Select-Object -First 1
    Assert-True ($null -ne $stick) 'kein USB-Stick im Bestand'
    Assert-True ($null -ne $card) 'keine Speicherkarte im Bestand'
    Assert-True $stick.isRemovable 'Stick nicht als Wechselmedium gekennzeichnet'
    Assert-Equal 'Speicherkarte' $card.deviceKindLabel 'Bezeichnung der Karte'
}

Test-Case 'Sicherungsziele schliessen den Quelldatentraeger aus' {
    $targets = @(Get-BackupTarget -ExcludeDiskNumber 1 -Demo)
    Assert-True ($targets.Count -ge 2) 'zu wenige Ziele'
    Assert-Equal 0 (@($targets | Where-Object { $_.diskNumber -eq 1 }).Count) 'Quelldatentraeger ist als Ziel aufgefuehrt'
    Assert-True (@($targets | Where-Object { $_.driveLetter -eq 'E' }).Count -eq 1) 'USB-Stick fehlt als moegliches Ziel'
}

Test-Case 'Robocopy-Argumente setzen auf Tempo - und meiden die Bremse /Z' {
    $copy = Get-RobocopyArgument -Source 'E:\' -Destination 'D:\Rettung' -Mode Copy -Unbuffered
    Assert-True ($copy -contains '/MT:32') 'Mehrfaedigkeit fehlt'
    Assert-True ($copy -contains '/J') 'ungepufferte Ein-/Ausgabe fehlt'
    Assert-True ($copy -contains '/R:1') 'Wiederholungsgrenze fehlt'
    Assert-True ($copy -contains '/XJ') 'Verzeichnisverknuepfungen nicht ausgeschlossen'
    Assert-True ($copy -notcontains '/Z') 'der langsame Wiederaufnahmemodus /Z darf nicht gesetzt sein'
    Assert-True ($copy -notcontains '/MOVE') 'Kopieren darf nicht verschieben'

    $move = Get-RobocopyArgument -Source 'E:\' -Destination 'D:\Rettung' -Mode Move -Threads 64
    Assert-True ($move -contains '/MOVE') 'Verschieben fehlt'
    Assert-True ($move -contains '/MT:64') 'Fadenzahl nicht uebernommen'
    Assert-True ($move -notcontains '/J') 'ungepuffert war nicht angefordert'
}

Test-Case 'Datenrettung im Demobetrieb meldet Fortschritt mit Abschnitt' {
    $updates = New-Object System.Collections.ArrayList
    $cb = { param($p) [void]$updates.Add($p) }
    $r = Invoke-DataRescue -DiskNumber 2 -TargetPath 'D:\Rettung' -Mode Copy -OnProgress $cb -Demo -Confirm:$false
    Assert-True $r.ok ('Rettung fehlgeschlagen: ' + $r.detail)
    Assert-True ($updates.Count -ge 5) 'zu wenige Fortschrittsmeldungen'
    Assert-Equal 'rescue' $updates[0].stage 'Abschnitt nicht gekennzeichnet'
    Assert-True ($r.bytes -gt 0) 'keine Datenmenge ermittelt'
}

Test-Case 'Ziel auf dem zu loeschenden Datentraeger wird abgelehnt' {
    $r = Invoke-DataRescue -DiskNumber 2 -TargetPath 'E:\Rettung' -Demo -Confirm:$false
    Assert-True (-not $r.ok) 'Ziel auf der Quelle wurde akzeptiert'
    Assert-True ($r.detail -like '*geloescht werden soll*') 'falsche Begruendung'
}

Test-Case 'Zu wenig Platz am Ziel stoppt die Rettung vorher' {
    # Datentraeger 1 hat rund 49 GB Daten, die Speicherkarte F: nur 28,9 GB frei
    $r = Invoke-DataRescue -DiskNumber 1 -TargetPath 'F:\Rettung' -Demo -Confirm:$false
    Assert-True (-not $r.ok) 'Rettung lief trotz Platzmangel an'
    Assert-True ($r.detail -like '*Zu wenig Platz*') 'falsche Begruendung'
    Assert-True ($r.neededBytes -gt $r.freeBytes) 'Platzangaben unstimmig'
}

Write-Host ''
Write-Host '  Datentraegeranalyse' -ForegroundColor Cyan

Import-Module (Join-Path (Join-Path $SrcDir 'modules') 'DiskAnalysis.psm1') -Force -DisableNameChecking
Import-Module (Join-Path (Join-Path $SrcDir 'modules') 'FileIntegrity.psm1') -Force -DisableNameChecking

Test-Case 'Bewertung: saubere Werte ergeben "Gesund"' {
    $smart = @{ available = $true; pendingSectors = 0; uncorrectableSectors = 0; reallocatedSectors = 0
        crcErrors = 0; temperatureCelsius = 38; wearPercent = 2; readErrorsTotal = 0
    }
    $b = Get-DiskVerdict -Smart $smart -Events @() -Surface $null -FailurePredicted $false -HealthStatus 'Healthy'
    Assert-Equal 0 $b.level 'saubere Werte duerfen nicht auffallen'
    Assert-Equal 'Gesund' $b.verdict 'Bezeichnung'
}

Test-Case 'Bewertung: wartende Sektoren und Ausfallvorhersage ergeben die hoechste Stufe' {
    $smart = @{ available = $true; pendingSectors = 27; uncorrectableSectors = 6; reallocatedSectors = 184
        crcErrors = 0; temperatureCelsius = 46; readErrorsTotal = 912
    }
    $b = Get-DiskVerdict -Smart $smart -Events @() -Surface $null -FailurePredicted $true -HealthStatus 'Healthy'
    Assert-Equal 3 $b.level 'muesste akut sein'
    Assert-True (@($b.reasons | Where-Object { $_.text -like '*wartende Sektoren*' }).Count -eq 1) 'wartende Sektoren fehlen in der Begruendung'
    Assert-True ($b.recommendation -like '*sichern*') 'Empfehlung nennt die Sicherung nicht'
}

Test-Case 'Bewertung: Windows meldet "Healthy", die Rohwerte sagen etwas anderes' {
    # Genau der Fall, der bisher nicht erkannt wurde
    $smart = @{ available = $true; pendingSectors = 12; uncorrectableSectors = 0; reallocatedSectors = 0
        crcErrors = 0; temperatureCelsius = 40; readErrorsTotal = 0
    }
    $b = Get-DiskVerdict -Smart $smart -Events @() -Surface $null -FailurePredicted $false -HealthStatus 'Healthy'
    Assert-True ($b.level -ge 2) ('trotz 12 wartender Sektoren nur Stufe ' + $b.level)
}

Test-Case 'Bewertung: nur Uebertragungsfehler deuten auf das Kabel, nicht auf die Platte' {
    $smart = @{ available = $true; pendingSectors = 0; uncorrectableSectors = 0; reallocatedSectors = 0
        crcErrors = 14; temperatureCelsius = 38; readErrorsTotal = 0
    }
    $b = Get-DiskVerdict -Smart $smart -Events @() -Surface $null
    Assert-Equal 1 $b.level 'CRC allein ist kein Austauschgrund'
    Assert-True (@($b.reasons | Where-Object { $_.text -like '*Kabel*' }).Count -eq 1) 'Hinweis auf das Kabel fehlt'
}

Test-Case 'Bewertung: unlesbare SMART-Werte werden benannt statt verschwiegen' {
    $b = Get-DiskVerdict -Smart @{ available = $false } -Events @() -Surface $null
    Assert-Equal 1 $b.level 'fehlende Werte muessen auffallen'
    Assert-True (@($b.reasons | Where-Object { $_.text -like '*nicht lesbar*' }).Count -eq 1) 'Hinweis fehlt'
}

Test-Case 'Lesefehler in der Oberflaechenpruefung heben die Bewertung auf akut' {
    $flaeche = @{ samples = 64; ok = 60; errors = 4; slow = 2; maxMsPerRead = 2800 }
    $b = Get-DiskVerdict -Smart @{ available = $true; pendingSectors = 0 } -Events @() -Surface $flaeche
    Assert-Equal 3 $b.level 'nicht lesbare Bereiche sind akut'
}

Test-Case 'Ereignisse werden dem richtigen Datentraeger zugeordnet' {
    Assert-True (@(Get-DiskEventSummary -DiskNumber 1 -Demo).Count -ge 3) 'kranker Datentraeger ohne Ereignisse'
    Assert-Equal 0 @(Get-DiskEventSummary -DiskNumber 0 -Demo).Count 'gesunder Datentraeger darf keine fremden Ereignisse erben'
}

Test-Case 'Vollstaendige Analyse unterscheidet gesunde und kranke Datentraeger' {
    $gesund = Invoke-DiskAnalysis -DiskNumber 0 -Samples 8 -Demo
    $krank = Invoke-DiskAnalysis -DiskNumber 1 -Samples 8 -Demo
    Assert-Equal 0 $gesund.verdict.level ('gesunde Platte wurde als ' + $gesund.verdict.verdict + ' bewertet')
    Assert-Equal 3 $krank.verdict.level ('kranke Platte wurde nur als ' + $krank.verdict.verdict + ' bewertet')
    Assert-True ($krank.surface.errors -gt 0) 'Oberflaechenpruefung findet die defekte Stelle nicht'
    Assert-True ($krank.smart.pendingSectors -gt 0) 'SMART-Werte fehlen'
}

Write-Host ''
Write-Host '  Dateipruefung' -ForegroundColor Cyan

Test-Case 'Formatpruefung erkennt heile und beschaedigte Dateien' {
    $ordner = Join-Path $WorkDir 'formate'
    New-Item -ItemType Directory -Path $ordner -Force | Out-Null

    $jpgGut = [byte[]](0xFF, 0xD8, 0xFF, 0xE0) + (New-Object byte[] 400) + [byte[]](0xFF, 0xD9)
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'gut.jpg'), $jpgGut)
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'kaputt.jpg'), ([byte[]](0xFF, 0xD8, 0xFF, 0xE0) + (New-Object byte[] 400)))
    $pngGut = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + (New-Object byte[] 80) + [byte[]](0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82)
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'gut.png'), $pngGut)
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'kaputt.png'), ([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + (New-Object byte[] 80)))
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'gut.pdf'), [System.Text.Encoding]::ASCII.GetBytes("%PDF-1.7`nInhalt`n%%EOF"))
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'kaputt.pdf'), [System.Text.Encoding]::ASCII.GetBytes("%PDF-1.7`nabgebrochen"))
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'leer.dat'), (New-Object byte[] 0))

    Assert-True (Get-FileSignatureCheck -Path (Join-Path $ordner 'gut.jpg')).valid 'heiles JPEG faelschlich beanstandet'
    Assert-True (Get-FileSignatureCheck -Path (Join-Path $ordner 'gut.png')).valid 'heiles PNG faelschlich beanstandet'
    Assert-True (Get-FileSignatureCheck -Path (Join-Path $ordner 'gut.pdf')).valid 'heiles PDF faelschlich beanstandet'

    $j = Get-FileSignatureCheck -Path (Join-Path $ordner 'kaputt.jpg')
    Assert-True (-not $j.valid) 'abgeschnittenes JPEG nicht erkannt'
    Assert-Equal 'JPEG' $j.format 'Format falsch erkannt'
    Assert-True ((Get-FileSignatureCheck -Path (Join-Path $ordner 'kaputt.png')).valid -eq $false) 'unvollstaendiges PNG nicht erkannt'
    Assert-True ((Get-FileSignatureCheck -Path (Join-Path $ordner 'kaputt.pdf')).valid -eq $false) 'PDF ohne %%EOF nicht erkannt'
    Assert-True ((Get-FileSignatureCheck -Path (Join-Path $ordner 'leer.dat')).valid -eq $false) 'leere Datei nicht erkannt'
}

Test-Case 'Suche findet genau die beschaedigten Dateien in einem echten Ordner' {
    $ordner = Join-Path $WorkDir 'formate'
    $ergebnis = Invoke-FileIntegrityScan -Path $ordner
    Assert-True $ergebnis.ok 'Suche fehlgeschlagen'
    Assert-Equal 7 $ergebnis.filesTotal 'Anzahl geprueftter Dateien'
    Assert-Equal 4 $ergebnis.damaged ('erwartet 4 Befunde, gefunden ' + $ergebnis.damaged)
    $namen = @($ergebnis.findings | ForEach-Object { Split-Path $_.path -Leaf } | Sort-Object)
    Assert-Equal 'kaputt.jpg kaputt.pdf kaputt.png leer.dat' ($namen -join ' ') 'falsche Dateien beanstandet'
}

Test-Case 'Tiefe Suche meldet nicht lesbare Dateien' {
    $ordner = Join-Path $WorkDir 'tief'
    New-Item -ItemType Directory -Path $ordner -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $ordner 'heil.bin'), (New-Object byte[] 2048))
    $ergebnis = Invoke-FileIntegrityScan -Path $ordner -Deep
    Assert-True $ergebnis.ok 'Suche fehlgeschlagen'
    Assert-True $ergebnis.deep 'Tiefenmodus nicht vermerkt'
    Assert-Equal 0 $ergebnis.damaged 'heile Datei faelschlich beanstandet'
}

Test-Case 'Reparatur im Demobetrieb: Systemdatei ueber SFC, Rest aus Vorgaengerversion' {
    $sc = Invoke-DemoIntegrityScan -Path 'C:\Users'
    $rp = Invoke-FileRepairBatch -Findings $sc.findings -Strategy Auto -Demo -Confirm:$false
    Assert-True ($rp.repaired -ge 3) ('zu wenige repariert: ' + $rp.repaired)
    $system = @($rp.results | Where-Object { $_.path -like '*Windows*' }) | Select-Object -First 1
    Assert-Equal 'SystemFile' $system.strategy 'Systemdatei haette ueber SFC laufen muessen'
    $ohne = @($rp.results | Where-Object { $_.path -like '*Projekt-2025.zip' }) | Select-Object -First 1
    Assert-True (-not $ohne.ok) 'fehlende Vorgaengerversion wurde als Erfolg gemeldet'
    Assert-True ($ohne.detail -like '*keine Vorgaengerversion*') 'Begruendung fehlt'
}

Test-Case 'Reparaturweg "Nur melden" veraendert nichts' {
    $sc = Invoke-DemoIntegrityScan -Path 'C:\Users'
    $rp = Invoke-FileRepairBatch -Findings $sc.findings -Strategy ReportOnly -Demo -Confirm:$false
    Assert-Equal 0 $rp.repaired 'es wurde trotzdem repariert'
    Assert-True (@($rp.results | Where-Object { $_.strategy -eq 'ReportOnly' }).Count -eq @($sc.findings).Count) 'nicht alle nur gemeldet'
}

Write-Host ''
Write-Host '  Starter und Installation' -ForegroundColor Cyan

Test-Case 'Startdateien sind sauber: nur ASCII, CRLF, keine Fortsetzungszeichen' {
    $dateien = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.cmd' -File |
            Where-Object { $_.FullName -notlike '*node_modules*' })
    Assert-True ($dateien.Count -ge 3) 'zu wenige Startdateien gefunden'
    foreach ($d in $dateien) {
        $bytes = [System.IO.File]::ReadAllBytes($d.FullName)
        # Nicht-ASCII: Umlaute in einer .cmd gehen in der Konsole kaputt
        $fremd = @($bytes | Where-Object { $_ -gt 127 })
        Assert-Equal 0 $fremd.Count ($d.Name + ' enthaelt Zeichen ausserhalb von ASCII')
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        Assert-True ($text.Contains("`r`n")) ($d.Name + ' hat keine Windows-Zeilenenden')
        # Fortsetzungszeichen am Zeilenende sind in Bloecken beruechtigt
        $zeilen = $text -split "`r`n"
        $mitCaret = @($zeilen | Where-Object { $_.TrimEnd().EndsWith('^') })
        Assert-Equal 0 $mitCaret.Count ($d.Name + ' nutzt Fortsetzungszeichen am Zeilenende')
        # Leere Argumentliste bricht unter Windows PowerShell 5.1 ab
        Assert-True (-not $text.Contains("-ArgumentList ''")) ($d.Name + " uebergibt eine leere Argumentliste")
    }
}

Test-Case 'Jeder Fehlerweg in den Startdateien haelt das Fenster offen' {
    foreach ($name in @('RepairCenter.cmd', 'installer\Install.cmd', 'installer\Uninstall.cmd')) {
        $pfad = Join-Path $Root $name
        $zeilen = Get-Content -LiteralPath $pfad
        # Sprungmarken einsammeln und je Marke pruefen, ob vor dem naechsten
        # Sprungziel ein "pause" steht. Bewusst zeilenweise statt mit einem
        # Regex - der vorige Versuch scheiterte an einem Steuerzeichen.
        $marken = @()
        for ($i = 0; $i -lt $zeilen.Count; $i++) {
            $z = $zeilen[$i].Trim()
            if ($z -match '^:[A-Za-z]') { $marken += ,@($z.TrimStart(':'), $i) }
        }
        Assert-True ($marken.Count -ge 1) ($name + ' hat keine Sprungmarken')

        $fehlermarken = @($marken | Where-Object { $_[0] -like 'fehl*' -or $_[0] -like 'keine*' })
        Assert-True ($fehlermarken.Count -ge 1) ($name + ' hat keine Fehlerbehandlung')

        foreach ($m in $fehlermarken) {
            $von = [int]$m[1]
            $bis = $zeilen.Count - 1
            foreach ($andere in $marken) {
                if ([int]$andere[1] -gt $von -and [int]$andere[1] -le $bis) { $bis = [int]$andere[1] - 1 }
            }
            $abschnitt = @($zeilen[$von..$bis] | ForEach-Object { $_.Trim().ToLowerInvariant() })
            Assert-True ($abschnitt -contains 'pause') ($name + ': Sprungmarke ' + $m[0] + ' ohne pause')
        }
        Assert-True (($zeilen -join ' ') -like '*if not exist*') ($name + ' prueft nicht, ob die Zieldatei vorhanden ist')
    }
}

Test-Case 'Das Setup-Skript nimmt alles mit, was zum Start noetig ist' {
    $iss = Get-Content -LiteralPath (Join-Path (Join-Path $Root 'installer') 'RepairCenter.iss') -Raw
    # Ohne tools\ fehlt der Starter - die Installation waere sofort unbrauchbar
    foreach ($pflicht in @('..\src\*', '..\web\*', '..\tools\*', '..\RepairCenter.cmd', '..\package.json',
            'Install.ps1', 'Uninstall.ps1')) {
        Assert-True ($iss -like ('*' + $pflicht + '*')) ('Setup-Skript kopiert nicht: ' + $pflicht)
    }
}

Test-Case 'Installation kopiert alles und laesst sich wiederholen' {
    $env:RC_NONINTERACTIVE = '1'
    try {
        $ziel = Join-Path $WorkDir 'inst'
        New-Item -ItemType Directory -Path $ziel -Force | Out-Null
        $skript = Join-Path (Join-Path $Root 'installer') 'Install.ps1'

        & $skript -DestinationRoot $ziel -NoShortcuts -NoRegistry -NoTask -Quiet -Confirm:$false | Out-Null
        Assert-Equal 0 $LASTEXITCODE 'Installation meldete einen Fehler'

        $installiert = Join-Path $ziel 'RepairCenter'
        foreach ($pflicht in @('src\RepairCenter.Server.ps1', 'src\modules\RepairEngine.psm1',
                'src\modules\DiskAnalysis.psm1', 'src\modules\FileIntegrity.psm1',
                'web\index.html', 'web\i18n\de.json', 'tools\Start-RepairCenter.ps1',
                'installer\Install.ps1', 'RepairCenter.cmd', 'package.json')) {
            Assert-True (Test-Path (Join-Path $installiert $pflicht)) ('nach der Installation fehlt: ' + $pflicht)
        }

        # Zweiter Lauf darf nicht scheitern (Aktualisierung einer vorhandenen Fassung)
        & $skript -DestinationRoot $ziel -NoShortcuts -NoRegistry -NoTask -Quiet -Confirm:$false | Out-Null
        Assert-Equal 0 $LASTEXITCODE 'die Wiederholung der Installation scheiterte'
    }
    finally { Remove-Item Env:RC_NONINTERACTIVE -ErrorAction SilentlyContinue }
}

Test-Case 'Unvollstaendige Quelle wird mit Hinweis abgelehnt' {
    $env:RC_NONINTERACTIVE = '1'
    try {
        $kaputt = Join-Path $WorkDir 'kaputtequelle'
        New-Item -ItemType Directory -Path (Join-Path $kaputt 'installer') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Join-Path $Root 'installer') 'Install.ps1') `
            -Destination (Join-Path $kaputt 'installer\Install.ps1') -Force
        # Write-Host schreibt nicht in den Ausgabestrom - ohne *>&1 bleibt
        # die Meldung unsichtbar und der Test prueft ins Leere.
        $ausgabe = & (Join-Path $kaputt 'installer\Install.ps1') -DestinationRoot (Join-Path $WorkDir 'inst2') -Quiet -Confirm:$false *>&1
        Assert-Equal 2 $LASTEXITCODE 'unvollstaendige Quelle wurde angenommen'
        Assert-True ((($ausgabe | Out-String) -like '*unvollstaendig*')) 'kein verstaendlicher Hinweis'
    }
    finally { Remove-Item Env:RC_NONINTERACTIVE -ErrorAction SilentlyContinue }
}

Test-Case 'Der Starter faehrt den Dienst wirklich hoch' {
    # Dieser Test fehlte - geprueft wurde nur der Fehlerweg. Dadurch blieb
    # unbemerkt, dass die Parameter als Array gesplattet wurden und damit
    # positionsweise ankamen ("-Port" landete im Parameter Port).
    $env:RC_NONINTERACTIVE = '1'
    $prozess = $null
    $testPort = 8699
    try {
        $starter = Join-Path (Join-Path $Root 'tools') 'Start-RepairCenter.ps1'
        $startArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $starter,
            '-Port', $testPort, '-NoElevate', '-NoBrowser', '-Demo',
            '-LogRoot', (Join-Path $WorkDir 'starterlogs'))
        $prozess = Start-Process -FilePath $psExe -ArgumentList $startArgs -PassThru

        $erreichbar = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 1
            try {
                $h = Invoke-RestMethod -Uri ('http://localhost:{0}/api/health' -f $testPort) -TimeoutSec 5
                if ($h.ok) { $erreichbar = $true; break }
            }
            catch { Write-Verbose 'noch nicht da' }
            if ($prozess.HasExited) { break }
        }
        Assert-True $erreichbar 'der ueber den Starter gestartete Dienst war nicht erreichbar'

        $cfg = Invoke-RestMethod -Uri ('http://localhost:{0}/api/config' -f $testPort) -TimeoutSec 10
        Assert-Equal $testPort $cfg.port 'der Starter hat den Port nicht durchgereicht'
        Assert-True $cfg.demo 'der Starter hat -Demo nicht durchgereicht'
    }
    finally {
        if ($prozess -and -not $prozess.HasExited) {
            try { Stop-Process -Id $prozess.Id -Force -ErrorAction SilentlyContinue } catch { Write-Verbose 'schon beendet' }
        }
        Remove-Item Env:RC_NONINTERACTIVE -ErrorAction SilentlyContinue
    }
}

Test-Case 'Der Starter meldet eine fehlende Dienstdatei, statt sich zu schliessen' {
    $env:RC_NONINTERACTIVE = '1'
    try {
        $leer = Join-Path $WorkDir 'leerstart'
        New-Item -ItemType Directory -Path (Join-Path $leer 'tools') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Join-Path $Root 'tools') 'Start-RepairCenter.ps1') `
            -Destination (Join-Path $leer 'tools\Start-RepairCenter.ps1') -Force
        $ausgabe = & (Join-Path $leer 'tools\Start-RepairCenter.ps1') -NoElevate -NoBrowser *>&1
        Assert-Equal 1 $LASTEXITCODE 'fehlende Dienstdatei wurde nicht gemeldet'
        $text = $ausgabe | Out-String
        Assert-True ($text -like '*nicht gefunden*') 'keine verstaendliche Meldung'
        Assert-True ($text -like '*entpacken*') 'kein Hinweis, was zu tun ist'
    }
    finally { Remove-Item Env:RC_NONINTERACTIVE -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '  Aktualisierung einspielen' -ForegroundColor Cyan

function New-TestInstallation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Testhilfe: legt nur Dateien im Pruefverzeichnis an.')]
    param([string]$Ziel, [string]$Version)
    New-Item -ItemType Directory -Path (Join-Path $Ziel 'src\modules') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Ziel 'web') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Ziel 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Ziel 'src\RepairCenter.Server.ps1') -Value ('# Fassung ' + $Version) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Ziel 'src\modules\RepairEngine.psm1') -Value ('# Modul ' + $Version) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Ziel 'web\index.html') -Value ('<html>' + $Version + '</html>') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Ziel 'README.md') -Value ('Fassung ' + $Version) -Encoding UTF8
}

Test-Case 'Einspielen ersetzt die Dateien und legt eine Sicherung an' {
    $wurzel = Join-Path $WorkDir 'upd'
    $installation = Join-Path $wurzel 'RepairCenter'
    $neuerStand = Join-Path $wurzel 'neu\repair-center'
    New-TestInstallation -Ziel $installation -Version 'alt'
    New-TestInstallation -Ziel $neuerStand -Version 'neu'
    Set-Content -LiteralPath (Join-Path $neuerStand 'src\NEU.txt') -Value 'dazugekommen' -Encoding UTF8

    $paket = Join-Path $wurzel 'RepairCenter-9.9.9.zip'
    Compress-Archive -Path (Join-Path $wurzel 'neu\repair-center') -DestinationPath $paket -Force

    $helfer = Join-Path (Join-Path $Root 'tools') 'Apply-Update.ps1'
    & $helfer -Package $paket -InstallDir $installation -NoRestart -SkipWait -Confirm:$false | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'Einspielen meldete einen Fehler'

    $inhalt = Get-Content -LiteralPath (Join-Path $installation 'src\RepairCenter.Server.ps1') -Raw
    Assert-True ($inhalt -like '*neu*') 'Datei wurde nicht ersetzt'
    Assert-True (Test-Path (Join-Path $installation 'src\NEU.txt')) 'neue Datei fehlt'

    $sicherungen = @(Get-ChildItem -LiteralPath $wurzel -Directory | Where-Object { $_.Name -like 'RepairCenter-Sicherung-*' })
    Assert-Equal 1 $sicherungen.Count 'keine Sicherung angelegt'
    $alt = Get-Content -LiteralPath (Join-Path $sicherungen[0].FullName 'src\RepairCenter.Server.ps1') -Raw
    Assert-True ($alt -like '*alt*') 'die Sicherung enthaelt nicht die alte Fassung'
}

Test-Case 'Unvollstaendiges Paket wird abgelehnt - ohne etwas zu veraendern' {
    $wurzel = Join-Path $WorkDir 'upd2'
    $installation = Join-Path $wurzel 'RepairCenter'
    New-TestInstallation -Ziel $installation -Version 'alt'

    $muell = Join-Path $wurzel 'muell'
    New-Item -ItemType Directory -Path $muell -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $muell 'liesmich.txt') -Value 'kein Programm' -Encoding UTF8
    $paket = Join-Path $wurzel 'RepairCenter-9.9.9.zip'
    Compress-Archive -Path (Join-Path $muell '*') -DestinationPath $paket -Force

    $helfer = Join-Path (Join-Path $Root 'tools') 'Apply-Update.ps1'
    & $helfer -Package $paket -InstallDir $installation -NoRestart -SkipWait -Confirm:$false 2>&1 | Out-Null
    Assert-Equal 1 $LASTEXITCODE 'unvollstaendiges Paket wurde angenommen'
    $inhalt = Get-Content -LiteralPath (Join-Path $installation 'src\RepairCenter.Server.ps1') -Raw
    Assert-True ($inhalt -like '*alt*') 'die alte Fassung wurde trotzdem ueberschrieben'
}

Test-Case 'Fehlendes Paket bricht sauber ab' {
    $helfer = Join-Path (Join-Path $Root 'tools') 'Apply-Update.ps1'
    & $helfer -Package (Join-Path $WorkDir 'gibtsnicht.zip') -InstallDir $WorkDir -NoRestart -SkipWait -Confirm:$false 2>&1 | Out-Null
    Assert-Equal 1 $LASTEXITCODE 'fehlendes Paket haette einen Fehler ergeben muessen'
}

Write-Host ''
Write-Host '  Backend (REST-API)' -ForegroundColor Cyan

$serverArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SrcDir 'RepairCenter.Server.ps1'),
    '-Port', $Port, '-LogRoot', $WorkDir, '-Demo', '-NoBrowser')
$server = Start-Process -FilePath $psExe -ArgumentList $serverArgs -PassThru
Start-Sleep -Seconds 4
$base = ('http://localhost:{0}' -f $Port)

try {
    Test-Case 'GET /api/health antwortet' {
        $r = Invoke-RestMethod -Uri ($base + '/api/health') -TimeoutSec 10
        Assert-True $r.ok 'health nicht ok'
        Assert-Equal '1.5.1' $r.version 'Version'
    }
    Test-Case 'GET /api/system liefert Systemdaten' {
        $r = Invoke-RestMethod -Uri ($base + '/api/system') -TimeoutSec 10
        Assert-True ($null -ne $r.psVersion) 'psVersion fehlt'
        Assert-True $r.demo 'Demoflag nicht gesetzt'
    }
    Test-Case 'GET /api/config liefert Ablage und Betriebsart' {
        $r = Invoke-RestMethod -Uri ($base + '/api/config') -TimeoutSec 10
        Assert-Equal '1.5.1' $r.version 'Version'
        Assert-True $r.demo 'Demoflag'
        Assert-True ([bool]$r.logRoot) 'logRoot fehlt'
    }
    Test-Case 'GET /api/schedule antwortet (unter Linux als nicht unterstuetzt)' {
        $r = Invoke-RestMethod -Uri ($base + '/api/schedule') -TimeoutSec 10
        Assert-True ($null -ne $r.supported) 'Feld supported fehlt'
    }
    Test-Case 'Oberflaeche und Sprachpakete werden ausgeliefert' {
        foreach ($p in @('/', '/assets/app.js', '/assets/styles.css', '/i18n/de.json', '/i18n/en.json')) {
            $resp = Invoke-WebRequest -Uri ($base + $p) -TimeoutSec 10 -UseBasicParsing
            Assert-Equal 200 $resp.StatusCode ('HTTP-Status fuer ' + $p)
        }
    }
    Test-Case 'Sprachpakete haben identische Schluessel' {
        $de = Invoke-RestMethod -Uri ($base + '/i18n/de.json') -TimeoutSec 10
        $en = Invoke-RestMethod -Uri ($base + '/i18n/en.json') -TimeoutSec 10
        $kde = @($de.PSObject.Properties.Name) | Sort-Object
        $ken = @($en.PSObject.Properties.Name) | Sort-Object
        $missing = @(Compare-Object $kde $ken | ForEach-Object { $_.InputObject })
        Assert-Equal 0 $missing.Count ('Unterschiedliche Schluessel: ' + ($missing -join ', '))
    }
    Test-Case 'GET /api/disks liefert die Bestandsaufnahme' {
        # Hinweis: @(Invoke-RestMethod ...) direkt geschachtelt zaehlt in
        # PowerShell 7 nur 1, weil die PSObject-Huelle erhalten bleibt.
        $resp = Invoke-RestMethod -Uri ($base + '/api/disks') -TimeoutSec 10
        $r = @($resp)
        Assert-True ($r.Count -ge 3) ('zu wenige Datentraeger: ' + $r.Count)
        Assert-True ($r[0].protected) 'Systemdatentraeger nicht als geschuetzt gemeldet'
    }
    Test-Case 'GET /api/disk/estimate schaetzt Verfahren und Dauer' {
        $r = Invoke-RestMethod -Uri ($base + '/api/disk/estimate?number=1&strategy=Auto') -TimeoutSec 10
        Assert-Equal 'Zero' $r.strategy 'Verfahren fuer die Festplatte'
        Assert-Equal 'DISK1' $r.confirmationToken 'Bestaetigungsschluessel'
        Assert-True ($r.seconds -gt 0) 'keine Dauer geschaetzt'
    }
    Test-Case 'Loeschauftrag ueber die API laeuft durch' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $body = '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","demo":true}'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -Body $body -ContentType 'application/json' -Headers $script:ApiHeaders -TimeoutSec 15
        Assert-True ([bool]$start.jobId) 'keine Auftrags-ID'
        $done = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $done = $true; break }
        }
        Assert-True $done 'Auftrag wurde nicht fertig'
        Assert-True $j.ok 'Auftrag fehlgeschlagen'
        Assert-Equal 100 $j.percent 'Fortschritt unvollstaendig'
    }
    Test-Case 'Loeschauftrag auf den Systemdatentraeger scheitert kontrolliert' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $body = '{"diskNumber":0,"strategy":"Zero","confirmation":"DISK0","demo":true}'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -Body $body -ContentType 'application/json' -Headers $script:ApiHeaders -TimeoutSec 15
        $done = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $done = $true; break }
        }
        Assert-True $done 'Auftrag haengt'
        Assert-True (-not $j.ok) 'Systemdatentraeger wurde geloescht'
        Assert-True ($j.detail -like '*Systemdatentraeger*') 'falsche Begruendung'
    }
    Test-Case 'GET /api/disk/active meldet, ob gerade ein Vorgang laeuft' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorgang haengt'
        $a = Invoke-RestMethod -Uri ($base + '/api/disk/active') -TimeoutSec 10
        Assert-True (-not $a.busy) 'es duerfte gerade kein Vorgang laufen'

        $start = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","demo":true}'
        $b = Invoke-RestMethod -Uri ($base + '/api/disk/active') -TimeoutSec 10
        Assert-True $b.busy 'laufender Vorgang wird nicht gemeldet'
        Assert-Equal $start.jobId $b.running 'falsche Auftrags-ID gemeldet'
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorgang wurde nicht fertig'
    }

    Test-Case 'GET /api/disk/targets und /api/disk/measure liefern Planungsdaten' {
        $resp = Invoke-RestMethod -Uri ($base + '/api/disk/targets?exclude=1') -TimeoutSec 10
        $targets = @($resp)
        Assert-True ($targets.Count -ge 2) 'zu wenige Ziele'
        Assert-Equal 0 (@($targets | Where-Object { $_.diskNumber -eq 1 }).Count) 'Quelle als Ziel angeboten'
        $m = Invoke-RestMethod -Uri ($base + '/api/disk/measure?number=1') -TimeoutSec 10
        Assert-True ($m.bytes -gt 0) 'keine Datenmenge'
        Assert-True ($m.files -gt 0) 'keine Dateizahl'
    }
    Test-Case 'Sichern und danach loeschen laeuft als verketteter Auftrag' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $body = '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","demo":true,' +
                '"rescueTarget":"D:\\Rettung","rescueMode":"Copy","rescueThreads":32,"rescueUnbuffered":true}'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -Body $body -ContentType 'application/json' -Headers $script:ApiHeaders -TimeoutSec 15
        $done = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $done = $true; break }
        }
        Assert-True $done 'Auftrag wurde nicht fertig'
        Assert-True $j.ok ('Auftrag fehlgeschlagen: ' + $j.detail)
        $stages = @($j.stages)
        Assert-Equal 2 $stages.Count 'es muessten zwei Abschnitte sein'
        Assert-Equal 'rescue' $stages[0].name 'erster Abschnitt muss die Sicherung sein'
        Assert-Equal 'PASS' $stages[0].status 'Sicherung nicht erfolgreich'
        Assert-Equal 'wipe' $stages[1].name 'zweiter Abschnitt muss das Loeschen sein'
        Assert-Equal 'PASS' $stages[1].status 'Loeschen nicht erfolgreich'
        Assert-True ($null -ne $j.rescue -and $j.rescue.ok) 'Zusammenfassung der Sicherung fehlt'
    }
    Test-Case 'Scheitert die Sicherung, wird nichts geloescht' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $body = '{"diskNumber":1,"strategy":"Zero","confirmation":"DISK1","demo":true,' +
                '"rescueTarget":"F:\\Rettung","rescueMode":"Copy"}'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -Body $body -ContentType 'application/json' -Headers $script:ApiHeaders -TimeoutSec 15
        $done = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $done = $true; break }
        }
        Assert-True $done 'Auftrag haengt'
        Assert-True (-not $j.ok) 'Auftrag meldet Erfolg trotz gescheiterter Sicherung'
        $stages = @($j.stages)
        Assert-Equal 'FAILED' $stages[0].status 'Sicherung haette scheitern muessen'
        Assert-Equal 0 (@($stages | Where-Object { $_.name -eq 'wipe' }).Count) 'es wurde trotzdem geloescht'
        Assert-True ($j.detail -like '*NICHTS geloescht*') 'Hinweis fehlt'
    }
    Test-Case 'Schreibende Anfrage ohne Zusatzkopf wird abgewiesen (Schutz vor fremden Webseiten)' {
        $code = 0
        try {
            Invoke-WebRequest -Uri ($base + '/api/disk/wipe') -Method Post -UseBasicParsing -TimeoutSec 10 `
                -ContentType 'application/json' -Body '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","demo":true}' | Out-Null
        }
        catch { $code = [int]$_.Exception.Response.StatusCode }
        Assert-Equal 403 $code 'Anfrage ohne Zusatzkopf haette abgelehnt werden muessen'
    }

    Test-Case 'Anfrage mit fremder Herkunft wird abgewiesen' {
        $code = 0
        try {
            $h = @{ 'X-RepairCenter' = '1'; 'Origin' = 'https://boese-seite.example' }
            Invoke-WebRequest -Uri ($base + '/api/disk/wipe') -Method Post -UseBasicParsing -TimeoutSec 10 `
                -Headers $h -ContentType 'application/json' -Body '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","demo":true}' | Out-Null
        }
        catch { $code = [int]$_.Exception.Response.StatusCode }
        Assert-Equal 403 $code 'fremde Herkunft haette abgelehnt werden muessen'
    }

    Test-Case 'Vorabanfragen (OPTIONS) werden nicht beantwortet' {
        $code = 0
        try { $code = (Invoke-WebRequest -Uri ($base + '/api/disk/wipe') -Method Options -UseBasicParsing -TimeoutSec 10).StatusCode }
        catch { $code = [int]$_.Exception.Response.StatusCode }
        Assert-Equal 405 $code 'OPTIONS haette abgelehnt werden muessen'
    }

    Test-Case 'Eingeschleuste Zusatzparameter werden abgewiesen' {
        $faelle = @(
            '{"driveLetter":"E -Demo -Full","fileSystem":"NTFS"}',
            '{"driveLetter":"E","fileSystem":"XFS"}',
            '{"driveLetter":"E","fileSystem":"NTFS","label":"a\" -Force x"}',
            '{"driveLetter":"E","fileSystem":"NTFS","unbekanntesFeld":"x"}'
        )
        foreach ($f in $faelle) {
            $code = 0
            try {
                Invoke-WebRequest -Uri ($base + '/api/disk/format') -Method Post -UseBasicParsing -TimeoutSec 10 `
                    -Headers $script:ApiHeaders -ContentType 'application/json' -Body $f | Out-Null
            }
            catch { $code = [int]$_.Exception.Response.StatusCode }
            Assert-Equal 400 $code ('haette abgelehnt werden muessen: ' + $f)
        }
    }

    Test-Case 'Deutsche Bezeichnungen mit Umlauten werden angenommen' {
        # Ein deutschsprachiges Werkzeug muss "Buero" mit echtem Umlaut koennen.
        # Achtung, Stolperfalle: '+' und ',' in einer Zeile gemischt liest
        # PowerShell als EINEN Ausdruck - aus zwei Eintraegen wird dann eine
        # einzige Zeichenkette. Deshalb erst die Werte bilden, dann die Liste.
        $labelEins = 'B' + [char]0xFC + 'ro ' + [char]0xC4 + 'rger'
        $labelZwei = 'Gr' + [char]0xF6 + [char]0xDF + 'e (2026)'
        $gute = @(
            ('{"driveLetter":"E","fileSystem":"NTFS","label":"' + $labelEins + '","demo":true}'),
            ('{"driveLetter":"E","fileSystem":"NTFS","label":"' + $labelZwei + '","demo":true}')
        )
        Assert-Equal 2 @($gute).Count 'Testdaten sind nicht zwei getrennte Eintraege'
        foreach ($g in $gute) {
            Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
            $r = $null
            $grund = ''
            try {
                $r = Invoke-RestMethod -Uri ($base + '/api/disk/format') -Method Post -TimeoutSec 15 `
                    -Headers $script:ApiHeaders -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($g))
            }
            catch {
                # Die Begruendung des Dienstes gehoert in die Fehlermeldung -
                # sonst steht da nur "400" und man raet.
                $grund = $_.ErrorDetails.Message
                if (-not $grund -and $_.Exception.Response) {
                    $leser = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $grund = $leser.ReadToEnd()
                }
            }
            Assert-True ([bool]$r.jobId) ('abgelehnt, obwohl gueltig: ' + $g + ' | Antwort: ' + ($grund -replace '\s+', ' '))

            # Der Umlaut muss auch die Prozessgrenze heil ueberstehen
            $fertig = $false
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Seconds 1
                $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $r.jobId) -TimeoutSec 10
                if ($j.status -eq 'done') { $fertig = $true; break }
            }
            Assert-True $fertig 'Auftrag wurde nicht fertig'
        }
    }

    Test-Case 'Werte mit Leerzeichen kommen im Auftragsprozess unverfaelscht an' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $ziel = 'D:\Rettung B' + [char]0xFC + 'ro Ordner'
        $koerper = '{"diskNumber":2,"rescueTarget":"D:\\Rettung B' + [char]0xFC + 'ro Ordner","rescueMode":"Copy","demo":true}'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/rescue') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($koerper))
        $done = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $done = $true; break }
        }
        Assert-True $done 'Auftrag wurde nicht fertig'
        # Ohne Anfuehrungszeichen um das Argument endete der Pfad bei "D:\Rettung"
        $zeile = @($j.log | Where-Object { $_.text -like '*Sichere Daten*' }) | Select-Object -First 1
        Assert-True ($null -ne $zeile) 'kein Protokolleintrag zur Sicherung'
        Assert-True ($zeile.text -like ('*' + $ziel + '*')) ('Pfad kam verstuemmelt an: ' + $zeile.text)
    }

    Test-Case 'Gefaehrliche Zeichen in Bezeichnungen bleiben verboten' {
        foreach ($b in @(
                '{"driveLetter":"E","fileSystem":"NTFS","label":"a\" -Force"}',
                '{"driveLetter":"E","fileSystem":"NTFS","label":"pfad\\weg"}',
                '{"driveLetter":"E","fileSystem":"NTFS","label":"viel|zu|boese"}')) {
            $code = 0
            try {
                Invoke-WebRequest -Uri ($base + '/api/disk/format') -Method Post -UseBasicParsing -TimeoutSec 10 `
                    -Headers $script:ApiHeaders -ContentType 'application/json' -Body $b | Out-Null
            }
            catch { $code = [int]$_.Exception.Response.StatusCode }
            Assert-Equal 400 $code ('haette abgelehnt werden muessen: ' + $b)
        }
    }

    Test-Case 'Unsinnige Zahlenwerte werden abgewiesen' {
        foreach ($f in @(
                '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","bufferMiB":99999}',
                '{"diskNumber":-5,"strategy":"Zero","confirmation":"DISK2"}',
                '{"diskNumber":2,"strategy":"Loeschen","confirmation":"DISK2"}',
                '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","rescueTarget":"D:\\..\\..\\Windows"}')) {
            $code = 0
            try {
                Invoke-WebRequest -Uri ($base + '/api/disk/wipe') -Method Post -UseBasicParsing -TimeoutSec 10 `
                    -Headers $script:ApiHeaders -ContentType 'application/json' -Body $f | Out-Null
            }
            catch { $code = [int]$_.Exception.Response.StatusCode }
            Assert-Equal 400 $code ('haette abgelehnt werden muessen: ' + $f)
        }
    }

    Test-Case 'Zwei Datentraegervorgaenge gleichzeitig werden verhindert' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $body1 = '{"diskNumber":1,"strategy":"Zero","confirmation":"DISK1","demo":true}'
        $first = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -Body $body1 `
            -ContentType 'application/json' -Headers $script:ApiHeaders -TimeoutSec 15
        Assert-True ([bool]$first.jobId) 'erster Auftrag wurde nicht angenommen'

        $code = 0
        try {
            Invoke-WebRequest -Uri ($base + '/api/disk/wipe') -Method Post -UseBasicParsing -TimeoutSec 10 `
                -Headers $script:ApiHeaders -ContentType 'application/json' `
                -Body '{"diskNumber":2,"strategy":"Zero","confirmation":"DISK2","demo":true}' | Out-Null
        }
        catch { $code = [int]$_.Exception.Response.StatusCode }
        Assert-Equal 409 $code 'zweiter Auftrag haette abgelehnt werden muessen'

        # ersten Auftrag abwarten, damit die folgenden Tests frei sind
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 1
            $st = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $first.jobId) -TimeoutSec 10
            if ($st.status -eq 'done') { break }
        }
    }

Test-Case 'Beschaedigte Zustandsdateien: sichtbar, einmal gemeldet, entfernbar' {
        # Genau der Fall aus dem Echtbetrieb: eine leere und eine
        # abgeschnittene Zustandsdatei. Frueher verschwanden beide
        # Laeufe aus dem Verlauf und die Meldung kam bei jeder Abfrage neu.
        $runsDir = Join-Path $WorkDir 'runs'
        $leerId = '20260929-231933-aaaaaaaa'
        $halbId = '20260929-232151-bbbbbbbb'
        New-Item -ItemType Directory -Path (Join-Path $runsDir $leerId) -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runsDir $halbId) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path (Join-Path $runsDir $leerId) 'state.json') -Value '' -NoNewline -Encoding UTF8
        Set-Content -LiteralPath (Join-Path (Join-Path $runsDir $halbId) 'state.json') -Value '{"runId":"abc","status":"run' -NoNewline -Encoding UTF8

        $resp = Invoke-RestMethod -Uri ($base + '/api/runs') -TimeoutSec 10
        $alle = @($resp)
        $kaputt = @($alle | Where-Object { $_.status -eq 'unreadable' })
        Assert-True ($kaputt.Count -ge 2) ('beschaedigte Laeufe fehlen im Verlauf: ' + $kaputt.Count)
        $einer = $kaputt | Where-Object { $_.runId -eq $leerId } | Select-Object -First 1
        Assert-True ($null -ne $einer) 'der leere Lauf wird nicht aufgefuehrt'
        Assert-True ([bool]$einer.reason) 'kein Grund angegeben'
        Assert-True ($einer.reason -like '*Byte*') ('Grund nennt die Dateigroesse nicht: ' + $einer.reason)

        # Mehrfach abfragen darf die Meldung nicht wiederholen - geprueft
        # wird, dass der Dienst dabei nicht stolpert und stabil antwortet.
        for ($i = 0; $i -lt 3; $i++) {
            # Erst zuweisen, dann @() - sonst bleibt die PSObject-Huelle
            # stehen und die Liste zaehlt 1 statt n. Dieselbe Falle wie in 1.2.5.
            $antwort = Invoke-RestMethod -Uri ($base + '/api/runs') -TimeoutSec 10
            $w = @($antwort)
            Assert-True (@($w | Where-Object { $_.status -eq 'unreadable' }).Count -ge 2) `
                ('Verlauf wird instabil: ' + $w.Count + ' Eintraege, davon ' +
                 @($w | Where-Object { $_.status -eq 'unreadable' }).Count + ' unlesbar')
        }

        # Entfernen
        $weg = Invoke-RestMethod -Uri ($base + '/api/run/' + $leerId) -Method Delete `
            -Headers $script:ApiHeaders -TimeoutSec 10
        Assert-True $weg.removed 'Entfernen nicht bestaetigt'
        Assert-True (-not (Test-Path (Join-Path $runsDir $leerId))) 'Verzeichnis liegt noch da'
        $danach = @(Invoke-RestMethod -Uri ($base + '/api/runs') -TimeoutSec 10)
        Assert-Equal 0 (@($danach | Where-Object { $_.runId -eq $leerId }).Count) 'Eintrag noch im Verlauf'
    }

    Test-Case 'Ein unbekannter Lauf laesst sich nicht entfernen' {
        $code = 0
        try {
            Invoke-WebRequest -Uri ($base + '/api/run/00000000-000000-deadbeef') -Method Delete `
                -Headers $script:ApiHeaders -UseBasicParsing -TimeoutSec 10 | Out-Null
        }
        catch { $code = [int]$_.Exception.Response.StatusCode }
        Assert-Equal 404 $code 'unbekannte Kennung haette 404 ergeben muessen'
    }

    Test-Case 'Listen-Endpunkte liefern immer ein Array - auch bei genau einem Eintrag' {
        # ConvertTo-Json macht aus einem einelementigen Array ein Objekt und
        # aus einem leeren "null". Die Oberflaeche ruft darauf .forEach auf.
        foreach ($ep in @('/api/runs', '/api/disks', '/api/disk/targets?exclude=1')) {
            $raw = (Invoke-WebRequest -Uri ($base + $ep) -UseBasicParsing -TimeoutSec 10).Content.Trim()
            Assert-True ($raw.StartsWith('[')) ($ep + ' liefert kein Array, sondern: ' + $raw.Substring(0, [Math]::Min(60, $raw.Length)))
        }
    }

    Test-Case 'Abgebrochener Datentraegervorgang wird als beendet vermerkt' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/wipe') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"diskNumber":1,"strategy":"Zero","confirmation":"DISK1","demo":true}'
        Start-Sleep -Seconds 2
        $cancel = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId + '/cancel') -Method Post `
            -Headers $script:ApiHeaders -TimeoutSec 10
        Assert-True $cancel.cancelled 'Abbruch nicht bestaetigt'
        Start-Sleep -Seconds 2

        $st = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
        Assert-Equal 'done' $st.status 'Vorgang haengt weiter auf "running"'
        Assert-True (-not $st.ok) 'abgebrochener Vorgang darf nicht als erfolgreich gelten'
        Assert-True ($st.detail -like '*abgebrochen*') ('unerwarteter Text: ' + $st.detail)

        $active = Invoke-RestMethod -Uri ($base + '/api/disk/active') -TimeoutSec 10
        Assert-True (-not $active.busy) 'Sperre nach dem Abbruch nicht freigegeben'
    }

    Test-Case 'Abgebrochener Reparaturlauf wird als beendet vermerkt' {
        $start = Invoke-RestMethod -Uri ($base + '/api/run') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"mode":"Repair","optimize":"Safe","demo":true}'
        Start-Sleep -Seconds 3
        Invoke-RestMethod -Uri ($base + '/api/run/' + $start.runId + '/cancel') -Method Post `
            -Headers $script:ApiHeaders -TimeoutSec 10 | Out-Null
        Start-Sleep -Seconds 2
        $st = Invoke-RestMethod -Uri ($base + '/api/run/' + $start.runId) -TimeoutSec 10
        Assert-Equal 'done' $st.status 'Lauf haengt weiter auf "running"'
        # Zwei Wege sind moeglich: die Engine bemerkt die Steuerdatei und endet
        # geordnet, oder der Prozess wird hart beendet und der Dienst traegt
        # den Abbruch nach. In beiden Faellen muss der Lauf als abgebrochen
        # erkennbar sein - nie als regulaeres Ergebnis.
        $alsAbbruchErkennbar = ($st.cancelled -eq $true) -or ($st.overall -eq 'CANCELLED') -or
            (@($st.log | Where-Object { $_.text -like '*abgebrochen*' }).Count -gt 0)
        Assert-True $alsAbbruchErkennbar ('Lauf sieht aus wie ein regulaeres Ergebnis: overall=' + $st.overall)
        Assert-True ($st.overall -ne 'HEALTHY' -and $st.overall -ne 'REPAIRED') ('abgebrochener Lauf meldet ' + $st.overall)
    }

    Test-Case 'Analyse ueber die API liefert Bewertung und Begruendung' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $start = Invoke-RestMethod -Uri ($base + '/api/disk/analyze') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"diskNumber":1,"samples":8,"demo":true}'
        $fertig = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $start.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $fertig = $true; break }
        }
        Assert-True $fertig 'Analyse wurde nicht fertig'
        Assert-True $j.ok ('Analyse fehlgeschlagen: ' + $j.detail)
        Assert-Equal 3 $j.analysis.verdict.level 'kranke Platte nicht als akut erkannt'
        Assert-True (@($j.analysis.verdict.reasons).Count -ge 4) 'zu wenige Begruendungen'
        Assert-True ($j.analysis.smart.pendingSectors -gt 0) 'SMART-Werte fehlen in der Antwort'
    }

    Test-Case 'Dateisuche und Reparatur laufen als verkettete Auftraege ueber die API' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $suche = Invoke-RestMethod -Uri ($base + '/api/files/scan') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"path":"C:\\Users","demo":true}'
        $fertig = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $suche.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $fertig = $true; break }
        }
        Assert-True $fertig 'Suche wurde nicht fertig'
        Assert-True (@($j.scan.findings).Count -ge 3) 'zu wenige Befunde'

        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Suche haengt'
        $rep = Invoke-RestMethod -Uri ($base + '/api/files/repair') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body ('{"scanJobId":"' + $suche.jobId + '","repairStrategy":"Auto","demo":true}')
        $fertig = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            $j2 = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $rep.jobId) -TimeoutSec 10
            if ($j2.status -eq 'done') { $fertig = $true; break }
        }
        Assert-True $fertig 'Reparatur wurde nicht fertig'
        Assert-True ($j2.repair.repaired -ge 3) ('zu wenige repariert: ' + $j2.repair.repaired)
    }

    Test-Case 'Reparatur ohne vorherige Suche wird sauber abgelehnt' {
        Assert-True (Wait-DiskJobFree -BaseUrl $base) 'Vorheriger Vorgang haengt'
        $rep = Invoke-RestMethod -Uri ($base + '/api/files/repair') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"scanJobId":"gibtsnicht","repairStrategy":"Auto","demo":true}'
        $fertig = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            $j = Invoke-RestMethod -Uri ($base + '/api/disk/job/' + $rep.jobId) -TimeoutSec 10
            if ($j.status -eq 'done') { $fertig = $true; break }
        }
        Assert-True $fertig 'Auftrag haengt'
        Assert-True (-not $j.ok) 'Reparatur ohne Befunde meldete Erfolg'
        Assert-True ($j.detail -like '*zuerst suchen*') 'Hinweis fehlt'
    }

    Test-Case 'Aktualisierungspruefung erkennt neuere und aeltere Pakete' {
        $ordner = Join-Path $WorkDir 'pakete'
        New-Item -ItemType Directory -Path $ordner -Force | Out-Null
        $leer = Invoke-RestMethod -Uri ($base + '/api/update/check?source=' + [uri]::EscapeDataString($ordner)) -TimeoutSec 10
        Assert-True (-not $leer.available) 'leerer Ordner meldet eine Aktualisierung'
        Assert-True ($leer.note -like '*kein Paket*') 'Hinweis fehlt'

        Set-Content -LiteralPath (Join-Path $ordner 'RepairCenter-0.9.0.zip') -Value 'alt'
        $alt = Invoke-RestMethod -Uri ($base + '/api/update/check?source=' + [uri]::EscapeDataString($ordner)) -TimeoutSec 10
        Assert-True (-not $alt.available) 'aelteres Paket wurde als Aktualisierung gemeldet'

        Set-Content -LiteralPath (Join-Path $ordner 'RepairCenter-9.9.9.zip') -Value 'neu'
        $neu = Invoke-RestMethod -Uri ($base + '/api/update/check?source=' + [uri]::EscapeDataString($ordner)) -TimeoutSec 10
        Assert-True $neu.available 'neueres Paket wurde nicht erkannt'
        Assert-Equal '9.9.9' $neu.newestVersion 'falsche Version gemeldet'
        Assert-True ($neu.note -like '*Install.cmd*') 'Hinweis zum Einspielen fehlt'
    }

    Test-Case 'Bereitschaftspruefung meldet, was dieser Rechner hergibt' {
        $r = Invoke-RestMethod -Uri ($base + '/api/readiness') -TimeoutSec 15
        Assert-True ($null -ne $r.checks) 'keine Pruefpunkte'
        Assert-True (@($r.checks).Count -ge 1) 'Pruefliste ist leer'
        # Unter Linux muss klar gesagt werden, dass nur Demodaten moeglich sind
        if (-not $r.windows) {
            Assert-True (-not $r.ready) 'ohne Windows darf nicht "bereit" gemeldet werden'
            Assert-True (@($r.checks | Where-Object { $_.status -eq 'FAILED' }).Count -ge 1) 'fehlendes Windows nicht als Mangel gemeldet'
        }
    }

    Test-Case 'Bereitschaft laesst sich schrittweise abrufen' {
        $liste = Invoke-RestMethod -Uri ($base + '/api/readiness?step=list') -TimeoutSec 10
        $schritte = @($liste.steps)
        Assert-True ($schritte.Count -ge 8) ('zu wenige Pruefpunkte: ' + $schritte.Count)
        foreach ($name in @('os', 'admin', 'mode', 'smart', 'tools')) {
            Assert-True ($schritte -contains $name) ('Pruefpunkt fehlt: ' + $name)
        }
        # Jeder Punkt muss einzeln und schnell antworten - darauf baut die
        # fortlaufende Anzeige in der Oberflaeche auf.
        foreach ($name in $schritte) {
            $uhr = [System.Diagnostics.Stopwatch]::StartNew()
            $p = Invoke-RestMethod -Uri ($base + '/api/readiness?step=' + $name) -TimeoutSec 30
            $uhr.Stop()
            Assert-Equal $name $p.step ('falscher Punkt geliefert fuer ' + $name)
            Assert-True ([bool]$p.name) ('Pruefpunkt ohne Bezeichnung: ' + $name)
            Assert-True (@('PASS', 'WARNING', 'FAILED') -contains $p.status) ('unbekannter Zustand bei ' + $name)
            Assert-True ([bool]$p.detail) ('Pruefpunkt ohne Erklaerung: ' + $name)
        }
        $unbekannt = Invoke-RestMethod -Uri ($base + '/api/readiness?step=gibtsnicht') -TimeoutSec 10
        Assert-True ([bool]$unbekannt.error) 'unbekannter Pruefpunkt wird nicht gemeldet'
    }

    Test-Case 'Die Betriebsart ist ueber die Schnittstelle eindeutig ablesbar' {
        $cfg = Invoke-RestMethod -Uri ($base + '/api/config') -TimeoutSec 10
        Assert-True ($cfg.PSObject.Properties.Name -contains 'demo') 'Betriebsart fehlt in der Antwort'
        Assert-True ($cfg.demo -is [bool]) 'Betriebsart ist kein Wahrheitswert'
        $mode = Invoke-RestMethod -Uri ($base + '/api/readiness?step=mode') -TimeoutSec 10
        Assert-True ($mode.detail -like '*Demomodus*' -or $mode.detail -like '*Echtbetrieb*') `
            ('Betriebsart nicht im Klartext: ' + $mode.detail)
    }

    Test-Case 'Einspielen ist im Demomodus abgeschaltet' {
        $r = Invoke-RestMethod -Uri ($base + '/api/update/apply') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' -Body '{}'
        Assert-True (-not $r.ok) 'Einspielen lief im Demomodus an'
        Assert-True ($r.reason -like '*Demomodus*' -or $r.reason -like '*Windows*') ('unerwartete Begruendung: ' + $r.reason)
    }

    Test-Case 'Pfadausbruch wird abgewiesen' {
        $code = 0
        try { $code = (Invoke-WebRequest -Uri ($base + '/../src/RepairCenter.Server.ps1') -TimeoutSec 10 -UseBasicParsing).StatusCode }
        catch { $code = 404 }
        Assert-True ($code -ne 200) 'Datei ausserhalb von web/ wurde ausgeliefert'
    }
    Test-Case 'Ein frisch gestarteter Lauf ist sofort abfragbar (kein 404-Fenster)' {
        $start = Invoke-RestMethod -Uri ($base + '/api/run') -Method Post -TimeoutSec 15 `
            -Headers $script:ApiHeaders -ContentType 'application/json' `
            -Body '{"mode":"Quick","optimize":"None","demo":true}'
        Assert-True ([bool]$start.runId) 'keine Lauf-Kennung'
        # Ohne Wartezeit abfragen - genau hier trat unter Last der 404 auf.
        $st = Invoke-RestMethod -Uri ($base + '/api/run/' + $start.runId) -TimeoutSec 10
        Assert-Equal $start.runId $st.runId 'falscher Lauf geliefert'
        Assert-Equal 'running' $st.status 'Zustand muesste "running" sein'
        Assert-True ($st.log.Count -ge 1) 'kein erster Protokolleintrag'
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 1
            $st = Invoke-RestMethod -Uri ($base + '/api/run/' + $start.runId) -TimeoutSec 10
            if ($st.status -eq 'done') { break }
        }
        Assert-Equal 'done' $st.status 'Lauf wurde nicht fertig'
    }

    Test-Case 'Lauf ueber die API starten, verfolgen und abschliessen' {
        $body = '{"mode":"Quick","optimize":"Safe","demo":true}'
        $start = Invoke-RestMethod -Uri ($base + '/api/run') -Method Post -Body $body -ContentType 'application/json' -Headers $script:ApiHeaders -TimeoutSec 15
        Assert-True ([bool]$start.runId) 'keine Lauf-ID erhalten'
        $done = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Seconds 2
            $st = Invoke-RestMethod -Uri ($base + '/api/run/' + $start.runId) -TimeoutSec 10
            if ($st.status -eq 'done') { $done = $true; break }
        }
        Assert-True $done 'Lauf wurde nicht fertig'
        Assert-True (@($st.steps).Count -ge 4) 'zu wenige Schritte'
        Assert-True ($st.progress -eq 100) 'Fortschritt nicht 100 %'
        $report = Invoke-WebRequest -Uri ($base + '/api/report/' + $start.runId) -TimeoutSec 10 -UseBasicParsing
        Assert-Equal 200 $report.StatusCode 'Bericht nicht abrufbar'
        $history = Invoke-RestMethod -Uri ($base + '/api/runs') -TimeoutSec 10
        Assert-True (@($history).Count -ge 1) 'Verlauf leer'
        foreach ($fmt in @('json', 'tools', 'transcript')) {
            $f = Invoke-WebRequest -Uri ($base + '/api/report/' + $start.runId + '?format=' + $fmt) -TimeoutSec 10 -UseBasicParsing
            Assert-Equal 200 $f.StatusCode ('Format nicht abrufbar: ' + $fmt)
        }
        # CBS-Auszug entsteht nur, wenn es Befunde gab - 404 ist hier zulaessig
        $cbsCode = 0
        try { $cbsCode = (Invoke-WebRequest -Uri ($base + '/api/report/' + $start.runId + '?format=cbs') -TimeoutSec 10 -UseBasicParsing).StatusCode }
        catch { $cbsCode = 404 }
        Assert-True ($cbsCode -eq 200 -or $cbsCode -eq 404) 'CBS-Endpunkt antwortet unerwartet'
    }
}
finally {
    if ($server -and -not $server.HasExited) {
        try { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue } catch { Write-Verbose 'Server bereits beendet.' }
    }
}

Write-Host ''
Write-Host '  Kommandozeile' -ForegroundColor Cyan

Test-Case 'Kommandozeile laeuft durch und liefert Bericht samt Exitcode' {
    $cliDir = Join-Path $WorkDir 'cli'
    $cli = Join-Path $SrcDir 'RepairCenter.Cli.ps1'
    # $args waere die automatische Variable von PowerShell - eigener Name.
    $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
        '-Mode', 'Quick', '-Optimize', 'None', '-Demo', '-DemoScenario', 'Repaired', '-LogRoot', $cliDir)
    $proc = Start-Process -FilePath $psExe -ArgumentList $cliArgs -PassThru -Wait
    # REPARIERT ergibt Exitcode 1 - genau dafuer ist er da (Taskplaner)
    Assert-Equal 1 $proc.ExitCode ('unerwarteter Exitcode: ' + $proc.ExitCode)

    $runDir = Get-ChildItem -LiteralPath (Join-Path $cliDir 'runs') -Directory | Select-Object -First 1
    Assert-True ($null -ne $runDir) 'kein Laufverzeichnis angelegt'
    foreach ($f in @('report.txt', 'state.json', 'tools.log')) {
        Assert-True (Test-Path (Join-Path $runDir.FullName $f)) ('Datei fehlt: ' + $f)
    }
    $json = Get-Content -LiteralPath (Join-Path $runDir.FullName 'state.json') -Raw | ConvertFrom-Json
    Assert-Equal 'REPAIRED' $json.overall 'falscher Gesamtstatus'
    Assert-Equal 'Quick' $json.mode 'falscher Modus'
}

Test-Case 'Kommandozeile im Diagnosemodus aendert nichts und meldet sauber' {
    $cliDir = Join-Path $WorkDir 'cli2'
    $cli = Join-Path $SrcDir 'RepairCenter.Cli.ps1'
    $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli,
        '-Mode', 'Diagnose', '-Demo', '-DemoScenario', 'Healthy', '-LogRoot', $cliDir)
    $proc = Start-Process -FilePath $psExe -ArgumentList $cliArgs -PassThru -Wait
    Assert-Equal 0 $proc.ExitCode ('HEALTHY muesste Exitcode 0 ergeben, war: ' + $proc.ExitCode)
    $runDir = Get-ChildItem -LiteralPath (Join-Path $cliDir 'runs') -Directory | Select-Object -First 1
    $json = Get-Content -LiteralPath (Join-Path $runDir.FullName 'state.json') -Raw | ConvertFrom-Json
    Assert-Equal 'None' $json.optimize 'Diagnose muss die Wartung abschalten'
}

Write-Host ''
Write-Host '  Projektregeln' -ForegroundColor Cyan

Test-Case 'Versionsnummer ist im ganzen Projekt gleich (Regel: Fehlerbehebung erhoeht die Version)' {
    $out = & (Join-Path (Join-Path $Root 'tools') 'Update-Version.ps1') -Check 2>&1
    Assert-True ($LASTEXITCODE -eq 0) ('Versionsangaben laufen auseinander: ' + ($out -join ' '))
}

Test-Case 'Statische Pruefung laeuft wirklich und meldet keine Befunde' {
    $analyzer = Join-Path (Join-Path $Root 'tools') 'Invoke-Analyzer.ps1'
    $out = & $analyzer 2>&1
    if ($LASTEXITCODE -eq 2) {
        Write-Host '         (uebersprungen: PSScriptAnalyzer ist nicht installiert)' -ForegroundColor DarkGray
        return
    }
    Assert-True ($LASTEXITCODE -eq 0) ('PSScriptAnalyzer meldet Befunde: ' + (($out | Select-Object -Last 8) -join ' '))
}

Test-Case 'CHANGELOG fuehrt die aktuelle Version' {
    $pkg = Get-Content -LiteralPath (Join-Path $Root 'package.json') -Raw
    $version = [regex]::Match($pkg, '"version": "(\d+\.\d+\.\d+)"').Groups[1].Value
    $cl = Get-Content -LiteralPath (Join-Path $Root 'CHANGELOG.md') -Raw
    Assert-True ($cl -like ('*[' + $version + ']*')) ('CHANGELOG kennt Version ' + $version + ' nicht')
}

Write-Host ''
Write-Host '  Kompatibilitaet' -ForegroundColor Cyan
Test-Case 'Quelltext ist zu Windows PowerShell 5.1 kompatibel' {
    $out = & (Join-Path $TestDir 'Test-Compat51.ps1') -Path $Root 2>&1
    Assert-True ($LASTEXITCODE -eq 0) ('Kompatibilitaetspruefung meldet Befunde: ' + ($out -join ' '))
}

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail -gt 0) {
    # Namen am Ende wiederholen - sonst gehen sie in langen Laeufen unter,
    # und sporadische Fehler lassen sich nicht zuordnen.
    Write-Host '  Fehlgeschlagen:' -ForegroundColor Red
    foreach ($f in $script:Failed) {
        Write-Host ('    - {0}' -f $f.Name) -ForegroundColor Red
        Write-Host ('      {0}' -f $f.Message) -ForegroundColor DarkRed
    }
    Write-Host ''
}
Write-Host ('  Ergebnis: {0} bestanden, {1} fehlgeschlagen' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
if ($script:Fail -gt 0) { exit 1 }
exit 0
