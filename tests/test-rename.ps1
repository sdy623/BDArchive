[CmdletBinding()]
param([string]$WorkRoot,[string]$Python,[string]$DwarfsBin)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/rename-tests' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json')
$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite';$c.tools.python=$Python;$c.tools.dwarfs_bin=$DwarfsBin
$c.media.BD25.capacity_bytes=12MB;$c.media.BD25.dwarfs_payload_gib=0.002
$c.planning.reserve_mib=1;$c.planning.dwarfs_overhead_mib=0.1;$c.planning.per_file_overhead_bytes=128;$c.planning.par2_percent=0
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c;$checks=@()
function Assert($Value,$Message='Assertion failed') { if (!$Value) { throw $Message } }
function Reject([scriptblock]$Body,$Pattern) { $caught=$false;try { & $Body | Out-Null } catch { $caught=$true;Assert ($_.Exception.Message -match $Pattern) "Wrong rejection: $_" };Assert $caught 'Expected rejection.' }
function Case($Name,[scriptblock]$Body) { & $Body;$script:checks+=@{name=$Name;status='PASS'};Write-Host "PASS $Name" }
function Run($Cmd,$Extra=@{}) { $p=@{Config=$cfg;Execute=$true};foreach ($k in $Extra.Keys) { $p[$k]=$Extra[$k] };Invoke-Archive $Cmd $p }
function Guard-PayloadReads([bool]$Enabled) {
    & (Get-Module Archive.Core) {
        param($Enabled,$Source)
        if ($Enabled) {
            $script:originalHash=(Get-Command File-Hash).ScriptBlock;$script:guardSource=$Source
            function script:File-Hash($Path) {
                if ([string]$Path -like '*.dwarfs' -or ([string]$Path).StartsWith($script:guardSource,[StringComparison]::OrdinalIgnoreCase)) { throw 'Rename read payload bytes.' }
                & $script:originalHash $Path
            }
        } else { Set-Item Function:script:File-Hash -Value $script:originalHash }
    } $Enabled $source
}
$source=Join-Path $run '合成 备份';[IO.Directory]::CreateDirectory($source) | Out-Null
foreach ($name in @('a.bin','b.bin')) { [IO.File]::WriteAllBytes((Join-Path $source $name),(New-Object byte[] 1200000)) }
try {
    $null=Run init;$null=Run scan @{SetId='OLD-SET';Source=$source;Scenario='backup'}
    $null=Run plan @{SetId='OLD-SET';VolumeLabelTemplate='{set_id}_V{volume_index}';VolumeTemplates=@{iso9660='{disc_id}';volume_set='{set_id}';publisher='{set_id}'}}
    $plan=Load-Plan $c 'OLD-SET';Assert ($plan.discs.Count -eq 2)
    foreach ($d in $plan.discs) { $null=Run build @{DiscId=$d.disc_id};$null=Run stage @{DiscId=$d.disc_id} }
    $oldImage=Join-Path $c.archive_root 'build/BD-B-0001/BD-B-0001.dwarfs';$imageHash=File-Hash $oldImage
    $buildStamp=(Get-Item -LiteralPath $oldImage).LastWriteTimeUtc.Ticks
    Case 'disc and set dry-run / WhatIf leave bytes and paths intact' {
        $before=File-Hash (Catalog-Path $c)
        $p=@{Config=$cfg;DiscId='BD-B-0001';NewDiscId='IPA-009'}
        Assert ((Invoke-Archive rename-disc $p).status -eq 'DRY_RUN')
        $p.Execute=$true;$null=Invoke-Archive rename-disc $p -WhatIf
        Assert ((Invoke-Archive rename-set @{Config=$cfg;SetId='OLD-SET';NewSetId='NEW-SET'}).status -eq 'DRY_RUN')
        Assert ((File-Hash (Catalog-Path $c)) -eq $before)
        Assert (Test-Path -LiteralPath $oldImage)
    }
    Case 'rename compiled disc without payload reads or recompilation; invalidate full set staging' {
        Guard-PayloadReads $true
        try { $script:renamed=Run rename-disc @{DiscId='BD-B-0001';NewDiscId='IPA-009'} } finally { Guard-PayloadReads $false }
        $newImage=Join-Path $c.archive_root 'build/IPA-009/IPA-009.dwarfs'
        Assert ((File-Hash $newImage) -eq $imageHash -and (Get-Item -LiteralPath $newImage).LastWriteTimeUtc.Ticks -eq $buildStamp)
        Assert (!(Test-Path -LiteralPath $oldImage))
        $r=Get-Disc $c 'IPA-009';Assert ($r.disc_index -eq 1 -and $r.volume_id -eq 'OLD-SET-V0001')
        Assert ($r.authoring_metadata.values.iso9660 -eq 'IPA-009')
        Assert ((Read-Json (Join-Path $c.archive_root 'build/IPA-009/build.json')).image -eq $newImage)
        Assert ($renamed.staging_to_reprepare.Count -eq 2)
        foreach ($d in (Load-Plan $c 'OLD-SET').discs) { Assert (!(Get-Disc $c $d.disc_id).stage) }
        Assert (Test-Path -LiteralPath (Join-Path $renamed.history 'staging/BD-B-0001/DISC.json'))
        Assert ((Get-ArchiveIds $c).discs.Count -eq 2)
        Reject { Run rename-disc @{DiscId='IPA-009';NewDiscId='BD-B-0001'} } 'reserved'
        Reject { Run rename-disc @{DiscId='IPA-009';NewDiscId='BD-B-0002'} } 'already exists'
    }
    Case 'rename archive ID without source reads; preserve image, volume IDs and allocation' {
        foreach ($d in (Load-Plan $c 'OLD-SET').discs) { $null=Run stage @{DiscId=$d.disc_id} }
        Guard-PayloadReads $true
        try { $null=Run rename-set @{SetId='OLD-SET';NewSetId='NEW-SET'} } finally { Guard-PayloadReads $false }
        Assert (!(Test-Path -LiteralPath (Set-Dir $c 'OLD-SET')))
        $plan=Load-Plan $c 'NEW-SET';$ing=Load-Ingest $c 'NEW-SET'
        Assert ($ing.archive_set_id -eq 'NEW-SET' -and $ing.files.Count -eq 2)
        Assert ($plan.discs[0].volume_id -eq 'OLD-SET-V0001')
        Assert ($plan.discs[0].volume_label -eq 'NEW-SET_V0001')
        Assert ($plan.discs[0].authoring_metadata.values.volume_set -eq 'NEW-SET')
        Assert ($plan.ingest_sha256 -eq (File-Hash (Join-Path (Set-Dir $c 'NEW-SET') 'ingest.json')))
        Assert ((Get-ArchiveIds $c).disc_index_next -eq 3)
        Reject { Run rename-set @{SetId='NEW-SET';NewSetId='OLD-SET'} } 'reserved'
        Reject { Run scan @{SetId='OLD-SET';Source=$source;Scenario='backup'} } 'reserved'
    }
    Case 'mid-transaction write failure rolls back both rename types byte for byte' {
        foreach ($d in (Load-Plan $c 'NEW-SET').discs) { $null=Run stage @{DiscId=$d.disc_id} }
        foreach ($kind in @('rename-disc','rename-set')) {
            $before=File-Hash (Catalog-Path $c);$planBefore=File-Hash (Join-Path (Set-Dir $c 'NEW-SET') 'plan.json')
            & (Get-Module Archive.Core) {
                $script:savedWriter=(Get-Command Write-Json).ScriptBlock;$script:failOnce=$true
                function script:Write-Json($Path,$Value) {
                    if ($script:failOnce -and [IO.Path]::GetFileName($Path) -eq 'plan.json') { $script:failOnce=$false;throw 'Injected rename failure' }
                    & $script:savedWriter $Path $Value
                }
            }
            try {
                if ($kind -eq 'rename-disc') { Reject { Run $kind @{DiscId='IPA-009';NewDiscId='BD-B-0099'} } 'Injected' }
                else { Reject { Run $kind @{SetId='NEW-SET';NewSetId='FAIL-SET'} } 'Injected' }
            } finally { & (Get-Module Archive.Core) { Set-Item Function:script:Write-Json -Value $script:savedWriter } }
            Assert ((File-Hash (Catalog-Path $c)) -eq $before)
            Assert ((File-Hash (Join-Path (Set-Dir $c 'NEW-SET') 'plan.json')) -eq $planBefore)
            Assert (!(Test-Path -LiteralPath (Join-Path $c.archive_root 'pending-identity-change.json')))
            Assert (Test-Path -LiteralPath (Join-Path $c.archive_root 'build/IPA-009/IPA-009.dwarfs'))
            Assert (Test-Path -LiteralPath (Join-Path $c.archive_root 'staging/IPA-009/DISC.json'))
        }
    }
    Case 'interrupted disc/set transaction rolls back through explicit recovery' {
        foreach ($kind in @('rename-disc','rename-set')) {
            $before=File-Hash (Catalog-Path $c);$ingBefore=File-Hash (Join-Path (Set-Dir $c 'NEW-SET') 'ingest.json')
            & (Get-Module Archive.Core) {
                $script:savedWriter=(Get-Command Write-Json).ScriptBlock
                $script:savedRepair=(Get-Command Repair-PendingIdentityChange).ScriptBlock
                function script:Write-Json($Path,$Value) {
                    if ([IO.Path]::GetFileName($Path) -eq 'plan.json') { throw 'Interrupted fixture' }
                    & $script:savedWriter $Path $Value
                }
                function script:Repair-PendingIdentityChange($C) { throw 'Process-exit fixture retains pending journal' }
            }
            try {
                if ($kind -eq 'rename-disc') { Reject { Run $kind @{DiscId='IPA-009';NewDiscId='BD-B-0101'} } 'journal retained' }
                else { Reject { Run $kind @{SetId='NEW-SET';NewSetId='INTERRUPTED-SET'} } 'journal retained' }
            } finally {
                & (Get-Module Archive.Core) {
                    Set-Item Function:script:Write-Json -Value $script:savedWriter
                    Set-Item Function:script:Repair-PendingIdentityChange -Value $script:savedRepair
                }
            }
            Assert (Test-Path -LiteralPath (Join-Path $c.archive_root 'pending-identity-change.json'))
            Assert ((Run repair-identity-change).status -eq 'ROLLED_BACK')
            Assert ((File-Hash (Catalog-Path $c)) -eq $before)
            Assert ((File-Hash (Join-Path (Set-Dir $c 'NEW-SET') 'ingest.json')) -eq $ingBefore)
            Assert (Test-Path -LiteralPath (Join-Path $c.archive_root 'staging/IPA-009/DISC.json'))
        }
    }
    Case 'repeated rename flattens old NFC aliases; global counters stay monotonic' {
        $null=Run rename-disc @{DiscId='IPA-009';NewDiscId='BD-B-0099'}
        $null=Run rename-set @{SetId='NEW-SET';NewSetId='FINAL-SET'}
        $cat=Read-Json (Catalog-Path $c)
        Assert (@($cat.disc_aliases | Where-Object new_id -eq 'BD-B-0099').Count -eq 2)
        Assert (@($cat.set_aliases | Where-Object new_id -eq 'FINAL-SET').Count -eq 2)
        Assert ((Get-ArchiveIds $c).counters[2].next_number -eq 100)
        Assert ($cat.discs.Count -eq 2 -and $cat.sets.Count -eq 1)
    }
    Case 'pending transaction blocks writes and recovery finishes committed change' {
        $journal=Get-ChildItem -LiteralPath (Join-Path $c.archive_root 'identity-history') -Filter COMMITTED.json -Recurse | Select-Object -Last 1
        $tx='identity-history/'+$journal.Directory.Name
        Write-Json (Join-Path $c.archive_root 'pending-identity-change.json') @{transaction=$tx}
        Reject { Run set-counter @{Prefix='B';NextNumber=101} } 'interrupted'
        Assert ((Run repair-identity-change).status -eq 'ALREADY_COMMITTED')
        Assert ((Run repair-identity-change).status -eq 'NO_PENDING_CHANGE')
    }
    Case 'saved settings resume without rebuilding; simulated restore uses revised manifests' {
        $saved=Get-SavedPreparationSettings $c 'FINAL-SET';$p=$saved.parameters
        $p.Config=$cfg;$p.Execute=$true
        Assert ((Invoke-Archive prepare $p).status -eq 'READY_FOR_REVIEW')
        $image=Join-Path $c.archive_root 'build/BD-B-0099/BD-B-0099.dwarfs'
        Assert ((File-Hash $image) -eq $imageHash -and (Get-Item -LiteralPath $image).LastWriteTimeUtc.Ticks -eq $buildStamp)
        $roots=@()
        foreach ($d in (Load-Plan $c 'FINAL-SET').discs) {
            $r=Get-Disc $c $d.disc_id;$manifest=Read-Json (Join-Path $r.stage.path 'SET-MANIFEST.json')
            Assert ($manifest.plan.archive_set_id -eq 'FINAL-SET' -and $manifest.plan.discs[0].disc_id -eq 'BD-B-0099')
            $null=Run burn @{DiscId=$d.disc_id;Simulate=$true};$null=Run verify @{DiscId=$d.disc_id;Simulate=$true}
            $roots+=Join-Path $c.archive_root ('simulated/'+$d.disc_id)
        }
        $restored=Run restore @{SetId='FINAL-SET';MediaRoots=$roots;Output=(Join-Path $run 'restored');Simulate=$true}
        Assert ($restored.status -match 'PASS')
        Reject { Run rename-disc @{DiscId='BD-B-0099';NewDiscId='BD-B-0100'} } 'written/verified'
        Reject { Run rename-set @{SetId='FINAL-SET';NewSetId='WRITTEN-SET'} } 'written/verified'
    }
    Write-Json (Join-Path $run 'rename-results.json') @{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();checks=$checks;physical_burn=$false;source_deletion=$false;run=$run}
} catch { Write-Json (Join-Path $run 'rename-results.json') @{status='FAIL';checks=$checks;error=$_.Exception.Message;stack=$_.ScriptStackTrace};throw }
