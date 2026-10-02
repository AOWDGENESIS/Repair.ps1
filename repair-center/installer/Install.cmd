@echo off
rem =========================================================================
rem  RepairCenter - Installation starten
rem  Version: 1.5.1
rem  Holt Administratorrechte und uebergibt an Install.ps1. Bei jedem
rem  Abbruch bleibt das Fenster offen - genau das fehlte vorher.
rem  MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
rem =========================================================================
setlocal
cd /d "%~dp0" 2>nul

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
set "SKRIPT=%~dp0Install.ps1"

if not exist "%SKRIPT%" goto :fehltSkript

net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" goto :erhoehen

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%SKRIPT%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :fehler
endlocal
exit /b 0

:erhoehen
echo.
echo   Administratorrechte erforderlich - es erscheint die Nachfrage von Windows.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%PSEXE%' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','%SKRIPT%') -Verb RunAs"
if not "%ERRORLEVEL%"=="0" goto :keineRechte
endlocal
exit /b 0

:keineRechte
echo.
echo   Die Rechteerhoehung ist fehlgeschlagen oder wurde abgelehnt.
echo   Alternative: Rechtsklick auf Install.cmd, "Als Administrator ausfuehren".
echo.
pause
endlocal
exit /b 3

:fehltSkript
echo.
echo   FEHLER: Install.ps1 wurde nicht gefunden (erwartet in %~dp0).
echo   Bitte das ZIP-Archiv vollstaendig entpacken.
echo.
pause
endlocal
exit /b 2

:fehler
echo.
echo   Die Installation wurde mit Fehlercode %RC% beendet.
echo   Die Meldungen darueber nennen den Grund.
echo.
pause
endlocal
exit /b %RC%
