#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Versionsnummer setzen und pruefen
 Version: 1.5.1 | MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================

.SYNOPSIS
    Setzt die Versionsnummer an allen Stellen des Projekts - oder prueft,
    ob sie ueberall uebereinstimmt.

.DESCRIPTION
    Projektregel: JEDE Fehlerbehebung erhoeht die Versionsnummer.
    Weil eine Version an einem Dutzend Stellen steht, gibt es dieses
    Werkzeug - und den Test "Versionsnummer ist ueberall gleich", der
    einen Lauf scheitern laesst, sobald etwas auseinanderlaeuft.

    Zaehlweise (semantische Versionierung):
      1.2.3 -> 1.2.4   Fehlerbehebung, Haertung, Dokumentationskorrektur
      1.2.3 -> 1.3.0   neue Funktion, abwaertskompatibel
      1.2.3 -> 2.0.0   Bruch mit bisherigem Verhalten

.EXAMPLE
    .\tools\Update-Version.ps1 -Check
    Prueft nur und meldet Abweichungen (Exitcode 1, wenn etwas nicht passt).

.EXAMPLE
    .\tools\Update-Version.ps1 -Version 1.2.2 -Reason "Absturz beim Formatieren behoben"
    Setzt die Version ueberall und legt einen Eintrag im CHANGELOG an.

.EXAMPLE
    .\tools\Update-Version.ps1 -BumpPatch -Reason "Rechenfehler in der Dauerschaetzung"
    Erhoeht die letzte Stelle automatisch.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(ParameterSetName = 'Bump', Mandatory = $true)][switch]$BumpPatch,
    [Parameter(ParameterSetName = 'BumpMinor', Mandatory = $true)][switch]$BumpMinor,

    [string]$Reason = '',

    [Parameter(ParameterSetName = 'Check')][switch]$Check
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Alle Stellen, an denen eine Versionsnummer steht.
# Muster mit einer Gruppe: davor und danach bleibt alles unveraendert.
$Targets = @(
    @{ File = 'src/modules/RepairEngine.psm1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| Plattform", "version          = '(\d+\.\d+\.\d+)'") }
    @{ File = 'src/modules/DiskManager.psm1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| Plattform") }
    @{ File = 'src/modules/DiskAnalysis.psm1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| Plattform") }
    @{ File = 'src/modules/FileIntegrity.psm1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| Plattform") }
    @{ File = 'src/RepairCenter.Server.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| Plattform", "version   = '(\d+\.\d+\.\d+)'", "version = '(\d+\.\d+\.\d+)'; demo", "   RepairCenter (\d+\.\d+\.\d+)", "\$aktuell = '(\d+\.\d+\.\d+)'") }
    @{ File = 'src/RepairCenter.Cli.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| Plattform") }
    @{ File = 'src/RepairCenter.Runner.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+)") }
    @{ File = 'src/RepairCenter.DiskJob.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+)") }
    @{ File = 'tools/Update-Version.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| MIT") }
    @{ File = 'tools/Invoke-Analyzer.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| MIT") }
    @{ File = 'tools/Apply-Update.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| MIT") }
    @{ File = 'tools/Start-RepairCenter.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| MIT") }
    @{ File = 'installer/Install.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| MIT") }
    @{ File = 'installer/Uninstall.ps1'; Patterns = @(" Version: (\d+\.\d+\.\d+) \| MIT") }
    @{ File = 'installer/Uninstall.cmd'; Patterns = @("rem  Version: (\d+\.\d+\.\d+)") }
    @{ File = 'package.json'; Patterns = @('"version": "(\d+\.\d+\.\d+)"') }
    @{ File = 'installer/RepairCenter.iss'; Patterns = @('#define AppVersion   "(\d+\.\d+\.\d+)"', 'RepairCenter-Setup-(\d+\.\d+\.\d+)\.exe') }
    @{ File = 'installer/Install.cmd'; Patterns = @("rem  Version: (\d+\.\d+\.\d+)") }
    @{ File = 'RepairCenter.cmd'; Patterns = @('rem  Version: (\d+\.\d+\.\d+)') }
    @{ File = 'web/index.html'; Patterns = @('<span class="muted">(\d+\.\d+\.\d+)</span>') }
    @{ File = 'README.md'; Patterns = @('Version-(\d+\.\d+\.\d+)-1473e6') }
    @{ File = 'README.en.md'; Patterns = @('Version-(\d+\.\d+\.\d+)-1473e6') }
    @{ File = 'tests/Test-RepairCenter.ps1'; Patterns = @("Assert-Equal '(\d+\.\d+\.\d+)' \`$r\.version") }
)

function Get-VersionOccurrence {
    $found = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        $path = Join-Path $Root $t.File
        if (-not (Test-Path -LiteralPath $path)) {
            [void]$found.Add([pscustomobject]@{ File = $t.File; Pattern = '(Datei fehlt)'; Version = $null })
            continue
        }
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($pattern in $t.Patterns) {
            $matches2 = [regex]::Matches($text, $pattern)
            if ($matches2.Count -eq 0) {
                [void]$found.Add([pscustomobject]@{ File = $t.File; Pattern = $pattern; Version = $null })
                continue
            }
            foreach ($m in $matches2) {
                [void]$found.Add([pscustomobject]@{ File = $t.File; Pattern = $pattern; Version = $m.Groups[1].Value })
            }
        }
    }
    return $found
}

function Get-CurrentVersion {
    $path = Join-Path $Root 'package.json'
    $m = [regex]::Match((Get-Content -LiteralPath $path -Raw), '"version": "(\d+\.\d+\.\d+)"')
    if (-not $m.Success) { throw 'Version in package.json nicht gefunden.' }
    return $m.Groups[1].Value
}

# ----------------------------- Pruefen -----------------------------
if ($PSCmdlet.ParameterSetName -eq 'Check') {
    $all = Get-VersionOccurrence
    $versions = @($all | Where-Object { $_.Version } | Select-Object -ExpandProperty Version | Sort-Object -Unique)
    $missing = @($all | Where-Object { -not $_.Version })

    Write-Host ''
    Write-Host ('  Gefundene Stellen : {0}' -f @($all).Count)
    Write-Host ('  Versionen         : {0}' -f ($versions -join ', '))

    if ($missing.Count -gt 0) {
        Write-Host '  Nicht gefunden:' -ForegroundColor Red
        foreach ($m in $missing) { Write-Host ('    {0}  ->  {1}' -f $m.File, $m.Pattern) -ForegroundColor Red }
    }
    if ($versions.Count -eq 1 -and $missing.Count -eq 0) {
        Write-Host ('  Ergebnis          : einheitlich {0}' -f $versions[0]) -ForegroundColor Green
        exit 0
    }
    Write-Host '  Ergebnis          : ABWEICHUNG' -ForegroundColor Red
    foreach ($v in $versions) {
        $files = @($all | Where-Object { $_.Version -eq $v } | Select-Object -ExpandProperty File -Unique)
        Write-Host ('    {0}: {1}' -f $v, ($files -join ', ')) -ForegroundColor Yellow
    }
    exit 1
}

# ----------------------------- Setzen ------------------------------
$current = Get-CurrentVersion
if ($PSCmdlet.ParameterSetName -eq 'Bump' -or $PSCmdlet.ParameterSetName -eq 'BumpMinor') {
    $parts = $current.Split('.')
    if ($BumpMinor) { $Version = ('{0}.{1}.0' -f $parts[0], ([int]$parts[1] + 1)) }
    else { $Version = ('{0}.{1}.{2}' -f $parts[0], $parts[1], ([int]$parts[2] + 1)) }
}

Write-Host ''
Write-Host ('  {0}  ->  {1}' -f $current, $Version) -ForegroundColor Cyan

$changed = 0
foreach ($t in $Targets) {
    $path = Join-Path $Root $t.File
    if (-not (Test-Path -LiteralPath $path)) { Write-Warning ('Datei fehlt: {0}' -f $t.File); continue }
    $text = Get-Content -LiteralPath $path -Raw
    $before = $text
    foreach ($pattern in $t.Patterns) {
        $text = [regex]::Replace($text, $pattern, {
                param($m)
                $whole = $m.Value
                $old = $m.Groups[1].Value
                $idx = $whole.LastIndexOf($old)
                return $whole.Substring(0, $idx) + $Version + $whole.Substring($idx + $old.Length)
            })
    }
    if ($text -ne $before) {
        if ($PSCmdlet.ShouldProcess($t.File, 'Version setzen')) {
            Set-Content -LiteralPath $path -Value $text -Encoding UTF8 -NoNewline
            $changed++
            Write-Host ('    aktualisiert: {0}' -f $t.File)
        }
    }
}

# CHANGELOG-Eintrag anlegen, wenn ein Grund genannt wurde
if ($Reason) {
    $clPath = Join-Path $Root 'CHANGELOG.md'
    $cl = Get-Content -LiteralPath $clPath -Raw
    $header = ('## [{0}] - {1}' -f $Version, (Get-Date -Format 'yyyy-MM-dd'))
    if ($cl -notmatch [regex]::Escape($header)) {
        $entry = $header + "`r`n`r`n### Behoben`r`n- " + $Reason + "`r`n`r`n"
        $anchor = '[Semantic Versioning](https://semver.org/lang/de/).'
        $cl = $cl.Replace($anchor, $anchor + "`r`n`r`n" + $entry.TrimEnd())
        if ($PSCmdlet.ShouldProcess('CHANGELOG.md', 'Eintrag anlegen')) {
            Set-Content -LiteralPath $clPath -Value $cl -Encoding UTF8 -NoNewline
            Write-Host '    Eintrag im CHANGELOG angelegt'
        }
    }
}

Write-Host ('  {0} Dateien geaendert.' -f $changed) -ForegroundColor Green
Write-Host '  Zur Kontrolle:  .\tools\Update-Version.ps1 -Check'
Write-Host ''
exit 0
