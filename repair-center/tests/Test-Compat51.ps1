#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - Kompatibilitaetspruefung fuer Windows PowerShell 5.1
 Findet Konstrukte, die PowerShell 7 akzeptiert, Windows PowerShell 5.1
 aber ablehnt. Ohne Fremdmodule lauffaehig.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
#>
[CmdletBinding()]
param([string]$Path)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

$files = Get-ChildItem -LiteralPath $Path -Recurse -Include '*.ps1', '*.psm1' -File |
    Where-Object { $_.FullName -notmatch '[\\/](dist|\.git)[\\/]' }

$problems = New-Object System.Collections.ArrayList

function Add-Problem {
    param([string]$File, [int]$Line, [string]$Rule, [string]$Text)
    [void]$problems.Add([pscustomobject]@{ File = (Split-Path $File -Leaf); Line = $Line; Rule = $Rule; Text = $Text })
}

foreach ($f in $files) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    foreach ($e in @($errors)) {
        Add-Problem -File $f.FullName -Line $e.Extent.StartLineNumber -Rule 'Parser' -Text $e.Message
    }
    if (-not $ast) { continue }

    # --- Regel 1: Ablaufsteuerung, die einen finally-Block verlassen wuerde
    foreach ($try in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
        if (-not $try.Finally) { continue }
        $ctrl = $try.Finally.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.BreakStatementAst] -or
                $n -is [System.Management.Automation.Language.ContinueStatementAst] -or
                $n -is [System.Management.Automation.Language.ReturnStatementAst]
            }, $true)
        foreach ($c in $ctrl) {
            $parent = $c.Parent
            $allowed = $false
            while ($parent -and $parent -ne $try.Finally) {
                if ($parent -is [System.Management.Automation.Language.LoopStatementAst] -or
                    $parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                    $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $allowed = $true; break }
                $parent = $parent.Parent
            }
            if (-not $allowed) {
                Add-Problem -File $f.FullName -Line $c.Extent.StartLineNumber -Rule 'ControlLeavingFinally' `
                    -Text ("'{0}' im finally-Block - Windows PowerShell 5.1 bricht mit ParserError ab." -f $c.Extent.Text.Trim())
            }
        }
    }

    # --- Regel 2: Syntax, die es erst ab PowerShell 7 gibt
    # Token-basiert, damit Zeichenketten (z. B. der NT-Pfad "\??\C:\...")
    # und Kommentare keine Fehlalarme ausloesen.
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$null)
    foreach ($tok in @($tokens)) {
        $kind = [string]$tok.Kind
        if ($kind -eq 'Comment' -or $kind -like 'String*' -or $kind -eq 'HereStringLiteral' -or $kind -eq 'HereStringExpandable') { continue }
        $txt = [string]$tok.Text
        if ($txt -eq '??' -or $txt -eq '?.' -or $txt -eq '??=') {
            Add-Problem -File $f.FullName -Line $tok.Extent.StartLineNumber -Rule 'NullCoalescing' `
                -Text 'Null-Coalescing (?? / ?. / ??=) gibt es erst ab PowerShell 7.'
        }
        elseif ($txt -eq '&&' -or $txt -eq '||') {
            Add-Problem -File $f.FullName -Line $tok.Extent.StartLineNumber -Rule 'PipelineChain' `
                -Text 'Pipeline-Ketten (&& / ||) gibt es erst ab PowerShell 7.'
        }
        elseif ($txt -eq '$PSStyle') {
            Add-Problem -File $f.FullName -Line $tok.Extent.StartLineNumber -Rule 'PSStyle' `
                -Text '$PSStyle gibt es erst ab PowerShell 7.2.'
        }
        elseif ($txt -eq '-Parallel' -or $txt -eq '-AsJob') {
            Add-Problem -File $f.FullName -Line $tok.Extent.StartLineNumber -Rule 'ForEachParallel' `
                -Text ('{0} bei ForEach-Object gibt es erst ab PowerShell 7.' -f $txt)
        }
        elseif ($kind -eq 'Ternary' -or $txt -eq '?:') {
            Add-Problem -File $f.FullName -Line $tok.Extent.StartLineNumber -Rule 'Ternary' `
                -Text 'Ternaeroperator gibt es erst ab PowerShell 7.'
        }
    }
}

Write-Host ''
Write-Host ('  Geprueft: {0} Dateien' -f @($files).Count)
if ($problems.Count -eq 0) {
    Write-Host '  Ergebnis: kompatibel zu Windows PowerShell 5.1' -ForegroundColor Green
    exit 0
}
Write-Host ('  Ergebnis: {0} Befund(e)' -f $problems.Count) -ForegroundColor Red
$problems | Format-Table File, Line, Rule, Text -AutoSize -Wrap | Out-String -Width 160 | Write-Host
exit 1
