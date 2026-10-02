@echo off
rem =========================================================================
rem  Repair - Starter
rem  Version: 3.0.1 | Plattform: Windows 10/11
rem  Umgeht die Ausfuehrungsrichtlinie fuer genau diesen Start und uebergibt
rem  alle Parameter an Repair.ps1. Die Rechteerhoehung (UAC) macht das
rem  Skript anschliessend selbst.
rem
rem  Beispiele:
rem    Repair-Starten.cmd
rem    Repair-Starten.cmd -Mode Diagnose
rem    Repair-Starten.cmd -Mode Full -Optimize Standard
rem
rem  MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
rem =========================================================================

setlocal
rem Arbeitsverzeichnis auf den Skriptordner setzen (schuetzt vor Fehlern,
rem wenn das Terminal auf einem getrennten Netzlaufwerk steht -> Systemfehler 55)
cd /d "%~dp0" 2>nul

set "PS1=%~dp0Repair.ps1"

if not exist "%PS1%" (
    echo.
    echo   FEHLER: Repair.ps1 wurde nicht gefunden.
    echo   Erwartet wird sie im selben Ordner wie diese Datei:
    echo   %~dp0
    echo.
    pause
    exit /b 2
)

rem PowerShell ermitteln ^(Standardpfad, unabhaengig von PATH^)
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

echo.
echo   Starte Repair.ps1 ...
echo.

rem 1) Internet-Markierung der heruntergeladenen Datei entfernen
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%PS1%' -ErrorAction SilentlyContinue"

rem 2) Skript starten - die UAC-Abfrage loest Repair.ps1 selbst aus
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" echo   Ergebnis: HEALTHY - System ist integer.
if "%RC%"=="1" echo   Ergebnis: REPAIRED - bitte Windows neu starten.
if "%RC%"=="2" echo   Ergebnis: WARNING - Hinweise im Report pruefen.
if "%RC%"=="3" echo   Ergebnis: FAILED - Report pruefen, danach -Mode Full.
if "%RC%"=="4" echo   Ergebnis: keine Administratorrechte.
if "%RC%"=="5" echo   Ergebnis: UAC-Abfrage abgebrochen.
if "%RC%"=="1" goto ende
if "%RC%" GEQ "4" (
    echo.
    echo   Hinweis: Greift die Ausfuehrungsrichtlinie per Gruppenrichtlinie
    echo   ^(AllSigned^), hilft "Bypass" nicht - dann muss Repair.ps1 signiert
    echo   werden. Pruefen mit:  Get-ExecutionPolicy -List
)

:ende
echo.
echo   Logs: C:\RepairLogs\
echo.
pause
exit /b %RC%
