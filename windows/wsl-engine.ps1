[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Install','Start','Stop','Status','Remove')][string]$Action,[string]$InstallationRoot='')
# Command-line front end for the built-in Docker engine (see docker-host.ps1).
# "Remove" deletes the WSL distribution with every image, container and volume in it.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'docker-host.ps1')
if(-not $InstallationRoot){$InstallationRoot=$(if((Split-Path -Leaf $PSScriptRoot) -eq 'windows'){[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}else{$PSScriptRoot})}
switch($Action){
 'Install'{Install-WslEngine $InstallationRoot}
 'Start'{if(Start-WslEngine $InstallationRoot){'running'}else{throw 'מנוע Docker המובנה לא עלה. פרטים ב-/var/log/dockerd.log בתוך סביבת OpenKritt.'}}
 'Stop'{Stop-WslEngine; 'stopped'}
 'Status'{if(-not (Test-WslEngineInstalled)){'not-installed'}elseif(Test-WslEngineRunning){'running'}else{'stopped'}}
 'Remove'{Remove-WslEngine; 'removed'}
}
