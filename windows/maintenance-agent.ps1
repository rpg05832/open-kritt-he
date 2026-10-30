[CmdletBinding()]
param([ValidateSet('Server','Worker')][string]$Mode='Server',[ValidateSet('Backup','Restore','Install','Rollback','Package')][string]$Operation='Backup',[string]$JobId='')
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot; $App=Join-Path $Root 'app'; $Store=Join-Path $Root '.maintenance'
$Backups=Join-Path $Store 'backups'; $Jobs=Join-Path $Store 'jobs'; $Updates=Join-Path $Store 'updates'
foreach($directory in @($Store,$Backups,$Jobs,$Updates)){[void][IO.Directory]::CreateDirectory($directory)}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
# Docker may be missing or stopped; the agent must still start so the user can
# open the preparation wizard from the maintenance page.
. (Join-Path $PSScriptRoot 'docker-host.ps1')
$EngineMode=Get-DockerEngineMode (Join-Path $App '.env')
function Json-Write($path,$value){
 $text=ConvertTo-Json -InputObject $value -Depth 30
 $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temporary,$text,(New-Object Text.UTF8Encoding($false)))
  for($attempt=0;$attempt -lt 5;$attempt++){
   try{if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}; break}
   catch [IO.IOException]{if($attempt -eq 4){throw}; Start-Sleep -Milliseconds 25}
  }
 }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Json-Read($path){Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json}
function Run-Docker([string[]]$Arguments,[int]$Timeout=120){
 if(-not (Test-DockerEngineInstalled $EngineMode)){throw ((Get-DockerEngineName $EngineMode)+' אינו מותקן. פתחו את "בדיקה ותיקון" במסך התחזוקה.')}
 $call=Get-DockerCall $EngineMode $Arguments
 $p=New-Object Diagnostics.Process; $p.StartInfo.FileName=$call.File; $p.StartInfo.Arguments=$call.CommandLine
 # Compose resolves COMPOSE_FILE (prebuilt-image mode) relative to the working folder.
 $p.StartInfo.WorkingDirectory=$(if(Test-Path -LiteralPath $App){$App}else{$Root})
 $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
 $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
 $p.StartInfo.StandardOutputEncoding=[Text.Encoding]::UTF8; $p.StartInfo.StandardErrorEncoding=[Text.Encoding]::UTF8 # docker and wsl.exe (WSL_UTF8) print UTF-8
 [void]$p.Start(); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync()
 if(-not $p.WaitForExit($Timeout*1000)){$p.Kill(); throw 'הפעולה חרגה מזמן ההמתנה.'}
 $p.WaitForExit(); if($p.ExitCode -ne 0){$p.Dispose(); throw 'פעולת Docker נכשלה. בדקו שמנוע Docker ושירותי התוכנה פועלים.'}
 $result=$o.Result; $p.Dispose(); return $result
}
function Compose([string[]]$Arguments,[int]$Timeout=180){Run-Docker (@('compose','--project-directory',$App,'-p','openkritt-he')+$Arguments) $Timeout}
function Assert-Idle {
 $sql="SELECT (SELECT count(*) FROM public.scans WHERE status NOT IN ('completed','failed','stopped')) + (SELECT count(*) FROM public.generations WHERE status IN ('pending','running')) + (SELECT count(*) FROM workflows.supplemental_post_script_runs WHERE status IN ('queued','running'))"
 $count=Run-Docker @('exec','open-kritt-db','sh','-c',('export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "'+$sql+'"'))
 if($count.Trim() -ne '0'){throw 'יש בדיקה פעילה או ממתינה. עצרו או השלימו אותה לפני פעולת תחזוקה.'}
}
function Make-Backup {
 Assert-Idle
 $id=[guid]::NewGuid().ToString('N'); $file=Join-Path $Backups ($id+'.dump')
 [void](Run-Docker @('exec','open-kritt-db','sh','-c',('export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --file=/tmp/kritt-'+$id+'.dump')) 300)
 [void](Run-Docker @('cp',('open-kritt-db:/tmp/kritt-'+$id+'.dump'),$file) 300)
 [void](Run-Docker @('exec','open-kritt-db','rm',('--'),('/tmp/kritt-'+$id+'.dump')))
 $metadata=@{id=$id; createdAt=(Get-Date).ToUniversalTime().ToString('o'); bytes=(Get-Item -LiteralPath $file).Length; sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower(); scope='database'; format=1}
 Json-Write (Join-Path $Backups ($id+'.json')) $metadata
 return $metadata
}
function Get-Backup([string]$id){
 if($id -notmatch '^[a-f0-9]{32}$'){throw 'מזהה גיבוי לא תקין.'}
 $meta=Json-Read (Join-Path $Backups ($id+'.json'))
 $file=Join-Path $Backups ($id+'.dump')
 if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() -ne $meta.sha256){throw 'בדיקת תקינות הגיבוי נכשלה.'}
 return $meta
}
function Restore-Database([string]$id){
 $meta=Get-Backup $id
 [void](Run-Docker @('cp',(Join-Path $Backups ($meta.id+'.dump')),'open-kritt-db:/tmp/kritt-restore.dump') 300)
 [void](Run-Docker @('exec','open-kritt-db','sh','-c','export PGPASSWORD="$POSTGRES_PASSWORD"; pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --single-transaction /tmp/kritt-restore.dump') 600)
 $stopPending="BEGIN; UPDATE public.scans SET status='stopped' WHERE status NOT IN ('completed','failed','stopped'); UPDATE public.generations SET status='failed' WHERE status IN ('pending','running'); UPDATE workflows.supplemental_post_script_runs SET status='failed' WHERE status IN ('queued','running'); UPDATE workflows.supplemental_post_script_targets SET status='failed' WHERE status IN ('pending','running'); COMMIT;"
 [void](Run-Docker @('exec','open-kritt-db','sh','-c',('export PGPASSWORD="$POSTGRES_PASSWORD"; psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "'+$stopPending+'"')))
 [void](Run-Docker @('exec','open-kritt-db','rm','--','/tmp/kritt-restore.dump'))
}
function Wait-Application {
 $until=(Get-Date).AddSeconds(120)
 do{
  try{
   [void](Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:3002/api/overview' -TimeoutSec 3)
   [void](Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:5173/' -TimeoutSec 3)
   if((Run-Docker @('inspect','--format','{{.State.Running}}','open-kritt-engine')).Trim() -eq 'true'){return}
  }catch{}
  Start-Sleep -Seconds 2
 }while((Get-Date) -lt $until)
 throw 'בדיקת זמינות התוכנה לאחר העדכון נכשלה.'
}
function Source-Allowed([string]$name){
 if($name -match '\\|(^|/)\.\.?(/|$)|:' -or $name.StartsWith('/')){return $false}
 # Same allow-list as legal/build-update-package.cjs (keep in sync).
 if($name -match '(^|/)(node_modules|\.git|\.data|local_repos|local-certs|local-tools|vendor-cache|\.env)(/|$)' -or $name -match '\.env'){return $false}
 if($name -match '^app/(LICENSE$|NOTICE\.md$|OWNERSHIP\.md$|THIRD_PARTY_NOTICES\.md$|images\.json$|update-source\.json$|legal/|windows/|frontend/public/legal/)'){return $true}
 return $name -match '^app/(frontend/(src/|localization/|package(-lock)?\.json$|vite\.config\.js$|index\.html$|Dockerfile$)|backend/(src/|prisma/|package(-lock)?\.json$|Dockerfile$|runtime-env\.sh$)|engine/(open_kritt_engine/|requirements\.txt$|Dockerfile$|security-tools\.json$|install_security_tools\.py$|runtime-env\.sh$)|executor-view/(src/|package(-lock)?\.json$|Dockerfile$|runtime-env\.sh$)|database/(init/|Dockerfile$)|docker-compose\.yml$)'
}
function Source-Files {
 $licenseInventory=Join-Path $App 'frontend/public/legal/inventory.json'
 if(-not (Test-Path -LiteralPath $licenseInventory)){throw 'חסר מלאי רישיונות לחבילת ההפצה.'}
 $licenseData=Json-Read $licenseInventory
 foreach($relativeInput in @('LICENSE','frontend/package-lock.json','backend/package-lock.json','engine/requirements.txt','engine/Dockerfile','frontend/Dockerfile','backend/Dockerfile','database/Dockerfile','executor-view/Dockerfile')){
  $expected=$licenseData.inputHashes.$relativeInput
  # Same normalisation as legal/build-notices.cjs: no BOM, LF line endings.
  $normalized=[IO.File]::ReadAllText((Join-Path $App $relativeInput)).TrimStart([char]0xFEFF).Replace("`r`n","`n")
  $sha=[Security.Cryptography.SHA256]::Create(); try{$actual=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLower()}finally{$sha.Dispose()}
  if(-not $expected -or $actual -ne $expected){throw 'קובצי התלויות או הבנייה השתנו מאז בדיקת הרישיונות. יש לעדכן את הבדיקה לפני אריזת הפצה.'}
 }
 $result=New-Object 'System.Collections.Generic.List[string]'
 $queue=New-Object 'System.Collections.Generic.Queue[string]'; $queue.Enqueue($App)
 while($queue.Count){foreach($item in Get-ChildItem -LiteralPath $queue.Dequeue() -Force){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
  if($item.PSIsContainer){if($item.Name -notin @('node_modules','.git','.data','local_repos','local-certs','local-tools','__pycache__','dist')){$queue.Enqueue($item.FullName)}}
  else{$relative='app/'+$item.FullName.Substring($App.Length+1).Replace('\','/'); if((Source-Allowed $relative) -and $item.Length -le 20MB){$result.Add($relative)}}
 }}
 return $result.ToArray()
}
function Source-Zip([string]$destination,[string[]]$files){
 $archive=[IO.Compression.ZipFile]::Open($destination,[IO.Compression.ZipArchiveMode]::Create)
 try{foreach($relative in $files){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $Root $relative),$relative,[IO.Compression.CompressionLevel]::Optimal)}}finally{$archive.Dispose()}
}
function Validate-Zip([string]$file){
 $zip=[IO.Compression.ZipFile]::OpenRead($file); $names=New-Object 'System.Collections.Generic.List[string]'; $size=0L
 try{foreach($entry in $zip.Entries){
  if($entry.FullName.EndsWith('/')){continue}
  $size+=$entry.Length
  if(-not (Source-Allowed $entry.FullName) -or $entry.Length -gt 20MB -or $size -gt 200MB -or $names.Count -ge 5000 -or ($entry.ExternalAttributes -band 0xF0000000L) -eq 0xA0000000L){throw 'חבילת העדכון מכילה נתיב או קובץ שאינו מורשה.'}
  if(@($names|Where-Object {$_ -ieq $entry.FullName}).Count){throw 'בחבילת העדכון יש נתיב כפול.'}; $names.Add($entry.FullName)
 }}finally{$zip.Dispose()}
 if(-not $names.Contains('app/frontend/package.json')){throw 'החבילה אינה כוללת את ממשק התוכנה.'}
 foreach($requiredNotice in @('app/LICENSE','app/NOTICE.md','app/THIRD_PARTY_NOTICES.md')){if(-not $names.Contains($requiredNotice)){throw 'חבילת העדכון חסרה רישיון או הודעות זכויות נדרשות.'}}
 return $names.ToArray()
}
function Get-Source {
 # A saved choice wins; otherwise the repository built into the release (app/update-source.json).
 foreach($file in @((Join-Path $Store 'update-source.json'),(Join-Path $App 'update-source.json'))){
  if(Test-Path -LiteralPath $file){$value=[string](Json-Read $file).repository; if($value -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){return $value}}
 }
 return ''
}
# Publisher's RSA public key (PKCS#1 v1.5, SHA-256). Embedded in the agent so it
# cannot be removed separately; the private half never leaves the publisher's PC.
$script:UpdateKeyModulus='srl2A_xdC9VP4A6r7QbW98lTL5FCdIv6D9qkFqKr3XP9APcpBek_WRwgtAwgpkFYisLruwLiKIR7sLk1PRiPn9RlfUnWm9u-SgumsfAScALn61imAVJ2OYxRO7gKfr-G-fD5QYYYHUZ1iPmZ6bJoq3Ypt9ySYDXYPLiZZ720Kh3_GPvhEWbHwtIYe_y7EEUUVys4ZoXSIjPkl0Jd7KBP5wL30jDtgCmA-9lORoX2YBa6exIPm_2CBRxlIRa8Ax42Af7Lc3KCpI9kZFa-J4oyg7UwKxf-odtv_caNmy3OIE0HvKXgqUDLH4ax2F4SbccHeTpIPeX7i8WG_J5c8fAhCwQw0eRXEKm-_wpk4-uLnwYXNN4k2Mm6GitmlQw_Y2dOAHzsuJAW_F5R5OjWCpXqx-HtSWD8twyuGWGBYrkTUGK_IxVw8Qgil8dGA5XV_Y3okeFZtKAGCxRDuGJj4RTGhq6zfZPJml65yIAzWNAqavBSXreyBm5q4JHXsICCYUuL'
$script:UpdateKeyExponent='AQAB'
function Test-UpdateSignature([string]$message,[string]$signatureBase64){
 if([string]::IsNullOrWhiteSpace($signatureBase64)){return $false}
 try{
  $fromB64Url={param($s) $s=$s.Replace('-','+').Replace('_','/'); switch($s.Length % 4){2{$s+='=='}3{$s+='='}}; [Convert]::FromBase64String($s)}
  $rsa=[Security.Cryptography.RSA]::Create()
  $p=New-Object Security.Cryptography.RSAParameters
  $p.Modulus=& $fromB64Url $script:UpdateKeyModulus; $p.Exponent=& $fromB64Url $script:UpdateKeyExponent
  $rsa.ImportParameters($p)
  return $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($message),[Convert]::FromBase64String($signatureBase64),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
 }catch{return $false}
}
function Get-VersionNumbers([string]$version){ return @([regex]::Matches([string]$version,'\d+') | ForEach-Object { [long]$_.Value }) }
function Test-VersionNewer([string]$candidate,[string]$installed){
 # True when $candidate is a later release than $installed (he-v1.5.0 > he-v1.4.1-3).
 $a=Get-VersionNumbers $candidate; $b=Get-VersionNumbers $installed
 for($i=0;$i -lt [Math]::Max($a.Count,$b.Count);$i++){
  $x=$(if($i -lt $a.Count){$a[$i]}else{0}); $y=$(if($i -lt $b.Count){$b[$i]}else{0})
  if($x -gt $y){return $true}; if($x -lt $y){return $false}
 }
 return $false
}
function Check-Release {
 $repository=Get-Source
 if(-not $repository){return @{status='not_configured'; message='בגרסה הזאת עדיין אין מקור עדכונים. הוא יתווסף בגרסה הבאה.'}}
 $release=Invoke-RestMethod -Uri ('https://api.github.com/repos/'+$repository+'/releases/latest') -Headers @{'User-Agent'='Open-Kritt-Hebrew'} -TimeoutSec 15
 $zip=@($release.assets|Where-Object name -eq 'open-kritt-hebrew-update.zip')
 $manifest=@($release.assets|Where-Object name -eq 'open-kritt-hebrew-update.json')
 if($zip.Count -ne 1 -or $manifest.Count -ne 1){throw 'לא נמצאה חבילת הפצה עברית תואמת בגרסה האחרונה.'}
 if($zip[0].size -gt 100MB -or $manifest[0].size -gt 64KB){throw 'חבילת העדכון חורגת ממגבלת הגודל המותרת.'}
 $data=Invoke-RestMethod -Uri $manifest[0].browser_download_url -Headers @{'User-Agent'='Open-Kritt-Hebrew'} -TimeoutSec 15
 if($data.distribution -ne 'open-kritt-hebrew' -or $data.format -ne 2 -or $data.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$data.version)){throw 'קובץ האימות של העדכון אינו תואם להפצה הזאת.'}
 # The publisher signs distribution, format, version and SHA-256 together, so a
 # signed manifest cannot be reused for another version. Unsigned updates are refused.
 $signed="open-kritt-hebrew`n2`n$($data.version)`n$($data.sha256)"
 if(-not (Test-UpdateSignature $signed ([string]$data.signature))){throw 'חתימת העדכון אינה תקפה או חסרה. ההתקנה נעצרה מטעמי אבטחה.'}
 $current=Join-Path $Store 'installed-release.json'; $installed=$null
 if(Test-Path -LiteralPath $current){$installed=Json-Read $current}
 # Never install an older signed release over a newer one (rollback has its own action).
 if($installed -and $installed.version -and $installed.sha256 -ne $data.sha256 -and -not (Test-VersionNewer $data.version $installed.version)){throw 'הגרסה שפורסמה אינה חדשה מהגרסה המותקנת. העדכון לא יותקן.'}
 return @{status=$(if($installed.sha256 -eq $data.sha256){'current'}else{'available'}); repository=$repository; version=$data.version; sha256=$data.sha256.ToLower(); download=$zip[0].browser_download_url; releaseUrl=$release.html_url}
}
function Restore-Source([string]$zipFile,[string[]]$removeFiles){
 $names=Validate-Zip $zipFile
 $zip=[IO.Compression.ZipFile]::OpenRead($zipFile)
 try{foreach($entry in $zip.Entries){if($entry.FullName.EndsWith('/')){continue}; $target=[IO.Path]::GetFullPath((Join-Path $Root $entry.FullName)); if(-not $target.StartsWith([IO.Path]::GetFullPath($App)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'נתיב יעד לא תקין.'}; $ancestor=$target; while($ancestor.Length -gt $App.Length){if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'נתיב העדכון מכיל קישור לתיקייה או לקובץ אחר.'}; $ancestor=[IO.Path]::GetDirectoryName($ancestor)}; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)); [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)}}finally{$zip.Dispose()}
 foreach($relative in $removeFiles){if($relative -notin $names -and (Source-Allowed $relative)){$target=[IO.Path]::GetFullPath((Join-Path $Root $relative)); if($target.StartsWith([IO.Path]::GetFullPath($App)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $target)){Remove-Item -LiteralPath $target -Force}}}
}
function Sync-RootScripts {
 # app/windows is the source of truth; the copies next to app/ are what the
 # shortcuts start. A running script keeps its loaded copy until restarted.
 foreach($name in @('manage.ps1','maintenance-agent.ps1','prepare.ps1','prepare-lib.ps1','install.ps1','docker-host.ps1','wsl-engine.ps1')){
  $source=Join-Path $App ('windows\'+$name); if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination (Join-Path $Root $name) -Force}
 }
}
# ---------- prebuilt-image mode (install.ps1 -FromImages) ----------
$ImageKeys=@{frontend='OPEN_KRITT_FRONTEND_IMAGE';backend='OPEN_KRITT_BACKEND_IMAGE';engine='ENGINE_IMAGE';'executor-view'='OPEN_KRITT_EXECUTOR_VIEW_IMAGE';db='OPEN_KRITT_DB_IMAGE'}
function Test-ImagesMode {
 $path=Join-Path $App '.env'
 return (Test-Path -LiteralPath $path) -and ([IO.File]::ReadAllText($path) -match '(?m)^COMPOSE_FILE=.*docker-compose\.images\.yml')
}
function Get-EnvImages {
 $values=@{}; $path=Join-Path $App '.env'
 if(Test-Path -LiteralPath $path){$text=[IO.File]::ReadAllText($path); foreach($key in @($ImageKeys.Values)+'ENGINE_SCAN_RUNNER_IMAGE'){$match=[regex]::Match($text,('(?m)^'+$key+'=(.*)$')); if($match.Success){$values[$key]=$match.Groups[1].Value.Trim()}}}
 return $values
}
function Set-EnvImages($values){
 if(-not $values -or -not $values.Count){return}
 $path=Join-Path $App '.env'; $text=[IO.File]::ReadAllText($path)
 foreach($key in @($values.Keys)){$text=[regex]::Replace($text,('(?m)^'+$key+'=.*\r?\n?'),''); $text=$text.TrimEnd()+[Environment]::NewLine+$key+'='+$values[$key]}
 [IO.File]::WriteAllText($path,$text+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}
function Apply-ImageReferences([string]$manifestPath){
 # Only digest-pinned references to this distribution's images are accepted.
 $release=Json-Read $manifestPath; $values=@{}
 foreach($service in $ImageKeys.Keys){
  $reference=[string]$release.images.$service
  if($reference -notmatch ('^ghcr\.io/[a-z0-9._-]+/open-kritt-he-'+[regex]::Escape($service)+'@sha256:[a-f0-9]{64}$')){throw 'קובץ התמונות של העדכון אינו תקין. העדכון נעצר.'}
  $values[$ImageKeys[$service]]=$reference
 }
 $values['ENGINE_SCAN_RUNNER_IMAGE']=$values['ENGINE_IMAGE']
 Set-EnvImages $values
}
function Set-Job([string]$status,[string]$message,$result=$null){Json-Write (Join-Path $Jobs ($JobId+'.json')) @{id=$JobId; operation=$Operation; status=$status; message=$message; result=$result; updatedAt=(Get-Date).ToUniversalTime().ToString('o')}}
if($Mode -eq 'Worker'){
 if($JobId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid job'}
 $inputData=Json-Read (Join-Path $Jobs ($JobId+'.input.json'))
 try{
  Set-Job 'running' 'בודק שהמערכת פנויה…'
  switch($Operation){
   'Backup'{Set-Job 'running' 'יוצר גיבוי למסד הנתונים…'; $result=Make-Backup; Set-Job 'completed' 'הגיבוי נוצר ונבדקה טביעת הקובץ.' $result}
   'Restore'{
    $meta=Get-Backup $inputData.backupId; Assert-Idle
    Set-Job 'running' 'יוצר גיבוי לפני שחזור…'; $safety=Make-Backup
    [void](Compose @('stop','engine','backend'))
    $safeToStart=$false
    try{
     Set-Job 'running' 'משחזר את מסד הנתונים בפעולה אחת…'
     Restore-Database $meta.id
     $safeToStart=$true
    }catch{
     try{Restore-Database $safety.id; $safeToStart=$true}catch{}
     throw 'השחזור נכשל. גיבוי המצב המקורי נשמר. אם המנוע נשאר כבוי, בדקו מצב לפני הפעלתו מחדש.'
    }finally{[void](Compose @('start','backend')); if($safeToStart){[void](Compose @('start','engine'))}}
    Set-Job 'completed' 'השחזור הסתיים. רעננו את הדף. גיבוי המצב שלפני השחזור נשמר.' @{safetyBackupId=$safety.id}
   }
   'Package'{
    Set-Job 'running' 'אורז את קוד ההפצה העברית ללא נתונים וחשבונות…'
    $folder=Join-Path $Updates $JobId; [void][IO.Directory]::CreateDirectory($folder)
    $zip=Join-Path $folder 'open-kritt-hebrew-update.zip'; Source-Zip $zip (Source-Files)
    [void](Validate-Zip $zip)
    $manifest=@{distribution='open-kritt-hebrew'; format=1; version=('local-'+(Get-Date -Format 'yyyyMMdd-HHmmss')); sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()}
    Json-Write (Join-Path $folder 'open-kritt-hebrew-update.json') $manifest
    Set-Job 'completed' 'חבילת ההפצה מוכנה. יש לפרסם את שני הקבצים יחד ב־GitHub Release.' @{packageId=$JobId; version=$manifest.version}
   }
   'Install'{
    Assert-Idle; $release=Check-Release
    if($release.status -ne 'available'){throw 'לא נמצא עדכון חדש להתקנה.'}
    Set-Job 'running' 'מוריד ובודק את חבילת העדכון…'
    $zip=Join-Path $Updates ($JobId+'.zip'); Invoke-WebRequest -UseBasicParsing -Uri $release.download -OutFile $zip -TimeoutSec 300
    if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower() -ne $release.sha256){throw 'טביעת קובץ העדכון אינה תואמת. ההתקנה נעצרה.'}
    $newFiles=Validate-Zip $zip
    Set-Job 'running' 'מגבה נתונים וקוד לפני העדכון…'; $backup=Make-Backup
    $rollbackZip=Join-Path $Updates ($JobId+'-previous.zip'); Source-Zip $rollbackZip (Source-Files)
    $images=@(); foreach($name in @('open-kritt-backend','open-kritt-engine','open-kritt-frontend')){
      $parts=(Run-Docker @('inspect','--format','{{.Config.Image}}|{{.Image}}',$name)).Trim().Split('|'); $images+=@{tag=$parts[0]; id=$parts[1]}
    }
    $rollback=@{zipName=[IO.Path]::GetFileName($rollbackZip); newFiles=$newFiles; images=$images; envImages=(Get-EnvImages); databaseBackupId=$backup.id; previousRelease=$null}
    if(Test-Path -LiteralPath (Join-Path $Store 'installed-release.json')){$rollback.previousRelease=Json-Read (Join-Path $Store 'installed-release.json')}
    Json-Write (Join-Path $Updates 'rollback.json') $rollback
    [void](Compose @('stop','engine','backend','frontend'))
    try{
      Restore-Source $zip @(); Sync-RootScripts
      if(Test-ImagesMode){
        # Prebuilt images: download the release's signed, digest-pinned images instead of building.
        Set-Job 'running' 'מוריד את הרכיבים המוכנים של הגרסה החדשה…'
        Apply-ImageReferences (Join-Path $App 'images.json')
        [void](Compose @('pull','db','backend','engine','frontend','executor-view') 1800)
        [void](Compose @('up','-d','--renew-anon-volumes','backend','engine','frontend','executor-view') 300)
      }else{
        Set-Job 'running' 'בונה את רכיבי התוכנה. הפעולה עשויה להימשך מספר דקות…'
        [void](Compose @('build','backend','engine','frontend') 1800)
        [void](Compose @('up','-d','--no-deps','backend','engine','frontend') 300)
      }
      Wait-Application
      Json-Write (Join-Path $Store 'installed-release.json') $release
    }catch{
      [void](Compose @('stop','engine','backend','frontend'))
      Restore-Source $rollbackZip $newFiles
      Restore-Database $backup.id
      # Images mode: the previous digests are still on this computer; point .env back to them.
      if(Test-ImagesMode){Set-EnvImages $rollback.envImages}
      else{foreach($image in $images){[void](Run-Docker @('tag',$image.id,$image.tag))}}
      [void](Compose @('up','-d','--no-deps','backend','engine','frontend') 300)
      throw 'העדכון נכשל. הקוד, תמונות ההפעלה ומסד הנתונים הוחזרו למצב שלפני העדכון.'
    }
    Set-Job 'completed' 'העדכון הותקן. רעננו את הדף.' @{version=$release.version; backupId=$backup.id}
   }
   'Rollback'{
    Assert-Idle; $rollback=Json-Read (Join-Path $Updates 'rollback.json')
    if($rollback.zipName -notmatch '^[a-f0-9]{32}-previous\.zip$'){throw 'גיבוי הקוד הקודם אינו תקין.'}
    $rollbackZip=Join-Path $Updates $rollback.zipName
    [void](Validate-Zip $rollbackZip)
    foreach($image in $rollback.images){try{[void](Run-Docker @('image','inspect',$image.id))}catch{throw 'תמונת ההפעלה הקודמת אינה זמינה במחשב הזה. לא בוצע שינוי.'}}
    [void](Make-Backup); [void](Compose @('stop','engine','backend','frontend'))
    Restore-Source $rollbackZip @($rollback.newFiles)
    Restore-Database $rollback.databaseBackupId
    if(Test-ImagesMode -and $rollback.envImages){
     $previous=@{}; foreach($property in $rollback.envImages.PSObject.Properties){$previous[$property.Name]=$property.Value}
     Set-EnvImages $previous
    }else{foreach($image in $rollback.images){[void](Run-Docker @('tag',$image.id,$image.tag))}}
    [void](Compose @('up','-d','--no-deps','backend','engine','frontend') 300)
    Json-Write (Join-Path $Store 'installed-release.json') $rollback.previousRelease
    Wait-Application
    Set-Job 'completed' 'הקוד והיסטוריית מסד הנתונים הוחזרו למצב שלפני העדכון. גיבוי של המצב האחרון נשמר.'
   }
  }
 }catch{Set-Job 'failed' $_.Exception.Message}
 exit
}
$mutex=New-Object Threading.Mutex($false,'Local\OpenKrittHebrewMaintenance')
if(-not $mutex.WaitOne(0)){exit}
$listener=New-Object Net.HttpListener; $listener.Prefixes.Add('http://127.0.0.1:5180/')
try{
 $listener.Start()
 [IO.File]::WriteAllText((Join-Path $Store 'server.pid'),[string]$PID)
 foreach($jobFile in Get-ChildItem -LiteralPath $Jobs -Filter '*.json'|Where-Object Name -notlike '*.input.json'){
  $oldJob=Json-Read $jobFile.FullName
  if($oldJob.status -in @('queued','running')){
   $worker=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -like ('*maintenance-agent.ps1*Worker*'+$oldJob.id+'*')}
   if(-not $worker){$oldJob.status='failed'; $oldJob.message='פעולת התחזוקה הקודמת הופסקה לפני סיום. בדקו מצב לפני ניסיון נוסף.'; Json-Write $jobFile.FullName $oldJob}
  }
 }
 while($listener.IsListening){
  $context=$listener.GetContext(); $request=$context.Request; $response=$context.Response
  $response.Headers['Cache-Control']='no-store'; $response.Headers['X-Content-Type-Options']='nosniff'
  $origin=$request.Headers['Origin']
  try{
   if($origin -notin @('http://localhost:5173','http://127.0.0.1:5173')){throw 'מקור הבקשה אינו מורשה.'}
   $response.Headers['Access-Control-Allow-Origin']=$origin; $response.Headers['Vary']='Origin'
   $response.Headers['Access-Control-Allow-Headers']='Content-Type, X-Kritt-Management'; $response.Headers['Access-Control-Allow-Methods']='GET, POST, OPTIONS'
   if($request.HttpMethod -eq 'OPTIONS'){$response.StatusCode=204; $response.Close(); continue}
   if($request.Headers['X-Kritt-Management'] -ne '1'){throw 'חסרה הרשאת ממשק מקומי.'}
   $path=$request.Url.AbsolutePath; $body=@{}
   if($request.HttpMethod -eq 'POST' -and $path -ne '/backup-import'){
    if($request.ContentLength64 -gt 8192){throw 'הבקשה גדולה מדי.'}
    $reader=New-Object IO.StreamReader($request.InputStream,[Text.Encoding]::UTF8); $raw=$reader.ReadToEnd(); $reader.Dispose(); if($raw){$body=$raw|ConvertFrom-Json}
   }
   $data=$null
   if($path -eq '/status' -and $request.HttpMethod -eq 'GET'){
    $backupEntries=@(Get-ChildItem -LiteralPath $Backups -Filter '*.json'|Sort-Object LastWriteTime -Descending|ForEach-Object{Json-Read $_.FullName})
    $jobList=@(Get-ChildItem -LiteralPath $Jobs -Filter '*.json'|Where-Object Name -notlike '*.input.json'|Sort-Object LastWriteTime -Descending|Select-Object -First 10|ForEach-Object{Json-Read $_.FullName})
    $data=@{available=$true; repository=(Get-Source); backups=$backupEntries; jobs=$jobList; canRollback=(Test-Path -LiteralPath (Join-Path $Updates 'rollback.json'))}
   }elseif($path -eq '/diagnostics' -and $request.HttpMethod -eq 'GET'){
    $services=@(); $dockerReady=$true
    try{$lines=Run-Docker @('ps','-a','--filter','label=com.docker.compose.project=openkritt-he','--format','{{.Names}}|{{.Status}}'); foreach($line in ($lines -split "`n")){if($line.Trim()){$parts=$line.Trim().Split('|'); $services+=@{name=$parts[0]; status=$parts[1]}}}}catch{$dockerReady=$false}
    $resources=''; if($dockerReady){try{$resources=Run-Docker @('stats','--no-stream','--format','{{.Name}}: {{.MemUsage}}; CPU {{.CPUPerc}}','open-kritt-engine','open-kritt-backend','open-kritt-frontend','open-kritt-db') 15}catch{}}
    $checks=@(); foreach($url in @('http://127.0.0.1:3002/api/health','http://127.0.0.1:5173/')){try{[void](Invoke-WebRequest -UseBasicParsing $url -TimeoutSec 3); $checks+=@{url=$url; ready=$true}}catch{$checks+=@{url=$url; ready=$false}}}
    $data=@{dockerReady=$dockerReady; services=$services; resources=$resources; checks=$checks; measuredAt=(Get-Date).ToUniversalTime().ToString('o')}
   }elseif($path -eq '/backup-import' -and $request.HttpMethod -eq 'POST'){
    if($request.ContentLength64 -lt 5 -or $request.ContentLength64 -gt 512MB){throw 'קובץ הגיבוי חייב להיות עד 512 MB.'}
    $id=[guid]::NewGuid().ToString('N'); $file=Join-Path $Backups ($id+'.dump')
    $stream=[IO.File]::Create($file); try{$request.InputStream.CopyTo($stream)}finally{$stream.Dispose()}
    $stream=[IO.File]::OpenRead($file); $magic=New-Object byte[] 5; try{[void]$stream.Read($magic,0,5)}finally{$stream.Dispose()}
    if([Text.Encoding]::ASCII.GetString($magic) -ne 'PGDMP'){Remove-Item -LiteralPath $file -Force; throw 'זה אינו קובץ גיבוי מתאים למסד הנתונים.'}
    try{
     [void](Run-Docker @('cp',$file,('open-kritt-db:/tmp/kritt-import-'+$id+'.dump')) 300)
     [void](Run-Docker @('exec','open-kritt-db','pg_restore','--list',('/tmp/kritt-import-'+$id+'.dump')))
    }catch{Remove-Item -LiteralPath $file -Force; throw 'לא ניתן לאמת את קובץ הגיבוי. ודאו ש־Docker פועל ושהקובץ נוצר בתוכנה הזאת.'}
    finally{try{[void](Run-Docker @('exec','open-kritt-db','rm','--',('/tmp/kritt-import-'+$id+'.dump')))}catch{}}
    $data=@{id=$id; createdAt=(Get-Date).ToUniversalTime().ToString('o'); bytes=(Get-Item -LiteralPath $file).Length; sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower(); scope='database'; format=1; imported=$true}
    Json-Write (Join-Path $Backups ($id+'.json')) $data
   }elseif($path -eq '/prepare' -and $request.HttpMethod -eq 'POST'){
    # Opens the local wizard window; every change inside it needs the user's own click.
    $wizard=Join-Path $Root 'prepare.ps1'; if(-not (Test-Path -LiteralPath $wizard)){$wizard=Join-Path $App 'windows\prepare.ps1'}
    $open=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"|Where-Object {$_.CommandLine -like '*prepare.ps1*'})
    if(-not $open.Count){Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$wizard+'" -InstallationRoot "'+$Root+'" -Mode Repair')}
    $data=@{opened=$true; alreadyOpen=[bool]$open.Count}
   }elseif($path -eq '/release' -and $request.HttpMethod -eq 'GET'){$data=Check-Release
   }elseif($path -eq '/source' -and $request.HttpMethod -eq 'POST'){
    if($body.repository -and $body.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'כתבו מאגר בצורה owner/repository.'}
    Json-Write (Join-Path $Store 'update-source.json') @{repository=[string]$body.repository}; $data=@{saved=$true}
   }elseif($path -match '^/backup/([a-f0-9]{32})$' -and $request.HttpMethod -eq 'GET'){
    $meta=Get-Backup $Matches[1]; $file=Join-Path $Backups ($meta.id+'.dump')
    $response.ContentType='application/octet-stream'; $response.ContentLength64=(Get-Item -LiteralPath $file).Length
    $stream=[IO.File]::OpenRead($file); try{$stream.CopyTo($response.OutputStream)}finally{$stream.Dispose()}; $response.Close(); continue
   }elseif($path -match '^/package/([a-f0-9]{32})/(zip|json)$' -and $request.HttpMethod -eq 'GET'){
    $file=Join-Path (Join-Path $Updates $Matches[1]) ('open-kritt-hebrew-update.'+$Matches[2]); $response.ContentType='application/octet-stream'; $stream=[IO.File]::OpenRead($file); $response.ContentLength64=$stream.Length; try{$stream.CopyTo($response.OutputStream)}finally{$stream.Dispose()}; $response.Close(); continue
   }elseif($path -eq '/action' -and $request.HttpMethod -eq 'POST'){
    if($body.operation -notin @('Backup','Restore','Install','Rollback','Package')){throw 'פעולה לא מוכרת.'}
    $busy=@(Get-ChildItem -LiteralPath $Jobs -Filter '*.json'|Where-Object Name -notlike '*.input.json'|ForEach-Object{Json-Read $_.FullName}|Where-Object {$_.status -in @('queued','running')})
    if($busy.Count){throw 'פעולת תחזוקה אחרת עדיין מתבצעת.'}
    if($body.operation -in @('Restore','Install','Rollback') -and $body.confirm -ne 'APPLY'){throw 'יש לאשר את הפעולה במסך התחזוקה.'}
    $id=[guid]::NewGuid().ToString('N'); Json-Write (Join-Path $Jobs ($id+'.input.json')) $body
    Json-Write (Join-Path $Jobs ($id+'.json')) @{id=$id; operation=$body.operation; status='queued'; message='ממתין להפעלה…'}
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode Worker -Operation '+$body.operation+' -JobId '+$id
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
    $response.StatusCode=202; $data=@{id=$id}
   }else{throw 'פעולה לא נמצאה.'}
   $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $data -Depth 30)); $response.ContentType='application/json; charset=utf-8'; $response.ContentLength64=$bytes.Length; $response.OutputStream.Write($bytes,0,$bytes.Length)
  }catch{$response.StatusCode=400; $bytes=[Text.Encoding]::UTF8.GetBytes((@{error=$_.Exception.Message}|ConvertTo-Json)); $response.ContentType='application/json; charset=utf-8'; $response.OutputStream.Write($bytes,0,$bytes.Length)}finally{$response.Close()}
 }
}finally{$listener.Close(); $mutex.ReleaseMutex(); $mutex.Dispose()}
