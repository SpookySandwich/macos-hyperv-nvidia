#define AppVersion "1.3.1"
[Setup]
AppId={{20A3EA25-857E-49A9-9609-41A79130368E}
AppName=macOS
AppVersion={#AppVersion}
AppPublisher=Local macOS Workspace
DefaultDirName={autopf}\macOS
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\macOS.exe
SetupIconFile=..\src\MacOS.App\Assets\macOS.ico
OutputDir=..\dist
OutputBaseFilename=macOS-Setup
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=no
[Files]
Source: "..\publish\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\publish\service\*"; DestDir: "{app}\service"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "configure.ps1"; DestDir: "{app}\installer"; Flags: ignoreversion
[Icons]
Name: "{autoprograms}\macOS"; Filename: "{app}\macOS.exe"; WorkingDir: "{app}"; IconFilename: "{app}\Assets\macOS.ico"
[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var Code: Integer;
begin
  Result := '';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile -NonInteractive -Command "if (Get-Service MacOSSession -ErrorAction SilentlyContinue) { Stop-Service MacOSSession -ErrorAction Stop }"', '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
    Result := 'Could not stop the macOS service for updating. The virtual machine has been left running.';
end;
function Configure(Action: String): Boolean;
var Code: Integer; Args: String;
begin
  Args := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\installer\configure.ps1') + '" -Action ' + Action;
  if Action = 'Install' then Args := Args + ' -OwnerSid "{#GetEnv('MACOS_OWNER_SID')}" -OwnerAccount "{#GetEnv('MACOS_OWNER_ACCOUNT')}"';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Args, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    if not Configure('Install') then RaiseException('macOS service setup failed. The existing virtual machine and GPU assignment were preserved.');
  end;
end;
function InitializeUninstall(): Boolean;
begin
  Result := Configure('Uninstall');
  if not Result then MsgBox('Shut down macOS before uninstalling. Your virtual machine and disks will be kept.', mbError, MB_OK);
end;
