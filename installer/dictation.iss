; Inno Setup script for Dictation.
;
; Build with:  iscc installer\dictation.iss /DVersion=0.1.0
; It packages whatever `dart run tool/package.dart` staged, so the installer
; and the portable zip can never contain different builds.

#ifndef Version
  #define Version "0.0.0"
#endif

#define Name "Dictation"
#define Publisher "PopupBits"
#define Url "https://github.com/lohanidamodar/dictation"
#define Exe "dictate.exe"
#define Staged "..\build\dictation-" + Version + "-windows-x64"

[Setup]
AppId={{5F2A9C41-7E3D-4B18-9A6C-2D8E1F4B7C30}
AppName={#Name}
AppVersion={#Version}
AppPublisher={#Publisher}
AppPublisherURL={#Url}
AppSupportURL={#Url}/issues
AppUpdatesURL={#Url}/releases

; Per-user, so installing never needs an administrator. This is a tray app for
; one person; there is nothing here a machine-wide install would buy.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
DisableProgramGroupPage=yes
DisableDirPage=auto

LicenseFile={#Staged}\LICENSE
InfoAfterFile=after-install.txt
OutputDir=..\build
OutputBaseFilename=dictation-{#Version}-windows-x64-setup
SetupIconFile=dictation.ico
UninstallDisplayIcon={app}\dictation.ico
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startup"; Description: "Start {#Name} when I sign in"; GroupDescription: "Startup"

[Files]
Source: "{#Staged}\{#Exe}"; DestDir: "{app}"; Flags: ignoreversion
; Both libraries must land together: Windows resolves onnxruntime.dll by search
; order, and a stray copy elsewhere on the system otherwise wins and crashes
; inside native code.
Source: "{#Staged}\sherpa-onnx-c-api.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Staged}\onnxruntime.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "dictation.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Staged}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Staged}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Staged}\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Minimised, because the program is a console executable that frees its console
; on startup — without this there is a brief black flash before it does.
Name: "{group}\{#Name}"; Filename: "{app}\{#Exe}"; IconFilename: "{app}\dictation.ico"; Flags: runminimized
Name: "{group}\Settings"; Filename: "{userappdata}\Dictation\config.json"
Name: "{group}\Uninstall {#Name}"; Filename: "{uninstallexe}"
Name: "{userstartup}\{#Name}"; Filename: "{app}\{#Exe}"; IconFilename: "{app}\dictation.ico"; Tasks: startup; Flags: runminimized

[Run]
Filename: "{app}\{#Exe}"; Description: "Start {#Name} now"; Flags: nowait postinstall skipifsilent runminimized

[UninstallDelete]
Type: files; Name: "{userappdata}\Dictation\config.json"
Type: dirifempty; Name: "{userappdata}\Dictation"

[Code]
// The speech models are large and shared with the other PopupBits apps, so
// they are not removed with the program unless asked for. Deleting them would
// silently cost another app its recogniser.
procedure CurUninstallStepChanged(CurStep: TUninstallStep);
var
  Models: String;
begin
  if CurStep <> usPostUninstall then
    Exit;

  // /SUPPRESSMSGBOXES does not reach a MsgBox called from here, so a silent
  // uninstall would sit forever waiting for an answer nobody can give. Keep
  // the models, which is the safe half of the choice.
  if UninstallSilent then
    Exit;

  Models := ExpandConstant('{localappdata}\PopupBits\models');
  if not DirExists(Models) then
    Exit;

  if MsgBox('Also delete the downloaded speech models (about 900 MB)?' + #13#10#13#10 +
            Models + #13#10#13#10 +
            'Other PopupBits apps share these. Say No if you have any installed.',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(Models, True, True, True);
end;
