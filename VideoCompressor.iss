; Inno Setup script - Video Compressor
; Put this file in the SAME folder as: VideoCompressor.ps1, ffmpeg.exe, ffprobe.exe, LICENSE, VideoCompressor.ico, Agreement.txt
; Open it in Inno Setup and press F9 (Build > Compile). Output: VideoCompressorSetup.exe

[Setup]
AppId={{8F3A6B1E-2C4D-4E7A-9B15-6D0C7A3F2E91}
AppName=Video Compressor
AppVersion=1.2.2
AppPublisher=Whitepumpkin
DefaultDirName={autopf}\Video Compressor
DefaultGroupName=Video Compressor
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=.
OutputBaseFilename=VideoCompressorSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile=Agreement.txt
UninstallDisplayName=Video Compressor
SetupIconFile=VideoCompressor.ico
UninstallDisplayIcon={app}\VideoCompressor.ico

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "VideoCompressor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "ffprobe.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "VideoCompressor.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Video Compressor"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\VideoCompressor.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\VideoCompressor.ico"; Flags: runminimized
Name: "{autodesktop}\Video Compressor"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\VideoCompressor.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\VideoCompressor.ico"; Flags: runminimized; Tasks: desktopicon

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\VideoCompressor"