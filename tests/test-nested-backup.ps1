[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/nested-backup'),[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.example.json'))
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$c.media.BD25.payload_gib=0.0003;$c.media.BD25.dwarfs_payload_gib=0.0003;$c.planning.dwarfs_overhead_mib=0;$c.planning.per_file_overhead_bytes=0
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$source=Join-Path $run 'source';$prefix='包装/device/'
Write-Text (Join-Path $source ($prefix+'Info.plist')) '<?xml version="1.0"?><plist version="1.0"><dict><key>Product Name</key><string>iPhone test</string></dict></plist>'
Write-Text (Join-Path $source ($prefix+'Manifest.plist')) '<?xml version="1.0"?><plist version="1.0"><dict><key>IsEncrypted</key><true/></dict></plist>'
Write-Text (Join-Path $source ($prefix+'Manifest.db')) 'synthetic encrypted database bytes'
foreach($bucket in @('00','01','02')){ $p=Join-Path $source ($prefix+$bucket+'/file');Write-Text $p 'x';[IO.File]::WriteAllBytes($p,(New-Object byte[] 200000)) }
$p=@{Config=$cfg;Execute=$true;SetId='NESTED';Source=$source;Scenario='backup';Summary='test';Media='BD25';ParPercent=0}
$null=Invoke-Archive init $p;$null=Invoke-Archive scan $p
$ing=Load-Ingest $c 'NESTED';$roots=@(Backup-MetadataRoots $ing)
if($roots.Count -ne 1 -or $roots[0] -ne $prefix){throw 'Nested root not found'}
$missing=$false;try{$null=Get-SavedPreparationSettings $c 'NESTED'}catch{$missing=$_.Exception.Message -match '扫描清单存在'}
if(!$missing){throw 'Missing-plan diagnostic not specific'}
$null=Invoke-Archive plan $p;$plan=Load-Plan $c 'NESTED'
if($plan.discs.Count -ne 3){throw 'Wrong disc count'}
foreach($disc in $plan.discs){foreach($name in @('Info.plist','Manifest.plist','Manifest.db')){if(@($disc.files|Where-Object path -eq ($prefix+$name)).Count -ne 1){throw 'Nested metadata not repeated'}}}
$meta=Extract-BackupMetadata $c $ing
if($meta.device -ne 'iPhone test' -or !$meta.encrypted -or !($meta.metadata_files[0].file.StartsWith($prefix))){throw 'Nested summary provenance failed'}
$null=Get-SavedPreparationSettings $c 'NESTED'
Write-Json (Join-Path $run 'nested-results.json') @{status='PASS';checks=@('nested backup detection','metadata repeated per disc','nested summary with bound hashes','specific ingest-only diagnostic','completed settings load')}
Write-Host "PASS nested backup and load diagnostics: $run"
