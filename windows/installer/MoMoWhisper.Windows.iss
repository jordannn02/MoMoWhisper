#ifndef SourceDir
  #define SourceDir "..\artifacts\publish"
#endif
#ifndef OutputDir
  #define OutputDir "..\artifacts\installer"
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0-beta.1"
#endif

[Setup]
AppId={{A6AB7E8A-91D7-4CB4-81BE-AFF82A36A6F0}
AppName=MoMoWhisper Windows Beta
AppVersion={#AppVersion}
AppPublisher=MoMoWhisper
DefaultDirName={localappdata}\Programs\MoMoWhisper Windows Beta
DefaultGroupName=MoMoWhisper Windows Beta
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=MoMoWhisper-Windows-Beta-{#AppVersion}-x64-Setup
UninstallDisplayIcon={app}\MoMoWhisper.Windows.exe
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MoMoWhisper Windows Beta"; Filename: "{app}\MoMoWhisper.Windows.exe"
Name: "{autodesktop}\MoMoWhisper Windows Beta"; Filename: "{app}\MoMoWhisper.Windows.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "建立桌面捷徑"; GroupDescription: "其他選項："; Flags: unchecked

[Run]
Filename: "{app}\MoMoWhisper.Windows.exe"; Description: "啟動 MoMoWhisper Windows Beta"; Flags: nowait postinstall skipifsilent
