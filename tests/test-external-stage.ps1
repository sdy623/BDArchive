param([string]$WorkRoot,[string]$Python,[switch]$LeaveForUi)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) {$WorkRoot=Join-Path $PSScriptRoot '../work/external-stage'}
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
function Assert($Value,$Message) {if (!$Value) {throw $Message}}
function Reject([scriptblock]$Body) {$failed=$false;try {& $Body | Out-Null} catch {$failed=$true};Assert $failed 'Expected rejection.'}
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
function Run($Command,$Extra=@{}) {$p=@{Config=$cfg;Execute=$true};foreach ($k in $Extra.Keys) {$p[$k]=$Extra[$k]};Invoke-Archive $Command $p}
$source=Join-Path $run 'original photos';Write-Text (Join-Path $source 'photo.CR2') 'Synthetic RAW';Write-Text (Join-Path $source 'photo.xmp') '<xmp>Synthetic</xmp>'
$legacy=Join-Path $run 'legacy index only';Write-Text (Join-Path $legacy 'CONTENTS.txt') 'Legacy incorrect subset'
$null=Run init;$null=Run scan @{SetId='PHOTOS';Source=$legacy;Scenario='photo';PhotoTier='C'}
$null=Run plan @{SetId='PHOTOS';StartDiscId='BD-P-0005';ParPercent=0};$null=Run stage @{DiscId='BD-P-0005'}
$null=Run burn @{DiscId='BD-P-0005';Simulate=$true};$old=Get-Disc $c 'BD-P-0005';$oldStage=$old.stage.path;$oldSimulation=$old.burn.root
$oldPlan=Join-Path (Set-Dir $c 'PHOTOS') 'plan.json';$oldPlanHash=File-Hash $oldPlan
$root=Join-Path $run 'prepared 现成盘';$rows=@();$bytes=[int64]0
foreach ($f in @(Tree-Files $source)) {
    $path='data/中文 folder/'+$f.Name;$null=Stage-Payload $f.FullName (Safe-Join $root $path) (File-Hash $f.FullName)
    $rows+=@{archive_path=$path;bytes=$f.Length;sha256=(File-Hash $f.FullName)};$bytes+=$f.Length
}
$meta=Join-Path $root '00_DISC_CATALOG';[IO.Directory]::CreateDirectory($meta)|Out-Null
$rows | ForEach-Object {[pscustomobject]$_} | Export-Csv -LiteralPath (Join-Path $meta 'CONTENTS.csv') -NoTypeInformation -Encoding UTF8
Write-Json (Join-Path $meta 'DISC-INFO.json') @{disc_id='BD-P-0005';archive_set_id='EXTERNAL-PLAN';photo_files=2;logical_payload_bytes=$bytes;sealed=$false}
Reject {Assert-PhotoSourceRoot $meta}
$before=File-Hash (Catalog-Path $c)
$preview=Invoke-Archive import-stage @{Config=$cfg;DiscId='BD-P-0005';Source=$meta}
Assert ($preview.status -eq 'DRY_RUN' -and $preview.photo_files -eq 2 -and $preview.root -eq $root -and (File-Hash (Catalog-Path $c)) -eq $before) 'Preview did not normalize catalog folder or changed state.'
Assert (![IO.File]::Exists((Join-Path $root 'DISC.json'))) 'Preview wrote metadata.'
Write-Text (Join-Path $root 'data/extra.raw') 'extra';Reject {External-PhotoPreview $c @{DiscId='BD-P-0005';Source=$root}}
[IO.File]::Delete((Join-Path $root 'data/extra.raw'))
# Stop after preparing metadata, before any seal becomes authoritative.
& (Get-Module Archive.Core) {$script:savedExternalCheck=${function:Check-DiscTree};function script:Check-DiscTree {throw [OperationCanceledException]::new('Synthetic import cancellation')}}
try {Reject {$null=Run import-stage @{DiscId='BD-P-0005';Source=$root}}}
finally {& (Get-Module Archive.Core) {Set-Item Function:script:Check-DiscTree $script:savedExternalCheck}}
Assert ((Get-Disc $c 'BD-P-0005').stage.path -eq $oldStage -and (File-Hash $oldPlan) -eq $oldPlanHash) 'Interrupted import activated a partial revision.'
$pending=Read-Json (Join-Path $c.archive_root 'external-imports/BD-P-0005/pending.json')
$revisionPlan=Join-Path (Safe-Join $c.archive_root $pending.revision) 'plan.json';$savedPlan=[IO.File]::ReadAllBytes($revisionPlan)
[IO.File]::AppendAllText($revisionPlan,' ')
try {Reject {$null=Run import-stage @{DiscId='BD-P-0005';Source=$root}}} finally {[IO.File]::WriteAllBytes($revisionPlan,$savedPlan)}
$photo=Join-Path $source 'photo.CR2';$savedPhoto=[IO.File]::ReadAllBytes($photo);$corrupt=$savedPhoto.Clone();$corrupt[0]=$corrupt[0] -bxor 1
[IO.File]::WriteAllBytes($photo,$corrupt)
try {Reject {$null=Run import-stage @{DiscId='BD-P-0005';Source=$root}}} finally {[IO.File]::WriteAllBytes($photo,$savedPhoto)}
Assert ((Get-Disc $c 'BD-P-0005').stage.path -eq $oldStage) 'Failed hash check activated a revision.'
& (Get-Module Archive.Core) {
    param($Root)
    $script:firstImportData=$Root;$script:firstImportCounts=@{};$script:firstImportHash=${function:File-Hash}
    function script:File-Hash($Path) {
        if ([string]$Path -like ($script:firstImportData+'*')) {
            if (!$script:firstImportCounts.ContainsKey($Path)) {$script:firstImportCounts[$Path]=0}
            $script:firstImportCounts[$Path]++
        }
        & $script:firstImportHash $Path
    }
} (Join-Path $root 'data')
try {$result=Run import-stage @{DiscId='BD-P-0005';Source=$root}}
finally {& (Get-Module Archive.Core) {Set-Item Function:script:File-Hash $script:firstImportHash}}
$reads=& (Get-Module Archive.Core) {$script:firstImportCounts}
Assert ($reads.Count -eq 2 -and @($reads.Values | Where-Object {$_ -ne 1}).Count -eq 0) 'First successful import must hash each payload once.'

$record=Get-Disc $c 'BD-P-0005';$ing=Load-Ingest $c 'PHOTOS';$plan=Load-Plan $c 'PHOTOS'
Assert ($result.status -eq 'STAGED' -and $record.stage.path -eq $root -and !$record.burn -and $ing.file_count -eq 2 -and $plan.discs[0].files.Count -eq 2) 'Whole disc was not activated.'
Assert ($record.disc_index -eq $old.disc_index -and $record.volume_id -eq $old.volume_id -and (File-Hash $oldPlan) -eq $oldPlanHash -and [IO.Directory]::Exists($oldStage) -and [IO.Directory]::Exists($oldSimulation)) 'Old evidence or IDs changed.'
Assert (@($record.burn_history | Where-Object simulation).Count -eq 1) 'Old simulation history lost.'
Assert ([ArchiveFileLinks]::Identity((Join-Path $source 'photo.CR2')) -eq [ArchiveFileLinks]::Identity((Join-Path $root 'data/中文 folder/photo.CR2'))) 'Payload was copied/replaced.'
$project=Join-Path $run 'disc.ibb';$null=Write-ImgBurnProject $plan.discs[0] $record.stage.path $project -OutputMode DEVICE
Assert ([IO.File]::ReadAllText($project).Contains("[START_BACKUP_LIST]`r`n$root`r`n[END_BACKUP_LIST]")) 'ImgBurn does not receive the complete prepared root.'
& (Get-Module Archive.Core) {
    param($Root)
    $script:externalData=$Root;$script:oldExternalHash=${function:File-Hash}
    function script:File-Hash($Path) {if ([string]$Path -like ($script:externalData+'*')) {throw 'Reused payload was hashed again.'};& $script:oldExternalHash $Path}
} (Join-Path $root 'data')
try {$again=Run import-stage @{DiscId='BD-P-0005';Source=$root};Assert $again.reused 'Finished import was not reused.';$staged=Run stage @{DiscId='BD-P-0005'};Assert ($staged.path -eq $root) 'stage copied an external payload.'}
finally {& (Get-Module Archive.Core) {Set-Item Function:script:File-Hash $script:oldExternalHash}}
Reject {Delete-ArchiveSource $c @{SetId='PHOTOS';DeleteSourceConfirmed=$true}}
Reject {Get-DiscRenameContext $c @{DiscId='BD-P-0005';NewDiscId='BD-P-0099'}}
$null=Run burn @{DiscId='BD-P-0005';Simulate=$true};$sim=Get-Disc $c 'BD-P-0005'
Assert ($sim.burn.root -ne $oldSimulation) 'Revised simulation overwrote the old one.'
$null=Run verify @{DiscId='BD-P-0005';Simulate=$true}
$out=Join-Path $run 'restore';$null=Run restore @{SetId='PHOTOS';Output=$out;MediaRoots=@($sim.burn.root)}
Assert ((File-Hash (Join-Path $out '中文 folder/photo.CR2')) -eq (File-Hash (Join-Path $source 'photo.CR2'))) 'External plan restore failed.'
$record=Get-Disc $c 'BD-P-0005';$record.burn=[pscustomobject]@{simulation=$false;result='WRITTEN'};Update-Disc $c $record
Reject {External-PhotoPreview $c @{DiscId='BD-P-0005';Source=$root}}
if ($LeaveForUi) {Update-Disc $c $sim;Write-Json (Join-Path $run 'ui-fixture.json') @{disc_id='BD-P-0005';root=$root;config=$cfg}}
Write-Json (Join-Path $run 'external-stage-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();metadata_only_rejected='PASS';preview_read_only='PASS';extra_payload_rejected='PASS';cancel_resume='PASS';first_seal_one_payload_read='PASS';modified_checkpoint_rejected='PASS';changed_payload_rejected='PASS';whole_root_imgburn_project='PASS';zero_payload_copy='PASS';revision_history='PASS';recent_reuse_no_payload_hash='PASS';source_delete_and_rename_blocked='PASS';simulated_verify_restore='PASS';physical_write_rebind_rejected='PASS';hardware_access=$false}
Write-Host "PASS external stage: $run"
