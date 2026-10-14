param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) {$WorkRoot=Join-Path $PSScriptRoot '../work/resume-completed'}
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
function Assert($Value,$Message) {if (!$Value) {throw $Message}}
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$c.media.BD25.payload_gib=0.0008;$c.planning.par2_percent=0
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$source=Join-Path $run 'source';[IO.Directory]::CreateDirectory($source)|Out-Null
foreach ($i in 1..4) {[IO.File]::WriteAllBytes((Join-Path $source ($i.ToString()+'.raw')),(New-Object byte[] (650KB)))}
$p=@{Config=$cfg;Execute=$true;SetId='RESUME';Source=$source;Category='I';Scenario='photo';PhotoTier='C';Media='BD25';ParPercent=0;StartDiscId='BD-P-0005'}
$null=Invoke-Archive init $p;$null=Invoke-Archive scan $p;$null=Invoke-Archive plan $p
$plan=Load-Plan $c 'RESUME';Assert ($plan.discs.Count -eq 4) 'Expected four synthetic discs.'
foreach ($d in $plan.discs[0..2]) {$null=Invoke-Archive stage @{Config=$cfg;Execute=$true;DiscId=$d.disc_id}}
$first=Get-Disc $c 'BD-P-0005';$first.status='VERIFIED';$first.burn=[pscustomobject]@{simulation=$false;result='WRITTEN';backend='SYNTHETIC_RECORD_ONLY'};Update-Disc $c $first
$removed=Full-Path (Join-Path $first.stage.path ('data/'+$plan.discs[0].files[0].path))
Assert ($removed.StartsWith($run+'\',[StringComparison]::OrdinalIgnoreCase)) 'Fixture deletion escapes test root.'
[IO.File]::Delete($removed) # Remove only this synthetic staging hard-link name.
$before=(Read-Json (Catalog-Path $c)).sequences.P;$oldTimes=@{}
foreach ($id in @('BD-P-0006','BD-P-0007')) {$oldTimes[$id]=(Get-Disc $c $id).stage.receipt.time}
& (Get-Module Archive.Core) {
    param($Root)
    $script:resumeFixtureRoot=$Root;$script:beforeResumeHash=${function:File-Hash};$script:beforeResumeStage=${function:Stage-Archive};$script:stagedIds=@()
    function script:File-Hash($Path) {
        if ($Path -like ($script:resumeFixtureRoot+'\staging\BD-P-0005\*') -or $Path -like ($script:resumeFixtureRoot+'\staging\BD-P-0006\data\*') -or $Path -like ($script:resumeFixtureRoot+'\staging\BD-P-0007\data\*')) {throw 'Completed disc payload was read again.'}
        & $script:beforeResumeHash $Path
    }
    function script:Stage-Archive($C,$P) {$script:stagedIds+=,$P.DiscId;& $script:beforeResumeStage $C $P}
} $c.archive_root
try {$result=Invoke-Archive prepare $p} finally {& (Get-Module Archive.Core) {Set-Item Function:script:File-Hash $script:beforeResumeHash;Set-Item Function:script:Stage-Archive $script:beforeResumeStage}}
Assert ($result.status -eq 'READY_FOR_REVIEW') 'Resume did not complete.'
$staged=@(& (Get-Module Archive.Core) {$script:stagedIds})
Assert ($staged.Count -eq 1 -and $staged[0] -eq 'BD-P-0008') 'Resume did not start remaining work at disc 8.'
Assert ((Read-Json (Catalog-Path $c)).sequences.P -eq $before) 'Resume allocated new IDs.'
Assert ((Get-Disc $c 'BD-P-0005').status -eq 'VERIFIED' -and ![IO.File]::Exists($removed)) 'Written disc was rebuilt or its status changed.'
foreach ($id in @('BD-P-0006','BD-P-0007')) {Assert ((Get-Disc $c $id).stage.receipt.time -eq $oldTimes[$id]) 'Reuse extended validation age.'}
# Uncertain writes must not be silently skipped or recompiled.
$first=Get-Disc $c 'BD-P-0005';$first.burn.result='UNKNOWN';$first.status='BURN_NEEDS_REVIEW';Update-Disc $c $first
$blocked=$false;try {$null=Invoke-Archive prepare $p} catch {$blocked=$_.Exception.Message -match '尚未确认结果'}
Assert $blocked 'Unknown physical write was treated as completed.'
Write-Json (Join-Path $run 'resume-completed-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();written_disc_without_local_payload_skipped=$true;recent_completed_stages_no_payload_reads=$true;only_disc_8_staged=$true;no_new_ids=$true;receipt_age_preserved=$true;unknown_write_blocked=$true;physical_burn=$false}
Write-Host "PASS completed-disc resume: $run"
