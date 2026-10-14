[CmdletBinding()]
param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/flex-management' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python
$c.media.BD25.payload_gib=0.000008;$c.planning.per_file_overhead_bytes=1
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c;$checks=@()
function Assert($Value,$Message='Assertion failed') { if (!$Value) { throw $Message } }
function Reject([scriptblock]$Body,$Pattern) { $caught=$false;try { & $Body | Out-Null } catch { $caught=$true;Assert ($_.Exception.Message -match $Pattern) "Wrong rejection: $_" };Assert $caught 'Expected rejection.' }
function Case($Name,[scriptblock]$Body) { & $Body;$script:checks+=@{name=$Name;status='PASS'};Write-Host "PASS $Name" }
function Run($Cmd,$Extra=@{}) { $p=@{Config=$cfg;Execute=$true};foreach ($k in $Extra.Keys) { $p[$k]=$Extra[$k] };Invoke-Archive $Cmd $p }
$source=Join-Path $run '合成 备份';[IO.Directory]::CreateDirectory($source) | Out-Null
foreach ($name in @('a.raw','b.raw')) { [IO.File]::WriteAllBytes((Join-Path $source $name),(New-Object byte[] 6000)) }
try {
    $null=Run init
    Case 'custom external prefix and padding survive multi-disc plan and catalog' {
        $null=Run scan @{SetId='EXT-ID';Source=$source;Scenario='photo';PhotoTier='C'}
        $null=Run plan @{SetId='EXT-ID';StartDiscId='IPA-009';VolumeTemplates=@{volume_set='{set_token}_{set_id}';application='BDARCHIVE 1.4.0';publisher='测试 catalog';system='WINDOWS';data_preparer='LOCAL';iso9660='{disc_id}';joliet='{set_id}'}}
        $plan=Load-Plan $c 'EXT-ID';Assert ($plan.discs.Count -eq 2)
        Assert ($plan.discs[0].disc_id -eq 'IPA-009' -and $plan.discs[1].disc_id -eq 'IPA-010')
        Assert ((Get-Disc $c 'IPA-009').disc_prefix -eq 'IPA')
        Assert ((Get-ArchiveIds $c).counters[0].next_number -eq 1)
        Assert ($plan.discs[0].authoring_metadata.values.volume_set -eq $plan.discs[1].authoring_metadata.values.volume_set)
    }
    Case 'an explicit unused lower batch range does not rewind the automatic counter' {
        $null=Run set-counter @{Prefix='P';NextNumber=500}
        $null=Run scan @{SetId='LOWER-ID';Source=$source;Scenario='photo';PhotoTier='C'}
        $null=Run plan @{SetId='LOWER-ID';StartDiscId='BD-P-0020'}
        Assert ((Load-Plan $c 'LOWER-ID').discs[1].disc_id -eq 'BD-P-0021')
        Assert ((Get-ArchiveIds $c).counters[0].next_number -eq 500)
    }
    Case 'collision inside a batch rejects the entire allocation' {
        $null=Run scan @{SetId='CONFLICT';Source=$source;Scenario='photo';PhotoTier='C'}
        $before=File-Hash (Catalog-Path $c)
        Reject { Run plan @{SetId='CONFLICT';StartDiscId='IPA-008'} } 'already exists'
        Assert ((File-Hash (Catalog-Path $c)) -eq $before)
        Assert (!(Test-Path -LiteralPath (Join-Path (Set-Dir $c 'CONFLICT') 'plan.json')))
        Reject { Batch-DiscId '../IPA-001' } 'Invalid'
        Reject { Batch-DiscId 'COM1' } 'reserved Windows'
        Reject { Batch-DiscId 'IPA-2147483647' 1 } 'outside'
    }
    Case 'metadata seals all fields but exposes the actual UDF writing scope' {
        $null=Run stage @{DiscId='IPA-009'};$d=Get-Disc $c 'IPA-009'
        $sealed=Read-Json (Join-Path $d.stage.path 'DISC.json')
        Assert ($sealed.authoring_metadata.values.publisher -eq '测试 catalog')
        Assert ($sealed.authoring_metadata.targets.publisher -eq 'MANIFEST_ONLY_IN_UDF_MODE')
        Assert (Test-Path -LiteralPath (Join-Path $d.stage.path 'VOLUME-METADATA.txt'))
        Reject { Assert-VolumeBackend (Selected-PlanDisc $c @{DiscId='IPA-009'}) IMAPI2 } 'ImgBurn'
        Assert-VolumeBackend (Selected-PlanDisc $c @{DiscId='IPA-009'}) ImgBurn
        $project=Write-ImgBurnProject (Selected-PlanDisc $c @{DiscId='IPA-009'}) $d.stage.path (Join-Path $run 'device-project.ibb') -OutputMode DEVICE
        Assert ([IO.File]::ReadAllText($project).Contains('BuildOutputMode=1'))
        Assert ((Format-VolumeLabel '{disc_id}_V{volume_count}' $sealed) -eq 'IPA-009_V0002')
        Assert ($sealed.authoring_metadata.targets.volume_set -eq 'MANIFEST_ONLY_UDF_VOLUME_SET_GENERATED_BY_BACKEND')
        $t=Volume-Templates $c @{VolumeTemplates=@{application=('X'*24)}}
        Reject { New-VolumeMetadata $t $sealed } '23 ASCII'
        $t=Volume-Templates $c @{VolumeTemplates=@{publisher='{unknown}'}}
        Reject { New-VolumeMetadata $t $sealed } 'Unknown template'
    }
    Case 'deletion dry-run and WhatIf preserve catalog bytes' {
        $before=File-Hash (Catalog-Path $c)
        Assert ((Invoke-Archive delete-disc-record @{Config=$cfg;DiscId='IPA-009'}).status -eq 'DRY_RUN')
        $null=Invoke-Archive delete-disc-record @{Config=$cfg;DiscId='IPA-009';Execute=$true} -WhatIf
        Assert ((File-Hash (Catalog-Path $c)) -eq $before)
    }
    Case 'record deletion and undo preserve sealed files and verification evidence' {
        $null=Run burn @{DiscId='IPA-009';Simulate=$true};$null=Run verify @{DiscId='IPA-009';Simulate=$true}
        $d=Get-Disc $c 'IPA-009';$hash=File-Hash (Join-Path $d.stage.path 'DISC.json');$report=File-Hash $d.verification.report
        $null=Run delete-disc-record @{DiscId='IPA-009';Reason='Synthetic record removal'}
        Assert (@((Get-ArchiveIds $c).discs | Where-Object disc_id -eq 'IPA-009').Count -eq 0)
        Assert ((Get-ArchiveIds $c).deleted_discs.Count -eq 1)
        Reject { Get-Disc $c 'IPA-009' } 'deleted'
        Reject { Run burn @{DiscId='IPA-009';Simulate=$true} } 'deleted'
        Assert ((File-Hash (Join-Path $d.stage.path 'DISC.json')) -eq $hash)
        Assert ((File-Hash $d.verification.report) -eq $report)
        Assert (Test-Path -LiteralPath (Join-Path $source 'a.raw'))
        $null=Run restore-disc-record @{DiscId='IPA-009'}
        Assert ((Get-Disc $c 'IPA-009').status -eq 'SIMULATED_PASS')
    }
    Case 'exclusive lock also protects record deletion' {
        $lock=[IO.File]::Open((Join-Path $c.archive_root 'archive.lock'),'Open','ReadWrite','None')
        try { Reject { Run delete-disc-record @{DiscId='IPA-009'} } 'being used|another process|process cannot|正由|別の|资源正在使用' } finally { $lock.Dispose() }
    }
    Case 'empty active exports clear stale labels while retaining deleted-record audit' {
        foreach ($d in (Get-ArchiveIds $c).discs) { $null=Run delete-disc-record @{DiscId=$d.disc_id} }
        $snap=Get-ArchiveIds $c;Assert ($snap.discs.Count -eq 0 -and $snap.deleted_discs.Count -eq 4)
        Assert (@(Import-Csv -LiteralPath (Join-Path $c.archive_root 'disc-index.csv')).Count -eq 0)
        Assert (@(Import-Csv -LiteralPath (Join-Path $c.archive_root 'disc-labels.csv')).Count -eq 0)
        Reject { Run plan @{SetId='CONFLICT';StartDiscId='IPA-009'} } 'already exists'
        Assert ([IO.File]::ReadAllText((Join-Path (Set-Dir $c 'EXT-ID') 'ARCHIVE-SUMMARY.txt')).Contains('RECORD DELETED'))
    }
    Write-Json (Join-Path $run 'flex-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();checks=$checks;physical_burn=$false;source_deletion=$false}
} catch { Write-Json (Join-Path $run 'flex-results.json') @{status='FAIL';checks=$checks;error=$_.Exception.Message};throw }
