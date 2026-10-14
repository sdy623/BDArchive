param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) {$WorkRoot=Join-Path $PSScriptRoot '../work/concurrency'}
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$results=New-Object 'System.Collections.Generic.List[object]';$workers=New-Object 'System.Collections.Generic.List[object]'
function Assert($Value,$Message) {if (!$Value) {throw $Message}}
function Pass($Name) {$results.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name"}
function Launch($Value) {
    $path=Join-Path $run ([guid]::NewGuid().ToString('N')+'.json');$Value.config=$cfg;Write-Json $path $Value
    $start=New-ArchiveWorkerStartInfo (Get-Process -Id $PID).Path (Full-Path (Join-Path $PSScriptRoot 'concurrency-worker.ps1')) $path $false
    $proc=New-Object Diagnostics.Process;$proc.StartInfo=$start;$null=$proc.Start()
    $w=@{process=$proc;path=$path};$workers.Add($w);return $w
}
function Ready($Worker) {
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while (![IO.File]::Exists($Worker.path+'.ready')) {
        if ($Worker.process.HasExited -or [DateTime]::UtcNow -gt $deadline) {throw "Worker did not acquire its lock: $($Worker.path)"}
        [Threading.Thread]::Sleep(25)
    }
}
function Finish($Worker,[switch]$Release) {
    if ($Release) {Write-Text ($Worker.path+'.release') 'release'}
    Assert ($Worker.process.WaitForExit(30000)) 'Worker timeout.'
    $r=Read-Json ($Worker.path+'.result.json');Assert ($Worker.process.ExitCode -eq 0 -and $r.status -eq 'PASS') (ConvertTo-Json $r)
}
function Reject-Lock($Command,$Params,$TargetConfig=$c) {
    $blocked=$false;$held=@()
    try {$held=Enter-ArchiveOperationLocks $TargetConfig $Command $Params} catch {$blocked=$_.Exception.Message -match '资源正在使用'} finally {Exit-ArchiveOperationLocks $held}
    Assert $blocked ('Expected lock conflict: '+$Command)
}
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json')
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c;$null=Invoke-Archive init @{Config=$cfg;Execute=$true}
$src=Join-Path $run 'source';Write-Text (Join-Path $src 'a.raw') 'synthetic fixture'
foreach ($id in @('A','B','C','D','E','F')) {$null=Invoke-Archive scan @{Config=$cfg;Execute=$true;SetId=$id;Category='I';Source=$src}}
try {
    $w=Launch @{mode='hold';command='prepare';parameters=@{SetId='A'}};Ready $w
    $other=Enter-ArchiveOperationLocks $c 'prepare' @{SetId='B'};Exit-ArchiveOperationLocks $other
    Reject-Lock 'prepare' @{SetId='a'}
    Reject-Lock 'rename-set' @{SetId='B';NewSetId='OTHER'}
    Finish $w -Release
    Pass 'different sets overlap; same set is case insensitive; maintenance waits'
    $w=Launch @{mode='legacy'};Ready $w;Reject-Lock 'prepare' @{SetId='B'};Finish $w -Release
    Pass 'legacy exclusive archive.lock and new jobs remain mutually compatible'
    $signal=Join-Path $run 'start-planning'
    $planners=@();foreach ($id in @('A','B','C','D','E','F')) {$planners+=Launch @{mode='plan';set_id=$id;start=$signal}}
    Write-Text $signal 'go';foreach ($w in $planners) {Finish $w}
    $cat=Read-Json (Catalog-Path $c)
    Assert ($cat.discs.Count -eq 6 -and @($cat.discs.disc_id | Select-Object -Unique).Count -eq 6 -and @($cat.discs.disc_index | Select-Object -Unique).Count -eq 6 -and $cat.sequences.P -eq 6) 'Parallel plans lost records or reused an ID/index.'
    Pass 'six real planning processes allocate unique IDs and global indices'
    $a=@($cat.discs | Where-Object archive_set_id -eq 'A')[0].disc_id;$b=@($cat.discs | Where-Object archive_set_id -eq 'B')[0].disc_id
    $w=Launch @{mode='hold';command='prepare';parameters=@{SetId='A'}};Ready $w
    $other=Enter-ArchiveOperationLocks $c 'burn' @{DiscId=$b;Drive='Z:';Simulate=$false};Exit-ArchiveOperationLocks $other
    Reject-Lock 'burn' @{DiscId=$a;Drive='Z:';Simulate=$false};Finish $w -Release
    Pass 'prepare A coexists with burn B; burn A conflicts before physical code'
    $w=Launch @{mode='hold';command='burn';parameters=@{DiscId=$a;Drive='Z:';Simulate=$false}};Ready $w
    Reject-Lock 'verify' @{DiscId=$b;Drive='z:\';Simulate=$false}
    $c2=[pscustomobject]@{archive_root=(Join-Path $run 'another archive')}
    Reject-Lock 'verify' @{SetId='OUTSIDE';Drive='Z:';Simulate=$false} $c2
    $other=Enter-ArchiveOperationLocks $c 'burn' @{DiscId=$b;Drive='Y:';Simulate=$false};Exit-ArchiveOperationLocks $other
    Finish $w -Release
    Pass 'same optical drive is exclusive across different sets; another drive is independent'
    $summary=Launch @{mode='summary-pause';set_id='A'};Ready $summary
    $r=Get-Disc $c $b;$r.location='changed while A summary held old snapshot';Update-Disc $c $r
    Finish $summary -Release
    Assert ((Get-Disc $c $b).location -eq $r.location) 'Summary A overwrote unrelated disc B.'
    Pass 'summary commits merge their set without writing a stale whole catalog'
    $signal=Join-Path $run 'start-updates';$updates=@()
    foreach ($id in @($a,$b)) {$updates+=Launch @{mode='updates';disc_id=$id;start=$signal}}
    $readers=@();for ($i=0;$i -lt 3;$i++) {$readers+=Launch @{mode='readers';start=$signal}}
    Write-Text $signal 'go';foreach ($w in ($updates+$readers)) {Finish $w}
    Pass '900 concurrent JSON snapshots remain complete during catalog replacement'
    Assert ((Get-Disc $c $a).location -eq ($a+'-24') -and (Get-Disc $c $b).location -eq ($b+'-24')) 'Concurrent disc updates lost state.'
    $events=@([IO.File]::ReadAllLines((Join-Path $c.archive_root 'events.jsonl')) | ForEach-Object {ConvertFrom-Json $_} | Where-Object action -eq 'concurrency-fixture')
    Assert ($events.Count -eq 50) 'Event lines interleaved or disappeared.'
    $index=Read-Json (Join-Path $c.archive_root 'disc-index.json')
    Assert (@($index.discs | Where-Object location -like '*-24').Count -eq 2) 'Final index snapshot was stale.'
    Pass '50 concurrent record/event updates retained; final index includes both writers'
    $w=Launch @{mode='hold';command='prepare';parameters=@{SetId='A'}};Ready $w
    $w.process.Kill();Assert ($w.process.WaitForExit(5000)) 'Synthetic crash did not exit.'
    $other=Enter-ArchiveOperationLocks $c 'prepare' @{SetId='A'};Exit-ArchiveOperationLocks $other
    Pass 'crash releases OS-owned set locks without deleting lock files'
    $before=File-Hash (Catalog-Path $c)
    $null=Invoke-Archive prepare @{Config=$cfg;SetId='A';Source=$src} -WhatIf
    Assert ((File-Hash (Catalog-Path $c)) -eq $before) 'WhatIf changed catalog.'
    Assert ((& (Get-Module Archive.Core) {$script:ArchiveHeldLocks.Count}) -eq 0) 'Parent leaked lock references.'
    Pass 'dry-run remains read-only and all parent locks are released'
    Write-Json (Join-Path $run 'concurrency-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results.ToArray();physical_burn=$false;physical_optical_read=$false}
    Write-Host "Results: $run"
} finally {
    foreach ($w in $workers) {if (!$w.process.HasExited) {$w.process.Kill();$null=$w.process.WaitForExit(5000)};$w.process.Dispose()}
}
