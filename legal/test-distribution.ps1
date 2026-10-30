param([Parameter(Mandatory=$true)][string]$ReleaseRoot,[switch]$SkipDocker)
# Verifies a folder produced by legal/build-distribution.cjs. Every check prints
# PASS or throws; nothing outside a temporary verification copy is changed.
$ErrorActionPreference='Stop'
$ReleaseRoot=[IO.Path]::GetFullPath($ReleaseRoot)
$manifest=Get-Content -LiteralPath (Join-Path $ReleaseRoot 'SOURCE-MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# 1. Manifest, SHA256SUMS and the absence of private or binary artifacts.
$listed=@{}
foreach($entry in $manifest.files){
 $listed[$entry.path]=$true
 if($entry.path -match '(^|/)(node_modules|\.data|local-tools|\.git)(/|$)|\.(exe|dll|so|whl|dump|crt|cer|pem|key|p12|pfx|sqlite3?|db)$'){throw ('Private or binary artifact: '+$entry.path)}
 if($entry.path -match '(^|/)local_repos/.+' -and $entry.path -ne 'app/local_repos/.gitkeep'){throw ('Scan project data in package: '+$entry.path)}
 if($entry.path -match '^app/vendor-cache/.+' -and $entry.path -notin @('app/vendor-cache/.gitkeep','app/vendor-cache/README.txt')){throw ('Vendor binary in package: '+$entry.path)}
 if($entry.path -match '(^|/)local-certs/.+' -and $entry.path -notmatch '/local-certs/\.gitkeep$'){throw ('Certificate in build context: '+$entry.path)}
 if($entry.path -match '(^|/)\.env($|\.)' -and $entry.path -ne 'app/.env.example'){throw ('Environment file leaked: '+$entry.path)}
 if((Get-FileHash -LiteralPath (Join-Path $ReleaseRoot $entry.path) -Algorithm SHA256).Hash.ToLower() -ne $entry.sha256){throw ('Source manifest mismatch: '+$entry.path)}
}
foreach($file in Get-ChildItem -LiteralPath $ReleaseRoot -Recurse -File -Force){
 $relative=$file.FullName.Substring($ReleaseRoot.Length+1).Replace('\','/')
 if($relative -notin @('SOURCE-MANIFEST.json','SHA256SUMS.txt') -and -not $listed.ContainsKey($relative)){throw ('File not listed in manifest: '+$relative)}
}
$sums=Get-Content -LiteralPath (Join-Path $ReleaseRoot 'SHA256SUMS.txt') -Encoding UTF8
if($sums.Count -ne @($manifest.files).Count){throw 'SHA256SUMS.txt and SOURCE-MANIFEST.json disagree'}
foreach($line in $sums){ if($line -notmatch '^([a-f0-9]{64}) \*(.+)$'){throw ('Bad SHA256SUMS line: '+$line)}; if((Get-FileHash -LiteralPath (Join-Path $ReleaseRoot $Matches[2]) -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]){throw ('SHA256SUMS mismatch: '+$Matches[2])} }
Write-Output ('PASS: '+@($manifest.files).Count+' files match SOURCE-MANIFEST.json and SHA256SUMS.txt; no account data, certificates, scan data or vendor binaries')

# 2. Secrets and personal paths (independent of the builder's own scan).
$patterns=@('-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----','\bsk-ant-[A-Za-z0-9_-]{20,}','\bgh[pousr]_[A-Za-z0-9]{30,}','\bAKIA[0-9A-Z]{16}\b','427A~1','OpenKritt[\\/]')
$allowed='^app/(engine/tests/|backend/test/|legal/raw/|frontend/public/legal/texts/|legal/build-distribution\.cjs|legal/test-distribution\.ps1|engine/open_kritt_engine/security_rules\.json)'
foreach($entry in $manifest.files){
 if($entry.path -match $allowed){continue}
 $bytes=[IO.File]::ReadAllBytes((Join-Path $ReleaseRoot $entry.path)); if($bytes -contains 0){continue}
 $text=[Text.Encoding]::UTF8.GetString($bytes)
 foreach($pattern in $patterns){if($text -match $pattern){throw ('Secret or personal path pattern in '+$entry.path)}}
}
Write-Output 'PASS: no keys, tokens or publisher paths'

# 3. Line endings and encodings the target machines need.
foreach($entry in $manifest.files){
 $bytes=[IO.File]::ReadAllBytes((Join-Path $ReleaseRoot $entry.path))
 if($entry.path -match '\.ps1$'){if($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF){throw ('PowerShell script without UTF-8 BOM: '+$entry.path)}; continue}
 if($entry.path -match '(\.(sh|sql|py|js|mjs|cjs|jsx|json|yml)$|(^|/)Dockerfile[^/]*$|^app/kritt(-headless)?$)' -and $bytes -notcontains 0 -and ([Text.Encoding]::UTF8.GetString($bytes)).Contains("`r`n")){throw ('Windows line endings in Linux file: '+$entry.path)}
}
Write-Output 'PASS: LF line endings for container files; UTF-8 BOM for PowerShell scripts'

# 4. Required notices and credit.
foreach($required in @('app/LICENSE','app/NOTICE.md','app/THIRD_PARTY_NOTICES.md','app/OWNERSHIP.md','README-he.md','app/frontend/public/legal/inventory.json')){if(-not $listed.ContainsKey($required)){throw ('Missing notice: '+$required)}}
$notice=[IO.File]::ReadAllText((Join-Path $ReleaseRoot 'app/NOTICE.md'))
if($notice -notmatch 'Harel Rom' -or $notice -notmatch 'Gabriel Balko' -or $notice -notmatch 'ממתמחים טופ'){throw 'Original authors or Hebrew adaptation credit missing from NOTICE.md'}
Write-Output 'PASS: LICENSE, notices, inventory, original authors and adaptation credit present'

# 5. PowerShell syntax of every Windows script.
foreach($script in @('install.ps1','prepare.ps1','prepare-lib.ps1','manage.ps1','maintenance-agent.ps1','prepare-computer.ps1','docker-host.ps1','wsl-engine.ps1')){
 $tokens=$null; $errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $ReleaseRoot $script),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('PowerShell syntax error: '+$script+' '+$errors[0].Message)}
}
Write-Output 'PASS: PowerShell syntax of installer, wizard and managers'

# 6. A fresh preparation in a throwaway copy.
$parent=[IO.Path]::GetDirectoryName($ReleaseRoot)
$verification=Join-Path $parent ('verification-'+[guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($verification)
 foreach($item in Get-ChildItem -LiteralPath $ReleaseRoot -Force){Copy-Item -LiteralPath $item.FullName -Destination $verification -Recurse -Force}
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $verification 'install.ps1') -PrepareOnly
 if($LASTEXITCODE -ne 0){throw 'Installer preparation failed'}
 $environment=[IO.File]::ReadAllText((Join-Path $verification 'app/.env'))
 if($environment -notmatch '(?m)^POSTGRES_PASSWORD=[a-f0-9]{48}\r?$'){throw 'Database password is not freshly randomized'}
 if($environment -notmatch '(?m)^ENGINE_WORKER_COUNT=1\r?$'){throw 'Unexpected worker default'}
 if($environment -notmatch '(?m)^INSTALL_CURSOR=0\r?$' -or $environment -notmatch '(?m)^INSTALL_GROK=0\r?$'){throw 'Proprietary optional CLIs are not opt-in'}
 foreach($key in @('OPENAI_API_KEY','ANTHROPIC_API_KEY','OPENROUTER_API_KEY','XAI_API_KEY','GITHUB_TOKEN')){
  if($environment -match ('(?m)^'+$key+'=\S+')){throw 'Nonempty provider credential in new installation'}
 }
 foreach($component in @('frontend','backend','engine','database','executor-view')){if(@(Get-ChildItem -LiteralPath (Join-Path $verification ('app/'+$component+'/local-certs')) -Filter '*.crt').Count){throw 'Certificate copied into a fresh installation without approval'}}
 Write-Output 'PASS: fresh preparation, randomized password, empty credentials, opt-in vendor CLIs, no certificates'
 if(-not $SkipDocker){
  & docker compose --project-directory (Join-Path $verification 'app') -p openkritt-distribution-check config --quiet
  if($LASTEXITCODE -ne 0){throw 'Clean-install Docker Compose configuration is invalid'}
  Write-Output 'PASS: valid Docker Compose configuration for a clean installation'
 }
}finally{
 $resolved=[IO.Path]::GetFullPath($verification)
 $expectedParent=[IO.Path]::GetFullPath($parent)+[IO.Path]::DirectorySeparatorChar
 if($resolved.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^verification-[a-f0-9]{32}$' -and (Test-Path -LiteralPath $resolved)){
  if((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing to remove linked verification directory'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
