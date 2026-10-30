[CmdletBinding()]
param()
# Kept for older shortcuts and guides: opens the installation and repair wizard.
& (Join-Path $PSScriptRoot 'prepare.ps1') -InstallationRoot $PSScriptRoot -Mode Repair
