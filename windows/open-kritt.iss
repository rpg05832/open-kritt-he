; קובץ ההתקנה של "סריקת אבטחה" (Inno Setup 6). נבנה דרך legal/build-setup.cjs, שמעביר AppVersion ו־Stage.
; ההתקנה בלי הרשאות מנהל, לתיקייה של המשתמש. נתוני התוכנה (‎.env, ‎.data, פרויקטים, תעודות שאושרו,
; קבצים מאומתים וגיבויים) נשארים במקומם בעדכון, וההסרה שואלת לפני שהיא מוחקת אותם.
; המבנה לפי הדגם של C:\Tzevet\app\installer\tzevet.iss.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Stage
  #define Stage "..\..\distribution\stage"
#endif

[Setup]
AppId={{4E9B2C71-0D5A-4F38-B6E2-9A1C7D3E5F80}
AppName=סריקת אבטחה
AppVersion={#AppVersion}
AppVerName=סריקת אבטחה {#AppVersion}
AppPublisher=@ארי ממתמחים טופ (מבוסס על open·kritt)
AppPublisherURL=https://mitmachim.top/user/%D7%90%D7%A8%D7%99
AppSupportURL=https://github.com/Kritt-ai/open-kritt
DefaultDirName={localappdata}\Programs\SecurityScan
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=SecurityScan-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=סריקת אבטחה
CloseApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#Stage}\app\LICENSE
InfoBeforeFile={#Stage}\SETUP-INFO-he.txt

[Languages]
Name: "he"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Tasks]
Name: "desktopicon"; Description: "קיצורי דרך בשולחן העבודה"

[InstallDelete]
; קוד ישן יורד לפני שמעתיקים חדש, כדי שקובץ שנמחק בגרסה החדשה לא יישאר.
; לא נמחקים: app\.env, app\.data, app\local_repos, app\vendor-cache, certificates, .maintenance, גיבויים.
Type: filesandordirs; Name: "{app}\app\frontend\src"
Type: filesandordirs; Name: "{app}\app\backend\src"
Type: filesandordirs; Name: "{app}\app\engine\open_kritt_engine"
Type: filesandordirs; Name: "{app}\app\engine\tests"
Type: filesandordirs; Name: "{app}\app\database\init"
Type: filesandordirs; Name: "{app}\app\windows"
Type: filesandordirs; Name: "{app}\app\legal"
Type: filesandordirs; Name: "{app}\app\frontend\public\legal"

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{userprograms}\סריקת אבטחה\הפעלה"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\manage.ps1"" -Action Start"; WorkingDir: "{app}"; Flags: runminimized
Name: "{userprograms}\סריקת אבטחה\עצירה"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\manage.ps1"" -Action Stop"; WorkingDir: "{app}"; Flags: runminimized
Name: "{userprograms}\סריקת אבטחה\ניהול"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\manage.ps1"" -Action Menu"; WorkingDir: "{app}"; Flags: runminimized
Name: "{userprograms}\סריקת אבטחה\בדיקה ותיקון"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\prepare.ps1"" -Mode Repair"; WorkingDir: "{app}"; Flags: runminimized
Name: "{userdesktop}\סריקת אבטחה"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\manage.ps1"" -Action Start"; WorkingDir: "{app}"; Flags: runminimized; Tasks: desktopicon

[Run]
; התקנה ראשונה: אשף ההכנה (Docker, רשת, תעודות ובניית הרכיבים). עדכון: אותו אשף במצב "בדיקה ותיקון".
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\prepare.ps1"" {code:WizardMode}"; Description: "להמשיך באשף ההכנה וההתקנה של רכיבי התוכנה"; Flags: postinstall nowait runhidden

[Code]
function IsUpdate: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\.maintenance\installed-here'));
end;

function WizardMode(Param: String): String;
begin
  if IsUpdate then Result := '-Mode Repair' else Result := '-Mode Install';
end;

// עוצר רק את סריקת אבטחה (לא את Docker ולא תוכנות אחרות), כדי שהקבצים לא יהיו נעולים.
procedure StopApp;
var R: Integer;
begin
  if FileExists(ExpandConstant('{app}\manage.ps1')) then
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\manage.ps1') + '" -Action Stop',
      '', SW_HIDE, ewWaitUntilTerminated, R);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopApp;
  Result := '';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var R: Integer;
begin
  // ההסרה של התוכנה עצמה (שירותים, נתונים, גיבוי) עוברת דרך מנהל ההפעלה, שמבקש אישור ומציע לשמור גיבוי.
  // Inno מסיר אחר כך רק את הקבצים שהוא התקין; גיבוי שנשמר נשאר בתיקייה.
  if (CurUninstallStep = usUninstall) and not UninstallSilent and FileExists(ExpandConstant('{app}\manage.ps1')) then
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\manage.ps1') + '" -Action Uninstall',
      '', SW_SHOW, ewWaitUntilTerminated, R);
end;
