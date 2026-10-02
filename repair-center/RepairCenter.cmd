@echo off
rem =========================================================================
rem  RepairCenter - Start
rem  Version: 1.5.1
rem  Diese Datei macht absichtlich fast nichts: sie ruft nur den Starter in
rem  PowerShell auf. Alle Logik liegt dort - in cmd.exe verschwinden
rem  Fehlermeldungen zu leicht und das Fenster schliesst sich, bevor man
rem  lesen kann, was los war.
rem  MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
rem =========================================================================
setlocal
cd /d "%~dp0" 2>nul

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
set "STARTER=%~dp0tools\Start-RepairCenter.ps1"

if not exist "%STARTER%" goto :fehltStarter

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%STARTER%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :fehler
endlocal
exit /b 0

:fehltStarter
echo.
echo   FEHLER: tools\Start-RepairCenter.ps1 wurde nicht gefunden.
echo   Erwartet in: %~dp0tools\
echo.
echo   Bitte das ZIP-Archiv vollstaendig entpacken - mit allen Unterordnern.
echo.
pause
endlocal
exit /b 2

:fehler
echo.
echo   RepairCenter wurde mit Fehlercode %RC% beendet.
echo   Die Meldungen darueber nennen den Grund.
echo.
pause
endlocal
exit /b %RC%
