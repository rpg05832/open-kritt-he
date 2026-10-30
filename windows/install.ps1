[CmdletBinding()]
param([switch]$PrepareOnly,[switch]$AcceptLicense,[switch]$IncludeCursor,[switch]$IncludeGrok,[switch]$NoStart,[switch]$BuildLocally,[string]$TargetRoot='')
$ErrorActionPreference='Stop'
# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1.
if(-not $TargetRoot){$TargetRoot=$PSScriptRoot}
$installationRoot=[IO.Path]::GetFullPath($TargetRoot)
if($installationRoot -notmatch '^[A-Za-z]:\\'){throw 'יש לחלץ את החבילה לתיקייה בכונן מקומי, ולא לשיתוף רשת.'}
$applicationRoot=Join-Path $installationRoot 'app'
if(-not (Test-Path -LiteralPath (Join-Path $applicationRoot 'LICENSE'))){throw 'חלצו את כל קובצי החבילה לאותה תיקייה לפני ההתקנה.'}
if(-not $PrepareOnly -and -not $AcceptLicense){
 Add-Type -AssemblyName System.Windows.Forms
 $answer=[Windows.Forms.MessageBox]::Show('הגרסה העברית, התוספות והשיפורים בוצעו על ידי @ארי ממתמחים טופ. קוד התוכנה ברישיון AGPL-3.0. הרישיונות וההודעות מצורפים לחבילה. ההתקנה מורידה כלים ותלויות ממקורותיהם הרשמיים; כלי הספק כפופים לתנאים נפרדים ולחיבור החשבון שלכם. אין חשבונות או נתונים של המפרסם בחבילה. להמשיך בהתקנה?','התקנת סריקת אבטחה','YesNo','Information')
 if($answer -ne 'Yes'){exit 0}
}
$environmentFile=Join-Path $applicationRoot '.env'
if(-not (Test-Path -LiteralPath $environmentFile)){
 $randomBytes=New-Object byte[] 24
 $generator=[Security.Cryptography.RandomNumberGenerator]::Create(); $generator.GetBytes($randomBytes); $generator.Dispose()
 $databasePassword=([BitConverter]::ToString($randomBytes)).Replace('-','').ToLowerInvariant()
 $text=[IO.File]::ReadAllText((Join-Path $applicationRoot '.env.example'))
 $values=@{POSTGRES_PASSWORD=$databasePassword;DATABASE_URL=('postgresql://open_kritt:'+$databasePassword+'@db:5432/open_kritt?schema=public');POSTGRES_PORT='15432';ENGINE_WORKER_COUNT='1';ENGINE_MAX_CONCURRENT_SCANS='1';ENGINE_MAX_WORKERS_PER_SCAN='1';ENGINE_MEMORY_RESERVE_GB='2';ENGINE_SCAN_RUNNER_MEMORY_MB='1536';ENGINE_SCAN_RUNNER_MEMORY_RESERVATION_MB='1536';ENGINE_MIN_FREE_STORAGE_GB='5';ENGINE_AUTO_PRUNE_DOCKER_BUILD_CACHE='false';ENGINE_AUTO_PRUNE_UNUSED_DOCKER_IMAGES='false';ENGINE_CODEX_AUTO_UPDATE='false';INSTALL_CURSOR=$(if($IncludeCursor){'1'}else{'0'});INSTALL_GROK=$(if($IncludeGrok){'1'}else{'0'})}
 foreach($key in $values.Keys){$text=[regex]::Replace($text,('(?m)^'+$key+'=.*\r?\n?'),'');$text+=[Environment]::NewLine+$key+'='+$values[$key]}
 [IO.File]::WriteAllText($environmentFile,$text+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}
# An explicit choice (for example -IncludeCursor:$false from the wizard) also
# updates an existing installation; without one the current value is kept.
foreach($choice in @(@('IncludeCursor','INSTALL_CURSOR'),@('IncludeGrok','INSTALL_GROK'))){
 if($PSBoundParameters.ContainsKey($choice[0])){
  $text=[IO.File]::ReadAllText($environmentFile)
  $text=[regex]::Replace($text,('(?m)^'+$choice[1]+'=.*\r?\n?'),'')
  $text=$text.TrimEnd()+[Environment]::NewLine+$choice[1]+'='+$(if($PSBoundParameters[$choice[0]]){'1'}else{'0'})+[Environment]::NewLine
  [IO.File]::WriteAllText($environmentFile,$text,(New-Object Text.UTF8Encoding($false)))
 }
}
foreach($relative in @('local_repos','.data/engine/credentials','.data/codex','.data/codex-accounts','.data/codex-home-source','.data/claude','.data/claude-accounts','.data/grok','.data/grok-accounts','.data/engine/executor-auth')){[void][IO.Directory]::CreateDirectory((Join-Path $applicationRoot $relative))}
# Approved public CA certificates (see prepare.ps1) are mirrored into every
# build context. Only thumbprint-named files are managed, so a certificate the
# user removed from "certificates" is removed from the next build as well.
# Without a "certificates" folder the existing build files are left untouched.
$certificateFolder=Join-Path $installationRoot 'certificates'
foreach($service in @('frontend','backend','engine','database','executor-view')){
 $destination=Join-Path (Join-Path $applicationRoot $service) 'local-certs'; [void][IO.Directory]::CreateDirectory($destination)
 if(-not (Test-Path -LiteralPath $certificateFolder)){continue}
 $approved=@(Get-ChildItem -LiteralPath $certificateFolder -Filter '*.crt'|Where-Object {$_.Name -match '^[A-Fa-f0-9]{40}\.crt$'})
 foreach($old in Get-ChildItem -LiteralPath $destination -Filter '*.crt'){if($old.Name -match '^[A-Fa-f0-9]{40}\.crt$' -and -not ($approved|Where-Object {$_.Name -ieq $old.Name})){Remove-Item -LiteralPath $old.FullName -Force}}
 foreach($certificate in $approved){Copy-Item -LiteralPath $certificate.FullName -Destination $destination -Force}
}
$drive=$applicationRoot.Substring(0,1).ToLowerInvariant()
$mountPath='/run/desktop/mnt/host/'+$drive+'/'+$applicationRoot.Substring(3).Replace('\','/')+'/.data/engine'
$text=[IO.File]::ReadAllText($environmentFile)
$text=[regex]::Replace($text,'(?m)^ENGINE_DOCKER_DATA_DIR_HOST=.*\r?\n?','')
$text+=[Environment]::NewLine+'ENGINE_DOCKER_DATA_DIR_HOST="'+$mountPath+'"'+[Environment]::NewLine
[IO.File]::WriteAllText($environmentFile,$text,(New-Object Text.UTF8Encoding($false)))
if($PrepareOnly){Write-Output 'Preparation verified; no containers started and no software downloaded.';exit 0}
$dockerPath=(Get-Command docker.exe -ErrorAction SilentlyContinue).Source
if(-not $dockerPath){$dockerPath=Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'}
if(-not (Test-Path -LiteralPath $dockerPath)){throw 'Docker Desktop אינו מותקן. פתחו את Install.cmd: האשף יוריד את המתקין הרשמי ויסביר מה לעשות.'}
$dockerCommand=[pscustomobject]@{Source=$dockerPath}
$osType=$null; try{$osType=& $dockerPath info --format '{{.OSType}}' 2>$null}catch{}
if($osType -ne 'linux'){throw 'Docker Desktop כבוי או לא מוכן. פתחו אותו, המתינו עד שכתוב Engine running, ונסו שוב.'}
$existing=& $dockerCommand.Source ps -aq --filter label=com.docker.compose.project=openkritt-he
$existingVolumes=& $dockerCommand.Source volume ls -q --filter label=com.docker.compose.project=openkritt-he
if(($existing -or $existingVolumes) -and -not (Test-Path -LiteralPath (Join-Path $installationRoot '.maintenance/installed-here'))){throw 'כבר קיימת במחשב התקנה או נתונים של התוכנה. השתמשו בתיקיית ההתקנה הקיימת או במסך העדכונים שלה; לא בוצע שינוי בשירותים.'}
Push-Location -LiteralPath $applicationRoot
try{
 # Prebuilt-image mode: images.json (published with each release) pins every
 # service image by digest. Downloading them replaces the long local build; when
 # the download fails, the installer falls back to building here.
 $imagesManifest=Join-Path $installationRoot 'images.json'
 $installLog=Join-Path $installationRoot 'installation.log'
 $usedImages=$false
 if(-not $BuildLocally -and (Test-Path -LiteralPath $imagesManifest)){
  $release=Get-Content -LiteralPath $imagesManifest -Raw -Encoding UTF8 | ConvertFrom-Json
  $keys=@{frontend='OPEN_KRITT_FRONTEND_IMAGE';backend='OPEN_KRITT_BACKEND_IMAGE';engine='ENGINE_IMAGE';'executor-view'='OPEN_KRITT_EXECUTOR_VIEW_IMAGE';db='OPEN_KRITT_DB_IMAGE'}
  $values=@{}
  foreach($service in $keys.Keys){
   $reference=[string]$release.images.$service
   if($reference -notmatch ('^ghcr\.io/[a-z0-9._-]+/open-kritt-he-'+[regex]::Escape($service)+'@sha256:[a-f0-9]{64}$')){throw ('images.json: הפניה לא תקינה לרכיב '+$service)}
   $values[$keys[$service]]=$reference
  }
  $values['ENGINE_SCAN_RUNNER_IMAGE']=$values['ENGINE_IMAGE']
  $values['COMPOSE_FILE']='docker-compose.yml;docker-compose.override.yml;docker-compose.images.yml'
  $text=[IO.File]::ReadAllText($environmentFile)
  foreach($key in $values.Keys){$text=[regex]::Replace($text,('(?m)^'+$key+'=.*\r?\n?'),''); $text=$text.TrimEnd()+[Environment]::NewLine+$key+'='+$values[$key]}
  [IO.File]::WriteAllText($environmentFile,$text+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
  $usedImages=$true
  foreach($service in @('db','backend','engine','frontend','executor-view')){
   Write-Output ('Downloading '+$service+'...')
   $previousPreference=$ErrorActionPreference
   try{
    $ErrorActionPreference='Continue'
    & $dockerCommand.Source compose -p openkritt-he pull $service 2>&1 | ForEach-Object { $line=$_.ToString(); Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8; Write-Host $line }
    $pullExit=$LASTEXITCODE
   }finally{$ErrorActionPreference=$previousPreference}
   if($pullExit -ne 0){$usedImages=$false; break}
  }
  if(-not $usedImages){
   # Back to local build: remove the image references so compose builds again.
   $text=[IO.File]::ReadAllText($environmentFile)
   foreach($key in $values.Keys){$text=[regex]::Replace($text,('(?m)^'+$key+'=.*\r?\n?'),'')}
   [IO.File]::WriteAllText($environmentFile,$text,(New-Object Text.UTF8Encoding($false)))
   Write-Output 'Prebuilt images could not be downloaded; building locally instead.'
  }
 }
 foreach($service in @('db','backend','engine','frontend','executor-view')){
  if($usedImages){break}
  Write-Output ('Building '+$service+'...')
  $previousPreference=$ErrorActionPreference
  try{
   $ErrorActionPreference='Continue'
   & $dockerCommand.Source compose -p openkritt-he build $service 2>&1 | ForEach-Object {
    $line=$_.ToString() -replace '(https?://)[^/\s]+@','$1[redacted]@'
    Add-Content -LiteralPath $installLog -Value $line -Encoding UTF8
    Write-Host $line
   }
   $buildExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$previousPreference}
  if($buildExit -ne 0){
   $recent=(Get-Content -LiteralPath $installLog -Tail 100 -Encoding UTF8) -join "`n"
   if($recent -match '(?i)unable to get local issuer|self.signed certificate|CERT_|certificate verify failed|x509|unknown authority'){$cause='אחד האתרים עובר דרך סינון שמחליף את תעודת האבטחה, ורכיבי התוכנה עוד לא מכירים אותה. בחלון האשף, בשלב "רשת ותעודות", אשרו את תעודת הרשת שנמצאה ונסו שוב. אין לכבות בדיקת תעודות.'}
   elseif($recent -match '(?i)blocked by|\b418\b|NetFree|access denied|\b403\b'){$cause='ייתכן שהסינון או שרת ההורדה חוסמים גישה. פתחו את installation.log ובדקו את הכתובת שנכשלה; פנו לסינון או למנהל הרשת להסדרת הגישה. תעודת אבטחה אינה פותרת חסימת כתובת.'}
   elseif($recent -match '(?i)ENOTFOUND|EAI_AGAIN|could not resolve|timed?\s*out|ECONNRESET'){$cause='זוהתה תקלה בחיבור, בפתרון כתובת או בזמן ההמתנה. בדקו אינטרנט והגדרות רשת ונסו שוב.'}
   else{$cause='פרטי השגיאה נשמרו בקובץ installation.log. העתיקו את השגיאה לקבלת עזרה.'}
   throw ('הבנייה נעצרה ברכיב '+$service+'. '+$cause+' לאחר פתרון התקלה הפעילו שוב את Install.cmd; Docker עשוי להשתמש בשלבים שכבר נשמרו במטמון.')
  }
 }
}finally{Pop-Location}
[void][IO.Directory]::CreateDirectory((Join-Path $installationRoot '.maintenance'))
[IO.File]::WriteAllText((Join-Path $installationRoot '.maintenance/installed-here'),$(if($usedImages){'prebuilt-images-v1'}else{'source-install-v1'}))
if(-not $NoStart){& (Join-Path $installationRoot 'manage.ps1') -Action Start}
