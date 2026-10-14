<# Read-only local dependency inventory. No tool installation or optical access. #>
[CmdletBinding()]
param([string]$Config)
$ErrorActionPreference='Stop'
if (!$Config) { $Config=Join-Path $PSScriptRoot '../archive.config.json' }
Import-Module (Join-Path $PSScriptRoot 'Archive.Core.psm1') -Force -DisableNameChecking
$c=Load-Config $Config
Get-ArchiveToolInventory $c | ConvertTo-Json -Depth 6
