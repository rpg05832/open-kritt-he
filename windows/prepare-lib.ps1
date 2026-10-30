# Shared, UI-free helpers for prepare.ps1 (and prepare-tests.ps1).
# Nothing here changes the Windows trust store or disables TLS verification.


# Hosts the local build and the scans need. Purpose text is shown to the user.
$script:ProbeHosts = @(
 @{Host='registry.npmjs.org';     Path='/';             Purpose='חבילות Node.js (npm) לבניית הממשק והשרת'},
 @{Host='pypi.org';               Path='/simple/pip/';  Purpose='רשימת חבילות Python למנוע הבדיקות'},
 @{Host='files.pythonhosted.org'; Path='/';             Purpose='קובצי חבילות Python'},
 @{Host='binaries.prisma.sh';     Path='/';             Purpose='רכיב מסד הנתונים של השרת (Prisma)'},
 @{Host='dl-cdn.alpinelinux.org'; Path='/alpine/';      Purpose='חבילות מערכת לרכיבי Alpine'},
 @{Host='deb.debian.org';         Path='/debian/';      Purpose='חבילות מערכת לרכיבי Debian'},
 @{Host='github.com';             Path='/';             Purpose='קוד מקור וכלים'},
 @{Host='api.osv.dev';            Path='/v1/query';     Purpose='מאגר החולשות OSV (בזמן סריקה)'}
)
# The probe image is already a build base image, so pulling it is not wasted.
$script:ProbeImage = 'node:24.1.0-alpine3.20'

# Runs inside a throwaway container. It READS the certificate chain that the
# container sees (rejectUnauthorized:false is used only for this inspection; no
# data is sent or trusted), then makes a normal, fully verified HTTPS request.
$script:ProbeScript = @'
const tls=require('tls'),https=require('https'),dns=require('dns');
const targets=JSON.parse(Buffer.from(process.argv[1],'base64').toString());
const ca=[...tls.rootCertificates,...JSON.parse(Buffer.from(process.argv[2]||'W10=','base64').toString())];
const pem=r=>'-----BEGIN CERTIFICATE-----\n'+r.toString('base64').match(/.{1,64}/g).join('\n')+'\n-----END CERTIFICATE-----';
const dn=o=>o?Object.entries(o).map(([k,v])=>k+'='+(Array.isArray(v)?v.join('+'):v)).join(', '):'';
function one(t){return new Promise(done=>{const r={host:t.host};
 dns.lookup(t.host,e=>{ if(e){r.stage='dns';r.code=e.code;return done(r);}
  const s=tls.connect({host:t.host,port:443,servername:t.host,ca,rejectUnauthorized:false,timeout:10000},()=>{
   r.authorized=s.authorized;r.tlsError=s.authorizationError?String(s.authorizationError):null;
   let c=s.getPeerCertificate(true);const seen=new Set();r.chain=[];
   while(c&&c.raw&&!seen.has(c.fingerprint256)){seen.add(c.fingerprint256);r.chain.push({subject:dn(c.subject),issuer:dn(c.issuer),sha1:c.fingerprint.replace(/:/g,''),pem:pem(c.raw)});c=c.issuerCertificate;}
   s.end(); if(!s.authorized){r.stage='tls';return done(r);}
   const q=https.get({host:t.host,path:t.path,ca,timeout:10000,headers:{'user-agent':'open-kritt-prepare'}},res=>{
    r.status=res.statusCode;let body='';res.setEncoding('latin1');
    res.on('data',d=>{if(body.length<4096)body+=d;});res.on('end',()=>{r.netfree=/netfree/i.test(body+JSON.stringify(res.headers));r.stage='http';done(r);});});
   q.on('timeout',()=>q.destroy(Object.assign(new Error('timeout'),{code:'ETIMEDOUT'})));
   q.on('error',e=>{r.stage='http';r.code=e.code||e.message;done(r);});});
  s.on('timeout',()=>s.destroy(Object.assign(new Error('timeout'),{code:'ETIMEDOUT'})));
  s.on('error',e=>{r.stage='connect';r.code=e.code||e.message;done(r);});});});}
Promise.all(targets.map(one)).then(x=>console.log('PROBE:'+JSON.stringify(x)));
'@

function Invoke-Pumped {
 # Runs an executable without freezing the window. Returns Code/Out/Err.
 param([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds=60,[scriptblock]$Pump={})
 $p=New-Object Diagnostics.Process; $p.StartInfo.FileName=$FilePath
 $p.StartInfo.Arguments=($Arguments|ForEach-Object{'"'+(($_ -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1')+'"'}) -join ' '
 $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
 $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
 try{[void]$p.Start()}catch{return [pscustomobject]@{Code=-1;Out='';Err=$_.Exception.Message;TimedOut=$false}}
 $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync(); $timer=[Diagnostics.Stopwatch]::StartNew()
 while(-not $p.WaitForExit(100)){& $Pump; if($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds){try{$p.Kill()}catch{}; $p.Dispose(); return [pscustomobject]@{Code=-1;Out='';Err='timeout';TimedOut=$true}}}
 $p.WaitForExit(); $r=[pscustomobject]@{Code=$p.ExitCode;Out=$o.Result;Err=$e.Result;TimedOut=$false}; $p.Dispose(); return $r
}

function ConvertFrom-PemText([string]$Text){
 if($Text -match 'PRIVATE KEY'){throw 'הקובץ מכיל מפתח פרטי. אין להשתמש בו.'}
 $list=@(); foreach($m in [regex]::Matches($Text,'(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----')){
  $list+=,(New-Object Security.Cryptography.X509Certificates.X509Certificate2(,[Convert]::FromBase64String(($m.Groups[1].Value -replace '\s',''))))
 }
 return $list
}

function Get-Sha256([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate){
 $sha=[Security.Cryptography.SHA256]::Create(); try{return ([BitConverter]::ToString($sha.ComputeHash($Certificate.RawData))).Replace('-','')}finally{$sha.Dispose()}
}

function Test-PublicCaCertificate([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate){
 # Returns a Hebrew reason when the certificate must not be added, otherwise $null.
 if($Certificate.HasPrivateKey){return 'הקובץ כולל מפתח פרטי.'}
 $ext=$Certificate.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.19'}|Select-Object -First 1
 if(-not $ext){return 'זו אינה תעודת רשות אישורים (CA).'}
 $bc=New-Object Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($ext,$ext.Critical)
 if(-not $bc.CertificateAuthority){return 'זו אינה תעודת רשות אישורים (CA).'}
 $now=Get-Date; if($Certificate.NotBefore -gt $now -or $Certificate.NotAfter -lt $now){return 'התעודה אינה בתוקף בתאריך הנוכחי.'}
 return $null
}

function Get-WindowsRootStores { @('LocalMachine','CurrentUser') | ForEach-Object { "Cert:\$_\Root" } }

function Find-TrustedRootForChain {
 # Builds the chain the container saw using Windows' own trusted roots.
 # Returns the root only when Windows validates the chain (cryptographically).
 param([object[]]$ChainPems,[object[]]$AdditionalRoots=@())
 $certs=@(); foreach($pemText in $ChainPems){$certs+=@(ConvertFrom-PemText $pemText)}
 if(-not $certs.Count){return $null}
 $chain=New-Object Security.Cryptography.X509Certificates.X509Chain
 try{
  $chain.ChainPolicy.RevocationMode='NoCheck'
  foreach($c in $certs|Select-Object -Skip 1){[void]$chain.ChainPolicy.ExtraStore.Add($c)}
  foreach($c in $AdditionalRoots){[void]$chain.ChainPolicy.ExtraStore.Add($c)}
  if($AdditionalRoots.Count){$chain.ChainPolicy.VerificationFlags='AllowUnknownCertificateAuthority'}
  $built=$chain.Build($certs[0])
  $root=$chain.ChainElements[$chain.ChainElements.Count-1].Certificate
  if($root.Subject -ne $root.Issuer){return $null}
  $bad=@($chain.ChainStatus|Where-Object {$_.Status -notin @('NoError','RevocationStatusUnknown','OfflineRevocation','NotValidForUsage')})
  if($AdditionalRoots.Count){
   # A user-supplied root is accepted only if it is exactly the chain's top.
   if(-not @($AdditionalRoots|Where-Object {$_.Thumbprint -eq $root.Thumbprint}).Count){return $null}
   $bad=@($bad|Where-Object {$_.Status -ne 'UntrustedRoot'})
  }elseif(-not $built -and $bad.Count){return $null}
  if($bad.Count){return $null}
  return New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$root.RawData)
 }finally{$chain.Dispose()}
}

function Get-RootOrigin([Security.Cryptography.X509Certificates.X509Certificate2]$Root){
 # Microsoft-distributed public roots live in AuthRoot; roots added by a filter,
 # antivirus or administrator are usually only in Root.
 foreach($s in @('Cert:\LocalMachine\AuthRoot','Cert:\CurrentUser\AuthRoot')){if(Test-Path "$s\$($Root.Thumbprint)"){return 'public'}}
 foreach($s in Get-WindowsRootStores){if(Test-Path "$s\$($Root.Thumbprint)"){return 'local'}}
 return 'unknown'
}

function Get-ProbeClass($r){
 # dns | network | certificate | blocked | maybe-blocked | ok
 switch($r.stage){
  'dns'     {return 'dns'}
  'connect' {return 'network'}
  'tls'     {if($r.tlsError -match 'CERT|SELF_SIGNED|ISSUER|VERIFY_LEAF'){return 'certificate'}; return 'network'}
  'http'    {
   if(-not $r.PSObject.Properties['status'] -or $null -eq $r.status){return 'network'}
   if($r.status -in @(418,451) -or ($r.PSObject.Properties['netfree'] -and $r.netfree -and $r.status -ge 400)){return 'blocked'}
   if($r.status -eq 403){return 'maybe-blocked'}
   return 'ok'
  }
 }
 return 'network'
}

function Get-ClassText([string]$class){
 switch($class){
  'ok'            {'תקין'}
  'dns'           {'בעיית רשת: לא ניתן לפענח את שם השרת (DNS). בדקו חיבור לאינטרנט.'}
  'network'       {'בעיית רשת: החיבור נכשל או לא הגיב בזמן. בדקו חיבור, חומת אש או VPN.'}
  'certificate'   {'תעודה חסרה: הרשת מחליפה את תעודת האבטחה ורכיבי התוכנה אינם מכירים את הרשות.'}
  'blocked'       {'חסימת סינון: השרת זמין, אבל הסינון חוסם את הכתובת. תעודה לא תפתור זאת; פנו לספק הסינון.'}
  'maybe-blocked' {'גישה נדחתה (403). ייתכן שזו חסימת סינון או מגבלה של השרת.'}
  default         {'מצב לא ידוע'}
 }
}

function Invoke-ContainerProbe {
 param([string]$Docker,[scriptblock]$Pump={},[object[]]$Targets=$script:ProbeHosts,[string[]]$ApprovedPems=@())
 $pull=Invoke-Pumped $Docker @('image','inspect',$script:ProbeImage) 20 $Pump
 if($pull.Code -ne 0){
  $pull=Invoke-Pumped $Docker @('pull',$script:ProbeImage) 600 $Pump
  if($pull.Code -ne 0){
   $kind=if($pull.Err -match '(?i)x509|certificate'){'certificate'}elseif($pull.Err -match '(?i)no such host|lookup'){'dns'}elseif($pull.Err -match '(?i)403|418|denied|forbidden'){'blocked'}else{'network'}
   return [pscustomobject]@{Ok=$false;PullFailed=$true;Kind=$kind;Detail=($pull.Err -split "`n" | Select-Object -Last 2) -join ' ';Results=@()}
  }
 }
 $json=ConvertTo-Json -Compress -InputObject @($Targets|ForEach-Object{@{host=$_.Host;path=$_.Path}})
 $encodedTargets=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
 $encodedScript=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:ProbeScript))
 # eval only runs the constant $script:ProbeScript above (base64 avoids Windows
 # argument quoting); nothing from the network or the user is evaluated.
 $code="eval(Buffer.from('$encodedScript','base64').toString())"
 # Certificates the user already approved are added, so the check shows the state
 # the next build will have.
 $encodedApproved=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject @($ApprovedPems))))
 $run=Invoke-Pumped $Docker @('run','--rm','--memory','128m','--cpus','0.5',$script:ProbeImage,'node','-e',$code,$encodedTargets,$encodedApproved) 120 $Pump
 $line=($run.Out -split "`n" | Where-Object {$_ -like 'PROBE:*'} | Select-Object -Last 1)
 if(-not $line){return [pscustomobject]@{Ok=$false;PullFailed=$false;Kind='network';Detail=$run.Err;Results=@()}}
 $parsed=($line.Substring(6)|ConvertFrom-Json)
 return [pscustomobject]@{Ok=$true;PullFailed=$false;Kind='';Detail='';Results=@($parsed)}
}

function Invoke-HostProbe {
 # Windows-side check, used when Docker is not running yet. Verification stays on:
 # the callback only records what Windows decided.
 param([string]$HostName,[int]$TimeoutMs=7000)
 $r=[ordered]@{host=$HostName;stage='';code='';rootSubject='';rootOrigin='';policyErrors=''}
 try{[void][Net.Dns]::GetHostAddresses($HostName)}catch{$r.stage='dns';return [pscustomobject]$r}
 $client=New-Object Net.Sockets.TcpClient
 try{
  try{if(-not $client.ConnectAsync($HostName,443).Wait($TimeoutMs)){throw 'timeout'}}catch{$r.stage='connect';$r.code='ETIMEDOUT';return [pscustomobject]$r}
  $state=@{chain=$null;errors='None'}
  $callback=[Net.Security.RemoteCertificateValidationCallback]{param($sender,$cert,$chain,$errors) $state.errors=[string]$errors; if($chain -and $chain.ChainElements.Count){$state.chain=New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$chain.ChainElements[$chain.ChainElements.Count-1].Certificate.RawData)}; return ($errors -eq 'None')}.GetNewClosure()
  $stream=New-Object Net.Security.SslStream($client.GetStream(),$false,$callback)
  try{
   # Synchronous on purpose: the PowerShell callback must run on this thread.
   try{$client.ReceiveTimeout=$TimeoutMs; $client.SendTimeout=$TimeoutMs; $stream.AuthenticateAsClient($HostName); $r.stage='http'}
   catch{$r.stage=if($state.errors -ne 'None'){'tls'}else{'connect'}}
   $r.policyErrors=$state.errors
   if($state.chain){$r.rootSubject=$state.chain.Subject; $r.rootOrigin=Get-RootOrigin $state.chain}
  }finally{$stream.Dispose()}
 }finally{$client.Dispose()}
 return [pscustomobject]$r
}

function Get-DockerPath {
 $command=Get-Command docker.exe -ErrorAction SilentlyContinue; if($command){return $command.Source}
 $default=Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'; if(Test-Path -LiteralPath $default){return $default}; return $null
}

function Get-SystemState {
 # Read-only snapshot of what the installation needs on this computer.
 param([string]$InstallationRoot,[scriptblock]$Pump={})
 $desktop=Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
 $drive=New-Object IO.DriveInfo($InstallationRoot.Substring(0,1))
 $s=[ordered]@{Is64=[Environment]::Is64BitOperatingSystem;FreeGb=[math]::Round($drive.AvailableFreeSpace/1GB,1);Wsl=[bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
  DesktopPath=$desktop;DesktopInstalled=(Test-Path -LiteralPath $desktop);DockerPath=(Get-DockerPath);EngineOk=$false;OsType='';MemGb=0;Compose='';ImagesBuilt=$false;EngineRunning=$false
  InstalledHere=(Test-Path -LiteralPath (Join-Path $InstallationRoot '.maintenance\installed-here'))}
 if($s.DockerPath){
  $info=Invoke-Pumped $s.DockerPath @('info','--format','{{.OSType}}|{{.MemTotal}}') 15 $Pump
  if($info.Code -eq 0 -and $info.Out.Trim()){
   $parts=$info.Out.Trim().Split('|'); $s.OsType=$parts[0]; $s.MemGb=[math]::Round([double]$parts[1]/1GB,1); $s.EngineOk=($parts[0] -eq 'linux')
   $compose=Invoke-Pumped $s.DockerPath @('compose','version','--short') 15 $Pump; if($compose.Code -eq 0){$s.Compose=$compose.Out.Trim()}
   $images=Invoke-Pumped $s.DockerPath @('images','-q','openkritt-he-backend') 15 $Pump; $s.ImagesBuilt=[bool]$images.Out.Trim()
   $running=Invoke-Pumped $s.DockerPath @('inspect','--format','{{.State.Running}}','open-kritt-engine') 15 $Pump; $s.EngineRunning=($running.Code -eq 0 -and $running.Out.Trim() -eq 'true')
  }
 }
 return [pscustomobject]$s
}

function Get-NetworkState {
 # Classifies every host and groups the certificate problems by the root that
 # Windows already trusts. Returns Probe, Rows and Candidates.
 param([string]$Docker,[string]$CertificateFolder,[scriptblock]$Pump={})
 $approved=@(if(Test-Path -LiteralPath $CertificateFolder){Get-ChildItem -LiteralPath $CertificateFolder -Filter '*.crt'|ForEach-Object{[IO.File]::ReadAllText($_.FullName)}})
 $probe=Invoke-ContainerProbe -Docker $Docker -Pump $Pump -ApprovedPems $approved
 $rows=@(); $byRoot=@{}; $unknownRoot=$false; $approvedPending=@()
 if($probe.Ok){
  foreach($r in $probe.Results){
   $class=Get-ProbeClass $r; $purpose=($script:ProbeHosts|Where-Object {$_.Host -eq $r.host}).Purpose; $rootName=''
   if($class -eq 'certificate'){
    $root=Find-TrustedRootForChain -ChainPems @($r.chain|ForEach-Object{$_.pem})
    if(-not $root){$unknownRoot=$true}
    else{
     $rootName=$root.GetNameInfo('SimpleName',$false)
     if(Test-Path -LiteralPath (Join-Path $CertificateFolder ($root.Thumbprint+'.crt'))){$approvedPending+=$root.Thumbprint}
     else{if(-not $byRoot.ContainsKey($root.Thumbprint)){$byRoot[$root.Thumbprint]=@{Root=$root;Hosts=@()}}; $byRoot[$root.Thumbprint].Hosts+=$r.host}
    }
   }
   $rows+=[pscustomobject]@{Host=$r.host;Purpose=$purpose;Class=$class;Root=$rootName}
  }
 }
 $candidates=@(foreach($entry in $byRoot.Values){[pscustomobject]@{Root=$entry.Root;Hosts=$entry.Hosts;Origin=(Get-RootOrigin $entry.Root)}})
 return [pscustomobject]@{Probe=$probe;Rows=$rows;Candidates=$candidates;UnknownRoot=$unknownRoot;ApprovedPending=@($approvedPending|Select-Object -Unique)}
}

function Save-ApprovedCertificate {
 param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$Folder)
 $reason=Test-PublicCaCertificate $Certificate; if($reason){throw $reason}
 [void][IO.Directory]::CreateDirectory($Folder)
 $pem="-----BEGIN CERTIFICATE-----`n"+[Convert]::ToBase64String($Certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks)+"`n-----END CERTIFICATE-----`n"
 $path=Join-Path $Folder ($Certificate.Thumbprint.ToUpperInvariant()+'.crt')
 [IO.File]::WriteAllText($path,$pem,(New-Object Text.UTF8Encoding($false)))
 return $path
}

function Get-CertificateDescription([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$Origin,[string[]]$Hosts){
 $originText=switch($Origin){'public'{'רשות ציבורית מוכרת של Microsoft'} 'local'{'רשות שהותקנה במחשב הזה (למשל סינון, אנטי־וירוס או מנהל רשת)'} default{'מקור לא ידוע'}}
 return ('שם הרשות: '+$Certificate.GetNameInfo('SimpleName',$false)+"`n"+'נושא מלא: '+$Certificate.Subject+"`n"+'מקור: '+$originText+"`n"+'בתוקף: '+$Certificate.NotBefore.ToString('dd/MM/yyyy')+' עד '+$Certificate.NotAfter.ToString('dd/MM/yyyy')+"`n"+'טביעת אצבע SHA-1: '+$Certificate.Thumbprint+"`n"+'טביעת אצבע SHA-256: '+(Get-Sha256 $Certificate)+"`n"+'נדרשת עבור: '+($Hosts -join ', '))
}

# ---------- optional vendor CLIs (Cursor Agent, Grok Build) ----------
# The pinned versions and official SHA-256 values are read from engine/Dockerfile,
# so the wizard and the build can never disagree.
function Get-VendorPins([string]$ApplicationRoot){
 $text=[IO.File]::ReadAllText((Join-Path $ApplicationRoot 'engine\Dockerfile'))
 $cursorVersion=[regex]::Match($text,'ARG CURSOR_AGENT_VERSION=(\S+)').Groups[1].Value
 $grokVersion=[regex]::Match($text,'ARG GROK_BUILD_VERSION=(\S+)').Groups[1].Value
 $cursorSha=[regex]::Match($text,'amd64\) cursor_arch=x64; cursor_sha256=([a-f0-9]{64})').Groups[1].Value
 $grokSha=[regex]::Match($text,'amd64\) grok_arch=linux-x86_64; grok_sha256=([a-f0-9]{64})').Groups[1].Value
 if(-not ($cursorVersion -and $grokVersion -and $cursorSha -and $grokSha)){throw 'לא ניתן לקרוא את גרסאות Cursor ו־Grok מקובץ הבנייה.'}
 return @(
  [pscustomobject]@{Key='cursor';Name='Cursor';Version=$cursorVersion;Sha256=$cursorSha;FileName="cursor-agent-$cursorVersion-linux-x64.tar.gz";Url="https://downloads.cursor.com/lab/$cursorVersion/linux/x64/agent-cli-package.tar.gz";Terms='https://cursor.com/terms-of-service'},
  [pscustomobject]@{Key='grok';Name='Grok Build';Version=$grokVersion;Sha256=$grokSha;FileName="grok-$grokVersion-linux-x86_64";Url="https://x.ai/cli/grok-$grokVersion-linux-x86_64";Terms='https://x.ai/legal/terms-of-service'}
 )
}

function Get-FileSha256([string]$Path){ return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Add-VendorFile {
 # Accepts a downloaded file only when it is byte-identical to the official one.
 param([string]$Path,[string]$ApplicationRoot)
 $digest=Get-FileSha256 $Path
 $pin=@(Get-VendorPins $ApplicationRoot | Where-Object {$_.Sha256 -eq $digest})[0]
 if(-not $pin){throw ('הקובץ אינו זהה לגרסה הרשמית הנעולה של Cursor או Grok, ולכן לא ישמש. טביעת הקובץ: '+$digest)}
 $folder=Join-Path $ApplicationRoot 'vendor-cache'; [void][IO.Directory]::CreateDirectory($folder)
 Copy-Item -LiteralPath $Path -Destination (Join-Path $folder $pin.FileName) -Force
 return $pin
}

function Get-VendorStatus {
 # For each optional CLI: is a verified local copy present, or can one be found
 # among the usual download folders?
 param([string]$ApplicationRoot,[string]$InstallationRoot)
 $folders=@((Join-Path $ApplicationRoot 'vendor-cache'),(Join-Path $InstallationRoot 'downloads'),(Join-Path $env:USERPROFILE 'Downloads'))|Where-Object {Test-Path -LiteralPath $_}
 foreach($pin in Get-VendorPins $ApplicationRoot){
  $cached=Join-Path (Join-Path $ApplicationRoot 'vendor-cache') $pin.FileName
  $ready=(Test-Path -LiteralPath $cached) -and ((Get-FileSha256 $cached) -eq $pin.Sha256)
  $found=$null
  if(-not $ready){
   $patterns=if($pin.Key -eq 'cursor'){@('cursor-agent*.tar.gz','agent-cli-package*.tar.gz')}else{@('grok-*')}
   foreach($folder in $folders){foreach($pattern in $patterns){foreach($file in Get-ChildItem -LiteralPath $folder -Filter $pattern -File -ErrorAction SilentlyContinue|Where-Object {$_.Length -lt 300MB}){if(-not $found -and (Get-FileSha256 $file.FullName) -eq $pin.Sha256){$found=$file.FullName}}}}
  }
  [pscustomobject]@{Pin=$pin;Ready=$ready;Found=$found}
 }
}
