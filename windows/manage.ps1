[CmdletBinding()]
param([ValidateSet('Start','Stop','Status','Uninstall','Repair','Menu')][string]$Action='Menu')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$Root=$PSScriptRoot; $App=Join-Path $Root 'app'; $Log=Join-Path $Root 'manager.log'
$Docker=Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
if(Get-Command docker.exe -ErrorAction SilentlyContinue){$Docker=(Get-Command docker.exe).Source}
$script:Busy=$false
function Note([string]$s) { $script:LastMessage=$s; Add-Content -LiteralPath $Log -Value "$(Get-Date -Format s) $s" -Encoding UTF8; if($script:StatusLabel){$script:StatusLabel.Text=$s}; [Windows.Forms.Application]::DoEvents() }
function Run-Docker([string[]]$Arguments,[int]$Timeout=45,[switch]$AllowFailure) {
 $p=New-Object Diagnostics.Process; $p.StartInfo.FileName=$Docker
 $p.StartInfo.Arguments=($Arguments | ForEach-Object { '"'+($_ -replace '"','\"')+'"' }) -join ' '
 $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
 $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
 $p.StartInfo.WorkingDirectory=$Root
 [void]$p.Start(); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync(); $timer=[Diagnostics.Stopwatch]::StartNew()
 while(-not $p.HasExited){ [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100; if($timer.Elapsed.TotalSeconds -gt $Timeout){$p.Kill(); throw 'הפעולה חרגה מזמן ההמתנה. ניתן לבדוק מצב ולנסות שוב.'} }
 $p.WaitForExit(); $result=[pscustomobject]@{Code=$p.ExitCode; Out=$o.Result; Err=$e.Result}; $p.Dispose()
 if($result.Code -ne 0 -and -not $AllowFailure){ throw 'פקודת Docker נכשלה. פרטים נוספים זמינים ב-Docker Desktop; לא נשמרו סודות ביומן.' }; return $result
}
function Compose([string[]]$Arguments,[int]$Timeout=180){Run-Docker (@('compose','--project-directory',$App,'-p','openkritt-he')+$Arguments) $Timeout}
function Engine-Ready { if(-not (Test-Path -LiteralPath $Docker)){return $false}; try{return (Run-Docker @('info','--format','{{.ServerVersion}}') 8 -AllowFailure).Code -eq 0}catch{return $false} }
function Pause-Pump([int]$Seconds){$until=(Get-Date).AddSeconds($Seconds); while((Get-Date) -lt $until){[Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100}}
function Wait-Engine { $until=(Get-Date).AddSeconds(90); do {if(Engine-Ready){return $true}; Pause-Pump 2}while((Get-Date) -lt $until); return $false }
function Repair-StaleRuntime {
 if(Engine-Ready){return $false}
 if(Get-Process -Name 'com.docker.backend' -ErrorAction SilentlyContinue){return $false}
 $base=Join-Path $env:LOCALAPPDATA 'Docker'
 $logs=Get-ChildItem -LiteralPath "$base\log\host" -Filter 'com.docker.backend*.log' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt (Get-Date).AddMinutes(-10)
 $evidence=$false
 foreach($f in $logs){$tail=Get-Content -LiteralPath $f.FullName -Tail 150 -ErrorAction SilentlyContinue; if(($tail -join "`n") -match '(?is)(dockerInference|engine\.sock).{0,250}(bind|already|in use|exist|cannot be accessed)|(?:bind|already|in use|exist).{0,250}(dockerInference|engine\.sock)'){$evidence=$true}}
 if(-not $evidence){return $false}
 foreach($leaf in @('run','docker-secrets-engine')){
  $target=if($leaf -eq 'run'){Join-Path $base $leaf}else{Join-Path $env:LOCALAPPDATA 'docker-secrets-engine'}
  if(Test-Path -LiteralPath $target){
   $item=Get-Item -LiteralPath $target -Force
   if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.FullName -ne [IO.Path]::GetFullPath($target)){throw 'תיקיית זמן הריצה אינה במיקום הצפוי.'}
   if((Engine-Ready) -or (Get-Process -Name 'com.docker.backend' -ErrorAction SilentlyContinue)){throw 'Docker התחיל לפעול; התיקון בוטל.'}
   Rename-Item -LiteralPath $target -NewName ($leaf+'.backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
  }
 }
 Note 'קובצי זמן ריצה ישנים הועברו לגיבוי. מפעיל מחדש את Docker.'; return $true
}
$DockerDesktop=Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
function Ensure-Engine {
 if(Engine-Ready){return}
 if(-not (Test-Path -LiteralPath $DockerDesktop)){throw 'Docker Desktop אינו מותקן במחשב. פתחו את "בדיקה ותיקון" (Prepare.cmd): האשף יוריד את המתקין הרשמי ויסביר מה לעשות.'}
 Note 'מפעיל את Docker Desktop וממתין עד 90 שניות...'
 Start-Process -FilePath $DockerDesktop -WindowStyle Hidden
 if(Wait-Engine){return}
 if(Repair-StaleRuntime){Start-Process -FilePath $DockerDesktop -WindowStyle Hidden; if(Wait-Engine){return}}
 throw 'Docker אינו זמין. פתחו Docker Desktop ובדקו את הודעת השגיאה. שירות פעיל לא נעצר על ידי מנהל זה.'
}
function Owned-Runners {
 $ids=(Run-Docker @('ps','-aq','--filter','label=open-kritt.scan-runner=1')).Out -split '\s+' | Where-Object {$_ -match '^[a-f0-9]{12,64}$'}
 foreach($id in $ids){
  $mounts=(Run-Docker @('inspect','--format','{{json .Mounts}}',$id)).Out | ConvertFrom-Json
  $owned=$false
  $driveLetter=$App.Substring(0,1).ToLowerInvariant(); $appRelative=$App.Substring(3).Replace('\','/').ToLowerInvariant()
  $prefixes=@($App.Replace('\','/').ToLowerInvariant()+'/.data/','/run/desktop/mnt/host/'+$driveLetter+'/'+$appRelative+'/.data/','/host_mnt/'+$driveLetter+'/'+$appRelative+'/.data/')
  foreach($m in $mounts){$source=($m.Source -replace '\\','/').ToLowerInvariant(); foreach($prefix in $prefixes){if($source.StartsWith($prefix)){$owned=$true}}}
  if($owned){$id}
 }
}
# All installations share the Docker project name and container names, so every
# action first checks that the running containers belong to THIS folder.
function Get-CanonicalPath([string]$Path){ if([string]::IsNullOrWhiteSpace($Path)){return ''}
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\'); $parts=$full.Split('\'); $current=$parts[0]+'\'
 foreach($part in $parts[1..($parts.Length-1)]){
  $current=Join-Path $current $part
  $item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
  if($item -and $item.LinkType -in @('Junction','SymbolicLink') -and $item.Target){$current=[IO.Path]::GetFullPath(@($item.Target)[0])}
 }
 return $current.TrimEnd('\')
}
function Test-SamePath([string]$A,[string]$B){ return (Get-CanonicalPath $A) -ieq (Get-CanonicalPath $B) }
function Get-RunningInstallation {
 # Folder of the installation whose containers exist now, or $null when there are none.
 $ids=(Run-Docker @('ps','-aq','--filter','label=com.docker.compose.project=openkritt-he','--filter','label=com.docker.compose.project.working_dir') 20 -AllowFailure).Out -split '\s+' | Where-Object {$_ -match '^[a-f0-9]{12,64}$'}
 if(-not $ids){return $null}
 # JSON output avoids quoting a label name through the command line.
 $labels=(Run-Docker @('inspect','--format','{{json .Config.Labels}}',@($ids)[0]) 20 -AllowFailure).Out
 try{$folder=($labels | ConvertFrom-Json).'com.docker.compose.project.working_dir'}catch{$folder=$null}
 if($folder){return [string]$folder}; return $null
}

function Stop-App {
 $maintenancePid=Join-Path $Root '.maintenance/server.pid'
 if(Test-Path -LiteralPath $maintenancePid){
  $pidText=(Get-Content -LiteralPath $maintenancePid -Raw).Trim()
  if($pidText -match '^\d+$'){$process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$pidText); if($process.Name -eq 'powershell.exe' -and $process.CommandLine -like '*maintenance-agent.ps1*' -and $process.CommandLine -notlike '*-Mode Worker*'){Stop-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue}}
 }
 if(-not (Engine-Ready)){Note 'Docker אינו פעיל; היישום כבר כבוי.'; return}
 $owner=Get-RunningInstallation
 if($owner -and -not (Test-SamePath $owner $App)){Note ('התוכנה שפועלת שייכת להתקנה אחרת ('+$owner+'), ולכן לא נעצרה.'); return}
 Note 'עוצר את Open-Kritt ושומר את הנתונים...'
 # Stop coordinator first so no new jobs can be created during runner cleanup.
 [void](Compose @('stop','engine'))
 foreach($id in @(Owned-Runners)){[void](Run-Docker @('stop','--time','20',$id) 40)}
 [void](Compose @('stop'))
 Note 'Open-Kritt נעצר. הנתונים נשמרו ושאר שירותי Docker ממשיכים לפעול.'
}

function Update-PortablePaths {
 $path=Join-Path $App '.env'
 if(-not (Test-Path -LiteralPath $path)){throw 'קובץ ההגדרות חסר. העתיקו את תיקיית ההתקנה המלאה.'}
 $drive=$App.Substring(0,1).ToLowerInvariant()
 $relative=$App.Substring(3).Replace('\','/')
 $dockerPath='/run/desktop/mnt/host/'+$drive+'/'+$relative+'/.data/engine'
 $text=[IO.File]::ReadAllText($path)
 $text=[regex]::Replace($text,'(?m)^ENGINE_DOCKER_DATA_DIR_HOST=.*\r?\n?','')
 $text+=[Environment]::NewLine+'ENGINE_DOCKER_DATA_DIR_HOST="'+$dockerPath+'"'+[Environment]::NewLine
 [IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($false)))
}

function Start-App {
 $maintenance=Join-Path $Root 'maintenance-agent.ps1'
 if(Test-Path -LiteralPath $maintenance){Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$maintenance+'"') -WindowStyle Hidden}
 Update-PortablePaths
 if(-not (Test-Path -LiteralPath "$App\docker-compose.yml")){throw 'תיקיית היישום חסרה. ייתכן שהיישום הוסר.'}
 Ensure-Engine
 $owner=Get-RunningInstallation
 if($owner -and -not (Test-SamePath $owner $App)){throw ('במחשב קיימת התקנה אחרת של התוכנה ('+$owner+'). עצרו אותה מהקיצור שלה לפני הפעלת ההתקנה הזאת.')}
 Note 'מפעיל את Open-Kritt...'; [void](Compose @('up','-d','--no-build') 240)
 $until=(Get-Date).AddSeconds(120)
 do { $ok=$true; foreach($url in @('http://localhost:3002/api/health','http://localhost:5173')){try{[void](Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 3)}catch{$ok=$false}}; if($ok){Note 'Open-Kritt מוכן. הדפדפן נפתח.'; Start-Process 'http://localhost:5173'; return}; Pause-Pump 2 }while((Get-Date) -lt $until)
 throw 'השירותים הופעלו, אך בדיקת הזמינות טרם הצליחה. בדקו מצב בעוד דקה.'
}
function App-Status {
 if(-not (Engine-Ready)){Note 'Docker אינו פעיל.'; return}
 $r=Run-Docker @('ps','-a','--filter','label=com.docker.compose.project=openkritt-he','--format','{{.Names}}: {{.Status}}')
 $message=if($r.Out.Trim()){$r.Out.Trim()}else{'אין שירותי Open-Kritt מותקנים.'}
 Note $message
}
function Assert-AppTree {
 $full=[IO.Path]::GetFullPath($App)
 if($full -ne (Join-Path $Root 'app')){throw 'נתיב ההסרה אינו בטוח.'}
 foreach($ancestor in @([IO.Path]::GetPathRoot($App),$Root,$App)){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'נתיב ההסרה מכיל קישור; ההסרה נעצרה.'}}
 # Walk without following reparse points; reject before any recursive removal.
 $queue=New-Object 'System.Collections.Generic.Queue[string]'; $queue.Enqueue($App)
 while($queue.Count){$dir=$queue.Dequeue(); foreach($item in Get-ChildItem -LiteralPath $dir -Force){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'בתיקיית היישום נמצא קישור. ההסרה נעצרה לשמירת קבצים חיצוניים.'}; if($item.PSIsContainer){$queue.Enqueue($item.FullName)}}}
}
function Uninstall-App {
 $choice=[Windows.Forms.MessageBox]::Show("להסיר את Open-Kritt?`n`nכן = להסיר ולשמור גיבוי של הנתונים ופרטי ההתחברות.`nלא = להסיר ולמחוק את נתוני היישום ופרטי ההתחברות.`nביטול = לא לבצע שינוי.",'הסרת Open-Kritt','YesNoCancel','Warning')
 if($choice -eq 'Cancel'){return}; $delete=$choice -eq 'No'
 if($delete -and [Windows.Forms.MessageBox]::Show('אישור אחרון: למחוק לצמיתות את נתוני Open-Kritt?','מחיקה לצמיתות','YesNo','Warning') -ne 'Yes'){return}
 Assert-AppTree
 if(-not (Engine-Ready)){throw 'יש להפעיל Docker לפני הסרה כדי להסיר רק את משאבי היישום באופן מסודר.'}
 $owner=Get-RunningInstallation
 if($owner -and -not (Test-SamePath $owner $App)){throw ('השירותים הפועלים שייכים להתקנה אחרת ('+$owner+'). ההסרה של ההתקנה הזאת לא תיגע בהם; הסירו את הקבצים בלבד או הסירו קודם את ההתקנה האחרת.')}
 Stop-App
 foreach($id in @(Owned-Runners)){[void](Run-Docker @('rm','-v',$id))}
 $anonymous=@(); $ids=(Run-Docker @('ps','-aq','--filter','label=com.docker.compose.project=openkritt-he')).Out -split '\s+' | Where-Object {$_ -match '^[a-f0-9]{12,64}$'}
 foreach($id in $ids){$mounts=(Run-Docker @('inspect','--format','{{json .Mounts}}',$id)).Out | ConvertFrom-Json; foreach($m in $mounts){if($m.Type -eq 'volume' -and $m.Name -match '^[a-f0-9]{64}$'){$anonymous+=$m.Name}}}
 if($delete){[void](Compose @('down','--volumes'))}else{[void](Compose @('down'))}
 foreach($v in $anonymous | Select-Object -Unique){[void](Run-Docker @('volume','rm',$v) 30 -AllowFailure)}
 Assert-AppTree
 if($delete){Remove-Item -LiteralPath $App -Recurse -Force; Note 'היישום ונתוניו הוסרו. תמונות Docker משותפות לא נמחקו.'}else{$backup='app.backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'); Rename-Item -LiteralPath $App -NewName $backup; Note "היישום הוסר. הנתונים ופרטי ההתחברות נשמרו ב-$Root\$backup. יש לשמור על הגיבוי באופן פרטי."}
 $shortcutDir=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Open-Kritt'
 foreach($name in @('הפעלה.lnk','עצירה.lnk','ניהול והסרה.lnk','בדיקה ותיקון.lnk','תיקיית הפרויקטים לבדיקה.lnk')){$p=Join-Path $shortcutDir $name; if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force}}
}
function Open-Repair {
 $wizard=Join-Path $Root 'prepare.ps1'; if(-not (Test-Path -LiteralPath $wizard)){$wizard=Join-Path $App 'windows\prepare.ps1'}
 Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$wizard+'" -InstallationRoot "'+$Root+'" -Mode Repair')
 Note 'אשף הבדיקה והתיקון נפתח בחלון נפרד.'
}
function Do-Action([string]$Name){
 if($script:Busy){return}; $script:Busy=$true
 try{switch($Name){Start{Start-App}; Stop{Stop-App}; Status{App-Status}; Uninstall{Uninstall-App}; Repair{Open-Repair}}}catch{Note ('שגיאה: '+$_.Exception.Message); [void][Windows.Forms.MessageBox]::Show($_.Exception.Message+"`n`nיומן: $Log",'Open-Kritt','OK','Error')}finally{$script:Busy=$false}
}
$created=$false; $mutex=New-Object Threading.Mutex($true,'Local\OpenKrittHebrewManager',[ref]$created)
if(-not $created){[void][Windows.Forms.MessageBox]::Show('חלון הניהול כבר פתוח. עברו לחלון הקיים.','Open-Kritt'); $mutex.Dispose(); exit}
try{
 if($Action -ne 'Menu'){Do-Action $Action; if($Action -eq 'Status'){[void][Windows.Forms.MessageBox]::Show($script:LastMessage,'Open-Kritt')}; return}
 $form=New-Object Windows.Forms.Form; $form.Text='סריקת אבטחה — ניהול'; $form.ClientSize=New-Object Drawing.Size(640,470); $form.StartPosition='CenterScreen'; $form.RightToLeft='Yes'; $form.RightToLeftLayout=$true; $form.Font=New-Object Drawing.Font('Segoe UI',10); $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false; $form.BackColor=[Drawing.Color]::White
 $heading=New-Object Windows.Forms.Label; $heading.Text='סריקת אבטחה — הפעלה וניהול'; $heading.Font=New-Object Drawing.Font('Segoe UI Semibold',15); $heading.SetBounds(24,16,590,34); $form.Controls.Add($heading)
 $items=@(
  @('הפעלה','Start','מפעיל את Docker ואת התוכנה ופותח את הדפדפן.'),
  @('עצירה','Stop','עוצר רק את התוכנה. הנתונים נשמרים ושאר תוכנות Docker ממשיכות לפעול.'),
  @('בדיקת מצב','Status','מציג אילו רכיבים פועלים כרגע.'),
  @('בדיקה ותיקון','Repair','פותח את האשף: בדיקת Docker, רשת ותעודות ובנייה מחדש.'),
  @('הסרה','Uninstall','מסיר את התוכנה. אפשר לבחור לשמור גיבוי של הנתונים.'))
 for($i=0;$i -lt $items.Count;$i++){
  $y=64+$i*48
  $b=New-Object Windows.Forms.Button; $b.Text=$items[$i][0]; $b.Tag=$items[$i][1]; $b.SetBounds(24,$y,150,36); $b.FlatStyle='Flat'; $b.Font=New-Object Drawing.Font('Segoe UI Semibold',10)
  if($i -eq 0){$b.BackColor=[Drawing.Color]::FromArgb(31,95,191); $b.ForeColor=[Drawing.Color]::White; $b.FlatAppearance.BorderSize=0}else{$b.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(223,227,233)}
  $b.Add_Click({Do-Action $this.Tag}); $form.Controls.Add($b)
  $d=New-Object Windows.Forms.Label; $d.Text=$items[$i][2]; $d.ForeColor=[Drawing.Color]::FromArgb(95,107,122); $d.SetBounds(186,($y+8),430,26); $form.Controls.Add($d)
 }
 $script:StatusLabel=New-Object Windows.Forms.Label; $script:StatusLabel.Text='אפשר להפעיל את התוכנה גם לפני חיבור חשבון AI.'; $script:StatusLabel.SetBounds(24,316,590,96); $script:StatusLabel.BackColor=[Drawing.Color]::FromArgb(244,246,249); $script:StatusLabel.Padding=New-Object Windows.Forms.Padding(10); $form.Controls.Add($script:StatusLabel)
 $logButton=New-Object Windows.Forms.LinkLabel; $logButton.Text='פתיחת יומן הפעולות'; $logButton.SetBounds(24,428,200,24); $logButton.Add_LinkClicked({if(Test-Path -LiteralPath $Log){Start-Process notepad.exe -ArgumentList ('"'+$Log+'"')}}); $form.Controls.Add($logButton)
 $credit=New-Object Windows.Forms.Label; $credit.Text='הגרסה העברית: @ארי ממתמחים טופ · מבוסס על open·kritt (AGPL-3.0)'; $credit.ForeColor=[Drawing.Color]::FromArgb(95,107,122); $credit.Font=New-Object Drawing.Font('Segoe UI',8.5); $credit.SetBounds(240,430,380,22); $form.Controls.Add($credit)
 $form.Add_FormClosing({if($script:Busy){$_.Cancel=$true}}); [void]$form.ShowDialog(); $form.Dispose()
}finally{$mutex.ReleaseMutex(); $mutex.Dispose()}
