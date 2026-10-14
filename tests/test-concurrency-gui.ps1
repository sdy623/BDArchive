param([string]$WorkRoot,[string]$Python,[string]$DwarfsBin)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) {$WorkRoot=Join-Path $PSScriptRoot '../work/concurrent-ui'}
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python;$c.tools.dwarfs_bin=$DwarfsBin
$c.dwarfs.build_profile='verified';$c.dwarfs.compression_level=9;$c.dwarfs.workers=1;$c.planning.par2_percent=0
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$small=Join-Path $run 'photo';Write-Text (Join-Path $small 'small.raw') 'fixture'
$p=@{Config=$cfg;SetId='B';Scenario='photo';Category='I';Source=$small;ParPercent=0;Execute=$true}
$null=Invoke-Archive init $p;$null=Invoke-Archive scan $p;$null=Invoke-Archive plan $p
$id=(Load-Plan $c 'B').discs[0].disc_id;$null=Invoke-Archive stage @{Config=$cfg;DiscId=$id;Execute=$true}
$source=Join-Path $run 'backup';[IO.Directory]::CreateDirectory($source)|Out-Null
$bytes=New-Object byte[] (64MB);$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
try {$rng.GetBytes($bytes);[IO.File]::WriteAllBytes((Join-Path $source 'data.bin'),$bytes)} finally {$rng.Dispose()};$bytes=$null
$fixture=Join-Path $run 'fixture.json';Write-Json $fixture @{prepare=@{Config=$cfg;SetId='A';Scenario='backup';Source=$source;ParPercent=0;Execute=$true};burn=@{Config=$cfg;DiscId=$id;Execute=$true;Simulate=$true}}
& (Join-Path $PSScriptRoot '../scripts/archive-ui.ps1') -Config $cfg -SmokeTest -ExerciseConcurrentJobs -ConcurrentTestFixture $fixture -TestNarrowWindow -DiagnosticsPath (Join-Path $run 'gui.json') -PreviewPath (Join-Path $run 'gui.png')
Write-Host "Results: $run"
