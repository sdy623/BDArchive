[CmdletBinding()]
param([string]$WorkRoot,[string]$Python)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/identities' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($run) | Out-Null
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'index.sqlite';$c.tools.python=$Python
$c.media.BD25.payload_gib=0.000008;$c.planning.per_file_overhead_bytes=1
$cfg=Join-Path $run 'config.json';Write-Json $cfg $c
$checks=New-Object 'System.Collections.Generic.List[object]'
function Assert($Value,$Message='Identity assertion failed') { if (!$Value) { throw $Message } }
function Reject([scriptblock]$Action,$Pattern) { $rejected=$false;try { & $Action | Out-Null } catch { $rejected=$true;Assert ($_.Exception.Message -match $Pattern) "Unexpected error: $_" };Assert $rejected 'Expected rejection' }
function Case($Name,[scriptblock]$Action) { & $Action;$checks.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name" }
function Run($Command,$Values=@{}) { $p=@{Config=$cfg;Execute=$true};foreach ($k in $Values.Keys) { $p[$k]=$Values[$k] };Invoke-Archive $Command $p }
try {
    Case 'read-only counters and previews do not initialize or reserve IDs' {
        $s=Invoke-Archive ids @{Config=$cfg}
        Assert ($s.counters[0].next_disc_id -eq 'BD-P-0001' -and !$s.catalog_id)
        $p=@{Config=$cfg;Prefix='P';NextNumber=42}
        Assert ((Invoke-Archive set-counter $p).status -eq 'DRY_RUN')
        $p.Execute=$true;Assert ((Invoke-Archive set-counter $p -WhatIf).status -eq 'DRY_RUN')
        Assert (!(Test-Path -LiteralPath $c.archive_root)) 'Preview wrote archive files'
    }
    Case 'counter advance persists and rollback is rejected' {
        $r=Run set-counter @{Prefix='P';NextNumber=42;Reason='Synthetic existing stock'}
        Assert ($r.next_disc_id -eq 'BD-P-0042' -and $r.skipped_count -eq 41)
        $s=Get-ArchiveIds $c;Assert ($s.catalog_id -and $s.counters[0].next_number -eq 42)
        Reject { Run set-counter @{Prefix='P';NextNumber=41} } 'rollback'
        Reject { Run set-counter @{Prefix='X';NextNumber=1} } 'Prefix'
    }
    $source=Join-Path $run '合成 照片';[IO.Directory]::CreateDirectory($source) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $source 'a.RAW'),(New-Object byte[] 6000))
    [IO.File]::WriteAllBytes((Join-Path $source 'b.RAW'),(New-Object byte[] 6000))
    Case 'plan allocates independent physical, logical and global identities' {
        $null=Run scan @{SetId='PHOTO-ID-TEST';Source=$source;Scenario='photo';PhotoTier='C'}
        $null=Run plan @{SetId='PHOTO-ID-TEST';Media='BD25';VolumeLabelTemplate='{prefix}{number}_V{volume_index}'}
        $plan=Load-Plan $c 'PHOTO-ID-TEST';Assert ($plan.discs.Count -eq 2)
        Assert ($plan.discs[0].disc_id -eq 'BD-P-0042' -and $plan.discs[1].disc_id -eq 'BD-P-0043')
        Assert ($plan.discs[0].volume_id -eq 'PHOTO-ID-TEST-V0001' -and $plan.discs[1].volume_index -eq 2)
        Assert ($plan.discs[0].volume_label -eq 'P0042_V0001' -and $plan.discs[1].volume_label -eq 'P0043_V0002')
        Assert ($plan.discs[0].disc_index -eq 1 -and $plan.discs[1].disc_index -eq 2)
        Assert ((Get-ArchiveIds $c).counters[0].next_disc_id -eq 'BD-P-0044')
        $csv=Import-Csv -LiteralPath (Join-Path (Set-Dir $c 'PHOTO-ID-TEST') 'plan.csv')
        Assert ($csv[0].volume_label -and $csv[0].disc_index -and $csv[0].volume_id)
    }
    Case 'stale high-watermark never reuses an allocated ID; rollover works' {
        $cat=Read-Json (Catalog-Path $c);$cat.sequences.P=0
        Assert ((Next-DiscId $cat P) -eq 'BD-P-0044')
        $cat.sequences.P=9999;Assert ((Next-DiscId $cat P) -eq 'BD-P-10000')
    }
    Case 'bad or duplicate volume labels reject without reserving a partial plan' {
        $null=Run scan @{SetId='BAD-LABEL';Source=$source;Scenario='photo';PhotoTier='C'}
        $before=File-Hash (Catalog-Path $c)
        Reject { Run plan @{SetId='BAD-LABEL';VolumeLabelTemplate='CONSTANT'} } 'already allocated'
        Reject { Run plan @{SetId='BAD-LABEL';VolumeLabelTemplate='{unknown}'} } 'Volume label'
        Reject { Run plan @{SetId='BAD-LABEL';VolumeLabelTemplate=('X'*33)} } 'Volume label'
        Assert ((File-Hash (Catalog-Path $c)) -eq $before) 'Invalid plan consumed IDs'
        Assert (!(Test-Path -LiteralPath (Join-Path (Set-Dir $c 'BAD-LABEL') 'plan.json')))
    }
    Case 'sealed DISC and summary carry identities; altered label blocks simulation' {
        $null=Run stage @{DiscId='BD-P-0042'}
        $disc=Get-Disc $c 'BD-P-0042';$sealed=Read-Json (Join-Path $disc.stage.path 'DISC.json')
        Assert ($sealed.volume_label -eq 'P0042_V0001' -and $sealed.volume_id -eq 'PHOTO-ID-TEST-V0001' -and $sealed.disc_index -eq 1)
        $planFile=Join-Path (Set-Dir $c 'PHOTO-ID-TEST') 'plan.json';$original=[IO.File]::ReadAllBytes($planFile)
        try {
            $plan=Read-Json $planFile;$plan.discs[0].volume_label='TAMPERED';Write-Json $planFile $plan
            Reject { Run burn @{DiscId='BD-P-0042';Simulate=$true} } 'Sealed volume label'
            Assert (!(Get-Disc $c 'BD-P-0042').burn)
        } finally { [IO.File]::WriteAllBytes($planFile,$original) }
        $summary=[IO.File]::ReadAllText((Join-Path $disc.stage.path 'ARCHIVE-SUMMARY.txt'))
        Assert ($summary.Contains('P0042_V0001') -and $summary.Contains('PHOTO-ID-TEST-V0001'))
    }
    Case 'simulation never invents a physical filesystem serial' {
        $null=Run burn @{DiscId='BD-P-0042';Simulate=$true}
        $null=Run verify @{DiscId='BD-P-0042';Simulate=$true}
        $r=@((Get-ArchiveIds $c).discs | Where-Object disc_id -eq 'BD-P-0042')[0]
        Assert ($r.status -eq 'SIMULATED_PASS' -and $null -eq $r.filesystem_serial)
        $export=Run export-index;Assert (Test-Path -LiteralPath $export.csv)
        $rows=Import-Csv -LiteralPath $export.csv;Assert ($rows[0].volume_label -eq 'P0042_V0001')
    }
    Case 'legacy plan identities are enriched in memory without rewriting plan' {
        $file=Join-Path (Set-Dir $c 'PHOTO-ID-TEST') 'plan.json';$bytes=[IO.File]::ReadAllBytes($file)
        try {
            $plan=Read-Json $file
            foreach ($key in @('disc_index','catalog_id','volume_id','identity_origin')) { $plan.discs[0].PSObject.Properties.Remove($key) }
            Write-Json $file $plan;$hash=File-Hash $file
            $d=Selected-PlanDisc $c @{DiscId='BD-P-0042'}
            Assert ($d.disc_index -eq 1 -and $d.volume_id -eq 'PHOTO-ID-TEST-V0001')
            Assert ((File-Hash $file) -eq $hash)
        } finally { [IO.File]::WriteAllBytes($file,$bytes) }
    }
    Case 'global index continues across physical ID prefixes' {
        $null=Run scan @{SetId='GAME-ID-TEST';Source=$source;Scenario='game'}
        $null=Run plan @{SetId='GAME-ID-TEST';VolumeLabelTemplate='{disc_id}'}
        $d=(Load-Plan $c 'GAME-ID-TEST').discs[0]
        Assert ($d.disc_id -eq 'BD-G-0001' -and $d.disc_index -eq 3)
    }
    Case 'exclusive lock prevents two counter writers' {
        $before=File-Hash (Catalog-Path $c)
        $lock=[IO.File]::Open((Join-Path $c.archive_root 'archive.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Reject { Run set-counter @{Prefix='B';NextNumber=999} } 'process|used|being|使用|占用' } finally { $lock.Dispose() }
        Assert ((File-Hash (Catalog-Path $c)) -eq $before)
    }
    Case 'old catalog backfill is stable and leaves sealed fixture bytes unchanged' {
        $legacy=Empty-Catalog;$legacy.sequences.B=12
        $legacy.sets=@([pscustomobject]@{archive_set_id='OLD';category='III';summary='SYNTHETIC';file_count=1;total_bytes=1;original_deleted=$false;restore_test=$null;ingest_sha256=('0'*64)})
        $legacy.discs=@([pscustomobject]@{disc_id='BD-B-0012';archive_set_id='OLD';position=1;disc_count=1;media_type='BD25';status='PLANNED';location='';nfc_url='/disc/BD-B-0012';hash=$null;verification=$null;registered=$false;original_deleted=$false})
        $sealedFixture=Join-Path $c.archive_root 'staging/BD-B-0012/DISC.json';Write-Text $sealedFixture '{"disc_id":"BD-B-0012"}'
        $oldPlan=Join-Path $c.archive_root 'sets/OLD/plan.json';Write-Text $oldPlan '{"archive_set_id":"OLD","discs":[{"disc_id":"BD-B-0012"}]}'
        $before=File-Hash $sealedFixture;$planHash=File-Hash $oldPlan;Write-Json (Catalog-Path $c) $legacy
        $null=Run init;$first=Get-ArchiveIds $c
        $null=Run init;$second=Get-ArchiveIds $c
        Assert ($first.catalog_id -eq $second.catalog_id -and $second.discs[0].disc_index -eq 1)
        Assert ($second.counters[2].next_disc_id -eq 'BD-B-0013' -and $second.discs[0].identity_origin -eq 'catalog_backfill')
        Assert ((File-Hash $sealedFixture) -eq $before)
        Assert ((File-Hash $oldPlan) -eq $planHash)
    }
    Case 'orphan set cleanup removes only metadata and keeps the high-water mark' {
        $cat=Read-Json (Catalog-Path $c)
        $cat.sets+=,[pscustomobject]@{archive_set_id='ORPHAN-SET-TEST';category='III';summary='ORPHAN';file_count=1;total_bytes=1;original_deleted=$false;restore_test=$null;ingest_sha256=('0'*64)}
        Write-Json (Catalog-Path $c) $cat
        $r=Run delete-orphan-set @{SetId='ORPHAN-SET-TEST';Reason='Synthetic interrupted ingest'}
        Assert ($r.status -eq 'SET_RECORD_DELETED' -and (Test-Path -LiteralPath $r.receipt))
        $after=Read-Json (Catalog-Path $c)
        Assert (@($after.sets | Where-Object archive_set_id -eq 'ORPHAN-SET-TEST').Count -eq 0)
        Assert ((Get-ArchiveIds $c).counters[2].next_disc_id -eq 'BD-B-0013')
    }
} finally {
    Write-Json (Join-Path $run 'identity-results.json') @{powershell=$PSVersionTable.PSVersion.ToString();checks=$checks.ToArray();physical_burn_executed=$false;source_deletion_executed=$false;run_id=(Split-Path $run -Leaf)}
    Write-Host "Identity test results: $run"
}
