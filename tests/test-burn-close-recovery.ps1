param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) {$WorkRoot=Join-Path $PSScriptRoot '../work/burn-close'}
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
function Assert($Value,$Message) {if (!$Value) {throw $Message}}
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json')
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
function Run($Command,$Extra=@{}) {
    $p=@{Config=$cfg;Execute=$true};foreach ($k in $Extra.Keys) {$p[$k]=$Extra[$k]}
    Invoke-Archive $Command $p
}
$source=Join-Path $run 'synthetic source';Write-Text (Join-Path $source 'image.raw') 'Synthetic photo bytes only'
$null=Run init;$null=Run scan @{SetId='CLOSE-TEST';Source=$source;Scenario='photo';PhotoTier='C'}
$null=Run plan @{SetId='CLOSE-TEST';StartDiscId='BD-P-0005';ParPercent=0}
$null=Run stage @{DiscId='BD-P-0005'}
$record=Get-Disc $c 'BD-P-0005';$stageBefore=ConvertTo-Json $record.stage -Depth 20 -Compress
$catBefore=Read-Json (Catalog-Path $c);$sequence=$catBefore.sequences.P
$project=Join-Path $run 'synthetic unique job/disc.ibb';$native=Join-Path $run 'ImgBurn.log'
$text=@"
I 10:09:29 ImgBurn Version 2.5.8.0 started!
I 10:09:29 Project Successfully Loaded!
I 10:09:29 File Name: $project
I 10:09:30 Operation Started!
I 10:09:30 Building Image Tree...
I 10:09:30 Calculating Totals...
I 10:09:30 Preparing Image...
I 10:09:30 Image Sectors: 1,632
I 10:09:32 Operation Successfully Completed! - Duration: 00:00:01
I 10:09:45 Close Request Acknowledged
I 10:09:45 Closing Down...
I 10:09:45 Shutting down SPTI...
I 10:09:45 ImgBurn closed!
"@
Write-Text $native $text;$nativeHash=File-Hash $native
$record.burn=[pscustomobject]@{simulation=$false;backend='ImgBurn';result='UNKNOWN';project=$project;native_log=$native;native_log_sha256=$nativeHash;exit_code=0}
$record.status='BURN_NEEDS_REVIEW';Update-Disc $c $record
$before=File-Hash (Catalog-Path $c)
$dry=Invoke-Archive recover-burn @{Config=$cfg;DiscId='BD-P-0005'}
Assert ($dry.status -eq 'DRY_RUN' -and (File-Hash (Catalog-Path $c)) -eq $before) 'Default recovery changed catalog.'
# Recovery reads the small bound log only, not the staged payload.
& (Get-Module Archive.Core) {
    param($Root)
    $script:guardStage=$Root;$script:originalRecoveryHash=${function:File-Hash}
    function script:File-Hash($Path) {
        if ([string]$Path -like ($script:guardStage+'*')) {throw 'Recovery reread staged payload.'}
        & $script:originalRecoveryHash $Path
    }
} $record.stage.path
try {
    Write-Text $native ($text+"`nModified log")
    $rejected=$false;try {$null=Run recover-burn @{DiscId='BD-P-0005'}} catch {$rejected=$_.Exception.Message -match '日志已变化'}
    Assert $rejected 'Changed evidence unlocked recovery.'
    Assert ((Get-Disc $c 'BD-P-0005').status -eq 'BURN_NEEDS_REVIEW') 'Rejected recovery changed state.'
    Write-Text $native $text
    $result=Run recover-burn @{DiscId='BD-P-0005'}
    $loaded=Get-Disc $c 'BD-P-0005';$cat=Read-Json (Catalog-Path $c)
    Assert ($result.status -eq 'STAGED' -and !$loaded.burn -and !$loaded.verification -and !$loaded.burn_date) 'Unwritten attempt did not return to STAGED.'
    Assert (@($loaded.burn_history).Count -eq 1 -and $loaded.burn_history[0].native_log_sha256 -eq $nativeHash -and $loaded.burn_history[0].result -eq 'NOT_STARTED') 'Recovery lost evidence.'
    Assert ((ConvertTo-Json $loaded.stage -Depth 20 -Compress) -ceq $stageBefore -and $cat.sequences.P -eq $sequence -and $cat.discs.Count -eq 1) 'Stage or allocated IDs changed.'
    $null=Run recover-burn @{DiscId='BD-P-0005'}
    Assert (@((Get-Disc $c 'BD-P-0005').burn_history).Count -eq 1) 'Repeat recovery duplicated history.'
} finally {& (Get-Module Archive.Core) {Set-Item Function:script:File-Hash $script:originalRecoveryHash}}
Write-Json (Join-Path $run 'burn-close-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();default_dry_run='PASS';tampered_log_rejected='PASS';restored_staged='PASS';history_preserved='PASS';no_payload_reads='PASS';ids_and_stage_preserved='PASS';repeated_recovery_idempotent='PASS';physical_burn=$false;hardware_access=$false}
Write-Host "PASS build-only close recovery: $run"
