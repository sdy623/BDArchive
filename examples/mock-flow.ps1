[CmdletBinding()]
param([string]$Python='',[string]$WorkRoot=(Join-Path $PSScriptRoot '../work/mock'))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$source=Join-Path $run 'source';$destination=Join-Path $run 'restored'
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.json'))
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite'
$c.tools.python=$Python;$c.planning.par2_percent=0
$config=Join-Path $run 'mock.config.json';Write-Json $config $c
Write-Text (Join-Path $source 'photos/example.raw') 'Synthetic RAW placeholder, not a photograph.'
Write-Text (Join-Path $source 'photos/example-copy.raw') 'Synthetic RAW placeholder, not a photograph.'
function Step($Command,$Extra=@{}) {
    $p=@{Config=$config;Execute=$true;Category='I';Summary='Synthetic demo only'}
    foreach ($key in $Extra.Keys) { $p[$key]=$Extra[$key] }
    Invoke-Archive -Command $Command -Parameters $p
}
$null=Step init
$null=Step scan @{SetId='MOCK-PHOTO';Source=$source;DetectDuplicates=$true}
$null=Step plan @{SetId='MOCK-PHOTO';Deduplicate=$true}
$null=Step stage @{DiscId='BD-P-0001'}
$null=Step burn @{DiscId='BD-P-0001';Simulate=$true}
$null=Step verify @{DiscId='BD-P-0001';Simulate=$true}
$null=Step register @{DiscId='BD-P-0001';Location='DEMO / no physical disc'}
$r=Step restore @{SetId='MOCK-PHOTO';MediaRoots=@((Get-Disc $c 'BD-P-0001').burn.root);Output=$destination}
Write-Host "Mock completed: $($r.status). No optical disc accessed; source files retained."
Write-Host "Inspect: $run"
Write-Host "Config: $config"
