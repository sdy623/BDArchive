[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Python,[string]$DwarfsBin,[string]$WorkRoot=(Join-Path $PSScriptRoot '../work/summary-tests'))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$config=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.json'))
$config.archive_root=Join-Path $run 'archive';$config.catalog_path=Join-Path $run 'catalog.sqlite';$config.tools.python=$Python
if ($DwarfsBin) { $config.tools.dwarfs_bin=$DwarfsBin }
$configPath=Join-Path $run 'config.json';Write-Json $configPath $config
$source=Join-Path $run 'SYNTHETIC-IPHONE'
& $Python (Join-Path $PSScriptRoot 'make_iphone_fixture.py') $source
if ($LASTEXITCODE -ne 0) { throw 'Fixture failed.' }
function Step($Command,$Extra=@{}) {
    $p=@{Config=$configPath;Execute=$true;Category='III';SetId='IPH-2025-0117';Summary='Synthetic example only'}
    foreach ($key in $Extra.Keys) { $p[$key]=$Extra[$key] }
    Invoke-Archive -Command $Command -Parameters $p
}
function Assert($OK,$Message) { if (!$OK) { throw $Message } }
$null=Step init;$null=Step scan @{Source=$source};$null=Step plan
$ingestHash=File-Hash (Join-Path (Set-Dir $config 'IPH-2025-0117') 'ingest.json')
$summary=Step summary @{Device='iPhone 13';DiscSetLabel='IPA-001';PasswordStorage='password manager'}
$text=[IO.File]::ReadAllText($summary.txt);$json=Read-Json $summary.json
Assert ($text.Contains('Device: iPhone 13')) 'Device override missing'
Assert ($text.Contains('Encrypted: YES')) 'Encryption metadata missing'
Assert ($text.Contains('2025-01-17')) 'Binary plist date missing'
Assert ($text.Contains('IPA-001 (label)')) 'User disc-set label missing'
Assert ($text.Contains('BD-B-0001')) 'Physical disc missing'
Assert ($text.Contains('stored in password manager')) 'Password storage label missing'
Assert ($json.details.device_source -eq 'user supplied') 'Provenance missing'
Assert ($json.details.backup_folder_id -eq '***') 'Folder ID not masked'
Assert ((File-Hash (Join-Path (Set-Dir $config 'IPH-2025-0117') 'ingest.json')) -eq $ingestHash) 'Summary mutated ingest'
if ($DwarfsBin) {
    $null=Step build @{DiscId='BD-B-0001'};$null=Step stage @{DiscId='BD-B-0001'}
    $stage=(Get-Disc $config 'BD-B-0001').stage.path
    Assert (Test-Path -LiteralPath (Join-Path $stage 'ARCHIVE-SUMMARY.txt')) 'Disc summary missing'
    $seal=File-Hash (Join-Path $stage 'SHA256SUMS')
    $stageSummaryHash=File-Hash (Join-Path $stage 'ARCHIVE-SUMMARY.txt')
    $null=Step summary @{SecondCopy='Not created; operator note only'}
    Assert ((File-Hash (Join-Path $stage 'SHA256SUMS')) -eq $seal) 'Summary change modified sealed checksums'
    Assert ((File-Hash (Join-Path $stage 'ARCHIVE-SUMMARY.txt')) -eq $stageSummaryHash) 'Summary change modified sealed snapshot'
    $null=Step burn @{DiscId='BD-B-0001';Simulate=$true};$null=Step verify @{DiscId='BD-B-0001';Simulate=$true}
    $null=Step register @{DiscId='BD-B-0001';Location='SYNTHETIC / no disc'}
}
$saved=File-Hash $summary.txt
[IO.File]::AppendAllText((Join-Path $source 'Manifest.plist'),'changed after snapshot')
$refused=$false
try { $null=Step summary @{RefreshMetadata=$true} } catch { $refused=$true }
Assert $refused 'Changed metadata refresh was accepted'
Assert ((File-Hash $summary.txt) -eq $saved) 'Failed refresh replaced cached summary'
Write-Json (Join-Path $run 'summary-test.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();live_dwarfs=[bool]$DwarfsBin;summary=$summary.txt}
Write-Host "Summary integration PASS: $run"
