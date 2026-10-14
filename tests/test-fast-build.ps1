[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/fast-build'),[string]$Python,[string]$DwarfsBin)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$module=Get-Module Archive.Core;$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.example.json'))
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python;$c.tools.dwarfs_bin=$DwarfsBin
$c.media.BD25.dwarfs_payload_gib=0.01;$c.planning.dwarfs_overhead_mib=0.1
$c.dwarfs.build_profile='fast';$c.dwarfs.skip_roundtrip=$true
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$source=Join-Path $run 'source';for($i=0;$i -lt 20;$i++){Write-Text (Join-Path $source ('目录 空格/'+$i+'.bin')) ('abc'+$i)*2000}
$p=@{Config=$cfg;Execute=$true;Source=$source;Scenario='backup';SetId='FAST';ParPercent=0}
$null=Invoke-Archive init $p;$null=Invoke-Archive scan $p;$null=Invoke-Archive plan $p
$p.DiscId=(Load-Plan $c 'FAST').discs[0].disc_id
& $module {param($root) $script:testSource=$root;$script:originalHash=${function:File-Hash};Set-Item Function:script:File-Hash {param($Path) if($Path.StartsWith($script:testSource)){throw 'Unexpected repeated source SHA256'};& $script:originalHash $Path}} $source
$report=Invoke-Archive build $p
if($report.roundtrip -ne 'SKIPPED_FAST' -or $report.content_matches_ingest -ne 'NOT_CHECKED' -or $report.arguments -notcontains 'none' -or $report.arguments[$report.arguments.IndexOf('-l')+1] -ne '0'){throw 'Fast profile not applied'}
$dir=Split-Path $report.image;if(Test-Path (Join-Path $dir 'roundtrip')){throw 'Fast profile wrote roundtrip files'}
$null=Invoke-Archive stage $p
& $module { Set-Item Function:script:File-Hash $script:originalHash }
$c.dwarfs.skip_roundtrip=$false;Write-Json $cfg $c
$p.SetId='STREAM';$null=Invoke-Archive scan $p;$null=Invoke-Archive plan $p;$p.DiscId=(Load-Plan $c 'STREAM').discs[0].disc_id
$report=Invoke-Archive build $p
if($report.roundtrip -ne 'PASS' -or $report.roundtrip_mode -ne 'STREAM' -or (Test-Path (Join-Path (Split-Path $report.image) 'roundtrip'))){throw 'Stream roundtrip did not verify without extraction'}
$null=Invoke-Archive stage $p
Write-Text (Join-Path $run 'producer.py') "import sys,time`nwhile True:`n sys.stdout.buffer.write(b'x'*65536);sys.stdout.buffer.flush();time.sleep(.02)"
Write-Text (Join-Path $run 'consumer.py') "import sys,time`nwhile sys.stdin.buffer.read(65536):time.sleep(.02)"
$process=New-Object ArchiveStreamingProcess($Python,@((Join-Path $run 'consumer.py')),(Join-Path $run 'pipe-cancel.log'),$Python,@((Join-Path $run 'producer.py')))
$producer=$process.GetType().GetField('producer',[Reflection.BindingFlags]'NonPublic,Instance').GetValue($process)
Start-Sleep -Milliseconds 200;$process.StopOwnedProcess();$null=$process.Finish()
if(!$process.Process.HasExited -or !$producer.HasExited){throw 'Owned pipeline process survived stop'};$process.Dispose()
Write-Json (Join-Path $run 'fast-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();checks=@('no repeated source hashes','no compression/internal dedup','skip recorded without false PASS','fast stage sealing','stream hash roundtrip without payload files','owned pipeline cancellation')}
Write-Host "PASS fast build and streaming: $run"
