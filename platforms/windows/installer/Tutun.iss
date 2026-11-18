; Установщик Tutun для Windows в один файл (Inno Setup 6).
; Собирается скриптом installer\build-installer.ps1: он сначала делает dist\Tutun, потом этот файл.
; Ставит программу в C:\Program Files\Tutun (путь фиксированный: на него рассчитана установка службы),
; ярлык в «Пуск», запускает Tutun. Службу ставит сам Tutun кнопкой «Установить службу» — так она
; привязывается к пользователю, который будет ею пользоваться.

#ifndef AppVer
  #define AppVer "1.0.0"
#endif

[Setup]
AppId={{5C7E4B1A-6A2D-4F0E-9B3C-7475747501AA}
AppName=Tutun
AppVersion={#AppVer}
AppVerName=Tutun {#AppVer}
AppPublisher=Tutun
DefaultDirName={autopf}\Tutun
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=Tutun-Setup-{#AppVer}
SetupIconFile=..\src\Tutun.App\Assets\tutun.ico
UninstallDisplayIcon={app}\Tutun.exe
UninstallDisplayName=Tutun
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
AppMutex=Local\Tutun.App
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\Tutun\bin\*"; DestDir: "{app}\cores"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\dist\Tutun\*"; Excludes: "\bin\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Tutun"; Filename: "{app}\Tutun.exe"
Name: "{autodesktop}\Tutun"; Filename: "{app}\Tutun.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Tutun.exe"; Description: "{cm:LaunchProgram,Tutun}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/im Tutun.exe /f"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "{app}\Tutun.exe"; Parameters: "--uninstall-service"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveService"

[UninstallDelete]
; Папку службы создаёт сам Tutun, журнал и состояние — служба.
Type: filesandordirs; Name: "{app}\service"
Type: files; Name: "{app}\bin\*.bak"
Type: files; Name: "{app}\*.old"
Type: filesandordirs; Name: "{commonappdata}\Tutun"

