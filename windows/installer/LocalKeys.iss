; LocalKeys Windows installer (Inno Setup 6)
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef PublishDir
  #define PublishDir "..\publish"
#endif

[Setup]
AppId={{8F3C2A1E-6B1D-4C55-9C2E-4A7E1F0B9D21}
AppName=LocalKeys
AppVersion={#AppVersion}
AppVerName=LocalKeys {#AppVersion}
AppPublisher=LocalKeys
DefaultDirName={autopf}\LocalKeys
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=admin
OutputDir=..\dist
OutputBaseFilename=LocalKeys-Setup-{#AppVersion}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\LocalKeys\Assets\app.ico
UninstallDisplayIcon={app}\LocalKeys.exe
UninstallDisplayName=LocalKeys
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0.17763
CloseApplications=no

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "uk"; MessagesFile: "compiler:Languages\Ukrainian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
ru.LaunchApp=Запустить LocalKeys
uk.LaunchApp=Запустити LocalKeys
en.LaunchApp=Launch LocalKeys
ru.Configuring=Настройка автозапуска и брандмауэра...
uk.Configuring=Налаштування автозапуску та брандмауера...
en.Configuring=Configuring autostart and firewall...

[Files]
Source: "{#PublishDir}\LocalKeys.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\LocalKeys"; Filename: "{app}\LocalKeys.exe"

[Run]
Filename: "{app}\LocalKeys.exe"; Parameters: "--install"; Flags: runhidden waituntilterminated; StatusMsg: "{cm:Configuring}"
Filename: "{sys}\schtasks.exe"; Parameters: "/Run /TN LocalKeys"; Flags: runhidden nowait postinstall; Description: "{cm:LaunchApp}"

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM LocalKeys.exe"; Flags: runhidden waituntilterminated; RunOnceId: "KillAgent"
Filename: "{app}\LocalKeys.exe"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "Unregister"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM LocalKeys.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(300);
  Result := '';
end;
