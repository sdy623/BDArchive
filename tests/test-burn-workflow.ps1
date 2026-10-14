[CmdletBinding()]
param([string]$WorkRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/burn-workflow' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'));$stage=Join-Path $run '待刻 fixture'
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $c.archive_root 'catalog.sqlite'
$null=Initialize-Archive $c
$payload=Join-Path $stage 'data/小文件.bin';Write-Text $payload 'Synthetic archive bytes, not user data.'
Write-Text (Join-Path $stage 'DISC.json') '{}';Write-Text (Join-Path $stage 'SET-MANIFEST.json') '{}';Write-Text (Join-Path $stage 'RESTORE.md') 'fixture'
$lines=@(Tree-Files $stage | ForEach-Object { (File-Hash $_.FullName)+'  '+(Relative-Path $stage $_.FullName) })
Write-Text (Join-Path $stage 'SHA256SUMS') (($lines -join "`n")+"`n")
$stamps=@(Get-StageStamps $stage);$total=[int64]0;foreach($f in $stamps) {$total+=$f.bytes}
$seal=[pscustomobject]@{path=$stage;hash=(File-Hash (Join-Path $stage 'SHA256SUMS'));disc_json_hash=(File-Hash (Join-Path $stage 'DISC.json'));bytes=$total;time=[DateTime]::UtcNow.ToString('o')}
$seal | Add-Member NoteProperty receipt (New-StageReceipt $seal $stamps)
$record=[pscustomobject]@{disc_id='BD-B-0001';stage=$seal;hash=$seal.hash;status='STAGED';burn=$null;burn_date=$null;verification=$null}
$cat=Read-Json (Catalog-Path $c);$cat.discs=@($record);Write-Json (Catalog-Path $c) $cat
$results=@()
Assert (Test-RecentStage $record).reuse 'Fresh seal did not reuse.'
$stampTime=[DateTime]::Parse($seal.receipt.time).ToUniversalTime()
Assert (Test-RecentStage $record $stampTime.AddDays(7)).reuse 'Exactly seven days should reuse.'
Assert (!(Test-RecentStage $record $stampTime.AddDays(7).AddTicks(1)).reuse) 'Expired receipt accepted.'
Assert (!(Test-RecentStage $record $stampTime.AddSeconds(-1)).reuse) 'Future receipt accepted.'
$results+=@{name='seven-day boundary and future/expired receipt';status='PASS'}
$persisted=Get-Disc $c $record.disc_id
Assert ((Convert-ArchiveUtcTime $persisted.stage.receipt.time).Ticks -eq $stampTime.Ticks) 'JSON date changed time zone.'
Assert (Test-RecentStage $persisted $stampTime.AddDays(7)).reuse 'Persisted seven-day boundary failed.'
$results+=@{name='PS 5.1 and PS 7 JSON date roundtrip preserves UTC';status='PASS'}
$oldTime=(Get-Item -LiteralPath $payload).LastWriteTimeUtc
[IO.File]::SetLastWriteTimeUtc($payload,$oldTime.AddSeconds(1))
Assert (!(Test-RecentStage $record).reuse) 'Changed mtime accepted.'
[IO.File]::SetLastWriteTimeUtc($payload,$oldTime)
$oldBytes=[IO.File]::ReadAllBytes($payload);[IO.File]::AppendAllText($payload,'x');[IO.File]::SetLastWriteTimeUtc($payload,$oldTime)
Assert (!(Test-RecentStage $record).reuse) 'Changed size with same mtime accepted.'
[IO.File]::WriteAllBytes($payload,$oldBytes);[IO.File]::SetLastWriteTimeUtc($payload,$oldTime)
$extra=Join-Path $stage 'extra.txt';Write-Text $extra 'fixture'
Assert (!(Test-RecentStage $record).reuse) 'Added file accepted.'
# Exact known test file, not recursive cleanup.
Remove-Item -LiteralPath $extra
$results+=@{name='mtime, size and file membership invalidation';status='PASS'}
$discPath=Join-Path $stage 'DISC.json';$old=[IO.File]::ReadAllBytes($discPath);[IO.File]::WriteAllText($discPath,'changed')
$failed=$false;try {$null=Test-RecentStage $record} catch {$failed=$true};Assert $failed 'Changed final metadata accepted.'
[IO.File]::WriteAllBytes($discPath,$old)
$results+=@{name='final output records bound to catalog';status='PASS'}
$seal.time=[DateTime]::UtcNow.ToString('o');$seal.PSObject.Properties.Remove('receipt')
$check=Test-RecentStage $record
Assert ($check.reuse -and $check.basis -eq 'LEGACY_METADATA_REUSE') 'Legacy migration not explicitly labeled.'
$seal | Add-Member NoteProperty receipt $check.receipt
$expiry=$seal.receipt.time;$null=Confirm-StageForBurn $c $record
Assert ($record.stage.receipt.time -ceq $expiry) 'Reuse extended expiry.'
$results+=@{name='legacy metadata-only migration and fixed expiry';status='PASS'}
$project='C:\合成 job\disc.ibb'
$header="I 12:00:00 ImgBurn Version 2.5.8.0 started!`nI 12:00:00 Project Successfully Loaded!`nI 12:00:00 File Name: $project`nI 12:00:01 Operation Started!`nI 12:00:01 Building Image Tree...`n"
$cancel=$header+"E 12:00:05 Operation Aborted! - Duration: 00:00:04`nI 12:00:06 ImgBurn closed!`n"
$outcome=Get-ImgBurnOutcome $cancel $project 0
Assert ($outcome.result -eq 'CANCELLED_BEFORE_WRITE' -and $outcome.retry_allowed) 'Exit-zero cancellation misclassified.'
$prepared=$header+"I 12:00:05 Operation Successfully Completed!`nI 12:00:06 ImgBurn closed!`n"
Assert (!(Get-ImgBurnOutcome $prepared $project 0).retry_allowed) 'Image building alone inferred writing or safe cancellation.'
$closed=$header+"I 12:00:01 Preparing Image...`nI 12:00:01 Image Sectors: 1,632`nI 12:00:02 Operation Successfully Completed! - Duration: 00:00:01`nI 12:00:03 Close Request Acknowledged`nI 12:00:03 Closing Down...`nI 12:00:03 Shutting down SPTI...`nI 12:00:03 ImgBurn closed!`n"
$closeOutcome=Get-ImgBurnOutcome $closed $project 0
Assert ($closeOutcome.result -eq 'NOT_STARTED' -and $closeOutcome.retry_allowed) 'Clean build-only close remained blocked.'
foreach ($variant in @(
    ($closed -replace 'Close Request Acknowledged',"Destination Device: G:`nI 12:00:03 Close Request Acknowledged"),
    ($closed -replace 'Close Request Acknowledged',"Operation Started!`nI 12:00:03 Close Request Acknowledged"),
    ($closed -replace 'Preparing Image','Missing prepare'),
    ($closed -replace 'Close Request Acknowledged','Missing close request'),
    ($closed -replace 'Image Sectors:',"File Name: C:\other\disc.ibb`nI 12:00:01 Image Sectors:"),
    ($closed -replace 'ImgBurn closed!','Missing end')
)) {Assert (!(Get-ImgBurnOutcome $variant $project 0).retry_allowed) 'Incomplete, second-operation, device, or foreign-project log unlocked a retry.'}
Assert (!(Get-ImgBurnOutcome $closed $project 4).retry_allowed) 'Failed exit was accepted as build-only close.'
$results+=@{name='clean build-only close permits retry; incomplete, second-operation, device and mixed-project evidence stays blocked';status='PASS'}

$partial=$header+"I 12:00:01 Writing LeadIn...`nE 12:00:05 Operation Aborted!`nI 12:00:06 ImgBurn closed!`n"
Assert (!(Get-ImgBurnOutcome $partial $project 4).retry_allowed) 'Partial write allowed retry.'
$written=$header+"I 12:00:01 Writing Track 1 of 1...`nI 12:01:00 Synchronising Cache...`nI 12:01:01 Finalising Disc...`nI 12:01:05 Operation Successfully Completed!`nI 12:01:05 Average Write Rate: 4x`nI 12:02:00 Verify Aborted!`nI 12:02:01 ImgBurn closed!`n"
Assert ((Get-ImgBurnOutcome $written $project 5).result -eq 'WRITTEN') 'Verification cancellation erased successful write.'
Assert (!(Get-ImgBurnOutcome $cancel 'C:\other\disc.ibb' 0).retry_allowed) 'Other project log accepted.'
Assert (!(Get-ImgBurnOutcome ($cancel+$cancel) $project 0).retry_allowed) 'Ambiguous sessions accepted.'
Assert (!(Get-ImgBurnOutcome ($cancel -replace 'ImgBurn closed!','missing end') $project 0).retry_allowed) 'Incomplete session accepted.'
$results+=@{name='native outcomes: exit-zero cancel, build-only, partial write, written/verify abort, foreign/ambiguous/incomplete logs';status='PASS'}
$record.burn=[pscustomobject]@{simulation=$false;result='RETURNED'};$record.status='BURNED_UNVERIFIED';$record.burn_date='synthetic'
Reset-UnwrittenBurn $c $record $outcome
$loaded=Get-Disc $c $record.disc_id
Assert ($loaded.status -eq 'STAGED' -and !$loaded.burn -and @($loaded.burn_history).Count -eq 1 -and !$loaded.burn_date) 'Cancel recovery lost history or remained blocked.'
$record.burn=[pscustomobject]@{simulation=$false;result='WRITTEN'}
$failed=$false;try { Reset-UnwrittenBurn $c $record $outcome } catch {$failed=$true};Assert $failed 'Written disc reset.'
$results+=@{name='unwritten recovery retains history; written record cannot reset';status='PASS'}
Assert (!(Optional-Field $c.burn 'verify_after_write')) 'Post-burn verify must default off.'
$results+=@{name='post-burn verification defaults off';status='PASS'}
Write-Json (Join-Path $run 'burn-workflow-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results;physical_burn=$false;hardware_access=$false}
Write-Host "PASS $($results.Count) groups: $run"
