; Tatakan for Windows — Inno Setup 6 script.
; Built by .github/workflows/release.yml (or locally: iscc /DAppVersion=0.4.0 windows\installer\Tatakan.iss)
; Expects framework-dependent builds in windows\dist\x64 and windows\dist\arm64.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6C0E9A4B-6B5E-4E7B-9D0B-7A1A2F7C4E21}
AppName=Tatakan
AppVersion={#AppVersion}
AppVerName=Tatakan {#AppVersion}
AppPublisher=Reihan Al Kautsar
AppPublisherURL=https://github.com/reihanalka/tatakan
AppSupportURL=https://github.com/reihanalka/tatakan/issues
AppUpdatesURL=https://github.com/reihanalka/tatakan/releases
AppCopyright=© 2026 Reihan Al Kautsar. MIT License.
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\Tatakan
DefaultGroupName=Tatakan
DisableProgramGroupPage=yes
DisableDirPage=auto
; Per-user install by default: no admin prompt. (Installing .NET, if needed, asks for admin on its own.)
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
MinVersion=10.0.17763
OutputDir=..\dist
OutputBaseFilename=Tatakan-Setup-{#AppVersion}
SetupIconFile=..\Tatakan\Assets\app.ico
UninstallDisplayIcon={app}\Tatakan.exe
UninstallDisplayName=Tatakan
WizardStyle=modern
WizardImageFile=wizard-side.bmp
WizardSmallImageFile=wizard-small.bmp
LicenseFile=..\..\LICENSE
Compression=lzma2/max
SolidCompression=yes
CloseApplications=force
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "id"; MessagesFile: "compiler:Languages\Indonesian.isl"

[CustomMessages]
en.StartupTask=Start Tatakan when I sign in
id.StartupTask=Jalankan Tatakan saat masuk Windows
en.Launch=Open Tatakan now
id.Launch=Buka Tatakan sekarang
en.NeedsDotNet=Tatakan needs the .NET 8 Desktop Runtime (about 55 MB, from Microsoft). It will be downloaded and installed now.
id.NeedsDotNet=Tatakan butuh .NET 8 Desktop Runtime (sekitar 55 MB, dari Microsoft). Sekarang akan di-download dan dipasang.
en.DotNetFailed=The .NET 8 Desktop Runtime couldn't be installed. Install it from https://aka.ms/dotnet/8.0 and run this setup again.
id.DotNetFailed=.NET 8 Desktop Runtime gagal dipasang. Pasang manual dari https://aka.ms/dotnet/8.0 lalu jalankan setup ini lagi.

[Tasks]
Name: "startup"; Description: "{cm:StartupTask}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\dist\x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs; Check: not IsArm64
Source: "..\dist\arm64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs; Check: IsArm64

[Icons]
Name: "{autoprograms}\Tatakan"; Filename: "{app}\Tatakan.exe"
Name: "{autodesktop}\Tatakan"; Filename: "{app}\Tatakan.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Tatakan"; \
  ValueData: """{app}\Tatakan.exe"" --background"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Tatakan.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im Tatakan.exe"; Flags: runhidden; RunOnceId: "KillTatakan"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Tatakan\Cache"

[Code]
var
  DownloadPage: TDownloadWizardPage;

function RuntimeArch: String;
begin
  if IsArm64 then Result := 'arm64' else Result := 'x64';
end;

{ .NET 8 Desktop Runtime registers itself under HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\<arch>\sharedfx\Microsoft.WindowsDesktop.App }
function HasDesktopRuntime8: Boolean;
var
  Names: TArrayOfString;
  I: Integer;
  Key: String;
begin
  Result := False;
  Key := 'SOFTWARE\dotnet\Setup\InstalledVersions\' + RuntimeArch + '\sharedfx\Microsoft.WindowsDesktop.App';
  if RegGetValueNames(HKLM64, Key, Names) then
    for I := 0 to GetArrayLength(Names) - 1 do
      if Copy(Names[I], 1, 2) = '8.' then
      begin
        Result := True;
        Exit;
      end;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ResultCode: Integer;
  Installer: String;
begin
  Result := True;
  if (CurPageID <> wpReady) or HasDesktopRuntime8 then Exit;

  if not WizardSilent then
    MsgBox(CustomMessage('NeedsDotNet'), mbInformation, MB_OK);

  DownloadPage.Clear;
  DownloadPage.Add('https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-' + RuntimeArch + '.exe', 'dotnet-desktop-runtime.exe', '');
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
    except
      if not WizardSilent then SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbCriticalError, MB_OK, IDOK);
      Result := False;
      Exit;
    end;
  finally
    DownloadPage.Hide;
  end;

  Installer := ExpandConstant('{tmp}\dotnet-desktop-runtime.exe');
  { The runtime installer asks for admin itself (UAC). }
  if not ShellExec('runas', Installer, '/install /quiet /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode)
     or not ((ResultCode = 0) or (ResultCode = 1638) or (ResultCode = 3010)) or not HasDesktopRuntime8 then
  begin
    SuppressibleMsgBox(CustomMessage('DotNetFailed'), mbCriticalError, MB_OK, IDOK);
    Result := False;
  end;
end;
