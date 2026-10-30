[CmdletBinding()]
param([string]$InstallationRoot='',[switch]$ReportOnly,[ValidateSet('Install','Repair')][string]$Mode='Install')
# Installation and repair wizard (Windows Forms, Hebrew, right-to-left).
# It never changes the Windows trust store, never disables TLS verification and
# never accepts vendor terms on the user's behalf.
$ErrorActionPreference='Stop'
# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1.
if(-not $InstallationRoot){$InstallationRoot=if((Split-Path -Leaf $PSScriptRoot) -eq 'windows' -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\app'))){[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}else{$PSScriptRoot}}
$library=@((Join-Path $PSScriptRoot 'prepare-lib.ps1'),(Join-Path $PSScriptRoot 'app\windows\prepare-lib.ps1'),(Join-Path $InstallationRoot 'app\windows\prepare-lib.ps1'))|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
if(-not $library){throw 'חסר הקובץ prepare-lib.ps1. חלצו מחדש את כל חבילת ההתקנה.'}
. $library
$InstallationRoot=[IO.Path]::GetFullPath($InstallationRoot)
$applicationRoot=Join-Path $InstallationRoot 'app'
$certificateFolder=Join-Path $InstallationRoot 'certificates'
$installLog=Join-Path $InstallationRoot 'installation.log'
$reportFile=Join-Path $InstallationRoot 'prepare-report.txt'

# ---------- text report (used by -ReportOnly and saved next to the installation) ----------
function Get-ReportText($system,$network){
 $l=New-Object 'System.Collections.Generic.List[string]'
 $l.Add('דוח בדיקת מחשב — '+(Get-Date -Format 'dd/MM/yyyy HH:mm'))
 $l.Add('Windows 64 ביט: '+$(if($system.Is64){'כן'}else{'לא'})+' | מקום פנוי: '+$system.FreeGb+' GB | WSL: '+$(if($system.Wsl){'קיים'}else{'לא נמצא'}))
 $l.Add('Docker Desktop: '+$(if($system.DesktopInstalled){'מותקן'}else{'לא מותקן'})+' | מנוע: '+$(if($system.EngineOk){'פועל, זיכרון '+$system.MemGb+' GB'}elseif($system.OsType){'מצב '+$system.OsType}else{'לא פועל'})+' | Compose: '+$system.Compose)
 $l.Add('רכיבי התוכנה: '+$(if($system.ImagesBuilt){'בנויים'}else{'לא בנויים'}))
 if($network){
  if(-not $network.Probe.Ok){$l.Add('בדיקת רשת: '+(Get-ClassText $network.Probe.Kind)+' '+$network.Probe.Detail)}
  foreach($row in $network.Rows){$l.Add('  '+$row.Host+': '+(Get-ClassText $row.Class)+$(if($row.Root){' ['+$row.Root+']'}))}
  foreach($c in $network.Candidates){$l.Add('תעודה מוצעת לאישור: '+$c.Root.Subject+' ('+$c.Root.Thumbprint+')')}
 }else{$l.Add('בדיקת רשת: לא בוצעה (Docker כבוי)')}
 return ($l -join [Environment]::NewLine)
}
if($ReportOnly){
 $system=Get-SystemState -InstallationRoot $InstallationRoot
 $network=if($system.EngineOk){Get-NetworkState -Docker $system.DockerPath -CertificateFolder $certificateFolder}else{$null}
 Get-ReportText $system $network
 return
}
if(-not (Test-Path -LiteralPath (Join-Path $applicationRoot 'LICENSE'))){
 Add-Type -AssemblyName System.Windows.Forms
 [void][Windows.Forms.MessageBox]::Show('לא נמצאה תיקיית התוכנה. חלצו את כל קובץ ה־ZIP לתיקייה אחת והפעילו שוב את Install.cmd מתוכה.','סריקת אבטחה','OK','Warning'); exit 1
}

# ---------- look and feel ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$Palette=@{Accent=[Drawing.Color]::FromArgb(31,95,191);AccentDark=[Drawing.Color]::FromArgb(22,72,148);Text=[Drawing.Color]::FromArgb(30,35,41);Muted=[Drawing.Color]::FromArgb(95,107,122)
 Side=[Drawing.Color]::FromArgb(244,246,249);Line=[Drawing.Color]::FromArgb(223,227,233);Ok=[Drawing.Color]::FromArgb(30,127,79);Warn=[Drawing.Color]::FromArgb(178,106,0);Bad=[Drawing.Color]::FromArgb(179,38,30);White=[Drawing.Color]::White}
$F=@{Body=New-Object Drawing.Font('Segoe UI',10);Bold=New-Object Drawing.Font('Segoe UI Semibold',10);Title=New-Object Drawing.Font('Segoe UI Semibold',17);Brand=New-Object Drawing.Font('Segoe UI Semibold',13);Small=New-Object Drawing.Font('Segoe UI',8.5);Icon=New-Object Drawing.Font('Segoe UI Symbol',11)}

function Pump{[Windows.Forms.Application]::DoEvents()}
function New-Label([string]$text,$font=$F.Body,$color=$Palette.Text){$l=New-Object Windows.Forms.Label; $l.Text=$(if($text){[string][char]0x200F+$text}else{$text}); $l.Font=$font; $l.ForeColor=$color; $l.AutoSize=$false; $l.UseMnemonic=$false; return $l}
function New-Button([string]$text,[switch]$Primary){
 $b=New-Object Windows.Forms.Button; $b.Text=$text; $b.Font=$F.Bold; $b.FlatStyle='Flat'; $b.Cursor='Hand'; $b.Height=36; $b.Width=[Math]::Max(110,[Windows.Forms.TextRenderer]::MeasureText($text,$F.Bold).Width+36)
 if($Primary){$b.BackColor=$Palette.Accent; $b.ForeColor=$Palette.White; $b.FlatAppearance.BorderSize=0; $b.FlatAppearance.MouseOverBackColor=$Palette.AccentDark}
 else{$b.BackColor=$Palette.White; $b.ForeColor=$Palette.Text; $b.FlatAppearance.BorderColor=$Palette.Line}
 return $b
}
function Show-Message([string]$text,[string]$title='סריקת אבטחה',[string]$icon='Information'){[void][Windows.Forms.MessageBox]::Show($script:Form,$text,$title,'OK',$icon,'Button1','RtlReading,RightAlign')}
function Ask([string]$text,[string]$title){return ([Windows.Forms.MessageBox]::Show($script:Form,$text,$title,'YesNo','Question','Button2','RtlReading,RightAlign') -eq 'Yes')}

# A status line: coloured mark, bold title, muted explanation, optional action button.
function Add-Status($panel,[string]$state,[string]$title,[string]$detail,[string]$actionText='',[scriptblock]$action=$null){
 $row=New-Object Windows.Forms.Panel; $row.Width=$panel.ClientSize.Width-24; $row.Height=58; $row.Margin=New-Object Windows.Forms.Padding(0,0,0,6)
 $symbols=@{ok='✓';warn='!';bad='✕';wait='…';info='•'}; $colors=@{ok=$Palette.Ok;warn=$Palette.Warn;bad=$Palette.Bad;wait=$Palette.Muted;info=$Palette.Accent}
 $mark=New-Label $symbols[$state] $F.Icon $colors[$state]
 $mark.SetBounds(($row.Width-26),2,24,24); $mark.TextAlign='MiddleCenter'; $row.Controls.Add($mark)
 $width=$row.Width-36; if($actionText){$width-=190}
 $t=New-Label $title $F.Bold; $t.SetBounds(($row.Width-32-$width),3,$width,22); $t.TextAlign='MiddleRight'; $row.Controls.Add($t)
 $d=New-Label $detail $F.Small $Palette.Muted; $d.SetBounds(($row.Width-32-$width),25,$width,32); $d.TextAlign='TopRight'; $row.Controls.Add($d)
 if($actionText){$b=New-Button $actionText; $b.Width=176; $b.Height=32; $b.Location=New-Object Drawing.Point(0,10); $b.Tag=$action; $b.Add_Click({param($s,$e) Invoke-Safely $s.Tag}); $row.Controls.Add($b)}
 $panel.Controls.Add($row); Pump
}
function Invoke-Safely([scriptblock]$block){
 $script:Form.Cursor='WaitCursor'; $script:Next.Enabled=$false; $script:Back.Enabled=$false
 try{& $block}catch{Show-Message $_.Exception.Message 'הפעולה לא הושלמה' 'Warning'}
 finally{$script:Form.Cursor='Default'; Update-Navigation}
}

# ---------- window ----------
$script:Form=New-Object Windows.Forms.Form
$Form.Text='סריקת אבטחה — התקנה'; $Form.ClientSize=New-Object Drawing.Size(960,640); $Form.StartPosition='CenterScreen'
$Form.RightToLeft='Yes'; $Form.RightToLeftLayout=$true; $Form.BackColor=$Palette.White; $Form.Font=$F.Body; $Form.FormBorderStyle='FixedSingle'; $Form.MaximizeBox=$false
$Form.AutoScaleMode='Dpi'
$side=New-Object Windows.Forms.Panel; $side.SetBounds(0,0,250,640); $side.BackColor=$Palette.Side; $Form.Controls.Add($side)
$brand=New-Label 'סריקת אבטחה' $F.Brand; $brand.SetBounds(24,28,210,30); $side.Controls.Add($brand)
$brandSub=New-Label $(if($Mode -eq 'Repair'){'בדיקה ותיקון'}else{'אשף התקנה'}) $F.Body $Palette.Muted; $brandSub.SetBounds(24,58,210,22); $side.Controls.Add($brandSub)
$script:Steps=@('ברוכים הבאים','בדיקת המחשב','רשת ותעודות','התקנה','סיום')
$script:StepLabels=@()
for($i=0;$i -lt $Steps.Count;$i++){
 $n=New-Label ([string]($i+1)) $F.Bold $Palette.Muted; $n.SetBounds(24,(118+$i*46),28,28); $n.TextAlign='MiddleCenter'; $n.BackColor=$Palette.White
 $circle=New-Object Drawing.Drawing2D.GraphicsPath; $circle.AddEllipse(0,0,28,28); $n.Region=New-Object Drawing.Region($circle); $side.Controls.Add($n)
 $t=New-Label $Steps[$i] $F.Body $Palette.Muted; $t.SetBounds(60,(120+$i*46),170,24); $side.Controls.Add($t)
 $script:StepLabels+=,@($n,$t)
}
$credit=New-Label 'הגרסה העברית, התוספות והשיפורים: @ארי ממתמחים טופ' $F.Small $Palette.Muted; $credit.SetBounds(16,560,220,36); $side.Controls.Add($credit)
$origin=New-Label 'מבוסס על open·kritt · AGPL-3.0' $F.Small $Palette.Muted; $origin.SetBounds(16,598,220,20); $side.Controls.Add($origin)

$script:TitleLabel=New-Label '' $F.Title; $TitleLabel.SetBounds(282,26,650,38); $Form.Controls.Add($TitleLabel)
$script:Lead=New-Label '' $F.Body $Palette.Muted; $Lead.SetBounds(282,66,650,44); $Form.Controls.Add($Lead)
$script:Body=New-Object Windows.Forms.FlowLayoutPanel; $Body.SetBounds(282,116,650,440); $Body.FlowDirection='TopDown'; $Body.WrapContents=$false; $Body.AutoScroll=$true; $Form.Controls.Add($Body)
$rule=New-Object Windows.Forms.Panel; $rule.SetBounds(250,572,710,1); $rule.BackColor=$Palette.Line; $Form.Controls.Add($rule)
$script:Next=New-Button 'הבא' -Primary; $Next.Location=New-Object Drawing.Point(800,588); $Next.Width=132; $Form.Controls.Add($Next)
$script:Back=New-Button 'חזרה'; $Back.Location=New-Object Drawing.Point(682,588); $Form.Controls.Add($Back)
$script:Cancel=New-Button 'סגירה'; $Cancel.Location=New-Object Drawing.Point(282,588); $Form.Controls.Add($Cancel)

$script:Page=0; $script:CanNext=$false; $script:System=$null; $script:Network=$null; $script:Installing=$false; $script:Installed=$false
function Update-Navigation{
 for($i=0;$i -lt $Steps.Count;$i++){
  $n=$StepLabels[$i][0]; $t=$StepLabels[$i][1]
  if($i -lt $script:Page){$n.Text='✓'; $n.BackColor=$Palette.Ok; $n.ForeColor=$Palette.White; $t.ForeColor=$Palette.Text; $t.Font=$F.Body}
  elseif($i -eq $script:Page){$n.Text=[string]($i+1); $n.BackColor=$Palette.Accent; $n.ForeColor=$Palette.White; $t.ForeColor=$Palette.Text; $t.Font=$F.Bold}
  else{$n.Text=[string]($i+1); $n.BackColor=$Palette.White; $n.ForeColor=$Palette.Muted; $t.ForeColor=$Palette.Muted; $t.Font=$F.Body}
 }
 $script:Next.Enabled=$script:CanNext -and -not $script:Installing
 # Flat buttons keep their colour when disabled; show the state explicitly.
 $script:Next.BackColor=$(if($script:Next.Enabled){$Palette.Accent}else{$Palette.Line}); $script:Next.ForeColor=$(if($script:Next.Enabled){$Palette.White}else{$Palette.Muted})
 $script:Back.Enabled=$script:Page -gt 0 -and $script:Page -lt 4 -and -not $script:Installing
 $script:Back.Visible=$script:Page -gt 0 -and $script:Page -lt 4
 $script:Next.Text=switch($script:Page){3{'המשך'} 4{'סיום'} default{'הבא'}}
}
function Set-Page([int]$index,[string]$pageTitle,[string]$pageLead){
 $script:Page=$index; $script:CanNext=$false; $TitleLabel.Text=$pageTitle; $script:Lead.Text=$pageLead
 $Body.SuspendLayout(); foreach($old in @($Body.Controls)){$old.Dispose()}; $Body.Controls.Clear(); $Body.ResumeLayout(); Update-Navigation; Pump
}
function Add-Paragraph([string]$text,$font=$F.Body,$color=$Palette.Text,[int]$height=0){
 $l=New-Label $text $font $color; $l.Width=$Body.ClientSize.Width-24
 $l.Height=if($height){$height}else{[Windows.Forms.TextRenderer]::MeasureText($text,$font,(New-Object Drawing.Size($l.Width,2000)),'WordBreak').Height+8}
 $l.Margin=New-Object Windows.Forms.Padding(0,0,0,8); $Body.Controls.Add($l); return $l
}
function Add-Link([string]$text,[scriptblock]$action){
 $l=New-Object Windows.Forms.LinkLabel; $l.Text=$text; $l.Font=$F.Body; $l.LinkColor=$Palette.Accent; $l.AutoSize=$true; $l.Margin=New-Object Windows.Forms.Padding(0,0,0,6); $l.Tag=$action
 $l.Add_LinkClicked({param($s,$e) Invoke-Safely $s.Tag}); $Body.Controls.Add($l)
}
function Open-File([string]$path){if(Test-Path -LiteralPath $path){Start-Process notepad.exe -ArgumentList ('"'+$path+'"')}else{throw 'הקובץ לא נמצא: '+[IO.Path]::GetFileName($path)}}

# ---------- page 1: welcome ----------
function Show-Welcome{
 $installed=Test-Path -LiteralPath (Join-Path $InstallationRoot '.maintenance\installed-here')
 Set-Page 0 'ברוכים הבאים' $(if($installed){'התוכנה כבר מותקנת בתיקייה הזאת. האשף יבדוק את המחשב ויבנה מחדש רכיבים חסרים. סריקות, חשבונות והגדרות נשמרים.'}else{'האשף יכין את המחשב ויתקין את התוכנה. כל שלב מוסבר, ושום דבר לא משתנה בלי אישור שלכם.'})
 Add-Paragraph 'מה יקרה בהתקנה' $F.Bold | Out-Null
 Add-Paragraph ("•  נבדוק שהמחשב מתאים ושיש מספיק מקום (כ־15 GB).`n•  אם חסר Docker Desktop, נוריד אותו מהאתר הרשמי ותתקינו אותו בעצמכם. זו ההתקנה היחידה ב־Windows.`n•  נבדוק את החיבור לאינטרנט ואת הסינון, ונסביר בדיוק מה לעשות אם משהו חסום.`n•  רכיבי התוכנה ייבנו בתוך Docker (20–60 דקות, תלוי במהירות האינטרנט).") | Out-Null
 Add-Paragraph 'תנאים ורישיונות' $F.Bold | Out-Null
 Add-Paragraph ('התוכנה מבוססת על open·kritt של Harel Rom ו־Gabriel Balko, ברישיון AGPL-3.0. הגרסה העברית, התוספות והשיפורים בוצעו על ידי @ארי ממתמחים טופ. Docker Desktop, Codex, Claude Code ושירותי ה־AI כפופים לתנאים של הספקים שלהם; חשבונות ומנויים מתחברים בנפרד, אחרי ההתקנה.') $F.Body $Palette.Muted | Out-Null
 Add-Link 'קריאת הרישיון (LICENSE)' {Open-File (Join-Path $applicationRoot 'LICENSE')}
 Add-Link 'הודעות זכויות ורכיבי צד שלישי' {Open-File (Join-Path $applicationRoot 'NOTICE.md')}
 Add-Link 'מדריך ההתקנה המלא' {$g=Join-Path $InstallationRoot 'README-he.md'; if(-not (Test-Path -LiteralPath $g)){$g=Join-Path $applicationRoot 'windows\DISTRIBUTION-README-he.md'}; Open-File $g}
 $check=New-Object Windows.Forms.CheckBox; $check.Text='קראתי, ואני מסכים להמשיך'; $check.Font=$F.Bold; $check.AutoSize=$true; $check.Margin=New-Object Windows.Forms.Padding(0,10,0,0)
 $check.Add_CheckedChanged({param($s,$e) $script:CanNext=$s.Checked; Update-Navigation}); $Body.Controls.Add($check)
}

# ---------- page 2: computer and Docker ----------
function Show-Computer{
 Set-Page 1 'בדיקת המחשב' 'בודקים מה כבר קיים. הבדיקה רק קוראת מצב ואינה משנה דבר.'
 Add-Status $Body 'wait' 'בודק…' 'זה לוקח כמה שניות.'
 $s=Get-SystemState -InstallationRoot $InstallationRoot -Pump {Pump}; $script:System=$s
 $Body.Controls.Clear()
 Add-Status $Body $(if($s.Is64){'ok'}else{'bad'}) 'Windows' $(if($s.Is64){'גרסת 64 ביט, מתאימה.'}else{'נדרש Windows בגרסת 64 ביט.'})
 Add-Status $Body $(if($s.FreeGb -ge 15){'ok'}else{'warn'}) ('מקום פנוי: '+$s.FreeGb+' GB') $(if($s.FreeGb -ge 15){'מספיק להתקנה.'}else{'מומלץ לפחות 15 GB. פנו מקום או חלצו את החבילה לכונן אחר.'})
 if($s.EngineMode -eq 'wsl' -and $s.WslEngineInstalled -and -not $s.EngineOk){
  Add-Status $Body 'warn' 'מנוע Docker המובנה כבוי' 'הוא פועל רק כשהתוכנה פועלת, כדי לא לתפוס זיכרון סתם.' 'הפעלת המנוע' {Start-BuiltinEngine}
 }elseif(-not $s.DesktopInstalled -and -not $s.DockerPath){
  if($s.WslReady){
   Add-Status $Body 'info' 'מנוע Docker מובנה (מומלץ)' 'סביבת Linux קטנה של Windows (WSL) שמשמשת רק את התוכנה הזאת. בלי Docker Desktop, בלי תנאי מנוי, כ־400 MB.' 'התקנת המנוע המובנה' {Install-BuiltinEngine}
  }else{
   Add-Status $Body 'bad' 'רכיב WSL של Windows כבוי' "המנוע המובנה צריך את WSL, רכיב חינמי של Windows. כדי להפעיל אותו: לחצו ימני על התחל ← Terminal (מנהל) ← הקלידו wsl --install --no-distribution ← הפעילו מחדש את המחשב ופתחו שוב את האשף."
  }
  Add-Status $Body 'info' 'או: Docker Desktop' 'תוכנה של חברת Docker עם חלון ניהול משלה. חינמית לשימוש אישי ולעסק קטן; ארגון גדול צריך מנוי.' 'הורדה והתקנה' {Install-DockerDesktop}
 }elseif(-not $s.OsType){
  Add-Status $Body 'warn' 'Docker Desktop מותקן אבל כבוי' 'הפעילו אותו והמתינו כדקה, עד שהכיתוב "Engine running" מופיע בחלון של Docker.' 'הפעלת Docker' {Start-DockerDesktop}
 }elseif(-not $s.EngineOk){
  Add-Status $Body 'bad' 'Docker במצב Windows containers' 'בתפריט של Docker (סמל הלוויתן ליד השעון) בחרו "Switch to Linux containers".'
 }else{
  Add-Status $Body 'ok' $(if($s.EngineMode -eq 'wsl'){'מנוע Docker המובנה פועל'}else{'Docker פועל'}) ('זיכרון זמין ל־Docker: '+$s.MemGb+' GB. התוכנה מותאמת למגבלה הזאת ולא תשנה אותה.')
  if($s.MemGb -lt 3.5){Add-Status $Body 'warn' 'מעט זיכרון' 'פחות מ־4 GB. התוכנה תעבוד, אבל לאט ובדיקה אחת בכל פעם.'}
 }
 if($s.ImagesBuilt){Add-Status $Body 'info' 'רכיבי התוכנה כבר בנויים' 'בהמשך אפשר לבנות אותם מחדש. הנתונים שלכם נשמרים.'}
 Add-Link 'בדיקה חוזרת' {Show-Computer}
 $script:CanNext=$s.Is64 -and $s.EngineOk; Update-Navigation
}
function Start-BuiltinEngine{
 $Body.Controls.Clear(); Add-Status $Body 'wait' 'מפעיל את מנוע Docker המובנה…' 'זה לוקח כמה שניות.'
 $script:WslPump={Pump}
 try{ if(-not (Start-WslEngine $InstallationRoot)){throw 'המנוע לא עלה בתוך דקה. פרטים ב-/var/log/dockerd.log בתוך סביבת OpenKritt.'} }finally{$script:WslPump={}}
 Show-Computer
}
function Install-BuiltinEngine{
 $terms="יותקן מנוע Docker מובנה, בלי Docker Desktop:`n`n•  סביבת Alpine Linux רשמית (קובץ של כ־3 MB מ־dl-cdn.alpinelinux.org). טביעת האצבע (SHA-256) שלו נבדקת מול הערך הקבוע בתוכנה.`n•  Docker Engine ו־Docker Compose מהמאגר החתום של Alpine. רישיון Apache-2.0, ללא מנוי.`n`nהסביבה נשמרת בתיקייה wsl-engine שליד התוכנה, אינה פתוחה לרשת, ומשתמשת במגבלת הזיכרון הקיימת של WSL. הסרה מלאה של התוכנה מוחקת גם אותה."
 if(-not (Ask $terms 'התקנת המנוע המובנה')){return}
 $Body.Controls.Clear(); Add-Status $Body 'wait' 'בודק את החיבור לאתר של Alpine…' 'בודקים מ־Windows אם הסינון מחליף את תעודת האבטחה.'
 Pump
 $probe=Invoke-HostProbe 'dl-cdn.alpinelinux.org'
 if($probe.stage -eq 'dns' -or $probe.stage -eq 'connect'){throw 'אין חיבור לאתר dl-cdn.alpinelinux.org (כתובת או רשת). בדקו את החיבור לאינטרנט ונסו שוב.'}
 if($probe.root -and $probe.rootOrigin -eq 'local' -and -not (Test-Path -LiteralPath (Join-Path $certificateFolder ($probe.root.Thumbprint+'.crt')))){
  # A filter or antivirus replaces the site's certificate. Linux inside WSL needs the same root, with the user's approval.
  $text=(Get-CertificateDescription $probe.root 'local' @('dl-cdn.alpinelinux.org'))+"`n`nהתעודה תותקן רק בתוך המנוע המובנה וברכיבי התוכנה. מאגר האישורים של Windows לא משתנה, ואימות האבטחה נשאר פעיל."
  if(-not (Ask $text 'אישור תעודת רשת')){throw 'בלי תעודת הרשת אי אפשר להוריד את רכיבי המנוע דרך הסינון. אפשר לבחור שוב ולאשר, או להשתמש ב־Docker Desktop.'}
  [void](Save-ApprovedCertificate $probe.root $certificateFolder)
 }
 $Body.Controls.Clear(); Add-Status $Body 'wait' 'מתקין את מנוע Docker המובנה…' 'מוריד ומאמת את Alpine ואת Docker. בדרך כלל פחות מדקה.'
 $script:WslPump={Pump}
 try{
  try{[void](Install-WslEngine $InstallationRoot)}
  catch{
   $message=$_.Exception.Message
   if($message -match '(?i)certificate|x509|ssl|tls'){throw 'הורדת רכיבי המנוע נכשלה בגלל תעודת אבטחה. כנראה שהסינון משתמש בתעודה שעדיין לא אושרה. עברו לשלב "רשת ותעודות" אחרי שהמנוע יותקן, או פנו לספק הסינון.'}
   if($message -match '(?i)418|403|blocked'){throw 'הסינון חוסם את מאגר החבילות של Alpine (dl-cdn.alpinelinux.org). בקשו מספק הסינון לפתוח אותו ונסו שוב.'}
   throw
  }
  if(-not (Start-WslEngine $InstallationRoot)){throw 'המנוע הותקן אבל לא עלה. פרטים ב-/var/log/dockerd.log בתוך סביבת OpenKritt.'}
 }finally{$script:WslPump={}}
 Show-Computer
}
function Start-DockerDesktop{
 $path=Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
 if(-not (Test-Path -LiteralPath $path)){throw 'Docker Desktop אינו מותקן.'}
 Start-Process -FilePath $path
 $Body.Controls.Clear(); Add-Status $Body 'wait' 'מפעיל את Docker…' 'ממתין עד שתי דקות. אם Docker מבקש לאשר תנאים, אשרו בחלון שלו.'
 $docker=Get-DockerPath; $until=(Get-Date).AddSeconds(120)
 while((Get-Date) -lt $until){$r=Invoke-Pumped $docker @('info','--format','{{.OSType}}') 10 {Pump}; if($r.Code -eq 0){break}; $t=Get-Date; while(((Get-Date)-$t).TotalSeconds -lt 3){Pump; Start-Sleep -Milliseconds 100}}
 Show-Computer
}
function Install-DockerDesktop{
 $terms="Docker Desktop הוא תוכנה של חברת Docker. הוא חינמי לשימוש אישי, ללימוד ולעסקים קטנים (פחות מ־250 עובדים וגם פחות מ־10 מיליון דולר הכנסה בשנה). ארגון גדול יותר צריך מנוי בתשלום.`n`nהמתקין יורד מהאתר הרשמי של Docker (כ־600 MB), והחתימה הדיגיטלית שלו נבדקת לפני הפעלה. את ההתקנה עצמה, הרשאות המנהל והסכמת התנאים אתם מאשרים בחלון של Docker.`n`nלהמשיך?"
 if(-not (Ask $terms 'התקנת Docker Desktop')){return}
 $downloads=Join-Path $InstallationRoot 'downloads'; [void][IO.Directory]::CreateDirectory($downloads)
 $file=Join-Path $downloads 'Docker-Desktop-Installer.exe'; $partial=$file+'.part'
 $Body.Controls.Clear(); Add-Paragraph 'מוריד את מתקין Docker Desktop הרשמי…' $F.Bold | Out-Null
 $bar=New-Object Windows.Forms.ProgressBar; $bar.Width=$Body.ClientSize.Width-24; $bar.Height=18; $bar.RightToLeftLayout=$true; $Body.Controls.Add($bar)
 $status=Add-Paragraph '' $F.Small $Palette.Muted 24
 [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
 $request=[Net.HttpWebRequest]::Create('https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'); $request.Timeout=30000; $request.ReadWriteTimeout=60000
 try{$response=$request.GetResponse()}catch{throw 'ההורדה מאתר Docker נכשלה. ייתכן שהסינון חוסם את desktop.docker.com, או שאין חיבור. אפשר להוריד ידנית מ־docker.com ולהתקין.'}
 try{
  $total=$response.ContentLength; $source=$response.GetResponseStream(); $output=[IO.File]::Create($partial)
  try{$buffer=New-Object byte[] 1048576; $done=0L
   while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){$output.Write($buffer,0,$read); $done+=$read; if($total -gt 0){$bar.Value=[Math]::Min(100,[int](100*$done/$total)); $status.Text=([math]::Round($done/1MB))+' מתוך '+([math]::Round($total/1MB))+' MB'}; Pump}
  }finally{$output.Dispose(); $source.Dispose()}
 }finally{$response.Dispose()}
 Move-Item -LiteralPath $partial -Destination $file -Force
 $signature=Get-AuthenticodeSignature -LiteralPath $file
 if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Docker Inc(,|$)'){Remove-Item -LiteralPath $file -Force; throw 'לא ניתן לאמת שהמתקין חתום על ידי Docker Inc. הקובץ נמחק ולא הופעל.'}
 Start-Process -FilePath $file
 $Body.Controls.Clear()
 Add-Status $Body 'ok' 'החתימה הדיגיטלית אומתה: Docker Inc' 'המתקין של Docker נפתח בחלון נפרד.'
 Add-Paragraph ("מה עושים עכשיו:`n1. בחלון של Docker השאירו מסומן 'Use WSL 2' ולחצו OK.`n2. אם Docker מבקש להפעיל מחדש את המחשב, הפעילו מחדש ופתחו שוב את Install.cmd. האשף יזכור שהתנאים כבר אושרו.`n3. פתחו את Docker Desktop, אשרו את התנאים שלו והמתינו עד שהוא פועל.`n4. חזרו לכאן ולחצו 'בדיקה חוזרת'.") | Out-Null
 Add-Link 'בדיקה חוזרת' {Show-Computer}
}

# ---------- page 3: network and certificates ----------
function Show-Network{
 Set-Page 2 'רשת ותעודות אבטחה' 'בודקים מתוך Docker את האתרים שמהם יורדים רכיבי התוכנה, בדיוק כמו בבנייה עצמה.'
 Add-Status $Body 'wait' 'בודק חיבורים…' 'בפעם הראשונה תורד תמונת בדיקה קטנה (כ־50 MB). זה עשוי לקחת דקה.'
 $n=Get-NetworkState -Docker $script:System.DockerPath -CertificateFolder $certificateFolder -Pump {Pump}; $script:Network=$n
 $Body.Controls.Clear()
 try{[IO.File]::WriteAllText($reportFile,(Get-ReportText $script:System $n),(New-Object Text.UTF8Encoding($true)))}catch{}
 if(-not $n.Probe.Ok){
  Add-Status $Body 'bad' 'לא ניתן לבדוק את הרשת' ((Get-ClassText $n.Probe.Kind)+' '+$n.Probe.Detail)
  if($n.Probe.Kind -eq 'blocked'){Add-Paragraph 'בקשו מספק הסינון לפתוח את Docker Hub: registry-1.docker.io ו־production.cloudflare.docker.com.' | Out-Null}
  if($n.Probe.Kind -eq 'certificate'){Add-Paragraph 'Docker עצמו אינו מכיר את תעודת הרשת. התקינו את תעודת הסינון ב־Windows לפי ההוראות של ספק הסינון, והפעילו מחדש את Docker Desktop.' | Out-Null}
  Add-Link 'בדיקה חוזרת' {Show-Network}; return
 }
 # The action that fixes most problems comes first; the per-site list follows.
 foreach($candidate in $n.Candidates){
  $name=$candidate.Root.GetNameInfo('SimpleName',$false)
  Add-Status $Body 'info' ('נמצאה תעודת הרשת: '+$name) ('הסינון או האנטי־וירוס שלכם משתמשים בה, ו־Windows כבר סומך עליה. היא חסרה ל־'+$candidate.Hosts.Count+' אתרים ברשימה למטה.') 'הצגה ואישור' ([scriptblock]::Create('Approve-Candidate "'+$candidate.Root.Thumbprint+'"'))
 }
 $problems=@($n.Rows|Where-Object {$_.Class -ne 'ok'}).Count
 $okCount=$n.Rows.Count-$problems
 Add-Paragraph ($(if($problems){$okCount.ToString()+' מתוך '+$n.Rows.Count+' אתרים תקינים.'}else{'כל '+$n.Rows.Count+' האתרים תקינים. אפשר להמשיך.'})) $F.Bold | Out-Null
 foreach($row in $n.Rows){
  $state=switch($row.Class){'ok'{'ok'} 'maybe-blocked'{'warn'} 'certificate'{if($row.Root){'warn'}else{'bad'}} default{'bad'}}
  $detail=switch($row.Class){'ok'{$row.Purpose} 'certificate'{if($row.Root){$row.Purpose+' — צריך את תעודת הרשת שלמעלה.'}else{$row.Purpose+' — '+(Get-ClassText 'certificate')}} default{$row.Purpose+' — '+(Get-ClassText $row.Class)}}
  Add-Status $Body $state $row.Host $detail
 }
 if($n.UnknownRoot){Add-Status $Body 'warn' 'תעודה לא מוכרת' 'Windows אינו מכיר את הרשות שחתמה על חלק מהחיבורים. בקשו מספק הסינון את קובץ התעודה.' 'בחירת קובץ תעודה' {Select-CertificateFile}}
 elseif(-not $n.Candidates.Count){Add-Link 'יש לי קובץ תעודה מספק הסינון' {Select-CertificateFile}}
 Add-Link 'בדיקה חוזרת' {Show-Network}
 if($problems -eq 0){$script:CanNext=$true}
 else{
  $force=New-Object Windows.Forms.CheckBox; $force.Text='להמשיך בכל זאת (ההתקנה עלולה להיכשל)'; $force.AutoSize=$true; $force.ForeColor=$Palette.Muted
  $force.Add_CheckedChanged({param($s,$e) $script:CanNext=$s.Checked; Update-Navigation}); $Body.Controls.Add($force)
 }
 Update-Navigation
}
function Approve-Candidate([string]$thumbprint){
 $candidate=@($script:Network.Candidates|Where-Object {$_.Root.Thumbprint -eq $thumbprint})[0]
 $text=(Get-CertificateDescription $candidate.Root $candidate.Origin $candidate.Hosts)+"`n`nאם תאשרו: התעודה תישמר בתיקיית certificates של ההתקנה הזאת ותיכלל רק ברכיבי התוכנה. מאגר האמון של Windows לא ישתנה, ובדיקת התעודות נשארת פעילה.`n`nאשרו רק אם אתם מזהים את השם (למשל NetFree או האנטי־וירוס שלכם). להוסיף את התעודה?"
 if(Ask $text 'אישור תעודת רשת'){[void](Save-ApprovedCertificate $candidate.Root $certificateFolder); Show-Network}
}
function Select-CertificateFile{
 $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='תעודת רשות (*.crt;*.cer;*.pem)|*.crt;*.cer;*.pem'
 try{
  if($dialog.ShowDialog($script:Form) -ne 'OK'){return}
  $text=[IO.File]::ReadAllText($dialog.FileName)
  $list=if($text -match 'BEGIN CERTIFICATE'){@(ConvertFrom-PemText $text)}else{if($text -match 'PRIVATE KEY'){throw 'הקובץ מכיל מפתח פרטי.'};@(New-Object Security.Cryptography.X509Certificates.X509Certificate2(,[IO.File]::ReadAllBytes($dialog.FileName)))}
  if($list.Count -ne 1){throw 'בחרו קובץ שמכיל תעודה אחת בלבד.'}
  $certificate=$list[0]; $reason=Test-PublicCaCertificate $certificate; if($reason){throw $reason}
  if($certificate.Subject -ne $certificate.Issuer){throw 'זו תעודת ביניים. בחרו את תעודת הרשות העליונה (Root).'}
  # The file must complete a chain that actually failed in the network check.
  $hosts=@(); if($script:Network -and $script:Network.Probe.Ok){foreach($r in $script:Network.Probe.Results){if((Get-ProbeClass $r) -eq 'certificate' -and (Find-TrustedRootForChain -ChainPems @($r.chain|ForEach-Object{$_.pem}) -AdditionalRoots @($certificate))){$hosts+=$r.host}}}
  $warning=if($hosts.Count){''}else{"`n`nשימו לב: התעודה אינה מתאימה לאף חיבור שנכשל בבדיקה. כנראה שזו לא התעודה הנכונה."}
  $text=(Get-CertificateDescription $certificate (Get-RootOrigin $certificate) $(if($hosts.Count){$hosts}else{@('לא אומת')}))+$warning+"`n`nהתעודה תיכלל רק ברכיבי התוכנה. מאגר האמון של Windows לא ישתנה. להוסיף?"
  if(Ask $text 'אישור תעודה מקובץ'){[void](Save-ApprovedCertificate $certificate $certificateFolder); Show-Network}
 }finally{$dialog.Dispose()}
}

# ---------- page 4: installation ----------
function Show-Install{
 Set-Page 3 'התקנה' 'בחרו אם להוסיף כלי AI אופציונליים, ולחצו "התחלת ההתקנה". אפשר להוסיף אותם גם אחר כך מ"בדיקה ותיקון".'
 Add-Paragraph 'רכיבים אופציונליים' $F.Bold | Out-Null
 Add-Paragraph 'Codex ו־Claude Code מותקנים תמיד. Cursor ו־Grok הם כלים של חברות אחרות, עם תנאי שימוש משלהן, ולכן הם כבויים אם לא בחרתם בהם. הם נחוצים רק אם אתם מתכוונים לחבר חשבון שלהם.' $F.Body $Palette.Muted | Out-Null
 $script:VendorChecks=@{}
 foreach($status in Get-VendorStatus -ApplicationRoot $applicationRoot -InstallationRoot $InstallationRoot){
  $pin=$status.Pin
  if($status.Found -and -not $status.Ready){ try{ [void](Add-VendorFile -Path $status.Found -ApplicationRoot $applicationRoot); $status.Ready=$true }catch{} }
  $box=New-Object Windows.Forms.CheckBox; $box.Text=('להתקין גם '+$pin.Name+' (גרסה '+$pin.Version+')'); $box.Font=$F.Bold; $box.AutoSize=$true; $box.Margin=New-Object Windows.Forms.Padding(0,8,0,0)
  $box.Checked=($pin.Key -eq 'cursor' -and $status.Ready); $Body.Controls.Add($box); $script:VendorChecks[$pin.Key]=$box
  $source=if($status.Ready){'✓ נמצא קובץ מאומת במחשב, זהה בדיוק לגרסה הרשמית. ההתקנה לא תוריד אותו שוב.'}elseif($pin.Key -eq 'grok'){'יורד מ־x.ai. ברשת מסוננת (למשל נטפרי) האתר עשוי להיות חסום: בקשו לפתוח את x.ai/cli, או הוסיפו קובץ שהורדתם ברשת אחרת.'}else{'יורד מהאתר הרשמי של Cursor. ברשת מסוננת נדרשת תעודת הרשת מהשלב הקודם.'}
  Add-Paragraph $source $F.Small $(if($status.Ready){$Palette.Ok}else{$Palette.Muted}) | Out-Null
  Add-Link ('תנאי השימוש של '+$pin.Name) ([scriptblock]::Create('Start-Process "'+$pin.Terms+'"'))
 }
 Add-Link 'יש לי קובץ שהורדתי (Cursor או Grok)' {
  $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Title='בחירת קובץ Cursor או Grok שהורדתם'
  try{ if($dialog.ShowDialog($script:Form) -eq 'OK'){ $pin=Add-VendorFile -Path $dialog.FileName -ApplicationRoot $applicationRoot; Show-Message ('הקובץ זהה בדיוק לגרסה הרשמית של '+$pin.Name+' ונשמר להתקנה.') 'הקובץ אומת'; Show-Install } }finally{ $dialog.Dispose() }
 }
 $start=New-Button 'התחלת ההתקנה' -Primary; $start.Margin=New-Object Windows.Forms.Padding(0,16,0,0)
 $start.Add_Click({ Invoke-Safely { Run-Install } }); $Body.Controls.Add($start)
 Update-Navigation
}

function Run-Install{
 $includeCursor=$script:VendorChecks['cursor'].Checked; $includeGrok=$script:VendorChecks['grok'].Checked
 foreach($pin in Get-VendorPins $applicationRoot){
  if(($pin.Key -eq 'cursor' -and $includeCursor) -or ($pin.Key -eq 'grok' -and $includeGrok)){
   if(-not (Ask ($pin.Name+' הוא כלי של חברה אחרת, ואינו חלק מהתוכנה. השימוש בו כפוף לתנאים שלה ולחשבון שלכם. להמשיך ולהתקין אותו?') ('התקנת '+$pin.Name))){ return }
  }
 }
 Set-Page 3 'התקנה' 'רכיבי התוכנה נבנים עכשיו בתוך Docker. אפשר להמשיך לעבוד במחשב; אל תכבו אותו עד הסיום.'
 $script:Phases=@('db','backend','engine','frontend','executor-view')
 $names=@{db='מסד הנתונים';backend='שרת התוכנה';engine='מנוע הבדיקות';frontend='ממשק המשתמש';'executor-view'='שירות חיבור החשבונות'}
 $bar=New-Object Windows.Forms.ProgressBar; $bar.Width=$Body.ClientSize.Width-24; $bar.Height=20; $bar.Maximum=$Phases.Count*10; $bar.RightToLeftLayout=$true; $Body.Controls.Add($bar)
 $phase=Add-Paragraph 'מתחיל…' $F.Bold $Palette.Text 26
 $activity=Add-Paragraph '' $F.Small $Palette.Muted 40
 $details=New-Object Windows.Forms.TextBox; $details.Multiline=$true; $details.ReadOnly=$true; $details.ScrollBars='Vertical'; $details.Width=$Body.ClientSize.Width-24; $details.Height=230; $details.RightToLeft='No'; $details.Font=New-Object Drawing.Font('Consolas',8.5); $details.Visible=$false; $details.BackColor=$Palette.Side; $details.BorderStyle='None'
 $toggle=New-Object Windows.Forms.LinkLabel; $toggle.Text='הצגת פרטים טכניים'; $toggle.AutoSize=$true; $toggle.LinkColor=$Palette.Accent; $toggle.Tag=$details
 $toggle.Add_LinkClicked({param($s,$e) $s.Tag.Visible=-not $s.Tag.Visible; $s.Text=$(if($s.Tag.Visible){'הסתרת פרטים טכניים'}else{'הצגת פרטים טכניים'})})
 $Body.Controls.Add($toggle); $Body.Controls.Add($details)
 $script:Installing=$true; Update-Navigation
 $script:Form.Add_FormClosing({param($s,$e) if($script:Installing){$e.Cancel=-not (Ask 'ההתקנה עדיין רצה. לסגור בכל זאת? אפשר להמשיך אחר כך מאותה נקודה.' 'סגירה')}})
 $installer=Join-Path $InstallationRoot 'install.ps1'; if(-not (Test-Path -LiteralPath $installer)){$installer=Join-Path $applicationRoot 'windows\install.ps1'}
 $command="[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$ErrorActionPreference='Stop'; try{ & '"+$installer.Replace("'","''")+"' -TargetRoot '"+$InstallationRoot.Replace("'","''")+"' -AcceptLicense -NoStart -DockerEngine '"+$script:System.EngineMode+"' -IncludeCursor:$"+$(if($includeCursor){'true'}else{'false'})+" -IncludeGrok:$"+$(if($includeGrok){'true'}else{'false'})+" *>&1 | ForEach-Object { [Console]::Out.WriteLine([string]`$_) }; exit 0 }catch{ [Console]::Out.WriteLine('INSTALL-ERROR:'+`$_.Exception.Message); exit 1 }"
 $p=New-Object Diagnostics.Process; $p.StartInfo.FileName='powershell.exe'
 $p.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
 $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true; $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true; $p.StartInfo.StandardOutputEncoding=[Text.Encoding]::UTF8
 [void]$p.Start(); $errors=$p.StandardError.ReadToEndAsync(); $pending=$p.StandardOutput.ReadLineAsync(); $failure=''; $index=0
 while($true){
  if($pending.IsCompleted){
   $line=$pending.Result; if($null -eq $line){break}
   if($line -like 'INSTALL-ERROR:*'){$failure=$line.Substring(14)}
   elseif($line -match '^(Building|Downloading) (\S+)\.\.\.$'){$verb=$(if($Matches[1] -eq 'Downloading'){'מוריד רכיב מוכן: '}else{'בונה: '}); $index=[array]::IndexOf($script:Phases,$Matches[2]); if($index -ge 0){$bar.Value=$index*10; $phase.Text=$verb+$names[$Matches[2]]+' ('+($index+1)+' מתוך '+$Phases.Count+')'}}
   elseif($line -match '^#\d+ \[[^\]]+\] (.+)$'){$activity.Text=$Matches[1].Substring(0,[Math]::Min(140,$Matches[1].Length)); if($bar.Value -lt $index*10+9){$bar.Value++}}
   if($details.TextLength -gt 200000){$details.Text=$details.Text.Substring(100000)}
   $details.AppendText($line+[Environment]::NewLine); $pending=$p.StandardOutput.ReadLineAsync()
  }else{Pump; Start-Sleep -Milliseconds 40}
 }
 $p.WaitForExit(); $code=$p.ExitCode; $p.Dispose(); $script:Installing=$false
 if($code -eq 0){$bar.Value=$bar.Maximum; $script:Installed=$true; Show-Finish; return}
 if(-not $failure){$failure=($errors.Result -split "`n"|Where-Object {$_.Trim()}|Select-Object -First 3) -join ' '}
 $Body.Controls.Clear()
 Add-Status $Body 'bad' 'ההתקנה נעצרה' $failure
 Add-Paragraph 'אפשר לתקן ולנסות שוב. שלבים שכבר הסתיימו נשמרו, ולכן הניסיון הבא יהיה מהיר יותר.' | Out-Null
 Add-Link 'חזרה לבדיקת הרשת והתעודות' {Show-Network}
 Add-Link 'ניסיון חוזר' {Run-Install}
 Add-Link 'פתיחת יומן ההתקנה' {Open-File $installLog}
 Update-Navigation
}

# ---------- page 5: done ----------
function Show-Finish{
 Set-Page 4 'ההתקנה הושלמה' 'התוכנה מוכנה. אחרי הפתיחה, היכנסו ל"חשבונות" וחברו חשבון AI שלכם.'
 Add-Status $Body 'ok' 'רכיבי התוכנה נבנו' 'הנתונים נשמרים בתיקיית ההתקנה ובתוך Docker.'
 $shortcuts=New-Object Windows.Forms.CheckBox; $shortcuts.Text='יצירת קיצורי דרך בשולחן העבודה (הפעלה, עצירה, ניהול)'; $shortcuts.Checked=$true; $shortcuts.AutoSize=$true; $Body.Controls.Add($shortcuts); $script:ShortcutsBox=$shortcuts
 $open=New-Object Windows.Forms.CheckBox; $open.Text='פתיחת התוכנה עכשיו'; $open.Checked=$true; $open.AutoSize=$true; $Body.Controls.Add($open); $script:OpenBox=$open
 Add-Paragraph 'בהמשך: Start.cmd מפעיל, Stop.cmd עוצר, ו־Manage.cmd פותח חלון ניהול עם בדיקת מצב והסרה. אין הפעלה אוטומטית עם Windows.' $F.Small $Palette.Muted | Out-Null
 $script:CanNext=$true; Update-Navigation
}
function New-Shortcuts{
 $folder=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Open-Kritt'; [void][IO.Directory]::CreateDirectory($folder)
 $shell=New-Object -ComObject WScript.Shell; $manage=Join-Path $InstallationRoot 'manage.ps1'
 foreach($item in @(@('הפעלה','Start'),@('עצירה','Stop'),@('ניהול והסרה','Menu'))){
  $link=$shell.CreateShortcut((Join-Path $folder ($item[0]+'.lnk'))); $link.TargetPath='powershell.exe'
  $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$manage+'" -Action '+$item[1]; $link.WorkingDirectory=$InstallationRoot; $link.Save()
 }
 $link=$shell.CreateShortcut((Join-Path $folder 'בדיקה ותיקון.lnk')); $link.TargetPath='powershell.exe'; $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $InstallationRoot 'prepare.ps1')+'" -Mode Repair'; $link.WorkingDirectory=$InstallationRoot; $link.Save()
}

$Next.Add_Click({
 switch($script:Page){
  0{Invoke-Safely {Show-Computer}}
  1{Invoke-Safely {Show-Network}}
  2{Invoke-Safely {Show-Install}}
  4{
   try{if($script:ShortcutsBox.Checked){New-Shortcuts}}catch{Show-Message ('קיצורי הדרך לא נוצרו: '+$_.Exception.Message) 'סריקת אבטחה' 'Warning'}
   if($script:OpenBox.Checked){Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $InstallationRoot 'manage.ps1')+'" -Action Start')}
   $script:Form.Close()
  }
 }
})
$Back.Add_Click({switch($script:Page){1{Show-Welcome} 2{Invoke-Safely {Show-Computer}} 3{Invoke-Safely {Show-Network}}}})
$Cancel.Add_Click({$script:Form.Close()})
$Form.Add_Shown({if($Mode -eq 'Repair'){Invoke-Safely {Show-Computer}}else{Show-Welcome}})
[void]$Form.ShowDialog(); $Form.Dispose()
