; =========================================================================
;  RepairCenter - Inno-Setup-Skript
;  Erzeugt RepairCenter-Setup-1.5.1.exe (klassisches Windows-Setup mit
;  Assistent, Startmenue-Eintrag, Deinstallation, mehrsprachig DE/EN).
;
;  Bauen:  iscc installer\RepairCenter.iss
;          (Inno Setup 6: https://jrsoftware.org/isdl.php - offline nutzbar)
;  Alternative ohne Inno Setup: installer\Install.cmd
;
;  MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
; =========================================================================

#define AppName      "RepairCenter"
#define AppVersion   "1.5.1"
#define AppPublisher "AOWD GENESIS"
#define AppExe       "RepairCenter.cmd"

[Setup]
AppId={{8E3F1C42-7B5A-4D66-9C2E-RC10000000A1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE
UninstallDisplayIcon={sys}\shell32.dll,165
MinVersion=10.0

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
de.LaunchAfter=RepairCenter nach der Installation starten
en.LaunchAfter=Launch RepairCenter after installation
de.WeeklyTask=Woechentliche Wartung im Taskplaner einrichten (sonntags 03:00)
en.WeeklyTask=Create a weekly maintenance task (Sundays 3:00 am)
de.DesktopIcon=Desktopverknuepfung anlegen
en.DesktopIcon=Create a desktop shortcut

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "weeklytask";  Description: "{cm:WeeklyTask}";  Flags: unchecked

[Files]
Source: "..\src\*";   DestDir: "{app}\src";   Flags: ignoreversion recursesubdirs
; tools\ enthaelt den Starter - ohne ihn findet RepairCenter.cmd nichts.
; Genau das fehlte hier einmal und machte die Installation unbrauchbar.
Source: "..\tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs
Source: "..\web\*";   DestDir: "{app}\web";   Flags: ignoreversion recursesubdirs
Source: "..\docs\*";  DestDir: "{app}\docs";  Flags: ignoreversion recursesubdirs skipifsourcedoesntexist
Source: "..\RepairCenter.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.en.md";     DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md";     DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE";          DestDir: "{app}"; Flags: ignoreversion
Source: "Uninstall.cmd";       DestDir: "{app}\installer"; Flags: ignoreversion
Source: "Uninstall.ps1";       DestDir: "{app}\installer"; Flags: ignoreversion
Source: "Install.cmd";         DestDir: "{app}\installer"; Flags: ignoreversion
Source: "Install.ps1";         DestDir: "{app}\installer"; Flags: ignoreversion
Source: "..\package.json";     DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md";      DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}";                  Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 165
Name: "{group}\{#AppName} (Demomodus)"; Filename: "{app}\{#AppExe}"; Parameters: "-Demo"; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 22
Name: "{group}\{#AppName} (Diagnose)";       Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\src\RepairCenter.Cli.ps1"" -Mode Diagnose"; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 23
Name: "{autodesktop}\{#AppName}";            Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 165; Tasks: desktopicon

[Run]
Filename: "{sys}\schtasks.exe"; \
  Parameters: "/Create /TN ""RepairCenter\Woechentliche Wartung"" /SC WEEKLY /D SUN /ST 03:00 /RL HIGHEST /RU SYSTEM /F /TR ""\""{sys}\WindowsPowerShell\v1.0\powershell.exe\"" -NoProfile -ExecutionPolicy Bypass -File \""{app}\src\RepairCenter.Cli.ps1\"" -Mode Quick -Optimize Safe -NoElevate"""; \
  Flags: runhidden; Tasks: weeklytask
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchAfter}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""RepairCenter\Woechentliche Wartung"" /F"; Flags: runhidden; RunOnceId: "DelTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\web"
Type: filesandordirs; Name: "{app}\src"
