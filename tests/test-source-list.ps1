[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/source-list'),[Parameter(Mandatory=$true)][string]$DwarfsBin,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.example.json'))
$c.tools.python=$Python
$c.dwarfs.build_profile='verified';$c.dwarfs.skip_roundtrip=$false
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.dwarfs_bin=$DwarfsBin
$c.media.BD25.dwarfs_payload_gib=0.0015;$c.planning.dwarfs_overhead_mib=0.1;$c.dwarfs.compression_level=1
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$source=Join-Path $run '备份 空格'
foreach ($path in @('a 空格/一.bin','b/二 file.bin','c/third.bin')) {
    $full=Safe-Join $source $path;[IO.Directory]::CreateDirectory((Split-Path $full)) | Out-Null
    [IO.File]::WriteAllBytes($full,(New-Object byte[] 716800))
}
Write-Text (Join-Path $source 'Manifest.db') 'synthetic root metadata'
$p=@{Config=$cfg;SetId='LIST-TEST';Scenario='backup';Source=$source;Execute=$true;Media='BD25';ParPercent=0}
$null=Invoke-Archive init $p;$null=Invoke-Archive scan $p;$null=Invoke-Archive plan $p
$plan=Load-Plan $c $p.SetId
if ($plan.discs.Count -lt 2) { throw 'Fixture did not split' }
$results=@()
foreach ($disc in $plan.discs) {
    $p.DiscId=$disc.disc_id;$null=Invoke-Archive build $p;$null=Invoke-Archive stage $p
    $dir=Join-Path $c.archive_root ('build/'+$disc.disc_id);$build=Read-Json (Join-Path $dir 'build.json')
    if ((Test-Path (Join-Path $dir 'input')) -or $build.input_mode -ne 'SOURCE_LIST' -or $build.roundtrip -ne 'PASS') { throw 'Build did not use source list' }
    $selected=[IO.File]::ReadAllLines($build.input_list,(New-Object Text.UTF8Encoding($false)))
    if (@(Compare-Object @($disc.files.path | Sort-Object) @($selected | Sort-Object)).Count) { throw 'Input selection mismatch' }
    if ($build.roundtrip_mode -ne 'STREAM' -or (Test-Path (Join-Path $dir 'roundtrip'))) { throw 'Roundtrip must stream without a payload tree' }
    if (@((Read-Json (Join-Path $dir 'stream-expected.json')) | Where-Object path -eq 'Manifest.db').Count -ne 1) { throw 'Root metadata missing from verified stream' }
    $target=Join-Path $c.archive_root ('staging/'+$disc.disc_id+'/data/'+$disc.disc_id+'.dwarfs')
    if ([ArchiveFileLinks]::Identity($build.image) -ne [ArchiveFileLinks]::Identity($target)) { throw 'DwarFS image was duplicated into staging' }
    $results+=@{disc=$disc.disc_id;status='PASS';input_copy=$false;independent_roundtrip=$true;staging_mode='HARDLINK';files=$disc.files.Count}
}
Write-Json (Join-Path $run 'source-list-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results;physical_burn=$false}
Write-Host "PASS selected Unicode/space paths, independent shards, repeated metadata and shared image staging: $run"

