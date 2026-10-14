[CmdletBinding()]
param([string]$WorkRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/Archive.Core.psm1') -Force -DisableNameChecking
if (!$WorkRoot) { $WorkRoot=Join-Path $PSScriptRoot '../work/finalization' }
$run=Join-Path (Full-Path $WorkRoot) ([guid]::NewGuid().ToString('N'))
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
Add-Type -Path (Join-Path $PSScriptRoot '../scripts/Archive.DiscInformation.cs')
$results=@()
$data=New-Object byte[] 34;$data[1]=32;$data[2]=14;$data[3]=1
$mmc=[ArchiveDiscInformation]::Parse($data)
Assert ($mmc.DiscStatus -eq 2 -and $mmc.LastSessionStatus -eq 3 -and $mmc.Finalized) 'Complete MMC header not decoded.'
$state=Resolve-DiscFinalization 0x8000 $mmc
Assert ($state.finalized -eq $true -and $state.source -eq 'MMC_READ_DISC_INFORMATION') 'Unsupported writer interface hid complete disc.'
$results+=@{name='recorded 00-20-0E-01 MMC response overrides unsupported writer status';status='PASS'}
Assert ((Resolve-DiscFinalization 0x4000).finalized -eq $true) 'IMAPI finalized flag rejected.'
foreach ($unknown in @($null,0,0x8000,0x2000,0x8)) { Assert ($null -eq (Resolve-DiscFinalization $unknown).finalized) 'Unknown status was called unfinalized/finalized.' }
$results+=@{name='IMAPI finalized and unknown states remain distinct';status='PASS'}
foreach ($flags in @(0,5,9,13,10)) {
    $data[2]=$flags;$info=[ArchiveDiscInformation]::Parse($data)
    Assert ((Resolve-DiscFinalization 0x8000 $info).finalized -eq $false) 'Empty/incomplete/damaged session accepted.'
}
$data[2]=15;Assert ($null -eq (Resolve-DiscFinalization 0x8000 ([ArchiveDiscInformation]::Parse($data))).finalized) 'Reserved disc status accepted.'
$rejected=$false;try {$null=[ArchiveDiscInformation]::Parse([byte[]]@(0,32,14))} catch {$rejected=$true};Assert $rejected 'Truncated MMC response accepted.'
$results+=@{name='empty, appendable, incomplete session, reserved and truncated MMC data';status='PASS'}
$c=Read-Json (Join-Path $PSScriptRoot '../archive.config.example.json');$c.archive_root=Join-Path $run 'archive';$c.catalog_path=Join-Path $run 'catalog.sqlite'
$null=Initialize-Archive $c
$record=[pscustomobject]@{disc_id='BD-B-0001';hash=('a'*64);status='BURNED_UNVERIFIED';burn=[pscustomobject]@{simulation=$false};verification=$null}
$cat=Read-Json (Catalog-Path $c);$cat.discs=@($record);Write-Json (Catalog-Path $c) $cat
$p=@{DiscId=$record.disc_id;Simulate=$false;MediaReloaded=$true;Drive='Z:';RecorderId='SYNTHETIC'}
& (Get-Module Archive.Core) {
    $script:testFinalization=$null;$script:contentCalls=0;$script:testBadContent=$false;$script:finalizationFixtureRoot='Z:\'
    function script:Get-OpticalReadbackMedia($Drive,$Record,$RecorderId) {
        if ($Drive -ne 'Z:' -or $RecorderId -ne 'SYNTHETIC') { throw 'Only synthetic devices accepted in test.' }
        @{root=$script:finalizationFixtureRoot;finalized=$script:testFinalization;finalization=@{source='FIXTURE'}}
    }
    function script:Check-DiscTree($C,$Root,$Record,[switch]$Integrity) {
        $script:contentCalls++
        if ($script:testBadContent) { throw 'SYNTHETIC_HASH_MISMATCH' }
        @{file_count=5;status='PASS'}
    }
}
try {
    $err='';try {$null=Verify-ArchiveDisc $c $p} catch {$err=$_.Exception.Message}
    $r=Get-Disc $c $record.disc_id
    Assert ($err -match 'NOT_RUN' -and $r.status -eq 'BURNED_UNVERIFIED' -and !$r.verification -and $r.last_verification_attempt.status -eq 'NOT_RUN') 'Preflight failure falsely marked corruption.'
    Assert ((& (Get-Module Archive.Core) {$script:contentCalls}) -eq 0) 'Preflight failure read content.'
    $results+=@{name='unknown preflight records NOT_RUN with zero content reads and preserved burn';status='PASS'}
    & (Get-Module Archive.Core) {$script:testFinalization=$true}
    $pass=Verify-ArchiveDisc $c $p;$r=Get-Disc $c $record.disc_id
    Assert ($pass.status -eq 'PASS' -and $r.status -eq 'VERIFIED' -and $r.verification.phase -eq 'CONTENT') 'Valid finalization did not reach content verification.'
    $previous=$r.verification.report
    & (Get-Module Archive.Core) {$script:testFinalization=$null}
    try {$null=Verify-ArchiveDisc $c $p} catch {}
    $r=Get-Disc $c $record.disc_id
    Assert ($r.status -eq 'VERIFIED' -and $r.verification.report -eq $previous -and $r.last_verification_attempt.status -eq 'NOT_RUN') 'An unavailable drive erased prior content evidence.'
    $results+=@{name='content PASS required for VERIFIED; later preflight error preserves prior verification';status='PASS'}
    & (Get-Module Archive.Core) {$script:testFinalization=$true;$script:testBadContent=$true}
    try {$null=Verify-ArchiveDisc $c $p} catch {}
    $r=Get-Disc $c $record.disc_id
    Assert ($r.status -eq 'VERIFY_FAILED' -and $r.verification.status -eq 'FAIL' -and $r.verification.phase -eq 'CONTENT') 'Real content failure was hidden.'
    $results+=@{name='content mismatch still records FAIL';status='PASS'}
    $fixtureRoot=Join-Path $run 'synthetic optical';Write-Text (Join-Path $fixtureRoot 'SHA256SUMS') 'fixture sums';Write-Text (Join-Path $fixtureRoot 'DISC.json') '{}'
    & (Get-Module Archive.Core) { param($Root) $script:finalizationFixtureRoot=$Root } $fixtureRoot
    $r.burn | Add-Member NoteProperty result 'WRITTEN'
    $r | Add-Member NoteProperty stage ([pscustomobject]@{hash=(File-Hash (Join-Path $fixtureRoot 'SHA256SUMS'));disc_json_hash=(File-Hash (Join-Path $fixtureRoot 'DISC.json'))})
    Update-Disc $c $r
    $blocked=$false;try {$null=Repair-VerificationPreflight $c $p} catch {$blocked=$true};Assert $blocked 'Actual content error was eligible for repair.'
    $legacyPath=Join-Path $run 'legacy-report.json'
    Write-Json $legacyPath @{error='Media is not reported finalized. Do not delete originals.';disc_id=$r.disc_id;manifest_sha256=$r.hash;root=$null;media=$null}
    $r.verification=[pscustomobject]@{status='FAIL';simulation=$false;report=$legacyPath;report_sha256=(File-Hash $legacyPath)};Update-Disc $c $r
    $contentBefore=& (Get-Module Archive.Core) {$script:contentCalls}
    $fixed=Repair-VerificationPreflight $c $p;$after=Get-Disc $c $r.disc_id
    Assert ($fixed.status -eq 'BURNED_UNVERIFIED' -and !$after.verification -and @($after.verification_history).Count -eq 1 -and (Test-Path -LiteralPath $legacyPath)) 'Legacy correction lost history or falsely passed content.'
    Assert ((& (Get-Module Archive.Core) {$script:contentCalls}) -eq $contentBefore) 'Metadata-only correction ran full content check.'
    $results+=@{name='legacy preflight correction preserves history without content reads; real content failures cannot clear';status='PASS'}
} finally { Remove-Module Archive.Core }
$result=@{status='PASS';powershell=$PSVersionTable.PSVersion.ToString();results=$results;device_access=$false;physical_burn=$false;content_reader_mocked=$true}
[IO.File]::WriteAllText((Join-Path $run 'finalization-results.json'),($result | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
Write-Host "PASS $($results.Count) groups: $run"
