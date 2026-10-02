@echo off
rem =========================================================================
rem  RepairCenter - Deinstallation starten
rem  Version: 1.5.1
rem  MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
rem =========================================================================
setlocal
cd /d "%~dp0" 2>nul

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
set "SKRIPT=%~dp0Uninstall.ps1"

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
endlocal
exit /b 0

:fehltSkript
echo.
echo   FEHLER: Uninstall.ps1 wurde nicht gefunden.
echo.
pause
endlocal
exit /b 2

:fehler
echo.
echo   Die Deinstallation wurde mit Fehlercode %RC% beendet.
echo.
pause
endlocal
exit /b %RC%
