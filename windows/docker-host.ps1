# Which Docker engine this installation uses, and how to call it.
#  desktop: Docker Desktop's docker.exe.
#  wsl:     a dedicated WSL 2 distribution ("OpenKritt": Alpine minirootfs pinned by
#           SHA-256, Docker engine from Alpine's signed repository, Apache-2.0, no
#           Docker Desktop subscription). docker runs inside it through wsl.exe and
#           Windows paths in arguments are translated to /mnt/<drive>/...
# Security: the WSL engine is never exposed on a TCP port (a web page could otherwise
# drive it); only this Windows user's processes can run wsl.exe. Memory comes from the
# existing WSL limit; .wslconfig is never changed.
# Library only (no param block, so dot-sourcing never overwrites the caller's variables).
$script:WslDistro='OpenKritt'
$script:WslAlpine=@{Version='3.24.2';File='alpine-minirootfs-3.24.2-x86_64.tar.gz';Sha256='c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677';Url='https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-minirootfs-3.24.2-x86_64.tar.gz'}
$script:WslPump={}
$env:WSL_UTF8='1' # wsl.exe prints UTF-16 unless asked for UTF-8

function ConvertTo-CommandLine([string[]]$Arguments){
 # Quote only when needed: wsl.exe does not recognise its own options when quoted.
 return ($Arguments|ForEach-Object{ if($_ -ne '' -and $_ -notmatch '[\s"]'){$_}else{'"'+(($_ -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1')+'"'} }) -join ' '
}

function Invoke-Wsl([string[]]$Arguments,[int]$TimeoutSeconds=120){
 $p=New-Object Diagnostics.Process; $p.StartInfo.FileName='wsl.exe'; $p.StartInfo.Arguments=ConvertTo-CommandLine $Arguments
 $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true; $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
 $p.StartInfo.StandardOutputEncoding=[Text.Encoding]::UTF8; $p.StartInfo.StandardErrorEncoding=[Text.Encoding]::UTF8
 [void]$p.Start(); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync()
 # A window can set $script:WslPump so it stays responsive during long installs.
 $timer=[Diagnostics.Stopwatch]::StartNew()
 while(-not $p.WaitForExit(100)){ & $script:WslPump; if($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds){try{$p.Kill()}catch{}; throw 'פקודת WSL חרגה מזמן ההמתנה.'} }
 $p.WaitForExit(); $r=[pscustomobject]@{Code=$p.ExitCode;Out=$o.Result;Err=$e.Result}; $p.Dispose(); return $r
}

function Test-WslAvailable { return [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue) -and (Invoke-Wsl @('--status') 30).Code -eq 0 }

function Test-WslEngineInstalled([string]$Name=$script:WslDistro){
 if(-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)){return $false}
 $list=Invoke-Wsl @('--list','--quiet') 30
 return @($list.Out -split "`r?`n" | ForEach-Object { $_.Trim([char]0,' ') }) -contains $Name
}

function ConvertTo-WslPath([string]$WindowsPath){
 # D:\a\b -> /mnt/d/a/b (Hebrew and spaces are kept as they are).
 $full=[IO.Path]::GetFullPath($WindowsPath)
 if($full -notmatch '^([A-Za-z]):\\(.*)$'){throw 'נתיב לא נתמך: '+$WindowsPath}
 return ('/mnt/'+$Matches[1].ToLowerInvariant()+'/'+($Matches[2] -replace '\\','/')).TrimEnd('/')
}

function Sync-WslCertificates([string]$Root,[string]$Name=$script:WslDistro){
 # Mirrors the certificates the user approved in the wizard (and only those).
 # Returns $true when the set of certificates changed.
 $fingerprint='cat /usr/local/share/ca-certificates/open-kritt-*.crt 2>/dev/null | sha256sum'
 $before=(Invoke-Wsl @('-d',$Name,'-u','root','--exec','sh','-c',$fingerprint) 60).Out
 $folder=Join-Path $Root 'certificates'
 [void](Invoke-Wsl @('-d',$Name,'-u','root','--exec','sh','-c','mkdir -p /usr/local/share/ca-certificates && rm -f /usr/local/share/ca-certificates/open-kritt-*.crt') 60)
 if(Test-Path -LiteralPath $folder){
  foreach($certificate in Get-ChildItem -LiteralPath $folder -Filter '*.crt'){
   [void](Invoke-Wsl @('-d',$Name,'-u','root','--exec','cp',(ConvertTo-WslPath $certificate.FullName),('/usr/local/share/ca-certificates/open-kritt-'+$certificate.Name)) 60)
  }
 }
 [void](Invoke-Wsl @('-d',$Name,'-u','root','--exec','sh','-c','command -v update-ca-certificates >/dev/null && update-ca-certificates --fresh >/dev/null 2>&1 || true') 120)
 return $before -ne (Invoke-Wsl @('-d',$Name,'-u','root','--exec','sh','-c',$fingerprint) 60).Out
}

function Install-WslEngine([string]$Root,[string]$Name=$script:WslDistro,[string]$DaemonJson=''){
 # DaemonJson: optional /etc/docker/daemon.json (tests use it to keep the engine off the shared network).
 if(-not (Test-WslAvailable)){throw 'רכיב WSL של Windows אינו מותקן או כבוי. התקינו אותו מ"תכונות Windows" (או בפקודה wsl --install) והפעילו מחדש את המחשב.'}
 if(Test-WslEngineInstalled $Name){return 'already-installed'}
 $downloads=Join-Path $Root 'downloads'; [void][IO.Directory]::CreateDirectory($downloads)
 $tarball=Join-Path $downloads $script:WslAlpine.File
 if(-not (Test-Path -LiteralPath $tarball) -or (Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant() -ne $script:WslAlpine.Sha256){
  [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $script:WslAlpine.Url -OutFile $tarball -TimeoutSec 300
 }
 if((Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant() -ne $script:WslAlpine.Sha256){Remove-Item -LiteralPath $tarball -Force; throw 'קובץ המערכת שהורד אינו זהה לגרסה הרשמית של Alpine. ההתקנה נעצרה.'}
 $target=Join-Path $Root 'wsl-engine'; [void][IO.Directory]::CreateDirectory($target)
 $import=Invoke-Wsl @('--import',$Name,$target,$tarball,'--version','2') 600
 if($import.Code -ne 0){throw ('יצירת סביבת WSL נכשלה: '+($import.Err+$import.Out).Trim())}
 # Approved network CAs first, so the package repository works behind a TLS-inspecting filter.
 [void](Sync-WslCertificates $Root $Name)
 $setup=@'
set -e
cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
apk update
apk add --no-cache ca-certificates docker docker-cli-compose
update-ca-certificates --fresh >/dev/null 2>&1 || true
mkdir -p /etc/docker
if [ -n "$OPEN_KRITT_DAEMON_JSON" ]; then printf '%s' "$OPEN_KRITT_DAEMON_JSON" | base64 -d > /etc/docker/daemon.json; fi
cat > /usr/local/bin/open-kritt-dockerd <<'EOF'
#!/bin/sh
# WSL starts boot commands without PATH; dockerd needs it to find docker-proxy.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
pgrep -x dockerd >/dev/null 2>&1 && exit 0
mkdir -p /var/log
nohup dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
EOF
chmod 0755 /usr/local/bin/open-kritt-dockerd
cat > /etc/wsl.conf <<'EOF'
[boot]
command = /usr/local/bin/open-kritt-dockerd
[automount]
options = "metadata"
[interop]
appendWindowsPath = false
EOF
'@
 $setup=$setup -replace "`r",'' # the distribution stores .ps1 files with CRLF; sh needs LF
 $daemon=$(if($DaemonJson){[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DaemonJson))}else{''})
 $result=Invoke-Wsl @('-d',$Name,'-u','root','--exec','env',('OPEN_KRITT_DAEMON_JSON='+$daemon),'sh','-c',$setup) 900
 if($result.Code -ne 0){throw ('התקנת מנוע Docker בסביבת WSL נכשלה. פרטים: '+(($result.Err+$result.Out) -split "`n" | Select-Object -Last 4) -join ' ')}
 [void](Invoke-Wsl @('--terminate',$Name) 60)
 return 'installed'
}

function Test-WslEngineRunning([string]$Name=$script:WslDistro){
 return (Invoke-Wsl @('-d',$Name,'-u','root','--exec','docker','info','--format','{{.OSType}}') 30).Out.Trim() -eq 'linux'
}

function Start-WslEngine([string]$Root='',[string]$Name=$script:WslDistro,[int]$WaitSeconds=60){
 # Certificates first: dockerd reads the trust store once, when it starts, so a
 # newly approved (or removed) certificate restarts the engine.
 if($Root -and (Sync-WslCertificates $Root $Name) -and (Test-WslEngineRunning $Name)){Stop-WslEngine $Name}
 [void](Invoke-Wsl @('-d',$Name,'-u','root','--exec','/usr/local/bin/open-kritt-dockerd') 60)
 $until=(Get-Date).AddSeconds($WaitSeconds)
 do{ if(Test-WslEngineRunning $Name){return $true}; Start-Sleep -Seconds 2 }while((Get-Date) -lt $until)
 return $false
}

function Stop-WslEngine([string]$Name=$script:WslDistro){ [void](Invoke-Wsl @('--terminate',$Name) 60) }

function Remove-WslEngine([string]$Name=$script:WslDistro){
 # Deletes the distribution together with every image, container and volume inside it.
 if(Test-WslEngineInstalled $Name){ $r=Invoke-Wsl @('--unregister',$Name) 300; if($r.Code -ne 0){throw 'הסרת סביבת WSL נכשלה.'} }
}

function Get-DesktopDockerPath {
 $command=Get-Command docker.exe -ErrorAction SilentlyContinue; if($command){return $command.Source}
 return (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe')
}

function Get-DockerEngineMode([string]$EnvironmentFile){
 # The installer records the choice in .env; older installations use Docker Desktop.
 if($EnvironmentFile -and (Test-Path -LiteralPath $EnvironmentFile)){
  $line=[regex]::Match([IO.File]::ReadAllText($EnvironmentFile),'(?m)^OPEN_KRITT_DOCKER_ENGINE=(wsl|desktop)\s*$')
  if($line.Success){return $line.Groups[1].Value}
 }
 return 'desktop'
}

function Get-DockerCall([string]$Mode,[string[]]$Arguments){
 # File and argument list for one docker command in the chosen engine.
 if($Mode -ne 'wsl'){ $list=@($Arguments) ; return [pscustomobject]@{File=(Get-DesktopDockerPath);List=$list;CommandLine=(ConvertTo-CommandLine $list)} }
 $translated=foreach($argument in $Arguments){ if($argument -match '^[A-Za-z]:\\'){ConvertTo-WslPath $argument}else{$argument} }
 $list=@('-d',$script:WslDistro,'-u','root','--exec','docker')+@($translated)
 return [pscustomobject]@{File='wsl.exe';List=$list;CommandLine=(ConvertTo-CommandLine $list)}
}

function Test-DockerEngineInstalled([string]$Mode){
 if($Mode -eq 'wsl'){return Test-WslEngineInstalled}
 return Test-Path -LiteralPath (Get-DesktopDockerPath)
}

function Get-DockerDataMountPath([string]$Mode,[string]$ApplicationRoot){
 # Absolute path of app\.data\engine as the Docker engine sees it (for scan runners).
 if($Mode -eq 'wsl'){return (ConvertTo-WslPath $ApplicationRoot)+'/.data/engine'}
 return '/run/desktop/mnt/host/'+$ApplicationRoot.Substring(0,1).ToLowerInvariant()+'/'+$ApplicationRoot.Substring(3).Replace('\','/').TrimEnd('/')+'/.data/engine'
}

function Get-DockerEngineName([string]$Mode){ if($Mode -eq 'wsl'){return 'מנוע Docker המובנה (WSL)'}; return 'Docker Desktop' }
