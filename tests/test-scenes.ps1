[CmdletBinding()]
param([string]$WorkRoot=(Join-Path $PSScriptRoot '../work/scenes'),[string]$Python,[string]$DwarfsBin)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($run) | Out-Null
$script:checks=New-Object 'System.Collections.Generic.List[object]'
function Assert($Test,$Message) { if (!$Test) { throw $Message } }
function Reject([scriptblock]$Action,$Match) { $rejected=$false;try { & $Action | Out-Null } catch { $rejected=$true;Assert ($_.Exception.Message -match $Match) "Unexpected rejection: $_" };Assert $rejected 'Expected operation to reject' }
function Case($Name,[scriptblock]$Action) { & $Action;$script:checks.Add(@{name=$Name;status='PASS'});Write-Host "PASS $Name" }
$config=Read-Json (Full-Path (Join-Path $PSScriptRoot '../archive.config.json'))
$config.dwarfs.build_profile='verified';$config.dwarfs.skip_roundtrip=$false
$config.archive_root=Join-Path $run 'archive';$config.catalog_path=Join-Path $run 'catalog.sqlite';$config.tools.python=$Python
$config.media.BD25.payload_gib=0.000022;$config.media.BD25.dwarfs_payload_gib=0.003
$config.planning.per_file_overhead_bytes=1;$config.planning.dwarfs_overhead_mib=0.1
if ($DwarfsBin) { $config.tools.dwarfs_bin=$DwarfsBin }
$cfg=Join-Path $run 'archive.config.json';Write-Json $cfg $config
function Run($Command,$Extra) { $p=@{Config=$cfg;Execute=$true;ParPercent=0};foreach ($k in $Extra.Keys) { $p[$k]=$Extra[$k] };Invoke-Archive $Command $p }
function RunWithDefaults($Command,$Extra) { $p=@{Config=$cfg;Execute=$true};foreach ($k in $Extra.Keys) { $p[$k]=$Extra[$k] };Invoke-Archive $Command $p }
$source=Join-Path $run '照片 空格';[IO.Directory]::CreateDirectory((Join-Path $source '旅程')) | Out-Null
foreach ($n in @('旅程/001.ARW','旅程/002.ARW','旅程/003.ARW')) { [IO.File]::WriteAllBytes((Join-Path $source $n),(New-Object byte[] 12000)) }
Write-Text (Join-Path $source '旅程/001.XMP') 'SYNTHETIC sidecar';Write-Text (Join-Path $source '旅程/002.ARW.xmp') 'SYNTHETIC sidecar';Write-Text (Join-Path $source '旅程/003.JPG') 'SYNTHETIC preview'
$photo=@{SetId='PHOTO-SYNTHETIC';Source=$source;Scenario='photo';PhotoTier='C';DateRange='2025-01 (user note)';Camera='Example camera';Summary='SYNTHETIC photo fixture';DetectDuplicates=$true;Deduplicate=$true}
try {
    Case 'preparation dry-run does not create archive' {
        $p=$photo.Clone();$p.Config=$cfg
        $r=Invoke-Archive prepare $p;Assert ($r.status -eq 'DRY_RUN') 'Wrong default'
        Assert (!(Test-Path -LiteralPath $config.archive_root)) 'Dry-run wrote the archive'
    }
    Case 'photo families remain independent and together on small discs' {
        $r=Run prepare $photo;Assert ($r.status -eq 'READY_FOR_REVIEW') 'Preparation failed'
        $plan=Load-Plan $config $photo.SetId;Assert ($plan.discs.Count -eq 3) 'Expected three complete photo families'
        foreach ($d in $plan.discs) {
            Assert ($d.files.Count -eq 2) 'Photo companion was separated or deduplicated'
            Assert (@($d.files | Group-Object { Photo-Family $_.path }).Count -eq 1) 'Families mixed unexpectedly'
            $rec=Get-Disc $config $d.disc_id;Assert (!$rec.burn -and $rec.status -eq 'STAGED') 'Prepare wrote a disc'
            Assert (Test-Path -LiteralPath (Join-Path $rec.stage.path 'PHOTO-CATALOG.csv')) 'Photo catalog missing'
        }
        Reject { Pack-Files @([pscustomobject]@{path='1.ARW';size=9},[pscustomobject]@{path='1.XMP';size=2}) 10 -PhotoFamilies } 'Oversize'
    }
    Case 'photo defaults to no PAR2 even when backup default is configured' {
        $p=$photo.Clone();$p.SetId='PHOTO-DEFAULT-NO-PAR'
        $null=RunWithDefaults prepare $p
        $plan=Load-Plan $config $p.SetId
        Assert (($plan.discs | Where-Object { $_.budget.par2_percent -ne 0 }).Count -eq 0) 'Photo plan inherited backup PAR2 default'
    }
    Case 'photo summary has no iPhone or password fields and supports resume' {
        $summary=Read-Json (Join-Path (Set-Dir $config $photo.SetId) 'ARCHIVE-SUMMARY.json')
        Assert ($summary.details.raw_files -eq 3 -and $summary.details.sidecar_files -eq 2) 'Incorrect photo counts'
        $text=[IO.File]::ReadAllText((Join-Path (Set-Dir $config $photo.SetId) 'ARCHIVE-SUMMARY.txt'))
        Assert ($text -notmatch 'Encryption password:|Backup date:|iOS:') 'Backup template leaked into photo summary'
        $hash=File-Hash (Join-Path (Set-Dir $config $photo.SetId) 'plan.json')
        $null=Run prepare $photo
        Assert ($hash -eq (File-Hash (Join-Path (Set-Dir $config $photo.SetId) 'plan.json'))) 'Resume changed immutable plan'
    }
    Case 'Tier B and A preserve sources, with distinct disc prefixes' {
        foreach ($tier in @('B','A')) {
            $p=$photo.Clone();$p.SetId="PHOTO-TIER-$tier";$p.PhotoTier=$tier;$p.Deduplicate=$false
            $null=Run prepare $p
            $plan=Load-Plan $config $p.SetId;$prefix=if ($tier -eq 'A') { 'BD-M-' } else { 'BD-P-' }
            Assert ($plan.discs[0].disc_id.StartsWith($prefix)) 'Wrong physical prefix'
            Reject { Run delete-source @{SetId=$p.SetId;DeleteSourceConfirmed=$true} } 'Tier A/B'
        }
        Assert (@(Tree-Files $source).Count -eq 6) 'Photo originals modified'
    }
    Case 'game workflow retains master notes independently of source deletion' {
        $src=Join-Path $run 'game';[IO.Directory]::CreateDirectory($src) | Out-Null
        Write-Text (Join-Path $src 'recording.mkv') 'SYNTHETIC placeholder, not playable video'
        $null=Run prepare @{SetId='GAME-SYNTHETIC';Source=$src;Scenario='game';Game='Example game';Summary='User reviewed docking event';MasterStatus='encoded_copy_is_master';EarlierOriginalStatus='DELETED'}
        $s=Read-Json (Join-Path (Set-Dir $config 'GAME-SYNTHETIC') 'ARCHIVE-SUMMARY.json')
        Assert ($s.details.game -eq 'Example game' -and $s.details.master_status -eq 'encoded_copy_is_master') 'Game summary lost metadata'
        Assert (!$s.original_deleted -and $s.details.earlier_original_status -eq 'DELETED') 'Historical/current original deletion conflated'
        Assert ($null -eq $s.details.PSObject.Properties['encrypted']) 'Phone fields in game template'
    }
    Case 'interactive confirmation cancellation produces no burn record' {
        $d=(Load-Plan $config $photo.SetId).discs[0];$rec=Get-Disc $config $d.disc_id
        $module=Get-Module Archive.Core
        & $module { function script:Read-Host { 'CANCEL' } }
        try {
            Reject { Confirm-PhysicalBurn $config $d $rec @{Drive='Z:';ConfirmationMode='Console'} 'TEST_NO_HARDWARE' 25000000000 } 'cancelled'
            Assert (!(Get-Disc $config $d.disc_id).burn) 'Cancellation consumed disc'
            $events=[IO.File]::ReadAllText((Join-Path $config.archive_root 'events.jsonl'))
            Assert ($events -notmatch 'user-burn-confirmed') 'Cancellation recorded approval'
        } finally { & $module { Remove-Item Function:Read-Host -ErrorAction SilentlyContinue } }
        Reject { Run burn @{DiscId=$d.disc_id;Drive='Z:'} } 'BurnConfirmed'
    }
    Case 'GUI JSON worker completes a dry-run without command interpolation' {
        $job=Join-Path $run 'request unicode 空格.json'
        Write-Json $job @{command='prepare';parameters=@{Config=$cfg;SetId='IGNORED';Source='C:\does not exist;$(ignored)';Scenario='photo';Execute=$false}}
        & (Join-Path $PSScriptRoot '../scripts/run-request.ps1') -RequestPath $job
        $r=Read-Json "$job.result.json";Assert ($r.status -eq 'PASS' -and $r.result.status -eq 'DRY_RUN') 'Worker failed'
    }
    if ($DwarfsBin) {
        Case 'backup preparation builds an independent real DwarFS and stops' {
            $src=Join-Path $run 'backup';[IO.Directory]::CreateDirectory($src) | Out-Null
            Write-Text (Join-Path $src 'Manifest.db') 'SYNTHETIC placeholder'
            Write-Text (Join-Path $src 'data-file') 'SYNTHETIC backup payload'
            $null=Run prepare @{SetId='BACKUP-SYNTHETIC';Source=$src;Scenario='backup'}
            $d=(Load-Plan $config 'BACKUP-SYNTHETIC').discs[0];$b=Read-Json (Safe-Join $config.archive_root "build/$($d.disc_id)/build.json")
            Assert ($b.roundtrip -eq 'PASS' -and $b.verification.exit_code -eq 0) 'DwarFS validation failed'
            Assert (!(Get-Disc $config $d.disc_id).burn) 'Backup preparation performed burn'
        }
    }
} finally {
    Write-Json (Join-Path $run 'scene-results.json') @{powershell=$PSVersionTable.PSVersion.ToString();checks=$script:checks.ToArray();run=$run;live_dwarfs=[bool]$DwarfsBin}
    Write-Host "Scene fixtures: $run"
}
